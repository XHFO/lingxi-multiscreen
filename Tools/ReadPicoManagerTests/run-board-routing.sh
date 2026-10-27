#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-board-routing-tests)"
trap 'rm -rf "$output"' EXIT
sdk="$(scripts/select-macos-sdk)"
scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift \
  Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoBoardRouting.swift \
  Tools/ReadPicoManagerTests/BoardRoutingTests.swift \
  -o "$output/tests"
"$output/tests"
