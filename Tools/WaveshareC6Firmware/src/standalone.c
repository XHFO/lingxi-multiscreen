#include "standalone.h"
#include "local_state.h"
#include "form_demo.h"
#include "nvs.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "cJSON.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include "terminal_display_policy.h"
#if C6_FORMLABS_ONLY
#include "../../FormlabsC6Firmware/src/formlabs_portal.h"
#else
#include "standalone_portal.h"
#endif
standalone_config_t standalone_config = {.enabled=true,.brightness=80,.interval=15,.timezone=28800,.saturation_percent=100,.contrast_percent=100,.card_mask=C6_DEFAULT_CARD_MASK,.clock=true,.diagnostics=C6_DEFAULT_DIAGNOSTICS,.local_first=C6_DEFAULT_LOCAL_FIRST,.flip_animation=true,.ha_port=8123,.weather_minutes=30,
    .sleep_idle_minutes=5,.sleep_start=1380,.sleep_end=420,.sleep_keep_printing=true,
    .theme={.dark=true,.background=0x080B12,.card=0x111827,.inset=0x0B1220,.border=0x26344A,.accent=0x55E6B8,.secondary_accent=0x60A5FA,.primary_text=0xF8FAFC,.secondary_text=0xB9C4D6,.tertiary_text=0x8A9AB0}};
