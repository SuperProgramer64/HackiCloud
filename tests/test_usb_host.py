import tempfile,unittest
from pathlib import Path
from hackicloud.usb_host import prepare_socket
class USBHost(unittest.TestCase):
 def test_private_socket_location_does_not_replace_a_file(self):
  with tempfile.TemporaryDirectory() as td:
   p=prepare_socket(td);self.assertEqual(p.parent.stat().st_mode&0o777,0o700)
   p.write_bytes(b'keep')
   with self.assertRaises(FileExistsError):prepare_socket(td)
   self.assertEqual(p.read_bytes(),b'keep')
 def test_refuses_shared_directory(self):
  with tempfile.TemporaryDirectory() as td:
   (Path(td)/'usb').mkdir(mode=0o755)
   with self.assertRaises(ValueError):prepare_socket(td)
