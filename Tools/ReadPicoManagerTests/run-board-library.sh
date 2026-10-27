#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-board-library-tests)"
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PYENUM'
from pathlib import Path
import sys
source = Path('Sources/LinxDisplayCore/Models.swift').read_text()
start = source.index('public enum CanvasModule:')
end = source.index('/// 键盘独立番茄钟卡片的刷新对齐策略。', start)
Path(sys.argv[1], 'CanvasModule.swift').write_text('import Foundation\n' + source[start:end])
PYENUM
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift "$output/CanvasModule.swift" \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoBoardPlaylist.swift \
  Sources/LinxDisplayApp/ReadPicoBoardLibrary.swift Tools/ReadPicoManagerTests/BoardLibraryTests.swift \
  -o "$output/board-library-tests"
"$output/board-library-tests"
