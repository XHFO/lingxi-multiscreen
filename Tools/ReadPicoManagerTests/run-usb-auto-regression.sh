#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-usb-auto-regression)"
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, subprocess, sys
root = Path.cwd(); output = Path(sys.argv[1])
manager = root / 'Sources/LinxDisplayApp/ReadPicoManagerView.swift'
library = root / 'Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift'
core = [root / 'Sources/LinxDisplayCore' / name for name in (
    'ReadPicoUSBTransfer.swift', 'ReadPicoUSBWireless.swift', 'ReadPicoBoardRouting.swift',
    'ReadPicoPowerStatus.swift', 'ReadPicoManager.swift', 'ReadPicoLocalLibrary.swift',
    'ReadPicoUSBBoard.swift', 'ReadPicoSafeEject.swift', 'ReadPicoBundledApps.swift',
    'ReadPicoWeRead.swift', 'ReadPicoWeReadTF.swift')]
tests = [root / 'Tools/ReadPicoManagerTests' / name for name in ('USBModelTests.swift', 'USBOneClickModelTests.swift')]
origins = [manager, library] + core + tests
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
before = {str(path.relative_to(root)): digest(path) for path in origins}
sdk = subprocess.check_output([str(root / 'scripts/select-macos-sdk')], text=True).strip()
compiler = [str(root / 'scripts/swiftc-sdk-compat'), '-sdk', sdk, '-swift-version', '5']
subprocess.run(compiler + ['-emit-library', '-emit-module', '-module-name', 'LinxDisplayCore'] +
               [str(path) for path in core] + ['-emit-module-path', str(output / 'LinxDisplayCore.swiftmodule'),
                                              '-o', str(output / 'libLinxDisplayCore.dylib')], check=True)
# Compile the unchanged production model, excluding its unrelated SwiftUI file
# view. This matches the existing one-click/lifecycle model test harnesses.
prefix = manager.read_text().split('struct ReadPicoManagerView: View {', 1)[0] + '\n' + \
         library.read_text().split('@MainActor final class ReadPicoLocalLibraryModel', 1)[0]
for test in tests:
    source = output / (test.stem + '-bound.swift'); executable = output / test.stem
    source.write_text(prefix + '\n' + test.read_text())
    subprocess.run(compiler + ['-parse-as-library', '-I', str(output), '-L', str(output), '-lLinxDisplayCore',
                               '-Xlinker', '-rpath', '-Xlinker', str(output), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
assert before == {str(path.relative_to(root)): digest(path) for path in origins}, 'Source changed during regression run'
print('PASS: both USB model suites bound to unchanged production sources; no hardware or user configuration accessed.')
PY
