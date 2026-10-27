#!/usr/bin/env python3
"""中文：仅测试打包守卫与复制；不构建签名、不访问设备。
English: Exercise only the packaging guard/copy block, never signing or hardware.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
script = (repo / 'scripts/make-app.sh').read_text()
block = script.split('# BEGIN READ_PICO_PACKAGE\n', 1)[1].split('# END READ_PICO_PACKAGE', 1)[0]
checks = 0
with tempfile.TemporaryDirectory(prefix='readpico-package-tests-') as temp:
    root = Path(temp)
    fixture = root / 'fixtures'
    fixture.mkdir()
    subprocess.run([sys.executable, str(Path(__file__).with_name('fixtures.py')), str(fixture)], check=True, capture_output=True)
    source = (fixture / 'app.bin').read_bytes()
    manifest = json.loads((fixture / 'manifest.json').read_text())

    def run(name, *, change=None, data=None, present=True, half=False, success=False, fresh=False, bad_fresh=False):
        global checks
        source_root, app = root / name / 'source', root / name / 'staged.app'
        source_root.mkdir(parents=True)
        (source_root / 'scripts').mkdir()
        for name in ['validate-readpico-tf-resources.py', 'validate-readpico-first-install.py']:
            (source_root / 'scripts' / name).write_bytes((repo / 'scripts' / name).read_bytes())
        data = source if data is None else data
        value = dict(manifest)
        if change:
            value.update(change)
        if present:
            directory = source_root / 'Resources/Firmware/ReadPico'
            directory.mkdir(parents=True)
            (directory / 'read-pico-app.bin').write_bytes(data)
            if not half:
                (directory / 'manifest.json').write_text(json.dumps(value))
        if fresh:
            import shutil
            for candidate in (fixture / 'fresh').iterdir():
                if candidate.name not in ['read-pico-app.bin', 'manifest.json']:
                    shutil.copy2(candidate, directory / candidate.name)
            if bad_fresh:
                (directory / 'bootloader.bin').write_bytes(b'bad bootloader')
        env = dict(os.environ, ROOT=str(source_root), APP=str(app))
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', block], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
        checks += 1
        destination = app / 'Contents/Resources/Firmware/ReadPico'
        if success and present:
            assert (destination / 'read-pico-app.bin').read_bytes() == data
            assert json.loads((destination / 'manifest.json').read_text()) == value
            checks += 2
            if fresh:
                for candidate in (fixture / 'fresh').iterdir():
                    assert (destination / candidate.name).read_bytes() == candidate.read_bytes()
                    checks += 1
        if not success:
            assert not destination.exists(), f'{name}: copied before validation'
            checks += 1

    run('valid', success=True)
    run('valid-first-install', success=True, fresh=True)
    run('invalid-first-install', fresh=True, bad_fresh=True)
    run('numeric-address', change={'app_address': 131072}, success=True)
    run('not-bundled', present=False, success=True)
    run('half-pair', half=True)
    for key, value in [('board', 'other-s3'), ('chip', 'esp32c6'), ('app_address', '0x10000'),
                       ('slot_bytes', 0x800000), ('image_bytes', len(source) + 1),
                       ('sha256', '0' * 64), ('kind', 'backup'), ('version', 'other')]:
        run('invalid-' + key, change={key: value})
    for name, offset, value in [('c6-chip', 12, 13), ('app-identity', 80, 0), ('descriptor', 32, 0)]:
        mutated = bytearray(source)
        mutated[offset] = value
        run(name, data=mutated, change={'sha256': hashlib.sha256(mutated).hexdigest()})
print(f'PASS {checks} offline packaging guard/copy assertions; no app packed or hardware accessed')
