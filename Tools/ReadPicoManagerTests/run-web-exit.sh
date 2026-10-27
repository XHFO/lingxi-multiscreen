#!/bin/sh
set -eu
# Only this optional test lookup knows the sibling firmware checkout layout.
# Production app code has no dependency on a developer's firmware directory.
manage="${1:-}"
if [ -n "$manage" ]; then
  if [ ! -f "$manage" ]; then
    printf '%s\n' "manage.html not found: $manage" >&2
    exit 2
  fi
  manage="$(cd "$(dirname "$manage")" && pwd)/$(basename "$manage")"
fi
cd "$(dirname "$0")/../.."
if [ -z "$manage" ]; then
  candidate="../../../2026-10-07/https-github-com-mindreset-read-pico/work/read_pico_firmware/components/read_pico_transfer/manage.html"
  if [ -f "$candidate" ]; then manage="$candidate"; fi
fi
output="$(mktemp -d -t readpico-web-exit-tests)"
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -emit-library -emit-module -module-name LinxDisplayCore \
  Sources/LinxDisplayCore/ReadPicoUSBTransfer.swift Sources/LinxDisplayCore/ReadPicoUSBWireless.swift Sources/LinxDisplayCore/ReadPicoBoardRouting.swift Sources/LinxDisplayCore/ReadPicoPowerStatus.swift Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoUSBBoard.swift Sources/LinxDisplayCore/ReadPicoSafeEject.swift Sources/LinxDisplayCore/ReadPicoBundledApps.swift \
  -emit-module-path "$output/LinxDisplayCore.swiftmodule" -o "$output/libLinxDisplayCore.dylib"
swiftc -parse-as-library -swift-version 5 -I "$output" -L "$output" \
  -lLinxDisplayCore -Xlinker -rpath -Xlinker "$output" \
  Sources/LinxDisplayApp/ReadPicoCanvasDraft.swift Sources/LinxDisplayApp/ReadPicoLockScreenDraft.swift Sources/LinxDisplayApp/ReadPicoDraftGuard.swift \
  Sources/LinxDisplayApp/ReadPicoManagementWebView.swift Sources/LinxDisplayApp/ReadPicoBundledAppsView.swift Sources/LinxDisplayApp/ReadPicoLocalLibraryView.swift Sources/LinxDisplayApp/ReadPicoUSBConnectionPanel.swift Sources/LinxDisplayApp/ReadPicoManagerView.swift \
  Tools/ReadPicoManagerTests/WebExitTests.swift -o "$output/web-exit-tests"
"$output/web-exit-tests"
if [ -n "$manage" ]; then
  node Tools/ReadPicoManagerTests/WebExitContract.mjs "$manage"
else
  printf '%s\n' 'SKIP real manage.html contract: pass its path as the first argument to include the firmware-page checks.'
fi
