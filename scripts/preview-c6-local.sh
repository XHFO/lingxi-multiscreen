#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/lingxi-c6-native-preview.XXXXXX)"
CJSON_ROOT="${LINGXI_CJSON_ROOT:-${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}/packages/framework-espidf/components/json/cJSON}"
SDK_PATH="$("$ROOT/scripts/select-macos-sdk")"
clang -isysroot "$SDK_PATH" -O2 -I "$ROOT/Sources/C6DisplayRenderer/include" -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/local_render_preview.m" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" \
    -framework CoreGraphics -framework ImageIO -framework CoreFoundation -o "$STAGE/render"
"$STAGE/render" "$STAGE"
printf '%s\n' "$STAGE"
