import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
const root=new URL('../../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/local_render.h'),'utf8');
const extract=(a,b)=>{const start=source.indexOf(a),end=source.indexOf(b,start);assert(start>=0&&end>start);return source.slice(start,end);};
const hash=extract('static uint64_t weather_hash_bytes(uint64_t hash,const void *bytes,size_t count){','static uint64_t weather_visible_key(');
const controls=extract('static uint64_t render_string_key(', 'static c6_render_style_t local_style(');
const overview=extract('static void draw_printer_overview(', 'static void draw_weather_content');
const stage=mkdtempSync('/private/tmp/formlabs-overview-runtime.');
const c=`
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "local_sources.h"
#include "form_demo.h"
#include "c6_display_renderer.h"
standalone_config_t standalone_config;
static uint32_t frame_generation;static unsigned renders,presents;static int focus_entity,focus_printer;
static c6_render_printer_summary_t captured[3];static unsigned captured_count;
static c6_renderer_t *renderer(void){return NULL;}
void c6_sources_media_focus(int entity,int printer){focus_entity=entity;focus_printer=printer;}
static void calibrated_display(void){presents++;frame_generation++;}
void c6_renderer_printer_overview(c6_renderer_t *r,const c6_render_printer_summary_t *rows,unsigned count){assert(count<=3);renders++;captured_count=count;memcpy(captured,rows,count*sizeof(*rows));}
${hash}
${controls}
${overview}
int main(void){
  c6_source_snapshot_t sources={0};standalone_config.printer_count=3;
  for(unsigned i=0;i<3;i++){
    snprintf(standalone_config.printers[i].name,sizeof(standalone_config.printers[i].name),"User %u",i);
    standalone_config.printers[i].enabled=true;sources.printers[i].connected=true;
    sources.printers[i].progress_valid=true;sources.printers[i].progress=(i+1)*25;strcpy(sources.printers[i].status,"printing");
  }
  draw_printer_overview(&sources);assert(renders==1&&presents==1&&captured_count==3&&focus_entity==-1&&focus_printer==-1);
  assert(!strcmp(captured[1].name,"User 1")&&captured[1].progress==50);
  for(unsigned i=0;i<100;i++)draw_printer_overview(&sources);assert(renders==1);
  strcpy(sources.printers[0].task,"New task / not visible in overview");sources.printers[0].remaining=999;draw_printer_overview(&sources);assert(renders==1);
  sources.printers[1].progress=51;draw_printer_overview(&sources);assert(renders==2&&captured[1].progress==51&&captured[0].progress==25);
  sources.printers[1].connected=false;draw_printer_overview(&sources);assert(renders==3&&!captured[1].connected);
  strcpy(sources.printers[1].status,"finished");draw_printer_overview(&sources);assert(renders==3);
  sources.printers[1].progress_valid=false;draw_printer_overview(&sources);assert(renders==4&&!captured[1].progress_available);
  sources.printers[1].progress=99;draw_printer_overview(&sources);assert(renders==4);
  standalone_config.printers[2].enabled=false;draw_printer_overview(&sources);assert(renders==5&&!captured[2].enabled&&!captured[2].progress_available);
  sources.printers[2].progress=88;draw_printer_overview(&sources);assert(renders==5);
  strcpy(standalone_config.printers[0].name,"Renamed");draw_printer_overview(&sources);assert(renders==6&&!strcmp(captured[0].name,"Renamed"));
  standalone_config.printer_count=2;draw_printer_overview(&sources);assert(renders==7&&captured_count==2);
  frame_generation++;draw_printer_overview(&sources);assert(renders==8);draw_printer_overview(&sources);assert(renders==8);
  standalone_config.language=1;draw_printer_overview(&sources);assert(renders==9);
  standalone_config.printers[0].source_formlabs=true;strcpy(standalone_config.printers[0].serial,";;tex_2");draw_printer_overview(&sources);assert(renders==10&&captured[0].demo&&!captured[1].demo);
  draw_printer_overview(&sources);assert(renders==10);
  strcpy(standalone_config.printers[0].serial,"REAL_2");draw_printer_overview(&sources);assert(renders==11&&!captured[0].demo);
  puts("Actual overview runtime: borrowed rows, device names/isolation, disabled/unknown progress, no-op redraw suppression and display invalidation passed");
}
`;
const file=join(stage,'test.c');writeFileSync(file,c);
const cjson=join(process.env.PLATFORMIO_CORE_DIR||join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
let r=spawnSync('clang',['-std=c11','-D_POSIX_C_SOURCE=200809L','-D','C6_FORMLABS_ONLY=1','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-I',join(root,'Sources/C6DisplayRenderer/include'),file,'-o',join(stage,'test')],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
r=spawnSync(join(stage,'test'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);process.stdout.write(r.stdout);
