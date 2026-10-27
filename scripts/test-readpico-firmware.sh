#!/bin/bash
# 中文：离线固件解析和模拟串口测试；从不打开真实设备。
# English: Offline image and fake-serial tests; never open a physical device.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/readpico-firmware-tests.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 "$TASK_ROOT/Tools/ReadPicoFirmwareTests/fixtures.py" "$TASK_TMP"
swiftc -parse-as-library \
  "$TASK_ROOT/Sources/LinxDisplayCore/ReadPicoPowerStatus.swift" \
  "$TASK_ROOT/Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift" \
  "$TASK_ROOT/Sources/LinxDisplayCore/ReadPicoFirmware.swift" \
  "$TASK_ROOT/Tools/ReadPicoFirmwareTests/FirmwareTests.swift" \
  "$TASK_ROOT/Tools/ReadPicoFirmwareTests/FreshInstallTests.swift" \
  -o "$TASK_TMP/tests"
"$TASK_TMP/tests" "$TASK_TMP"

python3 "$TASK_ROOT/Tools/ReadPicoFirmwareTests/package_tests.py"
