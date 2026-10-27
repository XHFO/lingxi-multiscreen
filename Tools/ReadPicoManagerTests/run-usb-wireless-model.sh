#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-usb-wireless-model}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path.cwd();output=Path(sys.argv[1]).resolve()
manager=root/'Sources/LinxDisplayApp/ReadPicoManagerView.swift';library=root/'Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift';test=root/'Tools/ReadPicoManagerTests/USBWirelessModelTests.swift'
core=[root/'Sources/LinxDisplayCore'/n for n in ('ReadPicoUSBTransfer.swift','ReadPicoUSBWireless.swift','ReadPicoBoardRouting.swift','ReadPicoManager.swift','ReadPicoPowerStatus.swift','ReadPicoLocalLibrary.swift','ReadPicoUSBBoard.swift','ReadPicoSafeEject.swift','ReadPicoBundledApps.swift')]
origins=[manager,library,test,root/'Tools/ReadPicoManagerTests/run-usb-wireless-model.sh']+core;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(root)):sha(p) for p in origins}
(output/'ModelAndTests.swift').write_text(manager.read_text().split('struct ReadPicoManagerView: View {',1)[0]+'\n'+library.read_text().split('@MainActor final class ReadPicoLocalLibraryModel',1)[0]+'\n'+test.read_text())
sdk=subprocess.check_output([str(root/'scripts/select-macos-sdk')],text=True).strip();compiler=[str(root/'scripts/swiftc-sdk-compat'),'-sdk',sdk,'-swift-version','5']
subprocess.run(compiler+['-emit-library','-emit-module','-module-name','LinxDisplayCore']+[str(p) for p in core]+['-emit-module-path',str(output/'LinxDisplayCore.swiftmodule'),'-o',str(output/'libLinxDisplayCore.dylib')],check=True)
subprocess.run(compiler+['-parse-as-library','-I',str(output),'-L',str(output),'-lLinxDisplayCore','-Xlinker','-rpath','-Xlinker',str(output),str(output/'ModelAndTests.swift'),'-o',str(output/'tests')],check=True)
result=subprocess.run([str(output/'tests')],capture_output=True,text=True);(output/'tests.log').write_text(result.stdout+result.stderr);print(result.stdout+result.stderr,end='');result.check_returncode()
assert before=={str(p.relative_to(root)):sha(p) for p in origins},'Source changed during test'
(output/'source-binding.json').write_text(json.dumps({'result':'PASS','source_sha256':before,'binary_sha256':sha(output/'tests'),'scope':'Actual production USB wireless client seam/ManagerModel and BoardClient with injected HTTP/registry, private temporary TF. No physical USB,user App or user settings.'},indent=2)+'\n')
PY
