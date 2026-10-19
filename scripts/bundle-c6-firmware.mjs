// Deterministic build-to-resource packaging only. No serial or network access.
// The App must flash its segmented regions; FF gaps are never user data.
import {readFileSync, writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const root = new URL('../', import.meta.url);
const build = new URL('Tools/WaveshareC6Firmware/.pio/build/waveshare-c6/', root);
const resources = new URL('Resources/Firmware/', root);
const profile = readFileSync(new URL('Tools/WaveshareC6Firmware/src/firmware_profile.h', root), 'utf8');
const version = profile.match(/#else\s*\n#define C6_FIRMWARE_VERSION "([^"]+)"/)?.[1];
assert(version, 'Missing general C6 firmware version');
const regions = [
    {file: 'bootloader.bin', address: 0, maximum: 0x8000},
    {file: 'partitions.bin', address: 0x8000, maximum: 0x1000},
    {file: 'ota_data_initial.bin', address: 0x10000, maximum: 0x2000},
    {file: 'firmware.bin', address: 0x20000, maximum: 0x1e0000}
].map(region => ({...region, bytes: readFileSync(new URL(region.file, build))}));
for (const region of regions) {
    assert(region.bytes.length > 0 && region.bytes.length <= region.maximum, `${region.file}: exceeds original region`);
}
const ota = regions[3].bytes;
for (const bytes of [regions[0].bytes, ota]) {
    assert.equal(bytes[0], 0xe9, 'Invalid ESP image magic');
    assert.equal(bytes.readUInt16LE(12), 13, 'Image is not ESP32-C6');
}
// Fail closed if the existing storage/OTA boundaries change, including NVS.
const table = regions[1].bytes;
const expected = [
    ['nvs', 1, 2, 0x9000, 0x6000],
    ['phy_init', 1, 1, 0xf000, 0x1000],
    ['otadata', 1, 0, 0x10000, 0x2000],
    ['ota_0', 0, 0x10, 0x20000, 0x1e0000],
    ['ota_1', 0, 0x11, 0x200000, 0x1e0000],
    ['lx_wifi', 1, 0x40, 0x3f0000, 0x1000]
];
expected.forEach(([name, type, subtype, address, size], index) => {
    const offset = index * 32;
    assert.equal(table.readUInt16LE(offset), 0x50aa, 'Invalid partition magic');
    assert.equal(table[offset + 2], type);
    assert.equal(table[offset + 3], subtype);
    assert.equal(table.readUInt32LE(offset + 4), address, `${name}: changed address`);
    assert.equal(table.readUInt32LE(offset + 8), size, `${name}: changed capacity`);
    assert.equal(table.subarray(offset + 12, offset + 28).toString().replace(/\0.*$/s, ''), name);
});
assert.equal(table.readUInt16LE(expected.length * 32), 0xebeb, 'Unexpected additional partition');
assert(ota.includes(Buffer.from(version)), 'Built image does not contain the expected version');
const full = Buffer.alloc(0x20000 + ota.length, 0xff);
for (const region of regions) region.bytes.copy(full, region.address);
assert(full.subarray(0x9000, 0x10000).every(byte => byte === 0xff), 'NVS/PHY gap is not empty');
assert(full.subarray(0x12000, 0x20000).every(byte => byte === 0xff), 'Reserved gap is not empty');
assert(full.subarray(0x20000).equals(ota), 'OTA and full application differ');
const hash = data => createHash('sha256').update(data).digest('hex');
const manifest = Buffer.from(JSON.stringify({version, full_sha256: hash(full), ota_sha256: hash(ota)}, null, 2) + '\n');
const outputs = [['lingxi-c6-2.0.0-full.bin', full], ['lingxi-c6-2.0.0-ota.bin', ota], ['c6-manifest.json', manifest]];
for (const [file, data] of outputs) {
    const target = new URL(file, resources);
    if (process.argv.includes('--check')) assert(readFileSync(target).equals(data), `${file}: stale embedded resource`);
    else writeFileSync(target, data);
}
console.log(`${version}: OTA ${ota.length}B; free ${0x1e0000 - ota.length}B; original partitions/NVS gaps verified; no device accessed`);
