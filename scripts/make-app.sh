#!/bin/bash
# 构建 多屏灵犀.app（无需 Xcode，仅需 Command Line Tools + Swift）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 优先使用当前工具链的最新 SDK，不从调用环境继承旧 SDKROOT。
# 当前某些 CLT 27 版本缺少 SDK 27 需要的 SwiftUIMacros，选择器会对这一
# 个明确条件回退至 26.5；安装完整 Xcode 27 后会自动改用 SDK 27。
SDKROOT="$("$ROOT/scripts/select-macos-sdk")"
export SDKROOT
export SWIFT_EXEC="$ROOT/scripts/swiftc-sdk-compat"
# 明确保留 macOS 26 作为最低版本：使用 SDK 27 构建不应该让产物变成仅 macOS 27 可用。
export MACOSX_DEPLOYMENT_TARGET="26.0"
# 不依赖用户目录缓存权限；同时按 SDK 单独建缓存，防止 26/27 SDK 模块串入。
SDK_VERSION="$(plutil -extract Version raw "$SDKROOT/SDKSettings.plist" 2>/dev/null \
  || xcrun --sdk macosx --show-sdk-version)"
SDK_CACHE_TAG="${SDK_VERSION//./_}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache-$SDK_CACHE_TAG"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swiftpm-module-cache-$SDK_CACHE_TAG"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
echo "==> swift build -c release（SDK ${SDK_VERSION}，最低 macOS ${MACOSX_DEPLOYMENT_TARGET}）"
# 分发包不携带 dSYM；在 Documents / File Provider 目录中生成 dSYM 还可能被系统
# 扩展属性拦截。使用 SwiftPM 的产品级选项，避免它在编译结束后仍调用 dsymutil。
BUILD_PATH="${LINGXI_SWIFT_BUILD_PATH:-$ROOT/.build}"
BUILD_LOG="$(mktemp /private/tmp/lingxi-swift-build.XXXXXX)"
swift build -c release --product LinxDisplayApp --disable-sandbox -debug-info-format none --scratch-path "$BUILD_PATH" 2>&1 | tee "$BUILD_LOG"
# swiftbuild can exit successfully after a database I/O error and leave the old
# executable untouched. Never label and package that stale executable as a new build.
if rg -q '^error:' "$BUILD_LOG"; then
    echo "Swift build reported an error; refusing to package a stale executable ($BUILD_LOG)" >&2
    exit 1
fi

BIN="$BUILD_PATH/release/LinxDisplayApp"
APP_NAME="多屏灵犀 2.0 测试版"
EXEC_NAME="LingxiMultiScreen"
# 完整 2.0 测试主程序也可输出到独立候选目录，避免覆盖正在使用的测试包。
# Full 2.0 test builds may target a separate directory without replacing the current app.
OUTPUT_DIRECTORY="${LINGXI_APP_OUTPUT_DIRECTORY:-$ROOT/dist}"
FINAL_APP="$OUTPUT_DIRECTORY/$APP_NAME.app"
mkdir -p "$OUTPUT_DIRECTORY"
# Documents 可能由 File Provider 管理，直接在其中组装会被注入 Finder 扩展属性并破坏签名。
# 先在本机临时目录完成全部组装与签名，再把成品移动到 dist。
STAGE_ROOT="$(mktemp -d /private/tmp/lingxi-multiscreen-build.XXXXXX)"
APP="$STAGE_ROOT/$APP_NAME.app"

echo "==> 组装 $APP"
# Keep the last runnable test app in place until the new staged bundle passes
# resource and signature checks. A failed build must not remove the old app.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"
# 打包内置资源（应用图标；摘录画板预览背景：quote_0 设备 hero 图；口袋先知画板预览背景：Rand/0 设备 hero 图）
if [ -f "$ROOT/Resources/Icon.icns" ]; then
    cp "$ROOT/Resources/Icon.icns" "$APP/Contents/Resources/"
