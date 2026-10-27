from pathlib import Path
import sys,zipfile,struct,zlib
root=Path(sys.argv[1]);root.mkdir(exist_ok=True)
def png():
 def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+bytes([235,40,25])*2+b'\0'+bytes([235,40,25])*2))+chunk(b'IEND',b'')
entries={'META-INF/container.xml':'<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>','OPS/content.opf':'<package xmlns:dc="dc"><metadata><dc:title>真实封面书</dc:title><dc:creator>作者甲</dc:creator></metadata><manifest><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch1"/></spine></package>','OPS/ch1.xhtml':'<html><body><h1>第一章</h1><p>真正的章节内容，与封面对应。</p></body></html>','OPS/cover.png':png()}
def make(name,entries):
 with zipfile.ZipFile(root/name,'w',zipfile.ZIP_DEFLATED) as z:
  for k,v in entries.items():z.writestr(k,v)
make('sample.epub',entries)
make('traversal.epub',{**entries,'../../escape':'bad'})
d=bytearray((root/'sample.epub').read_bytes());i=d.find(b'PK\x01\x02');d[i+16]^=1;(root/'crc.epub').write_bytes(d)
with zipfile.ZipFile(root/'duplicate.epub','w') as z:
 for k,v in entries.items():z.writestr(k,v)
 z.writestr('OPS/content.opf','bad')
make('bomb.epub',{**entries,'OPS/content.opf':b'0'*(1024*1024+1)})

make('entity.epub',{**entries,'OPS/content.opf':'<!DOCTYPE package [<!ENTITY x "bad">]><package><title>&x;</title></package>'})
