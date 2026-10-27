#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-board-session}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root = Path.cwd(); output = Path(sys.argv[1]).resolve()
manager = root/'Sources/LinxDisplayApp/ReadPicoManagerView.swift'
board = root/'Sources/LinxDisplayApp/ReadPicoLingxiBoardView.swift'
library = root/'Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift'
origins = [manager, board, root/'Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift', root/'Sources/LinxDisplayApp/ReadPicoBoardModuleOrder.swift', library, root/'Sources/LinxDisplayApp/ReadPicoBoardRefreshPolicy.swift']
board_support = [root/'Sources/LinxDisplayApp'/name for name in ('ReadPicoBoardPlaylist.swift', 'ReadPicoBoardCarouselCursor.swift')]
models = root/'Sources/LinxDisplayCore/Models.swift'
renderer = root/'Sources/LinxDisplayApp/ReadPicoLingxiBoardRenderer.swift'
core = [root/'Sources/LinxDisplayCore'/name for name in ('ReadPicoUSBTransfer.swift', 'ReadPicoUSBWireless.swift', 'ReadPicoBoardRouting.swift', 'ReadPicoManager.swift', 'ReadPicoLocalLibrary.swift', 'ReadPicoUSBBoard.swift', 'ReadPicoSafeEject.swift', 'ReadPicoBundledApps.swift', 'ReadPicoPowerStatus.swift')]
origins += core + board_support + [models, renderer, root/'Tools/ReadPicoManagerTests/BoardSessionTests.swift']
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): digest(p) for p in origins}
(output/'ManagerModel.swift').write_text(manager.read_text().split('struct ReadPicoManagerView: View {', 1)[0])
(output/'BoardSession.swift').write_text(board.read_text().split('/// The reader board follows Oracle', 1)[0])
(output/'LibrarySyncCounter.swift').write_text(library.read_text().split('@MainActor final class ReadPicoLocalLibraryModel', 1)[0])
(output/'RendererResult.swift').write_text(renderer.read_text().split('    @MainActor static func render(', 1)[0] + '}\n')
model_source = models.read_text()
start = model_source.index('public enum CanvasModule:')
end = model_source.index('/// 键盘独立番茄钟卡片的刷新对齐策略。', start)
(output/'CanvasModule.swift').write_text('import Foundation\n' + model_source[start:end])
sdk = subprocess.check_output([str(root/'scripts/select-macos-sdk')], text=True).strip()
compiler = [str(root/'scripts/swiftc-sdk-compat'), '-sdk', sdk, '-swift-version', '5']
subprocess.run(compiler + ['-emit-library', '-emit-module', '-module-name', 'LinxDisplayCore'] + [str(p) for p in core] + [str(output/'CanvasModule.swift'), '-emit-module-path', str(output/'LinxDisplayCore.swiftmodule'), '-o', str(output/'libLinxDisplayCore.dylib')], check=True)
subprocess.run(compiler + ['-parse-as-library', '-I', str(output), '-L', str(output), '-lLinxDisplayCore', '-Xlinker', '-rpath', '-Xlinker', str(output), str(output/'ManagerModel.swift'), str(output/'BoardSession.swift'), str(output/'LibrarySyncCounter.swift'), str(output/'RendererResult.swift'), str(origins[2]), str(origins[3]), str(origins[5])] + [str(p) for p in board_support] + [str(root/'Tools/ReadPicoManagerTests/BoardSessionTests.swift'), '-o', str(output/'tests')], check=True)
subprocess.run([str(output/'tests')], check=True)
assert before == {str(p.relative_to(root)): digest(p) for p in origins}, 'Source changed during test run'
(output/'source-binding.json').write_text(json.dumps({'result':'PASS', 'source_sha256':before, 'scope':'Unmodified production Session and ManagerModel prefixes plus actual CanvasDraft and transport; renderer Result schema and device are test fixtures. No network, user settings or hardware.'}, indent=2)+'\n')
PY
