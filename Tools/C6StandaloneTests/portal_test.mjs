import {readFileSync} from 'node:fs';
import {strict as assert} from 'node:assert';
import vm from 'node:vm';
const root = new URL('../WaveshareC6Firmware/', import.meta.url);
const decode = name => [...readFileSync(new URL('src/'+name+'_portal.h', root),'utf8').matchAll(/^"(?:[^"\\]|\\.)*"/gm)].map(m=>JSON.parse(m[0])).join('');
const html=decode('standalone'),wifiHTML=decode('wifi');
for(const source of [html,wifiHTML]){
    assert.match(source,/lang="zh-CN"/);assert.match(source,/role="status"/);assert.match(source,/aria-live="polite"/);
    assert.match(source,/prefers-color-scheme:dark/);assert.match(source,/focus-visible/);assert.match(source,/min-height:44px/);
    assert.ok(!source.includes('localStorage')&&!source.includes('sessionStorage')&&!source.includes('innerHTML'));
    new vm.Script(source.match(/<script>([\s\S]*)<\/script>/)[1]);
}
assert.match(html,/<fieldset id="options"[^>]*disabled/);assert.ok(html.indexOf('高级 · 查看配置 JSON')<html.indexOf('</fieldset>'));
const script=html.match(/<script>([\s\S]*)<\/script>/)[1],ids=new Map();
class Element {
    constructor(tag='div',id='',type='text'){Object.assign(this,{tag,id,type,value:'',checked:false,disabled:false,hidden:false,textContent:'',children:[],dataset:{},attributes:{},className:''});this.classList={add:()=>{},toggle:()=>{}};}
    append(...children){for(const c of children){this.children.push(c);const walk=e=>{if(e.id)ids.set(e.id,e);for(const child of e.children||[])walk(child);};walk(c);}}
    replaceChildren(...children){const remove=e=>{if(e.id)ids.delete(e.id);for(const c of e.children||[])remove(c);};for(const c of this.children)remove(c);this.children=[];this.append(...children);}
    setAttribute(name,value){this.attributes[name]=value;}removeAttribute(name){delete this.attributes[name];}focus(){this.focused=true;document.activeElement=this;}
    querySelectorAll(){return this.children.filter(c=>c.tag==='button');}
    addEventListener(name,callback){this['on'+name]=callback;}
}
for(const match of html.matchAll(/<([a-z]+)\b[^>]*\bid="([^"]+)"[^>]*>/g)){const type=match[0].match(/type="([^"]+)"/)?.[1]||'text';ids.set(match[2],new Element(match[1],match[2],type));}
ids.get('options').disabled=true;
const checkbox=id=>ids.get(id).checked,value=(id,v)=>ids.get(id).value=String(v),click=id=>ids.get(id).onclick();
let responseStatus=200,pairingStatus=200,putGate=null;const requests=[],events={};
const original={schema_version:2,revision:3,enabled:true,local_first:false,clock:true,flip_animation:true,diagnostics:false,rotation:180,brightness:80,interval:15,timezone:28800,weather:true,latitude:31.23,longitude:121.47,weather_city:'测试城市',weather_minutes:30,
    ha:{enabled:true,host:'192.168.1.10',port:8123,tls:false,token_set:true,entities:[{id:'sensor.room_temperature',name:'客厅温度'}]},
    printers:[{enabled:true,serial:'sample',name:'测试打印机',source_ha:true,host:'',trust_lan:false,certificate:'',status_entity:'sensor.sample_print_status',progress_entity:'sensor.sample_print_progress',task_entity:'',remaining_entity:'',image_entity:'image.sample_cover',show_image:true,show_status:true,show_progress:true,show_task:false,show_remaining:true,access_code_set:false}]};
