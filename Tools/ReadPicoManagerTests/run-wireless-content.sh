#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${1:-$PWD/.build/readpico-wireless-content-tests}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
core=(Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift Sources/LinxDisplayCore/ReadPicoBoardRouting.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBundledApps.swift)
app=(Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoDraftGuard.swift Sources/LinxDisplayApp/ReadPicoManagementWebView.swift Sources/LinxDisplayApp/ReadPicoBundledAppsView.swift Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift Sources/LinxDisplayApp/ReadPicoUSBConnectionPanel.swift Sources/LinxDisplayApp/ReadPicoManagerView.swift)
tests=(Tools/ReadPicoManagerTests/WirelessContentHTTPTests.swift Tools/ReadPicoManagerTests/WirelessContentModelTests.swift Tools/ReadPicoManagerTests/wireless-content-http.py Tools/ReadPicoManagerTests/run-wireless-content.sh)
python3 - "$output/sources-before.json" "${core[@]}" "${app[@]}" "${tests[@]}" <<'PY'
import hashlib,json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in sys.argv[2:]},sort_keys=True,indent=2)+'\n')
PY
swiftc -parse-as-library -swift-version 5 "${core[@]}" Tools/ReadPicoManagerTests/WirelessContentHTTPTests.swift -o "$output/http-tests"
python3 Tools/ReadPicoManagerTests/wireless-content-http.py "$output/http-tests" "$output/http-report.json" | tee "$output/http.log"
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore "${core[@]}" -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" "${app[@]}" Tools/ReadPicoManagerTests/WirelessContentModelTests.swift -o "$output/model-tests"
"$output/model-tests" | tee "$output/model.log"
python3 - "$output" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); before=json.loads((root/'sources-before.json').read_text())
after={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in before}
(root/'sources-after.json').write_text(json.dumps(after,sort_keys=True,indent=2)+'\n')
assert before==after,'source changed during tests; rerun after edits settle'
evidence={'passed':True,'sources':after,'binaries':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'http-tests',root/'model-tests',root/'libLinxDisplayCore.dylib']},'http_report':hashlib.sha256((root/'http-report.json').read_bytes()).hexdigest(),'hardware':False}
(root/'binding.json').write_text(json.dumps(evidence,sort_keys=True,indent=2)+'\n')
print('PASS wireless tests are bound to unchanged production Core/Manager sources and actual test binaries')
PY
