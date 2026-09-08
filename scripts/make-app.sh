#!/bin/bash
# 构建 多屏灵犀.app（无需 Xcode，仅需 Command Line Tools + Swift）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 始终使用当前 Command Line Tools 的 macOS SDK。不能从调用环境继承旧 SDKROOT：
# 用 15.x SDK 构建虽然仍能运行在 macOS 26，却会让 SwiftUI 进入旧版兼容外观，
# NavigationSplitView 侧边栏因此与 03:28 的 SDK 26.5 构建不一致。
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export SWIFT_EXEC="$ROOT/scripts/swiftc-sdk-compat"
# 不依赖用户目录缓存权限；同时按 SDK 单独建缓存，防止旧 SDK 模块串入构建。
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache-26"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swiftpm-module-cache-26"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
echo "==> swift build -c release（SDK $(xcrun --sdk macosx --show-sdk-version)）"
swift build -c release --product LinxDisplayApp --disable-sandbox

BIN=".build/release/LinxDisplayApp"
APP_NAME="多屏灵犀"
EXEC_NAME="LingxiMultiScreen"
FINAL_APP="$ROOT/dist/$APP_NAME.app"
# Documents 可能由 File Provider 管理，直接在其中组装会被注入 Finder 扩展属性并破坏签名。
# 先在本机临时目录完成全部组装与签名，再把成品移动到 dist。
STAGE_ROOT="$(mktemp -d /private/tmp/lingxi-multiscreen-build.XXXXXX)"
APP="$STAGE_ROOT/$APP_NAME.app"

echo "==> 组装 $APP"
# 旧包移入回收目录（避免 rm -rf 被安全策略拦截导致打包失败）
if [ -d "$FINAL_APP" ]; then
    mv -f "$FINAL_APP" "$ROOT/dist/.trash-$APP_NAME-$(date +%s)" 2>/dev/null || true
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
	<string>1.5.3</string>
	<key>CFBundleVersion</key>
	<string>14</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSInputMonitoringUsageDescription</key>
	<string>用于接收灵犀68的 Fn + 旋钮事件，并在用户主动启用时将其转换为手动翻页。</string>
	<key>NSHumanReadableCopyright</key>
	<string>多屏灵犀 for macOS - 灵犀68 键盘 / 口袋先知 / 摘录 多屏驱动</string>
</dict>
</plist>
PLIST

# 临时签名（本机运行用；如需分发需 Developer ID 证书）。
# Finder/File Provider 写入的扩展属性会让签名失败；先清理，再强制校验，禁止静默产出坏包。
xattr -cr "$APP"
# 位于文件同步目录时，根目录的 Finder/File Provider 标记可能不会被 -c 清除，
# 但它们会让 codesign 报 “resource fork, Finder information … not allowed”。
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mv "$APP" "$FINAL_APP"
rmdir "$STAGE_ROOT"
# File Provider 可能在移动到 dist 时立即给包根目录重新附加元数据；先尽量清理。
xattr -d com.apple.FinderInfo "$FINAL_APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$FINAL_APP" 2>/dev/null || true
# Documents 中的 File Provider 可能在清理后马上重新写入 FinderInfo，使原路径的
# codesign --strict 出现假失败。复制到不受 File Provider 管理的临时目录，剥离所有
# 扩展属性后做最终严格校验；GitHub 发布包也必须从这种干净副本创建。
VERIFY_ROOT="$(mktemp -d /private/tmp/lingxi-multiscreen-verify.XXXXXX)"
VERIFY_APP="$VERIFY_ROOT/$APP_NAME.app"
ditto --noextattr --noqtn "$FINAL_APP" "$VERIFY_APP"
xattr -cr "$VERIFY_APP"
codesign --verify --deep --strict "$VERIFY_APP"
rm -rf "$VERIFY_ROOT"

echo "==> 完成：$FINAL_APP"
echo "    严格签名校验：通过（File Provider 外的干净副本）"
echo "    打开方式：open $FINAL_APP"
