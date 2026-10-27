#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-canvas-pair}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve()
inputs=[root/name for name in ('Sources/LinxDisplayCore/ReadPicoPowerStatus.swift','Sources/LinxDisplayCore/ReadPicoManager.swift','Tools/ReadPicoManagerTests/CanvasPairTests.swift')]
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):digest(p) for p in inputs}
sdk=subprocess.check_output([str(root/'scripts/select-macos-sdk')],text=True).strip()
subprocess.run([str(root/'scripts/swiftc-sdk-compat'),'-sdk',sdk,'-swift-version','5','-parse-as-library',*[str(p) for p in inputs],'-o',str(output/'tests')],check=True)
result=subprocess.run([str(output/'tests')],check=True,capture_output=True,text=True)
print(result.stdout,end='')
assert before=={str(p.relative_to(root)):digest(p) for p in inputs},'Source changed during pair tests'
(output/'results.log').write_text(result.stdout)
(output/'source-binding.json').write_text(json.dumps({'result':'PASS','scope':'Production pair model, bitmap encoder and HTTP client, injected URLProtocol; no device, account, network or user settings.','source_sha256':before,'test_binary_sha256':digest(output/'tests')},indent=2)+'\n')
PY
