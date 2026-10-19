#pragma once
#include "button_input.h"
#include <stddef.h>
typedef enum {C6_MENU_CLOSED,C6_MENU_SETTINGS,C6_MENU_PIN,C6_MENU_NETWORK,C6_MENU_RESET,C6_MENU_INFO,C6_MENU_CLOCK,C6_MENU_WEATHER,C6_MENU_ENTITIES,C6_MENU_ENTITY,C6_MENU_PRINTER,C6_MENU_GENERIC,C6_MENU_DISPLAY,C6_MENU_CARDS,C6_MENU_WEB} c6_menu_view_t;
typedef struct {c6_menu_view_t view;unsigned selected;} c6_menu_level_t;
typedef struct {c6_menu_level_t levels[4];unsigned depth;int64_t touched;uint32_t revision;bool software_owner;} c6_menu_t;
static inline c6_menu_level_t *c6_menu_current(c6_menu_t *m){return m->depth?&m->levels[m->depth-1]:NULL;}
static inline void c6_menu_open(c6_menu_t *m,c6_menu_view_t view,bool software,int64_t now){
    m->depth=1;m->levels[0]=(c6_menu_level_t){view,0};m->software_owner=software;m->touched=now;m->revision++;
}
static inline bool c6_menu_enter(c6_menu_t *m,c6_menu_view_t view,int64_t now){
    if(m->depth>=4)return false;
    m->levels[m->depth++]=(c6_menu_level_t){view,0};m->touched=now;m->revision++;return true;
}
static inline void c6_menu_back(c6_menu_t *m,int64_t now){if(m->depth){m->depth--;m->touched=now;m->revision++;}}
static inline void c6_menu_next(c6_menu_t *m,unsigned count,int64_t now){
    c6_menu_level_t *p=c6_menu_current(m);if(p&&count){p->selected=(p->selected+1)%count;m->touched=now;m->revision++;}
}
static inline bool c6_menu_timeout(c6_menu_t *m,int64_t now){
    // Settings/confirmation never execute or dismiss because of a timeout.
    if(m->depth&&m->levels[0].view!=C6_MENU_SETTINGS&&now-m->touched>=30000){m->depth=0;m->revision++;return true;}return false;
}
