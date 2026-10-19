// Execute production native selection and display ownership with hardware mocks.
import {readFileSync,mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/main.c'),'utf8');
const menu=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_menu.h'),'utf8');
const between=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const ownership=between('static unsigned local_pages(', '#include "local_menu.h"');
const display=between('static void local_display(void *arg) {','static bool local_work_queued;');
const select=between('static esp_err_t native_card_handler(', 'static esp_err_t simulation_handler(');
const contexts=menu.slice(menu.indexOf('typedef enum {C6_CARD_GENERIC'),menu.indexOf('static char menu_entity_id'));
const contextHandlers=menu.slice(menu.indexOf('static void menu_set_printer('),menu.indexOf('static void menu_capture_context('));
const cjson=process.env.LINGXI_CJSON_ROOT??join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const stage=mkdtempSync(join(tmpdir(),'lingxi-c6-hybrid-'));
const program=`
#define main baseline_main
#include "${root}Tools/C6StandaloneTests/firmware_contract.c"
#undef main
#include <time.h>
#include "hybrid_cards.h"
#include "menu_state.h"
#include "local_sources.h"
#include "${root}Sources/C6DisplayRenderer/include/c6_display_renderer.h"
${contexts}
static c6_menu_t device_menu;
static struct {bool dirty;} menu_draft;
static bool station_joined_pending,station_offline,network_notice,network_notice_drawn,native_clock,pairing_visible,software_visible,local_visible;
static int64_t hotspot_close_at,software_simulation_until,page_since,clock_anchor;
static uint64_t software_heartbeat,clock_epoch;
static int hybrid_page=-1,brightness=80,clock_timezone,native_clock_style;
static int terminal_preview_page=-1;static int64_t terminal_preview_until;
static bool terminal_asleep;
static bool terminal_guide_offered,terminal_guide_qr,terminal_guide_empty,setup_notice_drawn;
static bool setup_display_notice(void){return false;}
static unsigned hybrid_ha_next,local_page,local_step_pending,last_clock_second,revision;
static unsigned draws,clock_draws,drawn_page=999;
static char ip[16]="192.168.1.8";
static c6_source_snapshot_t snapshot;
bool c6_sources_weather_available(void){return snapshot.weather.valid;}
typedef int wifi_mode_t;
#define WIFI_MODE_APSTA 3
#define WIFI_MODE_STA 1
static int esp_wifi_get_mode(wifi_mode_t *m){*m=WIFI_MODE_STA;return ESP_OK;}
static int esp_wifi_set_mode(wifi_mode_t m){return ESP_OK;}
uint64_t c6_seconds(void){return test_now/1000000;}
static unsigned esp_get_free_heap_size(void){return 60000;}
static bool c6_simulation_active(int64_t until,int64_t now){return until>now;}
static bool menu_save_draft(void){return true;}
static void menu_return_to_card(void){}
static void menu_render(void){}
static void finish_pairing_display(bool b){}
static void set_brightness(int level){}
static c6_render_style_t local_style(void){return (c6_render_style_t){0};}
static c6_renderer_t *renderer(void){return NULL;}
const char *c6_renderer_localized(c6_renderer_t *r,const char *s){return s;}
#include "${root}/Tools/WaveshareC6Firmware/src/local_language.h"
static void calibrated_display(void){draws++;}
void c6_renderer_menu(c6_renderer_t *r,const char *title,const c6_render_menu_row_t *rows,unsigned count,unsigned selected,const char *footer,const c6_render_style_t *s){}
void c6_renderer_pairing(c6_renderer_t *r,const char *pin,int seconds,const c6_render_style_t *s){}
bool c6_renderer_setup_qr(c6_renderer_t *r,const char *payload,const char *title,const char *address,const char *footer,const c6_render_style_t *s){return true;}
static const c6_source_snapshot_t *display_sources(void){return &snapshot;}
void c6_sources_media_focus(int e,int p){}
static void draw_clock(void *a){clock_draws++;}
static void draw_weather(const c6_source_snapshot_t *s){drawn_page=2;draws++;}
static void draw_printer(unsigned p,const c6_source_snapshot_t *s){drawn_page=20+p;draws++;}
static void draw_printer_overview(const c6_source_snapshot_t *s){drawn_page=31;draws++;}
static void draw_entity(unsigned p,const c6_source_snapshot_t *s){drawn_page=10+p;draws++;}
${contextHandlers}
static esp_err_t httpd_resp_send(httpd_req_t *r,const char *s,int n){if(!r->status)r->status=200;return ESP_OK;}
${ownership}
${display}
${select}
static int pick(c6_card_kind_t kind,const char *serial,const char *brand,const char *source){
 const char *card=kind==C6_CARD_CLOCK?"clock":kind==C6_CARD_WEATHER?"weather":kind==C6_CARD_HA?"ha":kind==C6_CARD_PRINTER?"printer":"generic";
 httpd_req_t r={.auth="Bearer 1234abcd1234abcd",.card=card,.serial=serial,.brand=brand,.source=source};native_card_handler(&r);return r.status;
}
static int native(const char *card,const char *serial,const char *brand,const char *source,const char *origin,const char *group){httpd_req_t r={.auth="Bearer 1234abcd1234abcd",.card=card,.native="1",.serial=serial,.brand=brand,.source=source,.origin=origin,.group=group};native_card_handler(&r);return r.status;}
int main(void){
 baseline_main();standalone_pairing_close();standalone_config.enabled=true;standalone_config.local_first=true;
 standalone_config.weather=true;standalone_config.ha_enabled=true;standalone_config.entity_count=6;
 standalone_config.clock=true;standalone_config.card_mask=13;standalone_config.interval=5;test_now=100000000;
 standalone_config.printer_count=3;
 memset(standalone_config.printers,0,sizeof(standalone_config.printers));
 for(unsigned i=0;i<3;i++){c6_printer_config_t *p=&standalone_config.printers[i];p->enabled=true;p->rotate=true;strcpy(p->name,"相同名称");strcpy(p->serial,"same-serial");}
 standalone_config.printers[0].source_ha=true;standalone_config.printers[1].source_formlabs=true;
 strcpy(standalone_config.ha_host,"192.168.1.10");standalone_config.ha_port=8123;standalone_config.ha_tls=false;
 strcpy(standalone_config.printers[1].form_client_id,"fixture-cloud-client");strcpy(standalone_config.printers[2].host,"192.168.1.20");
 assert(c6_hybrid_target(&standalone_config,"printer","same-serial","bambu","ha")==20);
 assert(c6_hybrid_target(&standalone_config,"printer","same-serial","formlabs","formlabs")==21);
 assert(c6_hybrid_target(&standalone_config,"printer","same-serial","bambu","mqtt")==22);
 assert(c6_hybrid_target(&standalone_config,"printer","same-serial","formlabs","ha")==-1);
 assert(c6_hybrid_target(&standalone_config,"generic","","","")==-1);
 httpd_req_t unauth={0};native_card_handler(&unauth);assert(unauth.status==401&&hybrid_page==-1);
 assert(pick(C6_CARD_WEATHER,"","","")==404&&hybrid_page==-1&&!software_visible);
 snapshot.weather.valid=true;
 assert(pick(C6_CARD_WEATHER,"","","")==200&&hybrid_page==2&&drawn_page==2&&software_visible&&software_controls());
 // A live native card is one member of the Mac playlist, not a second carousel.
 test_now+=10000000;local_display(NULL);assert(hybrid_page==2&&drawn_page==2&&local_page==0);
 int version=standalone_config.revision;
 assert(pick(C6_CARD_PRINTER,"same-serial","formlabs","formlabs")==200&&drawn_page==21);
 assert(standalone_config.revision==version);
 c6_card_context_t before=software_context;unsigned old_draws=draws;
 assert(pick(C6_CARD_PRINTER,"other-device","bambu","ha")==404&&hybrid_page==21&&draws==old_draws&&!memcmp(&before,&software_context,sizeof(before)));
 standalone_config.printers[1].rotate=false;
 assert(pick(C6_CARD_PRINTER,"same-serial","formlabs","formlabs")==404&&hybrid_page==21);
 standalone_config.printers[1].rotate=true;
 standalone_config.printers[2].source_ha=true;
 assert(pick(C6_CARD_PRINTER,"same-serial","bambu","ha")==404); // Ambiguous identity never guesses.
 standalone_config.printers[2].source_ha=false;
 device_menu.depth=1;old_draws=draws;
 assert(pick(C6_CARD_WEATHER,"","","")==204&&hybrid_page==21&&draws==old_draws);device_menu.depth=0;
 software_simulation_until=test_now+10000000;
 assert(pick(C6_CARD_WEATHER,"","","")==204&&hybrid_page==21);software_simulation_until=0;
 httpd_req_t body={.auth="Bearer 1234abcd1234abcd",.content_len=1};native_card_handler(&body);assert(body.status==400);
 assert(pick(C6_CARD_HA,"","","")==200&&hybrid_page==10);
 for(unsigned i=0;i<20;i++)assert(pick(C6_CARD_HA,"","","")==200&&hybrid_page==10);
 assert(pick(C6_CARD_WEATHER,"","","")==200);
 assert(pick(C6_CARD_HA,"","","")==200&&hybrid_page==11); // Entities 5/6 appear on next entry.
 standalone_config.card_mask=5;
 assert(pick(C6_CARD_HA,"","","")==404);standalone_config.card_mask=13;
 // Accepted generic frames set hybrid_page=-1; the production handler is
 // separately executed in button_api_contract. Here verify the display owner
 // leaves that external frame untouched until the actual lease expires.
 hybrid_page=-1;local_visible=false;native_clock=false;software_visible=true;software_heartbeat=c6_seconds();
 old_draws=draws;local_display(NULL);assert(draws==old_draws&&hybrid_page==-1);
 test_now+=29000000;assert(software_controls());local_display(NULL);assert(draws==old_draws);
 test_now+=1000000;assert(!software_controls());local_display(NULL);assert(local_visible&&draws>old_draws&&!software_visible);
 assert(pick(C6_CARD_WEATHER,"","","")==200&&hybrid_page==2&&software_controls());
 standalone_config.local_first=false;assert(pick(C6_CARD_WEATHER,"","","")==404);
 // Version 2: explicit native members coexist with software-first cards. Device
 // masks/rotate only affect automatic rotation, not manual configured selection.
 version=standalone_config.revision;standalone_config.card_mask=0;standalone_config.diagnostics=true;
 standalone_config.clock_style=1;standalone_config.timezone=3600;standalone_config.digit_style=1;
 assert(native("clock","","","","",NULL)==200&&hybrid_page==0&&native_clock&&native_clock_style==1&&clock_timezone==3600);
 assert(standalone_config.clock_style==1&&standalone_config.digit_style==1&&standalone_config.timezone==3600&&standalone_config.revision==version);
 unsigned before_clock=clock_draws;test_now+=15000000;local_display(NULL);assert(hybrid_page==0&&clock_draws>before_clock&&local_page==0);
 assert(native("diagnostics","","","","",NULL)==200&&hybrid_page==1&&software_context.kind==C6_CARD_DIAGNOSTICS);
 snapshot.weather.valid=false;assert(native("weather","","","","",NULL)==200&&hybrid_page==2&&drawn_page==2); // Native loading state, no Mac fallback.
 assert(native("ha","","","","192.168.1.10:8123:0","0")==200&&hybrid_page==10&&software_context.group==0);
 assert(native("ha","","","","192.168.1.10:8123:0","1")==200&&hybrid_page==11&&software_context.group==1);
 before=software_context;old_draws=draws;uint64_t heartbeat=software_heartbeat;
 assert(native("ha","","","","192.168.1.10:8123:0","2")==404&&hybrid_page==11&&draws==old_draws&&software_heartbeat==heartbeat&&!memcmp(&before,&software_context,sizeof(before)));
 assert(native("ha","","","","192.168.1.11:8123:0","1")==404&&hybrid_page==11&&draws==old_draws);
 assert(native("ha","","","","","1")==404&&hybrid_page==11);
 const char *bad_groups[]={"-1","1.0","01junk","999999999"};for(unsigned i=0;i<4;i++)assert(native("ha","","","","",bad_groups[i])==400&&hybrid_page==11);
 standalone_config.printers[1].rotate=false;
 assert(native("printer","same-serial","formlabs","formlabs","fixture-cloud-client",NULL)==200&&hybrid_page==21);
 before=software_context;old_draws=draws;
 assert(native("printer","same-serial","formlabs","formlabs","other-cloud-account",NULL)==404&&hybrid_page==21&&draws==old_draws&&!memcmp(&before,&software_context,sizeof(before)));
 assert(native("printer","same-serial","formlabs","formlabs","",NULL)==404);
 assert(native("printer","same-serial","bambu","ha","192.168.1.10:8123:0",NULL)==200&&hybrid_page==20);
 assert(native("printer","same-serial","bambu","ha","192.168.1.10:8123:1",NULL)==404);
 assert(native("printer","same-serial","bambu","mqtt","192.168.1.20",NULL)==200&&hybrid_page==22);
 // Same serial, brand and source on different origins are distinguishable;
 // two identical complete identities remain ambiguous and never pick first.
 standalone_config.printers[2].source_ha=true;
 assert(native("printer","same-serial","bambu","ha","192.168.1.10:8123:0",NULL)==404);
 standalone_config.printers[2].source_ha=false;
 assert(native("overview","","","","",NULL)==200&&hybrid_page==31&&drawn_page==31);
 standalone_config.printers[0].enabled=false;standalone_config.printers[2].enabled=false;
 assert(native("overview","","","","",NULL)==404&&hybrid_page==31);
 standalone_config.printers[0].enabled=true;standalone_config.printers[2].enabled=true;
 standalone_config.clock=false;assert(native("clock","","","","",NULL)==404);standalone_config.clock=true;
 standalone_config.enabled=false;assert(native("clock","","","","",NULL)==404);standalone_config.enabled=true;
 httpd_req_t bad_native={.auth="Bearer 1234abcd1234abcd",.card="clock",.native="true"};native_card_handler(&bad_native);assert(bad_native.status==400&&hybrid_page==31);
 char giant_origin[180];memset(giant_origin,'x',179);giant_origin[179]=0;assert(native("printer","same-serial","formlabs","formlabs",giant_origin,NULL)==400);
 // Menus, physical pairing, browser preview and simulation keep ownership.
 device_menu.depth=1;old_draws=draws;assert(native("clock","","","","",NULL)==204&&hybrid_page==31&&draws==old_draws);device_menu.depth=0;
 software_simulation_until=test_now+1000000;assert(native("clock","","","","",NULL)==204&&hybrid_page==31);software_simulation_until=0;
 terminal_preview_page=2;terminal_preview_until=test_now+90000000;assert(native("clock","","","","",NULL)==204&&hybrid_page==31);terminal_preview_page=-1;
 standalone_pairing_open();assert(native("clock","","","","",NULL)==204&&hybrid_page==31);standalone_pairing_close();
 network_notice=true;assert(native("clock","","","","",NULL)==204&&hybrid_page==31);network_notice=false;
 terminal_asleep=true;before_clock=clock_draws;assert(native("clock","","","","",NULL)==200&&hybrid_page==0&&terminal_asleep&&clock_draws==before_clock);terminal_asleep=false;
 local_display(NULL);assert(hybrid_page==0&&native_clock);
 // Native selection renews the same 30-second lease, no autonomous online
 // carousel; when it expires offline configured cards resume normally.
 standalone_config.card_mask=1;test_now+=29000000;assert(software_controls());local_display(NULL);assert(hybrid_page==0);
 test_now+=1000000;assert(!software_controls());local_display(NULL);assert(hybrid_page==-1&&!software_visible&&local_visible);
 assert(standalone_config.revision==version);
 puts("C6 actual hybrid v2 handlers/display: explicit clock/diagnostics/weather/HA groups/printer/overview with software-first; exact endpoint/account isolation; manual-mask independence; disabled/invalid/duplicate rejection; native styles; menus/simulation/sleep; 30-second owner handoff; no NVS mutation passed");
}
`;
const binary=join(stage,'test');
const build=spawnSync('clang',['-std=c11','-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',cjson,'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',join(root,'Tools/WaveshareC6Firmware/src/local_state.c'),join(cjson,'cJSON.c'),'-o',binary],{input:program,encoding:'utf8'});
assert.equal(build.status,0,build.stderr);
const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
