"""Protocol, private local state and device-command boundary regressions."""
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest

from hackicloud.protocol import Session, Mux, receive_frame, send_frame, command_line


class ClientTests(unittest.TestCase):
    def test_frames_reject_oversize_before_reading_payload(self):
        a, b = socket.socketpair()
        with a, b:
            a.sendall(struct.pack('>I', 1500001))
            with self.assertRaises(ValueError):
                receive_frame(b)

    def test_frames_roundtrip_unicode(self):
        a, b = socket.socketpair()
        with a, b:
            send_frame(a, {'ready': True, 'text': 'prueba'})
            self.assertEqual(receive_frame(b), {'ready': True, 'text': 'prueba'})

    def test_state_is_private_and_nonce_survives_reopening(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'state' / 'session.json'
            first = Session.open(path)
            second = Session.open(path)
            self.assertEqual(first.nonce, second.nonce)
            self.assertEqual(len(first.nonce), 32)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(set(json.loads(path.read_text())), {'nonce', 'version'})
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                Session.open(path)

    def test_state_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / 'target'
            target.write_text('{}')
            link = Path(d) / 'link'
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                Session.open(link)

    def test_unrepresentable_command_never_reaches_device(self):
        self.assertEqual(command_line(['/redwood/bin/jb_control', 'probe']), b'/redwood/bin/jb_control probe\n')
        for args in [[], ['a b'], ['a\nexit'], [''], ['x' * 1023]]:
            with self.assertRaises(ValueError):
                command_line(args)

    def test_multiple_usb_devices_require_selection(self):
        class ListedMux(Mux):
            def devices(self):
                return [
                    {'DeviceID': 1, 'Properties': {'ConnectionType': 'USB', 'ProductID': 0x12a8}},
                    {'DeviceID': 2, 'Properties': {'ConnectionType': 'USB', 'ProductID': 0x12a8}},
                    {'DeviceID': 3, 'Properties': {'ConnectionType': 'Network', 'ProductID': 0x12a8}},
                ]
        mux = ListedMux('/unused')
        with self.assertRaises(ValueError):
            mux.device()
        self.assertEqual(mux.device(2), 2)
        with self.assertRaises(ValueError):
            mux.device(3)


if __name__ == '__main__':
    unittest.main()
