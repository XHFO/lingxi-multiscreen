#include "local_sources.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include "esp_system.h"
static bool thumbnail_number(httpd_req_t *req,const char *header,unsigned maximum,unsigned *out) {
    char text[16];if(httpd_req_get_hdr_value_str(req,header,text,sizeof(text))!=ESP_OK||!*text)return false;
    for(const unsigned char *p=(const unsigned char*)text;*p;p++)if(*p<'0'||*p>'9')return false;
    char *end;unsigned long value=strtoul(text,&end,10);if(*end||value>maximum)return false;
    *out=(unsigned)value;return true;
}
static esp_err_t thumbnail_reply(httpd_req_t *req,int code) {
    const char *status=code==200?"200 OK":code==400?"400 Bad Request":code==403?"403 Forbidden":code==404?"404 Not Found":code==409?"409 Conflict":code==503?"503 Service Unavailable":"500 Internal Server Error";
    httpd_resp_set_status(req,status);httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_sendstr(req,code==200?"{\"cached\":true}":"{\"cached\":false}");
}
esp_err_t c6_thumbnail_handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    char serial[40]={0},key[17],entity[128]={0},role[16]={0},brand[16]={0},source[16]={0};unsigned revision,w,h;
    size_t brand_length=httpd_req_get_hdr_value_len(req,"X-Printer-Brand"),source_length=httpd_req_get_hdr_value_len(req,"X-Printer-Source");
    if(brand_length>=sizeof(brand)||source_length>=sizeof(source))return thumbnail_reply(req,400);
    if((brand_length&&httpd_req_get_hdr_value_str(req,"X-Printer-Brand",brand,sizeof(brand))!=ESP_OK)
       ||(source_length&&httpd_req_get_hdr_value_str(req,"X-Printer-Source",source,sizeof(source))!=ESP_OK))return thumbnail_reply(req,400);
    if((brand_length||source_length)&&!((!strcmp(brand,"formlabs")&&!strcmp(source,"formlabs"))
       ||(!strcmp(brand,"bambu")&&(!strcmp(source,"ha")||!strcmp(source,"mqtt")))))return thumbnail_reply(req,400);
    size_t entity_length=httpd_req_get_hdr_value_len(req,"X-Entity-ID"),role_length=httpd_req_get_hdr_value_len(req,"X-Media-Role");
    if(entity_length>=sizeof(entity)||role_length>=sizeof(role))return thumbnail_reply(req,400);
    bool has_entity=entity_length>0,has_role=role_length>0;
    if((has_entity&&httpd_req_get_hdr_value_str(req,"X-Entity-ID",entity,sizeof(entity))!=ESP_OK)
       ||(has_role&&httpd_req_get_hdr_value_str(req,"X-Media-Role",role,sizeof(role))!=ESP_OK))return thumbnail_reply(req,400);
    bool cover=has_role&&!strcmp(role,"cover");if(has_role&&!cover)return thumbnail_reply(req,400);
    if((!has_entity&&(httpd_req_get_hdr_value_str(req,"X-Printer-Serial",serial,sizeof(serial))!=ESP_OK||!*serial))||(has_entity&&cover)
       ||httpd_req_get_hdr_value_str(req,"X-Task-Key",key,sizeof(key))!=ESP_OK||!c6_thumbnail_valid_key(key)
       ||!thumbnail_number(req,"X-Config-Revision",INT_MAX-1,&revision)
       ||!thumbnail_number(req,"X-Thumbnail-Width",C6_THUMBNAIL_EDGE,&w)||!w
       ||!thumbnail_number(req,"X-Thumbnail-Height",C6_THUMBNAIL_EDGE,&h)||!h
       ||req->content_len!=(int)(w*h*2))return thumbnail_reply(req,400);
    for(const unsigned char *p=(const unsigned char*)serial;*p;p++)if(!((*p>='0'&&*p<='9')||(*p>='A'&&*p<='Z')||(*p>='a'&&*p<='z')||*p=='_'||*p=='-'))return thumbnail_reply(req,400);
    bool media=has_entity||cover;
    int status=media?c6_sources_media_validate_scoped((int)revision,serial,brand,source,entity,key,cover):c6_sources_thumbnail_validate_scoped((int)revision,serial,brand,source,key);if(status!=200)return thumbnail_reply(req,status);
    size_t length=w*h*2;if(esp_get_free_heap_size()<length+32768)return thumbnail_reply(req,503);
    uint8_t *staging=malloc(length);if(!staging)return thumbnail_reply(req,500);
    size_t received=0;
    while(received<length) {
        int n=httpd_req_recv(req,(char*)staging+received,length-received);
        if(n<=0){free(staging);return thumbnail_reply(req,400);}received+=n;
    }
    // HA/MQTT callbacks can change task identity while a slow upload is received.
    status=media?c6_sources_media_store_scoped((int)revision,serial,brand,source,entity,key,cover,w,h,staging,length):c6_sources_thumbnail_store_scoped((int)revision,serial,brand,source,key,w,h,staging,length);
    if(status!=200)free(staging);
    return thumbnail_reply(req,status);
}
