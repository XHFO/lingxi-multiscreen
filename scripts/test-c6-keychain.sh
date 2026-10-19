#!/bin/bash
set -euo pipefail
c6_test_root="$(cd "$(dirname "$0")/.." && pwd)"
c6_test_stage="$(mktemp -d /private/tmp/lingxi-c6-keychain-tests.XXXXXX)"
c6_test_sdk="$("$c6_test_root/scripts/select-macos-sdk")"
swiftc -sdk "$c6_test_sdk" -module-cache-path "${LINGXI_C6_KEYCHAIN_MODULE_CACHE:-$c6_test_stage/modules}" \
    "$c6_test_root/Sources/LinxDisplayCore/C6SecretStore.swift" \
    "$c6_test_root/Tools/C6KeychainTests/main.swift" -o "$c6_test_stage/tests"
"$c6_test_stage/tests"
node "$c6_test_root/Tools/C6KeychainTests/ui_contract.mjs"
