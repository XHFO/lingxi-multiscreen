#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/pico-native-lockscreen-20261024/native}"
configuration="${2:-Release}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
products=".build/out/Products/$configuration"
sdk="${PICO_TEST_SDK:-$(scripts/select-macos-sdk)}"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -parse-as-library -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx26.0 \
  -I "$products" -Xcc "-fmodule-map-file=.build/out/Intermediates.noindex/LinxDisplay.build/$configuration/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap" -Xcc -ISources/C6DisplayRenderer/include \
  Sources/LinxDisplayApp/PicoNativeDesign/PicoPhotoRenderer.swift \
  Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoLockScreenRenderer.swift \
  Tools/ReadPicoManagerTests/NativeLockScreenCompositionTests.swift "$products/LinxDisplayCore.o" "$products/C6DisplayRenderer.o" \
  -o "$output/tests"
"$output/tests"
