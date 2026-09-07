#!/bin/bash
# Build the isolated 240x240 ESP8266 experimental app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export SWIFT_EXEC="$ROOT/scripts/swiftc-sdk-compat"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/aimac-clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/aimac-swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build -c release --product AIMacScreenApp --disable-sandbox

BIN="$ROOT/.build/release/AIMacScreenApp"
APP_NAME="灵犀小屏实验版"
EXEC_NAME="LingxiAIMacScreen"
FINAL_APP="$ROOT/dist/$APP_NAME.app"
FINAL_ZIP="$ROOT/dist/$APP_NAME-0.1.0.zip"
STAGE_ROOT="$(mktemp -d /private/tmp/lingxi-aimac-screen.XXXXXX)"
APP="$STAGE_ROOT/$APP_NAME.app"
STAGE_ZIP="$STAGE_ROOT/$APP_NAME-0.1.0.zip"

if [ -d "$FINAL_APP" ]; then
    mkdir -p "$ROOT/dist/previous-builds"
    mv "$FINAL_APP" "$ROOT/dist/previous-builds/$APP_NAME-$(date +%s).app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"
if [ -f "$ROOT/Resources/Icon.icns" ]; then
    cp "$ROOT/Resources/Icon.icns" "$APP/Contents/Resources/"
fi

cp "$ROOT/packaging/AIMacScreenInfo.plist" "$APP/Contents/Info.plist"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Package directly from the clean temporary location.  A Documents/File
# Provider directory may attach Finder metadata immediately after a move;
# creating the ZIP here prevents that metadata from invalidating the bundle.
ditto --noextattr --noqtn -c -k --keepParent "$APP" "$STAGE_ZIP"
mv "$APP" "$FINAL_APP"
mv -f "$STAGE_ZIP" "$FINAL_ZIP"
rmdir "$STAGE_ROOT"

# Verify the exact archive users receive, not the File Provider-managed copy.
VERIFY_ROOT="$(mktemp -d /private/tmp/lingxi-aimac-screen-verify.XXXXXX)"
ditto -x -k "$FINAL_ZIP" "$VERIFY_ROOT"
xattr -cr "$VERIFY_ROOT/$APP_NAME.app"
codesign --verify --deep --strict "$VERIFY_ROOT/$APP_NAME.app"
rm -rf "$VERIFY_ROOT"

echo "完成：$FINAL_APP"
echo "发布包：${FINAL_ZIP}（解压后严格签名校验通过）"
echo "独立数据目录：~/Library/Application Support/LingxiAIMacScreenExperimental"
