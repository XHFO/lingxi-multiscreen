#include "thumbnail_cache.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
bool c6_thumbnail_valid_key(const char *key) {
    if(!key||strlen(key)!=16)return false;
    for(unsigned i=0;i<16;i++)if(!((key[i]>='0'&&key[i]<='9')||(key[i]>='a'&&key[i]<='f')))return false;
    return true;
}
bool c6_thumbnail_matches(const c6_thumbnail_cache_t *c,const char *serial,const char *key) {
    return c&&c->bytes&&serial&&key&&c6_thumbnail_valid_key(key)&&!strcmp(c->serial,serial)&&!strcmp(c->task_key,key);
}
bool c6_thumbnail_commit(c6_thumbnail_cache_t *c,const char *serial,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length) {
    if(!c||!serial||!*serial||strlen(serial)>=sizeof(c->serial)||!c6_thumbnail_valid_key(key)||!bytes||!w||!h||w>C6_THUMBNAIL_EDGE||h>C6_THUMBNAIL_EDGE||length!=(size_t)w*h*2)return false;
    free(c->bytes);c->bytes=bytes;c->width=w;c->height=h;
    snprintf(c->serial,sizeof(c->serial),"%s",serial);snprintf(c->task_key,sizeof(c->task_key),"%s",key);return true;
}
void c6_thumbnail_clear(c6_thumbnail_cache_t *c){if(c){free(c->bytes);memset(c,0,sizeof(*c));}}
bool c6_thumbnail_url(const char *host,int port,bool tls,const char *picture,char *out,size_t capacity) {
    if(!host||!picture||!out||!capacity||port<1||port>65535)return false;
    char origin[80],origin_default[80];int n=snprintf(origin,sizeof(origin),"%s://%s:%d",tls?"https":"http",host,port);
    if(n<=0||n>=(int)sizeof(origin))return false;
    snprintf(origin_default,sizeof(origin_default),"%s://%s",tls?"https":"http",host);
    const char *path=NULL;
    if(picture[0]=='/'&&picture[1]!='/')path=picture;
    else if(!strncmp(picture,origin,strlen(origin))&&picture[strlen(origin)]=='/')path=picture+strlen(origin);
    else if(port==(tls?443:80)&&!strncmp(picture,origin_default,strlen(origin_default))&&picture[strlen(origin_default)]=='/')path=picture+strlen(origin_default);
    if(!path||strstr(path,"/camera_proxy")||strstr(path,"/camera_proxy_stream")||strstr(path,"\\")||strchr(path,'#'))return false;
    for(const unsigned char *p=(const unsigned char*)path;*p;p++)if(*p<33||*p==127)return false;
    n=snprintf(out,capacity,"%s%s",origin,path);return n>0&&(size_t)n<capacity;
}
bool c6_camera_snapshot_url(const char *host,int port,bool tls,const char *entity,char *out,size_t capacity) {
    if(!entity||strncmp(entity,"camera.",7)||!entity[7]||strlen(entity)>=128||!host||!out||!capacity||port<1||port>65535)return false;
    for(const unsigned char *p=(const unsigned char*)entity+7;*p;p++)if(!((*p>='a'&&*p<='z')||(*p>='0'&&*p<='9')||*p=='_'))return false;
    // Configuration normally enforces IPv4; retain that guarantee at the URL boundary.
    unsigned parts=0,value=0,digits=0;
    for(const unsigned char *p=(const unsigned char*)host;;p++) {
        if(*p>='0'&&*p<='9'){value=value*10+*p-'0';if(++digits>3||value>255)return false;}
        else if(*p=='.'||!*p){if(!digits)return false;parts++;if(!*p)break;value=digits=0;}
        else return false;
    }
    if(parts!=4)return false;
    int n=snprintf(out,capacity,"%s://%s:%d/api/camera_proxy/%s",tls?"https":"http",host,port,entity);
    return n>0&&(size_t)n<capacity;
}
bool c6_thumbnail_due(bool camera,bool cached,uint64_t now,uint64_t next){return now>=next&&(camera||!cached);}
bool c6_thumbnail_rgb_block(uint8_t *out,unsigned sw,unsigned sh,unsigned left,unsigned top,unsigned right,unsigned bottom,const uint8_t *rgb) {
    if(!out||!rgb||!sw||!sh||sw>1024||sh>1024||left>right||top>bottom||right>=sw||bottom>=sh)return false;
    unsigned w,h;if(sw>=sh){w=C6_THUMBNAIL_EDGE;h=sh*C6_THUMBNAIL_EDGE/sw;}else{h=C6_THUMBNAIL_EDGE;w=sw*C6_THUMBNAIL_EDGE/sh;}
    if(!w)w=1;
    if(!h)h=1;
    unsigned dx=(C6_THUMBNAIL_EDGE-w)/2,dy=(C6_THUMBNAIL_EDGE-h)/2,block_width=right-left+1;
    for(unsigned y=0;y<h;y++) {
        unsigned sy=y*sh/h;if(sy<top||sy>bottom)continue;
        for(unsigned x=0;x<w;x++) {
            unsigned sx=x*sw/w;if(sx<left||sx>right)continue;
            const uint8_t *pixel=rgb+((sy-top)*block_width+sx-left)*3;
            uint16_t color=((uint16_t)(pixel[0]&0xf8)<<8)|((uint16_t)(pixel[1]&0xfc)<<3)|(pixel[2]>>3);
            unsigned offset=((y+dy)*C6_THUMBNAIL_EDGE+x+dx)*2;out[offset]=color>>8;out[offset+1]=color&255;
        }
    }
    return true;
}
