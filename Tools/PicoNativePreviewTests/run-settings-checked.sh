#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/pico-settings-checked-20261024}"
configuration="${2:-Release}"
mkdir -p "$output"
python3 - "$output" "$configuration" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root = Path.cwd(); output = Path(sys.argv[1]).resolve(); configuration = sys.argv[2]
products = root/'.build/out/Products'/configuration
source = root/'Sources/LinxDisplayCore/SettingsStore.swift'
test = root/'Tools/PicoNativePreviewTests/SettingsStoreCheckedTests.swift'
runner = root/'Tools/PicoNativePreviewTests/run-settings-checked.sh'
objects = [products/'LinxDisplayCore.o', products/'C6DisplayRenderer.o']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
tracked = [source, test, runner] + objects
before = {str(p.relative_to(root)): sha(p) for p in tracked}
symbols = subprocess.check_output(['nm', '-gU', str(objects[0])], text=True)
assert 'SettingsStoreC11saveChecked' in symbols, 'Current Core object does not export saveChecked; wait for the new Core build'
# Match the SDK of the current Release module instead of independently selecting a fallback SDK.
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
args = [str(root/'scripts/swiftc-sdk-compat'), '-parse-as-library', '-swift-version', '5', '-sdk', sdk,
        '-target', 'arm64-apple-macosx26.0', '-I', str(products), '-Xcc', f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/{configuration}/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap',
        '-Xcc', f'-I{root}/Sources/C6DisplayRenderer/include', str(test)] + [str(p) for p in objects] + ['-o', str(output/'tests')]
(output/'compile-command.json').write_text(json.dumps(args, indent=2)+'\n')
subprocess.run(args, check=True)
result = subprocess.run([str(output/'tests'), str(output)], capture_output=True, text=True)
(output/'settings-checked-tests.txt').write_text(result.stdout + result.stderr)
print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
result.check_returncode()
assert before == {str(p.relative_to(root)): sha(p) for p in tracked}, 'Source or linked Core object changed during testing'
(output/'source-binding.json').write_text(json.dumps({'result': 'PASS', 'configuration': configuration,
    'sha256': before, 'scope': 'Actual production Release SettingsStore.saveChecked/encode/atomic write/load. All inputs and file obstructions are in a unique temporary directory; no live app, user settings, network or device.'}, indent=2)+'\n')
PY
