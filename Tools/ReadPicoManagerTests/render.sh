#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-manager-preview}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
python3 - "$PWD" "$output" <<'PY'
from pathlib import Path
import shutil,sys
root,output=map(Path,sys.argv[1:])
shutil.copytree(root/'Resources/Firmware/ReadPico',output/'Firmware/ReadPico',dirs_exist_ok=True)
PY
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift Sources/LinxDisplayCore/ReadPicoBoardRouting.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBundledApps.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoDraftGuard.swift \
  Sources/LinxDisplayApp/ReadPicoManagementWebView.swift \
  Sources/LinxDisplayApp/ReadPicoBundledAppsView.swift Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift Sources/LinxDisplayApp/ReadPicoUSBConnectionPanel.swift Sources/LinxDisplayApp/ReadPicoManagerView.swift Tools/ReadPicoManagerTests/Render.swift \
  -o "$output/render"
"$output/render" books light "$output/books-light.png"
"$output/render" connection light "$output/connection-light.png"
"$output/render" canvas dark "$output/canvas-dark.png"
"$output/render" connection light "$output/connection-minimum.png" 660 540 connected
"$output/render" connection dark "$output/connection-busy-minimum.png" 660 540 busy
"$output/render" books light "$output/books-long-minimum.png" 660 540 long-files
"$output/render" canvas dark "$output/canvas-minimum.png" 660 540 connected
"$output/render" connection dark "$output/connection-dirty-minimum.png" 660 540 dirty
"$output/render" canvas light "$output/canvas-dirty-minimum.png" 660 540 canvas-dirty
"$output/render" connection light "$output/departure-minimum.png" 660 540 departure
