"""Owner-local host socket; never replaces Apple's system usbmuxd."""
import os
from pathlib import Path
import stat
from .runtime import ROOT

def socket_path(state_dir):return Path(state_dir).expanduser()/'usb'/'usbmuxd.sock'
def prepare_socket(state_dir):
    path=socket_path(state_dir)
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    info=path.parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('USB socket directory must be private and owned by this user')
    if len(os.fsencode(path))>=104:raise ValueError('USB socket path is too long; use a shorter --state-dir')
    if path.exists() or path.is_symlink():raise FileExistsError('USB socket exists; stop its bridge before starting another')
    return path

def start(state_dir):
    binary=ROOT/'build/mac/usb_host'
    if not binary.is_file():raise ValueError('Run build first to compile the universal Mac USB bridge')
    path=prepare_socket(state_dir)
    env=dict(os.environ,HAKIOS_USBMUXD_STORE=str(path.parent/'pair-records'))
    print('Puente USB local: '+str(path),flush=True)
    print('Déjalo abierto; ejecuta HackiCloud desde otra ventana. Ctrl+C para detener.',flush=True)
    try:
        import subprocess
        return subprocess.call([str(binary),str(path)],env=env)
    finally:
        # Only remove our own socket, never a file placed at that pathname.
        try:
            if stat.S_ISSOCK(path.lstat().st_mode):path.unlink()
        except FileNotFoundError:pass
