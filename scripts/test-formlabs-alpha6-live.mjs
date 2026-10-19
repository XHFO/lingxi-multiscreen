import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
// Historical alpha.6 acceptance helper; requires an explicitly selected test device.
const [mode,path]=process.argv.slice(2),ip=process.env.FORMLABS_C6_IP;
assert(/^192\.168\.\d{1,3}\.\d{1,3}$/.test(ip||'')&&ip.split('.').every(n=>Number(n)<=255),'Set FORMLABS_C6_IP to the verified test-device LAN address');
const origin='http://'+ip;
assert(['--verify','--style','--check-style'].includes(mode));
const request=(p,options={})=>fetch(origin+p,{...options,signal:AbortSignal.timeout(15000)});
const info=await request('/api/info').then(r=>r.json());
assert.equal(info.device,'lingxi-c6-formlabs-monitor');assert.equal(info.fw,'2.0.0-formlabs-alpha.6');
const pair=await request('/api/pair',{method:'POST',headers:{'Content-Type':'application/json','X-Lingxi-LAN':'1'},body:'{"mode":"lan"}'}).then(r=>r.json());
assert(/^[a-f0-9]{16}$/.test(pair.token));const headers={Authorization:'Bearer '+pair.token};
const config=()=>request('/api/standalone',{headers}).then(r=>{assert(r.ok);return r.json();});
const current=await config(),baseline=JSON.parse(readFileSync(path,'utf8'));
const strip=value=>{const {revision,digit_style,...rest}=value;return rest;};
assert.deepEqual(strip(current),strip(baseline),'Every unrelated user field must be preserved');
if(mode==='--verify'){
    assert.equal(current.digit_style,0,'Legacy devices retain their existing pixel numerals');
    console.log('alpha.6 verified: legacy pixel default; all unrelated user configuration retained.');
}
if(mode==='--check-style'){
    assert.equal(current.digit_style,Number(process.argv[4]));
    console.log('Digit style persisted; all unrelated user configuration retained.');
}
if(mode==='--style'){
    const style=Number(process.argv[4]);assert([0,1].includes(style));
    const body={...current,digit_style:style};
    const response=await request('/api/standalone',{method:'PUT',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify(body)});
    assert(response.ok,`Appearance update failed (${response.status})`);
    const saved=await response.json();assert.equal(saved.digit_style,style);assert.deepEqual(strip(saved),strip(baseline));
    const card=process.argv[5]||'clock';assert(['clock','weather','demo','auto','demo_off'].includes(card));
    const view=await request('/api/view?card='+card,{method:'POST',headers});assert(view.ok);
    const frame=await request('/api/frame',{headers});assert(frame.ok);const bytes=Buffer.from(await frame.arrayBuffer());assert.equal(bytes.length,115200);
    writeFileSync(path+`.${style}.${card}.rgb565`,bytes,{mode:0o600});
    console.log(`Digit style ${style} applied; ${card} actual frame read; all other user configuration retained.`);
}
