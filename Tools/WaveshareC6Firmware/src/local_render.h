// Included only by the HTTP/display owner. Network callbacks never draw.
// The implementation and redistributable smooth font are shared with SwiftPM.
#include "c6_display_renderer.h"
#include "form_demo.h"
static uint64_t weather_hash_bytes(uint64_t hash,const void *bytes,size_t count);
static uint64_t render_string_key(uint64_t hash,const char *text){return weather_hash_bytes(hash,text,strlen(text)+1);}
static uint64_t render_controls_key(uint64_t hash){
    hash=weather_hash_bytes(hash,&standalone_config.language,sizeof(standalone_config.language));
    hash=weather_hash_bytes(hash,&standalone_config.digit_style,sizeof(standalone_config.digit_style));
    const int controls[]={standalone_config.brightness,standalone_config.rotation,standalone_config.saturation_percent,standalone_config.contrast_percent};
    hash=weather_hash_bytes(hash,controls,sizeof(controls));
    const c6_theme_config_t *t=&standalone_config.theme;const uint32_t palette[]={t->background,t->card,t->inset,t->border,t->accent,t->secondary_accent,t->primary_text,t->secondary_text,t->tertiary_text};
    hash=weather_hash_bytes(hash,palette,sizeof(palette));return weather_hash_bytes(hash,&t->enabled,sizeof(t->enabled));
}
static c6_render_style_t local_style(void){
    const c6_theme_config_t *t=&standalone_config.theme;if(!t->enabled)return c6_renderer_default_style();
    return (c6_render_style_t){.enabled=true,.background=t->background,.card=t->card,.inset=t->inset,.border=t->border,.accent=t->accent,.secondary_accent=t->secondary_accent,.primary_text=t->primary_text,.secondary_text=t->secondary_text,.tertiary_text=t->tertiary_text};
}
static c6_renderer_t local_renderer;
static c6_renderer_t *renderer(void){
    if(local_renderer.frame!=frame)c6_renderer_init(&local_renderer,frame,FRAME_BYTES);
    local_renderer.english=standalone_config.language==1;
    local_renderer.smooth_digits=standalone_config.digit_style==1;
    return &local_renderer;
}
#include "local_language.h"
static uint32_t unpack_color(uint16_t c){return (((c>>11)*255/31)<<16)|((((c>>5)&63)*255/63)<<8)|((c&31)*255/31);}
static void clock_text(const char *text,int x,int y,bool large,bool centered,uint16_t color){
    unsigned size=large?44:16;
    if(centered)x-=c6_renderer_text_width(text,size)/2;
    c6_renderer_label(renderer(),text,x,y+(centered?(large?22:6):(large?44:16)),size,240-x,unpack_color(color));
}
static void data_text(const char *text,int x,int y,int scale,int max_width,uint16_t color){
    unsigned size=scale>1?20:14;
    c6_renderer_label(renderer(),text,x,y+size,size,max_width,unpack_color(color));
}
static void calibrated_display(void){
    c6_renderer_calibrate(renderer(),standalone_config.saturation_percent,standalone_config.contrast_percent);
    display_frame();
}
static void draw_flip_clock(const struct tm *t){
    c6_render_clock_t now={t->tm_year+1900,t->tm_mon+1,t->tm_mday,t->tm_wday,t->tm_hour,t->tm_min,t->tm_sec};
    c6_renderer_clock(renderer(),&now,NULL,1000);display_frame();
}
static c6_render_picture_t media_picture(const c6_thumbnail_cache_t *cache){return cache?(c6_render_picture_t){cache->bytes,cache->width,cache->height,cache->width*2}:(c6_render_picture_t){0};}
typedef struct {c6_render_entity_t *items;unsigned count;bool connected;c6_render_style_t style;} entity_render_context_t;
static void render_entity_pictures(const c6_thumbnail_cache_t *const *pictures,unsigned count,void *context){
    entity_render_context_t *c=context;for(unsigned i=0;i<count&&i<c->count;i++)c->items[i].picture=media_picture(pictures[i]);
    c6_renderer_entities_styled(renderer(),"Home System",c->items,c->count,c->connected,&c->style);
}
static void draw_entity(unsigned group,const c6_source_snapshot_t *sources){
    c6_sources_media_focus((int)group,-1);
    static uint64_t visible_key;static uint32_t rendered_generation;static bool rendered;
    unsigned first=group*4,count=standalone_config.entity_count>first?standalone_config.entity_count-first:0;
    if(count>4)count=4;
    c6_render_entity_t items[4]={0};
    uint64_t key=render_controls_key(UINT64_C(14695981039346656037));
    key=weather_hash_bytes(key,&count,sizeof(count));key=weather_hash_bytes(key,&sources->ha_connected,sizeof(sources->ha_connected));
    for(unsigned i=0;i<count;i++){
        unsigned index=first+i;const c6_entity_state_t *e=&sources->entities[index];
        items[i]=(c6_render_entity_t){*standalone_config.entities[index].name?standalone_config.entities[index].name:*e->name?e->name:standalone_config.entities[index].id,*e->state?e->state:"等待状态",e->unit,e->available};
        const char *id=standalone_config.entities[index].id;items[i].media=!strncmp(id,"image.",6)||!strncmp(id,"camera.",7);
        key=render_string_key(key,id);
        if(items[i].media){key=weather_hash_bytes(key,&sources->media_revision[index],sizeof(sources->media_revision[index]));key=weather_hash_bytes(key,&sources->media_status[index],sizeof(sources->media_status[index]));}
        key=render_string_key(key,items[i].name);key=render_string_key(key,items[i].state);key=render_string_key(key,items[i].unit);
        key=weather_hash_bytes(key,&items[i].available,sizeof(items[i].available));
    }
    if(rendered&&key==visible_key&&rendered_generation==frame_generation)return;
    entity_render_context_t context={items,count,sources->ha_connected,local_style()};c6_sources_entity_pictures_visit(first,count,render_entity_pictures,&context);calibrated_display();
    rendered=true;visible_key=key;rendered_generation=frame_generation;
}
static void render_printer_pictures(const c6_thumbnail_cache_t *const *pictures,unsigned count,void *context){
    c6_render_printer_t *p=context;
    if(count){c6_render_picture_t primary=media_picture(pictures[0]);
        if(p->camera_configured)p->camera=primary;else if(p->cover_configured)p->cover=primary;
        else{p->thumbnail_rgb565=primary.rgb565;p->thumbnail_width=primary.width;p->thumbnail_height=primary.height;p->thumbnail_stride=primary.stride;}}
    if(count>1&&pictures[1])p->cover=media_picture(pictures[1]);
    c6_renderer_printer(renderer(),p);
}
static void draw_printer(unsigned index,const c6_source_snapshot_t *sources){
    c6_sources_media_focus(-1,(int)index);
    static uint64_t visible_key;static uint32_t rendered_generation;static bool drawn;
    const c6_printer_state_t *s=&sources->printers[index];const c6_printer_config_t *p=&standalone_config.printers[index];
    bool demo=c6_form_is_demo(p),show_image=!demo&&c6_printer_images_enabled(p);
    char time_text[64]={0},updated_text[64]={0},layers[64]={0};uint64_t monotonic=c6_seconds();time_t wall=time(NULL);
    if(p->source_formlabs&&p->show_layers&&s->layer_count>0)snprintf(layers,sizeof(layers),local_format("层数 %d / %d","LAYERS %d / %d"),s->layer,s->layer_count);
    uint64_t remaining_seconds=(uint64_t)s->remaining*60;
    if(!demo&&s->remaining_valid&&c6_print_active(s->status)&&monotonic>=s->remaining_updated){uint64_t elapsed=monotonic-s->remaining_updated;remaining_seconds=elapsed<remaining_seconds?remaining_seconds-elapsed:0;}
    if(p->show_remaining){
        if(s->completed_at)snprintf(time_text,sizeof(time_text),"%s",local_format(C6_FORMLABS_ONLY?"打印已完成":"已完成 · 保留30分钟","PRINT COMPLETE"));
        else if(!demo&&p->time_mode==1&&wall>1700000000&&(s->end_epoch||s->remaining_valid)){
            time_t finish=(s->end_epoch?s->end_epoch:(uint64_t)wall+remaining_seconds)+standalone_config.timezone;struct tm t;gmtime_r(&finish,&t);snprintf(time_text,sizeof(time_text),local_format("预计结束 %02d:%02d","END %02d:%02d"),t.tm_hour,t.tm_min);
        }else if((demo||p->time_mode==0)&&s->remaining_valid){unsigned mins=(remaining_seconds+59)/60;if(mins>=60)snprintf(time_text,sizeof(time_text),local_format("剩余 %u时%u分","ETA %uh %um"),mins/60,mins%60);else snprintf(time_text,sizeof(time_text),local_format("剩余 %u分钟","ETA %um"),mins);}
    }
    if(s->updated&&wall>1700000000&&monotonic>=s->updated){time_t updated=wall-(time_t)(monotonic-s->updated)+standalone_config.timezone;struct tm t;gmtime_r(&updated,&t);snprintf(updated_text,sizeof(updated_text),local_format("数据更新 %02d:%02d","UPDATED %02d:%02d"),t.tm_hour,t.tm_min);}
    if(demo)snprintf(updated_text,sizeof(updated_text),"DEMO / FIXED");
    bool is_error=*s->error&&strcmp(s->error,"0")&&strcmp(s->error,"none")&&strcmp(s->error,"unknown")&&strcmp(s->error,"unavailable")&&strcmp(s->error,"无错误");
    c6_render_printer_t value={.name=*p->name?p->name:p->serial,.task=s->task,.status=s->status,
        .progress=s->progress,.remaining=s->remaining,.connected=s->connected,.completed=s->completed_at!=0,
        .show_task=p->show_task,.show_progress=p->show_progress&&s->progress_valid,.show_status=p->show_status,.show_remaining=p->show_remaining,
        .style=local_style(),.nozzle=p->show_nozzle?s->nozzle:"",.bed=p->show_bed?s->bed:"",.error=is_error?s->error:"",.time_text=time_text,.updated_text=updated_text,.image_label=p->live_image||!strncmp(p->image_entity,"camera.",7)?"实况":"任务",
        .show_temperature=p->show_nozzle||p->show_bed,.show_error=p->show_error,.is_error=is_error,
        .show_image=show_image&&(p->source_formlabs||*p->image_entity||*p->task_cover_entity||sources->thumbnail_status[index]==1),
        .formlabs=p->source_formlabs,.layers=layers,.material=p->source_formlabs&&p->show_material?s->material:""};
    if(p->brand_accent){value.style=local_style();if(!value.style.enabled)value.style=c6_renderer_default_style();value.style.accent=p->source_formlabs?0x2878DB:0x629E4E;value.style.enabled=true;}
    value.camera_configured=show_image&&!p->source_formlabs&&*p->image_entity&&(p->live_image||!strncmp(p->image_entity,"camera.",7));
    value.cover_configured=show_image&&(p->source_formlabs||*p->task_cover_entity||(*p->image_entity&&!value.camera_configured));
    value.demo=demo;value.card_style=p->card_style;value.remaining_seconds=remaining_seconds>UINT32_MAX?UINT32_MAX:(unsigned)remaining_seconds;
    value.remaining_available=s->remaining_valid;value.progress_available=s->progress_valid;
    uint64_t key=render_controls_key(UINT64_C(14695981039346656037));
    key=weather_hash_bytes(key,&index,sizeof(index));key=render_string_key(key,value.name);
    if(p->show_task)key=render_string_key(key,s->task);
    if(p->show_status){key=render_string_key(key,s->status);key=weather_hash_bytes(key,&s->connected,sizeof(s->connected));}
    if(p->show_progress){key=weather_hash_bytes(key,&s->progress,sizeof(s->progress));key=weather_hash_bytes(key,&s->progress_valid,sizeof(s->progress_valid));}
    if(p->show_remaining){key=render_string_key(key,time_text);key=weather_hash_bytes(key,&value.completed,sizeof(value.completed));}
    if(p->show_nozzle)key=render_string_key(key,s->nozzle);
    if(p->show_bed)key=render_string_key(key,s->bed);
    if(p->show_error)key=render_string_key(key,value.error);
    key=render_string_key(key,updated_text);
    key=render_string_key(key,layers);key=render_string_key(key,value.material);key=weather_hash_bytes(key,&p->source_formlabs,sizeof(p->source_formlabs));
    key=weather_hash_bytes(key,&value.card_style,sizeof(value.card_style));
    // Body icons depend on real status/connectivity even if the small header
    // status is hidden. A cloud change must not leave a stale ready icon.
    key=render_string_key(key,s->status);key=weather_hash_bytes(key,&s->connected,sizeof(s->connected));
    key=weather_hash_bytes(key,&value.is_error,sizeof(value.is_error));key=weather_hash_bytes(key,&value.completed,sizeof(value.completed));
    key=weather_hash_bytes(key,&value.demo,sizeof(value.demo));
    if(p->card_style==1)key=weather_hash_bytes(key,&value.progress,sizeof(value.progress));
    if(p->card_style==2)key=weather_hash_bytes(key,&value.completed,sizeof(value.completed));
    key=weather_hash_bytes(key,&value.progress_available,sizeof(value.progress_available));
    key=weather_hash_bytes(key,&value.remaining_available,sizeof(value.remaining_available));
    if(p->card_style==2){unsigned minutes=(unsigned)(((uint64_t)value.remaining_seconds+59)/60);key=weather_hash_bytes(key,&minutes,sizeof(minutes));}
    const bool flags[]={p->show_task,p->show_progress,p->show_status,p->show_remaining,p->show_image,p->show_nozzle,p->show_bed,p->show_error,p->brand_accent,p->live_image};key=weather_hash_bytes(key,flags,sizeof(flags));
    if(show_image){key=render_string_key(key,s->thumbnail_key);key=render_string_key(key,p->image_entity);key=render_string_key(key,p->task_cover_entity);key=weather_hash_bytes(key,&sources->thumbnail_status[index],sizeof(sources->thumbnail_status[index]));key=weather_hash_bytes(key,&sources->thumbnail_revision[index],sizeof(sources->thumbnail_revision[index]));unsigned k=C6_MAX_ENTITIES+index;key=weather_hash_bytes(key,&sources->media_status[k],sizeof(sources->media_status[k]));key=weather_hash_bytes(key,&sources->media_revision[k],sizeof(sources->media_revision[k]));}
    if(drawn&&key==visible_key&&rendered_generation==frame_generation)return;
    char picture_key[17];snprintf(picture_key,sizeof(picture_key),"%s",s->thumbnail_key);if(!*picture_key&&p->source_ha)c6_task_key("snapshot",*p->image_entity?p->image_entity:p->task_cover_entity,picture_key);
    if(show_image)c6_sources_printer_pictures_visit_scoped(p->serial,c6_printer_brand(p),c6_printer_source(p),picture_key,render_printer_pictures,&value);
    else c6_renderer_printer(renderer(),&value);
    calibrated_display();
    drawn=true;visible_key=key;rendered_generation=frame_generation;
}
static void draw_printer_overview(const c6_source_snapshot_t *sources){
    c6_sources_media_focus(-1,-1);
    static uint64_t visible_key;static uint32_t generation;static bool drawn;
    c6_render_printer_summary_t rows[C6_MAX_PRINTERS];unsigned count=standalone_config.printer_count;
    if(count>C6_MAX_PRINTERS)count=C6_MAX_PRINTERS;
    uint64_t key=render_controls_key(UINT64_C(14695981039346656037));key=weather_hash_bytes(key,&count,sizeof(count));
    for(unsigned i=0;i<count;i++){
        const c6_printer_config_t *p=&standalone_config.printers[i];const c6_printer_state_t *s=&sources->printers[i];
        rows[i]=(c6_render_printer_summary_t){.name=*p->name?p->name:p->serial,.status=s->status,.progress=s->progress,
            .enabled=p->enabled,.connected=p->enabled&&s->connected,.progress_available=p->enabled&&s->progress_valid,.demo=c6_form_is_demo(p),.formlabs=p->source_formlabs};
        key=weather_hash_bytes(key,&p->source_formlabs,sizeof(p->source_formlabs));
        key=weather_hash_bytes(key,&rows[i].demo,sizeof(rows[i].demo));
        key=render_string_key(key,rows[i].name);key=weather_hash_bytes(key,&rows[i].enabled,sizeof(rows[i].enabled));
        key=weather_hash_bytes(key,&rows[i].connected,sizeof(rows[i].connected));key=weather_hash_bytes(key,&rows[i].progress_available,sizeof(rows[i].progress_available));
        if(rows[i].enabled){if(rows[i].connected)key=render_string_key(key,s->status);if(rows[i].progress_available)key=weather_hash_bytes(key,&s->progress,sizeof(s->progress));}
    }
    if(drawn&&key==visible_key&&generation==frame_generation)return;
#if C6_FORMLABS_ONLY
    c6_renderer_printer_overview(renderer(),rows,count);
#else
    c6_render_style_t style=local_style();c6_renderer_printer_overview_styled(renderer(),rows,count,&style);
#endif
    calibrated_display();drawn=true;visible_key=key;generation=frame_generation;
}
static void draw_weather_content(const c6_source_snapshot_t *sources){
    const c6_weather_state_t *s=&sources->weather;time_t epoch=s->epoch+standalone_config.timezone;struct tm t;gmtime_r(&epoch,&t);
    c6_render_weather_t value={.city=*standalone_config.weather_city?standalone_config.weather_city:"天气",
        .temperature=s->temperature,.apparent=s->apparent,.low=s->low,.high=s->high,.code=s->code,.rain=s->rain,
        .updated_hour=t.tm_hour,.updated_minute=t.tm_min,.valid=s->valid,.stale=(uint64_t)time(NULL)>s->epoch+10800};
#if C6_FORMLABS_ONLY
    value.humidity=s->humidity;value.wind=s->wind;value.humidity_valid=s->humidity_valid;value.wind_valid=s->wind_valid;
#endif
    c6_renderer_weather(renderer(),&value);calibrated_display();
}
static uint64_t weather_hash_bytes(uint64_t hash,const void *bytes,size_t count){const uint8_t *p=bytes;for(size_t i=0;i<count;i++){hash^=p[i];hash*=UINT64_C(1099511628211);}return hash;}
static uint64_t weather_visible_key(const c6_weather_state_t *s){
    uint64_t hash=UINT64_C(14695981039346656037);
#define WEATHER_KEY(field) hash=weather_hash_bytes(hash,&(field),sizeof(field))
    WEATHER_KEY(s->valid);WEATHER_KEY(s->temperature);WEATHER_KEY(s->apparent);WEATHER_KEY(s->low);WEATHER_KEY(s->high);
    WEATHER_KEY(s->code);WEATHER_KEY(s->rain);WEATHER_KEY(s->epoch);
    bool stale=(uint64_t)time(NULL)>s->epoch+10800;WEATHER_KEY(stale);
    hash=weather_hash_bytes(hash,standalone_config.weather_city,strlen(standalone_config.weather_city));
    WEATHER_KEY(standalone_config.timezone);WEATHER_KEY(standalone_config.brightness);WEATHER_KEY(standalone_config.rotation);WEATHER_KEY(standalone_config.revision);
    WEATHER_KEY(standalone_config.saturation_percent);WEATHER_KEY(standalone_config.contrast_percent);
    WEATHER_KEY(standalone_config.language);WEATHER_KEY(standalone_config.digit_style);
#undef WEATHER_KEY
    return hash;
}
static void draw_weather(const c6_source_snapshot_t *sources){
    static uint64_t visible_key;static uint32_t rendered_generation;static bool rendered;
    uint64_t key=weather_visible_key(&sources->weather);
    if(rendered&&key==visible_key&&rendered_generation==frame_generation)return;
    draw_weather_content(sources);
    visible_key=key;rendered_generation=frame_generation;rendered=true;
}
