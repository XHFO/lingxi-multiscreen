#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-weread-phone-setup-tests}"
mkdir -p "$output"
python3 - "$output" <<'PY'
import pathlib, hashlib, json, sys
paths=['Sources/LinxDisplayCore/'+name+'.swift' for name in ['ReadPicoWeRead','ReadPicoWeReadPhoneSetupPage','ReadPicoWeReadPhoneSetupServer']]
paths += ['Tools/ReadPicoManagerTests/WeReadPhoneSetupTests.swift','Tools/ReadPicoManagerTests/run-weread-phone-setup.sh']
pathlib.Path(sys.argv[1],'sources-before.json').write_text(json.dumps({p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
PY
sdk="$(scripts/select-macos-sdk)"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoWeRead.swift Sources/LinxDisplayCore/ReadPicoWeReadPhoneSetupPage.swift \
  Sources/LinxDisplayCore/ReadPicoWeReadPhoneSetupServer.swift Tools/ReadPicoManagerTests/WeReadPhoneSetupTests.swift -o "$output/tests"
"$output/tests" "$output/phone-page.html" > "$output/checks.txt" 2>&1
cat "$output/checks.txt"
python3 - "$output" <<'PY'
import pathlib, hashlib, json, sys
out=pathlib.Path(sys.argv[1]); before=json.loads((out/'sources-before.json').read_text()); after={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in before}
assert before==after,'inputs changed; rerun after edits settle'
(out/'validation.json').write_text(json.dumps({'result':'PASS','source_sha256':after,'checks':(out/'checks.txt').read_text().strip(),'binary_sha256':hashlib.sha256((out/'tests').read_bytes()).hexdigest(),'loopback_only':True,'hardware_accessed':False,'account_accessed':False,'keychain_accessed':False},indent=2)+'\n')
PY
