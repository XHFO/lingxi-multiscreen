#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-console-data}"
mkdir -p "$output"
sdk="$(scripts/select-macos-sdk)"
scripts/swiftc-sdk-compat -sdk "$sdk" -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift \
  Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift \
  Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBoardModel.swift \
  Sources/LinxDisplayCore/ReadPicoBoardDelta.swift Sources/LinxDisplayCore/ReadPicoDesktopConsole.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  -I "$output" -L "$output" -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Tools/ReadPicoManagerTests/DesktopConsoleTests.swift -o "$output/tests"
"$output/tests" "$output/fixtures"
