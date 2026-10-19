#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDKROOT="$(scripts/select-macos-sdk)"
export SDKROOT
export SWIFT_EXEC="$ROOT/scripts/swiftc-sdk-compat"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/menu-bar-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/menu-bar-swift-cache"
swift run -c release --disable-sandbox -debug-info-format none LinxDisplaySmokeTests --menu-bar-only
STAGE="$(mktemp -d /private/tmp/lingxi-menu-tests.XXXXXX)"
swiftc -sdk "$SDKROOT" -module-cache-path "$ROOT/.build/menu-preview-modules" \
    Sources/LinxDisplayApp/MenuBarScreenPreview.swift Tools/MenuBarPreviewTests/main.swift \
    -o "$STAGE/menu-preview-tests"
"$STAGE/menu-preview-tests"
