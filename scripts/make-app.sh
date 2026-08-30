#!/bin/bash
# 构建 多屏灵犀.app（无需 Xcode，仅需 Command Line Tools + Swift）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release --product LinxDisplayApp --disable-sandbox

BIN=".build/release/LinxDisplayApp"
APP_NAME="多屏灵犀"
EXEC_NAME="LingxiMultiScreen"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> 组装 $APP"
# 旧包移入回收目录（避免 rm -rf 被安全策略拦截导致打包失败）
if [ -d "$APP" ]; then
    mv -f "$APP" "$ROOT/dist/.trash-$APP_NAME-$(date +%s)" 2>/dev/null || true
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"
# 打包内置资源（应用图标；摘录画板预览背景：quote_0 设备 hero 图；口袋先知画板预览背景：Rand/0 设备 hero 图）
if [ -f "$ROOT/Resources/Icon.icns" ]; then
    cp "$ROOT/Resources/Icon.icns" "$APP/Contents/Resources/"
fi
if [ -f "$ROOT/Resources/quote_0_hero.png" ]; then
    cp "$ROOT/Resources/quote_0_hero.png" "$APP/Contents/Resources/"
fi
if [ -f "$ROOT/Resources/rand0_hero.png" ]; then
    cp "$ROOT/Resources/rand0_hero.png" "$APP/Contents/Resources/"
fi
# 灵犀68 键盘设备外观图（实时预览打底，绿色显示区叠加渲染画面）
if [ -f "$ROOT/Resources/akko2.png" ]; then
    cp "$ROOT/Resources/akko2.png" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LingxiMultiScreen</string>
	<key>CFBundleIdentifier</key>
	<string>com.lingxi.multiscreen</string>
	<key>CFBundleName</key>
	<string>多屏灵犀</string>
	<key>CFBundleDisplayName</key>
	<string>多屏灵犀</string>
	<key>CFBundleIconFile</key>
	<string>Icon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.5.0</string>
	<key>CFBundleVersion</key>
	<string>7</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>多屏灵犀 for macOS - 灵犀68 键盘 / 口袋先知 / 摘录 多屏驱动</string>
</dict>
</plist>
PLIST

# 临时签名（本机运行用；如需分发需 Developer ID 证书）
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> 完成：$APP"
echo "    打开方式：open $APP"