let config=structuredClone(original);
const document={activeElement:null,getElementById:id=>ids.get(id),createElement:tag=>new Element(tag),querySelector:()=>null,querySelectorAll:selector=>selector==='[data-secret]'?[...ids.values()].filter(e=>e.dataset.secret):selector==='[aria-invalid]'?[...ids.values()].filter(e=>e.attributes['aria-invalid']):selector.startsWith('#options')?[...ids.values()].filter(e=>['input','select','textarea'].includes(e.tag)&&e.id!=='pin'):[]};
const context=vm.createContext({TextEncoder,AbortController,URLSearchParams,Uint8Array,Uint8ClampedArray,setTimeout,clearTimeout,setInterval:()=>0,console,confirm:()=>true,window:{addEventListener:(n,f)=>{const before=events[n];events[n]=before?e=>{before(e);f(e);}:f;}},document,
    fetch:async(url,options)=>{if(url.startsWith('/api/frame'))return{ok:false,status:503};if(url==='/api/health')return{ok:true,status:200,json:async()=>({printers:[]})};const request={url,...options};requests.push(request);if(url==='/api/info')return{ok:true,status:200,json:async()=>({fw:'2.0.0-alpha.18',ip:'192.168.1.24',language:config.language||0,revision:config.revision})};if(url==='/api/pair')return{ok:pairingStatus===200,status:pairingStatus,json:async()=>({token:'1234abcd1234abcd'})};
        let status=responseStatus;
        if(url==='/api/standalone'&&options?.method==='PUT'){
            if(putGate)await putGate;
            const body=JSON.parse(options.body),previous=config;
            if(status===200&&body.revision!==previous.revision)status=409;
            if(status===200){
                config=structuredClone(body);config.revision++;
                config.ha.token_set=!!body.ha.token||!!(previous.ha.token_set&&previous.ha.host===body.ha.host&&previous.ha.port===body.ha.port&&previous.ha.tls===body.ha.tls);delete config.ha.token;
                for(const p of config.printers){
                    const old=previous.printers.find(o=>o.source_formlabs===p.source_formlabs&&o.serial===p.serial);
                    p.access_code_set=!p.source_ha&&!p.source_formlabs&&(!!p.access_code||!!(old?.access_code_set&&old.host===p.host));
                    p.form_credentials_set=!!p.source_formlabs&&(!!p.form_client_secret||!!(old?.form_credentials_set&&old.form_client_id===p.form_client_id));
                    delete p.access_code;delete p.form_client_secret;
                }
            }
        }
        return{ok:status===200,status,json:async()=>structuredClone(config)};}});
const restore=async()=>{config=structuredClone(original);await click('reload');};
vm.runInContext(script,context);await new Promise(r=>setImmediate(r));await new Promise(r=>setImmediate(r));
context.previewConfig=structuredClone(config);context.previewConfig.ha.entities=Array.from({length:4},(_,i)=>({id:'sensor.fixture_'+i,name:'Fixture '+i}));vm.runInContext('previewOptions(previewConfig)',context);assert.equal(ids.get('previewCard').children.filter(o=>o.value.startsWith('ha:')).length,1);
context.previewConfig.ha.entities.push({id:'sensor.fixture_4',name:'Fixture 4'});vm.runInContext('previewOptions(previewConfig)',context);assert.equal(ids.get('previewCard').children.filter(o=>o.value.startsWith('ha:')).length,2);context.previewConfig=config;vm.runInContext('previewOptions(previewConfig)',context);
assert.equal(Number(ids.get('clock_style').value),0);
// The real save response updates saved state without replacing dynamic inputs.
const retainedPrinterSource=ids.get('p_source_0'),retainedEntityName=ids.get('entity_name_0');
let releasePut;putGate=new Promise(resolve=>{releasePut=resolve;});
value('weather_city','background-focus-fixture');ids.get('weather_city').focus();vm.runInContext('markDirty()',context);
const backgroundSave=vm.runInContext('autosave.flush()',context);await new Promise(r=>setImmediate(r));ids.get('clock_style').focus();releasePut();await backgroundSave;putGate=null;
assert.equal(document.activeElement,ids.get('clock_style'),'background PUT never restores the old focus');assert.equal(ids.get('p_source_0'),retainedPrinterSource,'background PUT retains dynamic select identity');assert.equal(ids.get('entity_name_0'),retainedEntityName,'background PUT retains entity input identity');assert.equal(config.weather_city,'background-focus-fixture');await restore();
config.ha.token_set=false;await click('reload');ids.get('clock_style').focus();value('clock_style',1);vm.runInContext('markDirty()',context);const incompleteHACount=requests.length;await vm.runInContext('autosave.flush()',context);
assert.equal(requests.length,incompleteHACount);assert.equal(document.activeElement,ids.get('clock_style'),'automatic HA validation never pulls focus to Token');assert.equal(Number(ids.get('clock_style').value),1);await restore();
value('clock_style',1);await click('save');assert.equal(JSON.parse(requests.at(-1).body).clock_style,1);
assert.equal(config.clock_style,1);assert.equal(Number(ids.get('clock_style').value),1,'a successful PUT retains the submitted clock style');
value('clock_style',2);const beforeInvalidClock=requests.length;await click('save');assert.equal(requests.length,beforeInvalidClock);await restore();
value('digit_style',1);value('rotation',270);value('sleep_mode',2);value('sleep_idle_minutes',10);value('sleep_start','22:30');value('sleep_end','06:45');ids.get('sleep_keep_printing').checked=false;value('p_card_style_0',2);await click('save');let merged=JSON.parse(requests.at(-1).body);
assert.equal(merged.digit_style,1);assert.equal(merged.rotation,270);assert.equal(merged.sleep_mode,2);assert.equal(merged.sleep_start,1350);assert.equal(merged.sleep_end,405);assert.equal(merged.sleep_idle_minutes,10);assert.equal(merged.sleep_keep_printing,false);assert.equal(merged.printers[0].card_style,2);assert.equal(merged.printers[0].show_image,true);
value('sleep_mode',2);value('sleep_start','07:00');value('sleep_end','07:00');const beforeInvalidSleep=requests.length;await click('save');assert.equal(requests.length,beforeInvalidSleep);assert.match(ids.get('status').textContent,/不能相同/);await restore();
value('p_card_style_0',3);const beforeInvalidStyle=requests.length;await click('save');assert.equal(requests.length,beforeInvalidStyle);await click('reload');
assert.equal(requests.find(r=>r.url==='/api/pair').headers['X-Lingxi-LAN'],'1');assert.equal(JSON.parse(requests.find(r=>r.url==='/api/pair').body).mode,'lan');assert.equal(requests.at(-1).headers.Authorization,'Bearer 1234abcd1234abcd');assert.equal(ids.get('options').disabled,false);assert.equal(ids.get('pairPrompt').hidden,true);assert.equal(ids.get('ha_token').value,'');assert.equal(checkbox('flip_animation'),true);assert.ok(!html.includes('id="pin"'));
const beforeColorRevision=config.revision;value('ha_token','fake-test-token');value('weather_minutes',60);value('saturation_percent',150);value('contrast_percent',115);ids.get('flip_animation').checked=false;await click('save');let sent=JSON.parse(requests.at(-1).body);
assert.equal(sent.weather_minutes,60);assert.equal(sent.flip_animation,false);assert.equal(sent.ha.token,'fake-test-token');assert.equal(sent.revision,beforeColorRevision);assert.equal(sent.printers[0].show_task,false);assert.equal(sent.printers[0].image_entity,'image.sample_cover');assert.equal(ids.get('ha_token').value,'');assert.ok(!ids.get('json').textContent.includes('fake-test-token'));
    assert.equal(sent.saturation_percent,150);assert.equal(sent.contrast_percent,115);assert.equal(Number(ids.get('saturation_percent').value),150);assert.equal(Number(ids.get('contrast_percent').value),115);
