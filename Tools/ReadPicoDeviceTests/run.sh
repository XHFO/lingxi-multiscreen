#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-device-tests)"
trap 'rm -rf "$output"' EXIT
mkdir -p "$output/c-module"
cat > "$output/c-module/module.modulemap" <<EOF
module C6DisplayRenderer {
    umbrella "$(pwd)/Sources/C6DisplayRenderer/include"
    export *
}
EOF
clang -c Sources/C6DisplayRenderer/c6_display_renderer.c -I Sources/C6DisplayRenderer/include -o "$output/renderer.o"
clang -c Sources/C6DisplayRenderer/qrcodegen.c -o "$output/qrcode.o"
swiftc -swift-version 5 -parse-as-library -emit-library -emit-module -module-name LinxDisplayCore \
    -I "$output/c-module" Sources/LinxDisplayCore/*.swift "$output/renderer.o" "$output/qrcode.o" \
    -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib" \
    -framework JavaScriptCore -framework CoreBluetooth
swiftc -swift-version 5 -parse-as-library -I "$output" -I "$output/c-module" -L "$output" \
    -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
    Tools/ReadPicoDeviceTests/Tests.swift -o "$output/device-tests"
"$output/device-tests"
