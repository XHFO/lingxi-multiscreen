#pragma once
#include "c6_display_renderer.h"
#include "firmware_profile.h"
// Pure, host-tested scheduling state. No task, network, allocation or framebuffer.
typedef struct {
    c6_render_clock_t previous,current;
    uint32_t utc,generation;
    int64_t started;
    bool has_frame,active;
} c6_clock_animation_t;
static inline bool c6_clock_animation_step(c6_clock_animation_t *state,
        const c6_render_clock_t *target,uint32_t utc,int64_t now,uint32_t generation,
        bool enabled,bool force,unsigned *progress){
    bool continuous=state->has_frame&&state->generation==generation&&!force;
    if(!continuous||!enabled)state->active=false;
    if(continuous&&utc==state->utc&&!state->active)return false;
    if(!continuous||utc!=state->utc){
        bool changed=state->current.hour!=target->hour||state->current.minute!=target->minute;
        if(enabled&&continuous&&utc==state->utc+1&&changed){state->previous=state->current;state->started=now;state->active=true;}
        else state->active=false;
        state->current=*target;
    }
    state->utc=utc;
    int64_t elapsed=now-state->started;
    if(elapsed<0)elapsed=0;
    *progress=state->active?(unsigned)(elapsed*1000/C6_CLOCK_DURATION_US):1000;
    if(*progress>=1000){*progress=1000;state->active=false;}
    return true;
}
static inline void c6_clock_animation_commit(c6_clock_animation_t *state,uint32_t generation){state->generation=generation;state->has_frame=true;}
static inline void c6_clock_animation_cancel(c6_clock_animation_t *state){state->active=false;state->has_frame=false;}
