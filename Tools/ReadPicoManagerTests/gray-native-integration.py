#!/usr/bin/env python3
"""中文：私有HTTP/TF会话中验证真实Swift灰阶编码、HTTP上传和C显示逐像素保真。
English: Verify actual Swift gray encoding/upload and C pixel presentation in a private HTTP/TF session.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import urllib.parse
import urllib.request
import zlib
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--base', help='Use only a new disposable session on this loopback preview; never stops the server')
    args = parser.parse_args()
    build = args.build.resolve()
    manifest = json.loads((build / 'native-preview-build.json').read_text())
    assert hashlib.sha256((build / 'native-preview').read_bytes()).hexdigest() == manifest['binary_sha256']
    source = Path(manifest['source_root'])
    module = None
    if args.base:
        parsed = urllib.parse.urlsplit(args.base)
        assert parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost', '::1') and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and parsed.path in ('', '/')
    else:
        # 冻结源位于build子目录，HTTP桥始终从当前项目位置读取。/ Frozen sources live under build; locate the HTTP bridge from the project root.
        outer = source
        while not (outer / 'outputs/firmware-preview/server.py').is_file() and outer != outer.parent:
            outer = outer.parent
        server_file = outer / 'outputs/firmware-preview/server.py'
        spec = importlib.util.spec_from_file_location('pico_gray_native_swift_server', server_file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.REPO = source
        module.BASELINE = {'version': manifest['version'], 'candidate': True, 'hardware_access': False}
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    report = {'result': 'RUNNING', 'hardware_access': False, 'existing_preview_modified': False,
              'native_binary_sha256': manifest['binary_sha256'], 'base': args.base or 'private-ephemeral-loopback', 'checks': []}
    core = ROOT / 'Sources/LinxDisplayCore/ReadPicoManager.swift'
    core_hash = hashlib.sha256(core.read_bytes()).hexdigest()
    old_offline = os.environ.get('RPICO_HOME_LINK_OFFLINE')
    os.environ['RPICO_HOME_LINK_OFFLINE'] = '1'
    try:
        with tempfile.TemporaryDirectory(prefix='readpico-swift-gray-native-') as temp:
            temp = Path(temp)
            if module is not None:
                module.BUILD = temp / 'native'
                module.BUILD.mkdir()
                shutil.copy2(build / 'native-preview', module.BUILD / 'native-preview')
                for name in ('game-packages', 'tool-packages'):
                    shutil.copytree(build / name, module.BUILD / name)
            executable = temp / 'gray-integration'
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(ROOT / 'Sources/LinxDisplayCore/ReadPicoPowerStatus.swift'), str(core),
                            str(ROOT / 'Tools/ReadPicoManagerTests/GrayNativeIntegration.swift'), '-o', str(executable)], check=True, cwd=ROOT)
            assert hashlib.sha256(core.read_bytes()).hexdigest() == core_hash, 'Core changed while compiling; rerun'
            server = server_thread = None
            if module is not None:
                server = ThreadingHTTPServer(('127.0.0.1', 0), module.Handler)
                module.MANAGEMENT_PORT = server.server_port
                server_thread = threading.Thread(target=server.serve_forever, daemon=True)
                server_thread.start()
                base = 'http://127.0.0.1:' + str(server.server_port)
            else:
                base = args.base.rstrip('/')
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            sid = key = None
            def request(path, body=None, authenticated=False):
                headers = {'Content-Type': 'application/json'} if body is not None else {}
                if authenticated:
                    headers.update({'X-Pico-Setup-Key': key, 'X-Pico-Preview-Session': sid})
                raw = json.dumps(body).encode() if body is not None else None
                with opener.open(urllib.request.Request(base + path, data=raw, headers=headers), timeout=45) as response:
                    data = response.read()
                    return json.loads(data) if 'json' in response.headers.get('Content-Type', '') else data
            def command(**values):
                result = request('/api/command', {'session': sid, **values})
                assert result['ok']
                return result
            def tick():
                return command(action='tick', ms=command(action='status')['now_ms'] + 100)
            def verify(expected, name):
                state = command(action='status')
                assert state['route'] == 29
                png = request(state['image_url'])
                (output / (name + '.png')).write_bytes(png)
                pgm = ((module.SESSIONS[sid].frame) if module is not None else (build / 'sessions' / sid / 'frame.pgm')).read_bytes()
                import re
                match = re.match(rb'P5\s+(\d+)\s+(\d+)\s+255\s', pgm)
                sw, sh = map(int, match.groups())
                pixels = pgm[match.end():]
                assert png[:8] == b'\x89PNG\r\n\x1a\n'
                png_at, compressed = 8, bytearray()
                while png_at < len(png):
                    count = struct.unpack_from('>I', png, png_at)[0]
                    kind, payload = png[png_at + 4:png_at + 8], png[png_at + 8:png_at + 8 + count]
                    if kind == b'IHDR':
                        pw, ph, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', payload)
                        assert (pw, ph, depth, color, comp, filt, interlace) == (sw, sh, 8, 0, 0, 0, 0)
                    elif kind == b'IDAT':
                        compressed.extend(payload)
                    png_at += count + 12
                decoded = zlib.decompress(compressed)
                assert len(decoded) == (sw + 1) * sh
                png_pixels = bytearray()
                for row in range(sh):
                    begin = row * (sw + 1)
                    assert decoded[begin] == 0
                    png_pixels.extend(decoded[begin + 1:begin + 1 + sw])
                assert bytes(png_pixels) == pixels, 'HTTP PNG differs from the actual native framebuffer'
                iw, ih = struct.unpack_from('<ii', expected, 18)
                top_first = ih < 0
                ih = abs(ih)
                stride = ((iw * 4 + 31) // 32) * 4
                w, h = sw, sw * ih // iw
                if h > sh:
                    h, w = sh, sh * iw // ih
                left, top = (sw - w) // 2, (sh - h) // 2
                compared = 0
                levels = set()
                for y in range(80, sh - 80):
                    for x in range(80, sw - 80):
                        gray = 255
                        if left <= x < left + w and top <= y < top + h:
                            sx, sy = (x - left) * iw // w, (y - top) * ih // h
                            row = sy if top_first else ih - 1 - sy
                            index = (expected[118 + row * stride + sx // 2] >> (0 if sx % 2 else 4)) & 15
                            gray = expected[54 + index * 4]
                            levels.add(gray)
                        assert pixels[y * sw + x] == gray, (name, x, y, pixels[y * sw + x], gray)
                        compared += 1
                assert levels == set(range(0, 256, 17)), levels
                return {'orientation': [sw, sh], 'compared_pixels': compared, 'levels': sorted(levels)}
            try:
                state = request('/api/session', {})
                sid = state['session']
                report['version'] = state['version']
                assert state['version'] == manifest['version'], 'HTTP server version does not match the verified native build'
                report['disposable_session'] = sid
                management = request('/api/manage-open', {'session': sid})['management']
                key = urllib.parse.parse_qs(urllib.parse.urlsplit(management['url']).fragment)['key'][0]
                # 使用生产导航注册入口；不修改其它已存在的预览会话。/ Use the production registered route, without existing sessions.
                command(action='route', route=0)
                results = []
                for w, h in ((684, 1216), (1216, 684)):
                    for variant in ('canonical', 'top-reverse'):
                        stop = threading.Event()
                        errors = []
                        def pump():
                            while not stop.wait(0.1):
                                try:
                                    tick()
                                except Exception as error:
                                    errors.append(type(error).__name__)
                                    stop.set()
                        worker = threading.Thread(target=pump, daemon=True)
                        worker.start()
                        name = str(w) + '-' + variant
                        target = output / (name + '.bmp')
                        env = {**os.environ, 'READ_PICO_MANAGE_URL': base + '/manage?session=' + sid + '#key=' + key,
                               'READ_PICO_GRAY_WIDTH': str(w), 'READ_PICO_GRAY_HEIGHT': str(h),
                               'READ_PICO_GRAY_VARIANT': variant, 'READ_PICO_EXPECTED_BMP': str(target)}
                        try:
                            completed = subprocess.run([str(executable)], cwd=ROOT, env=env, text=True, capture_output=True, timeout=40)
                        finally:
                            stop.set()
                            worker.join(timeout=45)
                        assert not errors, errors
                        assert completed.returncode == 0, (completed.stdout, completed.stderr)
                        status = request('/api/manage/pico/status', authenticated=True)
                        assert status['canvas']['state'] == 'displayed'
                        bmp = target.read_bytes()
                        assert len(bmp) == (418422 if w == 684 else 415990)
                        assert (((module.SESSIONS[sid].root) if module is not None else (build / 'sessions' / sid)) / 'tf/readpico/desktop/canvas.bmp').read_bytes() == bmp
                        result = {'client': completed.stdout.strip(), 'bytes': len(bmp), 'variant': variant, 'source': [w, h], 'screens': []}
                        for landscape in (0, 1):
                            command(action='rotate', landscape=landscape)
                            result['screens'].append(verify(bmp, name + ('-landscape' if landscape else '-portrait')))
                        command(action='rotate', landscape=0)
                        results.append(result)
                report['checks'] = results
                report['core_sha256'] = core_hash
                assert hashlib.sha256(core.read_bytes()).hexdigest() == core_hash, 'Core changed during run; rerun'
                report['result'] = 'PASS'
            finally:
                if sid:
                    request('/api/close', {'session': sid})
                if server is not None:
                    server.shutdown()
                    server.server_close()
                    server_thread.join(timeout=5)
                if module is not None:
                    for session in list(module.SESSIONS.values()):
                        session.close()
    finally:
        if old_offline is None:
            os.environ.pop('RPICO_HOME_LINK_OFFLINE', None)
        else:
            os.environ['RPICO_HOME_LINK_OFFLINE'] = old_offline
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
