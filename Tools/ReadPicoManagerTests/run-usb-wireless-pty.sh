#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-$(mktemp -d -t readpico-usb-wireless-pty-tests)}"
if [ "$#" -eq 0 ]; then trap 'rm -rf "$output"' EXIT; fi
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,re,subprocess,sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve()
sources=[root/p for p in [
    'Sources/LinxDisplayCore/ReadPicoPowerStatus.swift',
    'Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift',
    'Sources/LinxDisplayCore/ReadPicoUSBWireless.swift',
    'Tools/ReadPicoManagerTests/USBWirelessPTYTests.swift',
]]
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):digest(p) for p in sources}
sdk=subprocess.check_output([str(root/'scripts/select-macos-sdk')],text=True).strip()
command=[str(root/'scripts/swiftc-sdk-compat'),'-sdk',sdk,'-parse-as-library','-swift-version','5']+[str(p) for p in sources]+['-o',str(output/'tests')]
subprocess.run(command,check=True)
result=subprocess.run([str(output/'tests')],capture_output=True,text=True)
(output/'output.log').write_text(result.stdout+result.stderr)
print(result.stdout,end=''); print(result.stderr,end='',file=sys.stderr)
assert result.returncode==0,'PTY suite failed; see output.log'
assert before=={str(p.relative_to(root)):digest(p) for p in sources},'Source changed during PTY validation'
counts=re.search(r'USB wireless PTY: (\d+) checks passed across (\d+) real private-PTY exchanges',result.stdout)
assert counts,'Missing native test summary'
(output/'report.json').write_text(json.dumps({
    'result':'PASS','checks':int(counts[1]),'private_pty_exchanges':int(counts[2]),
    'source_sha256':before,'binary_sha256':digest(output/'tests'),
    'scope':'Unmodified production native PICO_WIFI1 POSIX exchange against generated private PTYs only. No physical serial discovery/opening, mounted volume, App or user settings.',
},indent=2)+'\n')
PY
