import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import vm from 'node:vm';

const page = readFileSync(new URL('../web/standalone.html', import.meta.url), 'utf8');
const elements = new Map();
class Element {
    constructor(tag) { this.tag = tag; this.value = ''; this.checked = false; this.children = []; this.dataset={}; }
    set id(id) { this.key = id; elements.set(id, this); }
    get id() { return this.key; }
    set value(value) { this.inputValue = String(value); }
    get value() { return this.inputValue; }
    append(...items) { this.children.push(...items); }
    replaceChildren(...items) { this.children = items; }
    addEventListener() {}
    setAttribute() {}
    focus() {}
    closest() { return { textContent: this.id }; }
}
for (const [, id] of page.matchAll(/\bid="([^"]+)"/g)) {
    const el = new Element('input'); el.id = id;
}
const context = vm.createContext({
    TextEncoder, structuredClone, Uint8Array, Uint32Array, DataView,autosave:{change(){}},weatherUI:{render(){},validate(){}},
    document: { getElementById: id => elements.get(id), createElement: tag => new Element(tag), createTextNode: text => text },
});
vm.runInContext(readFileSync(new URL('../web/sha256.js', import.meta.url), 'utf8'), context);
vm.runInContext(readFileSync(new URL('../web/i18n.js', import.meta.url), 'utf8'), context);
for (const size of [0, 1, 3, 55, 56, 63, 64, 65, 1024, 0x1e0000]) {
    const bytes = Uint8Array.from({ length: size }, (_, i) => (i * 131 + 17) & 255);
    context.bytes = bytes;
    assert.equal(vm.runInContext('firmwareSHA256(bytes)', context), createHash('sha256').update(bytes).digest('hex'));
}
const start = page.indexOf('const $=');
const end = page.indexOf('async function request(');
assert(start > 0 && end > start);
vm.runInContext(page.slice(start, end), context);
const baseline = {
    schema_version: 2, revision: 4, enabled: true, local_first: true, diagnostics: false,
    clock: true, flip_animation: true, card_mask: 5, weather: false, timezone: 28800,
    weather_city: '', latitude: 0, longitude: 0, weather_minutes: 30, rotation: 0,
    brightness: 80, interval: 15, saturation_percent: 100, contrast_percent: 100,
    printers: [],
};
context.baseline = baseline;
vm.runInContext('fill(structuredClone(baseline)); saved=structuredClone(baseline)', context);
assert.equal(vm.runInContext('collect().printers.length', context), 0);
assert.equal(vm.runInContext('collect().language', context), 0);
assert.equal(vm.runInContext('collect().digit_style',context),0);
elements.get('digit_style').value=1;assert.equal(vm.runInContext('collect().digit_style',context),1);
elements.get('digit_style').value=2;assert.throws(()=>vm.runInContext('collect()',context),/主数字风格/);elements.get('digit_style').value=0;
assert.equal(vm.runInContext('collect().sleep_mode',context),0);
assert.equal(vm.runInContext('collect().sleep_idle_minutes',context),5);
for(const rotation of [0,90,180,270]){elements.get('rotation').value=rotation;assert.equal(vm.runInContext('collect().rotation',context),rotation);}
elements.get('rotation').value=45;assert.throws(()=>vm.runInContext('collect()',context),/屏幕方向/);elements.get('rotation').value=0;
elements.get('sleep_mode').value=2;elements.get('sleep_end').value='23:00';assert.throws(()=>vm.runInContext('collect()',context),/不能相同/);
elements.get('sleep_end').value='07:00';assert.equal(vm.runInContext('collect().sleep_end',context),420);elements.get('sleep_mode').value=0;
const printers = [0, 1, 2].map(i => ({
    name: `Form ${i}`, serial: `FORM_${i}`, form_client_id: 'one-account', form_credentials_set: true,
    enabled: true, rotate: true, source_formlabs: true, show_task: true, show_status: true,
    show_progress: true, show_remaining: true, show_image: true, show_layers: true,
    show_material: true, brand_accent: true, time_mode: 0,
}));
context.printers = printers;
vm.runInContext('baseline.printers=printers; saved=structuredClone(baseline); fill(structuredClone(baseline))', context);
assert.equal(vm.runInContext('collect().printers[0].card_style',context),0);
elements.get('style_0').value=1;elements.get('style_0').onchange();assert(elements.get('show_image_0').disabled&&elements.get('show_progress_0').disabled);
assert.equal(vm.runInContext('collect().printers[0].card_style',context),1);assert.equal(vm.runInContext('collect().printers[1].card_style',context),0);
elements.get('style_0').value=2;elements.get('style_0').onchange();assert(elements.get('time_0').disabled&&elements.get('show_remaining_0').disabled);
assert.equal(vm.runInContext('collect().printers[0].card_style',context),2);
elements.get('style_0').value=3;assert.throws(()=>vm.runInContext('collect()',context),/卡片样式/);
elements.get('style_0').value=0;elements.get('style_0').onchange();assert(!elements.get('show_image_0').disabled&&!elements.get('time_0').disabled);
assert.equal(elements.get('add').disabled, true);
assert.equal(vm.runInContext('collect().printers.length', context), 3);
assert.equal(vm.runInContext("Object.hasOwn(collect().printers[0], 'form_client_secret')", context), false);
// Translation is independent of form collection/rebuilding; language is the
// confirmed device value, never an unsaved dropdown in the full settings form.
elements.get('name_0').value='天气';
elements.get('secret_0').value='unsaved-fixture-secret';
vm.runInContext('cfg.language=1;uiEnglish=true;applyLanguage()',context);
assert.equal(vm.runInContext("t('任务名称')",context),'Task name');
assert.equal(vm.runInContext('collect().language',context),1);
assert.equal(elements.get('name_0').value,'天气');
assert.equal(elements.get('secret_0').value,'unsaved-fixture-secret');
assert.equal(vm.runInContext("printState('printing')",context),'Printing');
vm.runInContext('cfg.language=0;uiEnglish=false;applyLanguage()',context);
assert.equal(vm.runInContext("t('任务名称')",context),'任务名称');
assert.equal(vm.runInContext("printState('printing')",context),'打印中');
elements.get('secret_0').value='';
vm.runInContext('cfg.language=2',context);
assert.throws(()=>vm.runInContext('collect()',context),/Invalid language/);
vm.runInContext('cfg.language=0',context);
elements.get('serial_0').value = 'DIFFERENT';
assert.throws(() => vm.runInContext('collect()', context), /云端凭据/);
elements.get('secret_0').value = 'new-fixture-secret';
assert.equal(vm.runInContext('collect().printers[0].form_client_secret', context), 'new-fixture-secret');
elements.get('serial_0').value = 'FORM_1';
assert.throws(() => vm.runInContext('collect()', context), /重复/);
elements.get('serial_0').value = 'FORM_0';
elements.get('brightness').value = 101;
assert.throws(() => vm.runInContext('collect()', context), /输入范围/);
elements.get('brightness').value = 80;
vm.runInContext('cfg.printers.reverse(); fill(cfg)', context);
assert.equal(vm.runInContext('collect().printers[0].serial', context), 'FORM_2');
assert.equal(vm.runInContext("Object.hasOwn(collect().printers[0], 'form_client_secret')", context), false);
assert(page.includes('r.status===409') && page.includes("token=''"));
vm.runInContext('baseline.clock=false; baseline.weather=false; baseline.card_mask=0; baseline.printers.forEach(p=>{p.enabled=false;p.rotate=false;}); fill(structuredClone(baseline));collect()',context);
vm.runInContext('cfg.printers=cfg.printers.slice(0,1); fill(cfg)',context);
assert.throws(()=>vm.runInContext('collect()',context),/至少启用/);
vm.runInContext('baseline.clock=true;baseline.card_mask=1;baseline.printers.forEach(p=>{p.enabled=true;p.rotate=true;});fill(structuredClone(baseline))',context);
assert(!/localStorage|sessionStorage/.test(page));
assert.equal((page.match(/id="pageLanguage"/g)||[]).length,1);
assert(!page.includes('id="language"')&&page.includes('语言 / Language')&&page.includes('<svg'));
assert(!page.includes('id="demo"')&&page.includes('演示序列号'));
for(const code of [';;tex_1',';;tex_2',';;tex_3',';;tex_4']){
    elements.get('serial_0').value=code;elements.get('serial_0').oninput();
    assert(elements.get('client_0').disabled&&elements.get('secret_0').disabled);
    assert.equal(elements.get('client_0').value,'');assert.equal(elements.get('secret_0').value,'');
    const demo=vm.runInContext('collect().printers[0]',context);assert.equal(demo.serial,code);assert.equal(demo.form_client_id,'');assert(!Object.hasOwn(demo,'form_client_secret')&&!Object.hasOwn(demo,'form_credentials_set'));
}
for(const code of [';;tex_0',';;tex_5',';;tex_12',';;tex_1x',';;TEX_1']){elements.get('serial_0').value=code;assert.throws(()=>vm.runInContext('collect()',context),/序列号/);}
elements.get('serial_0').value='NEW_REAL';elements.get('serial_0').oninput();assert(!elements.get('client_0').disabled&&!elements.get('secret_0').disabled);
assert.throws(()=>vm.runInContext('collect()',context),/凭据/);
elements.get('client_0').value='account';elements.get('secret_0').value='fixture';assert.equal(vm.runInContext('collect().printers[0].form_client_secret',context),'fixture');
vm.runInContext('fill(structuredClone(baseline))',context);
const ids=new Set(Array.from(page.matchAll(/\bid="([^"]+)"/g),m=>m[1]));
for(const [,href] of page.matchAll(/href="([^"]+)"/g)){const url=new URL(href,'http://device/standalone');assert.equal(url.origin,'http://device');if(url.hash)assert(ids.has(url.hash.slice(1)),href);}
const wifi=readFileSync(new URL('../web/wifi.html',import.meta.url),'utf8');
for(const [,href] of wifi.matchAll(/href="([^"]+)"/g)){const url=new URL(href,'http://device/');assert.equal(url.origin,'http://device');if(url.hash)assert(ids.has(url.hash.slice(1)),href);}
console.log('Formlabs portal: HTTP SHA-256, 3 printers, redaction, identity retention, reorder, validation and CAS contract passed');
// Exercise the real page's response merge, not only the autosave scheduler.
context.setTimeout=()=>1;context.clearTimeout=()=>{};context.refreshPreview=()=>{};
context.document.querySelectorAll=()=>[];
vm.runInContext(page.slice(page.indexOf('async function request('),page.indexOf('async function health('))
    .replace('/* PORTAL_AUTOSAVE */',readFileSync(new URL('../web/autosave.js',import.meta.url),'utf8')),context);
let sendBody,resolveResponse,writes=0;
context.send=async(path,options)=>{writes++;sendBody=JSON.parse(options.body);return new Promise(r=>resolveResponse=r);};
vm.runInContext("request=send;token='fixture';fill(structuredClone(baseline));saved=structuredClone(baseline)",context);
elements.get('brightness').value='81';
vm.runInContext('markDirty()',context);const first=vm.runInContext('autosave.flush()',context);
await Promise.resolve();await Promise.resolve();assert.equal(writes,1);
elements.get('brightness').value='82';elements.get('name_0').value='New user name';elements.get('secret_0').value='new-draft-secret';
vm.runInContext('markDirty()',context);
resolveResponse({ok:true,json:async()=>({...baseline,brightness:81,revision:5})});await first;
assert.equal(elements.get('brightness').value,'82');assert.equal(elements.get('name_0').value,'New user name');assert.equal(elements.get('secret_0').value,'new-draft-secret');
assert.equal(vm.runInContext('cfg.revision',context),5);assert(vm.runInContext('dirty&&autosave.pending',context));
const second=vm.runInContext('autosave.flush()',context);await Promise.resolve();await Promise.resolve();assert.equal(writes,2);
assert.equal(sendBody.brightness,82);assert.equal(sendBody.revision,5);assert.equal(sendBody.printers[0].form_client_secret,'new-draft-secret');
resolveResponse({ok:true,json:async()=>({...sendBody,revision:6,printers:sendBody.printers.map(p=>{const {form_client_secret,...safe}=p;return {...safe,form_credentials_set:true};})})});await second;
const beforeWrites=writes;vm.runInContext('markDirty()',context);await vm.runInContext('autosave.flush()',context);assert.equal(writes,beforeWrites,'Unchanged form must not write flash');
console.log('Actual web autosave merge: in-flight edits/secrets retained, latest revision queued and no-op flash suppression passed');
// Run the actual switch handler against an unfinished, invalid form. No
// collect(), fill(), secret clearing or focus changes are allowed here.
context.health=()=>{};context.previewOptions=()=>{};
vm.runInContext(page.slice(page.indexOf('async function switchLanguage()'),page.indexOf('setupAppearance();')),context);
vm.runInContext('autosave.reset();saved=structuredClone(baseline);fill(structuredClone(baseline));lastSavedFingerprint=fingerprint(collect());',context);
const originalInput=elements.get('name_0'),originalSecret=elements.get('secret_0');
elements.get('name_0').value='My unsaved name';elements.get('secret_0').value='unfinished-secret';elements.get('serial_0').value='';elements.get('sleep_start').value='';
let languagePosts=0;
context.AbortController=AbortController;
context.fetch=async(path,options)=>{
    if(path==='/api/info')return {ok:true,json:async()=>({revision:4,language:0})};
    assert.equal(path,'/api/language');languagePosts++;const body=JSON.parse(options.body);assert.deepEqual(body,{revision:4,language:1});
    assert.equal(options.headers['X-XH-Language'],'1');return {ok:true,json:async()=>({revision:5,language:1})};
};
elements.get('pageLanguage').value='1';await elements.get('pageLanguage').onchange();
assert.equal(languagePosts,1);assert.equal(vm.runInContext('cfg.language',context),1);assert.equal(vm.runInContext('cfg.revision',context),5);
assert.equal(elements.get('name_0'),originalInput);assert.equal(elements.get('secret_0'),originalSecret);
assert.equal(originalInput.value,'My unsaved name');assert.equal(originalSecret.value,'unfinished-secret');assert.equal(elements.get('sleep_start').value,'');
assert(elements.get('languageStatus').textContent.includes('synced'));assert.equal(elements.get('languageRetry').hidden,true);
// A failed save is visible, retains the requested web language and does not
// pretend the screen changed. Retry can reconcile a lost/failed response.
context.fetch=async(path)=>path==='/api/info'?{ok:true,json:async()=>({revision:5,language:1})}:{ok:false,status:500};
elements.get('pageLanguage').value='0';await elements.get('pageLanguage').onchange();
assert.equal(vm.runInContext('cfg.language',context),1);assert.equal(elements.get('languageRetry').hidden,false);assert(elements.get('languageStatus').textContent.includes('尚未同步'));
context.fetch=async(path)=>path==='/api/info'?{ok:true,json:async()=>({revision:5,language:1})}:{ok:true,json:async()=>({revision:6,language:0})};
await elements.get('languageRetry').onclick();assert.equal(vm.runInContext('cfg.language',context),0);assert.equal(elements.get('languageRetry').hidden,true);
// External changes never promote an old draft to the new full-config revision.
context.fetch=async(path)=>path==='/api/info'?{ok:true,json:async()=>({revision:9,language:0})}:{ok:true,json:async()=>({revision:10,language:1})};
elements.get('pageLanguage').value='1';await elements.get('pageLanguage').onchange();
assert.equal(vm.runInContext('cfg.revision',context),6);assert(vm.runInContext('autosave.blocked',context));assert.equal(originalSecret.value,'unfinished-secret');
context.fetch=async(path)=>path==='/api/info'?{ok:true,json:async()=>({revision:10,language:1})}:{ok:false,status:409};
elements.get('pageLanguage').value='0';await elements.get('pageLanguage').onchange();assert.equal(elements.get('languageRetry').hidden,false);assert(vm.runInContext('autosave.blocked',context));
console.log('Actual language sync: one bilingual entry, independent narrow write, invalid drafts/input identity/secrets retained, success/failure/retry/CAS and stale full-save blocking passed');
