import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
// Historical alpha.7 acceptance helper; requires an explicitly selected test device.
const [mode,path,arg]=process.argv.slice(2),ip=process.env.FORMLABS_C6_IP;
assert(/^192\.168\.\d{1,3}\.\d{1,3}$/.test(ip||'')&&ip.split('.').every(n=>Number(n)<=255),'Set FORMLABS_C6_IP to the verified test-device LAN address');
const origin='http://'+ip;
const request=(p,options={})=>fetch(origin+p,{...options,signal:AbortSignal.timeout(15000)});
const info=await request('/api/info').then(r=>r.json());
assert.equal(info.device,'lingxi-c6-formlabs-monitor');assert.equal(info.fw,'2.0.0-formlabs-alpha.7');
const pair=await request('/api/pair',{method:'POST',headers:{'Content-Type':'application/json','X-Lingxi-LAN':'1'},body:'{"mode":"lan"}'}).then(r=>r.json());
assert(/^[a-f0-9]{16}$/.test(pair.token));const headers={Authorization:'Bearer '+pair.token};
const current=await request('/api/standalone',{headers}).then(r=>{assert(r.ok);return r.json();}),baseline=JSON.parse(readFileSync(path,'utf8'));
const strip=v=>{const {revision,...rest}=v;return {...rest,printers:rest.printers.map(p=>{const {card_style,...data}=p;return data;})};};
assert.deepEqual(strip(current),strip(baseline),'All unrelated user configuration must remain unchanged');
if(mode==='--verify'){for(const p of current.printers)assert.equal(p.card_style,baseline.printers.find(b=>b.serial===p.serial)?.card_style||0);console.log('alpha.7: every user field retained; legacy card style defaults to standard.');}
else if(mode==='--check-style'){assert.equal(current.printers[0].card_style,Number(arg));for(let i=1;i<current.printers.length;i++)assert.equal(current.printers[i].card_style,baseline.printers[i].card_style||0);console.log('Web autosave applied requested per-printer style; every unrelated field retained.');}
else if(mode==='--restore'){
    const body={...current,printers:current.printers.map(p=>({...p,card_style:baseline.printers.find(b=>b.serial===p.serial)?.card_style||0}))};
    const saved=await request('/api/standalone',{method:'PUT',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify(body)});assert(saved.ok);assert.deepEqual(strip(await saved.json()),strip(baseline));console.log('Original styles restored; no unrelated configuration changed.');
}else if(mode==='--frame'){
    assert(['demo','demo_off','auto','printer'].includes(arg));const view=await request('/api/view?card='+arg+(arg==='printer'?'&index=0':''),{method:'POST',headers});assert(view.ok);
    const frame=await request('/api/frame',{headers});assert(frame.ok);const bytes=Buffer.from(await frame.arrayBuffer());assert.equal(bytes.length,115200);
    writeFileSync(path+`.style${current.printers[0]?.card_style||0}.${arg}.rgb565`,bytes,{mode:0o600});console.log('Actual device frame read; settings retained.');
}else throw Error('Unknown test mode');
