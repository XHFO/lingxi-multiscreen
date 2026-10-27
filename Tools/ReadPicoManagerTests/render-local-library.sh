#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-local-library-render}"
configuration="${2:-Debug}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
Tools/ReadPicoManagerTests/run-local-library-ui.sh "$output"
python3 - "$output" "$configuration" <<'PY'
from pathlib import Path
import hashlib,json,shlex,shutil,subprocess,sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve(); config=sys.argv[2]
objects=root/f'.build/out/Intermediates.noindex/LinxDisplay.build/{config}/LinxDisplayApp-p.build/Objects-normal/arm64'
products=root/f'.build/out/Products/{config}'
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
source=root/'Tools/ReadPicoManagerTests/LocalLibraryRender.swift'
fixture=output/'ProductionLibraryRender.swift'
fixture.write_text('import LinxDisplayApp\n'+source.read_text().replace('@main struct LocalLibraryRender','struct LocalLibraryRender')+'''
@MainActor @_cdecl("readpico_local_library_render_main")
func localLibraryRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in
        do { try await LocalLibraryRender.main(); exit(0) } catch { print("Library render failed: \\(error)"); exit(1) }
    }
    app.run(); return 0
}
''')
args=[str(root/'scripts/swiftc-sdk-compat'),'-parse-as-library','-swift-version','5','-module-name','ReadPicoLocalLibraryUIRender','-sdk',sdk,'-target','arm64-apple-macosx26.0','-Xfrontend','-disable-access-control','-I',str(objects),'-I',str(products),'-Xcc',f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/{config}/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap','-Xcc',f'-I{root}/Sources/C6DisplayRenderer/include',str(fixture)]
args+=shlex.split((objects/'LinxDisplayApp.LinkFileList').read_text())
args+=['-Xlinker','-e','-Xlinker','_readpico_local_library_render_main','-o',str(output/'render')]
(output/'compile-command.json').write_text(json.dumps(args,indent=2))
sources=['ReadPicoLocalLibraryView.swift','ReadPicoManagerView.swift','ReadPicoLockScreenView.swift','ReadPicoLockScreenDraft.swift','ReadPicoLockScreenRenderer.swift','ReadPicoDraftGuard.swift','ReadPicoUSBConnectionPanel.swift']
(output/'source.json').write_text(json.dumps({s:hashlib.sha256((root/'Sources/LinxDisplayApp'/s).read_bytes()).hexdigest() for s in sources},indent=2))
subprocess.run(args,check=True)
shutil.copytree(root/'Resources/Firmware/ReadPico',output/'Firmware/ReadPico',dirs_exist_ok=True)
subprocess.run([str(output/'render'),str(output/'screens')],check=True)
PY
