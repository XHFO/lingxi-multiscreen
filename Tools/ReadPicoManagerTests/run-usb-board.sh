#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-usb-board-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Tools/ReadPicoManagerTests/USBBoardTests.swift \
  -o "$output/usb-board-tests"
"$output/usb-board-tests" "$@"
