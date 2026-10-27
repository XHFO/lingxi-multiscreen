#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="$(mktemp -d -t readpico-usb-native-pty-tests)"
trap 'rm -rf "$output"' EXIT
python3 - "$output/ReadPicoUSBTransfer.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift").read_text()
old = "    private static func exchange(port: String, cancelled: @Sendable () -> Bool, start: Bool = true) throws -> ReadPicoUSBStartResult {"
new = "    static func exchange(port: String, cancelled: @Sendable () -> Bool, start: Bool = true) throws -> ReadPicoUSBStartResult {"
assert source.count(old) == 1, "production exchange signature changed; review this test seam"
Path(sys.argv[1]).write_text(source.replace(old, new))
PY
swiftc -parse-as-library -swift-version 5 \
  Sources/LinxDisplayCore/ReadPicoPowerStatus.swift "$output/ReadPicoUSBTransfer.swift" Tools/ReadPicoManagerTests/USBNativePTYTests.swift \
  -o "$output/usb-native-pty-tests"
"$output/usb-native-pty-tests"
