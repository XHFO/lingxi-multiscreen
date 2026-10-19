// Run the actual firmware cache/store/reconfigure and polling task with bounded
// network/scheduler mocks. No device connection or production credentials.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {strict as assert} from 'node:assert';
const root=new URL('../../',import.meta.url).pathname;
const cjson=process.env.LINGXI_CJSON_ROOT??join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_sources.c'),'utf8');
const cache=source.slice(source.indexOf('static void printer_picture_key('),source.indexOf('static unsigned config_copy('));
const task=source.slice(source.indexOf('typedef struct { char url[512]'),source.indexOf('// One bounded HTTPS exchange'));
assert.ok(cache.includes('c6_sources_reconfigure')&&task.includes('static void thumbnail_task'));
const program=`
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include "local_sources.h"
#include "source_budget.h"
standalone_config_t standalone_config;
static standalone_config_t settings;
static c6_source_snapshot_t state;
static c6_thumbnail_cache_t thumbnails[C6_MAX_PRINTERS];
typedef struct {char path[384],task_key[17];uint64_t next,last_attempt;} thumbnail_source_t;
static thumbnail_source_t thumbnail_sources[C6_MAX_PRINTERS];
static c6_thumbnail_cache_t media_images[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
static thumbnail_source_t media_sources[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
static uint64_t media_age[C6_MAX_PRINTERS*2+C6_MAX_ENTITIES],media_clock;
static unsigned media_focus;
static int lock=1,media_http_lock=1,fetches,failure,race,shade=0x55;
static uint64_t now=100;
static jmp_buf stop;
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
#define pdTRUE 1
static int xSemaphoreTake(int l,int t){return pdTRUE;}
static void xSemaphoreGive(int l){}
static bool runtime_enabled(unsigned work){return c6_source_needed(&settings,work);}
static bool ha_network_ready(void){return true;}
static void vTaskDelay(int t){longjmp(stop,1);}
uint64_t c6_seconds(void){return now;}
static bool current(unsigned g){return g==state.generation;}
${cache}
static unsigned thumbnail_fetch(const char *url,const char *token,bool tls,uint8_t **pixels,unsigned *w,unsigned *h){
    fetches++;assert(!strcmp(url,!strncmp(settings.printers[0].image_entity,"camera.",7)?"http://192.168.1.10:8123/api/camera_proxy/camera.printer":"http://192.168.1.10:8123/api/image_proxy/image.preview"));
    assert(!strcmp(token,"fixture"));
    if(race==1){settings.revision++;state.generation++;}
    if(race==2){c6_thumbnail_clear(&thumbnails[0]);strcpy(state.printers[0].thumbnail_key,"aaaaaaaaaaaaaaaa");}
    if(failure){*pixels=NULL;return 4;}
    *w=*h=80;*pixels=malloc(C6_THUMBNAIL_BYTES);memset(*pixels,shade,C6_THUMBNAIL_BYTES);return 1;
}
${task}
static void poll(void){fetches=0;if(!setjmp(stop))thumbnail_task(NULL);}
int main(void){
    settings.enabled=settings.ha_enabled=true;settings.ha_port=8123;settings.printer_count=1;settings.revision=3;
    strcpy(settings.ha_host,"192.168.1.10");strcpy(settings.ha_token,"fixture");state.generation=1;
    c6_printer_config_t *p=&settings.printers[0];p->enabled=p->source_ha=p->show_image=true;
    strcpy(p->serial,"printer");strcpy(p->image_entity,"camera.printer");strcpy(p->task_entity,"sensor.task");
    strcpy(state.printers[0].thumbnail_key,"1111111111111111");
    poll();assert(fetches==1&&thumbnails[0].bytes&&state.thumbnail_revision[0]==1&&state.thumbnail_status[0]==1);
    assert(thumbnail_sources[0].next==115);uint8_t *valid=thumbnails[0].bytes;
    now=114;poll();assert(fetches==0&&thumbnails[0].bytes==valid);
    now=115;poll();assert(fetches==1&&state.thumbnail_revision[0]==1); // same pixels deduplicated
    shade=0x77;now=130;poll();assert(fetches==1&&state.thumbnail_revision[0]==2&&thumbnails[0].bytes[0]==0x77);
    valid=thumbnails[0].bytes;failure=1;now=145;poll();assert(fetches==1&&thumbnails[0].bytes==valid&&state.thumbnail_revision[0]==2&&state.thumbnail_status[0]==1);
    failure=0;race=1;now=160;poll();assert(fetches==1&&thumbnails[0].bytes==valid&&state.thumbnail_revision[0]==2);
    race=0;standalone_config=settings;standalone_config.printers[0].show_task=true;c6_sources_reconfigure();
    assert(thumbnails[0].bytes==valid&&state.thumbnail_revision[0]==2); // display-only edits retain frame
    strcpy(standalone_config.printers[0].image_entity,"image.cover");c6_sources_reconfigure();assert(!thumbnails[0].bytes&&state.thumbnail_status[0]==0); // source switch cannot leak camera
    strcpy(standalone_config.printers[0].image_entity,"camera.printer");c6_sources_reconfigure();now=175;poll();assert(fetches==1&&thumbnails[0].bytes);
    strcpy(standalone_config.ha_host,"192.168.1.11");c6_sources_reconfigure();assert(!thumbnails[0].bytes&&!state.printers[0].thumbnail_key[0]);
    strcpy(settings.ha_host,"192.168.1.10");strcpy(state.printers[0].thumbnail_key,"1111111111111111");
    race=2;now=190;poll();assert(fetches==1&&!thumbnails[0].bytes); // task changed in flight: reject old snapshot
    race=0;p=&settings.printers[0];p->show_image=false;now=205;poll();assert(fetches==0);
    p->show_image=p->live_image=true;strcpy(p->image_entity,"image.preview");
    strcpy(thumbnail_sources[0].path,"/api/image_proxy/image.preview");strcpy(thumbnail_sources[0].task_key,state.printers[0].thumbnail_key);thumbnail_sources[0].next=0;
    now=220;poll();assert(fetches==1&&thumbnails[0].bytes);uint32_t generation=state.thumbnail_revision[0];
    shade=0x88;now=235;poll();assert(fetches==1&&state.thumbnail_revision[0]==generation+1); // image-domain live snapshot refreshes too
    p->live_image=false;thumbnail_sources[0].next=0;now=250;poll();assert(fetches==0); // a task cover isn't polled like video
    // Hero layouts retain the user's image option but neither fetch nor accept
    // hidden images; switching layout also releases the unused cached pixels.
    p->card_style=1;p->live_image=true;now=260;poll();assert(fetches==0&&p->show_image);
    assert(c6_sources_thumbnail_validate(settings.revision,p->serial,state.printers[0].thumbnail_key)==403);
    strcpy(p->task_cover_entity,"image.cover");assert(c6_sources_media_validate(settings.revision,p->serial,"",state.printers[0].thumbnail_key,true)==403);
    standalone_config=settings;standalone_config.printers[0].card_style=2;c6_sources_reconfigure();assert(!thumbnails[0].bytes&&settings.printers[0].show_image);
    now=275;poll();assert(fetches==0);
    standalone_config.printers[0].card_style=0;c6_sources_reconfigure();assert(settings.printers[0].show_image&&c6_printer_images_enabled(&settings.printers[0]));
    for(unsigned i=0;i<C6_MAX_PRINTERS*2+C6_MAX_ENTITIES;i++)c6_thumbnail_clear(cache_at(i));
    settings.entity_count=6;media_focus=0;
    for(unsigned i=0;i<6;i++){
        snprintf(settings.entities[i].id,128,"camera.entity_%u",i);char key[17];c6_task_key("entity",settings.entities[i].id,key);
        if(i<4){uint8_t *bytes=malloc(80*40*2);memset(bytes,20+i,80*40*2);assert(c6_sources_media_store(settings.revision,"",settings.entities[i].id,key,false,80,40,bytes,80*40*2)==200);}
    }
    c6_sources_media_focus(0,-1);char entity_key[17];c6_task_key("entity",settings.entities[4].id,entity_key);
    uint8_t *fifth=malloc(80*40*2);memset(fifth,99,80*40*2);assert(c6_sources_media_store(settings.revision,"",settings.entities[4].id,entity_key,false,80,40,fifth,80*40*2)==503);assert(!media_images[4].bytes);
    c6_sources_media_focus(1,-1);assert(c6_sources_media_store(settings.revision,"",settings.entities[4].id,entity_key,false,80,40,fifth,80*40*2)==200);
    assert(!media_images[0].bytes&&media_images[1].bytes&&media_images[4].bytes); // bounded LRU never evicts visible frames
    assert(c6_sources_media_validate(settings.revision,"","camera.not_selected",entity_key,false)==404);
    assert(c6_sources_media_validate(settings.revision-1,"",settings.entities[4].id,entity_key,false)==409);
    assert(c6_sources_media_validate(settings.revision,"",settings.entities[4].id,"1111111111111111",false)==409);
    standalone_config=settings;standalone_config.entities[0]=settings.entities[1];standalone_config.entities[1]=settings.entities[0];
    c6_sources_reconfigure();assert(media_images[0].bytes&&media_images[0].bytes[0]==21&&!strcmp(media_images[0].serial,"entity_0"));
    strcpy(settings.printers[0].task_cover_entity,"image.cover");strcpy(state.printers[0].thumbnail_key,"1111111111111111");
    assert(c6_sources_media_validate(settings.revision,"printer","","1111111111111111",true)==200);
    assert(c6_sources_media_validate(settings.revision,"other","","1111111111111111",true)==404);
    uint8_t *cover=malloc(80*40*2);memset(cover,77,80*40*2);assert(c6_sources_media_store(settings.revision,"printer","","1111111111111111",true,80,40,cover,80*40*2)==200);
    strcpy(state.printers[0].thumbnail_key,"2222222222222222");assert(c6_sources_media_validate(settings.revision,"printer","","1111111111111111",true)==409);
    for(unsigned i=0;i<C6_MAX_PRINTERS*2+C6_MAX_ENTITIES;i++)c6_thumbnail_clear(cache_at(i));
    settings.printer_count=2;settings.entity_count=0;media_focus=0;
    settings.printers[0]=(c6_printer_config_t){.enabled=true,.show_image=true,.source_ha=true};
    settings.printers[1]=(c6_printer_config_t){.enabled=true,.show_image=true,.source_formlabs=true};
    for(unsigned i=0;i<2;i++){strcpy(settings.printers[i].serial,"SHARED");strcpy(settings.printers[i].name,"same-name");strcpy(state.printers[i].thumbnail_key,"1111111111111111");state.printers[i].completed_at=100+i;}
    strcpy(settings.printers[1].form_client_id,"form-account");strcpy(settings.printers[1].form_client_secret,"form-secret");
    assert(c6_sources_thumbnail_validate(settings.revision,"SHARED","1111111111111111")==409);
    assert(c6_sources_thumbnail_validate_scoped(settings.revision,"SHARED","bambu","mqtt","1111111111111111")==404);
    for(unsigned i=0;i<2;i++){uint8_t *bytes=malloc(8);memset(bytes,10+i,8);assert(c6_sources_thumbnail_store_scoped(settings.revision,"SHARED",i?"formlabs":"bambu",i?"formlabs":"ha","1111111111111111",2,2,bytes,8)==200);}
    assert(thumbnails[0].bytes[0]==10&&thumbnails[1].bytes[0]==11);
    standalone_config=settings;standalone_config.printers[0]=settings.printers[1];standalone_config.printers[1]=settings.printers[0];c6_sources_reconfigure();
    assert(thumbnails[0].bytes[0]==11&&thumbnails[1].bytes[0]==10&&state.printers[0].completed_at==101&&state.printers[1].completed_at==100);
    strcpy(standalone_config.printers[0].form_client_secret,"changed-account-secret");c6_sources_reconfigure();
    assert(!thumbnails[0].bytes&&!state.printers[0].completed_at&&thumbnails[1].bytes[0]==10&&state.printers[1].completed_at==100);
    standalone_config.printers[1].source_ha=false;strcpy(standalone_config.printers[1].host,"192.168.1.25");c6_sources_reconfigure();assert(!thumbnails[1].bytes&&!state.printers[1].completed_at);
    puts("C6 brand isolation: same-name/same-serial devices, ambiguous legacy rejection, scoped source routing, images/completion reorder, account and source changes passed");
    puts("C6 HA media/dual images: real cache role/entity/revision/task isolation, non-square frames, four-frame global bound, visible-page protection and cache reorder passed");
    puts("C6 static camera: 15s sampling/dedup, last-good frame, hero no-fetch/no-upload/cache-release, source isolation and in-flight races passed");
}
`;
const directory=mkdtempSync(join(tmpdir(),'lingxi-c6-camera-')),binary=join(directory,'contract');
try{
    const build=spawnSync('clang',['-std=c11','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-',join(root,'Tools/WaveshareC6Firmware/src/thumbnail_cache.c'),join(root,'Tools/WaveshareC6Firmware/src/local_state.c'),join(cjson,'cJSON.c'),'-o',binary],{input:program,encoding:'utf8'});
    assert.equal(build.status,0,build.stderr);
    const test=spawnSync(binary,[],{encoding:'utf8'});assert.equal(test.status,0,test.stderr);console.log(test.stdout.trim());
}finally{rmSync(directory,{recursive:true,force:true});}
