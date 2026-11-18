"""Optional anonymous App Store catalog access; account authentication is outside scope."""
import concurrent.futures
import datetime
import json
import math
import re
import resource
import secrets
import subprocess
import time
from .protocol import send_frame
from .runtime import ROOT

HELPER='/var/jb/usr/bin/hackicloud_catalog'


def validate_token(value, now=None):
    now=time.time() if now is None else now
    if not isinstance(value,dict) or set(value)!={'token','expiry'}:
        raise ValueError('Invalid anonymous catalog response')
    token,expiry=value['token'],value['expiry']
    if not isinstance(token,str) or not 16<=len(token)<=8192 or not re.fullmatch(r'[A-Za-z0-9._~+/=-]+',token):
        raise ValueError('Invalid anonymous catalog token')
    if type(expiry) not in (int,float) or not math.isfinite(expiry) or not now+60<expiry<=now+60*86400:
        raise ValueError('Invalid anonymous catalog expiry')
    return value


def cached_result(output):
    rows=[line[7:] for line in output.splitlines() if line.startswith('STATUS ')]
    if len(rows)!=1:raise ValueError('Catalog metadata unavailable')
    value=json.loads(rows[0])
    if not isinstance(value,dict) or set(value)!={'present','valid','expiry'} or type(value['present']) is not bool or type(value['valid']) is not bool or type(value['expiry']) not in (int,float) or not math.isfinite(value['expiry']):
        raise ValueError('Invalid catalog metadata')
    return value


def enable(mux, storefront='us'):
    if not re.fullmatch('[a-z]{2}',storefront):raise ValueError('Use a two-letter storefront')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    state=cached_result(mux.run([HELPER,'status']))
    if state['valid']:
        print('El catálogo ya tiene un token válido; se conserva.')
    else:
        if state['present']:raise ValueError('Existing catalog entry is unusable; it has not been overwritten')
        result=subprocess.run([str(ROOT/'build/mac/catalog_provider'),'--pipe'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=55)
        rows=[line[10:] for line in result.stdout.splitlines() if line.startswith(b'TOKENJSON ')]
        if result.returncode or len(rows)!=1:raise RuntimeError('Native anonymous catalog request failed')
        value=validate_token(json.loads(rows[0]));del rows,result
        nonce=secrets.token_hex(16)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            receiver=pool.submit(mux.run,[HELPER,'install',nonce,storefront],timeout=75)
            deadline=time.monotonic()+12
            while True:
                if receiver.done():receiver.result();raise RuntimeError('Catalog receiver did not start')
                try:sock=mux.connect(19831);break
                except (ConnectionError,OSError):
                    if time.monotonic()>=deadline:raise TimeoutError('Catalog receiver unavailable')
                    time.sleep(.2)
            with sock:
                sock.settimeout(15);send_frame(sock,dict(value,nonce=nonce))
            del value
            receiver.result(timeout=45)
        state=cached_result(mux.run([HELPER,'status']))
        if not state['valid']:raise RuntimeError('Native catalog readback failed')
    output=mux.run([HELPER,'verify',storefront],timeout=40)
    if 'CATALOG HTTP=200 item=686449807' not in output:raise RuntimeError('Catalog verification failed')
    print('Catálogo verificado desde el móvil: HTTP 200, Telegram Messenger.')
    expiry=datetime.datetime.fromtimestamp(state['expiry'],datetime.timezone.utc)
    print('Vencimiento real del token:',expiry.isoformat())
    print('Esto habilita el catálogo; el acceso a la cuenta y las descargas no están incluidos.')
