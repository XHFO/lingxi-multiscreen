import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url).pathname,source=readFileSync(root+'Tools/WaveshareC6Firmware/src/main.c','utf8');
const start=source.indexOf('static void local_display(void *arg) {'),end=source.indexOf('    if(menu_draft.dirty',start);
assert(start>0&&end>start);const region=source.slice(source.indexOf('static bool setup_display_notice(void){'),start)+source.slice(start,end)+'}\n';
const c=`
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "captive_dns_packet.h"
#define ESP_OK 0
#define WIFI_MODE_NULL 0
#define WIFI_MODE_STA 1
#define WIFI_MODE_APSTA 3
#define WIFI_IF_AP 1
typedef int wifi_mode_t;
typedef struct {struct {char ssid[33];} ap;} wifi_config_t;
typedef int c6_render_style_t;
typedef struct {const char *label,*value;} c6_render_menu_row_t;
static int mode=WIFI_MODE_APSTA,draws,menus,brightness=80;
static int64_t now=1000000,hotspot_close_at;
static bool station_joined_pending,network_notice,network_notice_drawn,native_clock,station_offline,station_has_credentials;
static bool terminal_guide_qr,terminal_guide_offered,terminal_guide_empty,setup_notice_drawn,setup_qr_web;
static uint32_t revision,last_clock_second;
static struct {unsigned printer_count,entity_count;bool weather,ha_enabled;} standalone_config;
static struct {unsigned depth;} device_menu;
static char ip[16]="0.0.0.0",payload[128],title[80];
static int64_t esp_timer_get_time(void){return now;}
static int esp_wifi_get_mode(int *m){*m=mode;return ESP_OK;}
static int esp_wifi_set_mode(int m){mode=m;return ESP_OK;}
static int esp_wifi_get_config(int unused,wifi_config_t *ap){strcpy(ap->ap.ssid,"XH-Multiscreen-ABC123");return ESP_OK;}
static c6_render_style_t local_style(void){return 0;}
static void *renderer(void){return NULL;}
static const char *local_label(const char *s){return s;}
static void c6_renderer_setup_qr(void *r,const char *p,const char *t,const char *a,const char *f,const void *style){strcpy(payload,p);strcpy(title,t);}
static void c6_renderer_menu(void *r,const char *t,const c6_render_menu_row_t *rows,int a,int b,const char *footer,const void *style){menus++;}
static void calibrated_display(void){draws++;}
static void set_brightness(int b){}
${region}
int main(void){
 // Initial offline flag is zero: no stored credentials still shows a Wi-Fi QR.
 local_display(NULL);assert(draws==1&&!strcmp(payload,"WIFI:T:nopass;S:XH-Multiscreen-ABC123;;"));
 setup_qr_web=true;setup_notice_drawn=false;local_display(NULL);assert(!strcmp(payload,"http://192.168.4.1/"));
 // Submitting Wi-Fi is not success; the hotspot QR remains available on failure.
 station_has_credentials=true;station_offline=true;setup_qr_web=false;setup_notice_drawn=false;local_display(NULL);assert(!strncmp(payload,"WIFI:",5));
 strcpy(ip,"192.168.8.42");station_offline=false;station_joined_pending=true;local_display(NULL);
 assert(network_notice&&terminal_guide_qr&&!strcmp(payload,"http://192.168.8.42/standalone#printers")&&hotspot_close_at==now+12000000);
 now+=12000000;local_display(NULL);assert(mode==WIFI_MODE_STA&&network_notice&&!hotspot_close_at);
 // DHCP changes refresh an already-visible QR. Disconnect hides the old QR.
 strcpy(ip,"10.0.2.50");station_joined_pending=true;local_display(NULL);assert(!strcmp(payload,"http://10.0.2.50/standalone#printers"));
 station_offline=true;strcpy(ip,"0.0.0.0");int before=menus;local_display(NULL);assert(menus==before+1&&!network_notice_drawn);
 station_offline=false;strcpy(ip,"10.0.2.51");station_joined_pending=true;local_display(NULL);assert(!strcmp(payload,"http://10.0.2.51/standalone#printers"));
 terminal_guide_qr=false;network_notice_drawn=false;before=menus;local_display(NULL);assert(menus==before+1);
 standalone_config.printer_count=1;local_display(NULL);assert(!network_notice);
 // Weather-only users need not add a printer to finish the screen guide.
 standalone_config.printer_count=0;network_notice=true;terminal_guide_empty=true;standalone_config.weather=true;local_display(NULL);assert(!network_notice);
 // Already configured weather skips the guide on a normal restart, but an
 // explicit AP reprovision always shows the NEW LAN QR before dismissal.
 terminal_guide_offered=false;station_joined_pending=true;local_display(NULL);assert(!network_notice);
 mode=WIFI_MODE_APSTA;station_joined_pending=true;local_display(NULL);assert(network_notice&&network_notice_drawn&&!terminal_guide_empty);
 // DNS response preserves transaction, offers TTL=0 only and rejects malformed packets.
 const uint8_t query[]={0x12,0x34,1,0,0,1,0,0,0,0,0,0,3,'w','w','w',7,'e','x','a','m','p','l','e',3,'c','o','m',0,0,1,0,1};
 uint8_t b[512],address[]={192,168,4,1};memcpy(b,query,sizeof(query));
 size_t n=c6_captive_answer(b,sizeof(query),sizeof(b),address);assert(n==sizeof(query)+16&&b[0]==0x12&&b[1]==0x34&&b[7]==1&&!memcmp(b+n-4,address,4));
 for(unsigned i=n-10;i<n-6;i++)assert(b[i]==0);
 memcpy(b,query,sizeof(query));b[sizeof(query)-3]=28;assert(c6_captive_answer(b,sizeof(query),sizeof(b),address)==sizeof(query)&&b[7]==0);
 memcpy(b,query,sizeof(query));b[5]=2;assert(!c6_captive_answer(b,sizeof(query),sizeof(b),address));
 memcpy(b,query,sizeof(query));b[12]=0xc0;assert(!c6_captive_answer(b,sizeof(query),sizeof(b),address));
 memcpy(b,query,sizeof(query));assert(!c6_captive_answer(b,sizeof(query),sizeof(query)+15,address));
 for(size_t len=0;len<sizeof(query);len++){memcpy(b,query,sizeof(query));assert(!c6_captive_answer(b,len,sizeof(b),address));}
 puts("Actual first-boot guide: Wi-Fi/web QR, failure retry, actual LAN QR, 12s handoff, AP close and saved-printer dismissal; bounded DNS A/AAAA/TTL/malformed checks passed");
}
`;
const stage=mkdtempSync('/private/tmp/form-monitor-guide.');writeFileSync(stage+'/test.c',c);
let result=spawnSync('clang',['-std=c11','-D','C6_FORMLABS_ONLY=1','-I',root+'Tools/FormlabsC6Firmware/src',stage+'/test.c','-o',stage+'/test'],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
result=spawnSync(stage+'/test',[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);process.stdout.write(result.stdout);
const glyphs=readFileSync(root+'Sources/C6DisplayRenderer/aa_font.inc','utf8').split('static const aa_large_glyphs')[0],codes=new Set([...glyphs.matchAll(/^\{(\d+),/gm)].map(m=>Number(m[1])));
for(const [,text] of region.matchAll(/(?:local_label\(|,"|\?")([^"\n]+)"/g))for(const letter of text)assert(codes.has(letter.codePointAt(0)),text+' has missing glyph '+letter);
