#pragma once
#include <stdbool.h>
#include <stdint.h>
enum { TERMINAL_OVERVIEW_PAGE=31 };
static inline bool terminal_overview_available(unsigned printer_count){return printer_count>=2;}
// Shared display policy. Canonical framebuffer is never rotated.
static inline bool terminal_rotation_valid(int rotation){return rotation>=0&&rotation<=270&&rotation%90==0;}
static inline unsigned terminal_source_pixel(int rotation,unsigned x,unsigned y){
    switch(rotation){case 90:return (239-x)*240+y;case 180:return (239-y)*240+239-x;case 270:return x*240+239-y;default:return y*240+x;}
}
static inline bool terminal_schedule_active(int start,int end,int minute){
    if(minute<0||start==end)return false;
    return start<end?(minute>=start&&minute<end):(minute>=start||minute<end);
}
static inline bool terminal_should_sleep(int mode,int idle_minutes,int start,int end,bool keep_printing,
    bool printing,bool menu,uint64_t now,uint64_t last_activity,bool manual_override,int local_minute){
    if(!mode||menu||(keep_printing&&printing))return false;
    bool idle=now>=last_activity&&now-last_activity>=(uint64_t)idle_minutes*60;
    if(mode==1)return idle;
    return terminal_schedule_active(start,end,local_minute)&&!(manual_override&&!idle);
}
