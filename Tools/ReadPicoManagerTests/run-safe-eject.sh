#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-safe-eject-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoSafeEject.swift Tools/ReadPicoManagerTests/SafeEjectTests.swift \
  -o "$output/safe-eject-tests"
"$output/safe-eject-tests"
