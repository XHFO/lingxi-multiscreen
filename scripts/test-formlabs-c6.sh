#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/lingxi-formlabs-c6-tests.XXXXXX)"
CJSON_ROOT="${LINGXI_CJSON_ROOT:-${HOME}/.platformio/packages/framework-espidf/components/json/cJSON}"
SDK_PATH="$("$ROOT/scripts/select-macos-sdk")"
node "$ROOT/scripts/embed-formlabs-c6-portal.mjs" --check
node "$ROOT/Tools/FormlabsC6Firmware/tests/portal_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/weather_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/onboarding_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/guide_runtime_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/captive_http_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/language_http_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/autosave_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/preview_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/display_runtime_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/overview_runtime_test.mjs"
node "$ROOT/Tools/FormlabsC6Firmware/tests/demo_runtime_test.mjs"
clang -std=c11 -D C6_FORMLABS_ONLY=1 -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/FormlabsC6Firmware/tests/profile_test.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$ROOT/Tools/WaveshareC6Firmware/src/formlabs_source.c" "$CJSON_ROOT/cJSON.c" -lm -o "$STAGE/profile-tests"
"$STAGE/profile-tests"
clang -isysroot "$SDK_PATH" -O2 -D C6_FORMLABS_ONLY=1 -I "$ROOT/Sources/C6DisplayRenderer/include" \
    "$ROOT/Tools/FormlabsC6Firmware/tests/clock_preview.m" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" \
    -framework CoreGraphics -framework ImageIO -framework CoreFoundation -lm -o "$STAGE/clock-tests"
"$STAGE/clock-tests" "$STAGE"
clang -isysroot "$SDK_PATH" -O2 -D C6_FORMLABS_ONLY=1 -D C6_RENDER_LAYOUT_TEST=1 -I "$ROOT/Sources/C6DisplayRenderer/include" \
    "$ROOT/Tools/FormlabsC6Firmware/tests/printer_layout_preview.m" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" \
    -framework CoreGraphics -framework CoreText -framework ImageIO -framework CoreFoundation -lm -o "$STAGE/printer-layout-tests"
"$STAGE/printer-layout-tests" "$STAGE"
mkdir -p "$STAGE/smooth"
clang -isysroot "$SDK_PATH" -O2 -D C6_FORMLABS_ONLY=1 -D TEST_SMOOTH_DIGITS=1 -I "$ROOT/Sources/C6DisplayRenderer/include" \
    "$ROOT/Tools/FormlabsC6Firmware/tests/aero_digit_preview.m" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" \
    -framework CoreGraphics -framework ImageIO -framework CoreFoundation -lm -o "$STAGE/smooth-tests"
"$STAGE/smooth-tests" "$STAGE/smooth"
cmp "$STAGE/settings.png" "$STAGE/smooth/settings.png"
cmp "$STAGE/settings-en.png" "$STAGE/smooth/settings-en.png"
clang -isysroot "$SDK_PATH" -O2 -fobjc-arc -D C6_FORMLABS_ONLY=1 -I "$ROOT/Sources/C6DisplayRenderer/include" -I "$ROOT/Sources/C6DisplayRenderer" \
    "$ROOT/Tools/FormlabsC6Firmware/tests/setup_preview.m" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" \
    -framework Foundation -framework CoreImage -framework CoreGraphics -framework ImageIO -lm -o "$STAGE/setup-tests"
"$STAGE/setup-tests" "$STAGE"
printf '%s\n' "$STAGE"
