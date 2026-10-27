#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/cloudflare-analytics-tests}"
mkdir -p "$output"
sdk="$(scripts/select-macos-sdk)"
sh Tools/extract-cloudflare-test-appearance.sh > "$output/CloudflareAppearanceSupport.swift"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  "$output/CloudflareAppearanceSupport.swift" \
  Sources/LinxDisplayCore/SealedCredentialStore.swift Sources/LinxDisplayCore/CloudflareAnalytics.swift Tools/CloudflareAnalyticsTests.swift \
  -o "$output/tests"
"$output/tests" > "$output/checks.txt" 2>&1
cat "$output/checks.txt"
