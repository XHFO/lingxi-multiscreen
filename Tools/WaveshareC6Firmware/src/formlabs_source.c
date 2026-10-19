#include "formlabs_source.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>
static cJSON *get(cJSON *j,const char *key){return cJSON_GetObjectItemCaseSensitive(j,key);}
static const char *text(cJSON *j,const char *key){cJSON *v=get(j,key);return cJSON_IsString(v)?v->valuestring:"";}
static const char *first(cJSON *j,const char *a,const char *b){const char *s=text(j,a);return *s?s:text(j,b);}
static double number(cJSON *j,const char *key){cJSON *v=get(j,key);if(cJSON_IsNumber(v))return isfinite(v->valuedouble)?v->valuedouble:NAN;if(cJSON_IsString(v)){char *end;double n=strtod(v->valuestring,&end);if(end!=v->valuestring&&!*end&&isfinite(n))return n;}return NAN;}
static bool material_valid(const char *s){
    const char *bad[]={"","unknown","unknown material","none","null","n/a","not assigned","not_assigned","not set","not available","unassigned","default","未分配","未指定","未知","暂无","默认"};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++)if(!strcasecmp(s,bad[i]))return false;
    return true;
}
static const char *installed_material(cJSON *printer,cJSON *status,cJSON *run){
    cJSON *list=get(printer,"cartridge_status"),*entry;
    // The cartridge selected by this run wins over any other installed material.
    for(unsigned pass=0;pass<2;pass++)cJSON_ArrayForEach(entry,list){
        cJSON *cart=get(entry,"cartridge");if(!cJSON_IsObject(cart))cart=entry;
        const char *serial=text(cart,"serial");bool selected=*serial&&(!strcmp(serial,text(run,"cartridge"))||!strcmp(serial,text(run,"front_cartridge"))||!strcmp(serial,text(run,"back_cartridge")));
        if((pass==0)!=selected)continue;
        const char *keys[]={"display_name","material","consumable_type"};for(unsigned k=0;k<3;k++){const char *value=text(cart,keys[k]);if(material_valid(value))return value;}
    }
    cJSON *tank=get(get(printer,"tank_status"),"tank");const char *keys[]={"display_name","material","tank_type"};
    for(unsigned k=0;k<3;k++){const char *s=text(tank,keys[k]);if(material_valid(s))return s;}
    return text(status,"hopper_material");
}
bool c6_formlabs_update(c6_printer_state_t *s,cJSON *root,const char *serial,uint64_t now,char *picture,size_t capacity){
    if(!s||!cJSON_IsObject(root)||!picture||!capacity)return false;
    cJSON *p=get(root,"printer");if(!cJSON_IsObject(p))p=root;
    const char *reported=first(p,"serial","printer_serial");if(*reported&&strcmp(reported,serial))return false;
    cJSON *status=get(p,"printer_status");if(!cJSON_IsObject(status))status=get(p,"status");if(!cJSON_IsObject(status))status=p;
    const char *device_status=first(status,"status","state");if(!*device_status)device_status=text(p,"status");
    cJSON *run=get(status,"current_print_run");if(!cJSON_IsObject(run))run=get(p,"current_print_run");
    // A success response must actually contain printer state, not an API error object.
    if(!*device_status&&!cJSON_HasObjectItem(status,"current_print_run")&&!cJSON_HasObjectItem(p,"current_print_run"))return false;
    cJSON *online=get(p,"is_connected");bool connected=cJSON_IsBool(online)?cJSON_IsTrue(online):strcasecmp(device_status,"offline")&&strcasecmp(device_status,"disconnected")&&strcasecmp(device_status,"off")&&strcasecmp(device_status,"unavailable");
    cJSON *data=cJSON_CreateObject();if(!data)return false;
    if(cJSON_IsObject(run)){
        const char *id=first(run,"print_run_id","run_id");if(!*id)id=first(run,"uuid","id");
        char number_id[32];if(!*id&&isfinite(number(run,"id"))){snprintf(number_id,sizeof(number_id),"%.0f",number(run,"id"));id=number_id;}
        const char *name=first(run,"name","print_name");
        const char *run_status=text(run,"status");if(!*run_status)run_status=device_status;
        const char *identity=*id?id:name;char key[17];c6_task_key("formlabs",identity,key);
        bool new_task=*key&&strcmp(key,s->thumbnail_key);
        if(new_task){s->material[0]=0;s->layer=s->layer_count=0;picture[0]=0;}
        if(*key){cJSON_AddStringToObject(data,"thumbnail_key",key);cJSON_AddStringToObject(data,"task_id",identity);}
        cJSON_AddStringToObject(data,"subtask_name",name);cJSON_AddStringToObject(data,"gcode_state",run_status);
        double layer=number(run,"currently_printing_layer"),total=number(run,"layer_count");
        s->layer=isfinite(layer)&&layer>=0&&layer<=INT32_MAX?(int)layer:0;s->layer_count=isfinite(total)&&total>0&&total<=INT32_MAX?(int)total:0;
        double progress=NAN;if(isfinite(layer)&&isfinite(total)&&total>0)progress=100*layer/total;
        else {double elapsed=number(run,"elapsed_duration_ms"),duration=number(run,"estimated_duration_ms");if(elapsed>=0&&duration>0)progress=100*elapsed/duration;}
        if(c6_print_finished(run_status))progress=100;
        if(isfinite(progress))cJSON_AddNumberToObject(data,"mc_percent",progress);else cJSON_AddNullToObject(data,"mc_percent");
        double remaining=number(run,"estimated_time_remaining_ms");if(!isfinite(remaining))remaining=number(p,"estimated_print_time_remaining_ms");
        if(!isfinite(remaining)){double duration=number(run,"estimated_duration_ms"),elapsed=number(run,"elapsed_duration_ms");if(duration>=elapsed&&elapsed>=0)remaining=duration-elapsed;}
        if(remaining>=0&&remaining<=31536000000.0)cJSON_AddNumberToObject(data,"mc_remaining_time",ceil(remaining/60000));else cJSON_AddNullToObject(data,"mc_remaining_time");
        const char *candidates[]={text(run,"material_name"),text(run,"print_settings_name"),installed_material(p,status,run),text(run,"material")};
        for(unsigned k=0;k<4;k++)if(material_valid(candidates[k])){snprintf(s->material,sizeof(s->material),"%s",candidates[k]);break;}
        const char *message=text(run,"message");cJSON_AddStringToObject(data,"print_error",message);
        cJSON *thumb=get(run,"print_thumbnail");if(!cJSON_IsObject(thumb))thumb=get(run,"thumbnail");
        const char *url=text(thumb,"thumbnail");if(!*url)url=text(run,"thumbnail_url");
        if(*url&&strlen(url)<capacity)snprintf(picture,capacity,"%s",url);
    }else if(*s->thumbnail_key){
        // Match FormlabsTaskCachePolicy: keep the previous run until a genuinely new run.
        bool failure=!strcasecmp(s->status,"failed")||!strcasecmp(s->status,"error")||!strcasecmp(s->status,"cancelled")||!strcasecmp(s->status,"canceled")||!strcasecmp(s->status,"aborted");
        cJSON_AddStringToObject(data,"gcode_state",failure?s->status:"finished");
        if(!failure){cJSON_AddNumberToObject(data,"mc_percent",100);s->layer=s->layer_count;}
        cJSON_AddNumberToObject(data,"mc_remaining_time",0);
    }else cJSON_AddStringToObject(data,"gcode_state",*device_status?device_status:"unknown");
    c6_print_update(s,data,now);s->connected=connected;cJSON_Delete(data);return true;
}
static bool suffix(const char *host,const char *ending){size_t a=strlen(host),b=strlen(ending);return a>b&&!strcasecmp(host+a-b,ending);}
bool c6_formlabs_picture_url(const char *raw,char *url,size_t capacity,bool *bearer){
    if(!raw||!*raw||!url||!capacity||!bearer)return false;
    *bearer=false;
    int n=raw[0]=='/'&&raw[1]!='/'?snprintf(url,capacity,"https://api.formlabs.com%s",raw):snprintf(url,capacity,"%s%s",!strncmp(raw,"//",2)?"https:":"",raw);
    if(n<0||(size_t)n>=capacity||strncmp(url,"https://",8))return false;
    const char *end=strchr(url+8,'/');size_t length=end?(size_t)(end-url-8):strlen(url+8);char host[128];
    if(!length||length>=sizeof(host))return false;
    memcpy(host,url+8,length);host[length]=0;
    if(strspn(host,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")!=length||strstr(url,"\r")||strstr(url,"\n"))return false;
    *bearer=!strcasecmp(host,"api.formlabs.com");
    return *bearer||suffix(host,".formlabs.com")||suffix(host,".amazonaws.com")||suffix(host,".cloudfront.net")||!strcasecmp(host,"storage.googleapis.com");
}
static bool append_form(const char *value,char *body,size_t capacity,size_t *used){
    const char *hex="0123456789ABCDEF";for(const unsigned char *s=(const unsigned char*)value;*s;s++){
        bool plain=(*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||strchr("-._~",*s);
        unsigned count=plain?1:3;if(*used+count>=capacity)return false;
        if(plain)body[(*used)++]=*s;else{body[(*used)++]='%';body[(*used)++]=hex[*s>>4];body[(*used)++]=hex[*s&15];}
    }body[*used]=0;return true;
}
bool c6_formlabs_form_body(const char *id,const char *secret,char *body,size_t capacity){
    const char *head="grant_type=client_credentials&client_id=";size_t used=strlen(head);
    if(!id||!*id||!secret||!*secret||capacity<=used)return false;
    memcpy(body,head,used+1);
    if(!append_form(id,body,capacity,&used)||used+15>=capacity)return false;
    memcpy(body+used,"&client_secret=",15);used+=15;return append_form(secret,body,capacity,&used);
}
