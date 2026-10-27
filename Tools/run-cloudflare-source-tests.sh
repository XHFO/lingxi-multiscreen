#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/cloudflare-source-tests}"
mkdir -p "$output/c-module" "$output/modules"
root="$(pwd)"
sdk="$(scripts/select-macos-sdk)"
cat > "$output/c-module/module.modulemap" <<EOF
module C6DisplayRenderer {
    umbrella "$root/Sources/C6DisplayRenderer/include"
    export *
}
EOF
shasum -a 256 Sources/LinxDisplayCore/*.swift Tools/CloudflareSourceSettingsTests.swift > "$output/source-sha256.txt"
clang -isysroot "$sdk" -mmacosx-version-min=26.0 -c Sources/C6DisplayRenderer/c6_display_renderer.c -I Sources/C6DisplayRenderer/include -o "$output/renderer.o"
clang -isysroot "$sdk" -mmacosx-version-min=26.0 -c Sources/C6DisplayRenderer/qrcodegen.c -o "$output/qrcode.o"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target arm64-apple-macosx26.0 \
  -parse-as-library -swift-version 5 -module-name CloudflareSourceSettingsTests \
  -module-cache-path "$output/modules" -I "$output/c-module" \
  Sources/LinxDisplayCore/*.swift Tools/CloudflareSourceSettingsTests.swift \
  "$output/renderer.o" "$output/qrcode.o" -framework JavaScriptCore -framework CoreBluetooth \
  -o "$output/tests" > "$output/build.txt" 2>&1 || { cat "$output/build.txt"; exit 1; }
"$output/tests" > "$output/checks.txt" 2>&1 || { cat "$output/checks.txt"; exit 1; }
shasum -a 256 -c "$output/source-sha256.txt" > "$output/source-binding.txt"
cat "$output/checks.txt"
