#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-$(mktemp -d -t readpico-board-playlist)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, sys
sources = [
    'Sources/LinxDisplayCore/Models.swift',
    'Sources/LinxDisplayCore/ReadPicoPowerStatus.swift',
    'Sources/LinxDisplayCore/ReadPicoManager.swift',
    'Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift',
    'Sources/LinxDisplayApp/ReadPicoBoardPlaylist.swift',
    'Sources/LinxDisplayApp/ReadPicoBoardCarouselCursor.swift',
    'Sources/LinxDisplayApp/ReadPicoBoardPlaylistImage.swift',
    'Sources/LinxDisplayApp/PicoNativeDesign/PicoPhotoRenderer.swift',
    'Sources/LinxDisplayApp/PicoNativeDesign/PicoNativeLibrary.swift',
    'Tools/ReadPicoManagerTests/BoardPlaylistTests.swift',
    'Tools/ReadPicoManagerTests/run-board-playlist.sh',
]
digests = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sources}
Path(sys.argv[1], 'source-binding-start.json').write_text(json.dumps(digests, indent=2) + '\n')
source = Path('Sources/LinxDisplayCore/Models.swift').read_text()
start = source.index('public enum CanvasModule:')
end = source.index('/// 键盘独立番茄钟卡片的刷新对齐策略。', start)
Path(sys.argv[1], 'CanvasModule.swift').write_text('import Foundation\n' + source[start:end])
PY
sdk="$(scripts/select-macos-sdk)"
test_target="$(uname -m)-apple-macosx26.0"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target "$test_target" -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift "$output/CanvasModule.swift" \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target "$test_target" -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoBoardPlaylist.swift \
  Sources/LinxDisplayApp/ReadPicoBoardCarouselCursor.swift Sources/LinxDisplayApp/ReadPicoBoardPlaylistImage.swift \
  Sources/LinxDisplayApp/PicoNativeDesign/PicoPhotoRenderer.swift Sources/LinxDisplayApp/PicoNativeDesign/PicoNativeLibrary.swift \
  Tools/ReadPicoManagerTests/BoardPlaylistTests.swift -o "$output/tests"
"$output/tests"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, sys
output = Path(sys.argv[1])
before = json.loads((output / 'source-binding-start.json').read_text())
after = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in before}
assert before == after, 'Source changed during test run'
(output / 'source-binding.json').write_text(json.dumps({
    'result': 'PASS',
    'source_sha256': after,
    'scope': 'Actual production playlist, configuration validation, cursor and image sources; CanvasModule extracted unchanged from Models.swift. No full app build, network, user settings or hardware.',
}, indent=2) + '\n')
PY
