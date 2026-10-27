#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-library)"
trap 'rm -rf "$output"' EXIT
python3 Tools/ReadPicoManagerTests/local-library-fixtures.py "$output"
swiftc -parse-as-library -swift-version 5 Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Tools/ReadPicoManagerTests/LocalLibraryTests.swift -o "$output/library-tests"
"$output/library-tests" "$output"
