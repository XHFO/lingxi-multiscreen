import assert from 'node:assert/strict';
import {writeFileSync,readFileSync} from 'node:fs';
// Historical alpha.5 acceptance helper; requires an explicitly selected test device.
const [mode,path]=process.argv.slice(2),ip=process.env.FORMLABS_C6_IP;
assert(/^192\.168\.\d{1,3}\.\d{1,3}$/.test(ip||'')&&ip.split('.').every(n=>Number(n)<=255),'Set FORMLABS_C6_IP to the verified test-device LAN address');
const origin='http://'+ip;
const request=(path,options={})=>fetch(origin+path,{...options,signal:AbortSignal.timeout(15000)});
const info=await request('/api/info').then(r=>r.json());assert.equal(info.device,'lingxi-c6-formlabs-monitor');
const pair=await request('/api/pair',{method:'POST',headers:{'Content-Type':'application/json','X-Lingxi-LAN':'1'},body:'{"mode":"lan"}'}).then(r=>r.json());
assert(/^[a-f0-9]{16}$/.test(pair.token));const headers={Authorization:'Bearer '+pair.token};
const config=()=>request('/api/standalone',{headers}).then(r=>{assert(r.ok);return r.json();});
const current=await config();
if(mode==='--brightness'){
    const expected=JSON.parse(readFileSync(path,'utf8'));assert.equal(current.brightness,Number(process.argv[4]));
    const strip=v=>{const {revision,brightness,...rest}=v;return rest;};assert.deepEqual(strip(current),strip(expected));
    console.log('Web autosave brightness applied; every other user field unchanged.');
}
if(mode==='--capture'){writeFileSync(path,JSON.stringify(current),{mode:0o600});console.log('Private configuration baseline captured; no values printed.');}
if(mode==='--verify'){
    assert.equal(info.fw,'2.0.0-formlabs-alpha.5');assert.equal(info.product_name,'XH Multiscreen');assert.equal(info.demo_active,false);
    assert.deepEqual(current,JSON.parse(readFileSync(path,'utf8')),'Firmware update must preserve every user field');
    assert.equal((await request('/api/view?card=demo',{method:'POST'})).status,401);
    for(const [card,enabled] of [['demo',true],['demo_off',false],['demo',true]]){
        const r=await request('/api/view?card='+card,{method:'POST',headers});assert(r.ok);
        const state=await request('/api/info').then(r=>r.json());assert.equal(state.demo_active,enabled);
        assert.deepEqual(await config(),current,'Demo must not modify real configuration');
    }
    const r=await request('/api/frame',{headers});assert(r.ok);const bytes=Buffer.from(await r.arrayBuffer());assert.equal(bytes.length,115200);
    writeFileSync(path+'.demo.rgb565',bytes,{mode:0o600});console.log('alpha.5: all settings retained; demo auth, enable/disable, real-source isolation and actual 240x240 frame passed. Demo left enabled.');
}
