#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../Tools/WaveshareC6Firmware/src/thumbnail_api.c"
static c6_thumbnail_cache_t cache;
static const char *header_serial="printer_A",*header_key="51f8e7ab9c2c491e",*header_revision="3",*header_width="80",*header_height="80";
static const char *header_entity,*header_role;
static const char *header_brand,*header_source;
static int media_stores;
static int revision=3,receive_fail,change_task,store_calls;
static const char *current_key="51f8e7ab9c2c491e";
static uint32_t free_heap=100000;
uint32_t esp_get_free_heap_size(void){return free_heap;}
bool standalone_authorized(httpd_req_t *req){if(req->auth&&!strcmp(req->auth,"Bearer test-secret"))return true;req->status=401;return false;}
esp_err_t httpd_req_get_hdr_value_str(httpd_req_t *req,const char *header,char *out,size_t size) {
    const char *value=!strcmp(header,"X-Printer-Serial")?header_serial:!strcmp(header,"X-Task-Key")?header_key:!strcmp(header,"X-Config-Revision")?header_revision:!strcmp(header,"X-Thumbnail-Width")?header_width:!strcmp(header,"X-Thumbnail-Height")?header_height:!strcmp(header,"X-Entity-ID")?header_entity:!strcmp(header,"X-Media-Role")?header_role:NULL;
    if(!strcmp(header,"X-Printer-Brand"))value=header_brand;
    if(!strcmp(header,"X-Printer-Source"))value=header_source;
    if(!value||strlen(value)>=size)return ESP_FAIL;strcpy(out,value);return ESP_OK;
}
size_t httpd_req_get_hdr_value_len(httpd_req_t *req,const char *header){const char *value=!strcmp(header,"X-Entity-ID")?header_entity:!strcmp(header,"X-Media-Role")?header_role:!strcmp(header,"X-Printer-Brand")?header_brand:!strcmp(header,"X-Printer-Source")?header_source:NULL;return value?strlen(value):0;}
esp_err_t httpd_resp_set_status(httpd_req_t *r,const char *s){r->status=atoi(s);return ESP_OK;}
esp_err_t httpd_resp_set_type(httpd_req_t *r,const char *s){return ESP_OK;}
esp_err_t httpd_resp_set_hdr(httpd_req_t *r,const char *k,const char *v){return ESP_OK;}
esp_err_t httpd_resp_sendstr(httpd_req_t *r,const char *s){snprintf(r->response,sizeof(r->response),"%s",s);return ESP_OK;}
int httpd_req_recv(httpd_req_t *r,char *out,size_t count) {
    if(receive_fail&&r->offset>100)return -1;
    if(change_task&&r->offset>100)current_key="720a0e7b1c1c2e99";
    size_t left=r->content_len-r->offset;if(count>left)count=left;if(count>113)count=113;
    memcpy(out,r->body+r->offset,count);r->offset+=count;return (int)count;
}
int c6_sources_thumbnail_validate(int rev,const char *serial,const char *key) {
    if(rev!=revision||strcmp(key,current_key))return 409;return !strcmp(serial,"printer_A")?200:404;
}
int c6_sources_thumbnail_store(int rev,const char *serial,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length) {
    store_calls++;int result=c6_sources_thumbnail_validate(rev,serial,key);
    if(result==200&&!c6_thumbnail_commit(&cache,serial,key,w,h,bytes,length))result=400;return result;
}
int c6_sources_media_validate(int rev,const char *serial,const char *entity,const char *key,bool cover){if(rev!=revision||strcmp(key,current_key))return 409;return cover?!strcmp(serial,"printer_A")?200:404:!strcmp(entity,"camera.fixture")?200:404;}
int c6_sources_media_store(int rev,const char *serial,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length){int status=c6_sources_media_validate(rev,serial,entity,key,cover);if(status==200){media_stores++;free(bytes);}return status;}
int c6_sources_thumbnail_validate_scoped(int rev,const char *serial,const char *brand,const char *source,const char *key){if(brand&&*brand&&strcmp(brand,"bambu"))return 404;if(source&&*source&&strcmp(source,"ha"))return 404;return c6_sources_thumbnail_validate(rev,serial,key);}
int c6_sources_thumbnail_store_scoped(int rev,const char *serial,const char *brand,const char *source,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length){int result=c6_sources_thumbnail_validate_scoped(rev,serial,brand,source,key);return result==200?c6_sources_thumbnail_store(rev,serial,key,w,h,bytes,length):result;}
int c6_sources_media_validate_scoped(int rev,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover){return c6_sources_media_validate(rev,serial,entity,key,cover);}
int c6_sources_media_store_scoped(int rev,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length){return c6_sources_media_store(rev,serial,entity,key,cover,w,h,bytes,length);}
static httpd_req_t upload(const uint8_t *bytes,int length,const char *auth) {
    httpd_req_t r={.method=HTTP_POST,.body=(const char*)bytes,.content_len=length,.auth=auth};c6_thumbnail_handler(&r);return r;
}
int main(void) {
    uint8_t *image=calloc(1,C6_THUMBNAIL_BYTES);memset(image,0xa5,C6_THUMBNAIL_BYTES);
    assert(upload(image,C6_THUMBNAIL_BYTES,NULL).status==401&&store_calls==0);
    assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==200&&store_calls==1);
    assert(c6_thumbnail_matches(&cache,"printer_A",current_key));assert(!c6_thumbnail_matches(&cache,"printer_B",current_key));
    assert(!c6_thumbnail_matches(&cache,"printer_A","720a0e7b1c1c2e99"));
    uint8_t *prior=cache.bytes;
    receive_fail=1;assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);receive_fail=0;
    assert(cache.bytes==prior&&cache.bytes[0]==0xa5);
    change_task=1;assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==409);change_task=0;
    assert(cache.bytes==prior);current_key=header_key;
    header_revision="2";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==409);header_revision="3";
    header_serial="printer_B";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==404);header_serial="printer_A";
    header_serial="printer_A\r\nX:secret";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);header_serial="printer_A";
    header_key="123456789abcdefG";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);header_key=current_key;
    header_width="81";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);header_width="80";
    header_height="0";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);header_height="80";
    header_revision="-1";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);header_revision="3";
    assert(upload(image,C6_THUMBNAIL_BYTES-1,"Bearer test-secret").status==400);
    free_heap=40000;assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==503);free_heap=100000;
    assert(cache.bytes==prior);
    header_brand="bambu";header_source="ha";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==200);
    prior=cache.bytes;header_source="formlabs";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);
    header_brand="formlabs";assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==404);
    header_brand="bambu";header_source=NULL;assert(upload(image,C6_THUMBNAIL_BYTES,"Bearer test-secret").status==400);
    header_brand=header_source=NULL;
    header_entity="camera.fixture";header_serial=NULL;header_width="80";header_height="40";
    assert(upload(image,80*40*2,"Bearer test-secret").status==200&&media_stores==1);
    header_entity="camera.other";assert(upload(image,80*40*2,"Bearer test-secret").status==404);header_entity="camera.fixture";
    change_task=1;assert(upload(image,80*40*2,"Bearer test-secret").status==409&&media_stores==1);change_task=0;current_key=header_key;
    char oversized[160];memset(oversized,'x',sizeof(oversized)-1);oversized[159]=0;header_entity=oversized;
    assert(upload(image,80*40*2,"Bearer test-secret").status==400);header_entity=NULL;header_serial="printer_A";
    header_role="cover";assert(upload(image,80*40*2,"Bearer test-secret").status==200&&media_stores==2);
    header_entity="camera.fixture";assert(upload(image,80*40*2,"Bearer test-secret").status==400);header_entity=NULL;
    header_role="invalid";assert(upload(image,80*40*2,"Bearer test-secret").status==400);
    header_role=oversized;assert(upload(image,80*40*2,"Bearer test-secret").status==400);
    header_role=NULL;header_height="80";
    assert(!c6_thumbnail_commit(&cache,"printer_A",current_key,81,80,image,C6_THUMBNAIL_BYTES));assert(cache.bytes==prior);
    char url[512];
    assert(c6_thumbnail_url("192.168.1.10",8123,false,"/api/image_proxy/image.task?token=opaque",url,sizeof(url)));
    assert(!strcmp(url,"http://192.168.1.10:8123/api/image_proxy/image.task?token=opaque"));
    assert(c6_thumbnail_url("192.168.1.10",8123,true,"https://192.168.1.10:8123/image.jpg",url,sizeof(url)));
    const char *bad[]={"https://example.com/image.jpg","http://192.168.1.10:8123/image.jpg","https://192.168.1.10:8123.evil/image.jpg","//example.com/cover.jpg","/api/camera_proxy/camera.printer","/path\\x","/path\nX:token","/path#token"};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++)assert(!c6_thumbnail_url("192.168.1.10",8123,true,bad[i],url,sizeof(url)));
    assert(c6_camera_snapshot_url("192.168.1.10",8123,true,"camera.x2d_camera",url,sizeof(url)));
    assert(!strcmp(url,"https://192.168.1.10:8123/api/camera_proxy/camera.x2d_camera"));
    const char *bad_camera[]={"camera.","image.cover","camera.x/stream","camera.x?token=secret","camera.x#secret","camera.x\r\nAuthorization:X","camera.X"};
    for(unsigned i=0;i<sizeof(bad_camera)/sizeof(bad_camera[0]);i++)assert(!c6_camera_snapshot_url("192.168.1.10",8123,false,bad_camera[i],url,sizeof(url)));
    assert(!c6_camera_snapshot_url("192.168.1.10.evil",8123,false,"camera.x",url,sizeof(url)));
    assert(!c6_camera_snapshot_url("192.168.1.10",8123,false,"camera.x",url,10));
    assert(c6_thumbnail_due(true,true,115,115));assert(!c6_thumbnail_due(true,true,114,115));
    assert(!c6_thumbnail_due(false,true,999,0));assert(c6_thumbnail_due(false,false,300,300));
    uint8_t *rgb=malloc(160*80*3),output[C6_THUMBNAIL_BYTES]={0};
    for(unsigned i=0;i<160*80;i++){rgb[i*3]=255;rgb[i*3+1]=0;rgb[i*3+2]=0;}
    assert(c6_thumbnail_rgb_block(output,160,80,0,0,159,79,rgb));
    for(unsigned y=0;y<80;y++)for(unsigned x=0;x<80;x++){unsigned offset=(y*80+x)*2;assert(output[offset]==(y>=20&&y<60?0xf8:0)&&output[offset+1]==0);}
    assert(!c6_thumbnail_rgb_block(output,0,80,0,0,159,79,rgb));assert(!c6_thumbnail_rgb_block(output,160,80,0,0,160,79,rgb));
    c6_thumbnail_clear(&cache);assert(!cache.bytes&&!c6_thumbnail_matches(&cache,"printer_A",current_key));
    free(rgb);free(image);
    puts("C6 task thumbnail: authentication, serial/task/revision isolation, fragmented/incomplete uploads, task-switch race, low-heap backoff, RGB565 aspect-fit and same-origin URL checks passed");
}
