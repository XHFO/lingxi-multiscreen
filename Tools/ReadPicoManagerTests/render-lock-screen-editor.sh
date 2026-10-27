#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-lock-screen-editor-render}"
configuration="${2:-Debug}"
mkdir -p "$output"
python3 - "$output" "$configuration" <<'PY'
from pathlib import Path
import hashlib,json,shlex,subprocess,sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve(); config=sys.argv[2]
objects=root/f'.build/out/Intermediates.noindex/LinxDisplay.build/{config}/LinxDisplayApp-p.build/Objects-normal/arm64'
products=root/f'.build/out/Products/{config}'
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
args=[str(root/'scripts/swiftc-sdk-compat'),'-parse-as-library','-swift-version','5','-module-name','ReadPicoLockScreenUIRender','-sdk',sdk,'-target','arm64-apple-macosx26.0','-Xfrontend','-disable-access-control','-I',str(objects),'-I',str(products),'-Xcc',f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/{config}/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap','-Xcc',f'-I{root}/Sources/C6DisplayRenderer/include']
sources=['ReadPicoLockScreenView.swift','ReadPicoLockScreenDraft.swift','ReadPicoLockScreenRenderer.swift','ReadPicoDraftGuard.swift','ReadPicoUSBConnectionPanel.swift']
if config == 'Release':
    # WMO removes internal App symbols; compile the same actual UI sources in the
    # fixture module and bind their hashes to the successful production build.
    sources += ['ReadPicoCanvasDraft.swift','ReadPicoManagementWebView.swift','ReadPicoBundledAppsView.swift','ReadPicoLocalLibraryView.swift','ReadPicoUSBConnectionPanel.swift','ReadPicoManagerView.swift']
    fixture=output/'LockScreenEditorRender.swift'
    fixture.write_text((root/'Tools/ReadPicoManagerTests/LockScreenEditorRender.swift').read_text().replace('import LinxDisplayApp\n',''))
    args += [str(root/'Sources/LinxDisplayApp'/s) for s in sources] + [str(fixture),str(products/'LinxDisplayCore.o'),str(products/'C6DisplayRenderer.o')]
else:
    args += [str(root/'Tools/ReadPicoManagerTests/LockScreenEditorRender.swift')]
    args += shlex.split((objects/'LinxDisplayApp.LinkFileList').read_text())
args+=['-Xlinker','-e','-Xlinker','_readpico_lock_screen_editor_render_main','-o',str(output/'render')]
(output/'compile-command.json').write_text(json.dumps(args,indent=2))
(output/'source.json').write_text(json.dumps({s:hashlib.sha256((root/'Sources/LinxDisplayApp'/s).read_bytes()).hexdigest() for s in sources},indent=2))
subprocess.run(args,check=True);subprocess.run([str(output/'render'),str(output/'screens')],check=True)
PY
