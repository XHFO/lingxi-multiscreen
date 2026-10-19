// Execute the production HTTP frame/clock/reset handlers with platform mocks.
import {readFileSync,mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/main.c'),'utf8');
const between=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const frame=between('static esp_err_t frame_handler(', 'static esp_err_t brightness_handler(');
const preview=between('static esp_err_t preview_frame_handler(', 'static void terminal_wake(');
const clock=between('static esp_err_t clock_handler(', 'static void init_lcd(');
const reset=between('static bool reset_station_wifi(void){','static void wifi_event(');
const stage=mkdtempSync(join(tmpdir(),'lingxi-c6-button-api-'));
const cjson=join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const program=`
#define main baseline_main
#define httpd_req_recv baseline_recv
#include "${root}Tools/C6StandaloneTests/firmware_contract.c"
#undef httpd_req_recv
#undef main
#include "menu_state.h"
#include "wifi_provision.h"
#include "clock_animation.h"
static c6_menu_t device_menu;
static bool native_clock,software_visible,local_visible,display_rotated,station_has_credentials=true,station_offline;
static int64_t software_simulation_until,clock_anchor;static uint64_t software_heartbeat;
static uint32_t clock_epoch,last_clock_second,frame_generation,revision;
static int64_t page_since;static bool frame_valid,terminal_asleep;static c6_clock_animation_t clock_animation;
static int clock_timezone,native_clock_style;static char ip[16]="192.168.1.8";
static int terminal_rotation;static bool terminal_guide_offered,setup_notice_drawn,setup_qr_web,network_notice,network_notice_drawn;static int64_t hotspot_close_at;
static int hybrid_page=2;
#define FRAME_BYTES (240*240*2)
static uint8_t storage[FRAME_BYTES];static uint8_t *frame=storage;
static bool allow=true;static unsigned drawn,finished,context_count,recovery_draws;static int fail_receive_at=-1;
static size_t sent_bytes;
int httpd_req_recv(httpd_req_t *r,char *out,size_t n){if(fail_receive_at>=0&&r->offset>=fail_receive_at)return ESP_FAIL;return baseline_recv(r,out,n);}
static bool software_allowed(void){return !device_menu.depth&&allow;}
static uint64_t c6_seconds(void){return 100;}
static bool c6_simulation_active(int64_t deadline,int64_t now){return false;}
static void finish_pairing_display(bool waiting){finished++;}
static void menu_frame_context(httpd_req_t *r){context_count++;}
static void display_frame(void){drawn++;frame_valid=true;}
static void local_display(void *r){recovery_draws++;}
static void draw_clock(void *r){drawn++;}
static esp_err_t httpd_resp_send(httpd_req_t *r,const char *s,int n){sent_bytes=n;if(!r->status)r->status=200;return ESP_OK;}
static const char *clock_query="enabled=1&epoch=1791453000&tz=0";
static esp_err_t httpd_req_get_url_query_str(httpd_req_t *r,char *s,size_t n){snprintf(s,n,"%s",clock_query);return ESP_OK;}
static esp_err_t httpd_query_key_value(const char *q,const char *k,char *out,size_t n){
  size_t key=strlen(k);for(const char *p=q;*p;){const char *end=strchr(p,'&');if(!end)end=p+strlen(p);
    if((size_t)(end-p)>key&&p[key]=='='&&!strncmp(p,k,key)){size_t len=end-p-key-1;if(len>=n)return ESP_FAIL;memcpy(out,p+key+1,len);out[len]=0;return ESP_OK;}p=*end?end+1:end;}
  return ESP_FAIL;
}
${between('static bool query_number(', 'static esp_err_t clock_handler(')}
typedef struct {unsigned address,size;} esp_partition_t;
#define ESP_PARTITION_TYPE_DATA 1
typedef int esp_partition_subtype_t;
static esp_partition_t partition={C6_WIFI_PROVISION_OFFSET,C6_WIFI_PROVISION_SECTOR_BYTES};
static unsigned erased,configs,disconnected;static int wifi_error;
static const esp_partition_t *esp_partition_find_first(int t,int s,const char *label){assert(!strcmp(label,"lx_wifi"));return &partition;}
static int esp_partition_erase_range(const esp_partition_t *p,int start,int size){assert(start==0&&size==4096&&p->address==0x3f0000);erased++;return ESP_OK;}
typedef struct {struct {uint8_t ssid[32],password[64];} sta;} wifi_config_t;
#define WIFI_IF_STA 0
#define WIFI_MODE_APSTA 3
static int esp_wifi_set_mode(int mode){assert(mode==WIFI_MODE_APSTA);return ESP_OK;}
static int esp_wifi_set_config(int type,wifi_config_t *c){assert(type==WIFI_IF_STA);for(unsigned i=0;i<sizeof(*c);i++)assert(!((uint8_t*)c)[i]);configs++;return wifi_error;}
static int esp_wifi_disconnect(void){disconnected++;return ESP_OK;}
static int esp_wifi_connect(void){return ESP_OK;}
${reset}
${clock}
${frame}
${preview}
int main(void){
  baseline_main();c6_menu_open(&device_menu,C6_MENU_SETTINGS,true,0);
  httpd_req_t upload={.content_len=FRAME_BYTES,.body=(const char*)storage};frame_handler(&upload);
  assert(upload.status==204&&!upload.offset&&!drawn&&!finished&&!context_count&&hybrid_page==2);
  native_clock=true;httpd_req_t command={0};clock_handler(&command);assert(command.status==204&&native_clock&&!drawn&&!finished);
  device_menu.depth=0;allow=false;upload=(httpd_req_t){.content_len=FRAME_BYTES};frame_handler(&upload);assert(upload.status==204&&!drawn);
  allow=true;upload=(httpd_req_t){.content_len=FRAME_BYTES,.body=(const char*)storage};frame_handler(&upload);
  assert(upload.status==200&&upload.offset==FRAME_BYTES&&drawn==1&&context_count==1&&revision==1&&software_visible&&!local_visible&&!native_clock&&software_heartbeat==100);
  assert(hybrid_page==-1);
  // The only RAM frame is overwritten in place: a fragmented transfer that
  // fails must not expose those partial bytes as the actual LCD preview.
  static uint8_t replacement[FRAME_BYTES];memset(replacement,0x5a,sizeof(replacement));
  fail_receive_at=34;upload=(httpd_req_t){.content_len=FRAME_BYTES,.body=(const char*)replacement};
  assert(frame_handler(&upload)==ESP_FAIL&&upload.offset==34&&!frame_valid&&drawn==1&&recovery_draws==1);
  assert(storage[0]==0x5a&&storage[33]==0x5a&&storage[34]!=0x5a&&!software_heartbeat&&!software_visible&&revision==0);
  sent_bytes=0;httpd_req_t view={.auth="Bearer 1234abcd1234abcd"};preview_frame_handler(&view);assert(view.status==503&&!sent_bytes);
  terminal_asleep=true;upload=(httpd_req_t){.content_len=FRAME_BYTES,.body=(const char*)replacement};frame_handler(&upload);assert(!frame_valid&&recovery_draws==1&&terminal_asleep);
  terminal_asleep=false;fail_receive_at=-1;upload=(httpd_req_t){.content_len=FRAME_BYTES,.body=(const char*)replacement};frame_handler(&upload);
  assert(upload.status==200&&frame_valid&&drawn==2&&revision==1&&!memcmp(storage,replacement,sizeof(storage)));
  view=(httpd_req_t){.auth="Bearer 1234abcd1234abcd"};preview_frame_handler(&view);assert(view.status==200&&sent_bytes==FRAME_BYTES);
  hybrid_page=2;command=(httpd_req_t){0};clock_handler(&command);
  assert(command.status==200&&hybrid_page==-1&&native_clock&&software_visible&&!local_visible);
  assert(native_clock_style==0);
  clock_query="enabled=1&epoch=1791453000&tz=0&clock_style=1";command=(httpd_req_t){0};clock_handler(&command);assert(command.status==200&&native_clock_style==1);
  const char *invalid_styles[]={"-1","2","1junk","0.5",""};
  char query[128];for(unsigned i=0;i<5;i++){snprintf(query,sizeof(query),"enabled=1&epoch=1791453000&tz=0&clock_style=%s",invalid_styles[i]);clock_query=query;unsigned before_drawn=drawn;command=(httpd_req_t){0};clock_handler(&command);assert(command.status==400&&native_clock_style==1&&drawn==before_drawn);}
  // An explicitly selected native clock keeps the firmware's appearance,
  // timezone and hardware rotation despite a stale compatibility clock call.
  hybrid_page=0;software_visible=true;native_clock=true;standalone_config.clock_style=1;standalone_config.timezone=28800;
  terminal_rotation=270;standalone_config.digit_style=1;
  clock_query="enabled=1&epoch=1791453000&tz=-3600&rotation=0&clock_style=0";command=(httpd_req_t){0};clock_handler(&command);
  assert(command.status==200&&hybrid_page==0&&native_clock_style==1&&clock_timezone==28800&&terminal_rotation==270&&standalone_config.digit_style==1);
  unsigned native_drawn=drawn;clock_query="enabled=0";command=(httpd_req_t){0};clock_handler(&command);assert(command.status==200&&native_clock&&hybrid_page==0&&drawn==native_drawn);
  terminal_asleep=true;clock_query="enabled=1&epoch=1791453010&tz=0&clock_style=0";command=(httpd_req_t){0};clock_handler(&command);assert(command.status==200&&terminal_asleep&&drawn==native_drawn&&native_clock_style==1);terminal_asleep=false;
  char old_token[17];strcpy(old_token,standalone_token);int old_revision=standalone_config.revision;
  partition.address=0x400000;assert(!reset_station_wifi()&&!erased&&!configs&&station_has_credentials);
  partition.address=0x3f0000;wifi_error=ESP_FAIL;assert(!reset_station_wifi()&&station_has_credentials&&disconnected==1);
  wifi_error=ESP_OK;assert(reset_station_wifi()&&!station_has_credentials&&station_offline&&disconnected==2&&!strcmp(ip,"0.0.0.0"));
  assert(!strcmp(old_token,standalone_token)&&old_revision==standalone_config.revision);
  puts("C6 actual handlers: menus reject frames, failed partial uploads invalidate preview and recover without waking sleep, full replacement restores actual frame; Wi-Fi reset retains pairing/config");
}
`;
const binary=join(stage,'test');
const build=spawnSync('clang',['-std=c11','-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',cjson,'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-I',join(root,'Sources/C6DisplayRenderer/include'),'-x','c','-',join(root,'Tools/WaveshareC6Firmware/src/local_state.c'),join(cjson,'cJSON.c'),'-o',binary],{input:program,encoding:'utf8'});
assert.equal(build.status,0,build.stderr);
const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
