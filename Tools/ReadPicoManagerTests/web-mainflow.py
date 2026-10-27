#!/usr/bin/env python3
"""Exercise the real device HTML in production WKWebView with a private offline native session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    url = urllib.parse.urlsplit(args.base)
    if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.path not in ('', '/') or url.query or url.fragment or url.username or url.password:
        parser.error('only a plain loopback origin is accepted')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = args.base.rstrip('/')
    def request(path, body=None, *, method=None, headers=None):
        data = None if body is None else json.dumps(body).encode()
        with opener.open(urllib.request.Request(base + path, data=data, method=method,
                         headers={'Content-Type': 'application/json', **(headers or {})}), timeout=30) as response:
            return json.load(response)
    session = None
    report = {'result': 'RUNNING', 'hardware_accessed': False, 'real_credentials_used': False,
              'existing_preview_modified': False, 'runner': 'production WKWebView + real native HTTP adapter'}
    try:
        state = request('/api/session', {})
        session = state['session']
        assert state['version'] == args.version
        management = request('/api/manage-open', {'session': session})['management']
        assert management['active']
        key = urllib.parse.parse_qs(urllib.parse.urlsplit(management['url']).fragment)['key'][0]
        request('/api/manage/home', {'enabled': False}, method='PUT',
                headers={'X-Pico-Preview-Session': session, 'X-Pico-Setup-Key': key})
        address = base + '/manage?session=' + session + '#' + urllib.parse.urlsplit(management['url']).fragment
        environment = {**os.environ, 'READ_PICO_WEB_TEST_URL': address, 'READ_PICO_WEB_TEST_OUTPUT': str(output)}
        run = subprocess.run(['sh', str(ROOT / 'Tools/ReadPicoManagerTests/run-web-mainflow.sh')],
                             cwd=ROOT, env=environment, text=True, capture_output=True, timeout=120)
        (output / 'run.log').write_text(run.stdout + run.stderr)
        assert run.returncode == 0, 'WKWebView main flow failed; inspect the local run log'
        assert 'RESULT PASS' in run.stdout
        report.update(result='PASS', version=args.version, assertions=run.stdout.count('PASS '),
                      snapshots={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.glob('*.png'))})
    except Exception as error:
        report.update(result='FAIL', error=type(error).__name__)
        raise
    finally:
        if session:
            request('/api/close', {'session': session})
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
