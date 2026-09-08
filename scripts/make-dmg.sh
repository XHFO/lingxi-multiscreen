#!/bin/bash
# 构建并验证可发布的多屏灵犀 DMG。磁盘映像仅包含应用本体与 Applications 快捷入口。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="多屏灵犀"
APP_SOURCE="$ROOT/dist/$APP_NAME.app"

"$ROOT/scripts/make-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")"
DMG_PATH="$ROOT/dist/lingxi-multiscreen-$VERSION.dmg"
STAGE_ROOT="$(mktemp -d /private/tmp/lingxi-multiscreen-dmg.XXXXXX)"
STAGE_DIR="$STAGE_ROOT/source"
trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$STAGE_DIR"
ditto --noextattr --noqtn "$APP_SOURCE" "$STAGE_DIR/$APP_NAME.app"
xattr -cr "$STAGE_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> 创建 $DMG_PATH"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

hdiutil verify "$DMG_PATH"
echo "==> DMG 完成：$DMG_PATH"
