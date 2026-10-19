import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const page=readFileSync(new URL('../web/wifi.html',import.meta.url),'utf8');
const elements=new Map(),timers=new Map(),calls=[],listeners={};let timer=0,data={ip:'0.0.0.0',fw:'fixture',language:0,revision:0,wifi_connected:false},languageFailure=0;
for(const [,id] of page.matchAll(/\bid="([^"]+)"/g))elements.set(id,{value:'',textContent:'',dataset:{},hidden:id==='handoff',disabled:false});
const link={href:'/standalone#printers',getAttribute(){return '/standalone#printers';}};
const context=vm.createContext({TextEncoder,URLSearchParams,AbortSignal,AbortController,Map,Array,Promise,navigator:{language:'zh-CN'},
 document:{getElementById:id=>elements.get(id),querySelectorAll:()=>[link]},
 window:{addEventListener:(name,cb)=>listeners[name]=cb},
 setTimeout:cb=>{timers.set(++timer,cb);return timer;},clearTimeout:id=>timers.delete(id),
 fetch:async(path,options)=>{calls.push({path,options});if(path==='/api/language'){if(languageFailure)return {ok:false,status:languageFailure};const body=JSON.parse(options.body);assert.equal(body.revision,data.revision);if(body.language!==data.language)data.revision++;data.language=body.language;}return {ok:true,json:async()=>({...data})};}
});
const script=page.match(/<script>([\s\S]*?)<\/script>/)[1].replace('/* PORTAL_I18N */',readFileSync(new URL('../web/i18n.js',import.meta.url),'utf8'));
vm.runInContext(script,context);await new Promise(setImmediate);
assert.equal(elements.get('handoff').hidden,true);assert.equal(elements.get('pageLanguage').value,0);
elements.get('ssid').value='draft-network';elements.get('password').value='draft-password';
elements.get('pageLanguage').value='1';const sync=elements.get('pageLanguage').onchange();
assert(elements.get('identity').textContent.startsWith('Waiting for network'),'Dynamic connection state switches language immediately without another request');
await sync;assert.equal(data.language,1);assert(elements.get('languageStatus').textContent.includes('synced'));
assert.equal(elements.get('ssid').value,'draft-network');assert.equal(elements.get('password').value,'draft-password');
await vm.runInContext('info()',context);assert.equal(elements.get('pageLanguage').value,'1','Polling never overrides an explicit language choice');
elements.get('ssid').value='fixture-wifi';elements.get('password').value='fixture-password';
await elements.get('wifiForm').onsubmit({preventDefault(){}});
const post=calls.find(c=>c.path==='/wifi');assert.equal(post.options.headers['X-XH-WiFi'],'1');assert.equal(elements.get('password').value,'');
assert(elements.get('status').textContent.includes('Waiting for a LAN IP'));assert.equal(elements.get('handoff').hidden,true);
data={...data,ip:'192.168.8.42',wifi_connected:true};await vm.runInContext('waitForConnection()',context);
assert.equal(elements.get('handoff').hidden,false);assert.equal(link.href,'http://192.168.8.42/standalone#printers');
assert.equal(elements.get('lanAddress').textContent,'http://192.168.8.42/standalone');assert.equal(timers.size,0);
data.ip='10.0.2.50';await vm.runInContext('info()',context);assert.equal(link.href,'http://10.0.2.50/standalone#printers','Later IP changes do not append to an old absolute URL');
for(const ip of ['0.0.0.0','192.168.1.999','8.8.8.8','192.168.1.4/evil','172.32.0.1']){context.testIP=ip;assert.equal(vm.runInContext('privateIP(testIP)',context),false);}
languageFailure=500;elements.get('pageLanguage').value='0';await elements.get('pageLanguage').onchange();
assert.equal(data.language,1);assert.equal(elements.get('languageRetry').hidden,false);assert(elements.get('languageStatus').textContent.includes('尚未同步'));
languageFailure=0;await elements.get('languageRetry').onclick();assert.equal(data.language,0);assert.equal(elements.get('languageRetry').hidden,true);
// Continue the Wi-Fi handoff in English, as before.
elements.get('pageLanguage').value='1';await elements.get('pageLanguage').onchange();
// Saved is not connected; wrong-password/timeout remains retryable.
data={...data,ip:'0.0.0.0',wifi_connected:false};elements.get('password').value='fixture-password';
await elements.get('wifiForm').onsubmit({preventDefault(){}});await vm.runInContext('waitForConnection(59)',context);
assert.equal(elements.get('handoff').hidden,true);assert.equal(elements.get('connect').disabled,false);assert(elements.get('status').textContent.includes('Connection not confirmed'));
listeners.pagehide();assert.equal(timers.size,0);assert.equal(elements.get('password').value,'');
assert(!/localStorage|sessionStorage/.test(page));
const standalone=readFileSync(new URL('../web/standalone.html',import.meta.url),'utf8');
assert(standalone.includes('id="pageLanguage"')&&!standalone.includes('id="firstRun"')&&!standalone.includes('function onboarding'));
assert(!page.includes('<ol>')&&standalone.includes('Open-Meteo'));
let pairs=0,probes=0;const auth=vm.createContext({location:{hostname:'192.168.8.42'},token:'',portalAlive:true,t:x=>x,status(){},setTimeout:cb=>{cb();return 1;},
request:async path=>path==='/api/pair'?{ok:++pairs>1,status:pairs===1?403:200,json:async()=>({token:'abcdef0123456789'})}:{json:async()=>({wifi_connected:true,setup_ap:++probes<3,ip:'192.168.8.42'})}});
vm.runInContext(standalone.slice(standalone.indexOf('async function authorize()'),standalone.indexOf('function clearSecrets()')),auth);
await vm.runInContext('authorize()',auth);assert.equal(pairs,2);assert.equal(probes,3);assert.equal(vm.runInContext('token',auth),'abcdef0123456789');
auth.token='';auth.location.hostname='192.168.4.1';pairs=0;probes=0;
await assert.rejects(()=>vm.runInContext('authorize()',auth));assert.equal(pairs,1,'An AP browser must not obtain LAN authorization through the handoff retry');
console.log('First-run portal: explicit bilingual choice, same-origin header, saved-vs-connected, real LAN IP handoff/update, retry, cancellation and no browser password persistence passed');
