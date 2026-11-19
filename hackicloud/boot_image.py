"""Offline, non-flashing adapter for the duchamp HakiOS dual-APFS boot layout."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import sys
import tempfile
from .vendor.apfs import apfs
KERNEL=0x100000
MD0=0x1400000
MAX_BLOB=112<<20
ROOT=Path(__file__).resolve().parents[1]

def align(value,size):return (value+size-1)//size*size

def decode_header(data):
    if len(data)<4096 or data[:8]!=b'ANDROID!':raise ValueError('Not an Android boot image')
    size,ramdisk=struct.unpack_from('<II',data,8)
    if struct.unpack_from('<I',data,40)[0]!=4 or struct.unpack_from('<I',data,20)[0]!=1584 or ramdisk:
        raise ValueError('Only the HakiOS duchamp boot-v4 embedded-APFS layout is supported')
    if struct.unpack_from('<I',data,1580)[0] or data[-64:-60]==b'AVBf':
        raise ValueError('Signed boot images are unsupported; supply the port-generated unsigned boot image')
    if not 4<=size<=len(data)-4096 or any(data[4096+size:]):raise ValueError('Invalid boot payload or nonzero trailer')
    return {'size':size,'partition_size':len(data)}

def lz4_tool():
    tool=shutil.which('lz4')
    if not tool:raise ValueError('Install lz4 with brew install lz4, then retry')
    return tool

def unpack(path):
    path=Path(path)
    if not 4096<=path.stat().st_size<=256<<20:raise ValueError('Unexpected boot partition size')
    data=path.read_bytes();header=decode_header(data);payload=data[4096:4096+header['size']]
    if payload[:4]!=b'\x02\x21\x4c\x18':raise ValueError('Expected legacy LZ4 HakiOS payload')
    # File-backed input avoids deadlocking while simultaneously writing and reading pipes.
    with tempfile.TemporaryFile() as src:
        src.write(payload);src.seek(0)
        child=subprocess.Popen([lz4_tool(),'-d','-c'],stdin=src,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        try:
            blob=child.stdout.read(MAX_BLOB+1)
            if len(blob)>MAX_BLOB:raise ValueError('Expanded boot payload exceeds supported memory layout')
            if child.wait(timeout=30):raise ValueError('Invalid LZ4 payload')
        finally:
            if child.poll() is None:child.kill();child.wait()
            child.stdout.close()
    return data[:4096],blob

def layout(blob):
    if len(blob)<MD0+4096 or blob[0x38:0x3c]!=b'ARM\x64' or blob[KERNEL:KERNEL+4]!=b'\xcf\xfa\xed\xfe':
        raise ValueError('Not a recognized HakiOS duchamp payload')
    if b'usb=2' not in blob[:0xe0000] or b'hakios-usbmux' not in blob[KERNEL:MD0]:
        raise ValueError('The port kernel/loader must already provide hakios-usbmux and usb=2')
    a,b=struct.unpack_from('<QQ',blob,0x28);start=MD0+align(a,16384)
    android=struct.unpack_from('<Q',blob,0x20)[0];offset=android&0xffffffff;length=android>>32
    if not a or not b or a%4096 or b%4096 or start+b>offset or not length or offset+length!=len(blob):
        raise ValueError('Invalid embedded disk or fallback-kernel boundaries')
    md0_supported=blob[MD0+32:MD0+36]==b'NXSB' or (a==16384 and not any(blob[MD0:MD0+a]))
    if not md0_supported or blob[start+32:start+36]!=b'NXSB':raise ValueError('Unsupported embedded bootstrap disks')
    return a,b,start,offset,length

def inventory(path):
    container=apfs.Container(str(path))
    try:
        volumes=container.volumes()
        if len(volumes)!=1 or volumes[0].volname!='redwood':raise ValueError('Expected one redwood bootstrap volume')
        volume=volumes[0];result={};total=0
        for name,_,oid,_ in apfs.walk(volume,2):
            rel=name.lstrip('/');parts=PurePosixPath(rel).parts
            if not parts or any(p in ('.','..') or any(c in p for c in '\t\n\r\0') for p in parts):raise ValueError('Unsafe bootstrap path')
            if any('/'.join(parts[:i]) not in result or result['/'.join(parts[:i])]['kind']!='directory' for i in range(1,len(parts))):raise ValueError('Invalid bootstrap parent')
            inode=volume.inode(oid)
            if inode.size>128<<20 or total+inode.size>128<<20:raise ValueError('Bootstrap files exceed supported size')
            if inode.bsd_flags&~0x20:raise ValueError('Unsupported bootstrap BSD flags')
            if 'com.apple.ResourceFork' in inode.xattrs and inode.decmpfs is None:raise ValueError('Non-compression resource forks require a port-specific adapter')
            if inode.is_dir:kind='directory';data=b''
            elif inode.is_link:kind='symlink';data=inode.contents()
            elif inode.is_reg and inode.nlink==1:kind='file';data=inode.contents()
            else:raise ValueError('Unsupported inode or hard link in bootstrap')
            if set(inode.xattrs)-{'com.apple.decmpfs','com.apple.ResourceFork','com.apple.fs.symlink'}:raise ValueError('Unsupported bootstrap extended attributes')
            total+=len(data)
            if total>128<<20:raise ValueError('Bootstrap files exceed supported size')
            result[rel]={'kind':kind,'data':data,'mode':inode.mode,'uid':inode.owner,'gid':inode.group}
        return result
    finally:container.image.close()

def updated_files(files,artifacts):
    files={k:dict(v) for k,v in files.items()}
    for required in ['bin','etc']:
        if files.get(required,{}).get('kind')!='directory':raise ValueError('Missing bootstrap directory')
    jobs=files.get('etc/rc.jobs')
    if not jobs or jobs['kind']!='file':raise ValueError('Missing bootstrap startup jobs')
    text=jobs['data'].decode('utf-8');lines=text.splitlines()
    # Only replace exact known startup lines. Do not rewrite compound shell commands.
    for line in lines:
        if 'usbmuxd_dev' in line or 'usbmux_watchdog' in line:
            if line.strip() not in ['/redwood/bin/usbmuxd_dev &','/redwood/bin/usbmux_watchdog &']:
                raise ValueError('Unrecognized USB startup command; manual port integration required')
    lines=[line for line in lines if line.strip() not in ['/redwood/bin/usbmuxd_dev &','/redwood/bin/usbmux_watchdog &']]
    jobs['data']=('\n'.join(lines)+'\n/redwood/bin/usbmux_watchdog &\n').encode()
    for name in ['usbmuxd_dev','usbmux_watchdog']:
        binary=Path(artifacts)/name
        if not binary.is_file() or not 0<binary.stat().st_size<4<<20:raise ValueError('Build the USB device helpers first')
        files['bin/'+name]={'kind':'file','data':binary.read_bytes(),'mode':0o100755,'uid':0,'gid':0}
    return files

def write_volume(files,directory):
    tree=directory/'root';tree.mkdir();manifest=[]
    for rel,item in files.items():
        p=tree/rel;p.parent.mkdir(parents=True,exist_ok=True)
        if item['kind']=='directory':p.mkdir(exist_ok=True)
        elif item['kind']=='symlink':p.symlink_to(os.fsdecode(item['data']))
        else:p.write_bytes(item['data'])
        manifest.append(f"{item['mode']:o}\t{item['uid']}\t{item['gid']}\t{rel}")
    metadata=directory/'manifest.tsv';metadata.write_text('\n'.join(manifest)+'\n')
    image=directory/'redwood.apfs'
    # The historical writer's CLI uses commas as separators; reject ambiguous workspace paths.
    if ',' in str(directory):raise ValueError('Temporary path cannot contain a comma')
    subprocess.run([sys.executable,str(ROOT/'hackicloud/vendor/apfs/mkapfs.py'),'-z','-o',str(image),'redwood='+str(tree)+',manifest='+str(metadata)],check=True,stdout=subprocess.DEVNULL)
    verified=inventory(image)
    if verified!=files:raise ValueError('Rebuilt bootstrap content/ownership verification failed')
    return image.read_bytes()

def patch(source,output,artifacts):
    source=Path(source).expanduser().resolve();output=Path(output).expanduser().absolute()
    if output.exists() or output.is_symlink():raise FileExistsError('Output already exists')
    header,blob=unpack(source);a,b,start,android,length=layout(blob)
    original=hashlib.sha256(source.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='hackicloud-boot-') as td:
        directory=Path(td);disk=directory/'input.apfs';disk.write_bytes(blob[start:start+b])
        before=inventory(disk);after=updated_files(before,artifacts);rebuilt=write_volume(after,directory)
    tail=b'';table_size=0
    magic,size,table_at=struct.unpack_from('<4sIQ',blob,0xffff0)
    if magic==b'VTBL':
        if not 4<=size<=4<<20 or table_at<start+b or table_at+size>android or blob[table_at:table_at+4]!=b'XTBL':raise ValueError('Invalid preserved extent table')
        tail=blob[table_at:table_at+size];table_size=size
    elif any(blob[0xffff0:0x100000]):raise ValueError('Unknown loader table record')
    # Unknown nonzero tail data must never be silently discarded.
    occupied=bytearray(blob[start+b:android])
    if tail:occupied[table_at-start-b:table_at-start-b+table_size]=bytes(table_size)
    if any(occupied):raise ValueError('Unknown data after bootstrap; unsupported port revision')
    newtable=start+align(len(rebuilt),16384);newandroid=align(newtable+len(tail),2<<20)
    if newandroid+length>MAX_BLOB:raise ValueError('Patched image exceeds loader memory layout')
    new=bytearray(blob[:start]);new.extend(rebuilt);new.extend(bytes(newandroid-len(new)));new.extend(blob[android:])
    if tail:new[newtable:newtable+len(tail)]=tail;struct.pack_into('<4sIQ',new,0xffff0,b'VTBL',len(tail),newtable)
    struct.pack_into('<Q',new,0x10,align(len(new),2<<20));struct.pack_into('<Q',new,0x20,(length<<32)|newandroid);struct.pack_into('<Q',new,0x30,len(rebuilt))
    if new[KERNEL:MD0]!=blob[KERNEL:MD0] or new[MD0:start]!=blob[MD0:start] or new[newandroid:]!=blob[android:]:raise ValueError('Kernel or preserved-disk invariant failed')
    compressed=subprocess.check_output([lz4_tool(),'-l','-c'],input=new,stderr=subprocess.DEVNULL)
    size=source.stat().st_size
    if len(compressed)+4096>size:raise ValueError('Patched image does not fit the original boot partition')
    head=bytearray(header);struct.pack_into('<I',head,8,len(compressed));packed=head+compressed+bytes(size-4096-len(compressed))
    # Decode the completed candidate before exposing it as an output image.
    with tempfile.TemporaryDirectory(prefix='hackicloud-verify-') as td:
        candidate=Path(td)/'candidate.img';candidate.write_bytes(packed);_,check=unpack(candidate)
        if check!=new:raise ValueError('Final boot-image verification failed')
    with output.open('xb') as f:f.write(packed)
    return {'profile':'duchamp-dual-apfs-v1','input_sha256':original,'output_sha256':hashlib.sha256(packed).hexdigest(),'kernel_unchanged':True,'android_unchanged':True,'md0_unchanged':True,'changed_paths':sorted(k for k in after if before.get(k)!=after[k]),'flashed':False}
