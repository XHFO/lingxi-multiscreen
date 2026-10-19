#include "local_sources.h"
#include "formlabs_source.h"
#include "form_auth_cache.h"
#include "png_thumbnail.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "esp_netif.h"
#if !C6_FORMLABS_ONLY
#include "esp_transport_tcp.h"
#include "esp_transport_ssl.h"
#include "esp_transport_ws.h"
#include "mqtt_client.h"
#endif
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "nvs.h"
#include "esp32c6/rom/tjpgd.h"
#include <math.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#define MESSAGE_LIMIT 16384
#if !C6_FORMLABS_ONLY
#include "ha_subscription.h"
#endif
#include "source_budget.h"
static SemaphoreHandle_t lock;
static SemaphoreHandle_t media_http_lock;
static standalone_config_t settings;
static c6_source_snapshot_t state;
static c6_thumbnail_cache_t thumbnails[C6_MAX_PRINTERS];
typedef struct { char path[384],task_key[17];uint64_t next,last_attempt; } thumbnail_source_t;
static thumbnail_source_t thumbnail_sources[C6_MAX_PRINTERS];
static c6_thumbnail_cache_t media_images[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
static thumbnail_source_t media_sources[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
static uint64_t media_age[C6_MAX_PRINTERS*2+C6_MAX_ENTITIES],media_clock;
static unsigned media_focus;
#if !C6_FORMLABS_ONLY
typedef struct { esp_mqtt_client_handle_t client; unsigned index,generation; char topic[96]; char *body; int used,total; } printer_client_t;
static printer_client_t printers[C6_MAX_PRINTERS];
#endif
uint64_t c6_seconds(void){return esp_timer_get_time()/1000000+1;}
void c6_sources_snapshot(c6_source_snapshot_t *out){xSemaphoreTake(lock,portMAX_DELAY);*out=state;xSemaphoreGive(lock);}
bool c6_sources_try_snapshot(c6_source_snapshot_t *out){
    if(xSemaphoreTake(lock,pdMS_TO_TICKS(20))!=pdTRUE)return false;
    *out=state;xSemaphoreGive(lock);return true;
}
bool c6_sources_weather_available(void){
    if(xSemaphoreTake(lock,pdMS_TO_TICKS(20))!=pdTRUE)return false;
    bool valid=state.weather.valid&&state.weather.latitude==settings.latitude&&state.weather.longitude==settings.longitude;
    xSemaphoreGive(lock);return valid;
}
static void printer_picture_key(unsigned i,char key[17]){
    snprintf(key,17,"%s",state.printers[i].thumbnail_key);
    if(!*key&&settings.printers[i].source_ha)c6_task_key("snapshot",*settings.printers[i].image_entity?settings.printers[i].image_entity:settings.printers[i].task_cover_entity,key);
}
static c6_thumbnail_cache_t *cache_at(unsigned i){return i<C6_MAX_PRINTERS?&thumbnails[i]:&media_images[i-C6_MAX_PRINTERS];}
static bool media_room(unsigned target){
    unsigned count=0,candidate=UINT32_MAX;uint64_t oldest=UINT64_MAX;
    if(cache_at(target)->bytes)return true;
    for(unsigned i=0;i<C6_MAX_PRINTERS*2+C6_MAX_ENTITIES;i++)if(cache_at(i)->bytes){count++;if(!(media_focus&(1U<<i))&&media_age[i]<oldest){oldest=media_age[i];candidate=i;}}
    if(count<4)return true;
    if(candidate==UINT32_MAX)return false;
    c6_thumbnail_clear(cache_at(candidate));
    if(candidate<C6_MAX_PRINTERS){state.thumbnail_status[candidate]=0;state.thumbnail_revision[candidate]++;}
    else {unsigned j=candidate-C6_MAX_PRINTERS;state.media_status[j]=0;state.media_revision[j]++;}
    return true;
}
void c6_sources_media_focus(int entity_group,int printer){
    xSemaphoreTake(lock,portMAX_DELAY);media_focus=1U<<31;
    if(entity_group>=0)media_focus=0;
    if(entity_group>=0)for(unsigned i=(unsigned)entity_group*4;i<settings.entity_count&&i<(unsigned)entity_group*4+4;i++)media_focus|=1U<<(C6_MAX_PRINTERS+i);
    if(printer>=0&&(unsigned)printer<settings.printer_count)media_focus=(1U<<printer)|(1U<<(C6_MAX_PRINTERS+C6_MAX_ENTITIES+printer));
    xSemaphoreGive(lock);
}
// A legacy serial-only request is accepted only when unambiguous. Never
// choose the first of two brands with an identical serial or display name.
static int printer_index(const char *serial,const char *brand,const char *source,unsigned *index){
    unsigned matches=0;
    for(unsigned i=0;i<settings.printer_count;i++)if(!strcmp(serial,settings.printers[i].serial)
       &&(!brand||!*brand||!strcmp(brand,c6_printer_brand(&settings.printers[i])))
       &&(!source||!*source||!strcmp(source,c6_printer_source(&settings.printers[i])))){*index=i;matches++;}
    return matches==1?200:matches?409:404;
}
static int thumbnail_target(int revision,const char *serial,const char *brand,const char *source,const char *key,unsigned *index) {
    if(revision!=settings.revision)return 409;
    unsigned i;int result=printer_index(serial,brand,source,&i);if(result!=200)return result;
    {
        if(!settings.printers[i].enabled||!c6_printer_images_enabled(&settings.printers[i]))return 403;
        char expected[17];printer_picture_key(i,expected);
        if(!c6_thumbnail_valid_key(key)||strcmp(key,expected))return 409;
        if(index)*index=i;
        return 200;
    }
    return 404;
}
int c6_sources_thumbnail_validate(int revision,const char *serial,const char *key) {
    return c6_sources_thumbnail_validate_scoped(revision,serial,NULL,NULL,key);
}
int c6_sources_thumbnail_validate_scoped(int revision,const char *serial,const char *brand,const char *source,const char *key){
    xSemaphoreTake(lock,portMAX_DELAY);int result=thumbnail_target(revision,serial,brand,source,key,NULL);xSemaphoreGive(lock);return result;
}
int c6_sources_thumbnail_store(int revision,const char *serial,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length){return c6_sources_thumbnail_store_scoped(revision,serial,NULL,NULL,key,w,h,bytes,length);}
int c6_sources_thumbnail_store_scoped(int revision,const char *serial,const char *brand,const char *source,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length) {
    if(!bytes||!w||!h||w>C6_THUMBNAIL_EDGE||h>C6_THUMBNAIL_EDGE||length!=(size_t)w*h*2)return 400;
    xSemaphoreTake(lock,portMAX_DELAY);unsigned i=0;int result=thumbnail_target(revision,serial,brand,source,key,&i);
    if(result==200){
        if(!media_room(i)){xSemaphoreGive(lock);return 503;}
        bool changed=!c6_thumbnail_matches(&thumbnails[i],serial,key)||thumbnails[i].width!=w||thumbnails[i].height!=h||length!=(size_t)w*h*2;
        if(!changed)changed=memcmp(thumbnails[i].bytes,bytes,length)!=0;
        if(c6_thumbnail_commit(&thumbnails[i],serial,key,w,h,bytes,length)){media_age[i]=++media_clock;state.thumbnail_status[i]=1;if(changed)state.thumbnail_revision[i]++;}else result=400;
    }
    xSemaphoreGive(lock);return result;
}
bool c6_sources_thumbnail_visit(const char *serial,const char *key,c6_thumbnail_visitor_t visitor,void *context) {
    bool found=false;xSemaphoreTake(lock,portMAX_DELAY);
    unsigned i;if(printer_index(serial,NULL,NULL,&i)==200&&settings.printers[i].enabled&&c6_printer_images_enabled(&settings.printers[i])&&c6_thumbnail_matches(&thumbnails[i],serial,key)) {
        if(visitor)visitor(thumbnails[i].bytes,thumbnails[i].width,thumbnails[i].height,thumbnails[i].width*2,context);
        found=true;
    }
    xSemaphoreGive(lock);return found;
}
static int media_target(int revision,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover,unsigned *index,char owner[40]){
    if(revision!=settings.revision)return 409;
    if(!c6_thumbnail_valid_key(key))return 400;
    if(entity&&*entity){
        for(unsigned i=0;i<settings.entity_count;i++)if(!strcmp(entity,settings.entities[i].id)){
            if(!settings.ha_enabled||(strncmp(entity,"camera.",7)&&strncmp(entity,"image.",6)))return 403;
            char expected[17];c6_task_key("entity",entity,expected);if(strcmp(expected,key))return 409;
            *index=i;snprintf(owner,40,"entity_%u",i);return 200;
        }return 404;
    }
    if(!cover)return 400;
    unsigned i;int result=printer_index(serial,brand,source,&i);if(result!=200)return result;
    {
        if(!settings.printers[i].enabled||!c6_printer_images_enabled(&settings.printers[i])||!settings.printers[i].source_ha||!*settings.printers[i].task_cover_entity)return 403;
        char expected[17];printer_picture_key(i,expected);if(strcmp(expected,key))return 409;
        *index=C6_MAX_ENTITIES+i;snprintf(owner,40,"cover_%u",i);return 200;
    }return 404;
}
int c6_sources_media_validate(int revision,const char *serial,const char *entity,const char *key,bool cover){
    return c6_sources_media_validate_scoped(revision,serial,NULL,NULL,entity,key,cover);
}
int c6_sources_media_validate_scoped(int revision,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover){
    unsigned i;char owner[40];xSemaphoreTake(lock,portMAX_DELAY);int result=media_target(revision,serial,brand,source,entity,key,cover,&i,owner);xSemaphoreGive(lock);return result;
}
int c6_sources_media_store(int revision,const char *serial,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length){return c6_sources_media_store_scoped(revision,serial,NULL,NULL,entity,key,cover,w,h,bytes,length);}
int c6_sources_media_store_scoped(int revision,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length){
    if(!bytes||!w||!h||w>80||h>80||length!=(size_t)w*h*2)return 400;
    unsigned i;char owner[40];xSemaphoreTake(lock,portMAX_DELAY);int result=media_target(revision,serial,brand,source,entity,key,cover,&i,owner);
    if(result==200){
        if(!media_room(C6_MAX_PRINTERS+i))result=503;
        else {c6_thumbnail_cache_t *c=&media_images[i];bool changed=!c6_thumbnail_matches(c,owner,key)||c->width!=w||c->height!=h||memcmp(c->bytes,bytes,length);
            if(c6_thumbnail_commit(c,owner,key,w,h,bytes,length)){media_age[C6_MAX_PRINTERS+i]=++media_clock;state.media_status[i]=1;if(changed)state.media_revision[i]++;}else result=400;}
    }xSemaphoreGive(lock);return result;
}
void c6_sources_entity_pictures_visit(unsigned first,unsigned count,c6_media_visitor_t visitor,void *context){
    const c6_thumbnail_cache_t *pictures[4]={0};if(count>4)count=4;
    xSemaphoreTake(lock,portMAX_DELAY);for(unsigned n=0;n<count&&first+n<settings.entity_count;n++){
        unsigned i=first+n;char key[17],owner[40];c6_task_key("entity",settings.entities[i].id,key);snprintf(owner,sizeof(owner),"entity_%u",i);
        if(c6_thumbnail_matches(&media_images[i],owner,key)){pictures[n]=&media_images[i];media_age[C6_MAX_PRINTERS+i]=++media_clock;}
    }if(visitor)visitor(pictures,count,context);xSemaphoreGive(lock);
}
void c6_sources_printer_pictures_visit(const char *serial,const char *key,c6_media_visitor_t visitor,void *context){
    c6_sources_printer_pictures_visit_scoped(serial,NULL,NULL,key,visitor,context);
}
void c6_sources_printer_pictures_visit_scoped(const char *serial,const char *brand,const char *source,const char *key,c6_media_visitor_t visitor,void *context){
    const c6_thumbnail_cache_t *pictures[2]={0};xSemaphoreTake(lock,portMAX_DELAY);
    unsigned i;if(printer_index(serial,brand,source,&i)==200&&settings.printers[i].enabled&&c6_printer_images_enabled(&settings.printers[i])){
        char expected[17];printer_picture_key(i,expected);if(!strcmp(expected,key)){
        if(c6_thumbnail_matches(&thumbnails[i],serial,key)){pictures[0]=&thumbnails[i];media_age[i]=++media_clock;}
        char owner[40];snprintf(owner,sizeof(owner),"cover_%u",i);unsigned k=C6_MAX_ENTITIES+i;
        if(c6_thumbnail_matches(&media_images[k],owner,key)){pictures[1]=&media_images[k];media_age[C6_MAX_PRINTERS+k]=++media_clock;}}
    }if(visitor)visitor(pictures,2,context);xSemaphoreGive(lock);
}
void c6_sources_reconfigure(void) {
    if(!lock)return;
    xSemaphoreTake(lock,portMAX_DELAY);
    // Preserve cached states and the original completion window across display-only edits.
#if C6_FORMLABS_ONLY
    bool same_sources=settings.enabled==standalone_config.enabled&&settings.weather==standalone_config.weather&&
        settings.latitude==standalone_config.latitude&&settings.longitude==standalone_config.longitude&&
        settings.weather_minutes==standalone_config.weather_minutes&&settings.printer_count==standalone_config.printer_count;
    for(unsigned i=0;same_sources&&i<settings.printer_count;i++){
        const c6_printer_config_t *a=&settings.printers[i],*b=&standalone_config.printers[i];
        same_sources=a->enabled==b->enabled&&a->source_formlabs==b->source_formlabs&&c6_printer_images_enabled(a)==c6_printer_images_enabled(b)&&
            !strcmp(a->serial,b->serial)&&!strcmp(a->form_client_id,b->form_client_id)&&!strcmp(a->form_client_secret,b->form_client_secret);
    }
    if(same_sources){settings=standalone_config;xSemaphoreGive(lock);return;}
#endif
    c6_entity_state_t entities[C6_MAX_ENTITIES]={0};c6_printer_state_t previous[C6_MAX_PRINTERS]={0};
    c6_thumbnail_cache_t images[C6_MAX_PRINTERS]={0};thumbnail_source_t image_sources[C6_MAX_PRINTERS]={0};unsigned image_status[C6_MAX_PRINTERS]={0};uint32_t image_revision[C6_MAX_PRINTERS]={0};
    const bool same_ha=!strcmp(standalone_config.ha_host,settings.ha_host)&&standalone_config.ha_port==settings.ha_port&&standalone_config.ha_tls==settings.ha_tls&&!strcmp(standalone_config.ha_token,settings.ha_token);
    // Serialized by lock. Avoid adding ~5KB to the HTTP owner's 8KB stack.
    static c6_thumbnail_cache_t extra[C6_MAX_ENTITIES+C6_MAX_PRINTERS];static thumbnail_source_t extra_sources[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
    unsigned extra_status[C6_MAX_ENTITIES+C6_MAX_PRINTERS]={0};uint32_t extra_revision[C6_MAX_ENTITIES+C6_MAX_PRINTERS]={0};
    memset(extra,0,sizeof(extra));memset(extra_sources,0,sizeof(extra_sources));
    for(unsigned i=0;i<standalone_config.entity_count;i++)for(unsigned k=0;k<settings.entity_count;k++)
        if(same_ha&&!strcmp(standalone_config.entities[i].id,settings.entities[k].id)){
            entities[i]=state.entities[k];extra[i]=media_images[k];memset(&media_images[k],0,sizeof(media_images[k]));
            if(extra[i].bytes)snprintf(extra[i].serial,sizeof(extra[i].serial),"entity_%u",i);
            extra_sources[i]=media_sources[k];extra_status[i]=state.media_status[k];extra_revision[i]=state.media_revision[k];
        }
    for(unsigned i=0;i<standalone_config.printer_count;i++)for(unsigned k=0;k<settings.printer_count;k++) {
        const c6_printer_config_t *a=&standalone_config.printers[i],*b=&settings.printers[k];
        bool ha_same=!a->source_ha||same_ha;
        bool form_same=a->source_formlabs==b->source_formlabs&&(!a->source_formlabs||(!strcmp(a->form_client_id,b->form_client_id)&&!strcmp(a->form_client_secret,b->form_client_secret)));
        bool mqtt_same=a->source_ha||a->source_formlabs||(!strcmp(a->access_code,b->access_code)&&a->trust_lan==b->trust_lan&&!strcmp(a->certificate,b->certificate));
        if(ha_same&&form_same&&mqtt_same&&a->source_ha==b->source_ha&&!strcmp(a->serial,b->serial)&&!strcmp(a->host,b->host)&&!strcmp(a->status_entity,b->status_entity)) {
            previous[i]=state.printers[k];
            if(c6_printer_images_enabled(a)&&a->live_image==b->live_image&&!strcmp(a->image_entity,b->image_entity)&&!strcmp(a->task_entity,b->task_entity)) {
                images[i]=thumbnails[k];memset(&thumbnails[k],0,sizeof(thumbnails[k]));
                image_sources[i]=thumbnail_sources[k];image_status[i]=state.thumbnail_status[k];image_revision[i]=state.thumbnail_revision[k];
            }
            if(same_ha&&c6_printer_images_enabled(a)&&!strcmp(a->task_cover_entity,b->task_cover_entity)&&!strcmp(a->task_entity,b->task_entity)){
                unsigned x=C6_MAX_ENTITIES+i,y=C6_MAX_ENTITIES+k;extra[x]=media_images[y];memset(&media_images[y],0,sizeof(media_images[y]));
                if(extra[x].bytes)snprintf(extra[x].serial,sizeof(extra[x].serial),"cover_%u",i);
                extra_sources[x]=media_sources[y];extra_status[x]=state.media_status[y];extra_revision[x]=state.media_revision[y];
            }
        }
    }
    for(unsigned i=0;i<C6_MAX_PRINTERS;i++)c6_thumbnail_clear(&thumbnails[i]);
    memcpy(thumbnails,images,sizeof(images));memcpy(thumbnail_sources,image_sources,sizeof(image_sources));memcpy(state.thumbnail_status,image_status,sizeof(image_status));
    memcpy(state.thumbnail_revision,image_revision,sizeof(image_revision));
    for(unsigned i=0;i<C6_MAX_ENTITIES+C6_MAX_PRINTERS;i++)c6_thumbnail_clear(&media_images[i]);
    memcpy(media_images,extra,sizeof(extra));memcpy(media_sources,extra_sources,sizeof(extra_sources));
    memcpy(state.media_status,extra_status,sizeof(extra_status));memcpy(state.media_revision,extra_revision,sizeof(extra_revision));media_focus=0;
    if(settings.latitude!=standalone_config.latitude||settings.longitude!=standalone_config.longitude)memset(&state.weather,0,sizeof(state.weather));
    settings=standalone_config;memcpy(state.entities,entities,sizeof(entities));memcpy(state.printers,previous,sizeof(previous));
#if C6_FORMLABS_ONLY
    for(unsigned i=0;i<C6_MAX_PRINTERS;i++){
        state.form_phase[i]=0;
        if(i<settings.printer_count&&c6_form_demo_seed(&settings.printers[i],&state.printers[i]))state.form_phase[i]=5;
    }
#endif
    state.ha_connected=false;state.generation++;xSemaphoreGive(lock);
}
void c6_sources_display_options(int revision,bool flip_animation){
    // Keep media CAS aligned after a device-owned display change. Do not restart
    // HA/MQTT workers or discard their cached states for a clock preference.
    xSemaphoreTake(lock,portMAX_DELAY);settings.revision=revision;settings.flip_animation=flip_animation;xSemaphoreGive(lock);
}
#if !C6_FORMLABS_ONLY
static unsigned config_copy(standalone_config_t *out){xSemaphoreTake(lock,portMAX_DELAY);*out=settings;unsigned g=state.generation;xSemaphoreGive(lock);return g;}
static unsigned ha_config_copy(c6_ha_config_t *out){xSemaphoreTake(lock,portMAX_DELAY);c6_ha_project(&settings,out);unsigned g=state.generation;xSemaphoreGive(lock);return g;}
#endif
static bool runtime_enabled(unsigned work){xSemaphoreTake(lock,portMAX_DELAY);bool needed=c6_source_needed(&settings,work);xSemaphoreGive(lock);return needed;}
static bool http_budget(bool tls){return c6_http_budget(tls,esp_get_free_heap_size(),heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));}
static bool current(unsigned generation){xSemaphoreTake(lock,portMAX_DELAY);bool same=state.generation==generation;xSemaphoreGive(lock);return same;}
#if !C6_FORMLABS_ONLY
static void entity_update(cJSON *j,unsigned generation) {
    cJSON *id=cJSON_GetObjectItemCaseSensitive(j,"entity_id"),*value=cJSON_GetObjectItemCaseSensitive(j,"state");
    if(!cJSON_IsString(id)||!cJSON_IsString(value))return;
    xSemaphoreTake(lock,portMAX_DELAY);
    if(state.generation==generation)for(unsigned i=0;i<settings.entity_count;i++)if(!strcmp(settings.entities[i].id,id->valuestring)) {
        c6_entity_state_t *e=&state.entities[i];snprintf(e->state,sizeof(e->state),"%s",value->valuestring);
        cJSON *attrs=cJSON_GetObjectItemCaseSensitive(j,"attributes"),*name=cJSON_GetObjectItemCaseSensitive(attrs,"friendly_name"),*unit=cJSON_GetObjectItemCaseSensitive(attrs,"unit_of_measurement");
        snprintf(e->name,sizeof(e->name),"%s",*settings.entities[i].name?settings.entities[i].name:cJSON_IsString(name)?name->valuestring:id->valuestring);
        snprintf(e->unit,sizeof(e->unit),"%s",cJSON_IsString(unit)?unit->valuestring:"");
        e->available=strcmp(e->state,"unavailable")&&strcmp(e->state,"unknown");e->updated=c6_seconds();break;
    }
    if(state.generation==generation)for(unsigned i=0;i<settings.printer_count;i++)if(settings.printers[i].enabled&&settings.printers[i].source_ha) {
        const c6_printer_config_t *p=&settings.printers[i];cJSON *data=cJSON_CreateObject();bool matched=false;
        if(!strcmp(p->status_entity,id->valuestring)){cJSON_AddStringToObject(data,"gcode_state",value->valuestring);matched=true;}
        if(!strcmp(p->task_entity,id->valuestring)) {
            char key[17];c6_task_key("ha",value->valuestring,key);
            cJSON_AddStringToObject(data,"subtask_name",value->valuestring);cJSON_AddStringToObject(data,"task_id",value->valuestring);
            cJSON_AddStringToObject(data,"thumbnail_key",key);
            if(strcmp(key,state.printers[i].thumbnail_key)){
                c6_thumbnail_clear(&thumbnails[i]);memset(&thumbnail_sources[i],0,sizeof(thumbnail_sources[i]));state.thumbnail_status[i]=0;state.thumbnail_revision[i]++;
                unsigned k=C6_MAX_ENTITIES+i;c6_thumbnail_clear(&media_images[k]);media_sources[k].next=0;state.media_status[k]=0;state.media_revision[k]++;
            }
            matched=true;
        }
        if(c6_printer_images_enabled(p)&&!strncmp(p->image_entity,"image.",6)&&!strcmp(p->image_entity,id->valuestring)) {
            cJSON *picture=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(j,"attributes"),"entity_picture");
            char path[384]={0};if(cJSON_IsString(picture)&&strlen(picture->valuestring)<sizeof(path))snprintf(path,sizeof(path),"%s",picture->valuestring);
            thumbnail_source_t *source=&thumbnail_sources[i];
            if(strcmp(path,source->path)||strcmp(source->task_key,state.printers[i].thumbnail_key)) {
                if(!p->live_image&&*source->path&&*path&&strcmp(path,source->path)){c6_thumbnail_clear(&thumbnails[i]);state.thumbnail_status[i]=0;}
                snprintf(source->path,sizeof(source->path),"%s",path);snprintf(source->task_key,sizeof(source->task_key),"%s",state.printers[i].thumbnail_key);
                source->next=source->last_attempt?source->last_attempt+(p->live_image?15:60):0;
            }
        }
        const char *fields[]={p->progress_entity,p->remaining_entity},*keys[]={"mc_percent","mc_remaining_time"};
        for(unsigned k=0;k<2;k++)if(!strcmp(fields[k],id->valuestring)){char *end;double v=strtod(value->valuestring,&end);if(end!=value->valuestring&&!*end&&isfinite(v))cJSON_AddNumberToObject(data,keys[k],v);else cJSON_AddNullToObject(data,keys[k]);matched=true;}
        const char *details[]={p->nozzle_entity,p->bed_entity,p->error_entity,p->end_time_entity},*detail_keys[]={"nozzle_temper","bed_temper","print_error","end_time"};
        for(unsigned k=0;k<4;k++)if(*details[k]&&!strcmp(details[k],id->valuestring)){cJSON_AddStringToObject(data,detail_keys[k],value->valuestring);matched=true;}
        if(matched){c6_print_update(&state.printers[i],data,c6_seconds());state.printers[i].connected=state.ha_connected;}
        cJSON_Delete(data);
    }
    if(state.generation==generation){
        cJSON *picture=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(j,"attributes"),"entity_picture");
        for(unsigned k=0;k<C6_MAX_ENTITIES+C6_MAX_PRINTERS;k++){
            const char *entity=k<C6_MAX_ENTITIES?(k<settings.entity_count?settings.entities[k].id:""):(k-C6_MAX_ENTITIES<settings.printer_count?settings.printers[k-C6_MAX_ENTITIES].task_cover_entity:"");
            if(!*entity||strcmp(entity,id->valuestring)||strncmp(entity,"image.",6))continue;
            const char *path=cJSON_IsString(picture)&&strlen(picture->valuestring)<sizeof(media_sources[k].path)?picture->valuestring:"";
            if(strcmp(path,media_sources[k].path)){
                snprintf(media_sources[k].path,sizeof(media_sources[k].path),"%s",path);media_sources[k].next=0;
                c6_thumbnail_clear(&media_images[k]);state.media_status[k]=0;state.media_revision[k]++;
            }
        }
    }
    xSemaphoreGive(lock);
}
static bool initial_state(const c6_ha_config_t *c,unsigned g,char *body,unsigned *index,uint64_t *pending) {
    char auth[1050];snprintf(auth,sizeof(auth),"Bearer %s",c->ha_token);
    const char *ids[C6_MAX_ENTITIES+C6_MAX_PRINTERS*10];unsigned count=ha_ids(c,ids);
    // Prime one selected entity per socket-read cycle, not up to 33 blocking REST calls.
    // This keeps the subscription alive and makes the first restored state visible promptly.
    while(*index<count&&!(*pending&(UINT64_C(1)<<*index)))(*index)++;
    if(*index<count&&current(g)) {
        unsigned i=(*index)++;bool received=false;
        char url[200];snprintf(url,sizeof(url),"%s://%s:%d/api/states/%s",c->ha_tls?"https":"http",c->ha_host,c->ha_port,ids[i]);
        esp_http_client_config_t cfg={.url=url,.timeout_ms=4000,.buffer_size=1024,.crt_bundle_attach=c->ha_tls?esp_crt_bundle_attach:NULL,.disable_auto_redirect=true};
        esp_http_client_handle_t h=esp_http_client_init(&cfg);
        if(h) {
            esp_http_client_set_header(h,"Authorization",auth);
            if(esp_http_client_open(h,0)==ESP_OK) {
                esp_http_client_fetch_headers(h);int used=0,n;
                while(used<MESSAGE_LIMIT-1&&(n=esp_http_client_read(h,body+used,MESSAGE_LIMIT-1-used))>0)used+=n;
                body[used]=0;
                if(esp_http_client_get_status_code(h)==200&&esp_http_client_is_complete_data_received(h)) {
                    cJSON *j=cJSON_Parse(body),*id=cJSON_GetObjectItemCaseSensitive(j,"entity_id"),*value=cJSON_GetObjectItemCaseSensitive(j,"state");
                    received=cJSON_IsString(id)&&!strcmp(id->valuestring,ids[i])&&cJSON_IsString(value);
                    if(received)entity_update(j,g);
                    cJSON_Delete(j);
                }else if(esp_http_client_get_status_code(h)==404) {
                    cJSON *j=cJSON_CreateObject();cJSON_AddStringToObject(j,"entity_id",ids[i]);cJSON_AddStringToObject(j,"state","unavailable");entity_update(j,g);cJSON_Delete(j);received=true;
                }
                esp_http_client_close(h);
            }
            esp_http_client_cleanup(h);
        }
        if(received)*pending&=~(UINT64_C(1)<<i);
    }
    memset(auth,0,sizeof(auth));
    if(*index>=count){*index=0;return true;}
    return false;
}
static bool ws_send(esp_transport_handle_t ws,cJSON *j) {
    char *text=cJSON_PrintUnformatted(j);if(!text)return false;
    int size=strlen(text),sent=esp_transport_ws_send_raw(ws,WS_TRANSPORT_OPCODES_TEXT|WS_TRANSPORT_OPCODES_FIN,text,size,3000);
    memset(text,0,size);cJSON_free(text);return sent==size;
}
// Handles split socket reads and WebSocket continuations without unbounded buffers.
static int ws_receive(esp_transport_handle_t ws,char *out,unsigned g) {
    int used=0;
    while(current(g)) {
        int n=esp_transport_read(ws,out+used,MESSAGE_LIMIT-1-used,1000);
        if(n<0)return -1;
        if(!n){if(!used)return 0;continue;}
        int op=esp_transport_ws_get_read_opcode(ws)&0x7f;
        if(op==WS_TRANSPORT_OPCODES_CLOSE)return -1;
        if(op!=WS_TRANSPORT_OPCODES_TEXT&&op!=WS_TRANSPORT_OPCODES_CONT)continue;
        int total=esp_transport_ws_get_read_payload_len(ws),read=n;
        used+=n;
        if(total>MESSAGE_LIMIT-1-used+n)return -1;
        while(read<total) {
            n=esp_transport_read(ws,out+used,MESSAGE_LIMIT-1-used,3000);if(n<=0)return -1;
            used+=n;read+=n;
        }
        if(used>=MESSAGE_LIMIT-1)return -1;
        if(esp_transport_ws_get_fin_flag(ws)){out[used]=0;return used;}
    }
    return -1;
}
// This common DHCP gate is also needed by Formlabs and weather.
#endif
static bool ha_network_ready(void) {
    esp_netif_t *station=esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");esp_netif_ip_info_t ip={0};
    return station&&esp_netif_is_netif_up(station)&&esp_netif_get_ip_info(station,&ip)==ESP_OK&&ip.ip.addr!=0;
}
#if !C6_FORMLABS_ONLY
static void ha_phase(unsigned phase,unsigned generation) {
    xSemaphoreTake(lock,portMAX_DELAY);if(!generation||state.generation==generation)state.ha_phase=phase;xSemaphoreGive(lock);
}
static void ha_task(void *arg) {
    c6_ha_config_t *c=NULL;char *body=NULL;
    unsigned delay=2;
    for(;;) {
        if(!runtime_enabled(C6_WORK_HA)){
            if(c){memset(c,0,sizeof(*c));free(c);c=NULL;}free(body);body=NULL;
            ha_phase(0,0);delay=2;vTaskDelay(pdMS_TO_TICKS(1000));continue;
        }
        if(!ha_network_ready()){ha_phase(1,0);delay=2;vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!c)c=malloc(sizeof(*c));
        if(!body)body=malloc(MESSAGE_LIMIT);
        if(!c||!body){if(c){memset(c,0,sizeof(*c));free(c);}free(body);c=NULL;body=NULL;ha_phase(9,0);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        unsigned g=ha_config_copy(c);
        const char *selected[C6_MAX_ENTITIES+C6_MAX_PRINTERS*10];
        if(!ha_ids(c,selected)){ha_phase(0,g);delay=2;vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        // An RST boot starts this task before DHCP. Do not count that as a failed HA attempt.
        if(!ha_network_ready()){ha_phase(1,g);delay=2;vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        ha_phase(2,g);
        esp_transport_handle_t parent=c->ha_tls?esp_transport_ssl_init():esp_transport_tcp_init();
        if(!parent){ha_phase(9,g);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        if(c->ha_tls)esp_transport_ssl_crt_bundle_attach(parent,esp_crt_bundle_attach);
        esp_transport_handle_t ws=esp_transport_ws_init(parent);
        if(!ws){esp_transport_destroy(parent);ha_phase(9,g);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        esp_transport_ws_set_path(ws,"/api/websocket");
        bool authenticated=false,subscribed=false,ok=esp_transport_connect(ws,c->ha_host,c->ha_port,5000)==0;
        uint64_t last_reply=c6_seconds(),last_ping=last_reply;
        if(ok)ha_phase(3,g);
        unsigned failure_phase=6,prime_index=0;uint64_t prime_pending=0,prime_after=0;
        while(ok&&current(g)) {
            if(subscribed&&prime_pending&&c6_seconds()>=prime_after) {
                if(initial_state(c,g,body,&prime_index,&prime_pending))prime_after=c6_seconds()+30;
            }
            if(c6_seconds()-last_ping>=20){cJSON *ping=cJSON_CreateObject();cJSON_AddStringToObject(ping,"type","ping");cJSON_AddNumberToObject(ping,"id",99);ok=ws_send(ws,ping);cJSON_Delete(ping);last_ping=c6_seconds();if(!ok)break;}
            int n=ws_receive(ws,body,g);if(n<0)break;
            if(!n) {
                if(c6_seconds()-last_reply>60)break;
                continue;
            }
            last_reply=c6_seconds();cJSON *j=cJSON_Parse(body),*type=cJSON_GetObjectItemCaseSensitive(j,"type");
            if(cJSON_IsString(type)&&!strcmp(type->valuestring,"auth_required")) {
                cJSON *auth=cJSON_CreateObject();cJSON_AddStringToObject(auth,"type","auth");cJSON_AddStringToObject(auth,"access_token",c->ha_token);ok=ws_send(ws,auth);cJSON_Delete(auth);
            }else if(cJSON_IsString(type)&&!strcmp(type->valuestring,"auth_invalid")){ok=false;failure_phase=7;}
            else if(cJSON_IsString(type)&&!strcmp(type->valuestring,"auth_ok")) {
                ha_phase(4,g);
                authenticated=true;cJSON *sub=cJSON_CreateObject();cJSON_AddNumberToObject(sub,"id",1);cJSON_AddStringToObject(sub,"type","subscribe_trigger");
                cJSON *trigger=cJSON_AddObjectToObject(sub,"trigger");cJSON_AddStringToObject(trigger,"platform","state");cJSON *ids=cJSON_AddArrayToObject(trigger,"entity_id");
                const char *selected[C6_MAX_ENTITIES+C6_MAX_PRINTERS*10];unsigned count=ha_ids(c,selected);
                for(unsigned i=0;i<count;i++)cJSON_AddItemToArray(ids,cJSON_CreateString(selected[i]));
                ok=ws_send(ws,sub);cJSON_Delete(sub);
            }else if(authenticated&&cJSON_IsString(type)&&!strcmp(type->valuestring,"result")&&cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(j,"id"))&&cJSON_GetObjectItemCaseSensitive(j,"id")->valueint==1) {
                subscribed=cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(j,"success"));ok=subscribed;
                if(subscribed){xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==g){state.ha_connected=true;state.ha_phase=5;}xSemaphoreGive(lock);delay=2;prime_index=0;prime_after=0;prime_pending=(UINT64_C(1)<<ha_ids(c,selected))-1;}
                else failure_phase=8;
            }else if(subscribed&&cJSON_IsString(type)&&!strcmp(type->valuestring,"event")) {
                cJSON *e=cJSON_GetObjectItemCaseSensitive(j,"event"),*vars=cJSON_GetObjectItemCaseSensitive(e,"variables"),*t=cJSON_GetObjectItemCaseSensitive(vars,"trigger"),*next=cJSON_GetObjectItemCaseSensitive(t,"to_state");
                if(cJSON_IsNull(next)) {
                    cJSON *id=cJSON_GetObjectItemCaseSensitive(t,"entity_id");
                    if(cJSON_IsString(id)){cJSON *missing=cJSON_CreateObject();cJSON_AddStringToObject(missing,"entity_id",id->valuestring);cJSON_AddStringToObject(missing,"state","unavailable");entity_update(missing,g);cJSON_Delete(missing);}
                }else entity_update(next,g);
            }
            cJSON_Delete(j);
        }
        esp_transport_close(ws);esp_transport_destroy(ws);esp_transport_destroy(parent);
        ha_phase(ha_network_ready()?failure_phase:1,g);
        xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==g){state.ha_connected=false;for(unsigned i=0;i<settings.printer_count;i++)if(settings.printers[i].source_ha)state.printers[i].connected=false;}state.ha_reconnects++;xSemaphoreGive(lock);
        for(unsigned i=0;i<delay&&current(g)&&ha_network_ready();i++)vTaskDelay(pdMS_TO_TICKS(1000));
        if(delay<60)delay=delay*2>60?60:delay*2;
    }
}
static void mqtt_event(void *arg,esp_event_base_t base,int32_t id,void *data) {
    printer_client_t *p=arg;esp_mqtt_event_handle_t e=data;
    if(!current(p->generation))return;
    if(id==MQTT_EVENT_CONNECTED) {
        esp_mqtt_client_subscribe(p->client,p->topic,0);
        xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==p->generation)state.printers[p->index].connected=true;xSemaphoreGive(lock);
    }else if(id==MQTT_EVENT_SUBSCRIBED) {
        char topic[96],serial[40];xSemaphoreTake(lock,portMAX_DELAY);
        bool same=state.generation==p->generation;if(same)snprintf(serial,sizeof(serial),"%s",settings.printers[p->index].serial);xSemaphoreGive(lock);if(!same)return;
        snprintf(topic,sizeof(topic),"device/%s/request",serial);
        // Read-only initial state request; no print/control command is sent.
        esp_mqtt_client_publish(p->client,topic,"{\"pushing\":{\"sequence_id\":\"0\",\"command\":\"pushall\",\"version\":1,\"push_target\":1}}",0,0,0);
    }else if(id==MQTT_EVENT_DISCONNECTED||id==MQTT_EVENT_ERROR) {
        xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==p->generation){state.printers[p->index].connected=false;if(id==MQTT_EVENT_DISCONNECTED)state.mqtt_reconnects++;}xSemaphoreGive(lock);
    }else if(id==MQTT_EVENT_DATA) {
        if(e->current_data_offset==0) {
            free(p->body);p->body=NULL;p->used=0;p->total=0;
            if(e->total_data_len<=0||e->total_data_len>=MESSAGE_LIMIT||e->topic_len!=(int)strlen(p->topic)||memcmp(e->topic,p->topic,e->topic_len)) {
                xSemaphoreTake(lock,portMAX_DELAY);state.dropped_messages++;xSemaphoreGive(lock);return;
            }
            p->total=e->total_data_len;p->body=calloc(1,p->total+1);
        }
        if(!p->body||e->current_data_offset!=p->used||e->data_len>p->total-p->used){free(p->body);p->body=NULL;return;}
        memcpy(p->body+p->used,e->data,e->data_len);p->used+=e->data_len;
        if(p->used==p->total) {
            cJSON *j=cJSON_Parse(p->body);free(p->body);p->body=NULL;
            xSemaphoreTake(lock,portMAX_DELAY);
            if(state.generation==p->generation) {
                char previous_key[17];snprintf(previous_key,sizeof(previous_key),"%s",state.printers[p->index].thumbnail_key);
                cJSON *payload=cJSON_GetObjectItemCaseSensitive(j,"print");cJSON_DeleteItemFromObjectCaseSensitive(payload,"thumbnail_key");
                c6_print_update(&state.printers[p->index],payload,c6_seconds());
                if(strcmp(previous_key,state.printers[p->index].thumbnail_key)){c6_thumbnail_clear(&thumbnails[p->index]);state.thumbnail_status[p->index]=0;}
            }
            xSemaphoreGive(lock);cJSON_Delete(j);
        }
    }
}
static void mqtt_task(void *arg) {
    standalone_config_t *c=NULL;unsigned g=0;
    for(;;) {
        if(!runtime_enabled(C6_WORK_MQTT)){
            for(unsigned i=0;i<C6_MAX_PRINTERS;i++){if(printers[i].client)esp_mqtt_client_destroy(printers[i].client);free(printers[i].body);memset(&printers[i],0,sizeof(printers[i]));}
            if(c){memset(c,0,sizeof(*c));free(c);c=NULL;}g=0;vTaskDelay(pdMS_TO_TICKS(1000));continue;
        }
        if(!ha_network_ready()){vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!c){c=malloc(sizeof(*c));if(!c){vTaskDelay(pdMS_TO_TICKS(5000));continue;}}
        if(!current(g)) {
            for(unsigned i=0;i<C6_MAX_PRINTERS;i++){if(printers[i].client)esp_mqtt_client_destroy(printers[i].client);free(printers[i].body);memset(&printers[i],0,sizeof(printers[i]));}
            g=config_copy(c);
            for(unsigned i=0;c->enabled&&i<c->printer_count;i++) {
                c6_printer_config_t *v=&c->printers[i];if(!v->enabled||v->source_ha||v->source_formlabs)continue;
                printer_client_t *p=&printers[i];p->index=i;p->generation=g;snprintf(p->topic,sizeof(p->topic),"device/%s/report",v->serial);
                esp_mqtt_client_config_t cfg={.broker.address.hostname=v->host,.broker.address.port=8883,.broker.address.transport=MQTT_TRANSPORT_OVER_SSL,
                    .credentials.username="bblp",.credentials.authentication.password=v->access_code,
                    .broker.verification.certificate=*v->certificate?v->certificate:NULL,.broker.verification.skip_cert_common_name_check=true,
                    .session.keepalive=30,.network.reconnect_timeout_ms=15000,.network.timeout_ms=5000,.buffer.size=2048,.task.stack_size=6144};
                p->client=esp_mqtt_client_init(&cfg);if(p->client){esp_mqtt_client_register_event(p->client,ESP_EVENT_ANY_ID,mqtt_event,p);esp_mqtt_client_start(p->client);}
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
#endif
typedef struct {
    esp_http_client_handle_t client;
    unsigned used,scaled_width,scaled_height,width,height,left,top;
    uint8_t *pixels;
    int64_t deadline;
    uint8_t prefix[8];unsigned prefix_used,prefix_size;
} jpeg_stream_t;
// ROM TJpgDec reads a bounded stream; no full JPEG or full-resolution RGB buffer.
static UINT jpeg_input(JDEC *decoder,BYTE *out,UINT count) {
    jpeg_stream_t *s=decoder->device;unsigned done=0;uint8_t skip[64];
    if(s->used+count>131072||esp_timer_get_time()>s->deadline)return 0;
    while(done<count) {
        unsigned chunk=count-done;if(!out&&chunk>sizeof(skip))chunk=sizeof(skip);
        if(s->prefix_used<s->prefix_size){unsigned n=s->prefix_size-s->prefix_used;if(n>chunk)n=chunk;if(out)memcpy(out+done,s->prefix+s->prefix_used,n);s->prefix_used+=n;done+=n;continue;}
        int n=esp_http_client_read(s->client,(char*)(out?out+done:skip),chunk);
        if(n<=0)break;
        done+=n;s->used+=n;
        if(esp_timer_get_time()>s->deadline)break;
    }
    return done;
}
static size_t image_input(void *context,uint8_t *out,size_t count){JDEC decoder={.device=context};return jpeg_input(&decoder,out,(UINT)count);}
static UINT jpeg_output(JDEC *decoder,void *bitmap,JRECT *rect) {
    jpeg_stream_t *s=decoder->device;
    if(esp_timer_get_time()>s->deadline)return 0;
    return c6_thumbnail_rgb_block(s->pixels,s->scaled_width,s->scaled_height,rect->left,rect->top,rect->right,rect->bottom,bitmap)?1:0;
}
static unsigned thumbnail_fetch(const char *url,const char *token,bool tls,uint8_t **pixels,unsigned *width,unsigned *height) {
    unsigned status=4;*pixels=NULL;*width=*height=0;
    // Let the existing HA/MQTT TLS sessions win instead of increasing heap pressure.
    if(!http_budget(tls))return status;
    esp_http_client_config_t cfg={.url=url,.timeout_ms=4000,.buffer_size=512,
        .crt_bundle_attach=tls?esp_crt_bundle_attach:NULL,.disable_auto_redirect=true};
    esp_http_client_handle_t client=esp_http_client_init(&cfg);if(!client)return status;
    char auth[1050];if(token&&*token){snprintf(auth,sizeof(auth),"Bearer %s",token);esp_http_client_set_header(client,"Authorization",auth);}memset(auth,0,sizeof(auth));
    if(esp_http_client_open(client,0)==ESP_OK) {
        int64_t length=esp_http_client_fetch_headers(client);
        if(esp_http_client_get_status_code(client)==200) {
            if(length>131072)status=3;
            else {
                void *work=NULL;uint8_t *image=calloc(1,C6_THUMBNAIL_BYTES);
                if(image) {
                    JDEC decoder={0};jpeg_stream_t stream={.client=client,.pixels=image,.deadline=esp_timer_get_time()+6000000};
                    uint8_t signature[8];size_t prefix=image_input(&stream,signature,8);memcpy(stream.prefix,signature,prefix);stream.prefix_size=prefix;
                    if(prefix==8&&!memcmp(signature,"\211PNG\r\n\032\n",8)){
                        if(esp_get_free_heap_size()>=65000){unsigned w,h;if(c6_png_thumbnail(image_input,&stream,image,&w,&h)&&esp_timer_get_time()<=stream.deadline){*pixels=image;*width=w;*height=h;image=NULL;status=1;}else status=2;}
                    }else if((work=malloc(4096))){
                    JRESULT result=jd_prepare(&decoder,jpeg_input,work,4096,&stream);
                    if(result==JDR_OK&&decoder.width&&decoder.height) {
                        if(decoder.width>2048||decoder.height>2048)status=3;
                        else {
                            BYTE scale=0;while(scale<3&&(decoder.width>>(scale+1))>=C6_THUMBNAIL_EDGE&&(decoder.height>>(scale+1))>=C6_THUMBNAIL_EDGE)scale++;
                            stream.scaled_width=(decoder.width+(1U<<scale)-1)>>scale;stream.scaled_height=(decoder.height+(1U<<scale)-1)>>scale;
                            if(stream.scaled_width>=stream.scaled_height){stream.width=C6_THUMBNAIL_EDGE;stream.height=(stream.scaled_height*C6_THUMBNAIL_EDGE)/stream.scaled_width;}
                            else {stream.height=C6_THUMBNAIL_EDGE;stream.width=(stream.scaled_width*C6_THUMBNAIL_EDGE)/stream.scaled_height;}
                            if(!stream.width)stream.width=1;
                            if(!stream.height)stream.height=1;
                            stream.left=(C6_THUMBNAIL_EDGE-stream.width)/2;stream.top=(C6_THUMBNAIL_EDGE-stream.height)/2;
                            result=jd_decomp(&decoder,jpeg_output,scale);
                            if(result==JDR_OK){
                                // Keep source aspect ratio, not baked-in square letterboxing.
                                for(unsigned y=0;y<stream.height;y++)memmove(image+y*stream.width*2,image+((y+stream.top)*80+stream.left)*2,stream.width*2);
                                *pixels=image;*width=stream.width;*height=stream.height;image=NULL;status=1;
                            }
                            else status=(result==JDR_FMT1||result==JDR_FMT2||result==JDR_FMT3)?2:4;
                        }
                    }else status=(result==JDR_FMT1||result==JDR_FMT2||result==JDR_FMT3)?2:4;
                    }
                }
                free(image);free(work);
            }
        }
        esp_http_client_close(client);
    }
    esp_http_client_cleanup(client);return status;
}
#if !C6_FORMLABS_ONLY
typedef struct { char url[512],token[1024],serial[40],key[17];bool tls;unsigned generation;int revision; } thumbnail_request_t;
static void thumbnail_task(void *arg) {
    thumbnail_request_t *request=NULL;
    for(;;) {
        if(!runtime_enabled(C6_WORK_MEDIA)){if(request){memset(request,0,sizeof(*request));free(request);request=NULL;}vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!ha_network_ready()){vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!request){request=calloc(1,sizeof(*request));if(!request){vTaskDelay(pdMS_TO_TICKS(5000));continue;}}
        for(unsigned i=0;i<C6_MAX_PRINTERS;i++) {
            bool fetch=false;xSemaphoreTake(lock,portMAX_DELAY);
            if(i<settings.printer_count&&settings.enabled&&settings.ha_enabled) {
                const c6_printer_config_t *p=&settings.printers[i];thumbnail_source_t *source=&thumbnail_sources[i];
                bool camera=!strncmp(p->image_entity,"camera.",7);
                bool live=camera||p->live_image;
                char expected[17];printer_picture_key(i,expected);
                if(strcmp(source->task_key,expected)){snprintf(source->task_key,sizeof(source->task_key),"%s",expected);source->next=0;}
                if(p->enabled&&p->source_ha&&c6_printer_images_enabled(p)&&*p->image_entity&&(camera||*source->path)&&*source->task_key
                   &&(!media_focus||(media_focus&(1U<<i)))&&c6_thumbnail_due(live,c6_thumbnail_matches(&thumbnails[i],p->serial,source->task_key),c6_seconds(),source->next)) {
                    source->last_attempt=c6_seconds();source->next=source->last_attempt+(live?15:300);
                    {
                        fetch=camera?c6_camera_snapshot_url(settings.ha_host,settings.ha_port,settings.ha_tls,p->image_entity,request->url,sizeof(request->url)):c6_thumbnail_url(settings.ha_host,settings.ha_port,settings.ha_tls,source->path,request->url,sizeof(request->url));
                        if(fetch){snprintf(request->token,sizeof(request->token),"%s",settings.ha_token);snprintf(request->serial,sizeof(request->serial),"%s",p->serial);snprintf(request->key,sizeof(request->key),"%s",source->task_key);request->tls=settings.ha_tls;request->revision=settings.revision;request->generation=state.generation;}
                        else state.thumbnail_status[i]=2;
                    }
                }
            }
            xSemaphoreGive(lock);
            if(fetch) {
                if(xSemaphoreTake(media_http_lock,pdMS_TO_TICKS(100))!=pdTRUE){
                    xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==request->generation)thumbnail_sources[i].next=c6_seconds()+5;xSemaphoreGive(lock);
                    memset(request,0,sizeof(*request));continue;
                }
                uint8_t *pixels=NULL;unsigned w,h;unsigned result=thumbnail_fetch(request->url,request->token,request->tls,&pixels,&w,&h);
                xSemaphoreGive(media_http_lock);
                memset(request->token,0,sizeof(request->token));memset(request->url,0,sizeof(request->url));
                if(pixels&&current(request->generation)&&c6_sources_thumbnail_store_scoped(request->revision,request->serial,"bambu","ha",request->key,w,h,pixels,w*h*2)==200)pixels=NULL;
                xSemaphoreTake(lock,portMAX_DELAY);
                if(state.generation==request->generation&&i<settings.printer_count&&!strcmp(request->serial,settings.printers[i].serial)&&!strcmp(request->key,state.printers[i].thumbnail_key))state.thumbnail_status[i]=c6_thumbnail_matches(&thumbnails[i],request->serial,request->key)?1:result==1?4:result;
                xSemaphoreGive(lock);free(pixels);
            }
        }
        for(unsigned k=0;k<C6_MAX_ENTITIES+C6_MAX_PRINTERS;k++){
            char entity[128]={0},path[384]={0};bool fetch=false,camera=false,cover=k>=C6_MAX_ENTITIES;
            xSemaphoreTake(lock,portMAX_DELAY);
            if(settings.enabled&&settings.ha_enabled&&(!media_focus||(media_focus&(1U<<(C6_MAX_PRINTERS+k))))){
                thumbnail_source_t *source=&media_sources[k];const c6_printer_config_t *p=cover&&k-C6_MAX_ENTITIES<settings.printer_count?&settings.printers[k-C6_MAX_ENTITIES]:NULL;
                const char *id=cover?(p&&p->enabled&&p->source_ha&&c6_printer_images_enabled(p)?p->task_cover_entity:""):(k<settings.entity_count?settings.entities[k].id:"");
                snprintf(entity,sizeof(entity),"%s",id);camera=!strncmp(id,"camera.",7);
                if(camera||!strncmp(id,"image.",6)){
                    char key[17],owner[40];if(cover){printer_picture_key(k-C6_MAX_ENTITIES,key);snprintf(owner,sizeof(owner),"cover_%u",k-C6_MAX_ENTITIES);}else{c6_task_key("entity",id,key);snprintf(owner,sizeof(owner),"entity_%u",k);}
                    if(strcmp(key,source->task_key)){snprintf(source->task_key,sizeof(source->task_key),"%s",key);source->next=0;}
                    bool cached=c6_thumbnail_matches(&media_images[k],owner,key);
                    if(*key&&(camera||*source->path)&&c6_thumbnail_due(camera,cached,c6_seconds(),source->next)){
                        source->next=c6_seconds()+(camera?15:cached?300:60);source->last_attempt=c6_seconds();
                        fetch=camera?c6_camera_snapshot_url(settings.ha_host,settings.ha_port,settings.ha_tls,id,request->url,sizeof(request->url)):c6_thumbnail_url(settings.ha_host,settings.ha_port,settings.ha_tls,source->path,request->url,sizeof(request->url));
                        // Reject rather than truncate an invalid unterminated
                        // path: its full identity is used to reject stale HTTP
                        // responses after a source/configuration change.
                        size_t path_length=strnlen(source->path,sizeof(source->path));
                        if(path_length>=sizeof(path))fetch=false;
                        else memcpy(path,source->path,path_length+1);
                        if(fetch){snprintf(request->token,sizeof(request->token),"%s",settings.ha_token);snprintf(request->serial,sizeof(request->serial),"%s",p?p->serial:"");snprintf(request->key,sizeof(request->key),"%s",key);request->tls=settings.ha_tls;request->revision=settings.revision;request->generation=state.generation;}else state.media_status[k]=2;
                    }
                }
            }xSemaphoreGive(lock);
            if(fetch){
                if(xSemaphoreTake(media_http_lock,pdMS_TO_TICKS(100))!=pdTRUE){
                    xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==request->generation)media_sources[k].next=c6_seconds()+5;xSemaphoreGive(lock);
                    memset(request,0,sizeof(*request));continue;
                }
                uint8_t *pixels=NULL;unsigned w,h,result=thumbnail_fetch(request->url,request->token,request->tls,&pixels,&w,&h);xSemaphoreGive(media_http_lock);
                bool same=false;xSemaphoreTake(lock,portMAX_DELAY);same=state.generation==request->generation&&(camera||!strcmp(path,media_sources[k].path));xSemaphoreGive(lock);
                if(pixels&&same&&c6_sources_media_store_scoped(request->revision,request->serial,"bambu","ha",cover?NULL:entity,request->key,cover,w,h,pixels,w*h*2)==200)pixels=NULL;
                free(pixels);xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==request->generation&&state.media_status[k]!=1)state.media_status[k]=result==1?4:result;xSemaphoreGive(lock);
                memset(request->token,0,sizeof(request->token));memset(request->url,0,sizeof(request->url));
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
#endif
// One bounded HTTPS exchange, no redirects or logging response/credential bodies.
static cJSON *form_request(const char *url,const char *token,const char *body,int *status){
    *status=0;if(!http_budget(true)||time(NULL)<1700000000)return NULL;
    char *response=calloc(1,MESSAGE_LIMIT);if(!response)return NULL;
    esp_http_client_config_t cfg={.url=url,.timeout_ms=6000,.buffer_size=1024,.crt_bundle_attach=esp_crt_bundle_attach,.disable_auto_redirect=true,.method=body?HTTP_METHOD_POST:HTTP_METHOD_GET};
    esp_http_client_handle_t h=esp_http_client_init(&cfg);cJSON *result=NULL;
    if(h){
        if(token&&*token){char auth[1050];snprintf(auth,sizeof(auth),"Bearer %s",token);esp_http_client_set_header(h,"Authorization",auth);memset(auth,0,sizeof(auth));}
        if(body)esp_http_client_set_header(h,"Content-Type","application/x-www-form-urlencoded");
        size_t length=body?strlen(body):0;
        if(esp_http_client_open(h,length)==ESP_OK&&(!length||esp_http_client_write(h,body,length)==(int)length)){
            int64_t declared=esp_http_client_fetch_headers(h);*status=esp_http_client_get_status_code(h);
            if(*status==200&&declared<MESSAGE_LIMIT){int used=0,n;while(used<MESSAGE_LIMIT-1&&(n=esp_http_client_read(h,response+used,MESSAGE_LIMIT-1-used))>0)used+=n;response[used]=0;
                if(esp_http_client_is_complete_data_received(h))result=cJSON_Parse(response);
            }
            esp_http_client_close(h);
        }esp_http_client_cleanup(h);
    }
    memset(response,0,MESSAGE_LIMIT);free(response);return result;
}
#if C6_FORMLABS_ONLY
typedef struct {char serial[40],form_client_id[128],form_client_secret[256];bool show_image;} form_printer_request_t;
#else
typedef c6_printer_config_t form_printer_request_t;
#endif
typedef struct {form_printer_request_t printer;char token[1024],auth_key[17],picture[1536],url[1600],form[1280];uint64_t expires;unsigned generation;int revision;
#if C6_FORMLABS_ONLY
    c6_form_auth_cache_t auth;
#endif
} form_worker_t;
static void form_task(void *arg){
    form_worker_t *w=NULL;
    uint64_t next[C6_MAX_PRINTERS]={0};unsigned seen_generation=0,seen_focus=UINT32_MAX;
    for(;;){
        if(!runtime_enabled(C6_WORK_FORM)){if(w){memset(w,0,sizeof(*w));free(w);w=NULL;}seen_generation=0;vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!ha_network_ready()){vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!w){w=calloc(1,sizeof(*w));if(!w){vTaskDelay(pdMS_TO_TICKS(5000));continue;}}
        for(unsigned i=0;i<C6_MAX_PRINTERS;i++){
            bool fetch=false;xSemaphoreTake(lock,portMAX_DELAY);
            if(seen_generation!=state.generation){memset(next,0,sizeof(next));seen_generation=state.generation;
#if C6_FORMLABS_ONLY
                memset(&w->auth,0,sizeof(w->auth));memset(w->token,0,sizeof(w->token));w->auth_key[0]=0;w->expires=0;
#endif
            }
            if(seen_focus!=media_focus){seen_focus=media_focus;
#if !C6_FORMLABS_ONLY
                for(unsigned k=0;k<settings.printer_count;k++)if(media_focus&(1U<<k))next[k]=0;
#endif
            }
            if(settings.enabled&&i<settings.printer_count&&c6_form_pollable(&settings.printers[i])&&c6_seconds()>=next[i]){
#if C6_FORMLABS_ONLY
                const c6_printer_config_t *p=&settings.printers[i];
                snprintf(w->printer.serial,sizeof(w->printer.serial),"%s",p->serial);
                snprintf(w->printer.form_client_id,sizeof(w->printer.form_client_id),"%s",p->form_client_id);
                snprintf(w->printer.form_client_secret,sizeof(w->printer.form_client_secret),"%s",p->form_client_secret);
                w->printer.show_image=c6_printer_images_enabled(p);
#else
                w->printer=settings.printers[i];
#endif
                w->generation=state.generation;w->revision=settings.revision;fetch=true;
                next[i]=c6_seconds()+60;
            }xSemaphoreGive(lock);if(!fetch)continue;
            if(xSemaphoreTake(media_http_lock,pdMS_TO_TICKS(100))!=pdTRUE){next[i]=c6_seconds()+5;memset(&w->printer,0,sizeof(w->printer));continue;}
            int status=0;unsigned phase=2;
            snprintf(w->form,sizeof(w->form),"%zu:%s:%zu:%s",strlen(w->printer.form_client_id),w->printer.form_client_id,strlen(w->printer.form_client_secret),w->printer.form_client_secret);char key[17];c6_task_key("formAuth",w->form,key);memset(w->form,0,sizeof(w->form));
#if C6_FORMLABS_ONLY
            if(c6_form_auth_get(&w->auth,key,c6_seconds(),w->token,&w->expires))snprintf(w->auth_key,sizeof(w->auth_key),"%s",key);
#endif
            if(strcmp(key,w->auth_key)||c6_seconds()+120>=w->expires){
                memset(w->token,0,sizeof(w->token));w->expires=0;
                if(c6_formlabs_form_body(w->printer.form_client_id,w->printer.form_client_secret,w->form,sizeof(w->form))){
                    cJSON *j=form_request("https://api.formlabs.com/developer/v1/o/token/",NULL,w->form,&status);
                    cJSON *token=cJSON_GetObjectItemCaseSensitive(j,"access_token"),*expires=cJSON_GetObjectItemCaseSensitive(j,"expires_in");
                    if(cJSON_IsString(token)&&*token->valuestring&&strlen(token->valuestring)<sizeof(w->token)){
                        snprintf(w->token,sizeof(w->token),"%s",token->valuestring);snprintf(w->auth_key,sizeof(w->auth_key),"%s",key);
                        double lifetime=cJSON_IsNumber(expires)?expires->valuedouble:86400;
                        if(isfinite(lifetime)&&lifetime>0&&lifetime<=604800)w->expires=c6_seconds()+(uint64_t)lifetime;
                        else memset(w->token,0,sizeof(w->token));
                    }cJSON_Delete(j);
                }memset(w->form,0,sizeof(w->form));
            }
            if(*w->token){
                snprintf(w->url,sizeof(w->url),"https://api.formlabs.com/developer/v1/printers/%s/",w->printer.serial);
                cJSON *j=form_request(w->url,w->token,NULL,&status);char previous[17]={0};bool accepted=false,want_picture=false;w->picture[0]=0;
                xSemaphoreTake(lock,portMAX_DELAY);
                if(state.generation==w->generation&&i<settings.printer_count&&j){
                    snprintf(previous,sizeof(previous),"%s",state.printers[i].thumbnail_key);
                    accepted=c6_formlabs_update(&state.printers[i],j,w->printer.serial,c6_seconds(),w->picture,sizeof(w->picture));
                    if(accepted){
                        want_picture=!media_focus||(media_focus&(1U<<i));
                        phase=1;if(strcmp(previous,state.printers[i].thumbnail_key)){c6_thumbnail_clear(&thumbnails[i]);state.thumbnail_status[i]=0;state.thumbnail_revision[i]++;}
                        snprintf(previous,sizeof(previous),"%s",state.printers[i].thumbnail_key);
                        next[i]=c6_seconds()+(c6_print_active(state.printers[i].status)?30:120);
                    }
                }xSemaphoreGive(lock);cJSON_Delete(j);
                if(accepted&&want_picture&&*w->picture&&w->printer.show_image&&*previous&&current(w->generation)){
                    bool bearer=false;
                    if(c6_formlabs_picture_url(w->picture,w->url,sizeof(w->url),&bearer)){
                        xSemaphoreTake(lock,portMAX_DELAY);bool cached=c6_thumbnail_matches(&thumbnails[i],w->printer.serial,previous);xSemaphoreGive(lock);
                        if(!cached){uint8_t *pixels=NULL;unsigned width,height;unsigned result=thumbnail_fetch(w->url,bearer?w->token:NULL,true,&pixels,&width,&height);
                            if(pixels&&current(w->generation)&&c6_sources_thumbnail_store_scoped(w->revision,w->printer.serial,"formlabs","formlabs",previous,width,height,pixels,width*height*2)==200)pixels=NULL;
                            free(pixels);xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==w->generation&&!strcmp(previous,state.printers[i].thumbnail_key)&&state.thumbnail_status[i]!=1)state.thumbnail_status[i]=result==1?4:result;xSemaphoreGive(lock);
                        }
                    }else {xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==w->generation)state.thumbnail_status[i]=2;xSemaphoreGive(lock);}
                }
            }
            if(status==401||status==403){phase=3;memset(w->token,0,sizeof(w->token));w->expires=0;next[i]=c6_seconds()+300;}
            else if(status==429)next[i]=c6_seconds()+300;
            else if(!status&&esp_get_free_heap_size()<90000)phase=4;
#if C6_FORMLABS_ONLY
            if(status==401||status==403)c6_form_auth_reject(&w->auth,key);
            else if(!strcmp(w->auth_key,key))c6_form_auth_put(&w->auth,i,key,w->token,w->expires);
#endif
            xSemaphoreGive(media_http_lock);
            xSemaphoreTake(lock,portMAX_DELAY);if(state.generation==w->generation){state.form_phase[i]=phase;if(phase!=1)state.printers[i].connected=false;}xSemaphoreGive(lock);
            memset(w->printer.form_client_secret,0,sizeof(w->printer.form_client_secret));memset(w->url,0,sizeof(w->url));memset(w->picture,0,sizeof(w->picture));
        }vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
static bool weather_refresh_requested;
static uint64_t weather_last_attempt;
static void weather_phase(unsigned phase){xSemaphoreTake(lock,portMAX_DELAY);state.weather_phase=phase;xSemaphoreGive(lock);}
bool c6_sources_weather_refresh(void){
    xSemaphoreTake(lock,portMAX_DELAY);
    bool allow=settings.enabled&&settings.weather&&!weather_refresh_requested&&
        (!weather_last_attempt||c6_seconds()-weather_last_attempt>=300);
    if(allow)weather_refresh_requested=true;
    xSemaphoreGive(lock);return allow;
}
static void weather_task(void *arg) {
    uint64_t next=0;double last_lat=100,last_lon=200;bool last_enabled=false;
    nvs_handle_t store;
    if(nvs_open(C6_WEATHER_NAMESPACE,NVS_READWRITE,&store)==ESP_OK) {
        c6_weather_state_t cached={0};size_t size=sizeof(cached);
        if(nvs_get_blob(store,"snapshot",&cached,&size)==ESP_OK&&size==sizeof(cached)&&cached.valid&&cached.latitude==settings.latitude&&cached.longitude==settings.longitude){xSemaphoreTake(lock,portMAX_DELAY);state.weather=cached;xSemaphoreGive(lock);}
        nvs_close(store);
    }
    for(;;) {
        xSemaphoreTake(lock,portMAX_DELAY);
        bool enabled=settings.enabled&&settings.weather;double lat=settings.latitude,lon=settings.longitude;int minutes=settings.weather_minutes;unsigned g=state.generation;
        if(weather_refresh_requested){
            if(!weather_last_attempt||c6_seconds()-weather_last_attempt>=300)next=0;
            weather_refresh_requested=false;
        }
        xSemaphoreGive(lock);
        if(last_lat!=lat||last_lon!=lon){last_lat=lat;last_lon=lon;next=0;}
        if(enabled&&!last_enabled)next=0;
        last_enabled=enabled;
        if(!enabled){weather_phase(0);vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        // DHCP/resource deferral does not consume the network failure backoff.
        if(!ha_network_ready()){weather_phase(1);vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(c6_seconds()<next){vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!http_budget(true)){weather_phase(2);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        if(xSemaphoreTake(media_http_lock,pdMS_TO_TICKS(100))!=pdTRUE){vTaskDelay(pdMS_TO_TICKS(1000));continue;}
        if(!http_budget(true)){xSemaphoreGive(media_http_lock);weather_phase(2);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        char *body=malloc(2048);if(!body){xSemaphoreGive(media_http_lock);weather_phase(2);vTaskDelay(pdMS_TO_TICKS(5000));continue;}
        next=c6_seconds()+300; // Real network failures retain the existing backoff.
        xSemaphoreTake(lock,portMAX_DELAY);weather_last_attempt=c6_seconds();state.weather_phase=3;xSemaphoreGive(lock);
        char url[384];snprintf(url,sizeof(url),"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,apparent_temperature,weather_code" C6_WEATHER_EXTRA_FIELDS "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&forecast_days=1&timezone=auto",lat,lon);
        esp_http_client_config_t cfg={.url=url,.timeout_ms=8000,.buffer_size=512,.crt_bundle_attach=esp_crt_bundle_attach,.disable_auto_redirect=true};
        esp_http_client_handle_t h=esp_http_client_init(&cfg);bool ok=false;c6_weather_state_t result={.latitude=lat,.longitude=lon};
        if(h&&esp_http_client_open(h,0)==ESP_OK) {
            esp_http_client_fetch_headers(h);int used=0,n;
            while(used<2047&&(n=esp_http_client_read(h,body+used,2047-used))>0){used+=n;}
            body[used]=0;
            if(esp_http_client_get_status_code(h)==200&&esp_http_client_is_complete_data_received(h)) {
                cJSON *j=cJSON_Parse(body),*cur=cJSON_GetObjectItemCaseSensitive(j,"current"),*daily=cJSON_GetObjectItemCaseSensitive(j,"daily");
                cJSON *values[]={cJSON_GetObjectItemCaseSensitive(cur,"temperature_2m"),cJSON_GetObjectItemCaseSensitive(cur,"apparent_temperature"),cJSON_GetObjectItemCaseSensitive(cur,"weather_code"),cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(daily,"temperature_2m_min"),0),cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(daily,"temperature_2m_max"),0)};
                ok=true;for(unsigned i=0;i<5;i++)if(!cJSON_IsNumber(values[i])||!isfinite(values[i]->valuedouble))ok=false;
                if(ok){result.temperature=values[0]->valuedouble;result.apparent=values[1]->valuedouble;result.code=values[2]->valueint;result.low=values[3]->valuedouble;result.high=values[4]->valuedouble;cJSON *rain=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(daily,"precipitation_probability_max"),0);result.rain=cJSON_IsNumber(rain)?rain->valueint:0;result.valid=true;result.epoch=time(NULL);}
#if C6_FORMLABS_ONLY
                cJSON *humidity=cJSON_GetObjectItemCaseSensitive(cur,"relative_humidity_2m"),*wind=cJSON_GetObjectItemCaseSensitive(cur,"wind_speed_10m");
                result.humidity_valid=cJSON_IsNumber(humidity)&&isfinite(humidity->valuedouble)&&humidity->valuedouble>=0&&humidity->valuedouble<=100;
                result.wind_valid=cJSON_IsNumber(wind)&&isfinite(wind->valuedouble)&&wind->valuedouble>=0&&wind->valuedouble<=500;
                if(result.humidity_valid)result.humidity=humidity->valueint;
                if(result.wind_valid)result.wind=wind->valuedouble/3.6; // API defaults to km/h; terminal uses m/s.
#endif
                cJSON_Delete(j);
            }
            esp_http_client_close(h);
        }
        if(h){esp_http_client_cleanup(h);}
        free(body);
        xSemaphoreGive(media_http_lock);
        xSemaphoreTake(lock,portMAX_DELAY);
        bool accepted=ok&&state.generation==g;
        if(accepted)state.weather=result;
        state.weather_phase=accepted?4:5;
        xSemaphoreGive(lock);
        if(accepted) {
            if(nvs_open(C6_WEATHER_NAMESPACE,NVS_READWRITE,&store)==ESP_OK){if(nvs_set_blob(store,"snapshot",&result,sizeof(result))==ESP_OK)nvs_commit(store);nvs_close(store);}
            next=c6_seconds()+(uint64_t)(minutes>=15?minutes:30)*60;
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
void c6_sources_init(void) {
    lock=xSemaphoreCreateMutex();media_http_lock=xSemaphoreCreateMutex();if(!lock||!media_http_lock)abort();c6_sources_reconfigure();
#if !C6_FORMLABS_ONLY
    if(xTaskCreate(ha_task,"ha_subscription",6144,NULL,3,NULL)!=pdPASS||xTaskCreate(mqtt_task,"bambu_subscription",4096,NULL,3,NULL)!=pdPASS||xTaskCreate(weather_task,"weather",4096,NULL,2,NULL)!=pdPASS||xTaskCreate(thumbnail_task,"task_thumbnail",4096,NULL,1,NULL)!=pdPASS||xTaskCreate(form_task,"formlabs_cloud",5120,NULL,1,NULL)!=pdPASS)abort();
#else
    if(xTaskCreate(weather_task,"weather",4096,NULL,2,NULL)!=pdPASS||xTaskCreate(form_task,"formlabs_cloud",5120,NULL,1,NULL)!=pdPASS)abort();
#endif
}
