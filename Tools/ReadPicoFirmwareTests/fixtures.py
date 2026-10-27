from pathlib import Path
import hashlib, struct, zlib, json, sys
p=Path(sys.argv[1])
h=bytearray(24); h[0]=0xe9;h[1]=2;h[2]=2;h[3]=0x4f;struct.pack_into('<I',h,4,0x40380000);struct.pack_into('<H',h,12,9);struct.pack_into('<HH',h,15,0,65535);h[23]=1
payload=bytearray(256);struct.pack_into('<I',payload,0,0xabcd5432);payload[16:16+9]=b'0.0-test1';payload[48:57]=b'Read_Pico';payload[180]=16
part2=b'1234567890abcdef'
a=h+struct.pack('<II',0x3fc00000,len(payload))+payload
addr=0x3c000000+((0x20000+len(a)+8)&65535)
a+=struct.pack('<II',addr,len(part2))+part2
checksum=0xef
for b in payload+part2: checksum^=b
a+=bytes((len(a)|15)-len(a))+bytes([checksum]);a+=hashlib.sha256(a).digest()
(p/'app.bin').write_bytes(a)
manifest=dict(board='read-pico-esp32s3',chip='esp32s3',version='0.0-test1',app_address='0x20000',slot_bytes=0x400000,image_bytes=len(a),sha256=hashlib.sha256(a).hexdigest())
(p/'manifest.json').write_text(json.dumps(manifest))
parts=[('nvs',1,2,0x9000,0x6000),('otadata',1,0,0xf000,0x2000),('ota_0',0,16,0x20000,0x400000),('ota_1',0,17,0x420000,0x80000),('assets',1,130,0x4a0000,0x660000),('storage',1,130,0xb00000,0x500000)]
pt=b''.join(struct.pack('<HBBII16sI',0x50aa,t,s,o,n,name.encode(),0) for name,t,s,o,n in parts)
pt+=b'\xeb\xeb'+bytes([255])*14+hashlib.md5(pt).digest();pt+=bytes([255])*(4096-len(pt));(p/'pt.bin').write_bytes(pt)
for seq in [1,2,3]:
 ota=bytearray([255])*8192;struct.pack_into('<I',ota,0,seq);struct.pack_into('<I',ota,28,zlib.crc32(ota[:4],0xffffffff));(p/f'ota{seq}.bin').write_bytes(ota)
slot=bytearray(a+bytes([255])*(0x400000-len(a))); slot[-33:]=b'old APP tail is not always erased'; (p/'slot.bin').write_bytes(slot)
print('Fixtures ready',len(a))
# Dedicated first-install fixture; no device dump is accepted.
fresh=p/'fresh';fresh.mkdir()
(fresh/'read-pico-app.bin').write_bytes(a)
(fresh/'manifest.json').write_text(json.dumps(manifest))
(fresh/'partition-table.bin').write_bytes(pt)
(fresh/'ota-data.bin').write_bytes((p/'ota1.bin').read_bytes())
bh=bytearray(h);bh[1]=1
boot=bh+struct.pack('<II',0x3fc00000,16)+bytes(range(16))
bc=0xef
for value in range(16):bc^=value
boot+=bytes((len(boot)|15)-len(boot))+bytes([bc]);boot+=hashlib.sha256(boot).digest()
(fresh/'bootloader.bin').write_bytes(boot)
(fresh/'storage.bin').write_bytes(bytes([0xA5])*0x500000)
fm=dict(schema=1,kind='first-install',board='read-pico-esp32s3',chip='esp32s3',version=manifest['version'],flash_bytes=0x1000000,erase_flash=True,erased_partitions=['nvs','ota_1','assets'],files=[])
for role,name,offset in [('bootloader','bootloader.bin',0),('partitions','partition-table.bin',0x8000),('otadata','ota-data.bin',0xf000),('application','read-pico-app.bin',0x20000),('storage','storage.bin',0xb00000)]:
 data=(fresh/name).read_bytes();fm['files'].append(dict(role=role,file=name,address=offset,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
(fresh/'fresh-install.json').write_text(json.dumps(fm))
oldpt=bytearray(pt);struct.pack_into('<I',oldpt,8,0x5000);oldpt[208:224]=hashlib.md5(oldpt[:192]).digest();(p/'different-pt.bin').write_bytes(oldpt)
