#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef enum {C6_BUTTON_NONE,C6_BUTTON_SINGLE,C6_BUTTON_DOUBLE,C6_BUTTON_HOLD} c6_button_event_t;
typedef struct {
    bool raw,stable,armed,held,pending;
    int64_t changed,pressed,pressed_raw,released;
} c6_button_input_t;
static inline void c6_button_init(c6_button_input_t *b,bool level,int64_t now){
    *b=(c6_button_input_t){.raw=level,.stable=level,.armed=level,.changed=now};
}
// Monotonic milliseconds; active-low BOOT. No release event after a hold.
static inline c6_button_event_t c6_button_sample(c6_button_input_t *b,bool level,int64_t now){
    if(level!=b->raw){b->raw=level;b->changed=now;}
    if(level!=b->stable&&now-b->changed>=35){
        b->stable=level;
        if(!level&&b->armed){
            b->pressed=now;b->pressed_raw=b->changed;b->held=false;
            if(b->pending&&b->pressed_raw-b->released>250){b->pending=false;return C6_BUTTON_SINGLE;}
        }
        if(level){
            if(b->armed&&!b->held&&now-b->pressed>=40){
                if(b->pending&&b->pressed_raw-b->released<=250){b->pending=false;return C6_BUTTON_DOUBLE;}
                b->pending=true;b->released=now;
            }
            b->armed=true;b->held=false;
        }
    }
    if(!b->stable&&b->armed&&!b->held&&now-b->pressed>=1500){
        b->held=true;b->pending=false;return C6_BUTTON_HOLD;
    }
    // Wait through a second press (including its debounce), not just its release.
    if(b->pending&&b->stable&&b->raw&&now-b->released>250){b->pending=false;return C6_BUTTON_SINGLE;}
    return C6_BUTTON_NONE;
}
