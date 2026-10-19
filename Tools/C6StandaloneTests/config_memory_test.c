#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"

// Bound the combined request/config/JSON allocations, not just cJSON.
// The HTTP response and NVS mocks use fixed storage, like the device API.
typedef union { max_align_t alignment; struct {size_t size;bool counted;} value; } allocation_t;
static size_t live_bytes,peak_bytes,heap_limit=SIZE_MAX,failed_allocations,allocation_index,fail_at;
static bool measuring;
static void *bounded_malloc(size_t size){
    if(measuring){allocation_index++;if((fail_at&&allocation_index==fail_at)||size>heap_limit-live_bytes){failed_allocations++;return NULL;}}
    allocation_t *a=malloc(sizeof(*a)+size);if(!a)return NULL;
    a->value.size=size;a->value.counted=measuring;
    if(measuring){live_bytes+=size;if(live_bytes>peak_bytes)peak_bytes=live_bytes;}
    return a+1;
}
static void bounded_free(void *ptr){
    if(!ptr)return;allocation_t *a=(allocation_t *)ptr-1;
    if(a->value.counted){assert(live_bytes>=a->value.size);live_bytes-=a->value.size;}
    free(a);
}
static void *bounded_calloc(size_t count,size_t size){
    if(size&&count>SIZE_MAX/size)return NULL;
    void *p=bounded_malloc(count*size);if(p)memset(p,0,count*size);return p;
}
#define malloc bounded_malloc
#define calloc bounded_calloc
#define free bounded_free
#define C6_JSON_REFERENCE_TEST 1
#define main baseline_main
#include "firmware_contract.c"
#undef main
#undef malloc
#undef calloc
#undef free

