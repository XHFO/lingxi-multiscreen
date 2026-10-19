#pragma once
#include "standalone.h"
#include "form_demo.h"
#include <stddef.h>
#include <string.h>
enum { C6_WORK_HA, C6_WORK_MQTT, C6_WORK_FORM, C6_WORK_MEDIA };
static inline bool c6_source_needed(const standalone_config_t *c,unsigned work){
    if(!c->enabled)return false;
    if(work==C6_WORK_HA&&c->ha_enabled&&c->entity_count)return true;
    if(work==C6_WORK_MEDIA&&c->ha_enabled)for(unsigned i=0;i<c->entity_count;i++)
        if(!strncmp(c->entities[i].id,"camera.",7)||!strncmp(c->entities[i].id,"image.",6))return true;
    for(unsigned i=0;i<c->printer_count;i++){
        const c6_printer_config_t *p=&c->printers[i];if(!p->enabled)continue;
        if(work==C6_WORK_HA&&c->ha_enabled&&p->source_ha)return true;
        if(work==C6_WORK_MQTT&&!p->source_ha&&!p->source_formlabs)return true;
        if(work==C6_WORK_FORM&&c6_form_pollable(p))return true;
        if(work==C6_WORK_MEDIA&&c->ha_enabled&&p->source_ha&&p->show_image&&(*p->image_entity||*p->task_cover_entity))return true;
    }
    return false;
}
// Preserve subscription/UI headroom; total free bytes alone hide fragmentation.
static inline bool c6_http_budget(bool tls,size_t free_bytes,size_t largest){
    return free_bytes>=(tls?90000U:64000U)&&largest>=(tls?32768U:16384U);
}
