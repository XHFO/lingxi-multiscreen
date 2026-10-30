#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/control-center-printer-image-cache-tests}"
mkdir -p "$output"
sdk="$(scripts/select-macos-sdk)"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -module-cache-path "$output/module-cache" \
  -parse-as-library -swift-version 5 \
  Sources/LinxDisplayApp/ControlCenterPrinterImageCache.swift \
  Tools/ControlCenterPrinterImageCacheTests.swift -o "$output/tests"
"$output/tests"
