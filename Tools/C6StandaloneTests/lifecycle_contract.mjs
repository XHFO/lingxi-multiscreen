// Execute the actual firmware handler and HA task with bounded platform mocks.
// This tests lifecycle control flow, not a replacement JS implementation or live hardware.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {strict as assert} from 'node:assert';
const root=new URL('../../',import.meta.url).pathname;
const cjson=process.env.LINGXI_CJSON_ROOT??join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const main=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/main.c'),'utf8');
const sources=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_sources.c'),'utf8');
const handler=main.slice(main.indexOf('static esp_err_t software_handler('),main.indexOf('static void finish_pairing_display('));
// The production HA block is now gated by the independent Formlabs profile.
const ha=sources.slice(sources.indexOf('static bool ha_network_ready('),sources.indexOf('static void mqtt_event('))+'\n#endif\n';
const prime=sources.slice(sources.indexOf('static bool initial_state('),sources.indexOf('static bool ws_send('));
assert.match(handler,/standalone_authorized/);assert.match(ha,/static void ha_task/);
const directory=mkdtempSync(join(tmpdir(),'lingxi-c6-lifecycle-'));
function run(name,program,extras=[]){
  const binary=join(directory,name);
  const build=spawnSync('clang',['-std=c11','-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',cjson,'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',...extras,join(cjson,'cJSON.c'),'-o',binary],{input:program,encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  const test=spawnSync(binary,[],{encoding:'utf8'});assert.equal(test.status,0,test.stderr);console.log(test.stdout.trim());
}
try {
run('software',`
#define main baseline_main
#include "${root}Tools/C6StandaloneTests/firmware_contract.c"
#undef main
static uint64_t software_heartbeat;
static bool software_visible,native_clock,local_visible;
static int hybrid_page=2;
static int64_t software_simulation_until,page_since;
static unsigned local_page,last_clock_second,draws,wakes;
static bool allow=true;
#include "menu_state.h"
static c6_menu_t device_menu;
static bool base_software_allowed(void){return allow;}
static uint64_t c6_seconds(void){return 100;}
static bool software_allowed(void){return allow;}
static void set_brightness(int level){assert(level==80);wakes++;}
static void local_display(void *arg){draws++;local_visible=true;}
${handler}
static httpd_req_t action(const char *body,const char *auth){httpd_req_t r={.method=HTTP_POST,.body=body,.auth=auth,.content_len=body?(int)strlen(body):0};software_handler(&r);return r;}
int main(void){
  baseline_main();standalone_config.enabled=true;standalone_config.brightness=80;
  software_visible=true;software_heartbeat=1;
  assert(action(NULL,NULL).status==200&&software_heartbeat==100&&draws==0);
  allow=false;software_heartbeat=1;action(NULL,NULL);assert(software_heartbeat==1);allow=true;
  const char *valid="{\\"action\\":\\"release\\"}";
  assert(action(valid,NULL).status==401&&software_heartbeat==1&&draws==0);
  assert(action(valid,"Bearer 0007").status==401&&draws==0);
  const char *bad[]={"{}","{\\"action\\":\\"other\\"}","{\\"action\\":\\"release\\"}junk","{\\"action\\":4}","[1]"};
  for(unsigned i=0;i<5;i++)assert(action(bad[i],"Bearer 1234abcd1234abcd").status==400&&draws==0);
  char oversized[65];memset(oversized,'x',64);oversized[64]=0;assert(action(oversized,"Bearer 1234abcd1234abcd").status==400);
  native_clock=true;software_simulation_until=900;page_since=900;local_page=3;
  httpd_req_t released=action(valid,"Bearer 1234abcd1234abcd");
  assert(released.status==200&&strstr(released.response,"released"));
  assert(hybrid_page==-1);
  assert(!software_visible&&!native_clock&&local_visible&&software_heartbeat==0&&software_simulation_until==0&&page_since==0&&local_page==0&&last_clock_second==UINT32_MAX&&draws==1&&wakes==1);
  action(NULL,NULL);assert(software_heartbeat==0); // Renewal alone cannot reclaim the screen.
  software_visible=true;action(NULL,NULL);assert(software_heartbeat==100); // A new valid frame can.
  puts("C6 software handoff: authenticated release, malformed/fragmented input, immediate local draw, brightness restore, no renewal resurrection; legacy heartbeat retained");
}
`,[join(root,'Tools/WaveshareC6Firmware/src/local_state.c')]);
run('prime',`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "local_state.h"
#include "cJSON.h"
#define MESSAGE_LIMIT 16384
#include "ha_subscription.h"
typedef void *esp_http_client_handle_t;
typedef struct {const char *url;int timeout_ms,buffer_size;void *crt_bundle_attach;bool disable_auto_redirect;} esp_http_client_config_t;
static void *esp_crt_bundle_attach;
static int mode,updates,calls;
static bool same=true;
static char response[256],last_state[128],last_id[128];
static bool current(unsigned g){return same;}
static void entity_update(cJSON *j,unsigned g){updates++;strcpy(last_id,cJSON_GetObjectItemCaseSensitive(j,"entity_id")->valuestring);strcpy(last_state,cJSON_GetObjectItemCaseSensitive(j,"state")->valuestring);}
static void *esp_http_client_init(const esp_http_client_config_t *c){calls++;assert(c->timeout_ms==4000&&c->disable_auto_redirect);snprintf(response,sizeof(response),"{\\"entity_id\\":\\"%s\\",\\"state\\":\\"on\\"}",mode==5?"sensor.other":strrchr(c->url,'/')+1);return mode==2?NULL:(void*)1;}
static void esp_http_client_set_header(void *h,const char *name,const char *value){assert(!strcmp(name,"Authorization")&&!strcmp(value,"Bearer fixture"));}
static int esp_http_client_open(void *h,int bytes){return mode==1?ESP_FAIL:ESP_OK;}
static int esp_http_client_fetch_headers(void *h){return (int)strlen(response);}
static int esp_http_client_read(void *h,char *out,int size){if(!*response)return 0;int n=(int)strlen(response);assert(size>=n);memcpy(out,response,n);response[0]=0;return n;}
static int esp_http_client_get_status_code(void *h){return mode==4?404:200;}
static bool esp_http_client_is_complete_data_received(void *h){return mode!=3;}
static void esp_http_client_close(void *h){}
static void esp_http_client_cleanup(void *h){}
${prime}
int main(void){
  c6_ha_config_t c={.ha_host="192.168.1.10",.ha_port=8123,.ha_token="fixture",.count=3,.ids={"sensor.one","sensor.two","sensor.three"}};char body[MESSAGE_LIMIT];unsigned index=0;uint64_t pending=7;
  mode=1;assert(!initial_state(&c,1,body,&index,&pending)&&pending==7&&index==1&&calls==1&&updates==0);
  mode=0;assert(!initial_state(&c,1,body,&index,&pending)&&pending==5&&index==2&&calls==2&&updates==1);
  assert(initial_state(&c,1,body,&index,&pending)&&pending==1&&index==0&&calls==3&&updates==2);
  assert(!initial_state(&c,1,body,&index,&pending)&&pending==0&&updates==3&&!strcmp(last_id,"sensor.one")); // Only failed entity retried.
  for(mode=2;mode<=5;mode++){index=0;pending=1;int old=updates;initial_state(&c,1,body,&index,&pending);if(mode==4)assert(!pending&&updates==old+1&&!strcmp(last_state,"unavailable"));else assert(pending==1&&updates==old);}
  same=false;index=0;pending=1;int old=calls;initial_state(&c,1,body,&index,&pending);assert(calls==old&&pending==1);
  puts("C6 initial HA states: one REST request per read cycle, retry only failed entities, low memory/incomplete/mismatched responses, missing entity and changed configuration");
}
`);
run('ha',`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include "local_sources.h"
#include "cJSON.h"
#include "ha_subscription.h"
#include "source_budget.h"
typedef void *esp_transport_handle_t;
typedef void esp_netif_t;
typedef struct {struct {unsigned addr;} ip;} esp_netif_ip_info_t;
static c6_source_snapshot_t state;
static standalone_config_t settings;
static int lock,scenario,ticks,allocations,connects,reads,copies,phase9,prime_calls;
static bool online;
static uint64_t seconds;
static jmp_buf stop;
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
#define MESSAGE_LIMIT 16384
static void xSemaphoreTake(int l,int t){}
static void xSemaphoreGive(int l){if(state.ha_phase==9)phase9++;}
static void vTaskDelay(int ms){ticks++;seconds+=ms/1000;if(ticks>12||state.ha_phase==7||state.ha_phase==8)longjmp(stop,1);if(scenario==0&&ticks==2)online=true;}
static void *test_malloc(size_t n){allocations++;return scenario==1&&allocations==1?NULL:malloc(n);}
#define malloc test_malloc
static esp_netif_t *esp_netif_get_handle_from_ifkey(const char *k){assert(!strcmp(k,"WIFI_STA_DEF"));return (void*)1;}
static bool esp_netif_is_netif_up(esp_netif_t *s){return online;}
static int esp_netif_get_ip_info(esp_netif_t *s,esp_netif_ip_info_t *ip){ip->ip.addr=online?1:0;return ESP_OK;}
static bool runtime_enabled(unsigned work){return scenario!=4;}
static unsigned ha_config_copy(c6_ha_config_t *c){
  if(++copies>12)longjmp(stop,1);memset(c,0,sizeof(*c));c->count=3;strcpy(c->ids[0],"sensor.one");strcpy(c->ids[1],"sensor.two");strcpy(c->ids[2],"sensor.three");c->ha_port=8123;strcpy(c->ha_host,"192.168.1.10");strcpy(c->ha_token,"fixture");return 1;
}
static bool current(unsigned g){return g==state.generation;}
static void *esp_transport_tcp_init(void){return (void*)1;}
static void *esp_transport_ssl_init(void){return (void*)1;}
static int esp_crt_bundle_attach;
static void esp_transport_ssl_crt_bundle_attach(void *p,int bundle){}
static void *esp_transport_ws_init(void *p){return (void*)2;}
static void esp_transport_ws_set_path(void *p,const char *s){assert(!strcmp(s,"/api/websocket"));}
static int esp_transport_connect(void *p,const char *host,int port,int timeout){
  connects++;assert(online&&state.ha_phase==2);
  if(scenario<=1)longjmp(stop,1);return 0;
}
static void esp_transport_close(void *p){}
static void esp_transport_destroy(void *p){}
uint64_t c6_seconds(void){return seconds;}
static bool ws_send(void *p,cJSON *j){return true;}
static int ws_receive(void *p,char *out,unsigned g){
  reads++;const char *s=NULL;
  if(reads==1)s="{\\"type\\":\\"auth_required\\"}";
  else if(reads==2)s=scenario==3?"{\\"type\\":\\"auth_invalid\\"}":"{\\"type\\":\\"auth_ok\\"}";
  else if(reads==3)s=scenario==5?"{\\"type\\":\\"result\\",\\"id\\":1,\\"success\\":false}":"{\\"type\\":\\"result\\",\\"id\\":1,\\"success\\":true}";
  else {assert(state.ha_connected&&state.ha_phase==5);seconds++;if(reads==6)longjmp(stop,1);return 0;}
  strcpy(out,s);return (int)strlen(s);
}
static bool initial_state(const c6_ha_config_t *c,unsigned g,char *body,unsigned *index,uint64_t *pending){assert(reads==3+prime_calls);seconds+=4;*pending&=~(UINT64_C(1)<<*index);prime_calls++;if(++(*index)==3){*index=0;return true;}return false;}
static void entity_update(cJSON *j,unsigned g){}
${ha}
int main(void){
  for(scenario=0;scenario<6;scenario++){
    state=(c6_source_snapshot_t){.generation=1};ticks=allocations=connects=reads=copies=phase9=prime_calls=0;seconds=1;online=scenario!=0;
    if(!setjmp(stop))ha_task(NULL);
    if(scenario==0)assert(ticks==2&&connects==1&&state.ha_reconnects==0);
    if(scenario==1)assert(allocations==4&&ticks==1&&phase9>0&&connects==1);
    if(scenario==2)assert(state.ha_connected&&connects==1&&state.ha_reconnects==0&&reads==6&&prime_calls==3); // REST prime interleaves with socket reads.
    if(scenario==3)assert(!state.ha_connected&&state.ha_phase==7&&state.ha_reconnects==1);
    if(scenario==4)assert(connects==0&&state.ha_phase==0&&allocations==0);
    if(scenario==5)assert(!state.ha_connected&&state.ha_phase==8&&state.ha_reconnects==1);
  }
  puts("C6 HA boot/reconnect: delayed DHCP, temporary allocation failure, slow initial state refresh, rejected authorization/subscription, empty selection (6 control-flow cases)");
}
`);
// App-side barriers and bounded termination are also required for the final request to be a release.
const app=readFileSync(join(root,'Sources/LinxDisplayApp/AppModel.swift'),'utf8');
const lifecycle=readFileSync(join(root,'Sources/LinxDisplayApp/LinxDisplayApp.swift'),'utf8');
assert.match(app,/c6HeartbeatTask\?\.cancel\(\)/);
assert.match(app,/!c6PreparingForQuit && settings\.devices\.contains/);
assert.match(app,/await c6HeartbeatTask\?\.value/);
assert.match(app,/client\.releaseSoftwareControl\(token: token\)/);
assert.match(lifecycle,/model\.prepareForTermination\(\)[\s\S]*model\.releaseC6SoftwareControlBeforeQuit\(\)/);
assert.match(lifecycle,/3_000_000_000/);
console.log('C6 Mac quit source guards: stop renewal/pushes, ordered release, concurrent per-device handoff, existing 3-second exit bound');
} finally {rmSync(directory,{recursive:true,force:true});}
