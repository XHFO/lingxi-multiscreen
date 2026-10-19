#include <assert.h>
#include <stdio.h>
#include "../../Tools/WaveshareC6Firmware/src/menu_state.h"
static c6_button_input_t b;static int64_t now;static unsigned events[4];
static void init(bool level){now=0;for(unsigned i=0;i<4;i++)events[i]=0;c6_button_init(&b,level,now);}
static void drive(bool level,int duration){for(int i=0;i<duration;i+=5){now+=5;c6_button_event_t e=c6_button_sample(&b,level,now);if(e)events[e]++;}}
static void click(void){drive(false,100);drive(true,100);}
int main(void){
    init(true);click();assert(!events[C6_BUTTON_SINGLE]);drive(true,200);assert(events[C6_BUTTON_SINGLE]==1);drive(true,1000);assert(events[C6_BUTTON_SINGLE]==1);
    init(true);click();click();drive(true,400);assert(events[C6_BUTTON_DOUBLE]==1&&!events[C6_BUTTON_SINGLE]);
    init(true);drive(false,1700);assert(events[C6_BUTTON_HOLD]==1);drive(false,1000);drive(true,500);assert(events[C6_BUTTON_HOLD]==1&&!events[C6_BUTTON_SINGLE]&&!events[C6_BUTTON_DOUBLE]);
    init(false);drive(false,2000);drive(true,500);assert(!events[C6_BUTTON_HOLD]&&!events[C6_BUTTON_SINGLE]);click();drive(true,300);assert(events[C6_BUTTON_SINGLE]==1);
    init(true);for(int i=0;i<10;i++){drive(false,10);drive(true,10);}drive(true,500);assert(!events[C6_BUTTON_SINGLE]&&!events[C6_BUTTON_DOUBLE]);
    init(true);click();drive(true,400);click();drive(true,400);assert(events[C6_BUTTON_SINGLE]==2&&!events[C6_BUTTON_DOUBLE]);
    init(true);click();drive(true,170);click();drive(true,400);assert(events[C6_BUTTON_DOUBLE]==1&&!events[C6_BUTTON_SINGLE]); // Raw second press at window edge, despite debounce.
    init(true);click();drive(false,1800);drive(true,500);assert(events[C6_BUTTON_HOLD]==1&&!events[C6_BUTTON_SINGLE]&&!events[C6_BUTTON_DOUBLE]);
    c6_menu_t m={0};assert(!c6_menu_current(&m));c6_menu_open(&m,C6_MENU_SETTINGS,true,0);assert(m.depth==1&&m.software_owner);
    c6_menu_next(&m,3,1);c6_menu_next(&m,3,2);assert(c6_menu_current(&m)->selected==2);c6_menu_next(&m,3,3);assert(c6_menu_current(&m)->selected==0);
    assert(c6_menu_enter(&m,C6_MENU_NETWORK,4));assert(c6_menu_enter(&m,C6_MENU_RESET,5));assert(c6_menu_current(&m)->selected==0); // Cancel is always first.
    assert(!c6_menu_timeout(&m,300000));c6_menu_back(&m,6);assert(c6_menu_current(&m)->view==C6_MENU_NETWORK);c6_menu_back(&m,7);c6_menu_back(&m,8);assert(!m.depth);
    c6_menu_open(&m,C6_MENU_WEATHER,false,0);assert(!c6_menu_timeout(&m,29999));assert(c6_menu_timeout(&m,30000)&&!m.depth);
    c6_menu_open(&m,C6_MENU_ENTITIES,false,0);c6_menu_next(&m,0,1);assert(!c6_menu_current(&m)->selected);
    puts("C6 BOOT: debounce, single/double separation, hold-once, no release click, startup suppression; menu: bounded stack, cancel-default, timeout and cycling passed");
}
