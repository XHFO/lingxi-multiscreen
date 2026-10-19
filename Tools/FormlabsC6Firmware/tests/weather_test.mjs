import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import vm from 'node:vm';
const root=new URL('../../../',import.meta.url),source=readFileSync(new URL('Tools/FormlabsC6Firmware/web/weather.js',root),'utf8');
const elements=new Map(),timers=new Map(),listeners={};let n=0,edits=0,fetcher;
class Element{
    constructor(){this.value='';this.checked=false;this.children=[];this.handlers={};}
    append(...items){this.children.push(...items);}replaceChildren(){this.children=[];}
    addEventListener(name,cb){this.handlers[name]=cb;}
}
const $=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
const baseline={weather_city:'Old City',latitude:12,longitude:34,weather:true,revision:4};
$('city').value=baseline.weather_city;$('latitude').value='12';$('longitude').value='34';$('weather_on').checked=true;
const context=vm.createContext({$,encoder:new TextEncoder(),URL,URLSearchParams,AbortController,portalAlive:true,uiEnglish:false,saved:baseline,
    markDirty(){edits++;},document:{createElement:()=>new Element()},window:{addEventListener:(key,cb)=>listeners[key]=cb},
    setTimeout(cb){timers.set(++n,cb);return n;},clearTimeout(id){timers.delete(id);},fetch:(...args)=>fetcher(...args)});
vm.runInContext(source+'\nvar weatherUI=setupWeather();',context);
const run=code=>vm.runInContext(code,context),input=value=>{$('city').value=value;$('city').handlers.input();};
let requests=0;
fetcher=async(url,options)=>{requests++;assert.equal(url.origin,'https://geocoding-api.open-meteo.com');assert.equal(url.searchParams.get('name'),'Test City');assert.equal(options.credentials,'omit');assert(!options.headers&&!options.body);return {ok:true,json:async()=>({results:[{name:'Test City',admin1:'North',country:'Testland',latitude:51.5,longitude:-.12},{name:'Test City',admin1:'South',country:'Testland',latitude:22,longitude:113}]})};};
input('Test City');assert.throws(()=>run('weatherUI.validate()'),/选择匹配/);
await $('citySearch').onclick();assert.equal($('cityResults').children.length,2);assert.equal(requests,1);
assert($('cityResults').children[1].children[1].textContent.includes('South'));
assert.equal($('latitude').value,'12','Searching never selects a guessed location');
$('cityResults').children[1].onclick();assert.equal(Number($('latitude').value),22);assert.equal(Number($('longitude').value),113);assert($('weather_on').checked&&$('weather_rotate').checked);assert.equal(edits,1);run('weatherUI.validate()');
assert($('weatherStatus').textContent.includes('保存'));
context.saved={weather:true,weather_city:'Test City',latitude:22,longitude:113,revision:5};
run("weatherUI.health({config_revision:4,weather_phase:'cached',weather_cached:true})");assert($('weatherStatus').textContent.includes('查询'),'Old health revisions never confirm a new location');
run("weatherUI.health({config_revision:5,weather_phase:'cached',weather_cached:true})");assert($('weatherStatus').textContent.includes('已获取'));
run("weatherUI.health({config_revision:5,weather_phase:'retrying',weather_cached:true})");assert($('weatherStatus').textContent.includes('最近数据'));
run('uiEnglish=true;weatherUI.render()');assert($('weatherStatus').textContent.includes('Last data retained'));assert.equal($('citySearch').textContent,'Find city');
run('weatherUI.health(null)');assert($('weatherStatus').textContent.includes('Cannot read'));
fetcher=async()=>({ok:true,json:async()=>({})});input('Missing City');await $('citySearch').onclick();assert($('cityStatus').textContent.includes('No locations'));assert.equal($('cityResults').children.length,0);
fetcher=async()=>{throw Error('Fixture network failure');};input('Offline City');await $('citySearch').onclick();assert($('cityStatus').textContent.includes('failed'));
$('latitude').value='1';$('latitude').handlers.input();run('weatherUI.validate()');assert($('cityStatus').textContent.includes('manual'));
let resolve;fetcher=()=>new Promise(done=>resolve=done);input('Slow City');const slow=$('citySearch').onclick();input('New City');resolve({ok:true,json:async()=>({results:[{name:'Late',latitude:1,longitude:2}]})});await slow;assert.equal($('cityResults').children.length,0);
$('city').handlers.compositionstart();input('组字');await $('citySearch').onclick();assert.equal($('cityResults').children.length,0);assert.equal(timers.size,0);$('city').handlers.compositionend();assert.equal(timers.size,1);
listeners.pagehide();assert.equal(timers.size,0);
// Compile the scheduling statements from the actual weather worker, not a
// rewritten simulation. No network, tasks or hardware are involved here.
const worker=readFileSync(new URL('Tools/WaveshareC6Firmware/src/local_sources.c',root),'utf8');
const start=worker.indexOf('if(last_lat!=lat||last_lon!=lon)'),end=worker.indexOf('if(!enabled){weather_phase',start);assert(start>0&&end>start);
const stage=mkdtempSync('/private/tmp/formlabs-weather-runtime.');
writeFileSync(stage+'/schedule.c',`#include <assert.h>\n#include <stdbool.h>\nint main(void){double last_lat=12,last_lon=34,lat=12,lon=34;bool enabled=true,last_enabled=false;unsigned long long next=2000;
${worker.slice(start,end)}
assert(next==0&&last_enabled);next=2000;
${worker.slice(start,end)}
assert(next==2000);enabled=false;
${worker.slice(start,end)}
assert(next==2000&&!last_enabled);enabled=true;
${worker.slice(start,end)}
assert(next==0);next=2000;lat=56;
${worker.slice(start,end)}
assert(next==0&&last_lat==56);return 0;}\n`);
const compiled=spawnSync('clang',['-std=c11',stage+'/schedule.c','-o',stage+'/schedule'],{encoding:'utf8'});assert.equal(compiled.status,0,compiled.stderr);
const tested=spawnSync(stage+'/schedule',[],{encoding:'utf8'});assert.equal(tested.status,0,tested.stderr);
console.log('Weather: candidates/regions, explicit selection, coordinates + enable/rotate, actual health/revision, bilingual failure/fallback, IME/cancel/stale response, credential isolation, and compiled worker immediate/re-enable scheduling passed. No hardware test.');
