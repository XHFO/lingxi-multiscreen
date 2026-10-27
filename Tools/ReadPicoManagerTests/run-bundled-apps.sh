#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-bundled-apps-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  Sources/LinxDisplayCore/ReadPicoBundledApps.swift Tools/ReadPicoManagerTests/BundledAppsTests.swift \
  -o "$output/bundled-apps-tests"
"$output/bundled-apps-tests" "${1:-Resources/Firmware/ReadPico}"
