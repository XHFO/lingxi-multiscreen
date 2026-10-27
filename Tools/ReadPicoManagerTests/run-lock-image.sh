#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-lock-image-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Tools/ReadPicoManagerTests/LockImageHTTPTests.swift -o "$output/lock-image-tests"
"$output/lock-image-tests"
