#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-usb-weread-ui}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, shlex, subprocess, sys
root = Path.cwd(); output = Path(sys.argv[1]).resolve()
objects = root / '.build/out/Intermediates.noindex/LinxDisplay.build/Debug/LinxDisplayApp-p.build/Objects-normal/arm64'
products = root / '.build/out/Products/Debug'
origins = [root / name for name in ('Sources/LinxDisplayApp/ReadPicoFirmwareView.swift',
    'Sources/LinxDisplayApp/ReadPicoWeReadView.swift', 'Sources/LinxDisplayCore/ReadPicoFirmwareUSBRecovery.swift',
    'Tools/ReadPicoManagerTests/USBWeReadUIRender.swift', 'Tools/ReadPicoManagerTests/render-usb-weread-ui.sh')]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
before = {str(p.relative_to(root)): sha(p) for p in origins}
for name in ('ReadPicoFirmwareView', 'ReadPicoWeReadView'):
    assert (objects / (name + '.o')).stat().st_mtime >= (root / 'Sources/LinxDisplayApp' / (name + '.swift')).stat().st_mtime, 'Rebuild Debug after the injected initializer changes.'
linked = shlex.split((objects / 'LinxDisplayApp.LinkFileList').read_text())
linked_before = {str(p): sha(p) for p in linked}
product = products / 'LinxDisplayApp'; product_before = sha(product)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
args = [str(root / 'scripts/swiftc-sdk-compat'), '-parse-as-library', '-swift-version', '5',
    '-module-name', 'ReadPicoUSBWeReadUIRender', '-sdk', sdk, '-target', 'arm64-apple-macosx26.0',
    '-Xfrontend', '-disable-access-control', '-I', str(objects), '-I', str(products),
    '-Xcc', f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/Debug/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap',
    '-Xcc', f'-I{root}/Sources/C6DisplayRenderer/include',
    str(root / 'Tools/ReadPicoManagerTests/USBWeReadUIRender.swift'), *linked,
    '-Xlinker', '-e', '-Xlinker', '_readpico_usb_weread_render_main', '-o', str(output / 'render')]
(output / 'compile-command.json').write_text(json.dumps(args, indent=2))
subprocess.run(args, check=True)
subprocess.run([str(output / 'render'), str(output / 'screens')], check=True)
assert before == {str(p.relative_to(root)): sha(p) for p in origins}, 'Source changed during native rendering'
assert linked_before == {str(p): sha(p) for p in linked}, 'Debug objects changed during rendering'
assert product_before == sha(product), 'Debug product changed during rendering'
report = json.loads((output / 'screens/report.json').read_text()); assert report['result'] == 'PASS'
screens = {p.name: sha(p) for p in sorted((output / 'screens').glob('*.png'))}
assert len(screens) == len(report['screens'])
(output / 'source-binding.json').write_text(json.dumps({'result': 'PASS', 'source_sha256': before,
    'linked_objects': linked_before, 'debug_product_sha256': product_before,
    'native_ui_screens': screens, 'fixture_binary_sha256': sha(output / 'render')}, indent=2) + '\n')
PY
