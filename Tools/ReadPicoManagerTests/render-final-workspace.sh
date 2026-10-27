#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-final-workspace-ui}"
configuration="${2:-Debug}"
mkdir -p "$output"
python3 - "$output" "$configuration" <<'PY'
from pathlib import Path
import hashlib, json, shlex, subprocess, sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve(); config=sys.argv[2]
assert config == 'Debug', 'This fixture requires the final Debug objects; no SwiftPM or release substitute.'
objects=root/f'.build/out/Intermediates.noindex/LinxDisplay.build/{config}/LinxDisplayApp-p.build/Objects-normal/arm64'
products=root/f'.build/out/Products/{config}'
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
origins=[p for p in (root/'Sources').rglob('*') if p.is_file() and not p.is_symlink()]
origins += [root/'Tools/ReadPicoManagerTests/FinalWorkspaceUIRender.swift',root/'Tools/ReadPicoManagerTests/render-final-workspace.sh']
before={str(p.relative_to(root)):sha(p) for p in origins}
linked=shlex.split((objects/'LinxDisplayApp.LinkFileList').read_text())
linked_before={str(p):sha(p) for p in linked}
product=products/'LinxDisplayApp'; product_before=sha(product)
args=[str(root/'scripts/swiftc-sdk-compat'),'-parse-as-library','-swift-version','5','-module-name','ReadPicoFinalWorkspaceUIRender','-sdk',sdk,'-target','arm64-apple-macosx26.0','-Xfrontend','-disable-access-control','-I',str(objects),'-I',str(products),'-Xcc',f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/{config}/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap','-Xcc',f'-I{root}/Sources/C6DisplayRenderer/include',str(root/'Tools/ReadPicoManagerTests/FinalWorkspaceUIRender.swift'),*linked,'-Xlinker','-e','-Xlinker','_readpico_final_workspace_render_main','-o',str(output/'render')]
(output/'compile-command.json').write_text(json.dumps(args,indent=2))
subprocess.run(args,check=True)
subprocess.run([str(output/'render'),str(output/'screens')],check=True)
assert before=={str(p.relative_to(root)):sha(p) for p in origins},'Sources changed during render'
assert linked_before=={str(p):sha(p) for p in linked},'Linked Debug objects changed during render'
assert product_before==sha(product),'Debug product changed during render'
report=json.loads((output/'screens/report.json').read_text());assert report['result']=='PASS'
screens={p.name:sha(p) for p in sorted((output/'screens').glob('*.png'))}
assert len(screens)==len(report['screens'])
(output/'source-binding.json').write_text(json.dumps({'result':'PASS','source_sha256':before,'linked_objects':linked_before,'debug_product':str(product),'debug_product_sha256':product_before,'configuration':config,'native_ui_screens':len(screens),'screens':screens,'fixture_binary_sha256':sha(output/'render')},indent=2)+'\n')
PY
