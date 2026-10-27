#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-reading-notes}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
fixture="$(mktemp -d -t pico-reading-notes)"
trap 'rm -rf "$fixture"' EXIT
cc -std=c11 Tools/ReadPicoManagerTests/ReadingNotesFixture.c -o "$output/fixture"
"$output/fixture" "$fixture/card"
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoReadingNotes.swift -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" -lLinxDisplayCore \
  -Xlinker -rpath -Xlinker "$output" Tools/ReadPicoManagerTests/ReadingNotesTests.swift -o "$output/tests"
"$output/tests" "$fixture/card"
swiftc -typecheck -swift-version 5 -I "$output" Sources/LinxDisplayApp/ReadPicoReadingNotesView.swift
