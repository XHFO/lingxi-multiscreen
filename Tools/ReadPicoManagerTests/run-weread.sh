#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-weread-tests}"
mkdir -p "$output"
python3 - "$output" <<'PY'
import pathlib, hashlib, json, sys
paths = ['Sources/LinxDisplayCore/'+n+'.swift' for n in ['ReadPicoPowerStatus','ReadPicoManager','ReadPicoWeRead','ReadPicoWeReadTF']]
paths += ['Tools/ReadPicoManagerTests/WeReadTests.swift','Tools/ReadPicoManagerTests/run-weread.sh']
pathlib.Path(sys.argv[1], 'sources-before.json').write_text(json.dumps({p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths}, indent=2)+'\n')
PY
sdk="$(scripts/select-macos-sdk)"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoWeRead.swift Sources/LinxDisplayCore/ReadPicoWeReadTF.swift \
  Tools/ReadPicoManagerTests/WeReadTests.swift -o "$output/tests"
"$output/tests" "$output/swift-fixture" > "$output/checks.txt" 2>&1
cat "$output/checks.txt"
python3 - "$output" <<'PY'
import pathlib, hashlib, json, sys
out = pathlib.Path(sys.argv[1]); before = json.loads((out/'sources-before.json').read_text())
after = {p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in before}
assert before == after, 'source changed during test; rerun after edits settle'
report = {'result':'PASS','source_sha256':after,'test_binary_sha256':hashlib.sha256((out/'tests').read_bytes()).hexdigest(),
          'checks':(out/'checks.txt').read_text().strip(),'hardware_accessed':False,'account_accessed':False,
          'fixture_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (out/'swift-fixture').iterdir()}}
(out/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
PY
