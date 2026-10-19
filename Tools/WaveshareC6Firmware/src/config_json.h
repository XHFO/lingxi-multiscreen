#pragma once

// Two-pass bounded serialization: count first, then allocate the exact output.
// No output DOM, growing buffers, static staging config, or large HTTP stack.
typedef struct {char *bytes;size_t length,capacity;bool valid;} config_json_sink_t;
typedef struct {int revision,rotation,card_mask;bool flip;unsigned printers;
    int language;
    int sleep_mode;
} config_display_override_t;
static void config_json_bytes(config_json_sink_t *s,const char *bytes,size_t length){
    if(!s->valid||length>SIZE_MAX-s->length){s->valid=false;return;}
    if(s->bytes){if(length>s->capacity-s->length){s->valid=false;return;}memcpy(s->bytes+s->length,bytes,length);}
    s->length+=length;
}
static void config_json_text(config_json_sink_t *s,const char *text){config_json_bytes(s,text,strlen(text));}
static void config_json_string(config_json_sink_t *s,const char *text){
    static const char hex[]="0123456789abcdef";
    config_json_text(s,"\"");
    const char *start=text;
    for(const unsigned char *p=(const unsigned char *)text;;p++){
        if(!*p||*p=='"'||*p=='\\'||*p<32){
            config_json_bytes(s,start,(const char *)p-start);
            if(!*p)break;
            if(*p=='"'||*p=='\\'){char escaped[2]={'\\',(char)*p};config_json_bytes(s,escaped,2);}
            else {char escaped[6]={'\\','u','0','0',hex[*p>>4],hex[*p&15]};config_json_bytes(s,escaped,6);}
            start=(const char *)p+1;
        }
    }
    config_json_text(s,"\"");
}
static void config_json_key(config_json_sink_t *s,const char *key){config_json_string(s,key);config_json_text(s,":");}
static void config_json_bool(config_json_sink_t *s,const char *key,bool value){config_json_key(s,key);config_json_text(s,value?"true,":"false,");}
static void config_json_int(config_json_sink_t *s,const char *key,int64_t value){
    char text[32];snprintf(text,sizeof(text),"%lld,",(long long)value);config_json_key(s,key);config_json_text(s,text);
}
static void config_json_number(config_json_sink_t *s,const char *key,double value){
    char text[40];if(!isfinite(value)){s->valid=false;return;}snprintf(text,sizeof(text),"%.17g,",value);config_json_key(s,key);config_json_text(s,text);
}
static void config_json_field(config_json_sink_t *s,const char *key,const char *value){config_json_key(s,key);config_json_string(s,value);config_json_text(s,",");}
static void config_json_document(config_json_sink_t *s,const standalone_config_t *c,bool secrets,const config_display_override_t *display){
    config_json_text(s,"{");
    config_json_int(s,"schema_version",2);config_json_int(s,"revision",display?display->revision:c->revision);
    config_json_bool(s,"enabled",c->enabled);config_json_bool(s,"local_first",c->local_first);
    config_json_int(s,"rotation",display?display->rotation:c->rotation);config_json_int(s,"brightness",c->brightness);
    config_json_int(s,"interval",c->interval);config_json_int(s,"timezone",c->timezone);
    config_json_bool(s,"clock",c->clock);config_json_bool(s,"diagnostics",c->diagnostics);
    config_json_int(s,"clock_style",c->clock_style);
    config_json_bool(s,"flip_animation",display?display->flip:c->flip_animation);
    config_json_int(s,"language",display?display->language:c->language);
    config_json_int(s,"digit_style",c->digit_style);
    config_json_int(s,"sleep_mode",display?display->sleep_mode:c->sleep_mode);
    config_json_int(s,"sleep_idle_minutes",c->sleep_idle_minutes);
    config_json_int(s,"sleep_start",c->sleep_start);config_json_int(s,"sleep_end",c->sleep_end);
    config_json_bool(s,"sleep_keep_printing",c->sleep_keep_printing);
    config_json_int(s,"card_mask",display?display->card_mask:c->card_mask);
    config_json_int(s,"saturation_percent",c->saturation_percent);config_json_int(s,"contrast_percent",c->contrast_percent);
    config_json_text(s,"\"theme\":{");config_json_bool(s,"enabled",c->theme.enabled);config_json_bool(s,"dark",c->theme.dark);
#define JSON_THEME(field) config_json_int(s,#field,c->theme.field)
    JSON_THEME(background);JSON_THEME(card);JSON_THEME(inset);JSON_THEME(border);JSON_THEME(accent);JSON_THEME(secondary_accent);JSON_THEME(primary_text);JSON_THEME(secondary_text);
#undef JSON_THEME
    config_json_key(s,"tertiary_text");char number[32];snprintf(number,sizeof(number),"%lu",(unsigned long)c->theme.tertiary_text);config_json_text(s,number);
    config_json_text(s,"},");
    config_json_bool(s,"weather",c->weather);config_json_number(s,"latitude",c->latitude);config_json_number(s,"longitude",c->longitude);
    config_json_field(s,"weather_city",c->weather_city);config_json_int(s,"weather_minutes",c->weather_minutes);
    config_json_text(s,"\"ha\":{");config_json_bool(s,"enabled",c->ha_enabled);config_json_field(s,"host",c->ha_host);
    config_json_int(s,"port",c->ha_port);config_json_bool(s,"tls",c->ha_tls);config_json_bool(s,"token_set",*c->ha_token!=0);
    if(secrets)config_json_field(s,"token",c->ha_token);
    config_json_text(s,"\"entities\":[");
    for(unsigned i=0;i<c->entity_count;i++){
        if(i){config_json_text(s,",");}
        config_json_text(s,"{");config_json_field(s,"id",c->entities[i].id);
        config_json_key(s,"name");config_json_string(s,c->entities[i].name);config_json_text(s,"}");
    }
    config_json_text(s,"]},\"printers\":[");
    for(unsigned i=0;i<c->printer_count;i++){
        const c6_printer_config_t *p=&c->printers[i];if(i)config_json_text(s,",");config_json_text(s,"{");
#define JSON_BOOL(field) config_json_bool(s,#field,p->field)
#define JSON_STRING(field) config_json_field(s,#field,p->field)
        JSON_BOOL(enabled);JSON_STRING(host);config_json_bool(s,"rotate",display?(display->printers&(1U<<i))!=0:p->rotate);
        JSON_STRING(serial);JSON_STRING(name);config_json_field(s,"brand",c6_printer_brand(p));
        JSON_BOOL(trust_lan);JSON_STRING(certificate);config_json_bool(s,"access_code_set",*p->access_code!=0);
        JSON_BOOL(source_ha);JSON_BOOL(source_formlabs);JSON_STRING(form_client_id);config_json_bool(s,"form_credentials_set",*p->form_client_secret!=0);
        JSON_BOOL(show_layers);JSON_BOOL(show_material);if(secrets)JSON_STRING(form_client_secret);
        JSON_BOOL(show_status);JSON_BOOL(show_progress);JSON_BOOL(show_task);JSON_BOOL(show_remaining);JSON_BOOL(show_image);
        JSON_BOOL(show_nozzle);JSON_BOOL(show_bed);JSON_BOOL(show_error);config_json_int(s,"time_mode",p->time_mode);JSON_BOOL(brand_accent);
        config_json_int(s,"card_style",p->card_style);
        JSON_STRING(status_entity);JSON_STRING(progress_entity);JSON_STRING(task_entity);JSON_STRING(remaining_entity);JSON_STRING(image_entity);
        JSON_STRING(task_cover_entity);JSON_BOOL(live_image);JSON_STRING(nozzle_entity);JSON_STRING(bed_entity);JSON_STRING(error_entity);
        config_json_key(s,"end_time_entity");config_json_string(s,p->end_time_entity);
#undef JSON_BOOL
#undef JSON_STRING
        if(secrets){config_json_text(s,",");config_json_key(s,"access_code");config_json_string(s,p->access_code);}
        config_json_text(s,"}");
    }
    config_json_text(s,"]}");
}
static char *config_json_encode(const standalone_config_t *c,bool secrets,const config_display_override_t *display,bool *too_large){
    if(too_large)*too_large=false;
    config_json_sink_t count={.valid=true};config_json_document(&count,c,secrets,display);
    if(!count.valid||count.length>=C6_CONFIG_BYTES){if(too_large)*too_large=true;return NULL;}
    char *body=malloc(count.length+1);if(!body)return NULL;
    config_json_sink_t output={.bytes=body,.capacity=count.length,.valid=true};config_json_document(&output,c,secrets,display);
    if(!output.valid||output.length!=count.length){memset(body,0,count.length+1);free(body);return NULL;}
    body[output.length]=0;return body;
}
