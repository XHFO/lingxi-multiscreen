#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-lock-screen-guard-tests)"
trap 'rm -rf "$output"' EXIT
sdk="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
python3 - "$output" <<'PYENUM'
from pathlib import Path
import sys
source = Path('Sources/LinxDisplayCore/Models.swift').read_text()
start = source.index('public enum CanvasModule:')
end = source.index('/// 键盘独立番茄钟卡片的刷新对齐策略。', start)
Path(sys.argv[1], 'CanvasModule.swift').write_text('import Foundation\n' + source[start:end])
PYENUM
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target arm64-apple-macosx26.0 -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift Sources/LinxDisplayCore/ReadPicoBoardRouting.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBundledApps.swift \
  "$output/CanvasModule.swift" -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target arm64-apple-macosx26.0 -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoBoardPlaylist.swift Sources/LinxDisplayApp/ReadPicoBoardLibrary.swift Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoDraftGuard.swift \
  Sources/LinxDisplayApp/ReadPicoManagementWebView.swift Sources/LinxDisplayApp/ReadPicoBundledAppsView.swift \
  Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift Sources/LinxDisplayApp/ReadPicoUSBConnectionPanel.swift Sources/LinxDisplayApp/ReadPicoManagerView.swift Tools/ReadPicoManagerTests/LockScreenDraftGuardTests.swift \
  -o "$output/lock-screen-guard-tests"
"$output/lock-screen-guard-tests"
