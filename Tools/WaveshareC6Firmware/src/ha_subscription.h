#pragma once
#include "standalone.h"
#include <string.h>
#include <stdio.h>
#define C6_HA_IDS (C6_MAX_ENTITIES+C6_MAX_PRINTERS*10)
// HA needs selected IDs, not printer certificates, cloud credentials or themes.
typedef struct {
    char ha_host[16],ha_token[1024];int ha_port;bool ha_tls;
    unsigned count;char ids[C6_HA_IDS][128];
} c6_ha_config_t;
static inline void c6_ha_add(c6_ha_config_t *out,const char *id){
    if(!*id||out->count>=C6_HA_IDS)return;
    for(unsigned n=0;n<out->count;n++)if(!strcmp(out->ids[n],id))return;
    snprintf(out->ids[out->count++],128,"%s",id);
}
static inline void c6_ha_project(const standalone_config_t *c,c6_ha_config_t *out){
    memset(out,0,sizeof(*out));if(!c->enabled||!c->ha_enabled)return;
    memcpy(out->ha_host,c->ha_host,sizeof(out->ha_host));memcpy(out->ha_token,c->ha_token,sizeof(out->ha_token));out->ha_port=c->ha_port;out->ha_tls=c->ha_tls;
    for(unsigned i=0;i<c->entity_count;i++)c6_ha_add(out,c->entities[i].id);
    for(unsigned i=0;i<c->printer_count;i++)if(c->printers[i].enabled&&c->printers[i].source_ha){
        const c6_printer_config_t *p=&c->printers[i];
        const char *fields[]={p->status_entity,p->progress_entity,p->task_entity,p->remaining_entity,p->show_image?p->image_entity:"",p->show_nozzle?p->nozzle_entity:"",p->show_bed?p->bed_entity:"",p->show_error?p->error_entity:"",p->show_remaining&&p->time_mode==1?p->end_time_entity:"",p->show_image?p->task_cover_entity:""};
        for(unsigned k=0;k<10;k++)c6_ha_add(out,fields[k]);
    }
}
static inline unsigned ha_ids(const c6_ha_config_t *c,const char **ids){
    for(unsigned i=0;i<c->count;i++)ids[i]=c->ids[i];
    return c->count;
}
