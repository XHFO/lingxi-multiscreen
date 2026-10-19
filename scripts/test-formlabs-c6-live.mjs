// Dedicated test device only. Never prints pairing tokens or configuration secrets.
// Historical alpha.2 OTA helper; not the current firmware upgrade command.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
const [ip, mode, file] = process.argv.slice(2);
assert(/^192\.168\.\d{1,3}\.\d{1,3}$/.test(ip || ''), 'Pass the verified test device IPv4 address');
const origin = `http://${ip}`;
async function request(path, options = {}) {
    return fetch(origin + path, { ...options, signal: AbortSignal.timeout(path === '/api/ota' ? 60000 : 8000) });
}
async function info() { const r = await request('/api/info'); assert(r.ok); return r.json(); }
let device = await info(); assert.equal(device.device, 'lingxi-c6-formlabs-monitor');
assert.equal(device.max_printers, 3); assert.equal(device.accepts_software, false);
assert.equal(device.standalone_api.ha, false); assert.equal(device.standalone_api.bambu, false);
async function pair() {
    const r = await request('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Lingxi-LAN': '1' }, body: '{"mode":"lan"}' });
    assert(r.ok); const { token } = await r.json(); assert(/^[a-f0-9]{16}$/.test(token)); return { Authorization: `Bearer ${token}` };
}
let auth = await pair();
async function config() { const r = await request('/api/standalone', { headers: auth }); assert(r.ok); return r.json(); }
const before = await config();
if (mode === '--display') {
    assert.deepEqual(device.rotation_steps, [0,90,180,270]);
    const view = async card => { const r = await request('/api/view?card=' + card, { method:'POST', headers:auth }); assert(r.ok, `View rejected (${r.status})`); };
    const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
    const compare = value => { const { revision, ...rest } = value; return rest; };
    let expected = before;
    async function save(patch) {
        const current = await config(); assert.deepEqual(current, expected, 'Concurrent configuration change; stop rather than overwrite');
        const r = await request('/api/standalone', { method:'PUT', headers:{...auth,'Content-Type':'application/json'}, body:JSON.stringify({...current,...patch}) });
        assert(r.ok, `Display save rejected (${r.status})`); expected = await config();
    }
    const restore = Object.fromEntries(['rotation','sleep_mode','sleep_idle_minutes','sleep_start','sleep_end','sleep_keep_printing'].map(k => [k,before[k]]));
    try {
        await save({sleep_mode:0});
        await view('clock');
        for (const angle of [0,90,180,270]) {
            const r = await request('/api/rotation?rotation='+angle, {method:'POST',headers:auth});assert(r.ok);
            const frame = await request('/api/frame',{headers:auth});assert(frame.ok);assert.equal(Number(frame.headers.get('X-Lingxi-Rotation')),angle);
            assert.equal((await frame.arrayBuffer()).byteLength,115200);assert.equal((await info()).rotation,angle);
        }
        assert.deepEqual(await config(),expected,'Runtime preview rotation must not save configuration');
        await save({rotation:90,sleep_mode:1,sleep_idle_minutes:1,sleep_keep_printing:false});
        await view('clock');console.log('4 runtime rotations and canonical frame size passed; checking 1-minute inactivity sleep');
        await wait(62000);assert.equal((await info()).asleep,true,'Device must sleep even while LAN queries remain available');
        const frame = await request('/api/frame',{headers:auth});assert(frame.ok);assert.equal(frame.headers.get('X-Lingxi-Asleep'),'1');await frame.arrayBuffer();
        const revision = frame.headers.get('X-Lingxi-Frame-Revision');assert(/^\d+$/.test(revision));
        const unchanged = await request('/api/frame?rev='+revision,{headers:auth});assert.equal(unchanged.status,204);
        assert.equal(unchanged.headers.get('X-Lingxi-Frame-Revision'),revision);assert.equal(unchanged.headers.get('X-Lingxi-Rotation'),'90');
        assert.equal(unchanged.headers.get('X-Lingxi-Asleep'),'1');assert.equal((await unchanged.arrayBuffer()).byteLength,0);
        assert.equal((await info()).asleep,true,'Read-only frame preview must not wake the device');
        await view('clock');assert.equal((await info()).asleep,false,'Explicit view action wakes the screen');
        console.log('Actual idle sleep, LAN availability, read-only non-wake and explicit wake passed');
    } finally {
        await save(restore);await view('auto');assert.deepEqual(compare(await config()),compare(before),'Restore all user configuration after the display test');
        console.log('All user configuration restored; automatic rotation resumed');
    }
}
if (mode === '--language') {
    assert(file === '0' || file === '1', 'Language must be 0 (Chinese) or 1 (English)');
    const language = Number(file);
    const r = await request('/api/standalone', { method: 'PUT', headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...before, language }) });
    assert(r.ok, `Language save rejected (${r.status}); do not overwrite a configuration conflict`);
    const after = await config(); assert.equal(after.language, language);
    const withoutLanguage = value => { const { language, revision, ...rest } = value; return rest; };
    assert.deepEqual(withoutLanguage(after), withoutLanguage(before), 'Language changes must preserve all other configuration');
    device = await info(); assert.equal(device.language, language);
    console.log('Language saved; every other configuration field retained');
}
if (mode === '--ota') {
    const priorBoot = await request('/api/health', { headers: auth }).then(r => r.json());
    assert(file); const bytes = readFileSync(file), hash = createHash('sha256').update(bytes).digest('hex');
    const r = await request('/api/ota', { method: 'POST', headers: { ...auth, 'X-Firmware-SHA256': hash, 'Content-Type': 'application/octet-stream' }, body: bytes });
    assert(r.ok, `OTA rejected ${r.status}: ${r.ok?'':await r.text()}`); console.log('Dedicated OTA accepted; waiting for reboot');
    let rebooted = false;
    for (let i = 0; i < 30; i++) {
        await new Promise(resolve => setTimeout(resolve, 1000));
        try { device = await info(); const state = await request('/api/health', { headers: auth }).then(r => r.json()); if (device.fw === '2.0.0-formlabs-alpha.2' && state.boot_id !== undefined && state.boot_id !== priorBoot.boot_id) { rebooted = true; break; } } catch {}
    }
    assert.equal(device.fw, '2.0.0-formlabs-alpha.2'); assert(rebooted, 'OTA must actually reboot'); auth = await pair();
    const after = await config(); assert.deepEqual(after, before, 'OTA must preserve dedicated configuration');
    console.log('OTA reboot, Wi-Fi reconnection and complete configuration retention passed');
}
const healthResponse = await request('/api/health', { headers: auth }); assert(healthResponse.ok);
const health = await healthResponse.json();
console.log(JSON.stringify({ firmware: device.fw, uptime: health.uptime_seconds, free_heap: health.free_heap,
    largest_free_block: health.largest_free_block, config_restore: health.config_restore, weather_phase: health.weather_phase,
    language: device.language, printers: health.printers.map(p => ({ phase: p.phase, connected: p.connected })) }, null, 2));
