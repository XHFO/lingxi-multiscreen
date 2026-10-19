// Exercise the production cloud worker and HTTP exchange with a bounded fake
// clock/network. This does not access real accounts or flash a device.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {strict as assert} from 'node:assert';
const root=new URL('../../',import.meta.url).pathname;
const cjson=process.env.LINGXI_CJSON_ROOT??join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_sources.c'),'utf8');
const worker=source.slice(source.indexOf('static cJSON *form_request('),source.indexOf('static void weather_task('));
assert.ok(worker.includes('static void form_task'));
const program=`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <setjmp.h>
#include "local_sources.h"
#include "formlabs_source.h"
#include "source_budget.h"
#define MESSAGE_LIMIT 16384
#define HTTP_METHOD_POST 1
#define HTTP_METHOD_GET 0
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
typedef void *esp_http_client_handle_t;
typedef struct {const char *url;int timeout_ms,buffer_size;void *crt_bundle_attach;bool disable_auto_redirect;int method;} esp_http_client_config_t;
static void *esp_crt_bundle_attach;
static standalone_config_t settings;
static c6_source_snapshot_t state;
static c6_thumbnail_cache_t thumbnails[C6_MAX_PRINTERS];
static unsigned media_focus;
static int lock,media_http_lock,mode,token_calls,printer_calls,picture_calls;
static int http_status,offset,kind,bearer_headers;
static uint64_t now,until;
static char response[MESSAGE_LIMIT];
static jmp_buf stop;
#define pdTRUE 1
static int xSemaphoreTake(int l,int t){return pdTRUE;}
static void xSemaphoreGive(int l){}
static bool runtime_enabled(unsigned work){return c6_source_needed(&settings,work);}
static bool ha_network_ready(void){return true;}
static bool http_budget(bool tls){return mode!=6;}
uint64_t c6_seconds(void){return now;}
static bool current(unsigned generation){return generation==state.generation;}
static time_t fixture_time(time_t *t){return 1791453000;}
#define time fixture_time
static uint32_t esp_get_free_heap_size(void){return mode==6?80000:120000;}
static void vTaskDelete(void *p){assert(0);}
static void vTaskDelay(int ms){
    now+=ms/1000;
    if(mode==9&&now==10){strcpy(settings.printers[0].form_client_id,"other");state.generation++;}
    if(mode==10&&now==10)media_focus=1;
    if(now>=until)longjmp(stop,1);
}
static void *esp_http_client_init(const esp_http_client_config_t *c){
    assert(c->disable_auto_redirect&&c->timeout_ms==6000&&c->buffer_size==1024);
    offset=0;bearer_headers=0;http_status=200;kind=c->method;
    if(kind==HTTP_METHOD_POST){
        assert(!strcmp(c->url,"https://api.formlabs.com/developer/v1/o/token/"));token_calls++;
        snprintf(response,sizeof(response),"{\\"access_token\\":\\"fixture-token\\",\\"expires_in\\":%d}",mode==3?130:3600);
    }else{
        assert(!strcmp(c->url,"https://api.formlabs.com/developer/v1/printers/Form-123/"));printer_calls++;
        if(mode==1)http_status=401;if(mode==2)http_status=429;
        snprintf(response,sizeof(response),"{\\"serial\\":\\"Form-123\\",\\"status\\":{\\"status\\":\\"%s\\",\\"current_print_run\\":{\\"id\\":17,\\"name\\":\\"fixture\\",\\"status\\":\\"%s\\",\\"currently_printing_layer\\":4,\\"layer_count\\":10,\\"print_thumbnail\\":{\\"thumbnail\\":\\"https://files.formlabs.com/fixture.png\\"}}}}",mode==4?"idle":"printing",mode==4?"idle":"printing");
        if(mode==5)state.generation++; // Configuration changed while in flight.
    }
    return (void*)1;
}
static void esp_http_client_set_header(void *h,const char *key,const char *value){
    if(!strcmp(key,"Authorization")){assert(kind==HTTP_METHOD_GET&&!strcmp(value,"Bearer fixture-token"));bearer_headers++;}
    else assert(kind==HTTP_METHOD_POST&&!strcmp(key,"Content-Type")&&!strcmp(value,"application/x-www-form-urlencoded"));
}
static int esp_http_client_open(void *h,int length){if(kind==HTTP_METHOD_GET)assert(bearer_headers==1);else assert(!bearer_headers&&length>0);return ESP_OK;}
static int esp_http_client_write(void *h,const char *body,int length){
    assert(strstr(body,mode==9&&now>=10?"client_id=other":"client_id=client%2Bid"));
    assert(strstr(body,"client_secret=secret%26value"));return length;
}
static int64_t esp_http_client_fetch_headers(void *h){return strlen(response);}
static int esp_http_client_get_status_code(void *h){return http_status;}
static int esp_http_client_read(void *h,char *out,int size){int n=(int)strlen(response)-offset;if(n>size)n=size;if(n>31)n=31;memcpy(out,response+offset,n);offset+=n;return n;}
static bool esp_http_client_is_complete_data_received(void *h){return mode!=7&&offset==(int)strlen(response);}
static void esp_http_client_close(void *h){}
static void esp_http_client_cleanup(void *h){}
static unsigned thumbnail_fetch(const char *url,const char *token,bool tls,uint8_t **pixels,unsigned *width,unsigned *height){
    assert(!strcmp(url,"https://files.formlabs.com/fixture.png")&&!token&&tls);picture_calls++;
    *width=*height=20;*pixels=calloc(1,800);return 1;
}
int c6_sources_thumbnail_store_scoped(int revision,const char *serial,const char *brand,const char *source,const char *key,unsigned width,unsigned height,uint8_t *pixels,size_t length){
    assert(!strcmp(brand,"formlabs")&&!strcmp(source,"formlabs"));
    if(revision!=settings.revision||strcmp(key,state.printers[0].thumbnail_key))return 409;
    bool ok=c6_thumbnail_commit(&thumbnails[0],serial,key,width,height,pixels,length);state.thumbnail_status[0]=ok?1:4;return ok?200:400;
}
${worker}
static void run(int scenario,uint64_t duration){
    c6_thumbnail_clear(&thumbnails[0]);memset(&settings,0,sizeof(settings));memset(&state,0,sizeof(state));
    mode=scenario;token_calls=printer_calls=picture_calls=0;now=0;until=duration;media_focus=scenario==10?UINT32_C(1)<<31:0;
    settings.enabled=true;settings.printer_count=1;settings.revision=7;state.generation=1;
    c6_printer_config_t *p=&settings.printers[0];p->enabled=p->source_formlabs=p->show_image=true;
    strcpy(p->serial,"Form-123");strcpy(p->form_client_id,"client+id");strcpy(p->form_client_secret,"secret&value");
    if(!setjmp(stop))form_task(NULL);
}
int main(void){
    run(0,65);assert(token_calls==1&&printer_calls==3&&picture_calls==1&&state.form_phase[0]==1&&state.printers[0].progress==40);
    run(4,125);assert(token_calls==1&&printer_calls==2); // idle 120s
    run(1,301);assert(token_calls==2&&printer_calls==2&&state.form_phase[0]==3&&!state.printers[0].connected);
    run(2,301);assert(token_calls==1&&printer_calls==2); // rate-limit 300s, token retained
    run(3,35);assert(token_calls==2&&printer_calls==2); // refresh 120s before expiry
    run(5,1);assert(printer_calls==1&&!state.printers[0].thumbnail_key[0]&&!picture_calls); // reject stale response
    run(6,65);assert(!token_calls&&!printer_calls&&state.form_phase[0]==4); // low heap
    run(7,65);assert(token_calls==2&&!printer_calls&&!state.printers[0].updated); // incomplete token
    run(9,15);assert(token_calls==2&&printer_calls==2); // changed account invalidates token
    run(10,15);assert(printer_calls==2&&picture_calls==1); // visible-page entry fetches cover promptly
    c6_thumbnail_clear(&thumbnails[0]);
    puts("C6 Formlabs cloud worker: actual bounded HTTP/OAuth escaping, bearer isolation, token reuse/expiry, 30/120s polling, 401/429 backoff, source race, incomplete data, heap guard and visible-cover refresh passed");
}
`;
const directory=mkdtempSync(join(tmpdir(),'lingxi-c6-form-network-')),binary=join(directory,'contract');
try{
  const build=spawnSync('clang',['-std=c11','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',join(root,'Tools/WaveshareC6Firmware/src/formlabs_source.c'),join(root,'Tools/WaveshareC6Firmware/src/thumbnail_cache.c'),join(root,'Tools/WaveshareC6Firmware/src/local_state.c'),join(cjson,'cJSON.c'),'-lm','-o',binary],{input:program,encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  const test=spawnSync(binary,[],{encoding:'utf8'});assert.equal(test.status,0,test.stderr);console.log(test.stdout.trim());
}finally{rmSync(directory,{recursive:true,force:true});}
