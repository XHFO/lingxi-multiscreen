// Executes the production weather scheduler and portable allocation policy.
// All HTTP/DHCP/NVS operations are fixtures, not real network or stored accounts.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const cjson=join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_sources.c'),'utf8');
const weather=source.slice(source.indexOf('static bool weather_refresh_requested;'),source.indexOf('void c6_sources_init('));
const stage=mkdtempSync(join(tmpdir(),'lingxi-c6-resources-'));
const program=`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <setjmp.h>
#include "local_sources.h"
#include "ha_subscription.h"
#include "source_budget.h"
#include "cJSON.h"
static standalone_config_t settings;
static c6_source_snapshot_t state;
static int lock=1,media_http_lock=2,held,mode,attempts,allocations,offset,saves;
static uint64_t now,first_attempt,until;
static jmp_buf stop;
#define pdTRUE 1
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
static int xSemaphoreTake(int l,int t){if(l==2){assert(!held);if(mode==2&&now<3)return 0;held=1;}return 1;}
static void xSemaphoreGive(int l){if(l==2){assert(held);held=0;}}
uint64_t c6_seconds(void){return now;}
static void vTaskDelay(int ms){assert(!held);now+=ms/1000;if(now>=until)longjmp(stop,1);}
static bool ha_network_ready(void){return mode!=0||now>=3;}
static bool http_budget(bool tls){assert(tls);return mode!=1||now>=10;}
static void *fixture_malloc(size_t n){assert(held&&n==2048);allocations++;return mode==3&&allocations==1?NULL:malloc(n);}
#define malloc fixture_malloc
typedef int nvs_handle_t;
#define NVS_READWRITE 0
static int nvs_open(const char *n,int mode,nvs_handle_t *h){*h=1;return ESP_OK;}
static int nvs_get_blob(int h,const char *key,void *out,size_t *size){
 c6_weather_state_t cached={.valid=true,.latitude=44,.longitude=55,.temperature=17,.epoch=1791450000};assert(*size==sizeof(cached));memcpy(out,&cached,sizeof(cached));return ESP_OK;
}
static int nvs_set_blob(int h,const char *key,const void *v,size_t size){assert(!held);saves++;return ESP_OK;}
static void nvs_commit(int h){}
static void nvs_close(int h){}
typedef void *esp_http_client_handle_t;
typedef struct {const char *url;int timeout_ms,buffer_size;void *crt_bundle_attach;bool disable_auto_redirect;} esp_http_client_config_t;
static void *esp_crt_bundle_attach;
static const char *response="{\\"current\\":{\\"temperature_2m\\":25,\\"apparent_temperature\\":26,\\"weather_code\\":0},\\"daily\\":{\\"temperature_2m_min\\":[20],\\"temperature_2m_max\\":[28],\\"precipitation_probability_max\\":[10]}}";
static void *esp_http_client_init(const esp_http_client_config_t *c){assert(held&&ha_network_ready()&&http_budget(true));assert(c->buffer_size==512&&c->disable_auto_redirect);if(!attempts)first_attempt=now;attempts++;offset=0;return (void*)1;}
static int esp_http_client_open(void *h,int n){return ESP_OK;}
static int esp_http_client_fetch_headers(void *h){return strlen(response);}
static int esp_http_client_read(void *h,char *out,int size){int n=strlen(response)-offset;if(n>size)n=size;if(n>17)n=17;memcpy(out,response+offset,n);offset+=n;return n;}
static int esp_http_client_get_status_code(void *h){return mode==4?500:200;}
static bool esp_http_client_is_complete_data_received(void *h){return offset==(int)strlen(response);}
static void esp_http_client_close(void *h){}
static void esp_http_client_cleanup(void *h){if(mode==5)state.generation++;}
static time_t fixture_time(time_t *t){return 1791453000;}
#define time fixture_time
${weather}
static void run(unsigned scenario){
 mode=scenario;now=0;held=attempts=allocations=saves=0;first_attempt=0;until=mode==4?302:20;
 weather_last_attempt=0;weather_refresh_requested=false;state=(c6_source_snapshot_t){.generation=1};
 settings=(standalone_config_t){.enabled=true,.weather=mode!=6,.latitude=44,.longitude=55,.weather_minutes=30};
 if(!setjmp(stop))weather_task(NULL);
 assert(!held);if(mode==6){assert(!attempts&&!allocations&&state.weather_phase==0);return;}
 if(mode==4){assert(attempts==2&&!saves&&state.weather.valid&&state.weather.temperature==17&&state.weather_phase==5);return;}
 if(mode==5){assert(attempts==1&&!saves&&state.weather.temperature==17);return;}
 assert(attempts==1&&saves==1&&state.weather.temperature==25&&state.weather_phase==4);
 if(mode==0)assert(first_attempt==3);if(mode==1)assert(first_attempt==10);if(mode==2)assert(first_attempt==3);if(mode==3)assert(first_attempt==5&&allocations==2);
}
int main(void){
 standalone_config_t c={0};for(unsigned i=0;i<4;i++)assert(!c6_source_needed(&c,i));
 c.enabled=c.ha_enabled=true;c.entity_count=1;strcpy(c.entities[0].id,"camera.test");
 assert(c6_source_needed(&c,C6_WORK_HA)&&c6_source_needed(&c,C6_WORK_MEDIA)&&!c6_source_needed(&c,C6_WORK_MQTT)&&!c6_source_needed(&c,C6_WORK_FORM));
 c.printer_count=3;
 for(unsigned i=0;i<3;i++){c.printers[i].enabled=true;snprintf(c.printers[i].status_entity,128,"sensor.%u_print_status",i);strcpy(c.printers[i].progress_entity,"sensor.shared");}
 c.printers[0].source_ha=true;c.printers[1].source_formlabs=true;
 assert(c6_source_needed(&c,C6_WORK_MQTT)&&c6_source_needed(&c,C6_WORK_FORM));
 c6_ha_config_t compact;c6_ha_project(&c,&compact);assert(compact.count==3&&sizeof(compact)<sizeof(c));
 c.printers[0].show_image=true;strcpy(c.printers[0].image_entity,"camera.test");c6_ha_project(&c,&compact);assert(compact.count==3);
 c.printers[0].enabled=false;c6_ha_project(&c,&compact);assert(compact.count==1);
 c.ha_enabled=false;c6_ha_project(&c,&compact);assert(compact.count==0&&!compact.ha_token[0]);
 c=(standalone_config_t){.enabled=true,.ha_enabled=true,.entity_count=6,.printer_count=3};
 for(unsigned i=0;i<6;i++)snprintf(c.entities[i].id,128,"sensor.entity_%u",i);
 for(unsigned i=0;i<3;i++){
  c6_printer_config_t *p=&c.printers[i];p->enabled=p->source_ha=p->show_image=p->show_nozzle=p->show_bed=p->show_error=p->show_remaining=true;p->time_mode=1;
  char *fields[]={p->status_entity,p->progress_entity,p->task_entity,p->remaining_entity,p->image_entity,p->nozzle_entity,p->bed_entity,p->error_entity,p->end_time_entity,p->task_cover_entity};
  for(unsigned k=0;k<10;k++)snprintf(fields[k],128,"sensor.printer_%u_field_%u",i,k);
 }
 c6_ha_project(&c,&compact);assert(compact.count==36);const char *ids[36];assert(ha_ids(&compact,ids)==36&&!strcmp(ids[35],"sensor.printer_2_field_9"));
 assert(c6_http_budget(true,90000,32768)&&!c6_http_budget(true,89999,50000)&&!c6_http_budget(true,120000,32767));
 assert(c6_http_budget(false,64000,16384)&&!c6_http_budget(false,64000,16383));
 for(unsigned i=0;i<7;i++)run(i);
 printf("C6 resources: compact HA %zu vs full config %zu bytes; feature gating, fragmentation budget, delayed DHCP, low heap, busy media, allocation recovery, 300s backoff, retained cache and stale response rejection passed\\n",sizeof(compact),sizeof(c));
}
`;
try{
 const binary=join(stage,'resources');const build=spawnSync('clang',['-std=c11','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',join(cjson,'cJSON.c'),'-lm','-o',binary],{input:program,encoding:'utf8'});assert.equal(build.status,0,build.stderr);
 const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
}finally{rmSync(stage,{recursive:true,force:true});}