await click('saveBottom');sent=JSON.parse(requests.at(-1).body);assert.equal(sent.ha.token,undefined);assert.equal(sent.printers[0].access_code,undefined);await restore();
value('latitude','');value('longitude','');await click('addEntity');assert.equal(ids.get('latitude').value,'');assert.equal(ids.get('longitude').value,'');await click('reload');
await click('addPrinter');value('p_source_1','mqtt');ids.get('p_source_1').onchange();value('p_code_1','draft-code');value('p_source_1','ha');ids.get('p_source_1').onchange();await click('addEntity');value('p_source_1','mqtt');assert.equal(ids.get('p_code_1').value,'');await click('reload');
ids.get('theme_enabled').checked=true;value('theme_accent','#123456');ids.get('p_show_nozzle_0').checked=true;value('p_nozzle_entity_0','sensor.sample_nozzle');value('p_time_mode_0',1);ids.get('p_brand_accent_0').checked=false;await click('save');sent=JSON.parse(requests.at(-1).body);assert.equal(sent.theme.accent,0x123456);assert.equal(sent.theme.enabled,true);assert.equal(sent.printers[0].show_nozzle,true);assert.equal(sent.printers[0].time_mode,1);assert.equal(sent.printers[0].brand_accent,false);
const count=requests.length;value('ha_host','8.8.8.8');await click('save');assert.equal(requests.length,count);assert.match(ids.get('status').textContent,/局域网/);value('ha_host','192.168.1.11');await click('addEntity');value('entity_id_1','sensor.second');await click('save');assert.equal(requests.length,count);assert.match(ids.get('status').textContent,/长期访问令牌/);await click('reload');
value('p_image_entity_0','camera.printer');await click('save');sent=JSON.parse(requests.at(-1).body);assert.equal(sent.printers[0].image_entity,'camera.printer');await click('reload');
value('p_image_entity_0','camera.printer/stream');await click('save');assert.match(ids.get('status').textContent,/camera\.\*/);await click('reload');
ids.get('p_live_image_0').checked=true;await click('save');sent=JSON.parse(requests.at(-1).body);assert.equal(sent.printers[0].live_image,true);await click('reload');
await click('addFormPrinter');assert.equal(ids.get('p_source_1').value,'formlabs');assert.equal(ids.get('p_form_1').hidden,false);assert.equal(ids.get('p_ha_1').hidden,true);assert.equal(ids.get('p_mqtt_1').hidden,true);
ids.get('clock_style').focus();vm.runInContext('markDirty()',context);const incompleteFormCount=requests.length;await vm.runInContext('autosave.flush()',context);assert.equal(requests.length,incompleteFormCount);assert.equal(document.activeElement,ids.get('clock_style'),'automatic Formlabs validation never pulls focus from clock options');
value('p_name_1','工作室 Form 4');value('p_form_serial_1','Form-123');value('p_form_id_1','fixture-client');value('p_form_secret_1','fixture-form-secret');
await click('addEntity');assert.equal(ids.get('p_form_secret_1').value,'fixture-form-secret');value('entity_id_1','sensor.second');
await click('save');sent=JSON.parse(requests.at(-1).body);
assert.equal(sent.printers[1].source_formlabs,true);assert.equal(sent.printers[1].source_ha,false);assert.equal(sent.printers[1].serial,'Form-123');assert.equal(sent.printers[1].form_client_id,'fixture-client');assert.equal(sent.printers[1].form_client_secret,'fixture-form-secret');assert.equal(sent.printers[1].show_layers,true);assert.equal(sent.printers[1].show_material,true);assert.equal(config.printers[1].form_credentials_set,true);assert.equal(ids.get('p_form_secret_1').value,'');assert.ok(!ids.get('json').textContent.includes('fixture-form-secret'));
assert.equal(ids.get('p_brandlabel_1').textContent,'Formlabs · 工作室 Form 4','save acknowledgement updates the printer heading in place');assert.match(ids.get('p_form_secret_1_help').textContent,/同一打印机与 Client ID 留空保留/,'save acknowledgement shows the newly retained Secret state');
const beforeRetainedSecret=requests.length;value('p_form_id_1','another-client');ids.get('clock_style').focus();vm.runInContext('markDirty()',context);await vm.runInContext('autosave.flush()',context);assert.equal(requests.length,beforeRetainedSecret,'a changed Client ID cannot reuse another credential identity');assert.match(ids.get('status').textContent,/Client Secret/);assert.equal(document.activeElement,ids.get('clock_style'));await restore();
await click('addPrinter');value('p_source_1','formlabs');ids.get('p_source_1').onchange();
assert.match(ids.get('p_brandlabel_1').textContent,/Formlabs/);
value('p_form_serial_1','sample');value('p_form_id_1','fixture-client');value('p_form_secret_1','isolated-secret');value('p_code_1','stale-bambu-secret');
await click('save');sent=JSON.parse(requests.at(-1).body);assert.equal(sent.printers[0].brand,'bambu');assert.equal(sent.printers[1].brand,'formlabs');assert.equal(sent.printers[1].serial,sent.printers[0].serial);assert.equal(sent.printers[1].access_code,undefined);assert.equal(sent.printers[1].status_entity,'');await restore();
value('ha_token','pending-secret');await click('addEntity');assert.equal(ids.get('ha_token').value,'pending-secret');value('entity_id_1','sensor.room_temperature');await click('save');assert.match(ids.get('status').textContent,/重复/);await click('reload');
for(let i=1;i<6;i++)await click('addEntity');assert.equal(ids.get('addEntity').disabled,true);await click('reload');
await click('addFormPrinter');await click('addPrinter');assert.equal(ids.get('addPrinter').disabled,true);assert.equal(ids.get('addFormPrinter').disabled,true);const fullPrinterCount=vm.runInContext('cfg.printers.length',context);await click('addFormPrinter');assert.equal(vm.runInContext('cfg.printers.length',context),fullPrinterCount);await restore();
responseStatus=500;await click('save');assert.match(ids.get('status').textContent,/500.*原配置保留/);assert.equal(ids.get('options').disabled,false);
responseStatus=409;await click('save');assert.match(ids.get('status').textContent,/重新读取/);assert.equal(ids.get('options').disabled,false);assert.equal(requests.filter(r=>r.url==='/api/pair').length,1);
responseStatus=401;await click('reload');assert.equal(ids.get('options').disabled,true);assert.match(ids.get('status').textContent,/连接已失效/);assert.equal(ids.get('ha_token').value,'');
pairingStatus=403;await click('read');assert.match(ids.get('status').textContent,/同一 Wi-Fi/);assert.equal(ids.get('options').disabled,true);
pairingStatus=200;responseStatus=200;await click('read');value('ha_token','must-clear');events.pagehide();assert.equal(vm.runInContext('authToken',context),'');assert.equal(ids.get('ha_token').value,'');
assert.equal(ids.get('options').disabled,true);events.pageshow({persisted:true});assert.equal(ids.get('options').disabled,true);
assert.equal(vm.runInContext('previewAlive',context),true);assert.equal(vm.runInContext('authToken',context),'');events.pagehide();assert.equal(vm.runInContext('previewAlive',context),false);
console.log('C6 portal: real PUT state, stable form nodes/focus, non-stealing automatic validation, direct Formlabs cloud forms, LAN免PIN/CAS/credential isolation, add limits and no browser persistence passed');
