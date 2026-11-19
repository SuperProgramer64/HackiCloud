import hashlib, shutil, struct, subprocess, sys, tempfile, unittest
from pathlib import Path
from hackicloud import boot_image as boot
ROOT=Path(__file__).resolve().parents[1]
class BootImage(unittest.TestCase):
 def test_rejects_stock_or_signed_images(self):
  for data in [b'ANDROID!'+bytes(4088),b'not a boot image']:
   with self.assertRaises(ValueError):boot.decode_header(data)
 def test_rejects_image_with_avb_signature(self):
  hdr=bytearray(8192);hdr[:8]=b'ANDROID!';struct.pack_into('<I',hdr,8,4);struct.pack_into('<I',hdr,20,1584);struct.pack_into('<I',hdr,40,4);hdr[-64:-60]=b'AVBf'
  with self.assertRaises(ValueError):boot.decode_header(hdr)
 @unittest.skipUnless(shutil.which('lz4'),'requires lz4')
 def test_real_apfs_repack_preserves_kernel_android_files_and_input(self):
  with tempfile.TemporaryDirectory() as tmp:
   t=Path(tmp);root=t/'root';(root/'bin').mkdir(parents=True);(root/'etc').mkdir()
   (root/'etc/rc.jobs').write_text('/redwood/bin/other &\n/redwood/bin/usbmuxd_dev &\n')
   (root/'etc/inject.conf').write_text('preserve me\n');(root/'bin/original').write_bytes(b'original')
   (root/'bin/original').chmod(0o751);(root/'alias').symlink_to('/redwood/bin/original')
   rootimg=t/'root.apfs'
   subprocess.run([sys.executable,str(ROOT/'hackicloud/vendor/apfs/mkapfs.py'),'-z','-o',str(rootimg),'redwood='+str(root)],check=True,stdout=subprocess.DEVNULL)
   md0=bytes(16384);md1=rootimg.read_bytes();at=boot.MD0+boot.align(len(md0),16384);table=b"XTBL"+bytes(280000);table_at=boot.align(at+len(md1),16384);android_at=boot.align(table_at+len(table),2<<20)
   blob=bytearray(android_at+4096);blob[0x38:0x3c]=b'ARM\x64';blob[0x200:0x20d]=b'usb=2\0duchamp';blob[boot.KERNEL:boot.KERNEL+4]=b'\xcf\xfa\xed\xfe';marker=b'/dev/hakios-usbmux\0\0';blob[boot.KERNEL+100:boot.KERNEL+100+len(marker)]=marker
   struct.pack_into('<Q',blob,0x20,(4096<<32)|android_at);struct.pack_into('<QQ',blob,0x28,len(md0),len(md1));blob[boot.MD0:boot.MD0+len(md0)]=md0;blob[at:at+len(md1)]=md1;blob[android_at:android_at+4]=b'KEEP';blob[table_at:table_at+len(table)]=table;struct.pack_into('<4sIQ',blob,0xffff0,b'VTBL',len(table),table_at)
   compressed=subprocess.check_output(['lz4','-l','-c'],input=blob,stderr=subprocess.DEVNULL);hdr=bytearray(4096);hdr[:8]=b'ANDROID!';struct.pack_into('<I',hdr,8,len(compressed));struct.pack_into('<I',hdr,20,1584);struct.pack_into('<I',hdr,40,4)
   image=t/'boot.img';image.write_bytes(hdr+compressed+bytes((8<<20)-4096-len(compressed)));before=hashlib.sha256(image.read_bytes()).hexdigest()
   artifacts=t/'artifacts';artifacts.mkdir()
   for name in ['usbmuxd_dev','usbmux_watchdog']:(artifacts/name).write_bytes(b'my signed helper '+name.encode())
   out=t/'patched.img';report=boot.patch(image,out,artifacts)
   self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(),before)
   self.assertTrue(report['kernel_unchanged']);self.assertTrue(report['android_unchanged'])
   self.assertEqual(out.stat().st_size,image.stat().st_size)
   with self.assertRaises(FileExistsError):boot.patch(image,out,artifacts)
   # Re-read actual output filesystem, not just the patcher's report.
   _,newblob=boot.unpack(out);a,b=struct.unpack_from('<QQ',newblob,0x28);start=boot.MD0+boot.align(a,16384)
   _,table_length,newtable=struct.unpack_from('<4sIQ',newblob,0xffff0);self.assertEqual(newblob[newtable:newtable+table_length],table)
   extracted=t/'verify.apfs';extracted.write_bytes(newblob[start:start+b]);inventory=boot.inventory(extracted)
   self.assertEqual(inventory['bin/original']['data'],b'original');self.assertEqual(inventory['bin/original']['mode']&0o777,0o751)
   self.assertEqual(inventory['alias']['data'],b'/redwood/bin/original')
   self.assertEqual(inventory['etc/inject.conf']['data'],b'preserve me\n')
   self.assertEqual(inventory['etc/rc.jobs']['data'],b'/redwood/bin/other &\n/redwood/bin/usbmux_watchdog &\n')
   self.assertEqual(inventory['bin/usbmuxd_dev']['data'],(artifacts/'usbmuxd_dev').read_bytes())
if __name__=='__main__':unittest.main()
