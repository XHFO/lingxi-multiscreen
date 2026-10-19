// Actual streaming PNG decoder; native miniz is used only as the C6 ROM counterpart.
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {deflateSync} from 'node:zlib';
import {spawnSync} from 'node:child_process';
import {strict as assert} from 'node:assert';
const root=new URL('../../',import.meta.url).pathname;
const miniz=join(process.env.HOME,'.platformio/packages/tool-esptoolpy@1.30000.201119/flasher_stub');
const directory=mkdtempSync(join(tmpdir(),'lingxi-c6-png-'));
function crc(b){let n=0xffffffff;for(const v of b){n^=v;for(let k=0;k<8;k++)n=(n>>>1)^((n&1)?0xedb88320:0);}return (n^0xffffffff)>>>0;}
function chunk(type,data){const t=Buffer.from(type),head=Buffer.alloc(4),tail=Buffer.alloc(4);head.writeUInt32BE(data.length);tail.writeUInt32BE(crc(Buffer.concat([t,data])));return Buffer.concat([head,t,data,tail]);}
function paeth(a,b,c){const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);return pa<=pb&&pa<=pc?a:pb<=pc?b:c;}
function png(w,h,filter=0,color=6,interlace=0){
  const channels=color===3?1:4,raw=Buffer.alloc((w*channels+1)*h);let previous=Buffer.alloc(w*channels);
  for(let y=0;y<h;y++){
    const row=Buffer.alloc(w*channels);for(let x=0;x<w;x++)if(color===3)row[x]=x%2;else{row[x*4]=Math.floor(x*255/(w-1));row[x*4+1]=Math.floor(y*255/(h-1));row[x*4+2]=128;row[x*4+3]=x<w/2?255:128;}
    const offset=y*(w*channels+1);raw[offset]=filter;
    for(let x=0;x<row.length;x++){const a=x>=channels?row[x-channels]:0,b=previous[x],c=x>=channels?previous[x-channels]:0;const delta=filter===0?0:filter===1?a:filter===2?b:filter===3?Math.floor((a+b)/2):paeth(a,b,c);raw[offset+1+x]=(row[x]-delta)&255;}previous=row;
  }
  const header=Buffer.alloc(13);header.writeUInt32BE(w);header.writeUInt32BE(h,4);header[8]=8;header[9]=color;header[12]=interlace;
  const compressed=deflateSync(raw),pieces=[Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header)];
  if(color===3)pieces.push(chunk('PLTE',Buffer.from([255,0,0,0,255,0])),chunk('tRNS',Buffer.from([255,128])));
  // Multiple IDATs, including decoder dictionary wrap for >32KB raw data.
  for(let i=0;i<compressed.length;i+=37)pieces.push(chunk('IDAT',compressed.subarray(i,i+37)));
  pieces.push(chunk('IEND',Buffer.alloc(0)));return Buffer.concat(pieces);
}
const fixtures=[];function save(name,b){const file=join(directory,name+'.png');writeFileSync(file,b);fixtures.push(file);}
for(let f=0;f<5;f++)save('rgba-'+f,png(160,80,f));save('palette',png(80,80,4,3));save('large',png(512,256,4));
let corrupt=png(160,80);corrupt[29]^=1;save('bad-crc',corrupt);save('bad-interlace',png(80,80,0,6,1));save('bad-size',png(1025,1));save('bad-truncated',png(160,80).subarray(0,60));
const program=`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "png_thumbnail.h"
typedef struct {FILE *file;} input_t;
static size_t read_png(void *context,unsigned char *out,size_t count){if(count>7)count=7;return fread(out,1,count,((input_t*)context)->file);}
int main(int argc,char **argv){
 for(int n=1;n<argc;n++){
  input_t input={fopen(argv[n],"rb")};assert(input.file);unsigned char guarded[80*80*2+32];memset(guarded,0x5a,sizeof(guarded));unsigned w=0,h=0;
  bool ok=c6_png_thumbnail(read_png,&input,guarded+16,&w,&h);fclose(input.file);
  for(int i=0;i<16;i++){assert(guarded[i]==0x5a);assert(guarded[80*80*2+16+i]==0x5a);}
  bool bad=strstr(argv[n],"/bad-")!=NULL;assert(ok==!bad);if(!ok)continue;
  bool palette=strstr(argv[n],"/palette")!=NULL,large=strstr(argv[n],"/large")!=NULL;
  unsigned sw=large?512:palette?80:160,sh=large?256:80;assert(w==80&&h==(palette?80:40));
  for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){
   unsigned sx=x*sw/w,sy=y*sh/h,a=sx<sw/2?255:128;
   unsigned r=palette?(sx%2?0:255):(sx*255/(sw-1))*a/255;
   unsigned g=palette?(sx%2?128:0):(sy*255/(sh-1))*a/255;
   unsigned b=palette?0:128*a/255;unsigned expected=((r&248)<<8)|((g&252)<<3)|(b>>3),offset=(y*w+x)*2+16;
   assert((((unsigned)guarded[offset]<<8)|guarded[offset+1])==expected);
  }
 }
 puts("Actual PNG stream: all five filters, fragmented multiple IDAT, 32KB dictionary wrap, RGBA/palette alpha, source aspect ratio, CRC/truncation/interlace/size rejection and output guards passed");
}
`;
try{
  const binary=join(directory,'contract');
  const build=spawnSync('clang',['-std=c11','-I',join(miniz,'include'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',join(root,'Tools/WaveshareC6Firmware/src/png_thumbnail.c'),join(miniz,'miniz.c'),'-o',binary],{input:program,encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  const test=spawnSync(binary,fixtures,{encoding:'utf8'});assert.equal(test.status,0,test.stderr);console.log(test.stdout.trim());
}finally{rmSync(directory,{recursive:true,force:true});}
