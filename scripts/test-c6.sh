#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CJSON_ROOT="${LINGXI_CJSON_ROOT:-${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}/packages/framework-espidf/components/json/cJSON}"
STAGE="$(mktemp -d /private/tmp/lingxi-c6-tests.XXXXXX)"
SDK_PATH="$("$ROOT/scripts/select-macos-sdk")"
swiftc -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" \
    "$ROOT/Sources/LinxDisplayCore/C6Standalone.swift" \
    "$ROOT/Sources/LinxDisplayCore/C6ConfigurationSync.swift" \
    "$ROOT/Sources/LinxDisplayCore/Weather.swift" \
    "$ROOT/Tools/C6StandaloneTests/main.swift" -o "$STAGE/swift-tests"
"$STAGE/swift-tests"
node "$ROOT/Tools/C6StandaloneTests/card_option_lifecycle.mjs"
swiftc -D C6_TRANSPORT_CONTRACT_TEST -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" \
    "$ROOT/Sources/LinxDisplayCore/C6Standalone.swift" \
    "$ROOT/Tools/C6StandaloneTests/native_transport.swift" -o "$STAGE/native-transport"
node "$ROOT/Tools/C6StandaloneTests/native_transport.mjs" "$STAGE/native-transport"
clang -std=c11 -Wall -Wextra "$ROOT/Tools/C6StandaloneTests/button_menu_test.c" -o "$STAGE/button-menu-tests"
"$STAGE/button-menu-tests"
clang -std=c11 -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/menu_actions_test.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" -o "$STAGE/menu-action-tests"
"$STAGE/menu-action-tests"
clang -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/firmware_contract.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" -o "$STAGE/contract-tests"
"$STAGE/contract-tests"
clang -std=c11 -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/config_memory_test.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" -lm -o "$STAGE/config-memory-tests"
"$STAGE/config-memory-tests"
clang -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/local_state_test.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" -o "$STAGE/state-tests"
"$STAGE/state-tests"
clang -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/formlabs_contract.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/formlabs_source.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" -lm -o "$STAGE/formlabs-tests"
"$STAGE/formlabs-tests"
clang -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/thumbnail_contract.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/thumbnail_cache.c" -o "$STAGE/thumbnail-tests"
"$STAGE/thumbnail-tests"
clang -std=c11 -Wall -Wextra "$ROOT/Tools/C6StandaloneTests/font_contract.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" -lm -o "$STAGE/font-tests"
"$STAGE/font-tests"
clang -std=c11 -I "$ROOT/Tools/C6StandaloneTests/stubs" -I "$CJSON_ROOT" \
    "$ROOT/Tools/C6StandaloneTests/unified_ui_test.c" \
    "$ROOT/Tools/WaveshareC6Firmware/src/local_state.c" "$CJSON_ROOT/cJSON.c" \
    "$ROOT/Sources/C6DisplayRenderer/c6_display_renderer.c" "$ROOT/Sources/C6DisplayRenderer/qrcodegen.c" -lm -o "$STAGE/unified-ui-tests"
"$STAGE/unified-ui-tests"
node "$ROOT/Tools/C6StandaloneTests/portal_test.mjs"
node "$ROOT/Tools/C6StandaloneTests/ha_cache_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/camera_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/formlabs_network_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/png_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/lifecycle_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/button_api_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/hybrid_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/resource_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/recovery_contract.mjs"
node "$ROOT/Tools/C6StandaloneTests/network_settings_test.mjs"
bash "$ROOT/scripts/preview-c6-local.sh"
