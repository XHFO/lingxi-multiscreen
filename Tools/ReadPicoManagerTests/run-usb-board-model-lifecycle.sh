#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-usb-board-model-lifecycle}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root = Path.cwd(); output = Path(sys.argv[1]).resolve()
manager = root/'Sources/LinxDisplayApp/ReadPicoManagerView.swift'
library = root/'Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift'
test = root/'Tools/ReadPicoManagerTests/USBBoardModelLifecycleTests.swift'
core = [root/'Sources/LinxDisplayCore'/name for name in ('ReadPicoUSBTransfer.swift','ReadPicoUSBWireless.swift','ReadPicoBoardRouting.swift', 'ReadPicoManager.swift', 'ReadPicoPowerStatus.swift', 'ReadPicoLocalLibrary.swift', 'ReadPicoUSBBoard.swift', 'ReadPicoSafeEject.swift', 'ReadPicoBundledApps.swift')]
origins = [manager, library, test] + core
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): digest(p) for p in origins}
(output/'ModelAndLifecycleTests.swift').write_text(manager.read_text().split('struct ReadPicoManagerView: View {', 1)[0] + '\n' + library.read_text().split('@MainActor final class ReadPicoLocalLibraryModel', 1)[0] + '\n' + test.read_text())
sdk = subprocess.check_output([str(root/'scripts/select-macos-sdk')], text=True).strip()
compiler = [str(root/'scripts/swiftc-sdk-compat'), '-sdk', sdk, '-swift-version', '5']
subprocess.run(compiler + ['-emit-library', '-emit-module', '-module-name', 'LinxDisplayCore'] + [str(p) for p in core] + ['-emit-module-path', str(output/'LinxDisplayCore.swiftmodule'), '-o', str(output/'libLinxDisplayCore.dylib')], check=True)
subprocess.run(compiler + ['-parse-as-library', '-Xfrontend', '-disable-access-control', '-I', str(output), '-L', str(output), '-lLinxDisplayCore', '-Xlinker', '-rpath', '-Xlinker', str(output), str(output/'ModelAndLifecycleTests.swift'), '-o', str(output/'tests')], check=True)
subprocess.run([str(output/'tests')], check=True)
assert before == {str(p.relative_to(root)): digest(p) for p in origins}, 'Source changed during test run'
(output/'source-binding.json').write_text(json.dumps({'result':'PASS', 'source_sha256':before, 'scope':'Unmodified production ManagerModel prefix and core module; module-local delayed USB board transport fixture. Compiler access-control override only awaits the exact old task. Temporary TF directories only; no hardware, network or user configuration.'}, indent=2)+'\n')
PY
