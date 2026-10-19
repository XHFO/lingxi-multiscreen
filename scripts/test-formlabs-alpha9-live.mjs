import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
// Historical alpha.8-to-alpha.9 helper; requires an explicitly selected test device.
const [mode,path]=process.argv.slice(2),ip=process.env.FORMLABS_C6_IP;
assert(/^192\.168\.\d{1,3}\.\d{1,3}$/.test(ip||'')&&ip.split('.').every(n=>Number(n)<=255),'Set FORMLABS_C6_IP to the verified test-device LAN address');
const origin='http://'+ip;
const request=(p,options={})=>fetch(origin+p,{...options,signal:AbortSignal.timeout(15000)});
const info=await request('/api/info').then(r=>r.json());
assert.equal(info.device,'lingxi-c6-formlabs-monitor');
assert.equal(info.fw,mode==='--snapshot'?'2.0.0-formlabs-alpha.8':'2.0.0-formlabs-alpha.9');
const pair=await request('/api/pair',{method:'POST',headers:{'Content-Type':'application/json','X-Lingxi-LAN':'1'},body:'{"mode":"lan"}'}).then(r=>r.json());
assert(/^[a-f0-9]{16}$/.test(pair.token));const headers={Authorization:'Bearer '+pair.token};
const current=await request('/api/standalone',{headers}).then(r=>{assert(r.ok);return r.json();});
if(mode==='--snapshot'){
    writeFileSync(path,JSON.stringify({info,config:current}),{mode:0o600});
    console.log('Current alpha.8 redacted settings privately captured; no settings changed.');
}else{
    const baseline=JSON.parse(readFileSync(path,'utf8'));
    const strip=v=>{const {revision,...rest}=v;return rest;};
    assert.deepEqual(strip(current),strip(baseline.config),'Every user configuration field must be retained');
    if(mode==='--verify'){
        const view=await request('/api/view?card=overview',{method:'POST',headers});
        assert.equal(view.status,current.printers.length>=2?200:409);
        const page=await request('/standalone').then(r=>r.text());
        assert(page.includes("if(config.printers.length>=2)option('overview'"));
        console.log(`alpha.9 confirmed; all user fields retained; actual ${current.printers.length}-printer overview availability and embedded web page verified.`);
    }else if(mode==='--restore-runtime'){
        if(baseline.info.demo_active){const result=await request('/api/view?card=demo',{method:'POST',headers});assert(result.ok);}
        const result=await request('/api/view?card=auto',{method:'POST',headers});assert(result.ok);
        console.log('Original temporary demo state and automatic rotation restored.');
    }else if(mode==='--frame'){
        const card=current.printers.length>=2?'overview':'printer&index=0';
        const result=await request('/api/view?card='+card,{method:'POST',headers});assert(result.ok);
        const frame=await request('/api/frame',{headers});assert(frame.ok);const bytes=Buffer.from(await frame.arrayBuffer());assert.equal(bytes.length,115200);
        writeFileSync(path+'.actual.rgb565',bytes,{mode:0o600});
        const rgb=Buffer.alloc(240*240*3);for(let i=0;i<240*240;i++){const v=(bytes[i*2]<<8)|bytes[i*2+1];rgb[i*3]=Math.round((v>>11)*255/31);rgb[i*3+1]=Math.round(((v>>5)&63)*255/63);rgb[i*3+2]=Math.round((v&31)*255/31);}
        writeFileSync(path+'.actual.ppm',Buffer.concat([Buffer.from('P6\n240 240\n255\n'),rgb]),{mode:0o600});
        console.log('Actual configured printer frame captured privately; no settings changed.');
    }else throw Error('Unknown mode');
}
