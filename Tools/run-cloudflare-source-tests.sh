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
module CPicoBoardRenderer {
    umbrella "$root/Sources/CPicoBoardRenderer/include"
    export *
}
EOF
shasum -a 256 Sources/LinxDisplayCore/*.swift Tools/CloudflareSourceSettingsTests.swift \
  Sources/C6DisplayRenderer/*.c Sources/C6DisplayRenderer/*.h Sources/C6DisplayRenderer/include/*.h \
  Sources/CPicoBoardRenderer/main/system/*.[ch] \
  Sources/CPicoBoardRenderer/components/read_pico_home_link/*.[ch] \
  Sources/CPicoBoardRenderer/vendor/cJSON/*.[ch] \
  Sources/CPicoBoardRenderer/include/*.h Sources/CPicoBoardRenderer/private/mbedtls/*.h \
  Sources/CPicoBoardRenderer/pico_board_sha.c > "$output/source-sha256.txt"
clang -isysroot "$sdk" -mmacosx-version-min=26.0 -c Sources/C6DisplayRenderer/c6_display_renderer.c -I Sources/C6DisplayRenderer/include -o "$output/renderer.o"
clang -isysroot "$sdk" -mmacosx-version-min=26.0 -c Sources/C6DisplayRenderer/qrcodegen.c -o "$output/qrcode.o"
pico_root="$root/Sources/CPicoBoardRenderer"
# Keep this standalone test build aligned with Package.swift's portable target.
# home_link_json.c includes the private cJSON implementation, so do not also
# compile vendor/cJSON/cJSON.c as a second translation unit.
for pico_source in main/system/pico_board_data.c main/system/pico_board_render.c \
  components/read_pico_home_link/home_link_json.c pico_board_sha.c; do
  pico_object="$(basename "$pico_source" .c)"
  clang -isysroot "$sdk" -mmacosx-version-min=26.0 -DPICO_BOARD_PORTABLE \
    -I "$pico_root/include" -I "$pico_root/private" -I "$pico_root/vendor/cJSON" \
    -c "$pico_root/$pico_source" -o "$output/$pico_object.o"
done
SDKROOT="$sdk" scripts/swiftc-sdk-compat -sdk "$sdk" -target arm64-apple-macosx26.0 \
  -parse-as-library -swift-version 5 -module-name CloudflareSourceSettingsTests \
  -module-cache-path "$output/modules" -I "$output/c-module" \
  Sources/LinxDisplayCore/*.swift Tools/CloudflareSourceSettingsTests.swift \
  "$output/renderer.o" "$output/qrcode.o" \
  "$output/pico_board_data.o" "$output/pico_board_render.o" \
  "$output/home_link_json.o" "$output/pico_board_sha.o" \
  -framework JavaScriptCore -framework CoreBluetooth \
  -o "$output/tests" > "$output/build.txt" 2>&1 || { cat "$output/build.txt"; exit 1; }
"$output/tests" > "$output/checks.txt" 2>&1 || { cat "$output/checks.txt"; exit 1; }
shasum -a 256 -c "$output/source-sha256.txt" > "$output/source-binding.txt"
cat "$output/checks.txt"