static void begin_measure(size_t limit,size_t fail){
    assert(!live_bytes);heap_limit=limit;live_bytes=peak_bytes=failed_allocations=allocation_index=0;fail_at=fail;measuring=true;
}
static void end_measure(void){assert(!live_bytes);measuring=false;heap_limit=SIZE_MAX;fail_at=0;}
static standalone_config_t fixture(void){
    standalone_config_t c=standalone_config;
    c.revision=6;c.enabled=c.clock=c.diagnostics=c.ha_enabled=true;c.ha_port=8123;
    strcpy(c.ha_host,"192.168.1.10");strcpy(c.ha_token,"fixture-ha-token");c.entity_count=4;c.printer_count=1;
    for(unsigned i=0;i<c.entity_count;i++){snprintf(c.entities[i].id,128,"sensor.test_%u",i);snprintf(c.entities[i].name,64,"测试实体 %u",i);}
    c6_printer_config_t *p=&c.printers[0];memset(p,0,sizeof(*p));
    p->enabled=p->rotate=p->source_ha=p->show_status=p->show_progress=p->show_task=p->show_remaining=true;
    strcpy(p->serial,"TESTX2D");strcpy(p->name,"Fixture X2D");strcpy(p->status_entity,"sensor.fixture_print_status");
    strcpy(p->image_entity,"camera.fixture");strcpy(p->task_cover_entity,"image.fixture");
    return c;
}
static void parity(const standalone_config_t *c){
    for(unsigned secrets=0;secrets<2;secrets++){
        cJSON *reference=document(c,secrets);char *encoded=config_json_encode(c,secrets,NULL,NULL);assert(encoded);
        cJSON *actual=cJSON_ParseWithOpts(encoded,NULL,true);assert(actual&&cJSON_Compare(reference,actual,true));
        if(!secrets){assert(!cJSON_HasObjectItem(cJSON_GetObjectItemCaseSensitive(actual,"ha"),"token"));
            cJSON *printers=cJSON_GetObjectItemCaseSensitive(actual,"printers");for(unsigned i=0;i<c->printer_count;i++){
                cJSON *p=cJSON_GetArrayItem(printers,i);assert(!cJSON_HasObjectItem(p,"access_code")&&!cJSON_HasObjectItem(p,"form_client_secret"));
            }}
        cJSON_Delete(reference);cJSON_Delete(actual);bounded_free(encoded);
    }
}
int main(void){
    cJSON_Hooks hooks={bounded_malloc,bounded_free};cJSON_InitHooks(&hooks);
    standalone_config_t original=fixture();standalone_config=original;strcpy(standalone_token,"1234abcd1234abcd");
    cJSON *j=document(&original,true);char *body=cJSON_PrintUnformatted(j);cJSON_Delete(j);assert(body);
    httpd_req_t req={.method=HTTP_PUT,.body=body,.content_len=(int)strlen(body),.auth="Bearer 1234abcd1234abcd"};
    begin_measure(24000,0);handler(&req);size_t peak=peak_bytes,failures=failed_allocations;end_measure();
    printf("config size=%zu input=%zu limited-heap peak=%zu failures=%zu status=%d\n",sizeof(original),strlen(body),peak,failures,req.status);
    assert(req.status==200&&standalone_config.revision==original.revision+1&&peak<22000);
    // Every request/DOM/staging/output allocation can fail without replacing
    // the old config or losing its secrets. Failure after commit is distinguishable
    // from a rejected save, and the persisted revision must match live state.
    size_t calls=allocation_index;
    char saved[C6_CONFIG_BYTES];
    for(size_t fail=1;fail<=calls;fail++){
        standalone_config=original;strcpy(stored_blob,"previous-saved-fixture");strcpy(saved,stored_blob);applied=0;
        httpd_req_t fault={.method=HTTP_PUT,.body=body,.content_len=(int)strlen(body),.auth="Bearer 1234abcd1234abcd"};
        begin_measure(SIZE_MAX,fail);handler(&fault);assert(failed_allocations==1);end_measure();
        if(!applied){assert(!memcmp(&standalone_config,&original,sizeof(original))&&!strcmp(stored_blob,saved));}
        else {assert(standalone_config.revision==original.revision+1);cJSON *stored=cJSON_Parse(stored_blob);assert(stored);assert(cJSON_GetObjectItemCaseSensitive(stored,"revision")->valueint==standalone_config.revision);cJSON_Delete(stored);}
    }
    bounded_free(body);
    parity(&original);
    standalone_config_t varied=original;varied.entity_count=6;varied.printer_count=3;
    varied.latitude=-89.12345678901234;varied.longitude=179.12345678901234;varied.theme.tertiary_text=0xFFFFFF;
    strcpy(varied.weather_city,"中文 \"quoted\" \\ slash\n\t\r\b\f\001\037");
    for(unsigned i=0;i<6;i++){snprintf(varied.entities[i].id,128,"sensor.all_%u",i);strcpy(varied.entities[i].name,"设备😀\n\"\\\t");}
    for(unsigned i=0;i<3;i++){
        varied.printers[i]=original.printers[0];c6_printer_config_t *p=&varied.printers[i];
        snprintf(p->serial,40,"printer_%u",i);strcpy(p->name,"Bambu \"X2D\" \\测试\n");
        memset(p->certificate,'z',2047);p->certificate[2047]=0;strcpy(p->access_code,"fixture-code");strcpy(p->form_client_secret,"fixture-form-secret");
        p->source_formlabs=i==2;p->source_ha=i==1;p->show_image=p->show_layers=p->show_material=p->show_nozzle=p->show_bed=p->show_error=p->live_image=true;
    }
    parity(&varied);
    config_display_override_t display={.revision=7,.rotation=180,.card_mask=5,.flip=false,.printers=2};
    body=config_json_encode(&varied,true,&display,NULL);j=cJSON_Parse(body);assert(j);
    assert(cJSON_GetObjectItemCaseSensitive(j,"revision")->valueint==7&&cJSON_GetObjectItemCaseSensitive(j,"card_mask")->valueint==5);
    cJSON *printers=cJSON_GetObjectItemCaseSensitive(j,"printers");for(unsigned i=0;i<3;i++)assert(cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(cJSON_GetArrayItem(printers,i),"rotate"))==(i==1));
    bounded_free(body);cJSON_Delete(j);assert(varied.revision==6&&varied.printers[0].rotate);
    for(unsigned i=0;i<3;i++){memset(varied.printers[i].certificate,'"',2047);varied.printers[i].certificate[2047]=0;}
    bool too_large=false;begin_measure(SIZE_MAX,0);body=config_json_encode(&varied,true,NULL,&too_large);assert(!body&&too_large&&!allocation_index);end_measure();
    standalone_config=original;strcpy(stored_blob,"display-old-fixture");
    begin_measure(SIZE_MAX,1);assert(!standalone_save_display(6,180,false,3,0));end_measure();
    assert(!memcmp(&standalone_config,&original,sizeof(original))&&!strcmp(stored_blob,"display-old-fixture"));
    begin_measure(4000,0);assert(standalone_save_display(6,180,false,3,0)&&peak_bytes<2000);end_measure();
    // Repeated GETs allocate only their exact redacted response, not a DOM.
    for(unsigned i=0;i<1000;i++){
        httpd_req_t get={.method=HTTP_GET,.auth="Bearer 1234abcd1234abcd"};
        begin_measure(4000,0);handler(&get);assert(get.status==200&&peak_bytes<2000&&!strstr(get.response,"fixture-ha-token"));end_measure();
    }
    printf("allocation-failure rollback covered %zu points; exact JSON parity, escaping, size rejection, display save and 1000 GET cycles passed\n",calls);
    puts("C6 bounded configuration-save memory contract passed");
}