fi
# App chrome localization (development language zh-Hans + English)
if [ -d "$ROOT/Resources/Localization" ]; then
    for lproj in "$ROOT/Resources/Localization"/*.lproj; do
        [ -d "$lproj" ] || continue
        cp -R "$lproj" "$APP/Contents/Resources/"
    done
fi
if [ -f "$ROOT/Resources/quote_0_hero.png" ]; then
    cp "$ROOT/Resources/quote_0_hero.png" "$APP/Contents/Resources/"
fi
if [ -f "$ROOT/Resources/rand0_hero.png" ]; then
    cp "$ROOT/Resources/rand0_hero.png" "$APP/Contents/Resources/"
fi
# Official Pico shell and source attribution are required by native previews.
for resource in read_pico_hero.png read_pico_hero.NOTICE.txt; do
    [ -f "$ROOT/Resources/$resource" ] || { echo "Missing Pico preview resource: $resource" >&2; exit 1; }
    cp "$ROOT/Resources/$resource" "$APP/Contents/Resources/"
done
# 灵犀68 键盘设备外观图（实时预览打底，绿色显示区叠加渲染画面）
if [ -f "$ROOT/Resources/akko2.png" ]; then
    cp "$ROOT/Resources/akko2.png" "$APP/Contents/Resources/"
fi
# M5 StickS3 控制器透明产品图（主屏与按键提示预览）
if [ -f "$ROOT/Resources/Controller/m5-sticks3-cutout.png" ]; then
    cp "$ROOT/Resources/Controller/m5-sticks3-cutout.png" "$APP/Contents/Resources/"
fi
# AWTRIX NG 独立中文点阵：运行时从应用资源读取，不需要 Home Assistant。
if [ ! -f "$ROOT/Resources/AWTRIX/font_gb2312.bin" ] || [ ! -f "$ROOT/Resources/AWTRIX/font_ascii.bin" ]; then
    echo "错误：AWTRIX 中文点阵字库缺失" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources/AWTRIX"
cp "$ROOT/Resources/AWTRIX/font_gb2312.bin" "$APP/Contents/Resources/AWTRIX/"
cp "$ROOT/Resources/AWTRIX/font_ascii.bin" "$APP/Contents/Resources/AWTRIX/"
if [ -f "$ROOT/Resources/AWTRIX/FONT_LICENSE.md" ]; then
    cp "$ROOT/Resources/AWTRIX/FONT_LICENSE.md" "$APP/Contents/Resources/AWTRIX/"
fi
# AI Mac 小屏幕、M5 StickS3 内置固件与 Apple Silicon 刷机助手。正常运行不会启动助手，
# 只有用户在设备管理中二次确认刷写时才会执行。
FIRMWARE_SOURCE="$ROOT/Resources/Firmware/aimac-screen-0.8.6.bin"
M5_FIRMWARE_SOURCE="$ROOT/Resources/Firmware/m5-sticks3-1.5.5.bin"
FLASH_HELPER_SOURCE="$ROOT/Resources/Firmware/lingxi-esptool"
FIRMWARE_SHA256="55bfe4ca0088b143048d1002b7d9cd81673c8ae48f09c95d9c73791eabca8525"
M5_FIRMWARE_SHA256="7fe0b7e187076ba2eaa28cd8ae5cb051ff8c3ea301d90b3bc566a45279522697"
if [ ! -f "$FIRMWARE_SOURCE" ] || [ ! -f "$M5_FIRMWARE_SOURCE" ] || [ ! -f "$FLASH_HELPER_SOURCE" ]; then
    echo "错误：AI Mac / StickS3 固件或刷机助手缺失" >&2
    exit 1
fi
ACTUAL_FIRMWARE_SHA256="$(shasum -a 256 "$FIRMWARE_SOURCE" | awk '{print $1}')"
if [ "$ACTUAL_FIRMWARE_SHA256" != "$FIRMWARE_SHA256" ]; then
    echo "错误：AI Mac 小屏幕固件完整性校验失败" >&2
    exit 1
fi
ACTUAL_M5_FIRMWARE_SHA256="$(shasum -a 256 "$M5_FIRMWARE_SOURCE" | awk '{print $1}')"
if [ "$ACTUAL_M5_FIRMWARE_SHA256" != "$M5_FIRMWARE_SHA256" ]; then
    echo "错误：M5 StickS3 固件完整性校验失败" >&2
    exit 1
fi
# 一键刷机把单文件写到 0x0。除哈希外再验证完整镜像的关键偏移，防止把
# PlatformIO 默认的应用分区 firmware.bin（应写到 0x10000）误当成完整镜像。
M5_BOOT_MAGIC="$(xxd -p -l 1 -s 0 "$M5_FIRMWARE_SOURCE")"
M5_PARTITION_MAGIC="$(xxd -p -l 2 -s 32768 "$M5_FIRMWARE_SOURCE")"
M5_APP_MAGIC="$(xxd -p -l 1 -s 65536 "$M5_FIRMWARE_SOURCE")"
if [ "$M5_BOOT_MAGIC" != "e9" ] || [ "$M5_PARTITION_MAGIC" != "aa50" ] || [ "$M5_APP_MAGIC" != "e9" ]; then
    echo "错误：M5 StickS3 固件不是可从 0x0 写入的完整镜像" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources/Firmware"
for C6_NAME in lingxi-c6-2.0.0-full.bin lingxi-c6-2.0.0-ota.bin c6-manifest.json C6_FONT_LICENSE.txt C6_QR_LICENSE.txt; do
    if [ ! -f "$ROOT/Resources/Firmware/$C6_NAME" ]; then
        echo "错误：C6 内置资源缺失：$C6_NAME" >&2
        exit 1
    fi
    cp "$ROOT/Resources/Firmware/$C6_NAME" "$APP/Contents/Resources/Firmware/"
done
for C6_KIND in full ota; do
    C6_EXPECTED="$(plutil -extract "${C6_KIND}_sha256" raw "$ROOT/Resources/Firmware/c6-manifest.json")"
    C6_ACTUAL="$(shasum -a 256 "$ROOT/Resources/Firmware/lingxi-c6-2.0.0-${C6_KIND}.bin" | awk '{print $1}')"
    if [ "$C6_EXPECTED" != "$C6_ACTUAL" ]; then
        echo "错误：C6 $C6_KIND 固件哈希不匹配" >&2
        exit 1
    fi
done
if [ "$(plutil -extract version raw "$ROOT/Resources/Firmware/c6-manifest.json")" != "2.0.0-alpha.20" ] \
    || [ "$(xxd -p -l 2 -s 131084 "$ROOT/Resources/Firmware/lingxi-c6-2.0.0-full.bin")" != "0d00" ] \
    || [ "$(xxd -p -l 2 -s 12 "$ROOT/Resources/Firmware/lingxi-c6-2.0.0-ota.bin")" != "0d00" ]; then
    echo "错误：C6 固件版本或芯片不匹配" >&2
    exit 1
fi
# BEGIN READ_PICO_PACKAGE
# 中文：日常更新仅用 APP；首次安装资源独立校验，并只在分区不匹配且确认后使用。
# English: Normal updates use APP only; separately validate first-install resources for confirmed mismatches.
PICO_DIRECTORY="$ROOT/Resources/Firmware/ReadPico"
PICO_APP_SOURCE="$PICO_DIRECTORY/read-pico-app.bin"
PICO_MANIFEST_SOURCE="$PICO_DIRECTORY/manifest.json"
if [ -e "$PICO_DIRECTORY" ] || [ -L "$PICO_DIRECTORY" ]; then
    if [ ! -f "$PICO_APP_SOURCE" ] || [ ! -f "$PICO_MANIFEST_SOURCE" ]; then
        echo "错误：小纸 Pico APP 与 manifest.json 必须成对提供" >&2
        exit 1
    fi
    PICO_BOARD="$(plutil -extract board raw "$PICO_MANIFEST_SOURCE")"
    PICO_CHIP="$(plutil -extract chip raw "$PICO_MANIFEST_SOURCE")"
    PICO_VERSION="$(plutil -extract version raw "$PICO_MANIFEST_SOURCE")"
    PICO_ADDRESS="$(plutil -extract app_address raw "$PICO_MANIFEST_SOURCE")"
    PICO_SLOT_BYTES="$(plutil -extract slot_bytes raw "$PICO_MANIFEST_SOURCE")"
    PICO_IMAGE_BYTES="$(plutil -extract image_bytes raw "$PICO_MANIFEST_SOURCE")"
    PICO_KIND="$(plutil -extract kind raw "$PICO_MANIFEST_SOURCE" 2>/dev/null || true)"
    PICO_SHA256="$(plutil -extract sha256 raw "$PICO_MANIFEST_SOURCE" | tr '[:upper:]' '[:lower:]')"
    PICO_ACTUAL_BYTES="$(wc -c < "$PICO_APP_SOURCE" | tr -d '[:space:]')"
    if [ "$PICO_BOARD" != "read-pico-esp32s3" ] || [ "$PICO_CHIP" != "esp32s3" ] \
        || { [ "$PICO_ADDRESS" != "0x20000" ] && [ "$PICO_ADDRESS" != "131072" ]; } \
        || [ "$PICO_SLOT_BYTES" != "4194304" ] || [ -z "$PICO_VERSION" ] \
        || { [ -n "$PICO_KIND" ] && [ "$PICO_KIND" != "application" ]; } \
        || [ "$PICO_IMAGE_BYTES" != "$PICO_ACTUAL_BYTES" ] \
        || [ "$PICO_ACTUAL_BYTES" -lt 288 ] || [ "$PICO_ACTUAL_BYTES" -gt 4194304 ] \
        || [[ ! "$PICO_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "错误：小纸 Pico 固件清单的板卡、地址、版本、大小或类型无效" >&2
        exit 1
    fi
    PICO_ACTUAL_SHA256="$(shasum -a 256 "$PICO_APP_SOURCE" | awk '{print $1}')"
    PICO_DESCRIPTOR_VERSION="$(dd if="$PICO_APP_SOURCE" bs=1 skip=48 count=32 2>/dev/null | tr -d '\000')"
    PICO_DESCRIPTOR_PROJECT="$(dd if="$PICO_APP_SOURCE" bs=1 skip=80 count=32 2>/dev/null | tr -d '\000')"
    if [ "$PICO_ACTUAL_SHA256" != "$PICO_SHA256" ] \
        || [ "$(xxd -p -l 1 "$PICO_APP_SOURCE")" != "e9" ] \
        || [ "$(xxd -p -l 2 -s 12 "$PICO_APP_SOURCE")" != "0900" ] \
        || [ "$(xxd -p -l 4 -s 32 "$PICO_APP_SOURCE")" != "3254cdab" ] \
        || [ "$PICO_DESCRIPTOR_PROJECT" != "Read_Pico" ] \
        || [ "$PICO_DESCRIPTOR_VERSION" != "$PICO_VERSION" ]; then
        echo "错误：小纸 Pico APP 哈希或 ESP32-S3 芯片校验失败" >&2
        exit 1
    fi
    # Always validate declared TF resources, including a missing tree; legacy APP-only manifests remain supported.
    python3 "$ROOT/scripts/validate-readpico-tf-resources.py" "$PICO_DIRECTORY"
    if [ -e "$PICO_DIRECTORY/fresh-install.json" ]; then
        python3 "$ROOT/scripts/validate-readpico-first-install.py" "$PICO_DIRECTORY"
    fi
    PICO_MANIFEST_SHA256="$(shasum -a 256 "$PICO_MANIFEST_SOURCE" | awk '{print $1}')"
    PICO_DESTINATION="$APP/Contents/Resources/Firmware/ReadPico"
    mkdir -p "$PICO_DESTINATION"
    cp "$PICO_APP_SOURCE" "$PICO_DESTINATION/read-pico-app.bin"
    cp "$PICO_MANIFEST_SOURCE" "$PICO_DESTINATION/manifest.json"
    if [ "$(shasum -a 256 "$PICO_DESTINATION/read-pico-app.bin" | awk '{print $1}')" != "$PICO_SHA256" ] \
        || [ "$(shasum -a 256 "$PICO_DESTINATION/manifest.json" | awk '{print $1}')" != "$PICO_MANIFEST_SHA256" ]; then
        echo "错误：小纸 Pico 资源复制校验失败" >&2
        exit 1
    fi
    # 首次安装的固定资源与普通 APP 更新隔离；仅在明确确认分区迁移时使用。
    # Keep first-install resources separate from normal APP updates; migration requires explicit consent.
    if [ -e "$PICO_DIRECTORY/fresh-install.json" ]; then
        cp "$PICO_DIRECTORY/fresh-install.json" "$PICO_DESTINATION/fresh-install.json"
        for PICO_INITIAL_FILE in bootloader.bin partition-table.bin ota-data.bin assets.bin storage.bin; do
            if [ -f "$PICO_DIRECTORY/$PICO_INITIAL_FILE" ]; then
                cp "$PICO_DIRECTORY/$PICO_INITIAL_FILE" "$PICO_DESTINATION/$PICO_INITIAL_FILE"
            fi
        done
        python3 "$ROOT/scripts/validate-readpico-first-install.py" "$PICO_DESTINATION"
    fi
    # 附带的 TF 包仅供显式导入；固件升级不会自动写入 TF 卡。
    # Bundled TF packages require explicit import; firmware updates never install them automatically.
    if [ -d "$PICO_DIRECTORY/tf-card" ]; then
        cp -R "$PICO_DIRECTORY/tf-card" "$PICO_DESTINATION/tf-card"
        cp "$PICO_DIRECTORY/tf-manifest.json" "$PICO_DESTINATION/tf-manifest.json"
        diff -rq "$PICO_DIRECTORY/tf-card" "$PICO_DESTINATION/tf-card"
    fi
    if [ -d "$PICO_DIRECTORY/validation" ]; then
        cp -R "$PICO_DIRECTORY/validation" "$PICO_DESTINATION/validation"
        diff -rq "$PICO_DIRECTORY/validation" "$PICO_DESTINATION/validation"
    fi
    echo "==> 已校验并内置小纸 Pico APP：$PICO_VERSION"
else
    echo "==> 未提供小纸 Pico 内置固件，管理页保留本地文件选择"
fi
# END READ_PICO_PACKAGE
cp "$FIRMWARE_SOURCE" "$APP/Contents/Resources/Firmware/"
cp "$M5_FIRMWARE_SOURCE" "$APP/Contents/Resources/Firmware/"
cp "$FLASH_HELPER_SOURCE" "$APP/Contents/Resources/Firmware/"
chmod 755 "$APP/Contents/Resources/Firmware/lingxi-esptool"
if [ -f "$ROOT/Resources/Firmware/THIRD_PARTY_NOTICES.txt" ]; then
    cp "$ROOT/Resources/Firmware/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/Firmware/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LingxiMultiScreen</string>
	<key>CFBundleIdentifier</key>
	<string>com.lingxi.multiscreen.beta2</string>
	<key>CFBundleName</key>
	<string>多屏灵犀 2.0 测试版</string>
	<key>CFBundleDisplayName</key>
	<string>多屏灵犀 2.0 测试版</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>zh-Hans</string>
		<string>en</string>
	</array>
	<key>CFBundleIconFile</key>
	<string>Icon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0.0</string>
	<key>CFBundleVersion</key>
	<string>86</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSInputMonitoringUsageDescription</key>
	<string>用于接收灵犀68的 Fn + 旋钮事件，并在用户主动启用时将其转换为手动翻页。</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>用于连接局域网设备，以及在你主动开启时让手机扫码配置微信读书授权。</string>
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>仅在刷机配网时获取附近 2.4 GHz Wi-Fi 的网络名称，方便选择 SSID；不获取、保存或上传地理位置。</string>
	<key>NSLocationUsageDescription</key>
	<string>仅在刷机配网时获取附近 2.4 GHz Wi-Fi 的网络名称，方便选择 SSID；不获取、保存或上传地理位置。</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>用于通过蓝牙连接 M5Stack StickS3 控制器，接收摇晃翻页与按键切换设备信号。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>用于通过蓝牙连接 M5Stack StickS3 控制器，接收摇晃翻页与按键切换设备信号。</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_home-assistant._tcp</string>
		<string>_lingxi-aimac._tcp</string>
		<string>_http._tcp</string>
	</array>
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
# 嵌套可执行文件先单独签名，再签整个应用，避免 Gatekeeper 将刷机助手识别为未签名组件。
codesign --force --sign - "$APP/Contents/Resources/Firmware/lingxi-esptool"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

if [ -d "$FINAL_APP" ]; then
    ROLLBACK_ROOT="$(mktemp -d "$OUTPUT_DIRECTORY/.rollback-beta2.XXXXXX")"
    mv "$FINAL_APP" "$ROLLBACK_ROOT/$APP_NAME.app"
fi
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
