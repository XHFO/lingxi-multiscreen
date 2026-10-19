#pragma once
#include "local_state.h"
#include <string.h>
#include <stdio.h>
// Reserved, exact serials on the dedicated profile only. Never infer a demo
// from an authentication/network failure or from a real printer's identity.
static inline unsigned c6_form_demo_id(const char *serial){
#if C6_FORMLABS_ONLY
    if(serial&&strlen(serial)==7&&!strncmp(serial,";;tex_",6)&&serial[6]>='1'&&serial[6]<='4')return (unsigned)(serial[6]-'0');
#else
    (void)serial;
#endif
    return 0;
}
static inline bool c6_form_is_demo(const c6_printer_config_t *p){return p->source_formlabs&&c6_form_demo_id(p->serial)!=0;}
static inline bool c6_form_pollable(const c6_printer_config_t *p){return p->enabled&&p->source_formlabs&&!c6_form_is_demo(p);}
static inline bool c6_form_demo_seed(const c6_printer_config_t *p,c6_printer_state_t *s){
#if C6_FORMLABS_ONLY
    unsigned id=p->source_formlabs?c6_form_demo_id(p->serial):0;if(!id)return false;
    memset(s,0,sizeof(*s));s->known=true;s->connected=p->enabled;
    const char *statuses[]={"idle","printing","finished","failed"};
    snprintf(s->status,sizeof(s->status),"%s",statuses[id-1]);
    if(id>1){snprintf(s->task,sizeof(s->task),"DEMO / Turbine housing");snprintf(s->material,sizeof(s->material),"Grey V5");s->progress_valid=true;s->layer_count=1200;}
    if(id==2){s->progress=74;s->layer=888;s->remaining=42;s->remaining_valid=true;}
    if(id==3){s->progress=100;s->layer=1200;s->remaining_valid=true;s->completed_at=1;}
    if(id==4){s->progress=32;s->layer=384;snprintf(s->error,sizeof(s->error),"DEMO / Print error");}
    // No wall/monotonic timestamps, end time, thumbnail key or cloud task id.
    // Restarts and reorders produce the exact same immutable local snapshot.
    return true;
#else
    (void)p;(void)s;return false;
#endif
}
