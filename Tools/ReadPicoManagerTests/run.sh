#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Tools/ReadPicoManagerTests/Tests.swift -o "$output/readpico-tests"
"$output/readpico-tests"
