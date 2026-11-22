#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE="$(mktemp -d /private/tmp/lingxi-dashboard-tests.XXXXXX)"
SDK_PATH="$("$ROOT/scripts/select-macos-sdk")"
swiftc -swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" -parse-as-library \
  "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardSession.swift" \
  "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardLoginView.swift" \
  "$ROOT/Tools/FormlabsDashboardTests/PayloadTests.swift" -o "$STAGE/payload-tests"
"$STAGE/payload-tests" "$STAGE/observer.js"
node "$ROOT/Tools/FormlabsDashboardTests/observer_test.mjs" "$STAGE/observer.js"
if [[ "${1:-}" == "--webkit" ]]; then
  swiftc -swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" -parse-as-library \
    "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardSession.swift" \
    "$ROOT/Tools/FormlabsDashboardTests/HiddenWebViewTests.swift" -o "$STAGE/hidden-webkit-tests"
  "$STAGE/hidden-webkit-tests"
  swiftc -swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" -parse-as-library \
    "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardSession.swift" \
    "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardLoginView.swift" \
    "$ROOT/Tools/FormlabsDashboardTests/LoginFocusTests.swift" -o "$STAGE/login-focus-tests"
  "$STAGE/login-focus-tests"
  swiftc -swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$STAGE/modules" -parse-as-library \
    "$ROOT/Sources/LinxDisplayApp/FormlabsDashboardSession.swift" \
    "$ROOT/Tools/FormlabsDashboardTests/ViewportTests.swift" -o "$STAGE/viewport-tests"
  "$STAGE/viewport-tests"
fi
printf '%s\n' "$STAGE"
