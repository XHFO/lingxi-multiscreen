#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-usb-direct-board}"
mkdir -p "$output"
python3 - "$output" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Sources/LinxDisplayCore/ReadPicoUSBBoard.swift').read_text()
# Access-control-only test exposure. Actual port validation is exercised separately in model tests.
Path(sys.argv[1], 'USBBoardExposed.swift').write_text(source.replace('private static func directExchange(', 'static func directExchange('))
PYTHON
sdk="$(scripts/select-macos-sdk)"
scripts/swiftc-sdk-compat -sdk "$sdk" -parse-as-library -swift-version 5 -Xfrontend -disable-access-control \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift \
  "$output/USBBoardExposed.swift" Sources/LinxDisplayCore/ReadPicoSafeEject.swift Tools/ReadPicoManagerTests/USBDirectBoardPTYTests.swift \
  -o "$output/tests"
if [ "$#" -ge 2 ]; then
  "$output/tests" "$2"
else
  "$output/tests"
fi
