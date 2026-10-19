import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/main.c'),'utf8');
const between=(a,b)=>{const start=source.indexOf(a);assert(start>=0);const end=source.indexOf(b,start);assert(end>start);return source.slice(start,end);};
const region=between('static uint8_t clock_scanlines[','#include "local_render.h"');
const policy=between('static void terminal_wake(bool manual){','static void local_display_work');
const pagesPolicy=between('static unsigned local_pages(', 'static bool base_software_allowed(');
const frameHandler=between('static esp_err_t preview_frame_handler(httpd_req_t *req) {','static void terminal_wake');
const stage=mkdtempSync('/private/tmp/formlabs-display-runtime.');
const c=`
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "local_sources.h"
#include "form_demo.h"
#include "terminal_display_policy.h"
standalone_config_t standalone_config;
static int terminal_rotation,brightness=80;static bool terminal_asleep,terminal_manual_override;
static uint64_t terminal_last_activity,seconds=1;static int terminal_preview_page=-1;static int64_t terminal_preview_until;
static struct {unsigned depth;} device_menu;static uint32_t frame_generation,last_clock_second;static bool frame_valid=true;
static int64_t page_since,hotspot_close_at;static unsigned local_page;static bool network_notice,network_notice_drawn,station_joined_pending,setup_notice_drawn;
static c6_source_snapshot_t snapshot;static unsigned display_calls,brightness_calls;static int effective_brightness;
static const c6_source_snapshot_t *display_sources(void){return &snapshot;}
uint64_t c6_seconds(void){return seconds;}static int64_t esp_timer_get_time(void){return seconds*1000000;}
static void set_brightness(int value){brightness=value;effective_brightness=terminal_asleep?0:value;brightness_calls++;}
static void local_display(void *p){display_calls++;}
bool c6_print_active(const char *s){return !strcmp(s,"printing");}
static time_t epoch=1800000000;static time_t fake_time(void *p){return epoch;}
#define time(p) fake_time(p)
static const char *query;
int httpd_req_get_url_query_str(httpd_req_t *r,char *out,size_t n){if(!query||strlen(query)>=n)return ESP_FAIL;strcpy(out,query);return ESP_OK;}
int httpd_query_key_value(const char *s,const char *key,char *out,size_t n){size_t len=strlen(key);for(;*s;){if(!strncmp(s,key,len)&&s[len]=='='){s+=len+1;size_t m=strcspn(s,"&");if(m>=n)return ESP_FAIL;memcpy(out,s,m);out[m]=0;return ESP_OK;}s=strchr(s,'&');if(!s)break;s++;}return ESP_FAIL;}
bool standalone_authorized(httpd_req_t *r){if(r->auth)return true;r->status=401;return false;}
int httpd_resp_set_status(httpd_req_t *r,const char *s){r->status=atoi(s);return ESP_OK;}
int httpd_resp_sendstr(httpd_req_t *r,const char *s){if(!r->status)r->status=200;return ESP_OK;}
int httpd_resp_send_err(httpd_req_t *r,int code,const char *s){r->status=code;return ESP_OK;}
int httpd_resp_set_type(httpd_req_t *r,const char *s){return ESP_OK;}
static uint8_t frame_store[115200],physical[115200],*frame=frame_store;
#define FRAME_BYTES 115200
static const char *response_revision,*response_rotation,*response_sleep;
static unsigned received_revision,received_rotation,received_sleep,received_bytes;
int httpd_resp_set_hdr(httpd_req_t *r,const char *key,const char *value){
  if(!strcmp(key,"X-Lingxi-Frame-Revision"))response_revision=value;
  if(!strcmp(key,"X-Lingxi-Rotation"))response_rotation=value;
  if(!strcmp(key,"X-Lingxi-Asleep"))response_sleep=value;
  return ESP_OK;
}
int httpd_resp_send(httpd_req_t *r,const char *body,size_t n){
  received_revision=atoi(response_revision);received_rotation=atoi(response_rotation);received_sleep=atoi(response_sleep);received_bytes=n;
  if(!r->status)r->status=200;return ESP_OK;
}
static unsigned left,top,right,bottom,cursor;
static void command(uint8_t cmd,const uint8_t *data,size_t n){if(cmd==0x2a){left=data[1];right=data[3];}else if(cmd==0x2b){top=data[1];bottom=data[3];}else if(cmd==0x2c)cursor=0;}
typedef struct {unsigned length;const void *tx_buffer;} spi_transaction_t;static int lcd;
static int spi_device_polling_transmit(int d,const spi_transaction_t *t){const uint8_t *b=t->tx_buffer;unsigned count=t->length/16,width=right-left+1;for(unsigned i=0;i<count;i++){unsigned x=left+cursor%width,y=top+cursor/width;assert(y<=bottom);physical[(y*240+x)*2]=b[i*2];physical[(y*240+x)*2+1]=b[i*2+1];cursor++;}return ESP_OK;}
${region}
${pagesPolicy}
${policy}
${frameHandler}
int main(void){
  unsigned playlist[12];
  for(unsigned n=0;n<=3;n++){
    standalone_config.printer_count=n;
    unsigned count=local_pages(playlist,&snapshot);assert(count==(n>=2?1:0));if(count)assert(playlist[0]==TERMINAL_OVERVIEW_PAGE);
    for(unsigned i=0;i<n;i++){standalone_config.printers[i].enabled=standalone_config.printers[i].rotate=standalone_config.printers[i].source_formlabs=true;snprintf(standalone_config.printers[i].serial,40,";;tex_%u",i+1);}
    count=local_pages(playlist,&snapshot);assert(count==n+(n>=2?1:0));for(unsigned i=0;i<n;i++)assert(playlist[i]==20+i);
    memset(standalone_config.printers,0,sizeof(standalone_config.printers));
  }
  standalone_config.printer_count=2;standalone_config.printers[0].enabled=true;standalone_config.printers[0].rotate=true;
  assert(local_pages(playlist,&snapshot)==2&&playlist[0]==20&&playlist[1]==TERMINAL_OVERVIEW_PAGE);
  memset(&standalone_config,0,sizeof(standalone_config));
  for(unsigned i=0;i<57600;i++){frame[i*2]=i>>8;frame[i*2+1]=i&255;}
  for(terminal_rotation=0;terminal_rotation<360;terminal_rotation+=90){
    terminal_display_region(0,0,239,239);
    for(unsigned y=0;y<240;y++)for(unsigned x=0;x<240;x++){unsigned pos=y*240+x,from=terminal_rotation==90?(239-x)*240+y:terminal_rotation==180?(239-y)*240+239-x:terminal_rotation==270?x*240+239-y:pos;assert(physical[pos*2]==frame[from*2+1]&&physical[pos*2+1]==frame[from*2]);}
    memset(physical,0xa5,sizeof(physical));display_clock_tiles();
    for(unsigned y=0;y<240;y++)for(unsigned x=0;x<240;x++){unsigned pos=y*240+x,from=terminal_source_pixel(terminal_rotation,x,y);bool tile=from/240>=72&&from/240<=158;
      if(tile)assert(physical[pos*2]==frame[from*2+1]&&physical[pos*2+1]==frame[from*2]);else assert(physical[pos*2]==0xa5&&physical[pos*2+1]==0xa5);}
  }
  for(unsigned i=0;i<57600;i++)assert(frame[i*2]==(uint8_t)(i>>8)&&frame[i*2+1]==(uint8_t)i);
  for(int minute=0;minute<1440;minute++)assert(terminal_schedule_active(1380,420,minute)==(minute>=1380||minute<420));
  assert(!terminal_schedule_active(0,0,1)&&!terminal_schedule_active(1380,420,-1));
  standalone_config.sleep_mode=1;standalone_config.sleep_idle_minutes=1;seconds=59;assert(!terminal_sleep_tick());seconds=60;assert(terminal_sleep_tick()&&effective_brightness==0);
  terminal_wake(true);assert(!terminal_asleep&&effective_brightness==80);seconds=119;assert(!terminal_sleep_tick());seconds=120;assert(terminal_sleep_tick());
  standalone_config.sleep_keep_printing=true;standalone_config.printer_count=1;standalone_config.printers[0].enabled=true;snapshot.printers[0].connected=true;strcpy(snapshot.printers[0].status,"printing");assert(!terminal_sleep_tick());snapshot.printers[0].connected=false;assert(terminal_sleep_tick());
  device_menu.depth=1;assert(!terminal_sleep_tick());device_menu.depth=0;
  station_joined_pending=true;assert(!terminal_sleep_tick());station_joined_pending=false;
  hotspot_close_at=1;assert(!terminal_sleep_tick());hotspot_close_at=0;assert(terminal_sleep_tick());
  network_notice=true;assert(!terminal_sleep_tick());network_notice=false;
  setup_notice_drawn=true;assert(!terminal_sleep_tick());setup_notice_drawn=false;assert(terminal_sleep_tick());
  assert(terminal_should_sleep(2,1,1380,420,false,false,false,60,0,false,0));assert(!terminal_should_sleep(2,1,1380,420,false,false,false,60,60,true,0));assert(terminal_should_sleep(2,1,1380,420,false,false,false,120,60,true,0));
  standalone_config.clock=true;standalone_config.weather=true;
  httpd_req_t req={0};query="card=clock";terminal_view_handler(&req);assert(req.status==401&&display_calls==0);
  req=(httpd_req_t){.auth="fixture"};device_menu.depth=1;terminal_view_handler(&req);assert(req.status==409&&display_calls==0);device_menu.depth=0;
  req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==0&&terminal_preview_until==(int64_t)seconds*1000000+90000000&&!terminal_asleep);
  query="card=printer&index=0";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==20);
  query="card=printer&index=2";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==409&&terminal_preview_page==20);
  query="card=overview";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==409&&terminal_preview_page==20);
  for(unsigned n=2;n<=3;n++){standalone_config.printer_count=n;req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==TERMINAL_OVERVIEW_PAGE);}
  standalone_config.printer_count=1;
  query="card=weather";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==2);
  query="card=auto";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==-1);
  query="card=demo";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==409&&terminal_preview_page==-1);
  query="card=demo_off";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==409&&terminal_preview_page==-1);
  standalone_config.printers[0].source_formlabs=true;strcpy(standalone_config.printers[0].serial,";;tex_2");snapshot.printers[0].connected=true;strcpy(snapshot.printers[0].status,"printing");
  standalone_config.sleep_mode=1;standalone_config.sleep_idle_minutes=1;standalone_config.sleep_keep_printing=true;seconds+=61;
  assert(terminal_sleep_tick());query="card=printer&index=0";req=(httpd_req_t){.auth="fixture"};terminal_view_handler(&req);assert(req.status==200&&terminal_preview_page==20);
  frame_generation=123;terminal_rotation=270;terminal_asleep=true;query=NULL;req=(httpd_req_t){.auth="fixture"};preview_frame_handler(&req);
  assert(req.status==200&&received_revision==123&&received_rotation==270&&received_sleep==1&&received_bytes==FRAME_BYTES);
  query="rev=123";req=(httpd_req_t){.auth="fixture"};preview_frame_handler(&req);
  assert(req.status==204&&received_revision==123&&received_rotation==270&&received_sleep==1&&received_bytes==0);
  query="rev=122";req=(httpd_req_t){.auth="fixture"};preview_frame_handler(&req);
  assert(req.status==200&&received_revision==123&&received_rotation==270&&received_bytes==FRAME_BYTES);
  assert(terminal_asleep&&frame_generation==123);req=(httpd_req_t){0};preview_frame_handler(&req);assert(req.status==401);
  puts("Actual dedicated LCD: 4 rotations/byte order, partial refresh/canonical retention; idle/schedule/print/menu wake and authenticated preview actions passed");
}
`;
const file=join(stage,'test.c');writeFileSync(file,'#include <stdlib.h>\n'+c);
const cjson=join(process.env.PLATFORMIO_CORE_DIR||join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
let r=spawnSync('clang',['-std=c11','-D_POSIX_C_SOURCE=200809L','-D','C6_FORMLABS_ONLY=1','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),file,'-o',join(stage,'test')],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
r=spawnSync(join(stage,'test'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);process.stdout.write(r.stdout);
