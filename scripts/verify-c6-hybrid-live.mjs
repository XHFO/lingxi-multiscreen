// Explicit opt-in real LAN device check. No configuration writes or credential logs.
// Historical alpha.16 / native API v1 probe; use current host tests for API v2.
// Run with the test app quit so its carousel does not compete with this probe.
import http from 'node:http';
import assert from 'node:assert/strict';
const host=process.argv[2];assert(/^192\.168\.\d+\.\d+$/.test(host),'Pass the known C6 LAN address');
function request(path,method='GET',body,headers={}) {
 return new Promise((resolve,reject)=>{
  const bytes=body==null?null:Buffer.isBuffer(body)?body:Buffer.from(JSON.stringify(body));
  const req=http.request({hostname:host,port:80,path,method,headers:{Connection:'close',...(bytes?{'Content-Length':bytes.length,'Content-Type':'application/json'}:{}),...headers}},res=>{
   const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,bytes:Buffer.concat(chunks)}));res.on('error',reject);
  });req.setTimeout(12000,()=>req.destroy(new Error(path+' timed out')));req.on('error',reject);if(bytes)req.write(bytes);req.end();
 });
}
const json=r=>JSON.parse(r.bytes);
const info=json(await request('/api/info'));assert.equal(info.fw,'2.0.0-alpha.16');
assert.equal(info.native_card_api?.version,1);assert.equal(info.accepts_software,true);
const paired=await request('/api/pair','POST',{mode:'lan'},{'X-Lingxi-LAN':'1'});assert.equal(paired.status,200);
const token=json(paired).token;assert(/^[a-f0-9]{16}$/.test(token));
const auth={Authorization:`Bearer ${token}`};
const configuration=json(await request('/api/standalone','GET',null,auth));
assert(configuration.enabled&&configuration.local_first,'Enable native preference before this check');
let selected=0;
async function native(context){
 const result=await request('/api/card','POST',null,{...auth,...context});assert.equal(result.status,200);assert.equal(json(result).native,true);
 const state=json(await request('/api/info'));assert.equal(state.mode,'standalone');assert.equal(state.accepts_software,true);selected++;
 const frame=await request('/api/frame','GET',null,auth);assert.equal(frame.status,200);assert.equal(frame.bytes.length,115200);return frame.bytes;
}
try {
 assert(configuration.weather&&(configuration.card_mask&4),'Real weather native card must be enabled');
 const original=await native({'X-Lingxi-Card':'weather'});
 // Reuse the real frame as a generic software frame; no synthetic entities/images.
 const frame=await request('/image/rgb565','POST',original,{'Content-Type':'application/x-rgb565','X-Lingxi-Card':'generic'});
 assert.equal(frame.status,200);assert.equal(json(await request('/api/info')).mode,'external');
 const echoed=await request('/api/frame','GET',null,auth);assert(echoed.bytes.equals(original));
 if(configuration.ha_enabled&&configuration.entities.length&&(configuration.card_mask&8))await native({'X-Lingxi-Card':'ha'});
 for(const p of configuration.printers.filter(p=>p.enabled&&p.rotate)){
  await native({'X-Lingxi-Card':'printer','X-Lingxi-Serial':p.serial,'X-Lingxi-Brand':p.brand??(p.source==='formlabs'?'formlabs':'bambu'),'X-Lingxi-Source':p.source});
 }
 const missing=await request('/api/card','POST',null,{...auth,'X-Lingxi-Card':'printer','X-Lingxi-Serial':'not-configured','X-Lingxi-Brand':'bambu','X-Lingxi-Source':'mqtt'});
 assert.equal(missing.status,404);
 const unchanged=json(await request('/api/standalone','GET',null,auth));assert.equal(unchanged.revision,configuration.revision);
 const health=json(await request('/api/health','GET',null,auth));
 console.log(JSON.stringify({firmware:info.fw,nativeSelections:selected,genericFrameAccepted:true,exactFrameRoundtrip:true,missingFallback:404,configurationUnchanged:true,revision:configuration.revision,
   health:{uptime:health.uptime_seconds,freeHeap:health.free_heap,minimumHeap:health.minimum_heap,haPhase:health.ha_phase,weatherCached:health.weather_cached,printerSources:health.printers?.map(p=>({brand:p.brand,source:p.source,connected:p.connected}))}}));
}finally {
 const release=await request('/api/software','POST',{action:'release'},auth);assert.equal(release.status,200);
}
