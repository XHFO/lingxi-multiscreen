// Actual detail-render function, fake time/media only. No device or cloud.
import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_render.h'),'utf8');
const extract=(a,b)=>{const start=source.indexOf(a),end=source.indexOf(b,start);assert(start>=0&&end>start);return source.slice(start,end);};
const stage=mkdtempSync('/private/tmp/formlabs-demo-runtime.');
const program=`
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include "local_sources.h"
#include "source_budget.h"
#include "c6_display_renderer.h"
standalone_config_t standalone_config;
static uint32_t frame_generation;static unsigned renders,media_visits;
static uint64_t seconds=1;static time_t epoch=1800000000;
static c6_render_printer_t captured;static char timing[64],updated[64];
uint64_t c6_seconds(void){return seconds;}
static time_t fake_time(time_t *p){return epoch;}
#define time(p) fake_time(p)
static const char *local_format(const char *zh,const char *en){return standalone_config.language?en:zh;}
static c6_render_style_t local_style(void){return (c6_render_style_t){0};}
c6_render_style_t c6_renderer_default_style(void){return (c6_render_style_t){0};}
static c6_renderer_t *renderer(void){return NULL;}
static void calibrated_display(void){frame_generation++;}
void c6_sources_media_focus(int e,int p){}
void c6_renderer_printer(c6_renderer_t *r,const c6_render_printer_t *p){renders++;captured=*p;snprintf(timing,sizeof(timing),"%s",p->time_text);snprintf(updated,sizeof(updated),"%s",p->updated_text);}
static void render_printer_pictures(const c6_thumbnail_cache_t *const *p,unsigned n,void *context){c6_renderer_printer(NULL,context);}
void c6_sources_printer_pictures_visit_scoped(const char *serial,const char *brand,const char *src,const char *key,c6_media_visitor_t visit,void *context){media_visits++;visit(NULL,0,context);}
${extract('static uint64_t weather_hash_bytes(uint64_t hash,const void *bytes,size_t count){','static uint64_t weather_visible_key(')}
${extract('static uint64_t render_string_key(', 'static c6_render_style_t local_style(')}
${extract('static void draw_printer(', 'static void draw_printer_overview')}
int main(void){
  c6_source_snapshot_t sources={0};standalone_config.enabled=true;standalone_config.printer_count=1;
  c6_printer_config_t *p=&standalone_config.printers[0];p->enabled=p->source_formlabs=p->show_image=p->show_progress=p->show_status=p->show_remaining=p->show_layers=p->show_material=true;
  strcpy(p->name,"My printer");
  for(unsigned id=1;id<=4;id++)for(int style=0;style<3;style++)for(int mode=0;mode<2;mode++){
    snprintf(p->serial,40,";;tex_%u",id);p->card_style=style;p->time_mode=mode;
    assert(c6_form_demo_seed(p,&sources.printers[0]));assert(!c6_source_needed(&standalone_config,C6_WORK_FORM));
    frame_generation++;draw_printer(0,&sources);unsigned before=renders;
    assert(captured.demo&&!captured.show_image&&!strcmp(updated,"DEMO / FIXED")&&!strcmp(captured.name,"My printer"));
    assert(captured.card_style==style);
    if(id==2)assert(captured.remaining_seconds==2520&&strstr(timing,"42"));
    for(unsigned i=0;i<100;i++){seconds+=3600;epoch+=3600;draw_printer(0,&sources);assert(renders==before);}
  }
  assert(!media_visits);
  // A real snapshot still advances its remaining time and uses the real media
  // path; ordinary names/options don't become a synthetic fixture.
  strcpy(p->serial,"REAL_01");p->card_style=0;p->time_mode=0;
  sources.printers[0]=(c6_printer_state_t){.known=true,.connected=true,.remaining=42,.remaining_valid=true,.progress=74,.progress_valid=true,.remaining_updated=seconds};strcpy(sources.printers[0].status,"printing");
  frame_generation++;draw_printer(0,&sources);assert(!captured.demo&&captured.remaining_seconds==2520&&media_visits==1);
  seconds+=120;draw_printer(0,&sources);assert(captured.remaining_seconds==2400&&media_visits==2);
  // Body status must refresh even if all optional status/error/time rows are
  // hidden. Changing a device state cannot leave an old ready/completed icon.
  p->show_status=p->show_error=p->show_remaining=p->show_progress=p->show_image=false;
  draw_printer(0,&sources);unsigned before=renders;draw_printer(0,&sources);assert(renders==before);
  strcpy(sources.printers[0].status,"idle");draw_printer(0,&sources);assert(renders==++before&&!strcmp(captured.status,"idle"));
  draw_printer(0,&sources);assert(renders==before);
  sources.printers[0].connected=false;draw_printer(0,&sources);assert(renders==++before&&!captured.connected);
  sources.printers[0].connected=true;draw_printer(0,&sources);assert(renders==++before&&captured.connected);
  strcpy(sources.printers[0].error,"Tank error");draw_printer(0,&sources);assert(renders==++before&&captured.is_error);
  sources.printers[0].error[0]=0;draw_printer(0,&sources);assert(renders==++before&&!captured.is_error);
  strcpy(sources.printers[0].status,"printing");draw_printer(0,&sources);before=renders;
  sources.printers[0].completed_at=1;draw_printer(0,&sources);assert(renders==++before&&captured.completed);
  draw_printer(0,&sources);assert(renders==before);
  puts("Actual printer detail: 4 static demos x 3 styles x 2 timing modes, fixed over time, always marked, no media visits; real countdown/media path retained");
  puts("Hidden optional rows: idle/printing/offline/error/completed changes still redraw body status; unchanged snapshots do not redraw");
}
`;
const file=join(stage,'test.c');writeFileSync(file,program);
const cjson=join(process.env.PLATFORMIO_CORE_DIR||join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
let r=spawnSync('clang',['-std=c11','-D_POSIX_C_SOURCE=200809L','-D','C6_FORMLABS_ONLY=1','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-I',join(root,'Sources/C6DisplayRenderer/include'),file,join(root,'Tools/WaveshareC6Firmware/src/local_state.c'),join(cjson,'cJSON.c'),'-o',join(stage,'test')],{encoding:'utf8'});
assert.equal(r.status,0,r.stderr);r=spawnSync(join(stage,'test'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);process.stdout.write(r.stdout);

// Reserved codes must not become a credential bypass in the generic build.
const generic=join(stage,'generic.c');writeFileSync(generic,`#include <assert.h>\n#include "form_demo.h"\nint main(void){c6_printer_config_t p={.source_formlabs=true};strcpy(p.serial,";;tex_2");assert(!c6_form_demo_id(p.serial)&&!c6_form_is_demo(&p));}\n`);
r=spawnSync('clang',['-std=c11','-D','C6_FORMLABS_ONLY=0','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),generic,'-o',join(stage,'generic')],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
r=spawnSync(join(stage,'generic'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
