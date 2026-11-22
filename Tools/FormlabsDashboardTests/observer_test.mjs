// Local fixtures only: exercise the exact production injected script, no browser/account/network.
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import assert from 'node:assert/strict';
const source=readFileSync(process.argv[2], 'utf8');
const endpoint='https://api.formlabs.com/printernet/v1/my/printers/?detailed=True';
const fixture=[{serial:'OTHER',user:{email:'do-not-send'},printer_status:{status:'PRINTING'}},
  {serial:'FORM-FIXTURE',name:'Fixture',alias:'Workshop',user_facing_name:'Form 4',token:'do-not-send',group:{owner:'do-not-send'},
   printer_status:{status:'PRINTING',last_pinged_at:'2026-11-23T00:00:00Z',current_print_run:{
    id:42,guid:'job-guid-42',name:'Print fixture',currently_printing_layer:20,layer_count:100,user:'do-not-send',password:'do-not-send'}}}];
function harness(origin='https://dashboard.formlabs.com') {
 const messages=[]; let fetches=0, body=fixture, code=200, rejection=null;
 class XHR {
  constructor(){this.listeners={};this.responseType='';}
  open(method,url){this.method=method;this.url=url;}
  addEventListener(name,fn){this.listeners[name]=fn;}
  deliver(data=fixture,status=200){this.status=status;this.responseText=JSON.stringify(data);this.listeners.load?.call(this);}
 }
 const context={URL,XMLHttpRequest:XHR,location:{origin,href:origin+'/printers'},
  fetch: async function(...args){fetches++;if(rejection)throw rejection;return {status:code,clone:()=>({json:async()=>body}),marker:args}},
  webkit:{messageHandlers:{formlabsPrinter:{postMessage:m=>messages.push(m)}}}};
 context.window=context;context.top=context;
 runInNewContext(source,context);
 return {context,messages,XHR,get fetches(){return fetches;},respond(b,s=200){body=b;code=s;rejection=null;},fail(error){rejection=error;}};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
let h=harness();assert.equal(h.fetches,0,'injection never starts a request');
let returned=await h.context.fetch(endpoint);await flush();
assert.equal(h.fetches,1);assert.ok(returned.marker,'original response preserved');
assert.equal(h.messages.length,1);assert.equal(h.messages[0].printer.serial,'FORM-FIXTURE');
assert.equal(h.messages[0].printer.printer_status.current_print_run.layer_count,100);
assert.equal(h.messages[0].printer.printer_status.current_print_run.guid,'job-guid-42');
assert.equal(h.messages[0].printer.alias,'Workshop');assert.equal(h.messages[0].printer.user_facing_name,'Form 4');
assert.ok(!JSON.stringify(h.messages).includes('do-not-send'));
for(const url of ['https://evil.test/printernet/v1/my/printers/?detailed=True',
 'https://api.formlabs.com.evil.test/printernet/v1/my/printers/?detailed=True',
 'https://api.formlabs.com/developer/v1/printers/',
 'https://api.formlabs.com/printernet/v1/my/printers/?detailed=False']) await h.context.fetch(url);
await flush();assert.equal(h.messages.length,1,'only exact authorized list endpoint is observed');
h.respond(null,401);await h.context.fetch(endpoint);await flush();assert.equal(h.messages.at(-1).kind,'loginRequired');
h.respond([{serial:'OTHER'}]);await h.context.fetch(endpoint);await flush();assert.equal(h.messages.at(-1).kind,'printerNotFound');
h.respond({results:fixture});await h.context.fetch({url:endpoint});await flush();assert.equal(h.messages.at(-1).kind,'printer');
h.respond({token:'do-not-send'});await h.context.fetch(endpoint);await flush();assert.equal(h.messages.at(-1).kind,'invalidResponse');
let x=new h.XHR();x.open('GET',endpoint);x.deliver();assert.equal(h.messages.at(-1).kind,'printer');
x.open('GET','https://api.formlabs.com/printernet/v1/my/users/');const before=h.messages.length;x.deliver({password:'do-not-send'});assert.equal(h.messages.length,before);
x.open('GET',endpoint);x.deliver(null,403);assert.equal(h.messages.at(-1).kind,'loginRequired');
const offline=new Error('offline fixture');h.fail(offline);await assert.rejects(h.context.fetch(endpoint),e=>e===offline);assert.equal(h.messages.at(-1).kind,'requestFailed');
x.open('GET',endpoint);x.listeners.error.call(x);assert.equal(h.messages.at(-1).kind,'requestFailed');x.listeners.timeout.call(x);assert.equal(h.messages.at(-1).kind,'requestFailed');
let alien=harness('https://accounts.formlabs.com');await alien.context.fetch(endpoint);await flush();assert.equal(alien.messages.length,0);
assert.equal(alien.fetches,1);
assert.ok(!/document\.cookie|localStorage|sessionStorage|Authorization|getAllCookies|httpCookieStore/.test(source));
console.log('Dashboard observer: no autonomous request, exact origin/endpoint/serial, fetch+XHR semantics, account-field redaction, 401/403, missing printer, invalid response and non-Dashboard page isolation passed');
