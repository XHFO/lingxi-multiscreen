#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
fixture="${1:?Pass pico_reading_snapshot_host_test.c synthetic fixture root}"
output="${2:-.build/readpico-reading-notes-firmware-export}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoReadingNotes.swift -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" -lLinxDisplayCore \
  -Xlinker -rpath -Xlinker "$output" Tools/ReadPicoManagerTests/ReadingNotesFirmwareExportTests.swift -o "$output/tests"
"$output/tests" "$fixture"
