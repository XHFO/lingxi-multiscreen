#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/lingxi-formlabs-client-tests.XXXXXX)"
SDK_PATH="$("$ROOT/scripts/select-macos-sdk")"
swiftc -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" \
    "$ROOT/Sources/LinxDisplayCore/FormlabsClient.swift" \
    "$ROOT/Tools/FormlabsClientTests.swift" -o "$STAGE/formlabs-tests"
"$STAGE/formlabs-tests"