char standalone_token[17];
const char *standalone_restore_status="defaults";
const char *standalone_save_status="none";
// NVS strings must fit in a single page (~4KB). Printer/entity documents
// exceed that bound; NVS blobs span pages and keep the old value on failure.
static esp_err_t config_read(nvs_handle_t store,char *body,size_t *size){
    esp_err_t error=nvs_get_blob(store,"config_blob",body,size);
    if(error==ESP_ERR_NVS_NOT_FOUND){*size=C6_CONFIG_BYTES;return nvs_get_str(store,"config",body,size);}
    if(error==ESP_OK&&(!*size||*size>C6_CONFIG_BYTES||body[*size-1]!=0))return ESP_FAIL;
    return error;
}
static esp_err_t config_write(nvs_handle_t store,const char *body){
    size_t length=strlen(body)+1;if(length>C6_CONFIG_BYTES)return ESP_ERR_NVS_INVALID_LENGTH;
    esp_err_t error=nvs_set_blob(store,"config_blob",body,length);
    if(error==ESP_OK)error=nvs_commit(store);
    // Remove only the obsolete key, and only after the new document commits.
    // Never erase the NVS partition or pairing/Wi-Fi credentials.
    if(error==ESP_OK&&nvs_erase_key(store,"config")==ESP_OK)nvs_commit(store);
    return error;
}
static esp_err_t config_failure(httpd_req_t *req,const char *reason){
    standalone_save_status=reason;httpd_resp_set_status(req,"500 Internal Server Error");
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    char reply[96];snprintf(reply,sizeof(reply),"{\"error\":\"config_save\",\"reason\":\"%s\"}",reason);return httpd_resp_sendstr(req,reply);
}
static char pairing_pin[5];
static int64_t pairing_until;
static unsigned pairing_attempts;
static bool pairing_open;
void standalone_pairing_close(void){pairing_open=false;pairing_until=0;memset(pairing_pin,0,sizeof(pairing_pin));}
void standalone_pairing_open(void) {
    snprintf(pairing_pin,sizeof(pairing_pin),"%04u",(unsigned)(esp_random()%10000));
    pairing_until=esp_timer_get_time()+120000000;
    pairing_attempts=0;pairing_open=true;
}
bool standalone_pairing_pin(char pin[5],int *remaining_seconds) {
    if(!pairing_open||pairing_attempts>=5||esp_timer_get_time()>=pairing_until)return false;
    memcpy(pin,pairing_pin,sizeof(pairing_pin));
    if(remaining_seconds)*remaining_seconds=(int)((pairing_until-esp_timer_get_time()+999999)/1000000);
    return true;
}
int standalone_pairing_brightness(int requested,bool visible) {
    // Pairing temporarily wakes a dark screen; the requested level is retained.
    return visible&&requested<30?30:requested;
}
static esp_err_t pairing_error(httpd_req_t *req,const char *status,const char *error) {
    char body[64];snprintf(body,sizeof(body),"{\"error\":\"%s\"}",error);
    httpd_resp_set_status(req,status);httpd_resp_set_type(req,"application/json");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");return httpd_resp_sendstr(req,body);
}
static esp_err_t pairing_handler(httpd_req_t *req) {
    // LAN-only opt-in: never grant configuration access on the open setup AP.
    if(standalone_lan_pairing_allowed(req)){
        if(req->content_len<=0||req->content_len>=64)return pairing_error(req,"400 Bad Request","invalid_lan_request");
        char body[64]={0};int count=0;while(count<req->content_len){int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0)return ESP_FAIL;count+=n;}
        cJSON *j=cJSON_ParseWithOpts(body,NULL,true),*mode=cJSON_GetObjectItemCaseSensitive(j,"mode");bool valid=cJSON_IsString(mode)&&!strcmp(mode->valuestring,"lan");cJSON_Delete(j);
        if(!valid)return pairing_error(req,"400 Bad Request","invalid_lan_request");
        httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
        char reply[80];snprintf(reply,sizeof(reply),"{\"token\":\"%s\",\"mode\":\"lan\"}",standalone_token);
        return httpd_resp_sendstr(req,reply);
    }
    // Physical access is required for each two-minute, single-use pairing window.
    // All calls are serialized on the HTTP server task; never expose this token
    // in diagnostics, logs or the display. Saved clients keep their credential.
    if(!pairing_open)return pairing_error(req,"403 Forbidden","pairing_not_open");
    if(pairing_attempts>=5)return pairing_error(req,"429 Too Many Requests","pairing_locked");
    if(esp_timer_get_time()>=pairing_until)return pairing_error(req,"410 Gone","pairing_expired");
    if(req->content_len<=0||req->content_len>=128)return pairing_error(req,"400 Bad Request","invalid_pin");
    char body[128]={0};int count=0;
    while(count<req->content_len){int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0)return pairing_error(req,"400 Bad Request","invalid_pin");count+=n;}
    const char *end=NULL;cJSON *j=cJSON_ParseWithOpts(body,&end,true);
    cJSON *pin=cJSON_GetObjectItemCaseSensitive(j,"pin");
    bool valid=cJSON_IsObject(j)&&cJSON_IsString(pin)&&strlen(pin->valuestring)==4;
    if(valid)for(unsigned i=0;i<4;i++)valid&=pin->valuestring[i]>='0'&&pin->valuestring[i]<='9';
    if(!valid){cJSON_Delete(j);memset(body,0,sizeof(body));return pairing_error(req,"400 Bad Request","invalid_pin");}
    // Receiving a slow request must not extend the physical pairing window.
    if(esp_timer_get_time()>=pairing_until){cJSON_Delete(j);memset(body,0,sizeof(body));return pairing_error(req,"410 Gone","pairing_expired");}
    unsigned difference=0;for(unsigned i=0;i<4;i++)difference|=(unsigned char)pin->valuestring[i]^(unsigned char)pairing_pin[i];
    cJSON_Delete(j);memset(body,0,sizeof(body));
    if(difference){pairing_attempts++;return pairing_error(req,pairing_attempts>=5?"429 Too Many Requests":"401 Unauthorized",pairing_attempts>=5?"pairing_locked":"incorrect_pin");}
    pairing_open=false;memset(pairing_pin,0,sizeof(pairing_pin));
    char response[40];snprintf(response,sizeof(response),"{\"token\":\"%s\"}",standalone_token);
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t result=httpd_resp_sendstr(req,response);memset(response,0,sizeof(response));return result;
}
#ifdef C6_JSON_REFERENCE_TEST
// Host-only legacy encoder: independent schema parity oracle, never firmware.
static cJSON *document(const standalone_config_t *c,bool secrets) {
    cJSON *j=cJSON_CreateObject();if(!j)return NULL;
    cJSON_AddNumberToObject(j,"schema_version",2);cJSON_AddNumberToObject(j,"revision",c->revision);
    cJSON_AddBoolToObject(j,"enabled",c->enabled);cJSON_AddBoolToObject(j,"local_first",c->local_first);
    cJSON_AddNumberToObject(j,"rotation",c->rotation);cJSON_AddNumberToObject(j,"brightness",c->brightness);
    cJSON_AddNumberToObject(j,"interval",c->interval);cJSON_AddNumberToObject(j,"timezone",c->timezone);
    cJSON_AddBoolToObject(j,"clock",c->clock);cJSON_AddBoolToObject(j,"diagnostics",c->diagnostics);
    cJSON_AddNumberToObject(j,"clock_style",c->clock_style);
    cJSON_AddBoolToObject(j,"flip_animation",c->flip_animation);
    cJSON_AddNumberToObject(j,"language",c->language);
    cJSON_AddNumberToObject(j,"digit_style",c->digit_style);
    cJSON_AddNumberToObject(j,"sleep_mode",c->sleep_mode);cJSON_AddNumberToObject(j,"sleep_idle_minutes",c->sleep_idle_minutes);
    cJSON_AddNumberToObject(j,"sleep_start",c->sleep_start);cJSON_AddNumberToObject(j,"sleep_end",c->sleep_end);
    cJSON_AddBoolToObject(j,"sleep_keep_printing",c->sleep_keep_printing);
    cJSON_AddNumberToObject(j,"card_mask",c->card_mask);
    cJSON_AddNumberToObject(j,"saturation_percent",c->saturation_percent);cJSON_AddNumberToObject(j,"contrast_percent",c->contrast_percent);
    cJSON *theme=cJSON_AddObjectToObject(j,"theme");cJSON_AddBoolToObject(theme,"enabled",c->theme.enabled);cJSON_AddBoolToObject(theme,"dark",c->theme.dark);
#define THEME_WRITE(field) cJSON_AddNumberToObject(theme,#field,c->theme.field)
    THEME_WRITE(background);THEME_WRITE(card);THEME_WRITE(inset);THEME_WRITE(border);THEME_WRITE(accent);THEME_WRITE(secondary_accent);THEME_WRITE(primary_text);THEME_WRITE(secondary_text);THEME_WRITE(tertiary_text);
#undef THEME_WRITE
    cJSON_AddBoolToObject(j,"weather",c->weather);cJSON_AddNumberToObject(j,"latitude",c->latitude);cJSON_AddNumberToObject(j,"longitude",c->longitude);cJSON_AddStringToObject(j,"weather_city",c->weather_city);
    cJSON_AddNumberToObject(j,"weather_minutes",c->weather_minutes);
    cJSON *ha=cJSON_AddObjectToObject(j,"ha");cJSON_AddBoolToObject(ha,"enabled",c->ha_enabled);
    cJSON_AddStringToObject(ha,"host",c->ha_host);cJSON_AddNumberToObject(ha,"port",c->ha_port);
    cJSON_AddBoolToObject(ha,"tls",c->ha_tls);cJSON_AddBoolToObject(ha,"token_set",*c->ha_token!=0);
    if(secrets)cJSON_AddStringToObject(ha,"token",c->ha_token);
    cJSON *a=cJSON_AddArrayToObject(ha,"entities");
    for(unsigned i=0;i<c->entity_count;i++) {
        cJSON *e=cJSON_CreateObject();cJSON_AddStringToObject(e,"id",c->entities[i].id);
        cJSON_AddStringToObject(e,"name",c->entities[i].name);cJSON_AddItemToArray(a,e);
    }
    a=cJSON_AddArrayToObject(j,"printers");
    for(unsigned i=0;i<c->printer_count;i++) {
        const c6_printer_config_t *p=&c->printers[i];cJSON *e=cJSON_CreateObject();
        cJSON_AddBoolToObject(e,"enabled",p->enabled);cJSON_AddStringToObject(e,"host",p->host);
        cJSON_AddBoolToObject(e,"rotate",p->rotate);
        cJSON_AddStringToObject(e,"serial",p->serial);cJSON_AddStringToObject(e,"name",p->name);
        cJSON_AddStringToObject(e,"brand",c6_printer_brand(p));
        cJSON_AddBoolToObject(e,"trust_lan",p->trust_lan);cJSON_AddStringToObject(e,"certificate",p->certificate);
        cJSON_AddBoolToObject(e,"access_code_set",*p->access_code!=0);
        cJSON_AddBoolToObject(e,"source_ha",p->source_ha);
        cJSON_AddBoolToObject(e,"source_formlabs",p->source_formlabs);
        cJSON_AddStringToObject(e,"form_client_id",p->form_client_id);
        cJSON_AddBoolToObject(e,"form_credentials_set",*p->form_client_secret!=0);
        cJSON_AddBoolToObject(e,"show_layers",p->show_layers);cJSON_AddBoolToObject(e,"show_material",p->show_material);
        if(secrets)cJSON_AddStringToObject(e,"form_client_secret",p->form_client_secret);
        cJSON_AddBoolToObject(e,"show_status",p->show_status);cJSON_AddBoolToObject(e,"show_progress",p->show_progress);
        cJSON_AddBoolToObject(e,"show_task",p->show_task);cJSON_AddBoolToObject(e,"show_remaining",p->show_remaining);
        cJSON_AddBoolToObject(e,"show_image",p->show_image);
        cJSON_AddBoolToObject(e,"show_nozzle",p->show_nozzle);cJSON_AddBoolToObject(e,"show_bed",p->show_bed);cJSON_AddBoolToObject(e,"show_error",p->show_error);
        cJSON_AddNumberToObject(e,"time_mode",p->time_mode);
        cJSON_AddNumberToObject(e,"card_style",p->card_style);
        cJSON_AddBoolToObject(e,"brand_accent",p->brand_accent);
        cJSON_AddStringToObject(e,"status_entity",p->status_entity);cJSON_AddStringToObject(e,"progress_entity",p->progress_entity);
        cJSON_AddStringToObject(e,"task_entity",p->task_entity);cJSON_AddStringToObject(e,"remaining_entity",p->remaining_entity);
        cJSON_AddStringToObject(e,"image_entity",p->image_entity);
        cJSON_AddStringToObject(e,"task_cover_entity",p->task_cover_entity);
        cJSON_AddBoolToObject(e,"live_image",p->live_image);
        cJSON_AddStringToObject(e,"nozzle_entity",p->nozzle_entity);cJSON_AddStringToObject(e,"bed_entity",p->bed_entity);cJSON_AddStringToObject(e,"error_entity",p->error_entity);cJSON_AddStringToObject(e,"end_time_entity",p->end_time_entity);
        if(secrets)cJSON_AddStringToObject(e,"access_code",p->access_code);
        cJSON_AddItemToArray(a,e);
    }
    return j;
}
#endif
#include "config_json.h"
static bool integer(cJSON *j,const char *name,int min,int max,int *out) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(j,name);
    if(!cJSON_IsNumber(v)||!isfinite(v->valuedouble)||v->valuedouble<min||v->valuedouble>max||floor(v->valuedouble)!=v->valuedouble)return false;
    *out=(int)v->valuedouble;return true;
}
static bool boolean(cJSON *j,const char *name,bool *out) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(j,name);if(!cJSON_IsBool(v))return false;*out=cJSON_IsTrue(v);return true;
}
static bool string(cJSON *j,const char *name,char *out,size_t size) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(j,name);
    if(!cJSON_IsString(v)||strlen(v->valuestring)>=size)return false;
    memcpy(out,v->valuestring,strlen(v->valuestring)+1);return true;
}
static bool identifier(const char *s,bool entity) {
    if(!*s)return false;
    bool dot=false;const char *start=s;
    for(;*s;s++){if(*s=='.'&&entity){if(dot||s==start||!s[1])return false;dot=true;}else if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||*s=='_'))return false;}
    return !entity||dot;
}
static bool parse(cJSON *j,standalone_config_t *out,const standalone_config_t *previous) {
    memset(out,0,sizeof(*out));out->ha_port=8123;out->weather_minutes=30;out->flip_animation=true;out->saturation_percent=out->contrast_percent=100;out->card_mask=C6_DEFAULT_CARD_MASK;
    out->theme=(c6_theme_config_t){.dark=true,.background=0x080B12,.card=0x111827,.inset=0x0B1220,.border=0x26344A,.accent=0x55E6B8,.secondary_accent=0x60A5FA,.primary_text=0xF8FAFC,.secondary_text=0xB9C4D6,.tertiary_text=0x8A9AB0};
    int schema;
    if(!(cJSON_IsObject(j)&&integer(j,"schema_version",1,2,&schema)
        &&integer(j,"revision",0,INT_MAX-1,&out->revision)
        &&integer(j,"rotation",0,270,&out->rotation)&&terminal_rotation_valid(out->rotation)
        &&integer(j,"brightness",0,100,&out->brightness)&&integer(j,"interval",5,300,&out->interval)
        &&integer(j,"timezone",-43200,50400,&out->timezone)&&boolean(j,"enabled",&out->enabled)
        &&boolean(j,"clock",&out->clock)&&boolean(j,"diagnostics",&out->diagnostics)))return false;
    if(cJSON_HasObjectItem(j,"flip_animation")&&!boolean(j,"flip_animation",&out->flip_animation))return false;
    out->clock_style=previous?previous->clock_style:0;
    if(cJSON_HasObjectItem(j,"clock_style")&&!integer(j,"clock_style",0,1,&out->clock_style))return false;
    out->language=previous?previous->language:0;
    if(cJSON_HasObjectItem(j,"language")&&!integer(j,"language",0,1,&out->language))return false;
    out->digit_style=previous?previous->digit_style:0;
    if(cJSON_HasObjectItem(j,"digit_style")&&!integer(j,"digit_style",0,1,&out->digit_style))return false;
    out->sleep_mode=previous?previous->sleep_mode:0;out->sleep_idle_minutes=previous?previous->sleep_idle_minutes:5;
    out->sleep_start=previous?previous->sleep_start:1380;out->sleep_end=previous?previous->sleep_end:420;
    out->sleep_keep_printing=previous?previous->sleep_keep_printing:true;
    if(cJSON_HasObjectItem(j,"sleep_mode")&&!integer(j,"sleep_mode",0,2,&out->sleep_mode))return false;
    if(cJSON_HasObjectItem(j,"sleep_idle_minutes")&&!integer(j,"sleep_idle_minutes",1,120,&out->sleep_idle_minutes))return false;
    if(cJSON_HasObjectItem(j,"sleep_start")&&!integer(j,"sleep_start",0,1439,&out->sleep_start))return false;
    if(cJSON_HasObjectItem(j,"sleep_end")&&!integer(j,"sleep_end",0,1439,&out->sleep_end))return false;
    if(cJSON_HasObjectItem(j,"sleep_keep_printing")&&!boolean(j,"sleep_keep_printing",&out->sleep_keep_printing))return false;
    if(out->sleep_mode==2&&out->sleep_start==out->sleep_end)return false;
    if(cJSON_HasObjectItem(j,"card_mask")&&!integer(j,"card_mask",0,15,&out->card_mask))return false;
    if(cJSON_HasObjectItem(j,"saturation_percent")&&!integer(j,"saturation_percent",50,200,&out->saturation_percent))return false;
    if(cJSON_HasObjectItem(j,"contrast_percent")&&!integer(j,"contrast_percent",75,150,&out->contrast_percent))return false;
    cJSON *theme=cJSON_GetObjectItemCaseSensitive(j,"theme");
    if(theme){
        if(!cJSON_IsObject(theme))return false;
        if(cJSON_HasObjectItem(theme,"enabled")&&!boolean(theme,"enabled",&out->theme.enabled))return false;
        if(cJSON_HasObjectItem(theme,"dark")&&!boolean(theme,"dark",&out->theme.dark))return false;
#define THEME_READ(field) if(cJSON_HasObjectItem(theme,#field)){int rgb;if(!integer(theme,#field,0,0xFFFFFF,&rgb))return false;out->theme.field=(uint32_t)rgb;}
        THEME_READ(background);THEME_READ(card);THEME_READ(inset);THEME_READ(border);THEME_READ(accent);THEME_READ(secondary_accent);THEME_READ(primary_text);THEME_READ(secondary_text);THEME_READ(tertiary_text);
#undef THEME_READ
    }
    if(schema==1)return !out->enabled||out->clock||out->diagnostics;
    if(!boolean(j,"local_first",&out->local_first))return false;
    cJSON *lat=cJSON_GetObjectItemCaseSensitive(j,"latitude"),*lon=cJSON_GetObjectItemCaseSensitive(j,"longitude");
    if(!boolean(j,"weather",&out->weather)||!string(j,"weather_city",out->weather_city,sizeof(out->weather_city))||!cJSON_IsNumber(lat)||!cJSON_IsNumber(lon)||!isfinite(lat->valuedouble)||!isfinite(lon->valuedouble)||fabs(lat->valuedouble)>90||fabs(lon->valuedouble)>180)return false;
    out->latitude=lat->valuedouble;out->longitude=lon->valuedouble;
    if(cJSON_HasObjectItem(j,"weather_minutes")&&!integer(j,"weather_minutes",15,180,&out->weather_minutes))return false;
    cJSON *ha=cJSON_GetObjectItemCaseSensitive(j,"ha"),*a=cJSON_GetObjectItemCaseSensitive(ha,"entities");
    if(!boolean(ha,"enabled",&out->ha_enabled)||!string(ha,"host",out->ha_host,sizeof(out->ha_host))
        ||!integer(ha,"port",1,65535,&out->ha_port)||!boolean(ha,"tls",&out->ha_tls)
        ||!cJSON_IsArray(a)||cJSON_GetArraySize(a)>C6_MAX_ENTITIES)return false;
    cJSON *secret=cJSON_GetObjectItemCaseSensitive(ha,"token");
    if(secret&&!string(ha,"token",out->ha_token,sizeof(out->ha_token)))return false;
    if(!*out->ha_token&&previous&&!strcmp(out->ha_host,previous->ha_host)&&out->ha_port==previous->ha_port&&out->ha_tls==previous->ha_tls)
        snprintf(out->ha_token,sizeof(out->ha_token),"%s",previous->ha_token);
    cJSON *e;cJSON_ArrayForEach(e,a) {
        c6_entity_config_t *c=&out->entities[out->entity_count++];
        if(!string(e,"id",c->id,sizeof(c->id))||!identifier(c->id,true)||!string(e,"name",c->name,sizeof(c->name)))return false;
        for(unsigned i=0;i+1<out->entity_count;i++)if(!strcmp(out->entities[i].id,c->id))return false;
    }
    if(out->ha_enabled&&(!c6_private_ip(out->ha_host)||!*out->ha_token))return false;
    a=cJSON_GetObjectItemCaseSensitive(j,"printers");
    if(!cJSON_IsArray(a)||cJSON_GetArraySize(a)>C6_MAX_PRINTERS)return false;
    cJSON_ArrayForEach(e,a) {
        c6_printer_config_t *p=&out->printers[out->printer_count++];
        p->rotate=true;if(cJSON_HasObjectItem(e,"rotate")&&!boolean(e,"rotate",&p->rotate))return false;
        if(!boolean(e,"enabled",&p->enabled)||!boolean(e,"trust_lan",&p->trust_lan)
           ||!string(e,"host",p->host,sizeof(p->host))||!string(e,"serial",p->serial,sizeof(p->serial))
           ||!string(e,"name",p->name,sizeof(p->name))||!string(e,"certificate",p->certificate,sizeof(p->certificate)))return false;
        if(cJSON_HasObjectItem(e,"source_formlabs")&&!boolean(e,"source_formlabs",&p->source_formlabs))return false;
        p->show_layers=p->show_material=true;
        if(cJSON_HasObjectItem(e,"show_layers")&&!boolean(e,"show_layers",&p->show_layers))return false;
        if(cJSON_HasObjectItem(e,"show_material")&&!boolean(e,"show_material",&p->show_material))return false;
        if(p->source_formlabs){
            if(!c6_form_is_demo(p)&&(!*p->serial||strspn(p->serial,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")!=strlen(p->serial)))return false;
            if((!c6_form_is_demo(p)||cJSON_HasObjectItem(e,"form_client_id"))&&!string(e,"form_client_id",p->form_client_id,sizeof(p->form_client_id)))return false;
            if(cJSON_HasObjectItem(e,"form_client_secret")&&!string(e,"form_client_secret",p->form_client_secret,sizeof(p->form_client_secret)))return false;
            if(!*p->form_client_secret&&previous)for(unsigned k=0;k<previous->printer_count;k++){
                const c6_printer_config_t *old=&previous->printers[k];
                if(old->source_formlabs&&!strcmp(old->serial,p->serial)&&!strcmp(old->form_client_id,p->form_client_id))snprintf(p->form_client_secret,sizeof(p->form_client_secret),"%s",old->form_client_secret);
            }
        }else if(!identifier(p->serial,false))return false;
        if(!boolean(e,"source_ha",&p->source_ha)||!string(e,"status_entity",p->status_entity,sizeof(p->status_entity))||!string(e,"progress_entity",p->progress_entity,sizeof(p->progress_entity))||!string(e,"task_entity",p->task_entity,sizeof(p->task_entity))||!string(e,"remaining_entity",p->remaining_entity,sizeof(p->remaining_entity)))return false;
        if(p->source_formlabs&&p->source_ha)return false;
        cJSON *brand=cJSON_GetObjectItemCaseSensitive(e,"brand");
        if(brand&&(!cJSON_IsString(brand)||strcmp(brand->valuestring,c6_printer_brand(p))))return false;
        p->show_status=p->show_progress=p->show_task=p->show_remaining=p->show_image=true;
        p->brand_accent=true;
        if(cJSON_HasObjectItem(e,"image_entity")&&(!string(e,"image_entity",p->image_entity,sizeof(p->image_entity))||(*p->image_entity&&((strncmp(p->image_entity,"image.",6)&&strncmp(p->image_entity,"camera.",7))||!identifier(p->image_entity,true)))))return false;
        if(cJSON_HasObjectItem(e,"task_cover_entity")&&(!string(e,"task_cover_entity",p->task_cover_entity,sizeof(p->task_cover_entity))||(*p->task_cover_entity&&(strncmp(p->task_cover_entity,"image.",6)||!identifier(p->task_cover_entity,true)))))return false;
        if(cJSON_HasObjectItem(e,"show_image")&&!boolean(e,"show_image",&p->show_image))return false;
        p->live_image=!strncmp(p->image_entity,"camera.",7);
        if(cJSON_HasObjectItem(e,"live_image")&&!boolean(e,"live_image",&p->live_image))return false;
        if(cJSON_HasObjectItem(e,"show_nozzle")&&!boolean(e,"show_nozzle",&p->show_nozzle))return false;
        if(cJSON_HasObjectItem(e,"show_bed")&&!boolean(e,"show_bed",&p->show_bed))return false;
        if(cJSON_HasObjectItem(e,"show_error")&&!boolean(e,"show_error",&p->show_error))return false;
        if(cJSON_HasObjectItem(e,"time_mode")&&!integer(e,"time_mode",0,1,&p->time_mode))return false;
        if(cJSON_HasObjectItem(e,"card_style")){
            if(!integer(e,"card_style",0,2,&p->card_style))return false;
        }else if(previous)for(unsigned k=0;k<previous->printer_count;k++){
            const c6_printer_config_t *old=&previous->printers[k];
            if(old->source_formlabs==p->source_formlabs&&old->source_ha==p->source_ha&&!strcmp(old->serial,p->serial))p->card_style=old->card_style;
        }
        if(cJSON_HasObjectItem(e,"brand_accent")&&!boolean(e,"brand_accent",&p->brand_accent))return false;
        const char *detail_keys[]={"nozzle_entity","bed_entity","error_entity","end_time_entity"};char *detail_values[]={p->nozzle_entity,p->bed_entity,p->error_entity,p->end_time_entity};
        for(unsigned k=0;k<4;k++)if(cJSON_HasObjectItem(e,detail_keys[k])&&(!string(e,detail_keys[k],detail_values[k],128)||(*detail_values[k]&&!identifier(detail_values[k],true))))return false;
        if((cJSON_HasObjectItem(e,"show_status")&&!boolean(e,"show_status",&p->show_status))||(cJSON_HasObjectItem(e,"show_progress")&&!boolean(e,"show_progress",&p->show_progress))||(cJSON_HasObjectItem(e,"show_task")&&!boolean(e,"show_task",&p->show_task))||(cJSON_HasObjectItem(e,"show_remaining")&&!boolean(e,"show_remaining",&p->show_remaining)))return false;
        secret=cJSON_GetObjectItemCaseSensitive(e,"access_code");
        if(secret&&!string(e,"access_code",p->access_code,sizeof(p->access_code)))return false;
        if(!p->source_ha&&!p->source_formlabs&&!*p->access_code&&previous)for(unsigned i=0;i<previous->printer_count;i++)
            if(!previous->printers[i].source_ha&&!previous->printers[i].source_formlabs&&!strcmp(p->serial,previous->printers[i].serial)&&!strcmp(p->host,previous->printers[i].host))
                snprintf(p->access_code,sizeof(p->access_code),"%s",previous->printers[i].access_code);
        // Ignore stale, hidden source fields. Never persist credentials or
        // subscribe to entities belonging to a different brand/data source.
        if(p->source_ha||p->source_formlabs){memset(p->access_code,0,sizeof(p->access_code));memset(p->certificate,0,sizeof(p->certificate));memset(p->host,0,sizeof(p->host));p->trust_lan=false;}
        if(!p->source_formlabs){memset(p->form_client_id,0,sizeof(p->form_client_id));memset(p->form_client_secret,0,sizeof(p->form_client_secret));}
        if(c6_form_is_demo(p)){memset(p->form_client_id,0,sizeof(p->form_client_id));memset(p->form_client_secret,0,sizeof(p->form_client_secret));}
        if(!p->source_ha){p->status_entity[0]=p->progress_entity[0]=p->task_entity[0]=p->remaining_entity[0]=p->image_entity[0]=p->task_cover_entity[0]=0;p->nozzle_entity[0]=p->bed_entity[0]=p->error_entity[0]=p->end_time_entity[0]=0;}
        if(p->enabled) {
            if(p->source_formlabs){if(!c6_form_is_demo(p)&&(!*p->form_client_id||!*p->form_client_secret))return false;}
            else if(p->source_ha){if(!out->ha_enabled||!identifier(p->status_entity,true))return false;const char *ids[]={p->progress_entity,p->task_entity,p->remaining_entity};for(unsigned k=0;k<3;k++)if(*ids[k]&&!identifier(ids[k],true))return false;}
            else if(!c6_private_ip(p->host)||!identifier(p->serial,false)||!*p->access_code||(!p->trust_lan&&!*p->certificate))return false;
        }
        for(unsigned i=0;i+1<out->printer_count;i++)if(out->printers[i].source_formlabs==p->source_formlabs&&!strcmp(out->printers[i].serial,p->serial))return false;
    }
    bool pages=out->clock||out->diagnostics||(out->ha_enabled&&out->entity_count)||out->weather;
    for(unsigned i=0;i<out->printer_count;i++)pages|=out->printers[i].enabled;
    return !out->enabled||pages;
}
void standalone_init(void) {
    pairing_open=false;pairing_attempts=0;pairing_until=0;memset(pairing_pin,0,sizeof(pairing_pin));
    nvs_handle_t store;ESP_ERROR_CHECK(nvs_open(C6_CONFIG_NAMESPACE,NVS_READWRITE,&store));
    size_t size=sizeof(standalone_token);
    if(nvs_get_str(store,"token",standalone_token,&size)!=ESP_OK) {
        snprintf(standalone_token,sizeof(standalone_token),"%08lx%08lx",(unsigned long)esp_random(),(unsigned long)esp_random());
        ESP_ERROR_CHECK(nvs_set_str(store,"token",standalone_token));ESP_ERROR_CHECK(nvs_commit(store));
    }
    char *body=malloc(C6_CONFIG_BYTES);standalone_config_t *loaded=calloc(1,sizeof(*loaded));size=C6_CONFIG_BYTES;
    standalone_restore_status="defaults";
    if(!body||!loaded)standalone_restore_status="low_memory";
    else if(config_read(store,body,&size)==ESP_OK) {
        cJSON *j=cJSON_Parse(body);
        if(parse(j,loaded,NULL)&&standalone_profile_valid(loaded)){standalone_config=*loaded;standalone_restore_status="loaded";}
        else standalone_restore_status="invalid";
        cJSON_Delete(j);
    }
    if(body){memset(body,0,C6_CONFIG_BYTES);free(body);}if(loaded){memset(loaded,0,sizeof(*loaded));free(loaded);}nvs_close(store);
}
bool standalone_set_flip(bool enabled){
    unsigned mask=0;for(unsigned i=0;i<standalone_config.printer_count;i++)if(standalone_config.printers[i].rotate)mask|=1U<<i;
    return standalone_save_display(standalone_config.revision,standalone_config.rotation,enabled,standalone_config.card_mask,mask);
}
bool standalone_save_display(int expected_revision,int rotation,bool enabled,int card_mask,unsigned printer_mask){
    return standalone_save_display_language(expected_revision,rotation,enabled,card_mask,printer_mask,standalone_config.language);
}
bool standalone_save_display_language(int expected_revision,int rotation,bool enabled,int card_mask,unsigned printer_mask,int language){
    return standalone_save_monitor_display(expected_revision,rotation,enabled,card_mask,printer_mask,language,standalone_config.sleep_mode);
}
bool standalone_save_monitor_display(int expected_revision,int rotation,bool enabled,int card_mask,unsigned printer_mask,int language,int sleep_mode){
    if(language<0||language>1||sleep_mode<0||sleep_mode>2||(sleep_mode==2&&standalone_config.sleep_start==standalone_config.sleep_end))return false;
    if(expected_revision!=standalone_config.revision||expected_revision>=INT_MAX-1||
        !terminal_rotation_valid(rotation)||card_mask<0||card_mask>15)return false;
#if C6_FORMLABS_ONLY
    if(card_mask&~5)return false;
#endif
    // Change one device-owned display setting without reconnecting subscriptions.
    config_display_override_t display={.revision=expected_revision+1,.rotation=rotation,.card_mask=card_mask,.flip=enabled,.printers=printer_mask};
    display.language=language;
    display.sleep_mode=sleep_mode;
    char *body=config_json_encode(&standalone_config,true,&display,NULL);if(!body)return false;
    nvs_handle_t store;esp_err_t result=nvs_open(C6_CONFIG_NAMESPACE,NVS_READWRITE,&store);
    if(result==ESP_OK){result=config_write(store,body);nvs_close(store);}
    memset(body,0,strlen(body));free(body);
    if(result!=ESP_OK)return false;
    standalone_config.flip_animation=enabled;standalone_config.rotation=rotation;standalone_config.card_mask=card_mask;
    standalone_config.language=language;
    standalone_config.sleep_mode=sleep_mode;
    for(unsigned i=0;i<standalone_config.printer_count;i++)standalone_config.printers[i].rotate=(printer_mask&(1U<<i))!=0;
    standalone_config.revision++;return true;
}
bool standalone_authorized(httpd_req_t *req) {
    char auth[40],expected[40];snprintf(expected,sizeof(expected),"Bearer %s",standalone_token);
    if(httpd_req_get_hdr_value_str(req,"Authorization",auth,sizeof(auth))==ESP_OK&&!strcmp(auth,expected))return true;
    httpd_resp_set_status(req,"401 Unauthorized");httpd_resp_sendstr(req,"Unauthorized");return false;
}
static esp_err_t handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    if(req->method==HTTP_PUT) {
        if(req->content_len<=0||req->content_len>=C6_CONFIG_BYTES)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid configuration size");
        char *body=calloc(1,req->content_len+1);
        if(!body)return config_failure(req,"low_memory");
        int count=0;bool received=true;
        while(count<req->content_len){int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0){received=false;break;}count+=n;}
        cJSON *j=received?cJSON_Parse(body):NULL;
        memset(body,0,req->content_len);free(body);
        if(!j)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid configuration");
        standalone_config_t *next=calloc(1,sizeof(*next));
        if(!next){cJSON_Delete(j);return config_failure(req,"low_memory");}
        bool valid=parse(j,next,&standalone_config)&&standalone_profile_valid(next);cJSON_Delete(j);
        if(!valid){memset(next,0,sizeof(*next));free(next);return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid configuration");}
        if(next->revision!=standalone_config.revision){memset(next,0,sizeof(*next));free(next);httpd_resp_set_status(req,"409 Conflict");return httpd_resp_sendstr(req,"Read configuration again");}
        next->revision++;bool too_large=false;char *encoded=config_json_encode(next,true,NULL,&too_large);
        if(!encoded){memset(next,0,sizeof(*next));free(next);return config_failure(req,too_large?"storage_size":"low_memory");}
        nvs_handle_t store;esp_err_t error=nvs_open(C6_CONFIG_NAMESPACE,NVS_READWRITE,&store);
        if(error==ESP_OK){error=config_write(store,encoded);nvs_close(store);}
        memset(encoded,0,strlen(encoded));free(encoded);
        if(error==ESP_OK){standalone_config=*next;standalone_save_status="saved";standalone_apply();}
        memset(next,0,sizeof(*next));free(next);
        if(error!=ESP_OK)return config_failure(req,error==ESP_ERR_NVS_NOT_ENOUGH_SPACE?"storage_full":error==ESP_ERR_NVS_INVALID_LENGTH||error==ESP_ERR_NVS_VALUE_TOO_LONG?"storage_size":"storage_error");
    }
    char *encoded=config_json_encode(&standalone_config,false,NULL,NULL);
    if(!encoded)return ESP_FAIL;
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t result=httpd_resp_sendstr(req,encoded);free(encoded);return result;
}
static esp_err_t portal_handler(httpd_req_t *req) {
    httpd_resp_set_type(req,"text/html; charset=utf-8");httpd_resp_set_hdr(req,"Cache-Control","no-store");
#ifdef C6_PORTAL_GZIP
    httpd_resp_set_hdr(req,"Content-Encoding","gzip");return httpd_resp_send(req,(const char*)standalone_portal,sizeof(standalone_portal));
#else
    return httpd_resp_sendstr(req,standalone_portal);
#endif
}
void standalone_register(httpd_handle_t server) {
    httpd_uri_t routes[]={{.uri="/api/standalone",.method=HTTP_GET,.handler=handler},
        {.uri="/api/standalone",.method=HTTP_PUT,.handler=handler},{.uri="/standalone",.method=HTTP_GET,.handler=portal_handler},
        {.uri="/api/pair",.method=HTTP_POST,.handler=pairing_handler}};
    for(unsigned i=0;i<sizeof(routes)/sizeof(routes[0]);i++)ESP_ERROR_CHECK(httpd_register_uri_handler(server,&routes[i]));
}
