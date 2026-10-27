#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-power-status-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift \
  Sources/LinxDisplayCore/ReadPicoSafeEject.swift Tools/ReadPicoManagerTests/PowerStatusTests.swift \
  -o "$output/power-tests"
"$output/power-tests"
