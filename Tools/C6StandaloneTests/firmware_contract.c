#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define C6_JSON_REFERENCE_TEST 1
#include "../../Tools/WaveshareC6Firmware/src/standalone.c"
static int fail_storage,applied;
static bool test_lan_allowed;
bool standalone_lan_pairing_allowed(httpd_req_t *req){return test_lan_allowed;}
static int64_t test_now;
static int64_t recv_advance;
static uint32_t test_random=0x1234abcd;
static char stored_token[17],stored_config[C6_CONFIG_BYTES];
static char stored_blob[C6_CONFIG_BYTES];
esp_err_t nvs_get_blob(nvs_handle_t h,const char *k,void *v,size_t *size){
    if(!*stored_blob)return ESP_ERR_NVS_NOT_FOUND;
    size_t n=strlen(stored_blob)+1;if(n>*size)return ESP_ERR_NVS_INVALID_LENGTH;
    memcpy(v,stored_blob,n);*size=n;return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t h,const char *k,const void *v,size_t size){
    if(fail_storage)return ESP_ERR_NVS_NOT_ENOUGH_SPACE;
    assert(!strcmp(k,"config_blob")&&size<=sizeof(stored_blob));memcpy(stored_blob,v,size);return ESP_OK;
}
esp_err_t nvs_erase_key(nvs_handle_t h,const char *k){assert(!strcmp(k,"config"));stored_config[0]=0;return ESP_OK;}
esp_err_t nvs_open(const char *s,int mode,nvs_handle_t *h){*h=1;return ESP_OK;}
esp_err_t nvs_get_str(nvs_handle_t h,const char *k,char *v,size_t *size){
    const char *saved=!strcmp(k,"token")?stored_token:stored_config;
    if(!*saved||strlen(saved)+1>*size)return ESP_FAIL;
    strcpy(v,saved);*size=strlen(saved)+1;return ESP_OK;
}
esp_err_t nvs_set_str(nvs_handle_t h,const char *k,const char *v){
    if(fail_storage)return ESP_FAIL;
    if(strlen(v)+1>4000)return ESP_ERR_NVS_VALUE_TOO_LONG;
    if(!strcmp(k,"token"))snprintf(stored_token,sizeof(stored_token),"%s",v);
    else snprintf(stored_config,sizeof(stored_config),"%s",v);
    return ESP_OK;
}
esp_err_t nvs_commit(nvs_handle_t h){return ESP_OK;}
void nvs_close(nvs_handle_t h){}
uint32_t esp_random(void){return test_random;}
int64_t esp_timer_get_time(void){return test_now;}
void standalone_apply(void){applied++;}
static const char *test_header(httpd_req_t *r,const char *k){
    return !strcmp(k,"Authorization")?r->auth:!strcmp(k,"X-Lingxi-Card")?r->card:
        !strcmp(k,"X-Lingxi-Native")?r->native:!strcmp(k,"X-Lingxi-Origin")?r->origin:
        !strcmp(k,"X-Lingxi-Group")?r->group:!strcmp(k,"X-Lingxi-Serial")?r->serial:
        !strcmp(k,"X-Lingxi-Brand")?r->brand:!strcmp(k,"X-Lingxi-Source")?r->source:NULL;
}
esp_err_t httpd_req_get_hdr_value_str(httpd_req_t *r,const char *k,char *v,size_t n){const char *value=test_header(r,k);if(!value||strlen(value)>=n)return ESP_FAIL;strcpy(v,value);return ESP_OK;}
size_t httpd_req_get_hdr_value_len(httpd_req_t *r,const char *k){const char *value=test_header(r,k);return value?strlen(value):0;}
esp_err_t httpd_resp_set_status(httpd_req_t *r,const char *s){r->status=atoi(s);return ESP_OK;}
esp_err_t httpd_resp_sendstr(httpd_req_t *r,const char *s){
    if(!r->status)r->status=200;
    snprintf(r->response,sizeof(r->response),"%s",s);return ESP_OK;
}
esp_err_t httpd_resp_send_err(httpd_req_t *r,int status,const char *s){r->status=status;return httpd_resp_sendstr(r,s);}
int httpd_req_recv(httpd_req_t *r,char *out,size_t n){
    test_now+=recv_advance;
    size_t left=r->content_len-r->offset;if(n>left)n=left;
    if(n>17)n=17; // Exercise fragmented request bodies.
    memcpy(out,r->body+r->offset,n);r->offset+=n;return n;
}
esp_err_t httpd_resp_set_type(httpd_req_t *r,const char *s){return ESP_OK;}
esp_err_t httpd_resp_set_hdr(httpd_req_t *r,const char *k,const char *v){return ESP_OK;}
esp_err_t httpd_register_uri_handler(httpd_handle_t s,const httpd_uri_t *r){return ESP_OK;}
static httpd_req_t write_config(int revision,int rotation) {
    static char body[512];
    snprintf(body,sizeof(body),"{\"schema_version\":1,\"revision\":%d,\"enabled\":true,\"rotation\":%d,\"brightness\":80,\"interval\":15,\"timezone\":28800,\"clock\":true,\"diagnostics\":true}",revision,rotation);
    httpd_req_t req={.method=HTTP_PUT,.body=body,.content_len=strlen(body),.auth="Bearer 1234abcd1234abcd"};
    handler(&req);return req;
}
static httpd_req_t pair_with(const char *body) {
    httpd_req_t req={.method=HTTP_POST,.body=body,.content_len=(int)strlen(body)};
    pairing_handler(&req);return req;
}
int main(void) {
    standalone_init();
    assert(!strcmp(standalone_restore_status,"defaults"));
    assert(standalone_config.clock_style==0);
    cJSON *clock_json=document(&standalone_config,false);standalone_config_t clock_parsed;
    cJSON_ReplaceItemInObject(clock_json,"clock_style",cJSON_CreateNumber(1));
    assert(parse(clock_json,&clock_parsed,NULL)&&clock_parsed.clock_style==1);
    for(int style=-1;style<=2;style+=3){cJSON_ReplaceItemInObject(clock_json,"clock_style",cJSON_CreateNumber(style));assert(!parse(clock_json,&clock_parsed,NULL));}
    cJSON_DeleteItemFromObject(clock_json,"clock_style");
    assert(parse(clock_json,&clock_parsed,NULL)&&clock_parsed.clock_style==0);
    standalone_config_t old_clock=standalone_config;old_clock.clock_style=1;
    assert(parse(clock_json,&clock_parsed,&old_clock)&&clock_parsed.clock_style==1);
    cJSON_Delete(clock_json);
    char pin[5];int remaining;
    assert(!standalone_pairing_pin(pin,NULL));
    standalone_pairing_open();standalone_pairing_close();assert(!standalone_pairing_pin(pin,NULL));
    assert(pair_with("{\"pin\":\"0007\"}").status==403);
    assert(standalone_pairing_brightness(0,true)==30);
    assert(standalone_pairing_brightness(0,false)==0);
    assert(standalone_pairing_brightness(12,true)==30);
    assert(standalone_pairing_brightness(12,false)==12);
    assert(standalone_pairing_brightness(80,true)==80);
    httpd_req_t closed=pair_with("{\"pin\":\"0007\"}");assert(closed.status==403);assert(!strstr(closed.response,"1234abcd"));
    test_random=7;standalone_pairing_open();
    assert(standalone_pairing_pin(pin,&remaining));assert(!strcmp(pin,"0007"));assert(remaining==120);
    const char *invalid_pins[]={"{}","{\"pin\":7}","{\"pin\":\"007\"}","{\"pin\":\"00007\"}","{\"pin\":\"00a7\"}","{\"pin\":\"０００７\"}","{\"pin\":\"0007\"}junk"};
    for(unsigned i=0;i<sizeof(invalid_pins)/sizeof(invalid_pins[0]);i++)assert(pair_with(invalid_pins[i]).status==400);
    assert(pairing_attempts==0);
    for(unsigned i=0;i<4;i++){httpd_req_t wrong=pair_with("{\"pin\":\"0008\"}");assert(wrong.status==401);assert(!strstr(wrong.response,"1234abcd"));}
    httpd_req_t locked=pair_with("{\"pin\":\"0008\"}");assert(locked.status==429);assert(!standalone_pairing_pin(pin,NULL));
    assert(pair_with("{\"pin\":\"0007\"}").status==429);
    standalone_pairing_open();test_now=120000000;
    assert(!standalone_pairing_pin(pin,NULL));assert(pair_with("{\"pin\":\"0007\"}").status==410);
    standalone_pairing_open();test_now+=119000000;recv_advance=1000000;
    assert(pair_with("{\"pin\":\"0007\"}").status==410);recv_advance=0;
    standalone_pairing_open();test_now+=119999999;
    assert(standalone_pairing_pin(pin,&remaining));assert(remaining==1);
    httpd_req_t paired=pair_with("{\"pin\":\"0007\"}");assert(paired.status==200);assert(strstr(paired.response,"\"token\":\"1234abcd1234abcd\""));
    assert(!standalone_pairing_pin(pin,NULL));assert(pair_with("{\"pin\":\"0007\"}").status==403);
    httpd_req_t pin_auth={.method=HTTP_GET,.auth="Bearer 0007"};handler(&pin_auth);assert(pin_auth.status==401);
    httpd_req_t unauth={.method=HTTP_GET};handler(&unauth);assert(unauth.status==401);
    httpd_req_t read={.method=HTTP_GET,.auth="Bearer 1234abcd1234abcd"};handler(&read);
    assert(read.status==200);assert(!strstr(read.response,"1234abcd"));
    httpd_req_t first=write_config(0,180);assert(first.status==200);assert(standalone_config.revision==1);assert(applied==1);
    assert(standalone_config.flip_animation&&standalone_config.saturation_percent==100&&standalone_config.contrast_percent==100);
    httpd_req_t stale=write_config(0,180);assert(stale.status==409);assert(standalone_config.revision==1);
    assert(standalone_set_flip(false)&&!standalone_config.flip_animation&&standalone_config.revision==2);
    fail_storage=1;assert(!standalone_set_flip(true)&&!standalone_config.flip_animation&&standalone_config.revision==2);fail_storage=0;
    assert(standalone_set_flip(true));standalone_config.revision=1; // Continue legacy save-contract scenarios.
    httpd_req_t invalid=write_config(1,45);assert(invalid.status==400);assert(applied==1);
    fail_storage=1;
    httpd_req_t failed=write_config(1,0);assert(failed.status==500);assert(standalone_config.rotation==180);assert(standalone_config.revision==1);
    fail_storage=0;
    httpd_req_t recovered=write_config(1,0);assert(recovered.status==200);assert(standalone_config.revision==2);assert(applied==2);
    standalone_config=(standalone_config_t){0};memset(standalone_token,0,sizeof(standalone_token));
    standalone_init();assert(standalone_config.revision==2);assert(standalone_config.enabled);assert(standalone_config.clock);
    assert(!strcmp(standalone_restore_status,"loaded"));
    assert(!strcmp(standalone_token,"1234abcd1234abcd"));
    standalone_config.ha_enabled=true;snprintf(standalone_config.ha_host,16,"192.168.1.10");standalone_config.ha_port=8123;
    snprintf(standalone_config.ha_token,1024,"fake-test-token");standalone_config.entity_count=1;
    snprintf(standalone_config.entities[0].id,128,"sensor.room_temperature");snprintf(standalone_config.entities[0].name,64,"客厅温度");
    standalone_config.weather=true;standalone_config.weather_minutes=30;standalone_config.latitude=31;standalone_config.longitude=121;
    standalone_config.printer_count=1;c6_printer_config_t *p=&standalone_config.printers[0];
    p->enabled=p->source_ha=p->show_status=p->show_progress=p->show_remaining=true;p->show_task=false;
    p->show_image=false;snprintf(p->image_entity,128,"image.x2d_task_cover");standalone_config.flip_animation=false;
    standalone_config.theme.enabled=true;standalone_config.theme.dark=false;standalone_config.theme.background=0xEEF2F7;standalone_config.theme.accent=0x0F766E;
    p->show_nozzle=p->show_bed=p->show_error=true;p->brand_accent=false;p->time_mode=1;
    snprintf(p->nozzle_entity,128,"sensor.x2d_nozzle");snprintf(p->bed_entity,128,"sensor.x2d_bed");snprintf(p->error_entity,128,"sensor.x2d_error");snprintf(p->end_time_entity,128,"sensor.x2d_end_time");
    snprintf(p->serial,40,"test_printer");snprintf(p->status_entity,128,"sensor.x2d_print_status");
    cJSON *j=document(&standalone_config,true);char *body=cJSON_PrintUnformatted(j);cJSON_Delete(j);
    httpd_req_t next={.method=HTTP_PUT,.body=body,.content_len=strlen(body),.auth="Bearer 1234abcd1234abcd"};handler(&next);free(body);
    assert(next.status==200);assert(standalone_config.revision==3);assert(!standalone_config.printers[0].show_task);
    assert(!standalone_config.printers[0].show_image&&!standalone_config.flip_animation&&!strcmp(standalone_config.printers[0].image_entity,"image.x2d_task_cover"));
    assert(!strstr(next.response,"fake-test-token"));assert(!strstr(next.response,"\"token\":"));
    assert(standalone_config.theme.enabled&&!standalone_config.theme.dark&&standalone_config.theme.background==0xEEF2F7&&standalone_config.printers[0].show_nozzle&&!standalone_config.printers[0].brand_accent&&standalone_config.printers[0].time_mode==1);
    j=document(&standalone_config,false);body=cJSON_PrintUnformatted(j);cJSON_Delete(j);
    httpd_req_t retained={.method=HTTP_PUT,.body=body,.content_len=strlen(body),.auth="Bearer 1234abcd1234abcd"};handler(&retained);free(body);
    assert(retained.status==200);assert(!strcmp(standalone_config.ha_token,"fake-test-token"));
    standalone_config=(standalone_config_t){0};standalone_init();assert(standalone_config.weather);assert(standalone_config.printer_count==1);assert(!standalone_config.printers[0].show_task);
    assert(!standalone_config.flip_animation&&!standalone_config.printers[0].show_image&&!strcmp(standalone_config.printers[0].image_entity,"image.x2d_task_cover"));
    assert(!strcmp(standalone_config.ha_token,"fake-test-token"));
    assert(standalone_config.theme.enabled&&standalone_config.theme.accent==0x0F766E&&standalone_config.printers[0].show_bed&&!strcmp(standalone_config.printers[0].end_time_entity,"sensor.x2d_end_time"));
    j=document(&standalone_config,false);standalone_config_t parsed;
    cJSON *media=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j,"printers"),0);
    cJSON_ReplaceItemInObjectCaseSensitive(media,"image_entity",cJSON_CreateString("camera.x2d_camera"));assert(parse(j,&parsed,&standalone_config));
    cJSON_ReplaceItemInObjectCaseSensitive(media,"image_entity",cJSON_CreateString("camera.x2d_camera/stream"));assert(!parse(j,&parsed,&standalone_config));
    cJSON_ReplaceItemInObjectCaseSensitive(media,"image_entity",cJSON_CreateString("image.x2d_task_cover"));
    cJSON_ReplaceItemInObjectCaseSensitive(j,"saturation_percent",cJSON_CreateNumber(50));cJSON_ReplaceItemInObjectCaseSensitive(j,"contrast_percent",cJSON_CreateNumber(75));assert(parse(j,&parsed,&standalone_config));
    cJSON_ReplaceItemInObjectCaseSensitive(j,"saturation_percent",cJSON_CreateNumber(200));cJSON_ReplaceItemInObjectCaseSensitive(j,"contrast_percent",cJSON_CreateNumber(150));assert(parse(j,&parsed,&standalone_config));
    cJSON_ReplaceItemInObjectCaseSensitive(j,"saturation_percent",cJSON_CreateNumber(201));assert(!parse(j,&parsed,&standalone_config));
    cJSON_ReplaceItemInObjectCaseSensitive(j,"saturation_percent",cJSON_CreateNumber(100));cJSON_ReplaceItemInObjectCaseSensitive(j,"contrast_percent",cJSON_CreateNumber(74));assert(!parse(j,&parsed,&standalone_config));cJSON_Delete(j);
    j=document(&standalone_config,false);cJSON *theme=cJSON_GetObjectItemCaseSensitive(j,"theme");cJSON_ReplaceItemInObjectCaseSensitive(theme,"accent",cJSON_CreateNumber(16777216));assert(!parse(j,&parsed,&standalone_config));cJSON_Delete(j);
    j=document(&standalone_config,false);cJSON_DeleteItemFromObjectCaseSensitive(j,"theme");cJSON *entry=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j,"printers"),0);
    const char *new_keys[]={"show_nozzle","show_bed","show_error","brand_accent","time_mode","nozzle_entity","bed_entity","error_entity","end_time_entity"};for(unsigned i=0;i<9;i++)cJSON_DeleteItemFromObjectCaseSensitive(entry,new_keys[i]);
    assert(parse(j,&parsed,&standalone_config));assert(!parsed.theme.enabled&&parsed.theme.background==0x080B12&&!parsed.printers[0].show_nozzle&&parsed.printers[0].brand_accent&&parsed.printers[0].time_mode==0&&!*parsed.printers[0].end_time_entity);assert(!strcmp(parsed.ha_token,"fake-test-token"));cJSON_Delete(j);
    j=document(&standalone_config,false);entry=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j,"printers"),0);
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"source_ha",cJSON_CreateBool(false));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"source_formlabs",cJSON_CreateBool(true));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"brand",cJSON_CreateString("formlabs"));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"serial",cJSON_CreateString("Form-123"));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"form_client_id",cJSON_CreateString("test-client"));
    cJSON_AddStringToObject(entry,"form_client_secret","form-secret-fixture");
    assert(parse(j,&parsed,&standalone_config)&&parsed.printers[0].source_formlabs&&!strcmp(parsed.printers[0].form_client_secret,"form-secret-fixture"));cJSON_Delete(j);
    j=document(&parsed,false);body=cJSON_PrintUnformatted(j);assert(!strstr(body,"form-secret-fixture")&&!strstr(body,"form_client_secret")&&strstr(body,"form_credentials_set\":true"));free(body);
    standalone_config_t other;assert(parse(j,&other,&parsed)&&!strcmp(other.printers[0].form_client_secret,"form-secret-fixture"));
    entry=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j,"printers"),0);cJSON_ReplaceItemInObjectCaseSensitive(entry,"form_client_id",cJSON_CreateString("other-client"));assert(!parse(j,&other,&parsed));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"form_client_id",cJSON_CreateString("test-client"));cJSON_ReplaceItemInObjectCaseSensitive(entry,"source_ha",cJSON_CreateBool(true));assert(!parse(j,&other,&parsed));cJSON_Delete(j);
    standalone_config_t mixed=standalone_config;mixed.printer_count=2;
    strcpy(mixed.printers[0].serial,"SHARED");strcpy(mixed.printers[0].name,"same-name");
    mixed.printers[1]=parsed.printers[0];strcpy(mixed.printers[1].serial,"SHARED");strcpy(mixed.printers[1].name,"same-name");
    strcpy(mixed.printers[0].form_client_secret,"wrong-brand-secret");strcpy(mixed.printers[1].access_code,"wrong-brand-code");
    j=document(&mixed,true);assert(parse(j,&other,NULL));
    assert(other.printer_count==2&&!other.printers[0].source_formlabs&&other.printers[1].source_formlabs);
    assert(!*other.printers[0].form_client_secret&&!*other.printers[1].access_code&&!*other.printers[1].status_entity);cJSON_Delete(j);
    mixed.printers[1]=mixed.printers[0];j=document(&mixed,true);assert(!parse(j,&other,NULL));cJSON_Delete(j);
    // Source changes never reuse hidden HA or Formlabs access-code values.
    mixed=standalone_config;strcpy(mixed.printers[0].access_code,"ha-is-not-mqtt");
    j=document(&mixed,false);entry=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j,"printers"),0);
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"source_ha",cJSON_CreateBool(false));
    cJSON_ReplaceItemInObjectCaseSensitive(entry,"host",cJSON_CreateString("192.168.1.20"));cJSON_ReplaceItemInObjectCaseSensitive(entry,"trust_lan",cJSON_CreateBool(true));
    assert(!parse(j,&other,&mixed));cJSON_Delete(j);
    standalone_pairing_open();standalone_init();assert(!standalone_pairing_pin(pin,NULL));
    // Actual storage contract: legacy string fails beyond one page; blob
    // succeeds, survives reboot, and a rejected update preserves revision.
    standalone_config_t large=standalone_config;large.printer_count=3;
    memset(large.ha_token,'x',900);large.ha_token[900]=0;
    for(unsigned i=0;i<3;i++){large.printers[i]=large.printers[0];snprintf(large.printers[i].serial,40,"printer_%u",i);}
    j=document(&large,true);body=cJSON_PrintUnformatted(j);cJSON_Delete(j);
    assert(strlen(body)>4000);assert(nvs_set_str(1,"config",body)==ESP_ERR_NVS_VALUE_TOO_LONG);
    httpd_req_t oversized={.method=HTTP_PUT,.body=body,.content_len=strlen(body),.auth="Bearer 1234abcd1234abcd"};handler(&oversized);free(body);
    assert(oversized.status==200);int saved_revision=standalone_config.revision;
    standalone_init();assert(standalone_config.printer_count==3&&standalone_config.revision==saved_revision);
    fail_storage=1;httpd_req_t full=write_config(saved_revision,180);assert(full.status==500&&strstr(full.response,"storage_full"));
    fail_storage=0;standalone_init();assert(standalone_config.revision==saved_revision&&standalone_config.printer_count==3);
    // A pre-upgrade string is read if no new blob exists.
    strcpy(stored_config,stored_blob);stored_blob[0]=0;standalone_init();assert(standalone_config.revision==saved_revision);
    strcpy(stored_config,"{\"broken\":true}");standalone_init();assert(!strcmp(standalone_restore_status,"invalid"));
    puts("C6 firmware contract: PIN format, expiry, lockout, single use, legacy auth, fragmented bodies, revisions, validation, storage failures and restore checks passed");
    return 0;
}
