#!/usr/bin/env python3
"""校验内置 TF 包与构建证明，不访问设备。 / Validate bundled Pico resources offline."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zlib


def require(condition, message):
    # Packaging checks must also run with PYTHONOPTIMIZE enabled.
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    require(path.is_file() and not path.is_symlink(), f'Missing or linked manifest: {path.name}')
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f'Invalid manifest: {path.name}')
    return value


def plain_tree(path):
    require(path.is_dir() and not path.is_symlink(), f'Missing or linked resource tree: {path.name}')
    require(all(not p.is_symlink() for p in path.rglob('*')), f'Symlink in {path.name}')


def package_info(data):
    """Apply the same PGA1 envelope rules as ReadPicoPackage in the Mac manager."""
    require(512 <= len(data) <= 4 * 1024 * 1024, 'Invalid PGA size')
    require(data[:8] == b'PICOAPP1', 'Invalid PGA magic')

    def u32(offset):
        return struct.unpack_from('<I', data, offset)[0]

    def string(offset, count):
        field = data[offset:offset + count]
        end = field.find(b'\0')
        require(end >= 0 and not any(field[end:]), 'Invalid PGA text field')
        return field[:end].decode('utf-8')

    require((u32(8), u32(12), u32(16), u32(20)) == (1, 512, len(data), 1), 'Invalid PGA header')
    header = bytearray(data[:512])
    header[232:236] = bytes(4)
    require(zlib.crc32(header) == u32(232), 'Invalid PGA header CRC')
    kind, count = u32(28), u32(228)
    require(u32(24) > 0 and (kind <= 5 or 128 <= kind <= 255), 'Invalid PGA kind/version')
    require(1 <= count <= 4 and u32(224) == 0, 'Invalid PGA payload count/flags')
    require(not any(data[236:256] + data[384:448] + data[480:512]), 'Invalid PGA reserved fields')
    identifier = string(32, 32)
    require(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', identifier), 'Invalid PGA id')
    require(bool(string(64, 64)), 'Missing PGA title')
    string(128, 96)
    next_offset, payloads = 512, {}
    for i in range(4):
        offset = 256 + i * 32
        if i >= count:
            require(not any(data[offset:offset + 32]), 'Unused PGA payload is not empty')
            continue
        target = string(offset, 16)
        start, size, crc, flags = struct.unpack_from('<IIII', data, offset + 16)
        require(target and target not in payloads and start == next_offset and
                0 < size <= 2 * 1024 * 1024 and start + size <= len(data) and flags == 0,
                'Invalid PGA payload range/target')
        payload = data[start:start + size]
        require(zlib.crc32(payload) == crc, 'Invalid PGA payload CRC')
        payloads[target] = {'target': target, 'bytes': size, 'sha256': sha(payload)}
        next_offset += size
    require(next_offset == len(data) and 'esp32s3-xtensa' in payloads, 'Missing device payload or trailing bytes')
    return {'id': identifier, 'kind': kind, 'version': u32(24), 'targets': list(payloads), 'payloads': payloads}


def validate_proofs(directory, firmware):
    root = directory / 'validation'
    if not root.exists() and not root.is_symlink():
        return
    plain_tree(root)
    current_native = (root / 'swift-gray16-native.json').exists() or (root / 'swift-wireless-native.json').exists()
    native_names = ['swift-gray16-native', 'swift-wireless-native', 'native-preview-build'] if current_native else ['native-validation', 'http-validation']
    names = ['firmware-validation', 'source-binding', 'frozen-source-manifest', *native_names]
    proofs = {name: read_json(root / (name + '.json')) for name in names}
    for name, proof in proofs.items():
        require(proof['version'] == firmware['version'], f'Stale {name}')
        if name not in ['frozen-source-manifest', 'native-preview-build']:
            require(proof['result'] == 'PASS', f'Failed {name}')
    app = proofs['firmware-validation']
    require(app['app_sha256'] == firmware['sha256'] and app['app_bytes'] == firmware['image_bytes'],
            'Firmware proof is not bound to the bundled APP')
    binding = proofs['source-binding']
    require(binding['manifest_sha256'] == sha((root / 'frozen-source-manifest.json').read_bytes()),
            'Frozen source manifest binding mismatch')
    if current_native:
        native_sha = proofs['native-preview-build']['binary_sha256']
        require(isinstance(native_sha, str) and len(native_sha) == 64
                and all(character in '0123456789abcdef' for character in native_sha), 'Invalid native binary digest')
        require(proofs['swift-gray16-native']['native_binary_sha256'] == native_sha
                and proofs['swift-wireless-native']['native_binary_sha256'] == native_sha,
                'Native/HTTP/gray16 proof binding mismatch')
    else:
        require(proofs['native-validation']['native_sha256'] == proofs['http-validation']['native_sha256'],
                'Native/HTTP proof binding mismatch')


def validate(directory):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'Missing or linked Pico resource directory')
    firmware = read_json(directory / 'manifest.json')
    app = directory / 'read-pico-app.bin'
    require(not app.is_symlink(), 'Linked APP resource')
    root, manifest_path = directory / 'tf-card', directory / 'tf-manifest.json'
    declaration = firmware.get('tf_apps')
    if declaration is None:
        require(not root.exists() and not root.is_symlink() and
                not manifest_path.exists() and not manifest_path.is_symlink(), 'Undeclared TF resources')
        validate_proofs(directory, firmware)
        print('PASS legacy APP-only resources; no TF packages declared')
        return
    require(declaration['directory'] == 'tf-card' and declaration['manifest'] == 'tf-manifest.json',
            'Invalid TF resource locations')
    require(declaration['automatic_install'] is False, 'TF installation must be explicit')
    plain_tree(root)
    catalog = read_json(manifest_path)
    require(catalog['version'] == firmware['version'], 'TF package generation differs from firmware')
    require(catalog['automatic_install'] is False, 'TF installation must be explicit')
    entries = catalog['packages']
    require(isinstance(entries, list) and entries and len(entries) == declaration['count'], 'TF package count mismatch')
    seen, by_folder = set(), {'games': {}, 'tools': {}}
    for entry in entries:
        identifier = entry['id']
        require(isinstance(identifier, str) and re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,29}[a-z0-9])?', identifier),
                'Invalid TF application id')
        require(identifier not in seen, 'Duplicate TF application')
        seen.add(identifier)
        folder = 'tools' if entry['kind'] >= 128 else 'games'
        relative = f'apps/{folder}/{identifier}.pga'
        require(entry['path'] == relative, 'Invalid TF application path')
        payload = (root / relative).read_bytes()
        require(len(payload) == entry['bytes'] and sha(payload) == entry['sha256'], 'TF application hash/size mismatch')
        info = package_info(payload)
        require(all(entry[key] == info[key] for key in ('id', 'kind', 'targets')), 'TF manifest differs from PGA')
        by_folder[folder][identifier] = (entry, info)
    require({p.relative_to(root).as_posix() for p in root.rglob('*.pga')} == {e['path'] for e in entries},
            'Unlisted TF application')
    for folder, expected in by_folder.items():
        if not expected:
            continue
        listing = read_json(root / 'apps' / folder / 'catalog.json')
        require(listing['schema'] == 1, 'Unsupported TF catalog schema')
        items = listing['games' if folder == 'games' else 'apps']
        require(len(items) == len(expected) and {item['id'] for item in items} == set(expected), 'TF catalog set mismatch')
        for item in items:
            entry, info = expected[item['id']]
            require(all(item[key] == entry[key] for key in ('kind', 'bytes', 'sha256', 'targets')),
                    'TF catalog differs from manifest')
            require(item['file'] == item['id'] + '.pga' and item['abi'] == 1, 'Invalid catalog file/ABI')
            version = item.get('version_code', item['version'])
            require(version == info['version'], 'Catalog/PGA version mismatch')
            if 'payloads' in item:
                require(item['payloads'] == list(info['payloads'].values()), 'Catalog payload binding mismatch')
    validate_proofs(directory, firmware)
    print(f'PASS {len(entries)} bundled TF packages and catalogs; explicit import only')


if __name__ == '__main__':
    try:
        validate(sys.argv[1])
    except (ValueError, KeyError, TypeError, OSError, IndexError) as error:
        sys.exit(f'Invalid Pico resources: {error}')
