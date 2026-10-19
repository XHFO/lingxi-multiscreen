// Compile the actual reconfigure predicate/entity migration lines, not a JS copy.
// No device, credentials, platform SDK or firmware build is involved.
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {strict as assert} from 'node:assert';
const source=readFileSync(new URL('../WaveshareC6Firmware/src/local_sources.c',import.meta.url),'utf8');
const renderer=readFileSync(new URL('../WaveshareC6Firmware/src/local_render.h',import.meta.url),'utf8');
const displayName=renderer.match(/items\[i\]=\(c6_render_entity_t\)\{([^,]+),/)?.[1];assert.ok(displayName,'actual HA display-name expression must exist');
const predicate=source.match(/const bool same_ha=[^;]+;/)?.[0];assert.ok(predicate,'shared HA-origin predicate must exist');
const first=source.indexOf('for(unsigned i=0;i<standalone_config.entity_count;',source.indexOf('void c6_sources_reconfigure'));
const last=source.indexOf('for(unsigned i=0;i<standalone_config.printer_count;',first);
const migration=source.slice(first,last).replace(/extra\[i\]=media_images\[k\];[\s\S]*?extra_revision\[i\]=state.media_revision\[k\];/,'');
assert.ok(first>=0&&last>first);assert.match(source,/bool ha_same=!a->source_ha\|\|same_ha;/);
const program=`
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
typedef struct {char id[128],name[64];} entity_config;
typedef struct {char ha_host[16],ha_token[1024];int ha_port;bool ha_tls;unsigned entity_count;entity_config entities[6];} config;
typedef struct {char value[128],name[64];} entity_state;
static bool display_name_matches(config standalone_config,const entity_state *e,unsigned index,const char *expected){return !strcmp(${displayName},expected);}
static void migrate(config standalone_config,config settings,entity_state cached[6],entity_state out[6]){
    struct {entity_state entities[6];} state;memcpy(state.entities,cached,sizeof(state.entities));
    entity_state entities[6]={0};${predicate}
    ${migration}
    memcpy(out,entities,sizeof(entities));
}
int main(void){
    config previous={.ha_host="192.168.1.10",.ha_token="fixture-token",.ha_port=8123,.entity_count=2};
    strcpy(previous.entities[0].id,"sensor.one");strcpy(previous.entities[1].id,"sensor.two");
    entity_state cached[6]={{.value="first",.name="cached name"},{.value="second",.name="other cached name"}},out[6];config next=previous;
    migrate(next,previous,cached,out);assert(!strcmp(out[0].value,"first")&&!strcmp(out[1].value,"second"));
    strcpy(next.ha_host,"192.168.1.11");migrate(next,previous,cached,out);assert(!*out[0].value&&!*out[1].value);
    next=previous;next.ha_port=80;migrate(next,previous,cached,out);assert(!*out[0].value&&!*out[1].value);
    next=previous;next.ha_tls=true;migrate(next,previous,cached,out);assert(!*out[0].value&&!*out[1].value);
    next=previous;strcpy(next.ha_token,"other-fixture-token");migrate(next,previous,cached,out);assert(!*out[0].value&&!*out[1].value);
    next=previous;strcpy(next.entities[0].id,"sensor.two");strcpy(next.entities[1].id,"sensor.one");migrate(next,previous,cached,out);assert(!strcmp(out[0].value,"second")&&!strcmp(out[1].value,"first"));
    next=previous;strcpy(next.entities[0].id,"sensor.new");next.entity_count=1;migrate(next,previous,cached,out);assert(!*out[0].value&&!*out[1].value);
    next=previous;next.entity_count=1;migrate(next,previous,cached,out);assert(!strcmp(out[0].value,"first")&&!*out[1].value);
    next=previous;strcpy(next.entities[0].name,"new configured name");assert(display_name_matches(next,&cached[0],0,"new configured name"));
    next.entities[0].name[0]=0;assert(display_name_matches(next,&cached[0],0,"cached name"));cached[0].name[0]=0;assert(display_name_matches(next,&cached[0],0,"sensor.one"));
    puts("C6 HA cache origin/name: source changes isolated, same-source edits/reorder retained; explicit name wins offline, friendly-name/ID fallback (11 cases)");
}
`;
const directory=mkdtempSync(join(tmpdir(),'lingxi-c6-ha-cache-')),binary=join(directory,'contract');
try{
    const build=spawnSync('clang',['-std=c11','-Wall','-Wextra','-Werror','-x','c','-','-o',binary],{input:program,encoding:'utf8'});
    assert.equal(build.status,0,build.stderr);
    const test=spawnSync(binary,[],{encoding:'utf8'});assert.equal(test.status,0,test.stderr);console.log(test.stdout.trim());
}finally{rmSync(directory,{recursive:true,force:true});}
