"""Bounded USB transport and owner-private state. No authentication payload files."""
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import socket
import stat
import struct


def read_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise ConnectionError('USB connection ended')
        data.extend(part)
    return bytes(data)


def receive_frame(sock):
    size = struct.unpack('>I', read_exact(sock, 4))[0]
    if not 0 < size <= 1500000:
        raise ValueError('Invalid frame length')
    return json.loads(read_exact(sock, size))


def send_frame(sock, value):
    wire = json.dumps(value, separators=(',', ':')).encode()
    if not 0 < len(wire) <= 32768:
        raise ValueError('Invalid response length')
    sock.sendall(struct.pack('>I', len(wire)) + wire)


def command_line(args):
    if not args or len(args) > 63:
        raise ValueError('Invalid device argument count')
    if any(not x or any(c in x for c in ' \t\r\n\0') for x in args):
        raise ValueError('Device arguments cannot contain whitespace')
    wire = (' '.join(args) + '\n').encode()
    if len(wire) > 1023:
        raise ValueError('Device command is too long')
    return wire


class Session:
    def __init__(self, path, nonce):
        self.path, self.nonce = path, nonce

    @classmethod
    def open(cls, path):
        path = Path(path).expanduser()
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError('State directory must be private and owned by this user')
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'w') as f:
                json.dump({'nonce': secrets.token_hex(16), 'version': 1}, f)
                f.flush()
                os.fsync(f.fileno())
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            raise ValueError('Unsafe state file') from None
        with os.fdopen(fd, 'r') as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 1024:
                raise ValueError('Unsafe state file permissions or size')
            value = json.load(f)
        if set(value) != {'version', 'nonce'} or value['version'] != 1 or not isinstance(value['nonce'], str) or not re.fullmatch('[0-9a-f]{32}', value['nonce']):
            raise ValueError('Invalid session configuration')
        return cls(path, value['nonce'])


class Mux:
    def __init__(self, path='/var/run/usbmuxd', device_id=None):
        self.path, self.selected_id = path, device_id

    def _request(self, message):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(12)
        try:
            sock.connect(self.path)
            message = dict(message, ClientVersionString='HackiCloud', ProgName='hackicloud', kLibUSBMuxVersion=3)
            payload = plistlib.dumps(message)
            sock.sendall(struct.pack('<IIII', len(payload) + 16, 1, 8, 1) + payload)
            size, version, kind, tag = struct.unpack('<IIII', read_exact(sock, 16))
            if not 16 <= size <= 1048576 or (version, kind, tag) != (1, 8, 1):
                raise ValueError('Unexpected USB multiplexer reply')
            return sock, plistlib.loads(read_exact(sock, size - 16))
        except Exception:
            sock.close()
            raise

    def devices(self):
        sock, reply = self._request({'MessageType': 'ListDevices'})
        sock.close()
        return reply.get('DeviceList', [])

    def device(self, selected=None):
        selected = selected if selected is not None else self.selected_id
        ids = [d['DeviceID'] for d in self.devices()
               if d.get('Properties', {}).get('ConnectionType') == 'USB'
               and d.get('Properties', {}).get('ProductID') == 0x12a8]
        if selected is not None:
            if selected not in ids:
                raise ValueError('Selected compatible USB device is absent')
            return selected
        if len(ids) != 1:
            raise ValueError('Connect one compatible HakiOS device, or select --device-id')
        return ids[0]

    def connect(self, port):
        sock, reply = self._request({'MessageType': 'Connect', 'DeviceID': self.device(), 'PortNumber': socket.htons(port)})
        if reply.get('Number', 1) != 0:
            sock.close()
            raise ConnectionError('Device service is unavailable')
        return sock

    def run(self, args, timeout=15):
        wire = command_line(['/redwood/bin/jb_control', 'run'] + list(args))
        with self.connect(19802) as sock:
            sock.settimeout(timeout)
            sock.sendall(wire)
            out = bytearray()
            while True:
                part = sock.recv(4096)
                if not part:
                    break
                out.extend(part)
                if len(out) > 65536:
                    raise ValueError('Device output exceeded its limit')
        text = out.decode('utf-8', errors='replace')
        if not re.search(r'\[exit 0\]\s*$', text):
            raise RuntimeError('Device command failed; output suppressed')
        return text.rsplit('[exit 0]', 1)[0]
