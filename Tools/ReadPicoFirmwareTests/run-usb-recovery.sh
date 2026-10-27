#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-firmware-usb-recovery)"
trap 'rm -rf "$output"' EXIT
sdk="$(scripts/select-macos-sdk)"
scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoFirmwareUSBRecovery.swift \
  Tools/ReadPicoFirmwareTests/USBRecoveryTests.swift -o "$output/tests"
"$output/tests"
