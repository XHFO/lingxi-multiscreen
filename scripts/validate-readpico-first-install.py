#!/usr/bin/env python3
"""Validate curated Pico first-install resources; never access a device.
校验小纸 Pico 专用首次安装资源，不访问设备。
"""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import struct
import zlib

SPEC = {
    'bootloader': ('bootloader.bin', 0, 0x8000),
    'partitions': ('partition-table.bin', 0x8000, 0x1000),
    'otadata': ('ota-data.bin', 0xf000, 0x2000),
    'application': ('read-pico-app.bin', 0x20000, 0x400000),
    'assets': ('assets.bin', 0x4a0000, 0x660000),
    'storage': ('storage.bin', 0xb00000, 0x500000),
}
PARTITIONS = [
    ('nvs',1,2,0x9000,0x6000), ('otadata',1,0,0xf000,0x2000),
    ('ota_0',0,16,0x20000,0x400000), ('ota_1',0,17,0x420000,0x80000),
    ('assets',1,130,0x4a0000,0x660000), ('storage',1,130,0xb00000,0x500000)]


def sha(data): return hashlib.sha256(data).hexdigest()


def check_image(data, app=False):
    assert 24 <= len(data) <= (0x400000 if app else 0x8000)
    assert data[0] == 0xe9 and 1 <= data[1] <= 16
    assert data[2:4] == bytes([2, 0x4f]) and struct.unpack_from('<H', data, 12)[0] == 9
    minimum, maximum = struct.unpack_from('<HH', data, 15)
    assert minimum <= 2 <= maximum and data[23] == 1
    position, checksum = 24, 0xef
    for _ in range(data[1]):
        assert position + 8 <= len(data)
        address, size = struct.unpack_from('<II', data, position)
        position += 8
        assert size <= len(data) - position
        if app and (0x3c000000 <= address < 0x3e000000 or 0x42000000 <= address < 0x44000000):
            assert address & 65535 == (0x20000 + position) & 65535
        for byte in data[position:position + size]: checksum ^= byte
        position += size
    end = (position | 15) + 1
    assert end + 32 == len(data) and data[end - 1] == checksum
    assert not any(data[position:end - 1]) and hashlib.sha256(data[:end]).digest() == data[end:]


def validate(directory):
    root = directory.resolve()
    manifest = json.loads((root / 'fresh-install.json').read_text())
    app_manifest = json.loads((root / 'manifest.json').read_text())
    assert manifest['schema'] == 1 and manifest['kind'] == 'first-install'
    assert manifest['board'] == 'read-pico-esp32s3' and manifest['chip'] == 'esp32s3'
    assert manifest['version'] == app_manifest['version']
    assert manifest['flash_bytes'] == 0x1000000 and manifest['erase_flash'] is True
    files = manifest['files']; roles = [file['role'] for file in files]
    assert 4 <= len(files) <= 6 and len(roles) == len(set(roles))
    assert {'bootloader', 'partitions', 'otadata', 'application'} <= set(roles)
    erased = ['nvs', 'ota_1'] + [role for role in ['assets','storage'] if role not in roles]
    assert len(manifest['erased_partitions']) == len(set(manifest['erased_partitions']))
    assert set(manifest['erased_partitions']) == set(erased)
    for file in files:
        name, address, maximum = SPEC[file['role']]
        assert file['file'] == name and file['address'] == address
        path = root / name
        assert stat.S_ISREG(path.lstat().st_mode) and path.resolve().parent == root
        assert 0 < path.stat().st_size <= maximum
        data = path.read_bytes()
        assert len(data) == file['bytes'] and sha(data) == file['sha256'].lower()
        role = file['role']
        if role in ['application', 'bootloader']:
            check_image(data, role == 'application')
            if role == 'application':
                assert data[32:36] == bytes.fromhex('3254cdab')
                assert data[80:112].split(b'\0')[0] == b'Read_Pico'
                assert data[48:80].split(b'\0')[0].decode() == manifest['version']
                assert sha(data) == app_manifest['sha256'] and len(data) == app_manifest['image_bytes']
        elif role == 'partitions':
            assert len(data) == 4096
            for i, expected in enumerate(PARTITIONS):
                magic, kind, subtype, offset, size, label, flags = struct.unpack_from('<HBBII16sI', data, i * 32)
                assert magic == 0x50aa and flags == 0
                assert (label.split(b'\0')[0].decode(), kind, subtype, offset, size) == expected
            pos = 32 * len(PARTITIONS)
            assert data[pos:pos+16] == b'\xeb\xeb' + b'\xff' * 14
            assert data[pos+16:pos+32] == hashlib.md5(data[:pos]).digest()
            assert data[pos+32:] == b'\xff' * (4096-pos-32)
        elif role == 'otadata':
            expected = bytearray(b'\xff' * 8192)
            struct.pack_into('<I', expected, 0, 1)
            struct.pack_into('<I', expected, 28, zlib.crc32(expected[:4], 0xffffffff))
            assert data == expected
        else:
            assert len(data) == maximum
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--prepare', action='store_true', help='Create OTA sequence and manifest from already built, known-name resources')
    args = parser.parse_args()
    directory = args.directory
    if args.prepare:
        ota = bytearray(b'\xff' * 8192)
        struct.pack_into('<I', ota, 0, 1)
        struct.pack_into('<I', ota, 28, zlib.crc32(ota[:4], 0xffffffff))
        (directory / 'ota-data.bin').write_bytes(ota)
        app_manifest = json.loads((directory / 'manifest.json').read_text())
        manifest = dict(schema=1, kind='first-install', board='read-pico-esp32s3', chip='esp32s3',
                        version=app_manifest['version'], flash_bytes=0x1000000, erase_flash=True,
                        erased_partitions=['nvs', 'ota_1'], files=[])
        for role, (name, address, maximum) in SPEC.items():
            if role in ['assets', 'storage'] and not (directory / name).exists():
                manifest['erased_partitions'].append(role)
                continue
            data = (directory / name).read_bytes()
            manifest['files'].append(dict(role=role,file=name,address=address,bytes=len(data),sha256=sha(data)))
        (directory / 'fresh-install.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    manifest = validate(directory)
    print(f"PASS first-install resources {manifest['version']}: {len(manifest['files'])} verified files; no device accessed")

if __name__ == '__main__': main()
