#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-usb-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Tools/ReadPicoManagerTests/USBTransferTests.swift -o "$output/usb-tests"
"$output/usb-tests"
