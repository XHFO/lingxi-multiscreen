#pragma once
#include "standalone.h"
#include "terminal_display_policy.h"
#include <stdio.h>
#include <string.h>

// An origin is a public endpoint/account identifier, never a token or secret.
// Native pages cannot accidentally follow a same-named device to another source.
static void c6_ha_origin(const standalone_config_t *c,char *out,size_t size){snprintf(out,size,"%s:%d:%d",c->ha_host,c->ha_port,c->ha_tls?1:0);}
static void c6_printer_origin(const standalone_config_t *c,const c6_printer_config_t *p,char *out,size_t size){
    if(p->source_formlabs)snprintf(out,size,"%s",p->form_client_id);
    else if(p->source_ha)c6_ha_origin(c,out,size);
    else snprintf(out,size,"%s",p->host);
}

// Match a feature/physical device, never its editable display name. A disabled
// native card does not replace a Mac card; diagnostics != Mac system monitor.
// Explicit selections are members of the computer-owned playlist even while
// software data has priority. Masks/rotate only govern offline rotation and
// legacy replacement: a configured card can also be opened manually.
static int c6_native_target(const standalone_config_t *c,const char *kind,const char *serial,const char *brand,const char *source,const char *origin,unsigned group,bool explicit_native){
    if(!c->enabled||(!explicit_native&&!c->local_first))return -1;
    if(!strcmp(kind,"clock"))return c->clock&&(explicit_native||(c->card_mask&1))?0:-1;
    if(!strcmp(kind,"diagnostics"))return explicit_native&&!C6_FORMLABS_ONLY&&c->diagnostics?1:-1;
    if(!strcmp(kind,"weather"))return c->weather&&(explicit_native||(c->card_mask&4))?2:-1;
    if(!strcmp(kind,"ha")){
        char configured_origin[160];c6_ha_origin(c,configured_origin,sizeof(configured_origin));
        return !C6_FORMLABS_ONLY&&c->ha_enabled&&c->entity_count&&
            (explicit_native||(c->card_mask&8))&&group<(c->entity_count+3)/4&&
            (!explicit_native||!strcmp(origin,configured_origin))?10+(int)group:-1;
    }
    if(!strcmp(kind,"overview"))return explicit_native&&terminal_overview_available(c6_overview_printer_count(c))?TERMINAL_OVERVIEW_PAGE:-1;
    if(strcmp(kind,"printer")||!*serial||!*brand||!*source||(explicit_native&&!*origin))return -1;
    int found=-1;
    for(unsigned i=0;i<c->printer_count;i++){
        const c6_printer_config_t *p=&c->printers[i];
        char configured_origin[160];c6_printer_origin(c,p,configured_origin,sizeof(configured_origin));
        if(p->enabled&&(explicit_native||p->rotate)&&!strcmp(p->serial,serial)&&!strcmp(c6_printer_brand(p),brand)&&!strcmp(c6_printer_source(p),source)&&
           (!*origin||!strcmp(configured_origin,origin))){
            if(found>=0)return -1;
            found=20+(int)i;
        }
    }
    return found;
}
static int c6_hybrid_target(const standalone_config_t *c,const char *kind,const char *serial,const char *brand,const char *source){
    return c6_native_target(c,kind,serial,brand,source,"",0,false);
}
