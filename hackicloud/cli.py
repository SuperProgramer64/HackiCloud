"""Mac entry point. Commands never request an Apple Account password."""
import argparse
import base64
import gzip
import hashlib
import json
import secrets
import time
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
from .protocol import Mux, Session
from .runtime import ROOT, CONTROL, AnonymousProvider, relay, sign


def checked(args):
    subprocess.run(args, check=True)


def build(sdk=None):
    if platform.system() != 'Darwin':
        raise RuntimeError('macOS is required')
    mac=ROOT/'build/mac';mac.mkdir(parents=True,exist_ok=True)
    for name in ['anonymous_provider','settings_signer','catalog_provider']:
        out=mac/name
        checked(['xcrun','clang','-arch','arm64','-arch','x86_64','-mmacosx-version-min=13.0','-O2','-fobjc-arc','-fblocks','-framework','Foundation',str(ROOT/'native/mac'/(name+'.m')),'-o',str(out)])
        checked(['codesign','--force','--sign','-',str(out)])
        checked(['codesign','--verify','--strict',str(out)])
        checked(['lipo',str(out),'-verify_arch','arm64','x86_64'])
    print('Componentes Mac compilados para Intel y Apple Silicon.')
    if not sdk:
        print('Para compilar los módulos del móvil: build --ios-sdk RUTA_AL_SDK')
        return
    sdk=Path(sdk).expanduser().resolve()
    if not (sdk/'System/Library/Frameworks/Foundation.framework').is_dir():
        raise ValueError('SDK must be an extracted iPhoneOS SDK')
    device=ROOT/'build/device';device.mkdir(parents=True,exist_ok=True)
    sources={
        'anonymous':['anonymous_bridge.m','auth_bridge_transport.m','auth_bridge_data.m','bridge_lease.m'],
        'signer':['settings_signer.m','nac_reply.m','bridge_lease.m'],
        'control':['control.m','bridge_lease.m'],
        'catalog':['catalog.m'],
    }
    for name,files in sources.items():
        out=device/('hackicloud_'+name)
        cmd=['xcrun','clang','-target','arm64-apple-ios16.0','-isysroot',str(sdk),'-O2','-Wall','-Wextra','-fobjc-arc','-fblocks','-framework','Foundation']
        if name not in ('control','catalog'):cmd+=['-dynamiclib']
        checked(cmd+[str(ROOT/'native/device'/n)for n in files]+['-o',str(out)])
        signing=['codesign','--force','--sign','-']
        if name=='catalog':signing+=['--entitlements',str(ROOT/'native/device/catalog-entitlements.plist')]
        checked(signing+[str(out)])
        checked(['codesign','--verify','--strict',str(out)])
    print('Módulos ARM64 compilados. No se ha instalado ni reiniciado nada.')


def upload(mux,path):
    name=path.name
    if not re.fullmatch(r'hackicloud_[a-z]+',name):
        raise ValueError('Unexpected artifact filename')
    dest='/var/jb/usr/bin/'+name
    wire=base64.b64encode(gzip.compress(path.read_bytes(),mtime=0)).decode()
    suffix=secrets.token_hex(6)
    temp='/var/jb/tmp/'+name+'.upload.'+suffix
    out='/var/jb/usr/bin/'+name+'.new.'+suffix
    # Only fixed, project-owned paths and base64 chunks enter the remote shell.
    mux.run(['/var/jb/bin/sh','-c','umask${IFS}077;set${IFS}-C;:>'+temp])
    try:
        for offset in range(0,len(wire),600):
            mux.run(['/var/jb/bin/sh','-c','printf${IFS}%s${IFS}'+wire[offset:offset+600]+'|/var/jb/usr/bin/base64${IFS}-d>>'+temp])
        mux.run(['/var/jb/bin/sh','-c','umask${IFS}077;set${IFS}-C;/var/jb/usr/bin/gzip${IFS}-dc${IFS}'+temp+'>'+out])
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        actual=mux.run(['/var/jb/usr/bin/sha256sum',out])
        if not re.search(r'\b'+digest+r'\b',actual):
            raise ValueError('Device artifact checksum mismatch')
        mux.run(['/var/jb/usr/bin/chmod','755',out])
        mux.run(['/var/jb/usr/bin/mv','-f',out,dest])
    finally:
        try:mux.run(['/var/jb/usr/bin/rm','-f',temp,out])
        except Exception:pass


def doctor(args):
    print('HackiCloud 0.1.0 — comprobación local; no se leen cuentas ni contraseñas.')
    ok=platform.system()=='Darwin' and sys.version_info>=(3,9)
    print('macOS:', 'sí' if platform.system()=='Darwin' else 'no')
    print('Python >= 3.9:', 'sí' if sys.version_info>=(3,9) else 'no')
    print('Arquitectura del Mac:',platform.machine())
    for name in ['xcrun','codesign','lipo']:
        exists=bool(shutil.which(name));ok=ok and exists
        print(name+':','disponible' if exists else 'falta')
    if args.native_check:
        with AnonymousProvider()as provider:data=provider.fetch()
        if not data.get('mid')or not data.get('otp'):raise ValueError('Native validation unavailable')
        del data
        signature=sign(b'HackiCloud capability check; synthetic data only')
        print('Validación nativa y firma sintética: disponibles. Valores omitidos.')
        del signature
    if not args.offline:
        Mux(args.mux_socket,args.device_id).device()
        print('Un dispositivo USB compatible está disponible; todavía no acredita compatibilidad del kernel.')
    return 0 if ok else 1


