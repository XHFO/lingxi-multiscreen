#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/pico-reading-card-rendering-20261024}"
configuration="${2:-Release}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
products=".build/out/Products/$configuration"
sdk="${PICO_TEST_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
fixture="$(mktemp -d -t pico-reading-render)"
trap 'rm -rf "$fixture"' EXIT
cc -std=c11 Tools/ReadPicoManagerTests/ReadingNotesFixture.c -o "$output/fixture"
"$output/fixture" "$fixture/card"
SDKROOT="$sdk" scripts/swiftc-sdk-compat -parse-as-library -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx26.0 \
  -I "$products" -Xcc "-fmodule-map-file=.build/out/Intermediates.noindex/LinxDisplay.build/$configuration/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap" -Xcc -ISources/C6DisplayRenderer/include \
  Tools/ReadPicoManagerTests/ReadingCardRenderingTests.swift "$products/LinxDisplayCore.o" "$products/C6DisplayRenderer.o" \
  -o "$output/tests"
shasum -a 256 "$products/LinxDisplayCore.o" "$products/C6DisplayRenderer.o" \
  Sources/LinxDisplayCore/ScreenRenderer.swift Sources/LinxDisplayCore/ReadPicoReadingNotes.swift \
  Tools/ReadPicoManagerTests/ReadingNotesFixture.c Tools/ReadPicoManagerTests/ReadingCardRenderingTests.swift \
  > "$output/source-sha256.txt"
if "$output/tests" "$fixture/card" "$output" > "$output/results.txt" 2>&1; then
  cat "$output/results.txt"
else
  cat "$output/results.txt"
  exit 1
fi
