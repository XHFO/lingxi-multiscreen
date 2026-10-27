/* SPDX-FileCopyrightText: 2026 mindreset
 * SPDX-License-Identifier: Apache-2.0
 * 用真实页面脚本与离线 DOM / API 检查管理流程。/ Exercise the real page script with an offline DOM and API.
 */
'use strict';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const managePath=process.argv[2];
if(!managePath)throw Error('Usage: node WebExitContract.mjs /path/to/manage.html');
const fs=require('node:fs'), vm=require('node:vm'), assert=require('node:assert/strict');
const html=fs.readFileSync(managePath,'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const KEY='0123456789abcdef0123456789abcdef', SESSION='abcdef0123456789abcdef0123456789';
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const clone=value=>JSON.parse(JSON.stringify(value));
function elements(root){return [root,...root.children.filter(n=>n instanceof Element).flatMap(elements)];}
class Element {
  constructor(tag='div'){this.tagName=tag.toUpperCase();this.children=[];this.attrs={};this.dataset={};this.parent=null;this._value=undefined;this.checked=false;this.disabled=false;this.hidden=false;this.files=[];}
  setAttribute(name,value){value=String(value);this.attrs[name]=value;if(name==='value')this._value=value;else if(name==='checked')this.checked=true;else if(name==='disabled')this.disabled=true;else if(name==='hidden')this.hidden=true;else if(name.startsWith('data-'))this.dataset[name.slice(5).replace(/-([a-z])/g,(_,letter)=>letter.toUpperCase())]=value;else this[name]=value;}
  getAttribute(name){return this.attrs[name]??null;}
  get value(){return this._value??(this.tagName==='SELECT'?this.children.find(n=>n.tagName==='OPTION')?.value:'')??'';}
  set value(value){this._value=String(value);}
  get textContent(){return this.children.map(n=>n instanceof Element?n.textContent:String(n)).join('');}
  set textContent(value){this.replaceChildren(String(value));}
  set innerHTML(_){throw Error('Untrusted content must not use innerHTML');}
  append(...nodes){for(const n of nodes){if(n instanceof Element)n.parent=this;this.children.push(n);}}
  replaceChildren(...nodes){for(const n of this.children)if(n instanceof Element)n.parent=null;this.children=[];if(this.tagName==='SELECT')this._value=undefined;this.append(...nodes);}
  replaceWith(node){const index=this.parent?.children.indexOf(this);assert(index>=0,'replaceWith requires attached node');this.parent.children[index]=node;node.parent=this.parent;this.parent=null;}
  querySelectorAll(selector){const names=selector.split(',').map(s=>s.trim().toUpperCase());return elements(this).slice(1).filter(n=>names.includes(n.tagName));}
  contains(other){return elements(this).includes(other);}
  focus(){if(this.ownerDocument){if(this.ownerDocument.activeElement)this.ownerDocument.activeElement.focused=false;this.ownerDocument.activeElement=this;}this.focused=true;}
  blur(){if(this.ownerDocument?.activeElement===this)this.ownerDocument.activeElement=null;this.focused=false;}
}
function parseDOM(){const root=new Element('document'),stack=[root];const voids=new Set(['META','INPUT','BR','HR','LINK','IMG']);for(const token of html.slice(0,html.indexOf('<script>')).matchAll(/<!--[\s\S]*?-->|<[^>]+>|[^<]+/g)){const text=token[0];if(text.startsWith('<!--')||text.startsWith('<!'))continue;if(text.startsWith('</')){const tag=text.slice(2,-1).trim().toUpperCase();while(stack.length>1){const node=stack.pop();if(node.tagName===tag)break;}}else if(text.startsWith('<')){const match=text.match(/^<([\w-]+)([\s\S]*?)\/?\s*>$/);if(!match)continue;const node=new Element(match[1]);for(const attr of match[2].matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s'"=<>`]+)))?/g))node.setAttribute(attr[1],attr[2]??attr[3]??attr[4]??'');stack.at(-1).append(node);if(!voids.has(node.tagName))stack.push(node);}else stack.at(-1).append(text);}const document={visibilityState:'visible',activeElement:null,getElementById:id=>elements(root).find(n=>n.id===id)||null,createElement:tag=>{const node=new Element(tag);node.ownerDocument=document;return node;}};for(const node of elements(root))node.ownerDocument=document;return {root,document};}
function homeFixture(){return {config:{enabled:true,local:'http://ha.local:8123',external:'',home_wifi:'Home',external_enabled:false,external_control:false,has_token:true,rooms:[]},status:{result:2,http_status:200,revision:10,busy:false},network_online:true,at_home:true,saved_wifi:['Home','Guest']};}
function printersFixture(){return {printers:[{slot:0,source:2,name:'LAN',serial:'serial-lan',host:'192.168.1.2',port:8883,has_secret:true,has_certificate:true,status:{result:2,has_data:true,percent:30,remaining_minutes:20,state:'打印中'}},{slot:1,source:3,name:'Cloud',serial:'serial-cloud',region:0,has_username:true,has_secret:true,status:{result:2}},{slot:2,source:4,name:'Form',serial:'serial-form',has_client_id:true,has_client_secret:true,status:{result:2}}],imports:[{name:'HA printer',serial:'sensor.printer'}]};}
function bambuFixture(){return {session:0,revision:0,phase:0,region:0,count:0,result:0,error:0,http_status:0,seconds_left:0,retry_after:0,devices:[],config_revision:1,saved_count:1,saved_accounts:[{slot:1,region:0,printer_count:1,name:'Cloud'}],reused:false};}
function entityFixture(){return {items:[{id:'light.desk',name:'台灯',state:'off',room:'书房',kind:0,available:true,on:false,number:null},{id:'climate.room',name:'空调',state:'off',room:'客厅',kind:2,available:true,on:false,number:26},{id:'sensor.temp',name:'温度',state:'23',room:'客厅',kind:4,available:true,on:false,number:23,unit:'°C'}],offset:0,limit:24,total:3,retained:3,total_supported:3,truncated:false,busy:false,revision:10,can_control:true,rooms:['客厅','书房','卧室']};}
async function setup({hash='#key='+KEY,search='',storage={},confirmations=[],home=homeFixture(),printers=printersFixture(),entities=entityFixture(),bambu=bambuFixture(),nativeHost=false,hook}={}){
 const {root,document}=parseDOM(),saved=new Map(Object.entries(storage));
 const test={listeners:new Map(),requests:[],timers:new Map(),nextTimer:1,replaced:[],confirmations:[],home,printers,entities,bambu,saved};
 const fetch=async(url,options={})=>{assert(url.startsWith('/api/manage/'),'same-origin device API only');test.requests.push({url,options,body:options.body===undefined?undefined:JSON.parse(options.body)});let override=hook?await hook(url,options,test):undefined;if(override==='network')throw Error('secret-not-for-ui');let status=override?.status??200,body=override?.body;
  if(!override){if(url==='/api/manage/home'){if(options.method==='PUT'){const payload=JSON.parse(options.body);Object.assign(home.config,payload);if(payload.ha_token)home.config.has_token=true;delete home.config.ha_token;if(payload.clear?.includes('ha_token'))home.config.has_token=false;body={ok:true,queued:true};}else body=home;}
  else if(url==='/api/manage/printers')body=printers;
  else if(url.startsWith('/api/manage/printers?')){const slot=Number(new URL(url,'http://device').searchParams.get('slot'));if(options.method==='DELETE')printers.printers=printers.printers.map(p=>p.slot===slot?{slot,source:0,name:'',serial:'',status:{result:0}}:p);if(options.method==='PUT'){const payload=JSON.parse(options.body),old=printers.printers.find(p=>p.slot===slot),same=old?.source===payload.source,p={...(same?old:{}),...payload,slot,status:{result:0}};for(const name of ['username','secret','client_id','client_secret','certificate']){if(p[name])p['has_'+name]=true;delete p[name];}printers.printers=printers.printers.filter(p=>p.slot!==slot);printers.printers.push(p);home.config.enabled=true;}body={ok:true,queued:true};}
  else if(url==='/api/manage/bambu/auth'){if(options.method==='POST'){const payload=JSON.parse(options.body);if(payload.session!==bambu.session){status=409;body={error:'stale_session'};}else if(payload.action==='import'){const item=bambu.devices[payload.index];assert(item,'selected bound device exists');printers.printers=printers.printers.filter(p=>p.slot!==payload.slot);printers.printers.push({slot:payload.slot,source:3,name:payload.name||item.name,serial:item.serial,region:bambu.region,has_username:true,has_secret:true,status:{result:0}});home.config.enabled=true;const peers=printers.printers.filter(p=>p.source===3&&p.region===bambu.region);bambu.saved_accounts=[{slot:peers[0].slot,region:bambu.region,printer_count:peers.length,name:peers[0].name}];bambu.saved_count=1;bambu.config_revision++;body={ok:true,queued:true};}else if(payload.action==='cancel'){Object.assign(bambu,{session:bambu.session+1,phase:0,devices:[],count:0});}else if(payload.action==='login'){Object.assign(bambu,{session:bambu.session+1,phase:1,region:payload.region,revision:bambu.revision+1,seconds_left:300});}else if(payload.action==='reuse'){assert.equal(payload.config_revision,bambu.config_revision);const saved=bambu.saved_accounts.find(p=>p.slot===payload.saved_slot);assert(saved);Object.assign(bambu,{session:bambu.session+1,phase:1,region:saved.region,revision:bambu.revision+1,seconds_left:300,reused:true});}else if(payload.action==='email_code'||payload.action==='resend'){Object.assign(bambu,{phase:1,revision:bambu.revision+1});}else throw Error('unhandled Bambu action '+payload.action);}if(!body)body=bambu;}
  else if(url.startsWith('/api/manage/ha/entities?'))body=entities;
  else if(url==='/api/manage/refresh'||url==='/api/manage/ha/control'){body={ok:true,queued:true};status=202;}
  else throw Error('unhandled fixture '+url);}
  return {ok:status>=200&&status<300,status,json:async()=>{if(override?.invalidJSON)throw Error('json secret');return clone(body);}};
 };
 const context=vm.createContext({document,location:{hash,search,pathname:'/manage'},history:{replaceState:(...args)=>test.replaced.push(args[2])},sessionStorage:{getItem:key=>saved.get(key),setItem:(key,value)=>saved.set(key,value),removeItem:key=>saved.delete(key)},fetch,URL,URLSearchParams,TextEncoder,AbortController,setTimeout:(f,ms)=>{const id=test.nextTimer++;test.timers.set(id,{f,ms});return id;},clearTimeout:id=>test.timers.delete(id),confirm:message=>{test.confirmations.push(message);return confirmations.length?confirmations.shift():true;}});
 context.window=context;
 context.addEventListener=(type,listener)=>{if(!test.listeners.has(type))test.listeners.set(type,[]);test.listeners.get(type).push(listener);};
 if(nativeHost)Object.defineProperty(context,'__readPicoNativeDepartureGuard',{value:true,writable:false,configurable:false});
 test.unload=()=>{const event={defaultPrevented:false,returnValue:undefined,preventDefault(){this.defaultPrevented=true;}};for(const listener of test.listeners.get('beforeunload')||[])listener(event);return event;};
 vm.runInContext(script,context);await flush();await flush();
 const run=(code,values={})=>{Object.assign(context,values);return vm.runInContext(code,context);};
 const node=id=>{const value=document.getElementById(id);assert(value,'node '+id+' exists');return value;};
 const all=(id,tag)=>node(id).querySelectorAll(tag);
 return {test,context,run,node,all,root};
}



// Read the current production query, rather than duplicating its expression in the test.
const native=fs.readFileSync(new URL('../../Sources/LinxDisplayApp/ReadPicoManagementWebView.swift',import.meta.url),'utf8');
const query=native.match(/static let departureQuery = """([\s\S]*?)"""/)[1];
(async()=>{
 let checks=0;const inspect=t=>JSON.parse(JSON.stringify(t.run(query)));
 const check=(condition,label)=>{assert(condition,label);checks++;console.log('PASS '+label)};
 let t=await setup();check(JSON.stringify(inspect(t))===JSON.stringify({dirty:false,working:false}),'real page initializes clean');
 t.node('haToken').value='LOCAL-PRIVATE-TOKEN-ONLY';t.node('haToken').oninput();check(inspect(t).dirty,'HA token edits mark dirty');check(!JSON.stringify(inspect(t)).includes('PRIVATE'),'query returns no HA credentials');
 t.node('haLocal').value='http://changed.local:8123';await t.run('saveHome()');check(!inspect(t).dirty,'confirmed HA save clears close protection');
 t=await setup({hook:(url,opt)=>url==='/api/manage/home'&&opt.method==='PUT'?'network':undefined});t.node('haLocal').value='http://draft.local:8123';t.node('haLocal').oninput();await t.run('saveHome()');check(inspect(t).dirty,'failed HA save retains protection');
 for(const id of ['p-0-secret','p-2-client_secret']){t=await setup();t.node(id).value='LOCAL-PRIVATE-SECRET-ONLY';t.node(id).oninput();check(inspect(t).dirty,id+' edits mark dirty');check(!JSON.stringify(inspect(t)).includes('PRIVATE'),id+' query omits credentials');}
 t=await setup({bambu:{...bambuFixture(),session:7,phase:2}});check(!inspect(t).dirty&&inspect(t).working,'code challenge is protected even with no dirty inputs');t.node('b-code').value='987654';t.node('b-code').oninput();check(inspect(t).dirty,'verification input marks dirty');check(!JSON.stringify(inspect(t)).includes('987654'),'verification code is never returned');
 t.run('dropBambu()');check(t.node('b-code').value==='','explicit cancel clears verification code');check(inspect(t).dirty,'Bambu cancel conservatively retains touched-account dirty flag');
 t=await setup({bambu:{...bambuFixture(),session:7,phase:4,devices:[],count:0}});check(!inspect(t).dirty&&!inspect(t).working,'completed cloud auth alone does not force prompts');
 t.run('state.pending.add("light.desk")');check(inspect(t).working,'pending entity control prevents silent close');
 let release; t=await setup({hook:(url,opt)=>url==='/api/manage/bambu/auth'&&opt.method==='POST'&&JSON.parse(opt.body).action==='reuse'?new Promise(resolve=>release=resolve):undefined});const action=t.run('bambuAction(null,"reuse")');await flush();check(t.run('state.working')===false,'real Bambu reuse does not set global working');check(inspect(t).working,'query still detects Bambu reuse request');release({status:202,body:{...bambuFixture(),session:8,phase:1}});await action;check(inspect(t).working,'cloud calculation phase remains protected');
 t=await setup();check(t.run('typeof window.readPicoManagementDepartureState')==='function','page exposes the stable read-only departure function');
 check(t.run("Object.getOwnPropertyDescriptor(window,'readPicoManagementDepartureState').writable")===false,'public function cannot be accidentally replaced');
 check(JSON.stringify(inspect(t))===JSON.stringify(t.run('window.readPicoManagementDepartureState()')),'native query agrees with the public page contract');
 check((t.test.listeners.get('beforeunload')||[]).length===1,'page registers one browser unload handler');
 check(!t.test.unload().defaultPrevented,'external clean page does not block unload');
 t.node('haToken').value='LOCAL-PRIVATE-TOKEN-ONLY';t.node('haToken').oninput();let requests=t.test.requests.length,confirmations=t.test.confirmations.length;
 let event=t.test.unload();check(event.defaultPrevented&&event.returnValue==='','external dirty page requests the browser default unload prompt');
 check(t.test.requests.length===requests&&t.test.confirmations.length===confirmations,'unload neither mutates the device nor opens a custom confirm');
 check(inspect(t).dirty&&t.node('haToken').value==='LOCAL-PRIVATE-TOKEN-ONLY','unload does not clear the draft or secret input');
 t=await setup({bambu:{...bambuFixture(),session:7,phase:2}});check(t.test.unload().defaultPrevented,'external unfinished Bambu verification requests unload protection');
 t=await setup({nativeHost:true});t.node('haToken').value='LOCAL-PRIVATE-TOKEN-ONLY';t.node('haToken').oninput();event=t.test.unload();
 check(!event.defaultPrevented&&event.returnValue===undefined,'embedded page delegates unload prompting to the native gate');
 check(inspect(t).dirty,'host marker does not authorize departure or hide drafts from the native query');
 t=await setup();t.run('state.temperatureDrafts.set("climate.room","25.5")');check(inspect(t).dirty&&t.test.unload().defaultPrevented,'temperature draft uses the public contract rather than the old dirty Set');
 t.run('state.temperatureDrafts.clear()');check(!inspect(t).dirty,'cleared temperature draft no longer blocks departure');
 console.log(JSON.stringify({checks,passed:true},null,2));
})().catch(error=>{console.error(error);process.exitCode=1});
