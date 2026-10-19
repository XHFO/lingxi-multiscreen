#define main baseline_main
#include "firmware_contract.c"
#undef main
#include <time.h>
#include "../../Sources/C6DisplayRenderer/include/c6_display_renderer.h"
#include "../../Tools/WaveshareC6Firmware/src/menu_state.h"
#include "../../Tools/WaveshareC6Firmware/src/local_sources.h"
static c6_menu_t device_menu;
static unsigned local_page,local_step_pending;static uint32_t view_revision,revision,frame_generation,last_clock_second,button_sequence;
static bool native_clock,software_visible,pairing_visible,display_rotated;static uint64_t software_heartbeat;static int64_t software_simulation_until,page_since;
static int brightness=80;static char hostname[40]="lingxi-c6-test",ip[16]="192.168.1.8";
static int terminal_rotation;
static unsigned resets,frames;static c6_source_snapshot_t snapshot;
uint64_t c6_seconds(void){return 100;}
void c6_sources_snapshot(c6_source_snapshot_t *s){*s=snapshot;}
bool c6_sources_try_snapshot(c6_source_snapshot_t *s){*s=snapshot;return true;}
bool c6_sources_weather_refresh(void){return false;}
void c6_sources_display_options(int revision,bool flip_animation){assert(revision==standalone_config.revision&&flip_animation==standalone_config.flip_animation);}
static bool c6_simulation_active(int64_t deadline,int64_t now){return false;}
static bool software_controls(void){return !standalone_config.enabled||(software_heartbeat&&c6_seconds()-software_heartbeat<30);}
static unsigned local_pages(unsigned *pages,const c6_source_snapshot_t *s){return 1;}
static void set_brightness(int level){}
static void display_frame(void){frames++;frame_generation++;}
static void calibrated_display(void){display_frame();}
static c6_render_style_t local_style(void){return (c6_render_style_t){0};}
static c6_renderer_t *renderer(void){return NULL;}
void c6_renderer_message(c6_renderer_t *r,const char *title,const char *text){}
int c6_renderer_text_width(const char *s,unsigned size){return 128;}
void c6_renderer_label(c6_renderer_t *r,const char *s,int x,int y,unsigned size,int width,uint32_t color){}
void c6_renderer_menu(c6_renderer_t *r,const char *title,const c6_render_menu_row_t *rows,unsigned count,unsigned selected,const char *footer,const c6_render_style_t *style){}
void c6_renderer_pairing(c6_renderer_t *r,const char *pin,int seconds,const c6_render_style_t *style){}
bool c6_renderer_qr(c6_renderer_t *r,const char *url,const char *address,const c6_render_style_t *style){assert(strstr(url,"/standalone")&&!strstr(url,standalone_token));return true;}
const char *c6_renderer_print_status(const char *s){return s;}
const char *c6_renderer_localized(c6_renderer_t *r,const char *s){return s;}
typedef struct {uint8_t ssid[33];} wifi_ap_record_t;
static int esp_wifi_sta_get_ap_info(wifi_ap_record_t *r){return ESP_FAIL;}
#include "../../Tools/WaveshareC6Firmware/src/local_menu.h"
static bool reset_station_wifi(void){resets++;return true;}
int main(void){
    baseline_main();standalone_config.local_first=false;standalone_config.enabled=true;software_visible=true;software_heartbeat=100;
    menu_gesture(C6_BUTTON_SINGLE);assert(button_sequence==1&&!local_step_pending);
    standalone_config.local_first=true;
    menu_gesture(C6_BUTTON_SINGLE);assert(button_sequence==2&&!local_step_pending);
    standalone_config.local_first=false;
    for(unsigned cycle=0;cycle<1000;cycle++){
        menu_gesture(C6_BUTTON_HOLD);menu_build();assert(device_menu.depth==1&&!strcmp(menu_labels[0],"屏幕显示")&&menu_row_count==5);
        menu_gesture(C6_BUTTON_DOUBLE);assert(c6_menu_current(&device_menu)->view==C6_MENU_DISPLAY);
        int old=standalone_config.rotation,version=standalone_config.revision;bool flip=standalone_config.flip_animation;
        menu_gesture(C6_BUTTON_DOUBLE);assert(standalone_config.rotation==old&&menu_draft.dirty);
        menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);assert(standalone_config.flip_animation==flip);
        menu_gesture(C6_BUTTON_HOLD);assert(standalone_config.rotation!=old&&standalone_config.flip_animation!=flip&&standalone_config.revision==version+1);
        menu_build();assert(menu_row_count==5);menu_gesture(C6_BUTTON_HOLD);assert(!device_menu.depth);
    }
    menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);
    assert(c6_menu_current(&device_menu)->view==C6_MENU_CARDS);int mask=standalone_config.card_mask;
    menu_gesture(C6_BUTTON_DOUBLE);assert(menu_draft.card_mask==(mask^1)&&standalone_config.card_mask==mask);
    fail_storage=1;menu_gesture(C6_BUTTON_HOLD);assert(c6_menu_current(&device_menu)->view==C6_MENU_CARDS&&standalone_config.card_mask==mask&&menu_draft.dirty);
    menu_build();for(unsigned i=0;i<menu_row_count;i++)assert(strcmp(menu_labels[i],"结果"));
    fail_storage=0;menu_gesture(C6_BUTTON_HOLD);assert(standalone_config.card_mask==(mask^1));
    menu_gesture(C6_BUTTON_HOLD);
    menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_DOUBLE);menu_gesture(C6_BUTTON_DOUBLE);
    standalone_config.revision++;int current=standalone_config.rotation;menu_gesture(C6_BUTTON_HOLD);
    assert(standalone_config.rotation==current&&!menu_draft.dirty&&c6_menu_current(&device_menu)->view==C6_MENU_DISPLAY);
    menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_HOLD);
    menu_gesture(C6_BUTTON_HOLD);for(unsigned i=0;i<3;i++)menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);
    assert(c6_menu_current(&device_menu)->view==C6_MENU_NETWORK);
    menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);
    assert(c6_menu_current(&device_menu)->view==C6_MENU_RESET&&c6_menu_current(&device_menu)->selected==0);
    menu_gesture(C6_BUTTON_DOUBLE);assert(!resets);
    menu_gesture(C6_BUTTON_DOUBLE);menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);assert(resets==1);
    menu_build();assert(menu_row_count==3&&!strcmp(menu_labels[2],"重置 Wi-Fi"));
    menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_HOLD);
    software_heartbeat=0;software_visible=false;local_context=(c6_card_context_t){.kind=C6_CARD_HA};
    strcpy(standalone_config.entities[0].id,"sensor.test");strcpy(standalone_config.entities[0].name,"测试实体");standalone_config.entity_count=1;
    menu_gesture(C6_BUTTON_DOUBLE);menu_gesture(C6_BUTTON_DOUBLE);assert(c6_menu_current(&device_menu)->view==C6_MENU_ENTITY);
    strcpy(standalone_config.entities[0].id,"sensor.other");menu_build();assert(!strcmp(menu_labels[0],"实体已移除"));
    device_menu.depth=0;standalone_config.printer_count=2;
    for(unsigned i=0;i<2;i++){standalone_config.printers[i].enabled=true;standalone_config.printers[i].rotate=true;strcpy(standalone_config.printers[i].serial,"same-serial");}
    standalone_config.printers[1].source_formlabs=true;
    menu_set_printer(&local_context,1);menu_gesture(C6_BUTTON_DOUBLE);assert(menu_printer_index()==1);
    standalone_config.printers[0].source_formlabs=true;assert(menu_printer_index()==-1);
    device_menu.depth=0;menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);
    for(unsigned i=0;i<4;i++)menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);
    assert(menu_draft.printers==2&&standalone_config.printers[0].rotate);menu_gesture(C6_BUTTON_HOLD);
    assert(!standalone_config.printers[0].rotate&&standalone_config.printers[0].enabled&&standalone_config.printers[1].rotate);
    menu_gesture(C6_BUTTON_HOLD);menu_gesture(C6_BUTTON_HOLD);for(unsigned i=0;i<2;i++)menu_gesture(C6_BUTTON_SINGLE);menu_gesture(C6_BUTTON_DOUBLE);menu_render();
    assert(c6_menu_current(&device_menu)->view==C6_MENU_WEB);
    puts("C6 actual menu actions: 1000 return-autosave cycles; no result rows; display/card choices, NVS failure retry, conflict protection, reset cancellation, entity removal, brand isolation and LAN QR passed");
}