def legacy_sessions(mux):
    raw=mux.run([CONTROL,'legacy-info'])
    start=raw.find('{');end=raw.rfind('}')
    value=json.loads(raw[start:end+1])
    if set(value)!={'anonymous','signer'}or any(not isinstance(v,str)or not re.fullmatch('[0-9a-f]{32}',v)for v in value.values()):
        raise ValueError('Incompatible existing session')
    return Session(None,value['anonymous']),Session(None,value['signer'])


def main(argv=None):
    parser=argparse.ArgumentParser(description='HackiCloud: puente local para iCloud desde Ajustes en HakiOS.')
    parser.add_argument('--mux-socket',default=os.environ.get('HACKICLOUD_USBMUX_SOCKET','/var/run/usbmuxd'))
    parser.add_argument('--device-id',type=int)
    parser.add_argument('--state-dir',default=str(Path.home()/'Library/Application Support/HackiCloud'))
    sub=parser.add_subparsers(dest='command',required=True)
    d=sub.add_parser('doctor');d.add_argument('--offline',action='store_true');d.add_argument('--native-check',action='store_true')
    b=sub.add_parser('build');b.add_argument('--ios-sdk')
    i=sub.add_parser('install');i.add_argument('--restart-auth',action='store_true');i.add_argument('--dry-run',action='store_true');i.add_argument('--reuse-existing',action='store_true')
    r=sub.add_parser('run');r.add_argument('--minutes',type=int,default=120);r.add_argument('--reuse-existing',action='store_true')
    c=sub.add_parser('enable-catalog');c.add_argument('--storefront',default='us',help='Código de país de dos letras; por ejemplo us, es o ve')
    sub.add_parser('status');sub.add_parser('uninstall')
    args=parser.parse_args(argv)
    if args.command=='doctor':return doctor(args)
    if args.command=='build':build(args.ios_sdk);return 0
    if args.command=='install'and args.dry_run:
        print('Se instalarían únicamente hackicloud_anonymous, hackicloud_signer y hackicloud_control en /var/jb/usr/bin.')
        print('Se añadirían dos entradas propias en kern.exec_inject y dos permisos privados temporales.')
        print('No se ha conectado al móvil, creado sesión, instalado ni reiniciado nada.')
        return 0
    mux=Mux(args.mux_socket,args.device_id)
    if args.command=='enable-catalog':
        from .catalog import enable
        helper=ROOT/'build/device/hackicloud_catalog'
        if not helper.is_file():raise ValueError('Compile the optional catalog helper first')
        upload(mux,helper)
        enable(mux,args.storefront)
        return 0
    if args.command=='status':
        print(mux.run([CONTROL,'status']).strip());return 0
    if args.command=='uninstall':
        mux.run([CONTROL,'remove'])
        print('Entradas y permisos de HackiCloud retirados. Las cuentas se conservan.')
        return 0
    if args.command=='run'and not 1<=args.minutes<=1440:raise ValueError('Duration must be 1..1440 minutes')
    if args.command=='install'and args.reuse_existing:
        control=ROOT/'build/device/hackicloud_control'
        if not control.is_file():raise ValueError('Compile device modules first')
        upload(mux,control)
        mux.run([CONTROL,'sync-clock',str(int(time.time()))])
        legacy_sessions(mux)
        print('Integración existente compatible. No se han sustituido hooks ni reiniciado procesos.')
        return 0
    if args.command=='run'and args.reuse_existing:
        mux.run([CONTROL,'sync-clock',str(int(time.time()))])
        anonymous,signer=legacy_sessions(mux)
        print('Se utiliza la integración iCloud existente, sin sustituir sus módulos. Ctrl+C para detener.')
        relay(mux,anonymous,args.minutes,signer_session=signer)
        return 0
    session=Session.open(Path(args.state_dir)/'session.json')
    if args.command=='install':
        paths=[ROOT/'build/device'/('hackicloud_'+n)for n in ['anonymous','signer','control']]
        if not all(p.is_file()for p in paths):raise ValueError('Compile device modules first')
        for path in paths:upload(mux,path)
        mux.run([CONTROL,'sync-clock',str(int(time.time()))])
        mux.run([CONTROL,'install',session.nonce,'7190'])
        if args.restart_auth:mux.run([CONTROL,'restart-auth'])
        print('Configuración instalada. Cierra y abre Ajustes manualmente; ejecuta run antes de iniciar sesión.')
        if not args.restart_auth:print('Falta relanzar akd para cargar su módulo: usa install --restart-auth o el procedimiento de tu port.')
    elif args.command=='run':
        if not 1<=args.minutes<=1440:raise ValueError('Duration must be 1..1440 minutes')
        print('Se procesarán solicitudes de Ajustes en la RAM de este Mac por USB; sin registros de contenido. Ctrl+C para detener.')
        relay(mux,session,args.minutes)
    return 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except KeyboardInterrupt:raise SystemExit(130)
    except Exception as error:
        # A fixed error category is safe; exception values and tracebacks may contain payloads.
        if isinstance(error,subprocess.CalledProcessError):message='Falló la compilación o firma; revisa la salida de las herramientas.'
        elif isinstance(error,(ConnectionError,OSError,TimeoutError)):message='No se pudo acceder al servicio local o al móvil. Revisa doctor y el enlace USB.'
        else:message='No se pudo completar la operación. Revisa los requisitos, permisos y posibles módulos en conflicto.'
        print('HackiCloud: '+message,file=sys.stderr);raise SystemExit(1)
