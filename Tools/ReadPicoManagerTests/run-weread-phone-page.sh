#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
python3 - "${1:-.build/readpico-weread-phone-page}" <<'PY'
from pathlib import Path
import hashlib, http.server, json, subprocess, sys, threading
root = Path.cwd(); out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
paths = ['Sources/LinxDisplayCore/ReadPicoWeReadPhoneSetupPage.swift',
         'Tools/ReadPicoManagerTests/WeReadPhonePageTests.swift',
         'Tools/ReadPicoManagerTests/run-weread-phone-page.sh']
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
before = {p: sha(root/p) for p in paths}
page = (root/paths[0]).read_text().split('#"""', 1)[1].rsplit('"""#', 1)[0].strip().encode()
(out/'phone-page.html').write_bytes(page)
sdk = subprocess.check_output([str(root/'scripts/select-macos-sdk')], text=True).strip()
command = [str(root/'scripts/swiftc-sdk-compat'), '-sdk', sdk, '-parse-as-library', '-swift-version', '5',
           str(root/paths[1]), '-o', str(out/'phone-page-tests')]
with (out/'compile.stdout.log').open('w') as stdout, (out/'compile.stderr.log').open('w') as stderr:
    subprocess.run(command, check=True, stdout=stdout, stderr=stderr)
class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?', 1)[0] != '/': self.send_error(404); return
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page))); self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(page)
    def log_message(self, *_): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with (out/'run.stdout.log').open('w') as stdout, (out/'run.stderr.log').open('w') as stderr:
        subprocess.run([str(out/'phone-page-tests'), f'http://127.0.0.1:{server.server_port}', str(out/'screens')], check=True, timeout=90, stdout=stdout, stderr=stderr)
finally: server.shutdown(); server.server_close()
after = {p: sha(root/p) for p in paths}; assert before == after, 'production page/test source changed during run'
report = json.loads((out/'screens/report.json').read_text()); assert report['result'] == 'PASS'
binding = {'result': 'PASS', 'source_sha256': after, 'html_sha256': hashlib.sha256(page).hexdigest(),
           'binary_sha256': sha(out/'phone-page-tests'), 'checks': report['checks'],
           'screenshots': {p.name: sha(p) for p in (out/'screens').glob('*.png')},
           'real_credentials_used': False, 'real_account_accessed': False, 'hardware_accessed': False}
(out/'source-binding.json').write_text(json.dumps(binding, ensure_ascii=False, indent=2)+'\n')
print((out/'run.stdout.log').read_text().strip()); print(out/'source-binding.json')
PY
