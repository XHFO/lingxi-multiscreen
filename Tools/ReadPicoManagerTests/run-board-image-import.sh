#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-board-image-import}"
configuration="${2:-Debug}"
mkdir -p "$output"
python3 - "$output" "$configuration" <<'PY'
from pathlib import Path
import hashlib,json,shlex,subprocess,sys
root=Path.cwd();output=Path(sys.argv[1]).resolve();config=sys.argv[2]
objects=root/f'.build/out/Intermediates.noindex/LinxDisplay.build/{config}/LinxDisplayApp-p.build/Objects-normal/arm64';products=root/f'.build/out/Products/{config}'
source=root/'Sources/LinxDisplayApp/ReadPicoLingxiBoardView.swift';fixture=output/'ProductionBoardView.swift'
origins=[source,root/'Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift',root/'Sources/LinxDisplayApp/ReadPicoManagerView.swift',root/'Sources/LinxDisplayApp/ReadPicoLingxiBoardRenderer.swift',root/'Tools/ReadPicoManagerTests/BoardImageImportTests.swift',root/'Tools/ReadPicoManagerTests/run-board-image-import.sh']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(root)):sha(p) for p in origins}
fixture.write_text('import LinxDisplayApp\n'+source.read_text()+'\nextension ReadPicoLingxiBoardView { func importImageForTesting(from url: URL) -> Bool { loadImage(from: url) } }\n')
# Match the SDK recorded by the linked Debug modules, as the native UI fixture does.
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
args=[str(root/'scripts/swiftc-sdk-compat'),'-parse-as-library','-swift-version','5','-module-name','ReadPicoBoardImageImportTests','-sdk',sdk,'-target','arm64-apple-macosx26.0','-Xfrontend','-disable-access-control','-I',str(objects),'-I',str(products),'-Xcc',f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/{config}/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap','-Xcc',f'-I{root}/Sources/C6DisplayRenderer/include',str(origins[-2]),str(fixture)]
linked=shlex.split((objects/'LinxDisplayApp.LinkFileList').read_text());args+=linked
linked_before={str(p):sha(Path(p)) for p in linked};product_before=sha(products/'LinxDisplayApp')
args+=['-Xlinker','-e','-Xlinker','_readpico_board_image_import_tests_main','-o',str(output/'tests')]
(output/'compile-command.json').write_text(json.dumps(args,indent=2)+'\n')
subprocess.run(args,check=True);subprocess.run([str(output/'tests'),str(output)],check=True)
assert before=={str(p.relative_to(root)):sha(p) for p in origins},'Production/test source drift'
assert linked_before=={str(p):sha(Path(p)) for p in linked} and product_before==sha(products/'LinxDisplayApp'),'Debug product changed during test'
report=json.loads((output/'report.json').read_text());assert report['result']=='PASS'
(output/'source-binding.json').write_text(json.dumps(dict(result='PASS',source_sha256=before,linked_objects=linked_before,debug_product_sha256=product_before,scope='Actual production BoardView file/decode/import method and actual CanvasDraft save/load/render linked from current Debug product; no dialogs, physical device, network or user settings.'),indent=2)+'\n')
PY
