#!/usr/bin/env python3
"""Run the real Swift client against one new, disposable loopback firmware session.

Only simulator control requests drive its deterministic UI clock. Production Swift
requests still use the same authenticated management protocol as the physical Pico.
No physical device, existing preview session, cloud account or mounted TF is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[2]


def grayscale_png(raw):
    """Decode the simulator adapter's 8-bit grayscale, unfiltered PNG frames."""
    assert raw[:8] == b'\x89PNG\r\n\x1a\n'
    compressed = bytearray()
    width = height = 0
    offset = 8
    while offset < len(raw):
        length = struct.unpack_from('>I', raw, offset)[0]
        kind, payload = raw[offset + 4:offset + 8], raw[offset + 8:offset + 8 + length]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            assert (depth, color, compression, filtering, interlace) == (8, 0, 0, 0, 0)
        elif kind == b'IDAT':
            compressed.extend(payload)
        offset += 12 + length
    pixels = zlib.decompress(compressed)
    assert len(pixels) == (width + 1) * height
    rows = []
    for y in range(height):
        begin = y * (width + 1)
        assert pixels[begin] == 0
        rows.append(pixels[begin + 1:begin + 1 + width])
    return width, height, rows


def verify_canvas(frame, bmp, bottom_margin=80):
    width, height, rows = grayscale_png(frame)
    assert (width, height) == (684, 1216)
    assert struct.unpack_from('<ii', bmp, 18) == (width, height)
    stride = ((width + 31) // 32) * 4
    # The system draws status and gesture hints at the screen edges. Compare the
    # actual picture area pixel-for-pixel, including both black and white regions.
    compared = 0
    for y in range(80, height - bottom_margin):
        begin = 62 + (height - 1 - y) * stride
        for x in range(60, width - 60):
            bit = (bmp[begin + x // 8] >> (7 - x % 8)) & 1
            assert rows[y][x] == (255 if bit else 0), (x, y)
            compared += 1
    return compared


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, help='Existing native-preview HTTP server on loopback')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.base)
    if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        parser.error('--base must be a plain loopback HTTP origin; physical devices are refused')
    base = args.base.rstrip('/')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'result': 'RUNNING', 'hardware_access': False, 'existing_preview_modified': False,
              'cloud_credentials_used': False, 'checks': []}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    session = None
    key = None
    stop = threading.Event()
    errors = []
    worker = None

    def request(path, body=None, *, method=None, authenticated=False):
        headers = {}
        if authenticated:
            headers = {'X-Pico-Preview-Session': session, 'X-Pico-Setup-Key': key}
        if body is not None:
            headers['Content-Type'] = 'application/json'
            body = json.dumps(body).encode()
        with opener.open(urllib.request.Request(base + path, data=body, method=method, headers=headers), timeout=30) as response:
            data = response.read()
            return json.loads(data) if 'json' in response.headers.get('Content-Type', '') else data

    def command(**values):
        state = request('/api/command', {'session': session, **values})
        assert state['ok'], state.get('error')
        return state

    def tick():
        return command(action='tick', ms=command(action='status')['now_ms'] + 100)

    def tap(x, y):
        for phase in ('down', 'up'):
            state = command(action='touch', phase=phase, x=x, y=y, ms=command(action='status')['now_ms'] + 80)
        return state

    def pair():
        nonlocal key
        management = request('/api/manage-open', {'session': session})['management']
        assert management['active']
        key = urllib.parse.parse_qs(urllib.parse.urlsplit(management['url']).fragment)['key'][0]
        assert len(key) == 32

    def pump():
        while not stop.wait(0.1):
            try:
                tick()
            except Exception as error:
                errors.append(type(error).__name__)
                stop.set()

    def capture(name, expected, bottom_margin=80):
        state = command(action='status')
        assert state['route'] == 29, state['route_name']
        frame = request(state['image_url'])
        (output / name).write_bytes(frame)
        compared = verify_canvas(frame, expected, bottom_margin)
        return compared

    try:
        with tempfile.TemporaryDirectory(prefix='readpico-swift-native-') as temporary:
            temporary = Path(temporary)
            executable = temporary / 'integration'
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                            str(ROOT / 'Sources/LinxDisplayCore/ReadPicoPowerStatus.swift'),
                            str(ROOT / 'Sources/LinxDisplayCore/ReadPicoManager.swift'),
                            str(ROOT / 'Tools/ReadPicoManagerTests/NativeIntegration.swift'),
                            '-o', str(executable)], cwd=ROOT, check=True)
            state = request('/api/session', {})
            session = state['session']
            report['version'] = state['version']
            pair()
            initial = request('/api/manage/pico/status', authenticated=True)
            command(action='route', route=27)
            tap(80, 520)   # Add the registered computer-canvas entry to this private session.
            tap(130, 380)
            tap(300, 590)
            command(action='route', route=0)
            worker = threading.Thread(target=pump, daemon=True)
            worker.start()
            environment = {**os.environ, 'READ_PICO_MANAGE_URL': base + '/manage?session=' + session + '#key=' + key,
                           'READ_PICO_EXPECTED_BMP': str(temporary / 'expected.bmp'),
                           'READ_PICO_EXPECTED_LOCK_BMP': str(temporary / 'expected-lock.bmp')}
            completed = subprocess.run([str(executable)], env=environment, cwd=ROOT, capture_output=True, text=True, timeout=60)
            stop.set()
            worker.join(timeout=31)
            assert not errors, errors
            assert completed.returncode == 0, (completed.stdout, completed.stderr)
            report['client'] = completed.stdout.strip()
            expected = (temporary / 'expected.bmp').read_bytes()
            lock_expected = (temporary / 'expected-lock.bmp').read_bytes()
            assert lock_expected != expected
            (output / 'canvas-source.bmp').write_bytes(expected)
            (output / 'lock-source.bmp').write_bytes(lock_expected)
            displayed = request('/api/manage/pico/status', authenticated=True)
            assert displayed['canvas']['state'] == 'displayed'
            assert displayed['config']['state'] == 2 and displayed['config']['revision'] == initial['config']['revision'] + 4
            assert displayed['config']['lock_style'] == 4
            assert displayed['image_lock']['available'] and displayed['image_lock']['state'] == 'saved'
            assert request('/api/manage/pico/lock-image', authenticated=True) == lock_expected
            report['checks'].append('actual Swift HTTP client confirms same-value, changed and restored power commits')
            report['checks'].append('actual Swift BMP upload waits until native C presentation reports a new displayed revision')
            report['checks'].append('actual Swift saves a separate lock BMP, reads exact authenticated bytes and commits custom lock style without replacing the desktop canvas')
            report['compared_picture_pixels'] = capture('canvas-displayed.png', expected)
            request('/api/restart', {'session': session})
            try:
                request('/api/manage/pico/status', authenticated=True)
                raise AssertionError('old pairing survived restart')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            pair()
            restored = request('/api/manage/pico/status', authenticated=True)
            for name in ('auto_sleep_minutes', 'double_tap_wake'):
                assert restored['config'][name] == initial['config'][name]
            assert restored['config']['lock_style'] == 4 and restored['image_lock']['available']
            assert request('/api/manage/pico/lock-image', authenticated=True) == lock_expected
            command(action='route', route=0)
            tap(265, 48)
            assert request('/api/manage/pico/status', authenticated=True)['canvas']['state'] == 'displayed'
            assert capture('canvas-reopened-offline.png', expected) == report['compared_picture_pixels']
            report['checks'].append('restart revokes pairing, retains settings and reopens the saved TF canvas with identical picture pixels')
            locked = command(action='powerkey')
            assert locked['power_state'] == 1
            report['compared_lock_pixels'] = capture('custom-image-locked.png', lock_expected, bottom_margin=160)
            unlocked = command(action='powerkey')
            assert unlocked['power_state'] == 0
            report['checks'].append('restart retains separate TF lock BMP/style, and power-key lock displays the exact saved custom image before returning to the previous screen')
            report['bmp_sha256'] = hashlib.sha256(expected).hexdigest()
            report['lock_bmp_sha256'] = hashlib.sha256(lock_expected).hexdigest()
            report['result'] = 'PASS'
    except Exception as error:
        report['result'] = 'FAIL'
        report['failure_type'] = type(error).__name__
        raise
    finally:
        stop.set()
        if worker and worker.is_alive():
            worker.join(timeout=31)
        if session:
            try:
                request('/api/close', {'session': session})
            except Exception:
                pass
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(report['client'])
    print('PASS: native framebuffer matches %d BMP pixels before and after restart; no physical device modified.' % report['compared_picture_pixels'])


if __name__ == '__main__':
    main()
