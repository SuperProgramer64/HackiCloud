"""Two owner-local USB providers. Sensitive messages are never written to files or logs."""
import base64
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import struct
import subprocess
import threading
import time
from .protocol import receive_frame, send_frame

ROOT=Path(__file__).resolve().parents[1]
CONTROL='/var/jb/usr/bin/hackicloud_control'


def validate_request(row,nonce,kind,previous):
    expected={'op','nonce','request'} | ({'body'} if kind=='signer' else set())
    if not isinstance(row,dict) or set(row)!=expected or row['nonce']!=nonce or row['op']!=('nac-sign' if kind=='signer' else 'anisette'):
        raise ValueError('Invalid request')
    sequence=row['request']
    if type(sequence) is not int or not previous<sequence<=2**53:
        raise ValueError('Invalid request sequence')
    body=None
    if kind=='signer':
        if not isinstance(row['body'],str):raise ValueError('Invalid signing payload')
        try:body=base64.b64decode(row['body'],validate=True)
        except Exception:raise ValueError('Invalid signing payload') from None
        if not 0<len(body)<=1048576:raise ValueError('Invalid signing payload size')
    return sequence,body


class AnonymousProvider:
    def __enter__(self):
        self.process=subprocess.Popen([str(ROOT/'build/mac/anonymous_provider')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        return self
    def read(self,size):
        data=bytearray();deadline=time.monotonic()+12;fd=self.process.stdout.fileno()
        while len(data)<size:
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([fd],[],[],remaining)[0]:raise TimeoutError('Native provider timeout')
            part=os.read(fd,size-len(data))
            if not part:raise ConnectionError('Native provider exited')
            data.extend(part)
        return bytes(data)
    def fetch(self):
        self.process.stdin.write(b'\1');self.process.stdin.flush()
        size=struct.unpack('>I',self.read(4))[0]
        if not 0<size<=32768:raise ValueError('Invalid native response size')
        data=json.loads(self.read(size))
        if not isinstance(data,dict)or set(data)!={'mid','otp','routing','issued'}:raise ValueError('Invalid native response')
        return data
    def __exit__(self,*args):
        try:
            self.process.stdin.write(b'\0');self.process.stdin.flush();self.process.wait(timeout=2)
        except (BrokenPipeError,subprocess.TimeoutExpired):
            self.process.kill();self.process.wait()
        finally:self.process.stdin.close();self.process.stdout.close()


def sign(body):
    response=subprocess.run([str(ROOT/'build/mac/settings_signer')],input=struct.pack('>I',len(body))+body,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=39)
    if response.returncode or len(response.stdout)<4:raise RuntimeError('Native signer failed')
    size=struct.unpack('>I',response.stdout[:4])[0];signature=response.stdout[4:]
    if len(signature)!=size or not 16<=size<=16384:raise ValueError('Invalid native signature size')
    return signature


def serve(mux,session,kind,stop):
    port=19835 if kind=='anonymous' else 19836
    with mux.connect(port)as sock:
        sock.settimeout(40);send_frame(sock,{'nonce':session.nonce})
        if receive_frame(sock)!={'ready':True}:raise ConnectionError('Invalid provider handshake')
        print(('Validación' if kind=='anonymous' else 'Firma de Ajustes')+': conectado por USB.',flush=True)
        previous=0
        provider=AnonymousProvider().__enter__()if kind=='anonymous' else None
        try:
            while not stop.is_set():
                if not select.select([sock],[],[],1)[0]:continue
                row=receive_frame(sock);seq,body=validate_request(row,session.nonce,kind,previous)
                if provider:
                    response=provider.fetch();response.update(nonce=session.nonce,request=seq)
                else:
                    signature=sign(body)
                    response={'nonce':session.nonce,'request':seq,'issued':time.time(),'sha256':hashlib.sha256(body).hexdigest(),'signature':base64.b64encode(signature).decode()}
                    del signature
                send_frame(sock,response);del row,body,response;previous=seq
        finally:
            if provider:provider.__exit__(None,None,None)


def relay(mux,session,minutes,signer_session=None):
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    stop=threading.Event()
    def worker(kind):
        delay=1
        while not stop.is_set():
            try:serve(mux,signer_session if kind=="signer"and signer_session else session,kind,stop);delay=1
            except Exception:
                print(('Validación'if kind=='anonymous'else 'Firma de Ajustes')+': esperando conexión; detalles privados omitidos.',flush=True)
            if stop.wait(delay):return
            delay=min(30,delay*2)
    threads=[threading.Thread(target=worker,args=(kind,),daemon=True)for kind in ['anonymous','signer']]
    for t in threads:t.start()
    end=time.monotonic()+minutes*60;renew=0
    try:
        while time.monotonic()<end:
            if time.monotonic()>=renew:
                try:
                    cmd=[CONTROL,'legacy-renew',session.nonce,signer_session.nonce]if signer_session else[CONTROL,'renew',session.nonce,'7190']
                    mux.run(cmd);renew=time.monotonic()+600
                except Exception:renew=time.monotonic()+15
            stop.wait(1)
    except KeyboardInterrupt:pass
    finally:
        stop.set()
        for t in threads:t.join(timeout=2)
        print('Puente detenido. Las cuentas del móvil se conservan.',flush=True)
