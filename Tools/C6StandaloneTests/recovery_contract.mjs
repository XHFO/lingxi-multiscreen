// Production MQTT lifecycle, bounded snapshots and health recovery with mocks.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const cjson=join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const sources=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_sources.c'),'utf8');
const updates=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_updates.c'),'utf8');
const between=(s,a,b)=>s.slice(s.indexOf(a),s.indexOf(b,s.indexOf(a)));
const mqtt=between(sources,'static void mqtt_task(', 'typedef struct {\n    esp_http_client_handle_t client;').replace(/#endif\s*$/,'');
const snapshot=between(sources,'bool c6_sources_try_snapshot(', 'static void printer_picture_key(');
const health=between(updates,'static esp_err_t health_handler(', 'void c6_register_updates(');
const stage=mkdtempSync(join(tmpdir(),'lingxi-c6-recovery-'));
function run(name,program,extras=[]){
 const binary=join(stage,name);const build=spawnSync('clang',['-std=c11','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',...extras,join(cjson,'cJSON.c'),'-o',binary],{input:program,encoding:'utf8'});assert.equal(build.status,0,build.stderr);
 const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
}
try{
run('mqtt',`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include "source_budget.h"
static standalone_config_t settings;
typedef struct {void *client;unsigned index,generation;char topic[96];char *body;} printer_client_t;
static printer_client_t printers[C6_MAX_PRINTERS];
typedef struct {
 struct {struct {char *hostname;int port,transport;} address;struct {char *certificate;bool skip_cert_common_name_check;} verification;} broker;
 struct {char *username;struct {char *password;} authentication;} credentials;
 struct {int keepalive;} session;struct {int reconnect_timeout_ms,timeout_ms;} network;struct {int size;} buffer;struct {int stack_size;} task;
} esp_mqtt_client_config_t;
#define MQTT_TRANSPORT_OVER_SSL 1
#define ESP_EVENT_ANY_ID 0
#define pdMS_TO_TICKS(x) (x)
static unsigned ticks,mode,allocations,releases,starts,destroys;
static void *allocated;
static jmp_buf stop;
static bool runtime_enabled(unsigned work){return mode!=0&&(mode!=1||(ticks>=3&&ticks<6));}
static bool ha_network_ready(void){return mode!=3||ticks>=3;}
static bool current(unsigned g){return g==1;}
static unsigned config_copy(standalone_config_t *out){*out=settings;return 1;}
static void vTaskDelay(int ms){ticks+=ms/1000;if(ticks>=15)longjmp(stop,1);}
static void *fixture_malloc(size_t n){allocations++;assert(n==sizeof(standalone_config_t));if(mode==2&&allocations==1)return NULL;allocated=malloc(n);return allocated;}
static void fixture_free(void *p){if(p==allocated&&p){releases++;allocated=NULL;}free(p);}
#define malloc fixture_malloc
#define free fixture_free
static void *esp_mqtt_client_init(const esp_mqtt_client_config_t *c){assert(c->broker.address.port==8883);return (void*)1;}
static void mqtt_event(void){}
static void esp_mqtt_client_register_event(void *c,int e,void (*fn)(void),void *p){}
static void esp_mqtt_client_start(void *c){starts++;}
static void esp_mqtt_client_destroy(void *c){destroys++;}
${mqtt}
int main(void){
 settings.enabled=true;settings.printer_count=1;settings.printers[0].enabled=true;
 strcpy(settings.printers[0].serial,"fixture");strcpy(settings.printers[0].host,"192.168.1.9");
 for(mode=0;mode<4;mode++){
  memset(printers,0,sizeof(printers));ticks=allocations=releases=starts=destroys=0;allocated=NULL;
  if(!setjmp(stop))mqtt_task(NULL);
  if(mode==0)assert(!allocations&&!starts);
  if(mode==1)assert(allocations==1&&releases==1&&starts==1&&destroys==1);
  if(mode==2)assert(allocations==2&&starts==1);
  if(mode==3)assert(allocations==1&&starts==1);
  free(allocated);
 }
 puts("C6 actual MQTT worker: no idle allocations, lazy enable, disable destroys clients and releases config, transient allocation retry and DHCP gating passed");
}
`);
run('health',`
#define main baseline_main
#include "${root}Tools/C6StandaloneTests/firmware_contract.c"
#undef main
#include "local_sources.h"
static int lock=1,takes,waited;
static bool busy;
static c6_source_snapshot_t state;
static standalone_config_t settings;
#define pdTRUE 1
#define pdMS_TO_TICKS(x) (x)
#define MALLOC_CAP_8BIT 1
static int xSemaphoreTake(int l,int ms){takes++;waited=ms;return !busy;}
static void xSemaphoreGive(int l){}
uint64_t c6_seconds(void){return 100;}
static unsigned esp_get_free_heap_size(void){return 80000;}
static unsigned esp_get_minimum_free_heap_size(void){return 30000;}
static unsigned heap_caps_get_largest_free_block(int caps){return 20000;}
static struct {const char *version;} descriptor={"2.0.0-alpha.16"};
static void *esp_app_get_description_dummy;
#define esp_app_get_description() (&descriptor)
static uint32_t boot_id=1;
${snapshot}
${health}
int main(void){
 baseline_main();standalone_pairing_close();standalone_config.latitude=44;standalone_config.longitude=55;
 state.weather=(c6_weather_state_t){.valid=true,.latitude=44,.longitude=55};
 // Source mutex is taken with 20ms, and stale output is not overwritten.
 c6_source_snapshot_t out={.generation=77};busy=true;assert(!c6_sources_try_snapshot(&out)&&out.generation==77&&waited==20);
 assert(!c6_sources_weather_available());busy=false;assert(c6_sources_try_snapshot(&out));
 // Availability uses the source's actual coordinates, not stale city data.
 settings.latitude=44;settings.longitude=55;assert(c6_sources_weather_available());settings.longitude=56;assert(!c6_sources_weather_available());
 httpd_req_t denied={0};health_handler(&denied);assert(denied.status==401);
 busy=true;httpd_req_t r={.auth="Bearer 1234abcd1234abcd"};health_handler(&r);assert(r.status==200&&waited==20);
 cJSON *j=cJSON_Parse(r.response);assert(cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(j,"snapshot_available")));assert(cJSON_GetObjectItemCaseSensitive(j,"largest_free_block")->valueint==20000);cJSON_Delete(j);
 busy=false;state.weather_phase=2;r=(httpd_req_t){.auth="Bearer 1234abcd1234abcd"};health_handler(&r);j=cJSON_Parse(r.response);
 assert(cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(j,"snapshot_available")));assert(!strcmp(cJSON_GetObjectItemCaseSensitive(j,"weather_phase")->valuestring,"waiting_memory"));cJSON_Delete(j);
 puts("C6 actual snapshot/health: 20ms contention bound, preserved snapshot, weather coordinate validity, authenticated recovery diagnostics, largest block and weather phase passed");
}
`,[join(root,'Tools/WaveshareC6Firmware/src/local_state.c')]);
}finally{rmSync(stage,{recursive:true,force:true});}
