#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-lock-image-model-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift Sources/LinxDisplayCore/ReadPicoBoardRouting.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBundledApps.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoDraftGuard.swift \
  Sources/LinxDisplayApp/ReadPicoManagementWebView.swift Sources/LinxDisplayApp/ReadPicoBundledAppsView.swift \
  Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift Sources/LinxDisplayApp/ReadPicoUSBConnectionPanel.swift Sources/LinxDisplayApp/ReadPicoManagerView.swift Tools/ReadPicoManagerTests/LockImageModelTests.swift \
  -o "$output/lock-image-model-tests"
"$output/lock-image-model-tests"
