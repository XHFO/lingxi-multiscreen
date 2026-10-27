#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/usb-direct-board-live}"
mkdir -p "$(dirname "$output")"
sdk="$(scripts/select-macos-sdk)"
scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Tools/ReadPicoManagerTests/USBDirectBoardLive.swift \
  -o "$output"
printf '%s\n' "$output"
