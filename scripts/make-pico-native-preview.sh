#!/bin/bash
# Build the real SwiftUI views in the 2.0 app, without starting device services.
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
export SDKROOT="$(scripts/select-macos-sdk)"
export SWIFT_EXEC="$native_root/scripts/swiftc-sdk-compat"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$native_root/.build/pico-native-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/pico-native-swift-cache"
swift build -c release --product LinxDisplayApp --disable-sandbox -debug-info-format none

native_output="${PICO_NATIVE_PREVIEW_OUTPUT:-$native_root/dist/candidates/pico-native-20261024}"
native_stage="$(mktemp -d /private/tmp/lingxi-pico-native.XXXXXX)"
native_name="多屏灵犀 Pico 原生预览"
native_app="$native_stage/$native_name.app"
mkdir -p "$native_app/Contents/MacOS" "$native_app/Contents/Resources" "$native_output"
cp .build/release/LinxDisplayApp "$native_app/Contents/MacOS/LingxiPicoNativePreview"
if [ -f Resources/Icon.icns ]; then cp Resources/Icon.icns "$native_app/Contents/Resources/Icon.icns"; fi
cat > "$native_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>net.xhfo.lingxi.pico-native-preview</string>
<key>CFBundleExecutable</key><string>LingxiPicoNativePreview</string>
<key>CFBundleName</key><string>多屏灵犀 Pico 原生预览</string>
<key>CFBundleDisplayName</key><string>多屏灵犀 Pico 原生预览</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Icon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>PicoNativeDesignPreview</key><true/>
</dict></plist>
PLIST
xattr -cr "$native_app"
codesign --force --sign - "$native_app"
codesign --verify --deep --strict "$native_app"
native_final="$native_output/$native_name.app"
if [ -d "$native_final" ]; then
    native_previous="$(mktemp -d "$native_output/previous.XXXXXX")"
    mv "$native_final" "$native_previous/"
fi
mv "$native_app" "$native_final"
rmdir "$native_stage"
printf '%s\n' "$native_final"