if (mode === '--capture') {
    assert(file); mkdirSync(file, { recursive: true });
    const r = await request('/api/frame', { headers: auth }); assert(r.ok); const bytes = new Uint8Array(await r.arrayBuffer());
    assert.equal(bytes.length, 115200); const rgb = Buffer.alloc(240 * 240 * 3);
    for (let i = 0; i < 240 * 240; i++) { const v = bytes[i * 2] * 256 + bytes[i * 2 + 1]; rgb[i * 3] = (v >> 11) * 255 / 31; rgb[i * 3 + 1] = ((v >> 5) & 63) * 255 / 63; rgb[i * 3 + 2] = (v & 31) * 255 / 31; }
    writeFileSync(join(file, 'device-frame.ppm'), Buffer.concat([Buffer.from('P6\n240 240\n255\n'), rgb]));
    console.log('Actual device canonical framebuffer captured (not a photograph of the LCD)');
}
if (mode === '--clock') {
    for (let i = 0; i < 17; i++) {
        device = await info();
        if (device.clock_metrics?.last_fold_frames) { console.log(JSON.stringify(device.clock_metrics)); break; }
        await new Promise(resolve => setTimeout(resolve, 5000));
    }
    assert(device.clock_metrics?.last_fold_frames > 0, 'No measured minute transition; check NTP or selected page');
}
assert((await info()).device === 'lingxi-c6-formlabs-monitor');
console.log('Live dedicated device checks passed');
