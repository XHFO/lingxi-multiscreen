#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/control-center-preview-cache-tests}"
mkdir -p "$output"
sdk="$(scripts/select-macos-sdk)"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  -module-cache-path "$output/ModuleCache" \
  Sources/LinxDisplayApp/ControlCenterPreviewCache.swift Tools/ControlCenterPreviewCacheTests.swift \
  -o "$output/tests"
"$output/tests"
