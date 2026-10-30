#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/cloudflare-source-draft-tests}"
mkdir -p "$output/ModuleCache"
sdk="$(scripts/select-macos-sdk)"
sh Tools/extract-cloudflare-test-appearance.sh > "$output/CloudflareAppearanceSupport.swift"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  -module-cache-path "$output/ModuleCache" \
  -emit-module -emit-library -module-name LinxDisplayCore \
  "$output/CloudflareAppearanceSupport.swift" \
  Sources/LinxDisplayCore/SealedCredentialStore.swift Sources/LinxDisplayCore/CloudflareAnalytics.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  -module-cache-path "$output/ModuleCache" \
  -I "$output" -L "$output" -lLinxDisplayCore \
  Sources/LinxDisplayApp/CloudflareSourceDraft.swift Tools/CloudflareSourceDraftTests.swift \
  -o "$output/tests"
DYLD_LIBRARY_PATH="$output${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$output/tests" > "$output/checks.txt" 2>&1
cat "$output/checks.txt"
