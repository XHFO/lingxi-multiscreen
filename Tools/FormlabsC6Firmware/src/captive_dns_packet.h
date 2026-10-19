#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
// One bounded, uncompressed IN question. No forwarding, upstream DNS or
// retained records. AAAA gets NODATA; A points only at the setup interface.
static inline size_t c6_captive_answer(uint8_t *b,size_t n,size_t capacity,const uint8_t address[4]){
    if(n<17||n>capacity||(b[2]&0xf8)||b[4]||b[5]!=1)return 0;
    size_t p=12,total=0;
    while(p<n&&b[p]){unsigned len=b[p++];if(len>63||p+len>=n||total+len+1>255)return 0;p+=len;total+=len+1;}
    if(p>=n||p+5>n)return 0;
    p++;unsigned type=(unsigned)b[p]*256+b[p+1],klass=(unsigned)b[p+2]*256+b[p+3];p+=4;
    if(klass!=1)return 0;
    b[2]=(uint8_t)(0x80|(b[2]&1));b[3]=0x80;b[6]=b[7]=b[8]=b[9]=b[10]=b[11]=0;
    if(type!=1)return p;
    if(p+16>capacity)return 0;
    b[7]=1;const uint8_t answer[]={0xc0,0x0c,0,1,0,1,0,0,0,0,0,4};
    memcpy(b+p,answer,sizeof(answer));memcpy(b+p+12,address,4);return p+16;
}
