// 多屏灵犀 M5 控制器固件 —— M5Stack StickS3 (ESP32-S3-PICO-1)
//
// 角色：主应用（Mac）的蓝牙控制端。
//   * 作为 BLE GATT 外设广播自定义服务，等待 Mac 端多屏灵犀连接；
//   * 摇晃设备（BMI270 手势）→ 上报翻页事件，Mac 据此翻页当前被控设备内容；
//   * 两个按键 BtnA / BtnB → 上报按键事件，Mac 据此在被控设备之间循环切换；
//   * Mac 通过信息特征把「被控设备列表 + 当前页信息」写回来，本机屏幕直接渲染。
//
// 显示：每屏固定 3 台设备，超出自动分页（页码跟随当前选中设备）；
//       头部大字标题 + 连接状态胶囊 + 电池电量/充电指示。
// 电源：静置 15s 调暗并进入 BLE 低占空比连接 → 45s 息屏 → 10min 深度休眠（按 A/B 唤醒）。
//
// 硬件由 M5Unified 运行时自动识别（StickS3：135×240 ST7789 屏 / BMI270 / GPIO11+12 两键）。
// GATT 与事件/信息格式必须与 Mac 端 LinxDisplayCore/M5ControllerSupport.swift 保持一致。

#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_mac.h>
#include <esp_sleep.h>
#include <driver/rtc_io.h>
#include <vector>
#include <string>
#include <mutex>

// 现场诊断开关：默认关闭；构建时加 -DM5_DIAG=1 打开，每 5 秒打印一次运行状态
#ifndef M5_DIAG
#define M5_DIAG 0
#endif
#if M5_DIAG
static int g_diagPctRaw = -1;   // 平均后的原始电量（未限幅），便于观察采样噪声
#endif

// MARK: - GATT 标识（与 Mac 端 M5ControllerBLE 常量一致）

static const char *SERVICE_UUID = "E0A3C001-5B4C-4D2E-9F8A-6C1D2E3F4A50";
// 事件特征：本机 notify，Mac 订阅（按键 / 摇晃）
static const char *EVENT_CHAR_UUID = "E0A3C002-5B4C-4D2E-9F8A-6C1D2E3F4A50";
// 信息特征：Mac write，本机屏幕显示被控设备信息
static const char *INFO_CHAR_UUID = "E0A3C003-5B4C-4D2E-9F8A-6C1D2E3F4A50";
static const char *ADV_NAME_PREFIX = "Lingxi-Controller";

// MARK: - 全局状态

struct DevInfo {
    String name;
    String detail;
    bool available;
};

static std::vector<DevInfo> g_devices;   // 被 Mac 写入的被控设备列表
static int g_active = 0;                 // 当前选中的被控设备下标
static String g_title = "灵犀控制器";    // Mac 可按当前页面覆盖
static String g_footer = "摇动翻页 A/B切换";
static std::mutex g_mutex;               // 保护 g_devices / g_active（BLE 任务 vs 主循环）
static const int ROWS_PER_PAGE = 3;       // 单屏最多 3 项，超出分页

static volatile bool g_dirty = true;         // 需要整屏重绘（设备列表 / 连接状态变化）
static volatile bool g_headerDirty = true;   // 只需重绘头部（电量 / 充电）
static volatile bool g_bodyDirty = false;    // 只需重绘卡片区（选中项 / 文本变化）
static volatile bool g_footerDirty = false;  // 只需重绘底部操作提示
static volatile bool g_connected = false;    // BLE 是否已连接
static volatile bool g_blePing = false;      // BLE 有写入：唤醒屏幕并重置休眠计时
static bool g_buzzerEnabled = true;           // 由每台控制器的 Mac 端设置同步

static NimBLECharacteristic *g_eventChar = nullptr;
static NimBLECharacteristic *g_infoChar = nullptr;
static NimBLEHIDDevice *g_hidDevice = nullptr;
static NimBLECharacteristic *g_hidInputReport = nullptr;
static NimBLECharacteristic *g_hidConsumerReport = nullptr;
static NimBLECharacteristic *g_hidMouseReport = nullptr;
static NimBLECharacteristic *g_hidBootInput = nullptr;
static NimBLEServer *g_bleServer = nullptr;
static volatile uint16_t g_connHandle = BLE_HS_CONN_HANDLE_NONE;
static bool g_bleIdleProfile = false;
static volatile uint8_t g_hidModifiers = 0;
static volatile uint8_t g_hidKey = 0;
static volatile bool g_hidHold = false;
static volatile bool g_hidHeld = false;
static volatile bool g_clearInputOnShake = false;
static volatile uint16_t g_consumerUsage = 0;
static volatile uint16_t g_consumerUsageLeft = 0;
static volatile uint16_t g_consumerUsageRight = 0;
static volatile bool g_gyroMouseMode = false;
static volatile float g_gyroMouseSensitivity = 1.0f;
static volatile float g_gyroMouseDeadZone = 1.4f;
static volatile float g_gyroMouseSmoothing = 0.58f;
static volatile bool g_gyroMouseInvertX = false;
static volatile bool g_gyroMouseInvertY = false;
static volatile bool g_gyroMouseClutchEnabled = false;
static volatile bool g_gyroMouseSuspended = false;
static volatile uint8_t g_mouseButtons = 0;
static volatile bool g_mouseDragActive = false;
static volatile int g_mouseCalibrationSamples = 0;
// 50 Hz 活跃采样下约 0.5 秒。只有连续静止达到该窗口才接受校准，避免把
// 用户还在调整握姿时的角速度误当成零偏。
static const int MOUSE_CALIBRATION_SAMPLE_COUNT = 24;
static float g_mouseCalibrationGyroSumX = 0.0f;
static float g_mouseCalibrationGyroSumY = 0.0f;
static float g_mouseCalibrationGyroSumZ = 0.0f;
static float g_mouseCalibrationAccelSumX = 0.0f;
static float g_mouseCalibrationAccelSumY = 0.0f;
static float g_mouseCalibrationAccelSumZ = 0.0f;
static float g_mouseBiasX = 0.0f;
static float g_mouseBiasY = 0.0f;
static float g_mouseBiasZ = 0.0f;
// 校准时记录用户自然握姿下的重力方向。水平移动取绕重力轴的转动，
// 因此竖握时是左右转腕，平握时会自动过渡为绕屏幕法线的扭腕动作。
static float g_mouseGravityX = 0.0f;
static float g_mouseGravityY = 1.0f;
static float g_mouseGravityZ = 0.0f;
static float g_mouseRightX = 1.0f;
static float g_mouseRightY = 0.0f;
static float g_mouseRightZ = 0.0f;
static uint32_t g_mouseCalibrationCompletedAt = 0;
static uint32_t g_lastGyroRecenterToken = 0;
static bool g_hasGyroRecenterToken = false;
static float g_mouseFilteredX = 0.0f;
static float g_mouseFilteredY = 0.0f;
static float g_mouseFractionX = 0.0f;
static float g_mouseFractionY = 0.0f;
static uint32_t g_mouseLastSampleAt = 0;
static volatile bool g_hidSecured = false;
static bool g_pairingRecoveryAttempted = false;
static int8_t g_lastReportedHIDReady = -1;
static int8_t g_lastReportedHIDSecured = -1;

// 软件勾选的功能清单会以紧凑位图保存在 NVS。这样控制器重启后无需等待
// Mac 重新传一帧菜单，就能直接显示上次同步的本地主菜单。
static uint8_t g_mainMenuMask = 0;
static uint8_t g_shortcutMenuMask = 0;
static uint8_t g_targetDeviceCount = 0;
static uint8_t g_homeAssistantEntityCount = 0;
static uint8_t g_vibeActionCount = 0;
static uint8_t g_presentationActionCount = 0;
static uint8_t g_customActionCount = 0;
static bool g_hasMenuManifest = false;

static uint8_t clampMenuCount(int value) {
    return (uint8_t)min(max(value, 0), 99);
}

static void buildRootMenuFromManifest() {
    if (!g_hasMenuManifest) return;
    std::vector<DevInfo> list;
    if (g_mainMenuMask & 0x01) {
        list.push_back({"Vibe Coding", String(g_vibeActionCount) + " 个可用动作",
                        g_vibeActionCount > 0});
    }
    if (g_mainMenuMask & 0x02) {
        list.push_back({"多屏设备", String(g_targetDeviceCount) + " 台已配置",
                        g_targetDeviceCount > 0});
    }
    if (g_mainMenuMask & 0x04) {
        list.push_back({"Home Assistant",
                        String(g_homeAssistantEntityCount) + " 个控制实体",
                        g_homeAssistantEntityCount > 0});
    }
    if (g_mainMenuMask & 0x08) {
        int localCount = ((g_shortcutMenuMask & 0x01) ? 1 : 0)
                       + ((g_shortcutMenuMask & 0x02) ? 1 : 0);
        int actionGroups = ((g_shortcutMenuMask & 0x04) ? 1 : 0)
                         + ((g_shortcutMenuMask & 0x08) ? 1 : 0);
        String detail = String(localCount) + " 个本地功能";
        if (actionGroups > 0) detail += String(" + ") + actionGroups + " 组动作";
        list.push_back({"Mac 快捷键", detail, true});
    }
    if (list.empty()) {
        list.push_back({"尚未启用功能", "请在 Mac 软件中勾选", false});
    }
    std::lock_guard<std::mutex> lk(g_mutex);
    g_devices = list;
    g_active = 0;
    g_title = "灵犀控制器";
    g_footer = "A/B选择 长A进入";
}

static void loadMenuManifest() {
    Preferences prefs;
    if (!prefs.begin("lingxi-menu", true)) return;
    g_hasMenuManifest = prefs.getBool("valid", false);
    g_mainMenuMask = prefs.getUChar("main", 0);
    g_shortcutMenuMask = prefs.getUChar("shortcut", 0);
    g_targetDeviceCount = prefs.getUChar("targets", 0);
    g_homeAssistantEntityCount = prefs.getUChar("ha", 0);
    g_vibeActionCount = prefs.getUChar("vibe", 0);
    g_presentationActionCount = prefs.getUChar("present", 0);
    g_customActionCount = prefs.getUChar("custom", 0);
    prefs.end();
    buildRootMenuFromManifest();
}

static void updateMenuManifest(int mainMask, int shortcutMask, int targetCount,
                               int haCount, int vibeCount, int presentationCount,
                               int customCount) {
    if (mainMask < 0 || shortcutMask < 0) return;
    const uint8_t newMain = (uint8_t)(mainMask & 0x0F);
    const uint8_t newShortcut = (uint8_t)(shortcutMask & 0x0F);
    const uint8_t newTargets = clampMenuCount(targetCount);
    const uint8_t newHA = clampMenuCount(haCount);
    const uint8_t newVibe = clampMenuCount(vibeCount);
    const uint8_t newPresentation = clampMenuCount(presentationCount);
    const uint8_t newCustom = clampMenuCount(customCount);
    const bool changed = !g_hasMenuManifest || g_mainMenuMask != newMain
        || g_shortcutMenuMask != newShortcut || g_targetDeviceCount != newTargets
        || g_homeAssistantEntityCount != newHA || g_vibeActionCount != newVibe
        || g_presentationActionCount != newPresentation
        || g_customActionCount != newCustom;
    if (!changed) return;
    g_hasMenuManifest = true;
    g_mainMenuMask = newMain;
    g_shortcutMenuMask = newShortcut;
    g_targetDeviceCount = newTargets;
    g_homeAssistantEntityCount = newHA;
    g_vibeActionCount = newVibe;
    g_presentationActionCount = newPresentation;
    g_customActionCount = newCustom;
    Preferences prefs;
    if (!prefs.begin("lingxi-menu", false)) return;
    prefs.putBool("valid", true);
    prefs.putUChar("main", g_mainMenuMask);
    prefs.putUChar("shortcut", g_shortcutMenuMask);
    prefs.putUChar("targets", g_targetDeviceCount);
    prefs.putUChar("ha", g_homeAssistantEntityCount);
    prefs.putUChar("vibe", g_vibeActionCount);
    prefs.putUChar("present", g_presentationActionCount);
    prefs.putUChar("custom", g_customActionCount);
    prefs.end();
}

// Report ID 1 为标准 8-byte Boot Keyboard；Report ID 2 为 16-bit Consumer Control；
// Report ID 3 为三键相对坐标鼠标。因此键盘、媒体键和陀螺仪鼠标都由 StickS3
// 作为真实蓝牙输入设备发送，不依赖 Mac 辅助功能权限。
static uint8_t HID_REPORT_MAP[] = {
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x06,       // Usage (Keyboard)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x01,       //   Report ID (1)
    0x05, 0x07,       //   Usage Page (Keyboard)
    0x19, 0xE0,       //   Usage Minimum (Left Control)
    0x29, 0xE7,       //   Usage Maximum (Right GUI)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x01,       //   Logical Maximum (1)
    0x75, 0x01,       //   Report Size (1)
    0x95, 0x08,       //   Report Count (8)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x95, 0x01,       //   Report Count (1)
    0x75, 0x08,       //   Report Size (8)
    0x81, 0x01,       //   Input (Constant)
    0x95, 0x06,       //   Report Count (6)
    0x75, 0x08,       //   Report Size (8)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x65,       //   Logical Maximum (101)
    0x05, 0x07,       //   Usage Page (Keyboard)
    0x19, 0x00,       //   Usage Minimum (Reserved)
    0x29, 0x65,       //   Usage Maximum (Keyboard Application)
    0x81, 0x00,       //   Input (Data, Array)
    0xC0,             // End Collection

    0x05, 0x0C,       // Usage Page (Consumer)
    0x09, 0x01,       // Usage (Consumer Control)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x02,       //   Report ID (2)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x03, //   Logical Maximum (1023)
    0x19, 0x00,       //   Usage Minimum (Unassigned)
    0x2A, 0xFF, 0x03, //   Usage Maximum (0x03FF)
    0x75, 0x10,       //   Report Size (16)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x00,       //   Input (Data, Array, Absolute)
    0xC0,             // End Collection

    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x02,       // Usage (Mouse)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x03,       //   Report ID (3)
    0x09, 0x01,       //   Usage (Pointer)
    0xA1, 0x00,       //   Collection (Physical)
    0x05, 0x09,       //     Usage Page (Button)
    0x19, 0x01,       //     Usage Minimum (Button 1)
    0x29, 0x03,       //     Usage Maximum (Button 3)
    0x15, 0x00,       //     Logical Minimum (0)
    0x25, 0x01,       //     Logical Maximum (1)
    0x95, 0x03,       //     Report Count (3)
    0x75, 0x01,       //     Report Size (1)
    0x81, 0x02,       //     Input (Data, Variable, Absolute)
    0x95, 0x01,       //     Report Count (1)
    0x75, 0x05,       //     Report Size (5)
    0x81, 0x01,       //     Input (Constant)
    0x05, 0x01,       //     Usage Page (Generic Desktop)
    0x09, 0x30,       //     Usage (X)
    0x09, 0x31,       //     Usage (Y)
    0x09, 0x38,       //     Usage (Wheel)
    0x15, 0x81,       //     Logical Minimum (-127)
    0x25, 0x7F,       //     Logical Maximum (127)
    0x75, 0x08,       //     Report Size (8)
    0x95, 0x03,       //     Report Count (3)
    0x81, 0x06,       //     Input (Data, Variable, Relative)
    0xC0,             //   End Collection
    0xC0              // End Collection
};

// 电源状态缓存（主循环周期性读 PMIC，避免每次重绘都走 I2C）
static int g_batteryPct = -1;            // -1 = 读取失败/无电池
static bool g_charging = false;
static bool g_vbusPresent = false;
static uint32_t g_batteryNextRead = 0;
static bool g_chgRaw = false;            // 充电状态去抖：最近一次原始读数
static int g_chgStreak = 0;              // 连续相同次数

// MARK: - 屏幕配色（RGB565）

static uint16_t colBg() { return M5.Display.color565(12, 15, 19); }
static uint16_t colPanel() { return M5.Display.color565(30, 37, 46); }
static uint16_t colPanelHi() { return M5.Display.color565(44, 54, 66); }
static uint16_t colAccent() { return M5.Display.color565(45, 127, 249); }
static uint16_t colText() { return M5.Display.color565(240, 243, 247); }
static uint16_t colSub() { return M5.Display.color565(170, 178, 190); }
static uint16_t colDim() { return M5.Display.color565(112, 120, 132); }
static uint16_t colGreen() { return M5.Display.color565(52, 199, 123); }
static uint16_t colAmber() { return M5.Display.color565(255, 176, 32); }
static uint16_t colRed() { return M5.Display.color565(255, 69, 58); }

// MARK: - 事件上报

// 通过事件特征把一条 JSON 文本 notify 给 Mac（未连接时丢弃）
static void sendEvent(const char *json) {
    if (!g_connected || g_eventChar == nullptr) return;
    g_eventChar->setValue((uint8_t *)json, strlen(json));
    g_eventChar->notify();
}

static void sendButton(const char *key, bool longPress = false) {
    char buf[64];
    if (longPress) {
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"button\",\"key\":\"%s\",\"press\":\"long\"}", key);
    } else {
        snprintf(buf, sizeof(buf), "{\"type\":\"button\",\"key\":\"%s\"}", key);
    }
    sendEvent(buf);
}

static void sendButtonUp(const char *key) {
    char buf[72];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"button\",\"key\":\"%s\",\"press\":\"up\"}", key);
    sendEvent(buf);
}

static void sendButtonHID(const char *key, bool down) {
    char buf[80];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"button\",\"key\":\"%s\",\"press\":\"%s\"}",
             key, down ? "hid-long" : "hid-up");
    sendEvent(buf);
}

static void sendPointerRecenter() {
    sendEvent("{\"type\":\"mouse\",\"action\":\"recenter\"}");
}

static bool hidHostReady() {
    return (g_hidInputReport != nullptr && g_hidInputReport->getSubscribedCount() > 0)
        || (g_hidConsumerReport != nullptr && g_hidConsumerReport->getSubscribedCount() > 0)
        || (g_hidMouseReport != nullptr && g_hidMouseReport->getSubscribedCount() > 0)
        || (g_hidBootInput != nullptr && g_hidBootInput->getSubscribedCount() > 0);
}

static bool consumerHostReady() {
    return g_hidConsumerReport != nullptr
        && g_hidConsumerReport->getSubscribedCount() > 0;
}

static bool mouseHostReady() {
    return g_hidMouseReport != nullptr && g_hidMouseReport->getSubscribedCount() > 0;
}

static void notifyMouseReport(uint8_t buttons, int8_t dx = 0, int8_t dy = 0,
                              int8_t wheel = 0) {
    if (!mouseHostReady()) return;
    uint8_t report[4] = {
        (uint8_t)(buttons & 0x07), (uint8_t)dx, (uint8_t)dy, (uint8_t)wheel
    };
    g_hidMouseReport->setValue(report, sizeof(report));
    g_hidMouseReport->notify();
}

static void releaseGyroMouseButtons() {
    g_mouseDragActive = false;
    if (g_mouseButtons == 0) return;
    g_mouseButtons = 0;
    notifyMouseReport(0);
}

static bool clickMouseButton(uint8_t mask) {
    if (!g_connected || !mouseHostReady()) return false;
    notifyMouseReport(mask);
    delay(14);
    notifyMouseReport(0);
    return true;
}

static void resetGyroMouseCalibrationWindow() {
    g_mouseCalibrationSamples = MOUSE_CALIBRATION_SAMPLE_COUNT;
    g_mouseCalibrationGyroSumX = 0.0f;
    g_mouseCalibrationGyroSumY = 0.0f;
    g_mouseCalibrationGyroSumZ = 0.0f;
    g_mouseCalibrationAccelSumX = 0.0f;
    g_mouseCalibrationAccelSumY = 0.0f;
    g_mouseCalibrationAccelSumZ = 0.0f;
}

static void startGyroMouseCalibration() {
    releaseGyroMouseButtons();
    g_gyroMouseSuspended = false;
    resetGyroMouseCalibrationWindow();
    g_mouseCalibrationCompletedAt = 0;
    g_mouseFilteredX = 0.0f;
    g_mouseFilteredY = 0.0f;
    g_mouseFractionX = 0.0f;
    g_mouseFractionY = 0.0f;
    g_mouseLastSampleAt = 0;
    g_bodyDirty = true;
}

static void notifyHIDReport(uint8_t modifiers) {
    uint8_t report[8] = {modifiers, 0, 0, 0, 0, 0, 0, 0};
    if (g_hidInputReport != nullptr && g_hidInputReport->getSubscribedCount() > 0) {
        g_hidInputReport->setValue(report, sizeof(report));
        g_hidInputReport->notify();
    }
    if (g_hidBootInput != nullptr && g_hidBootInput->getSubscribedCount() > 0) {
        g_hidBootInput->setValue(report, sizeof(report));
        g_hidBootInput->notify();
    }
}

static void notifyHIDKey(uint8_t modifiers, uint8_t key) {
    uint8_t report[8] = {modifiers, 0, key, 0, 0, 0, 0, 0};
    if (g_hidInputReport != nullptr && g_hidInputReport->getSubscribedCount() > 0) {
        g_hidInputReport->setValue(report, sizeof(report));
        g_hidInputReport->notify();
    }
    if (g_hidBootInput != nullptr && g_hidBootInput->getSubscribedCount() > 0) {
        g_hidBootInput->setValue(report, sizeof(report));
        g_hidBootInput->notify();
    }
}

static void notifyConsumerUsage(uint16_t usage) {
    if (!consumerHostReady()) return;
    uint8_t report[2] = {
        (uint8_t)(usage & 0xFF),
        (uint8_t)((usage >> 8) & 0xFF)
    };
    g_hidConsumerReport->setValue(report, sizeof(report));
    g_hidConsumerReport->notify();
}

static bool pressConsumerUsage(uint16_t usage) {
    if (!g_connected || usage == 0 || !consumerHostReady()) return false;
    notifyConsumerUsage(usage);
    delay(14);
    notifyConsumerUsage(0);
    return true;
}

// macOS HID usage：A=0x04、Delete/Backspace=0x2A、Left GUI(Command)=0x08。
// 语音 PTT 正被按住时不清空，避免破坏按下/松开的完整时序。
static bool clearInputViaHID() {
    if (!g_connected || !g_clearInputOnShake || g_hidHeld || !hidHostReady()) return false;
    notifyHIDKey(0x08, 0x04); // Command+A
    delay(14);
    notifyHIDReport(0);
    delay(14);
    notifyHIDKey(0, 0x2A);    // Delete / Backspace
    delay(14);
    notifyHIDReport(0);
    return true;
}

static bool pressHIDShortcut() {
    const uint16_t consumerUsage = g_consumerUsage;
    if (consumerUsage != 0) return pressConsumerUsage(consumerUsage);
    const uint8_t modifiers = g_hidModifiers;
    const uint8_t key = g_hidKey;
    if (!g_connected || (modifiers == 0 && key == 0) || !hidHostReady()) return false;
    notifyHIDKey(modifiers, key);
    if (g_hidHold) {
        g_hidHeld = true;
    } else {
        // 普通动作由控制器发出完整的按下/松开；Mac 端只更新结果，不再注入 CGEvent。
        delay(14);
        notifyHIDReport(0);
    }
    return true;
}

static void releaseHIDModifiers() {
    if (!g_hidHeld) return;
    notifyHIDReport(0);
    g_hidHeld = false;
}

static void sendShake(int dir) {
    char buf[48];
    snprintf(buf, sizeof(buf), "{\"type\":\"shake\",\"dir\":%d}", dir >= 0 ? 1 : -1);
    sendEvent(buf);
}

static void sendClearInput(bool handledByHID) {
    sendEvent(handledByHID
        ? "{\"type\":\"input\",\"action\":\"clear\",\"source\":\"hid\"}"
        : "{\"type\":\"input\",\"action\":\"clear\"}");
}

static void sendMediaGesture(int dir, bool handledByHID) {
    char buf[80];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"media\",\"dir\":%d,\"source\":\"%s\"}",
             dir >= 0 ? 1 : -1, handledByHID ? "hid" : "device");
    sendEvent(buf);
}

static void reportHIDStateIfChanged() {
    if (!g_connected || g_eventChar == nullptr || g_eventChar->getSubscribedCount() == 0) return;
    const bool secured = g_hidSecured;
    const bool ready = secured && hidHostReady();
    if ((int8_t)ready == g_lastReportedHIDReady
        && (int8_t)secured == g_lastReportedHIDSecured) return;
    char buf[72];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"hid\",\"ready\":%s,\"secured\":%s}",
             ready ? "true" : "false", secured ? "true" : "false");
    sendEvent(buf);
    g_lastReportedHIDReady = ready;
    g_lastReportedHIDSecured = secured;
}

// MARK: - BLE 回调

// 活跃档优先交互延迟；空闲档延长连接间隔并允许从设备跳过两个连接事件，
// 在保持 Mac 可随时唤醒/下发数据的前提下降低 BLE 射频占空比。
static void applyBLEConnectionProfile(bool idle) {
    if (!g_connected || g_bleServer == nullptr
        || g_connHandle == BLE_HS_CONN_HANDLE_NONE
        || g_bleIdleProfile == idle) return;
    g_bleIdleProfile = idle;
    if (idle) {
        // 60–90 ms，slave latency 1；最坏监听约 180 ms。旧参数最坏约 480 ms，
        // 会让设备从空闲档恢复后的第一次操作明显慢一拍。
        g_bleServer->updateConnParams(g_connHandle, 48, 72, 1, 500);
    } else {
        // 15–30 ms，无 latency；按键/摇晃交互保持灵敏。
        g_bleServer->updateConnParams(g_connHandle, 12, 24, 0, 400);
    }
}

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer *server) override {
        g_connected = true;
        g_dirty = true;
        g_headerDirty = true;
        g_blePing = true;
    }
    void onConnect(NimBLEServer *server, ble_gap_conn_desc *desc) override {
        g_bleServer = server;
        g_connHandle = desc->conn_handle;
        g_hidSecured = desc->sec_state.encrypted;
        // 强制首次连接应用活跃参数，而不是依赖协商默认值。
        g_bleIdleProfile = true;
        applyBLEConnectionProfile(false);
        // 多屏灵犀连接的是自定义 GATT 服务，macOS 不一定会主动读取加密的 HID
        // report。连接后主动启动安全流程，才能可靠弹出系统蓝牙键盘配对请求。
        if (!g_hidSecured) NimBLEDevice::startSecurity(desc->conn_handle);
    }
    void onAuthenticationComplete(ble_gap_conn_desc *desc) override {
        if (desc->sec_state.encrypted) {
            g_hidSecured = true;
            g_pairingRecoveryAttempted = false;
            g_headerDirty = true;
            return;
        }

        g_hidSecured = false;
        g_headerDirty = true;
        // 单边残留 bond 时只清理控制器端失效密钥，不在这里主动断开：如果 macOS
        // 仍保存旧键盘记录，断开后自动重连会造成连接状态持续闪烁。控制 GATT 保持
        // 稳定并显示“待配对”，等待用户在系统蓝牙中忽略旧设备后重新扫描。
        if (!g_pairingRecoveryAttempted) {
            g_pairingRecoveryAttempted = true;
            NimBLEDevice::deleteBond(NimBLEAddress(desc->peer_id_addr));
        }
    }
    void onDisconnect(NimBLEServer *server) override {
        g_hidHeld = false; // 断开连接时 macOS 自身也会释放该 HID 设备的全部键位
        releaseGyroMouseButtons();
        g_gyroMouseMode = false;
        g_hidSecured = false;
        g_lastReportedHIDReady = -1;
        g_lastReportedHIDSecured = -1;
        g_connected = false;
        g_connHandle = BLE_HS_CONN_HANDLE_NONE;
        g_bleIdleProfile = false;
        g_dirty = true;
        g_headerDirty = true;
        NimBLEDevice::startAdvertising();   // 断线后重新广播，等待 Mac 自动重连
    }
};

static void sendInfoAck(uint16_t transferID, size_t byteCount, bool ok) {
    char buf[80];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"info\",\"id\":%u,\"bytes\":%u,\"ok\":%s}",
             transferID, (unsigned int)byteCount, ok ? "true" : "false");
    sendEvent(buf);
}

static bool applyInfoPayload(const std::string &payload, uint16_t transferID) {
        DynamicJsonDocument doc(8192);
        DeserializationError jsonError = deserializeJson(doc, payload);
        if (jsonError) {
            Serial.printf("[M5] info JSON rejected id=%u bytes=%u error=%s\n",
                          transferID, (unsigned int)payload.size(), jsonError.c_str());
            sendInfoAck(transferID, payload.size(), false);
            return false;
        }

        std::vector<DevInfo> list;
        JsonArray arr = doc["devices"];
        if (arr) {
            for (JsonObject d : arr) {
                DevInfo di;
                di.name = String((const char *)(d["name"] | ""));
                di.detail = String((const char *)(d["detail"] | ""));
                di.available = d["available"] | true;
                list.push_back(di);
            }
        }
        int active = doc["active"] | 0;
        String title = String((const char *)(doc["title"] | "灵犀控制器"));
        String footer = String((const char *)(doc["footer"] | "摇动翻页 A/B切换"));
        bool buzzer = doc["buzzer"] | true;
        int hidModifiers = doc["hidModifiers"] | 0;
        int hidKey = doc["hidKey"] | 0;
        bool hidHold = doc["hidHold"] | false;
        bool clearInputOnShake = doc["clearInputOnShake"] | false;
        int consumerUsage = doc["consumerUsage"] | 0;
        int consumerUsageLeft = doc["consumerUsageLeft"] | 0;
        int consumerUsageRight = doc["consumerUsageRight"] | 0;
        bool gyroMouseActive = doc["gyroMouseActive"] | false;
        float gyroMouseSensitivity = doc["gyroMouseSensitivity"] | 1.0f;
        float gyroMouseDeadZone = doc["gyroMouseDeadZone"] | 1.4f;
        float gyroMouseSmoothing = doc["gyroMouseSmoothing"] | 0.58f;
        bool gyroMouseInvertX = doc["gyroMouseInvertX"] | false;
        bool gyroMouseInvertY = doc["gyroMouseInvertY"] | false;
        bool gyroMouseClutchEnabled = doc["gyroMouseClutchEnabled"] | false;
        long long gyroMouseRecenterToken = doc["gyroMouseRecenterToken"] | -1;
        int mainMenuMask = doc["mainMenuMask"] | -1;
        int shortcutMenuMask = doc["shortcutMenuMask"] | -1;
        int targetDeviceCount = doc["targetDeviceCount"] | 0;
        int homeAssistantEntityCount = doc["homeAssistantEntityCount"] | 0;
        int vibeActionCount = doc["vibeActionCount"] | 0;
        int presentationActionCount = doc["presentationActionCount"] | 0;
        int customActionCount = doc["customActionCount"] | 0;
        bool resetHIDBond = doc["resetHIDBond"] | false;
        if (hidModifiers < 0 || hidModifiers > 255) hidModifiers = 0;
        if (hidKey < 0 || hidKey > 255) hidKey = 0;
        if (consumerUsage < 0 || consumerUsage > 0x03FF) consumerUsage = 0;
        if (consumerUsageLeft < 0 || consumerUsageLeft > 0x03FF) consumerUsageLeft = 0;
        if (consumerUsageRight < 0 || consumerUsageRight > 0x03FF) consumerUsageRight = 0;
        gyroMouseSensitivity = fminf(fmaxf(gyroMouseSensitivity, 0.35f), 2.5f);
        gyroMouseDeadZone = fminf(fmaxf(gyroMouseDeadZone, 0.4f), 4.0f);
        gyroMouseSmoothing = fminf(fmaxf(gyroMouseSmoothing, 0.0f), 0.85f);
        updateMenuManifest(mainMenuMask, shortcutMenuMask, targetDeviceCount,
                           homeAssistantEntityCount, vibeActionCount,
                           presentationActionCount, customActionCount);

        if (g_hidHeld && ((uint8_t)hidModifiers != g_hidModifiers
                          || (uint8_t)hidKey != g_hidKey || hidHold != g_hidHold)) {
            releaseHIDModifiers();
        }
        if (resetHIDBond) {
            releaseHIDModifiers();
            releaseGyroMouseButtons();
            NimBLEDevice::deleteAllBonds();
            g_hidSecured = false;
            g_pairingRecoveryAttempted = false;
            g_lastReportedHIDReady = -1;
            g_lastReportedHIDSecured = -1;
            Serial.println("[M5] HID bonds cleared by explicit app unpair");
        }

        const bool enteringGyroMouse = gyroMouseActive && !g_gyroMouseMode;
        const bool leavingGyroMouse = !gyroMouseActive && g_gyroMouseMode;
        if (leavingGyroMouse) {
            releaseGyroMouseButtons();
            g_gyroMouseSuspended = false;
        }
        const bool recenterRequested = gyroMouseRecenterToken >= 0
            && (!g_hasGyroRecenterToken
                || g_lastGyroRecenterToken != (uint32_t)gyroMouseRecenterToken);

        bool bodyChanged = false;
        bool headerChanged = false;
        bool footerChanged = false;
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            bodyChanged = g_active != active || g_devices.size() != list.size();
            if (!bodyChanged) {
                for (size_t i = 0; i < list.size(); ++i) {
                    if (g_devices[i].name != list[i].name
                        || g_devices[i].detail != list[i].detail
                        || g_devices[i].available != list[i].available) {
                        bodyChanged = true;
                        break;
                    }
                }
            }
            const int oldPage = g_active >= 0 ? g_active / ROWS_PER_PAGE : 0;
            const int newPage = active >= 0 ? active / ROWS_PER_PAGE : 0;
            headerChanged = g_title != title || g_devices.size() != list.size()
                || oldPage != newPage;
            footerChanged = g_footer != footer;
            g_devices = list;
            g_active = active;
            g_title = title.length() ? title : String("灵犀控制器");
            g_footer = footer.length() ? footer : String("摇动翻页 A/B切换");
            g_buzzerEnabled = buzzer;
            g_hidModifiers = (uint8_t)hidModifiers;
            g_hidKey = (uint8_t)hidKey;
            g_hidHold = hidHold;
            g_clearInputOnShake = clearInputOnShake;
            g_consumerUsage = (uint16_t)consumerUsage;
            g_consumerUsageLeft = (uint16_t)consumerUsageLeft;
            g_consumerUsageRight = (uint16_t)consumerUsageRight;
            g_gyroMouseMode = gyroMouseActive;
            g_gyroMouseSensitivity = gyroMouseSensitivity;
            g_gyroMouseDeadZone = gyroMouseDeadZone;
            g_gyroMouseSmoothing = gyroMouseSmoothing;
            g_gyroMouseInvertX = gyroMouseInvertX;
            g_gyroMouseInvertY = gyroMouseInvertY;
            g_gyroMouseClutchEnabled = gyroMouseClutchEnabled;
            if (!g_gyroMouseClutchEnabled) g_gyroMouseSuspended = false;
        }
        if (gyroMouseRecenterToken >= 0) {
            g_lastGyroRecenterToken = (uint32_t)gyroMouseRecenterToken;
            g_hasGyroRecenterToken = true;
        }
        if (enteringGyroMouse || (gyroMouseActive && recenterRequested)) {
            startGyroMouseCalibration();
        }
        if (bodyChanged) g_bodyDirty = true;
        if (headerChanged) g_headerDirty = true;
        if (footerChanged) g_footerDirty = true;
        g_blePing = true;
        Serial.printf("[M5] info applied id=%u bytes=%u cards=%u gyro=%d mouse=%d\n",
                      transferID, (unsigned int)payload.size(), (unsigned int)list.size(),
                      (int)gyroMouseActive, (int)mouseHostReady());
        sendInfoAck(transferID, payload.size(), true);
        return true;
}

class InfoCallbacks : public NimBLECharacteristicCallbacks {
    static const size_t HEADER_SIZE = 14;
    static const size_t MAX_PAYLOAD_SIZE = 8 * 1024;
    std::string buffer;
    uint16_t activeTransferID = 0;
    uint16_t expectedChunk = 0;
    uint16_t expectedChunkCount = 0;
    uint32_t expectedByteCount = 0;

    static uint16_t readU16(const uint8_t *p) {
        return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    }

    static uint32_t readU32(const uint8_t *p) {
        return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
            | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }

    void resetTransfer() {
        buffer.clear();
        activeTransferID = 0;
        expectedChunk = 0;
        expectedChunkCount = 0;
        expectedByteCount = 0;
    }

public:
    void onWrite(NimBLECharacteristic *c) override {
        std::string packet = c->getValue();
        if (packet.empty()) return;
        const uint8_t *bytes = reinterpret_cast<const uint8_t *>(packet.data());
        const bool chunked = packet.size() >= HEADER_SIZE
            && bytes[0] == 0x1E && bytes[1] == 0x4C
            && bytes[2] == 0x58 && bytes[3] == 0x01;
        if (!chunked) {
            applyInfoPayload(packet, 0);
            return;
        }

        const uint16_t transferID = readU16(bytes + 4);
        const uint16_t chunkIndex = readU16(bytes + 6);
        const uint16_t chunkCount = readU16(bytes + 8);
        const uint32_t byteCount = readU32(bytes + 10);
        const size_t bodyLength = packet.size() - HEADER_SIZE;
        if (transferID == 0 || chunkCount == 0 || chunkIndex >= chunkCount
            || byteCount == 0 || byteCount > MAX_PAYLOAD_SIZE) {
            Serial.printf("[M5] invalid info chunk id=%u part=%u/%u bytes=%u\n",
                          transferID, chunkIndex, chunkCount, (unsigned int)byteCount);
            resetTransfer();
            sendInfoAck(transferID, byteCount, false);
            return;
        }

        // 第 0 片既开始新传输，也允许 Mac 在确认超时后完整重试同一个 ID。
        if (chunkIndex == 0) {
            resetTransfer();
            activeTransferID = transferID;
            expectedChunkCount = chunkCount;
            expectedByteCount = byteCount;
            buffer.reserve(byteCount);
        }
        if (transferID != activeTransferID || chunkIndex != expectedChunk
            || chunkCount != expectedChunkCount || byteCount != expectedByteCount
            || buffer.size() + bodyLength > expectedByteCount) {
            Serial.printf("[M5] out-of-order info chunk id=%u part=%u expected=%u\n",
                          transferID, chunkIndex, expectedChunk);
            resetTransfer();
            sendInfoAck(transferID, byteCount, false);
            return;
        }

        buffer.append(packet.data() + HEADER_SIZE, bodyLength);
        ++expectedChunk;
        if (expectedChunk < expectedChunkCount) return;

        const bool complete = buffer.size() == expectedByteCount;
        std::string payload;
        payload.swap(buffer);
        const uint16_t completedID = activeTransferID;
        const uint32_t completedBytes = expectedByteCount;
        resetTransfer();
        if (!complete) {
            Serial.printf("[M5] incomplete info id=%u got=%u expected=%u\n",
                          completedID, (unsigned int)payload.size(),
                          (unsigned int)completedBytes);
            sendInfoAck(completedID, payload.size(), false);
            return;
        }
        applyInfoPayload(payload, completedID);
    }
};

static void setupBLE() {
    // 用 MAC 末两字节生成唯一后缀，便于同时区分多台控制器
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);
    char suffix[8];
    snprintf(suffix, sizeof(suffix), "%02X%02X", mac[4], mac[5]);
    String name = String(ADV_NAME_PREFIX) + "-" + suffix;

    NimBLEDevice::init(name.c_str());
    // 室内近距离控制无需最高发射功率，P3 可显著降低 BLE 峰值功耗。
    NimBLEDevice::setPower(ESP_PWR_LVL_P3);
    // HID Keyboard 的加密订阅会触发一次 Just Works 配对；保留 bonding 后重启无需重配。
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    NimBLEDevice::setSecurityAuth(true, false, true);

    NimBLEServer *server = NimBLEDevice::createServer();
    g_bleServer = server;
    server->setCallbacks(new ServerCallbacks());

    g_hidDevice = new NimBLEHIDDevice(server);
    g_hidInputReport = g_hidDevice->inputReport(1);
    g_hidConsumerReport = g_hidDevice->inputReport(2);
    g_hidMouseReport = g_hidDevice->inputReport(3);
    g_hidBootInput = g_hidDevice->bootInput();
    g_hidDevice->manufacturer("Lingxi");
    // 产品修订号递增，提示主机重新读取新增的复合鼠标 HID 描述。
    g_hidDevice->pnp(0x02, 0x303A, 0x1555, 0x0101);
    g_hidDevice->hidInfo(0x00, 0x02);
    g_hidDevice->reportMap(HID_REPORT_MAP, sizeof(HID_REPORT_MAP));
    g_hidDevice->setBatteryLevel(g_batteryPct < 0 ? 100 : (uint8_t)g_batteryPct);
    g_hidDevice->startServices();

    NimBLEService *service = server->createService(SERVICE_UUID);

    g_eventChar = service->createCharacteristic(
        EVENT_CHAR_UUID,
        NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);

    g_infoChar = service->createCharacteristic(
        INFO_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    g_infoChar->setCallbacks(new InfoCallbacks());

    service->start();

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SERVICE_UUID);   // Mac 端按此服务 UUID 过滤扫描结果
    adv->addServiceUUID(NimBLEUUID((uint16_t)0x1812));
    adv->setAppearance(HID_KEYBOARD);
    adv->setScanResponse(true);
    // 不再把 preferred interval 写进 31-byte 广播包：自定义 128-bit UUID、
    // HID 16-bit UUID 与 Keyboard appearance 必须同时可见。连接后仍由
    // applyBLEConnectionProfile() 协商活跃/空闲间隔。
    NimBLEDevice::startAdvertising();

    Serial.printf("[M5] advertising as %s\n", name.c_str());
}

// MARK: - 输入处理

static void playFeedbackTone(bool confirm, bool back = false) {
    if (!g_buzzerEnabled) return;
    const uint16_t frequency = back ? 680 : (confirm ? 1320 : 980);
    const uint32_t duration = confirm || back ? 105 : 45;
    M5.Speaker.tone(frequency, duration);
}

// 短按 A/B 在所有菜单页都表示移动选中项。先在设备端乐观更新高亮，
// 再把事件发给 Mac；Mac 回写的最终状态仍是权威值，避免蓝牙往返让 UI 慢一拍。
static void previewSelection(int direction) {
    std::lock_guard<std::mutex> lk(g_mutex);
    const int count = (int)g_devices.size();
    if (count <= 0) return;
    const int oldPage = g_active / ROWS_PER_PAGE;
    g_active = ((g_active + direction) % count + count) % count;
    g_bodyDirty = true;
    if (g_active / ROWS_PER_PAGE != oldPage) g_headerDirty = true;
}

static void handleGyroMouseButtons() {
    static bool chordActive = false;
    const bool bothPressed = M5.BtnA.isPressed() && M5.BtnB.isPressed();

    // A+B 是始终可恢复的本地校准动作，不依赖 Mac 往返。整段按键周期都吞掉，
    // 避免松手时又被解释成一次左键或右键。
    if (bothPressed && !chordActive) {
        chordActive = true;
        if (g_mouseDragActive) {
            releaseGyroMouseButtons();
        }
        startGyroMouseCalibration();
        playFeedbackTone(true);
    }
    if (chordActive) {
        if (!M5.BtnA.isPressed() && !M5.BtnB.isPressed()) chordActive = false;
        return;
    }

    if (M5.BtnA.wasHold()) {
        g_mouseDragActive = true;
        g_mouseButtons = 0x01;
        notifyMouseReport(g_mouseButtons);
        playFeedbackTone(true);
    } else if (M5.BtnA.wasClicked()) {
        const bool handled = clickMouseButton(0x01);
        playFeedbackTone(handled);
    }
    if (M5.BtnA.wasReleased() && g_mouseDragActive) {
        releaseGyroMouseButtons();
    }

    if (M5.BtnB.wasHold()) {
        playFeedbackTone(true, true);
        sendButton("b", true); // Mac 切回“Mac 快捷键”，随后回写并关闭鼠标模式
    } else if (M5.BtnB.wasClicked()) {
        if (g_gyroMouseClutchEnabled) {
            releaseGyroMouseButtons();
            g_gyroMouseSuspended = !g_gyroMouseSuspended;
            g_mouseFilteredX = 0.0f;
            g_mouseFilteredY = 0.0f;
            g_mouseFractionX = 0.0f;
            g_mouseFractionY = 0.0f;
            g_mouseLastSampleAt = 0;
            g_bodyDirty = true;
            playFeedbackTone(!g_gyroMouseSuspended, g_gyroMouseSuspended);
        } else {
            const bool handled = clickMouseButton(0x02);
            playFeedbackTone(handled);
        }
    }
}

static void handleButtons() {
    if (g_gyroMouseMode) {
        handleGyroMouseButtons();
        return;
    }
    // wasHold() 只在跨过长按阈值时触发一次；长按松手后不会再补发短按。
    static bool aLongActive = false;
    static bool bLongActive = false;
    static bool aLongUsedHID = false;
    if (M5.BtnA.wasHold()) {
        aLongActive = true;
        playFeedbackTone(true);
        aLongUsedHID = pressHIDShortcut();
        if (aLongUsedHID) sendButtonHID("a", true);
        else sendButton("a", true);
    } else if (M5.BtnA.wasClicked()) {
        playFeedbackTone(false);
        previewSelection(1);
        sendButton("a");
    }
    if (M5.BtnB.wasHold()) {
        bLongActive = true;
        playFeedbackTone(true, true);
        sendButton("b", true);
    } else if (M5.BtnB.wasClicked()) {
        playFeedbackTone(false);
        previewSelection(-1);
        sendButton("b");
    }
    // 长按开始与松开必须成对上报。Mac 可据此让语音输入快捷键保持真正的
    // keyDown 状态；短按不会产生额外的 up 事件。
    if (M5.BtnA.wasReleased() && aLongActive) {
        aLongActive = false;
        if (aLongUsedHID) {
            const bool wasHeld = g_hidHeld;
            releaseHIDModifiers();
            if (wasHeld) sendButtonHID("a", false);
        } else {
            sendButtonUp("a");
        }
        aLongUsedHID = false;
    }
    if (M5.BtnB.wasReleased() && bLongActive) {
        bLongActive = false;
        sendButtonUp("b");
    }
}

// 摇晃检测：加速度合量突增视为一次摇晃，方向取横向（X 轴）主冲量符号。
static const float SHAKE_G = 2.3f;          // 触发阈值（g，静息约 1.0）
static const uint32_t SHAKE_COOLDOWN_MS = 600;
static const uint32_t SHAKE_WINDOW_MS = 150;

static bool g_inShake = false;
static uint32_t g_shakeStart = 0;
static uint32_t g_lastShake = 0;
static float g_bestAxis = 0.0f;

// 每循环只采样一次 IMU，供手势状态机与唤醒判断共用
static float g_ax = 0.0f, g_ay = 0.0f, g_az = 0.0f, g_mag = 1.0f;
static float g_gx = 0.0f, g_gy = 0.0f, g_gz = 0.0f;
static bool g_hasGyroSample = false;

static bool pollImu() {
    if (!M5.Imu.update()) return false;
    float ax = 0, ay = 0, az = 0;
    if (!M5.Imu.getAccel(&ax, &ay, &az)) return false;
    float gx = 0, gy = 0, gz = 0;
    g_hasGyroSample = M5.Imu.getGyro(&gx, &gy, &gz);
    if (g_hasGyroSample) {
        g_gx = gx;
        g_gy = gy;
        g_gz = gz;
    }
    g_ax = ax;
    g_ay = ay;
    g_az = az;
    g_mag = sqrtf(ax * ax + ay * ay + az * az);
    return true;
}

static float airMousePixelsPerDegree(float angularSpeed, float sensitivity) {
    // LG Magic Remote 风格的分段增益：慢速移动保持接近线性，便于点中小控件；
    // 快速扫腕才明显提速，让约 40~50 度的自然动作可以横跨一块宽屏。
    const float speed = fminf(fabsf(angularSpeed), 320.0f);
    const float precisionT = fminf(speed / 35.0f, 1.0f);
    const float precisionGain = 15.0f + 7.0f * powf(precisionT, 1.35f);
    const float fastT = fminf(fmaxf((speed - 35.0f) / 190.0f, 0.0f), 1.0f);
    const float sweepBoost = 26.0f * powf(fastT, 1.25f);
    return (precisionGain + sweepBoost) * sensitivity;
}

static void updateAirMouseAxes() {
    // 加速度计只负责缓慢修正“世界竖直方向”，陀螺仪仍负责即时运动。
    // 这让用户从竖握转为飞鼠式平握时，左右始终是水平扫动，
    // 而不会突然变成滚转轴；低通足够慢，不会把甩腕加速度当成重力。
    if (g_mag < 0.88f || g_mag > 1.12f) return;
    float ax = g_ax / g_mag, ay = g_ay / g_mag, az = g_az / g_mag;
    const float alignment = ax * g_mouseGravityX
                          + ay * g_mouseGravityY
                          + az * g_mouseGravityZ;
    if (alignment < 0.0f) { ax = -ax; ay = -ay; az = -az; }
    const float follow = 0.012f;
    float gx = g_mouseGravityX * (1.0f - follow) + ax * follow;
    float gy = g_mouseGravityY * (1.0f - follow) + ay * follow;
    float gz = g_mouseGravityZ * (1.0f - follow) + az * follow;
    const float norm = sqrtf(gx * gx + gy * gy + gz * gz);
    if (norm < 0.2f) return;
    g_mouseGravityX = gx / norm;
    g_mouseGravityY = gy / norm;
    g_mouseGravityZ = gz / norm;

    float rx = 1.0f - g_mouseGravityX * g_mouseGravityX;
    float ry = -g_mouseGravityX * g_mouseGravityY;
    float rz = -g_mouseGravityX * g_mouseGravityZ;
    float rightNorm = sqrtf(rx * rx + ry * ry + rz * rz);
    if (rightNorm < 0.25f) {
        rx = -g_mouseGravityZ * g_mouseGravityX;
        ry = -g_mouseGravityZ * g_mouseGravityY;
        rz = 1.0f - g_mouseGravityZ * g_mouseGravityZ;
        rightNorm = sqrtf(rx * rx + ry * ry + rz * rz);
    }
    if (rightNorm > 0.01f) {
        g_mouseRightX = rx / rightNorm;
        g_mouseRightY = ry / rightNorm;
        g_mouseRightZ = rz / rightNorm;
    }
}

// 返回是否产生了实际指针移动；调用方据此唤醒屏幕并延后休眠。
static bool processGyroMouse() {
    if (!g_gyroMouseMode || !g_hasGyroSample) return false;

    if (g_mouseCalibrationSamples > 0) {
        // HID 尚未订阅时也必须完成校准；旧逻辑把 mouseHostReady 放在前面，
        // 会导致重新居中永久卡住。只采集相对稳定的样本，手还在移动时等待。
        const float gyroMotion = sqrtf(g_gx * g_gx + g_gy * g_gy + g_gz * g_gz);
        if (gyroMotion > 6.0f || g_mag < 0.82f || g_mag > 1.18f) {
            // 必须是连续稳定窗口；移动后丢弃此前样本，而不是把两段静止数据拼接。
            resetGyroMouseCalibrationWindow();
            return false;
        }
        g_mouseCalibrationGyroSumX += g_gx;
        g_mouseCalibrationGyroSumY += g_gy;
        g_mouseCalibrationGyroSumZ += g_gz;
        g_mouseCalibrationAccelSumX += g_ax;
        g_mouseCalibrationAccelSumY += g_ay;
        g_mouseCalibrationAccelSumZ += g_az;
        if (--g_mouseCalibrationSamples == 0) {
            const float sampleCount = (float)MOUSE_CALIBRATION_SAMPLE_COUNT;
            g_mouseBiasX = g_mouseCalibrationGyroSumX / sampleCount;
            g_mouseBiasY = g_mouseCalibrationGyroSumY / sampleCount;
            g_mouseBiasZ = g_mouseCalibrationGyroSumZ / sampleCount;

            float gx = g_mouseCalibrationAccelSumX / sampleCount;
            float gy = g_mouseCalibrationAccelSumY / sampleCount;
            float gz = g_mouseCalibrationAccelSumZ / sampleCount;
            float gravityNorm = sqrtf(gx * gx + gy * gy + gz * gz);
            if (gravityNorm < 0.35f) {
                gx = 0.0f; gy = 1.0f; gz = 0.0f;
                gravityNorm = 1.0f;
            }
            g_mouseGravityX = gx / gravityNorm;
            g_mouseGravityY = gy / gravityNorm;
            g_mouseGravityZ = gz / gravityNorm;
            // 同一握姿翻转屏幕朝向时不应让左右方向突然反转。以竖握 Y、
            // 平握 Z 中占比更大的轴统一为正向，保留旧版直观的 gy/gz 手感。
            const float dominant = fabsf(g_mouseGravityY) >= fabsf(g_mouseGravityZ)
                ? g_mouseGravityY : g_mouseGravityZ;
            if (dominant < 0.0f) {
                g_mouseGravityX = -g_mouseGravityX;
                g_mouseGravityY = -g_mouseGravityY;
                g_mouseGravityZ = -g_mouseGravityZ;
            }

            // 屏幕横向轴以 M5Unified 已矫正后的 +X 为基准，并投影到重力
            // 垂直平面。即使控制器略微斜握，向上/向下也不会串到水平移动。
            float rx = 1.0f - g_mouseGravityX * g_mouseGravityX;
            float ry = -g_mouseGravityX * g_mouseGravityY;
            float rz = -g_mouseGravityX * g_mouseGravityZ;
            float rightNorm = sqrtf(rx * rx + ry * ry + rz * rz);
            if (rightNorm < 0.25f) {
                // 极端侧握时 +X 接近重力，用屏幕法线 +Z 作为稳定回退。
                rx = -g_mouseGravityZ * g_mouseGravityX;
                ry = -g_mouseGravityZ * g_mouseGravityY;
                rz = 1.0f - g_mouseGravityZ * g_mouseGravityZ;
                rightNorm = sqrtf(rx * rx + ry * ry + rz * rz);
            }
            if (rightNorm < 0.01f) {
                rx = 1.0f; ry = 0.0f; rz = 0.0f;
                rightNorm = 1.0f;
            }
            g_mouseRightX = rx / rightNorm;
            g_mouseRightY = ry / rightNorm;
            g_mouseRightZ = rz / rightNorm;
            g_mouseFilteredX = 0.0f;
            g_mouseFilteredY = 0.0f;
            g_mouseFractionX = 0.0f;
            g_mouseFractionY = 0.0f;
            g_mouseLastSampleAt = 0;
            g_mouseCalibrationCompletedAt = millis();
            g_bodyDirty = true;
            // 设备只负责相对 HID 移动；由 Mac 把指针放到当前显示器中心，随后
            // 继续相对跟随。A+B 与软件“重新居中”都会走同一条路径。
            sendPointerRecenter();
        }
        return false;
    }
    if (g_gyroMouseSuspended || !mouseHostReady()) return false;

    updateAirMouseAxes();

    const float rateX = g_gx - g_mouseBiasX;
    const float rateY = g_gy - g_mouseBiasY;
    const float rateZ = g_gz - g_mouseBiasZ;
    // 手腕式空中鼠标：水平移动使用“绕校准时重力方向”的转动。
    // 控制器竖握时主要来自 Y 轴；平握时自然过渡到 Z 轴，不再固定死轴。
    float horizontal = rateX * g_mouseGravityX
                     + rateY * g_mouseGravityY
                     + rateZ * g_mouseGravityZ;
    float vertical = -(rateX * g_mouseRightX
                     + rateY * g_mouseRightY
                     + rateZ * g_mouseRightZ);
    const float deadZone = g_gyroMouseDeadZone;
    auto applyDeadZone = [deadZone](float value) {
        const float amount = fabsf(value);
        if (amount <= deadZone) return 0.0f;
        return copysignf(amount - deadZone, value);
    };
    horizontal = applyDeadZone(horizontal);
    vertical = applyDeadZone(vertical);
    if (g_gyroMouseInvertX) horizontal = -horizontal;
    if (g_gyroMouseInvertY) vertical = -vertical;

    const float projectedSpeed = sqrtf(horizontal * horizontal + vertical * vertical);
    if (projectedSpeed <= 0.0f) {
        // 飞鼠停手就必须停，不能让滤波残量继续拖着光标走。亚像素余量也在此
        // 清除，避免静止数秒后由累计误差突然跳动一个像素。
        g_mouseFilteredX = 0.0f;
        g_mouseFilteredY = 0.0f;
        g_mouseFractionX = 0.0f;
        g_mouseFractionY = 0.0f;
        g_mouseLastSampleAt = millis();
        const float residual = sqrtf(rateX * rateX + rateY * rateY + rateZ * rateZ);
        if (residual < deadZone * 0.7f) {
            g_mouseBiasX = g_mouseBiasX * 0.998f + g_gx * 0.002f;
            g_mouseBiasY = g_mouseBiasY * 0.998f + g_gy * 0.002f;
            g_mouseBiasZ = g_mouseBiasZ * 0.998f + g_gz * 0.002f;
        }
        return false;
    }

    // 慢速时保留少量平滑来压住手抖，快速扫动时自动降低历史权重以减少迟滞。
    const float speedT = fminf(projectedSpeed / 150.0f, 1.0f);
    const float baseHistory = fminf(g_gyroMouseSmoothing * 0.52f, 0.44f);
    const float smoothing = baseHistory * (1.0f - speedT * 0.72f);
    g_mouseFilteredX = smoothing * g_mouseFilteredX + (1.0f - smoothing) * horizontal;
    g_mouseFilteredY = smoothing * g_mouseFilteredY + (1.0f - smoothing) * vertical;

    const uint32_t now = millis();
    if (g_mouseLastSampleAt == 0) {
        g_mouseLastSampleAt = now;
        return false;
    }
    const float deltaSeconds = fminf(fmaxf((now - g_mouseLastSampleAt) / 1000.0f,
                                           0.008f), 0.05f);
    g_mouseLastSampleAt = now;
    const float filteredSpeed = sqrtf(g_mouseFilteredX * g_mouseFilteredX
                                    + g_mouseFilteredY * g_mouseFilteredY);
    const float gain = airMousePixelsPerDegree(filteredSpeed, g_gyroMouseSensitivity);
    g_mouseFractionX += g_mouseFilteredX * deltaSeconds * gain;
    g_mouseFractionY += g_mouseFilteredY * deltaSeconds * gain;

    // BLE HID 每轴单包只有 int8。快速扫腕时最多拆成三包，避免先截断再丢弃
    // 位移造成“甩得越快反而越短”，也避免把大批积压留到停手后继续滑行。
    bool moved = false;
    for (int packet = 0; packet < 3; ++packet) {
        const int dx = min(max((int)g_mouseFractionX, -127), 127);
        const int dy = min(max((int)g_mouseFractionY, -127), 127);
        if (dx == 0 && dy == 0) break;
        g_mouseFractionX -= dx;
        g_mouseFractionY -= dy;
        notifyMouseReport(g_mouseButtons, (int8_t)dx, (int8_t)dy, 0);
        moved = true;
    }
    if (fabsf(g_mouseFractionX) > 127.0f) {
        g_mouseFractionX = copysignf(127.0f, g_mouseFractionX);
    }
    if (fabsf(g_mouseFractionY) > 127.0f) {
        g_mouseFractionY = copysignf(127.0f, g_mouseFractionY);
    }
    return moved;
}

// 依据最新样本推进摇晃状态机（仅在屏幕点亮时调用）
static void processShake() {
    uint32_t now = millis();
    if (!g_inShake) {
        if (g_mag > SHAKE_G && (now - g_lastShake) > SHAKE_COOLDOWN_MS) {
            g_inShake = true;
            g_shakeStart = now;
            g_bestAxis = g_ax;
        }
        return;
    }

    if (fabsf(g_ax) > fabsf(g_bestAxis)) g_bestAxis = g_ax;
    if (now - g_shakeStart > SHAKE_WINDOW_MS) {
        g_inShake = false;
        g_lastShake = now;
        if (g_clearInputOnShake && !g_hidHeld) {
            const bool handled = clearInputViaHID();
            playFeedbackTone(handled);
            sendClearInput(handled);
        } else {
            const int direction = g_bestAxis >= 0.0f ? 1 : -1;
            const uint16_t mediaUsage = direction < 0
                ? g_consumerUsageLeft : g_consumerUsageRight;
            if (mediaUsage != 0) {
                const bool handled = pressConsumerUsage(mediaUsage);
                playFeedbackTone(handled);
                sendMediaGesture(direction, handled);
            } else {
                playFeedbackTone(false);
                sendShake(direction);
            }
        }
    }
}

// MARK: - 显示辅助

static const int HEADER_H = 46;     // 两行：标题 + 状态/电量
static const int FOOTER_H = 22;
// UTF-8 安全截断：不切断多字节字符，超出时追加省略号
static String fitText(const String &src, int maxW, const lgfx::IFont *font) {
    M5.Display.setFont(font);
    if (M5.Display.textWidth(src) <= maxW) return src;

    String out;
    size_t i = 0;
    while (i < src.length()) {
        uint8_t c = (uint8_t)src[i];
        size_t len = 1;
        if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        if (i + len > src.length()) len = src.length() - i;

        String candidate = out + src.substring(i, i + len) + "...";
        if (M5.Display.textWidth(candidate) > maxW) break;
        out += src.substring(i, i + len);
        i += len;
    }
    return out.isEmpty() ? String("...") : out + "...";
}

// 电池图标：外框 + 正极头 + 按电量填充；接入 USB 时用矢量线条画闪电，
// 不依赖字库中的特殊符号。满电后 charging=false，但 USB 供电图标仍应保留。
static void drawBatteryIcon(int x, int y, int w, int h, int pct, bool externalPower) {
    uint16_t fg = externalPower ? colGreen() : (pct < 0) ? colDim()
                : (pct <= 15 ? colRed()
                : (pct <= 35 ? colAmber() : colGreen()));
    M5.Display.drawRect(x, y, w, h, externalPower ? colGreen() : colSub());
    M5.Display.fillRect(x + w, y + h / 3, 2, h / 3,
                        externalPower ? colGreen() : colSub());

    if (externalPower) {
        M5.Display.fillRect(x + 2, y + 2, w - 4, h - 4, fg);
    } else if (pct > 0) {
        int fillW = (w - 4) * pct / 100;
        if (fillW > 0) M5.Display.fillRect(x + 2, y + 2, fillW, h - 4, fg);
    } else if (pct == 0) {
        M5.Display.fillRect(x + 2, y + 2, 3, h - 4, fg);
    }

    if (externalPower) {
        const int cx = x + w / 2;
        const uint16_t bolt = colBg();
        M5.Display.drawLine(cx + 2, y + 2, cx - 2, y + 7, bolt);
        M5.Display.drawLine(cx + 3, y + 2, cx - 1, y + 7, bolt);
        M5.Display.drawLine(cx - 2, y + 7, cx + 2, y + 7, bolt);
        M5.Display.drawLine(cx - 1, y + 8, cx - 4, y + h - 2, bolt);
        M5.Display.drawLine(cx, y + 8, cx - 3, y + h - 2, bolt);
    }
}

static void drawHeader(int W) {
    const bool connected = g_connected;
    M5.Display.fillRect(0, 0, W, HEADER_H, colPanel());

    // 第一行：大字标题
    String title;
    int count, active;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        title = g_title;
        count = (int)g_devices.size();
        active = g_active;
    }
    M5.Display.setFont(&fonts::efontCN_14);
    M5.Display.setTextColor(colText(), colPanel());
    M5.Display.setTextDatum(top_left);
    const int titleMaxW = count > ROWS_PER_PAGE ? W - 52 : W - 16;
    M5.Display.drawString(fitText(title, titleMaxW, &fonts::efontCN_14), 8, 5);

    // 第一行右侧：页码（仅多于一页时显示）
    if (count > ROWS_PER_PAGE) {
        int pages = (count + ROWS_PER_PAGE - 1) / ROWS_PER_PAGE;
        int page = active / ROWS_PER_PAGE + 1;
        if (page < 1) page = 1;
        if (page > pages) page = pages;
        char pg[16];
        snprintf(pg, sizeof(pg), "%d/%d页", page, pages);
        M5.Display.setFont(&fonts::efontCN_12);
        M5.Display.setTextColor(colSub(), colPanel());
        M5.Display.setTextDatum(top_right);
        M5.Display.drawString(pg, W - 8, 8);
        M5.Display.setTextDatum(top_left);
    }

    // 第二行左侧：电池图标 + 电量
    drawBatteryIcon(8, 28, 26, 13, g_batteryPct, g_vbusPresent);
    char batt[24];
    if (g_batteryPct < 0) snprintf(batt, sizeof(batt), g_vbusPresent ? "USB" : "--");
    else snprintf(batt, sizeof(batt), "%d%%", g_batteryPct);
    M5.Display.setFont(&fonts::efontCN_12);
    M5.Display.setTextColor(g_vbusPresent ? colGreen() : (g_batteryPct < 0 ? colDim() : colSub()),
                            colPanel());
    M5.Display.drawString(batt, 40, 28);

    // 第二行右侧：连接状态胶囊。控制 GATT 已连接但 HID 尚未加密时明确提示待配对。
    const bool secured = g_hidSecured;
    const char *stateText = !connected ? "未连接" : (secured ? "已配对" : "待配对");
    uint16_t stateCol = !connected ? colRed() : (secured ? colGreen() : colAmber());
    M5.Display.setFont(&fonts::efontCN_12);
    int tw = M5.Display.textWidth(stateText);
    int pillW = tw + 22;
    int pillH = 18;
    int pillX = W - 6 - pillW;
    int pillY = 25;
    M5.Display.fillRoundRect(pillX, pillY, pillW, pillH, pillH / 2, stateCol);
    M5.Display.fillCircle(pillX + 9, pillY + pillH / 2, 3, colText());
    M5.Display.setTextColor(colText(), stateCol);
    M5.Display.drawString(stateText, pillX + 16, pillY + 2);

    M5.Display.drawFastHLine(0, HEADER_H - 1, W, colPanelHi());
}

static void drawFooter(int W, int H) {
    String footer;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        footer = g_footer;
    }
    int y = H - FOOTER_H;
    M5.Display.fillRect(0, y, W, FOOTER_H, colPanel());
    M5.Display.drawFastHLine(0, y, W, colPanelHi());
    M5.Display.setFont(&fonts::efontCN_12);
    M5.Display.setTextColor(colSub(), colPanel());
    M5.Display.setTextDatum(middle_center);
    M5.Display.drawString(fitText(footer, W - 10, &fonts::efontCN_12),
                          W / 2, y + FOOTER_H / 2);
    M5.Display.setTextDatum(top_left);
}

static void drawCenterHint(int W, int H) {
    int cy = HEADER_H + (H - HEADER_H - FOOTER_H) / 2;
    M5.Display.setTextDatum(middle_center);
    M5.Display.setFont(&fonts::efontCN_16);
    M5.Display.setTextColor(colSub(), colBg());
    M5.Display.drawString(g_connected ? "等待被控设备" : "未连接 Mac", W / 2, cy - 18);
    M5.Display.setFont(&fonts::efontCN_12);
    M5.Display.setTextColor(colDim(), colBg());
    M5.Display.drawString(g_connected ? "请在设备管理中勾选" : "请在多屏灵犀里配对",
                          W / 2, cy + 10);
    M5.Display.setTextDatum(top_left);
}

static void drawRows(int W, int H) {
    std::vector<DevInfo> devices;
    int active;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        devices = g_devices;
        active = g_active;
    }
    const int count = (int)devices.size();
    if (active < 0) active = 0;
    if (active >= count) active = count - 1;

    // 每屏 3 台：页面跟随当前选中设备
    int page = active / ROWS_PER_PAGE;
    const int pageCount = (count + ROWS_PER_PAGE - 1) / ROWS_PER_PAGE;
    if (page < 0) page = 0;
    if (page >= pageCount) page = pageCount - 1;
    const int start = page * ROWS_PER_PAGE;
    int visible = count - start;
    if (visible > ROWS_PER_PAGE) visible = ROWS_PER_PAGE;

    const int rowX = 6;
    const int rowW = W - rowX * 2;
    const int bodyTop = HEADER_H + 4;
    const int bodyH = H - HEADER_H - FOOTER_H - 8;
    const int gap = 4;
    // 卡片始终采用三行布局的固定高度。只有 1–2 项时保留下面的自然留白，
    // 不把少量卡片纵向拉伸填满屏幕。
    const int rowH = (bodyH - gap * (ROWS_PER_PAGE - 1)) / ROWS_PER_PAGE;

    for (int i = 0; i < visible; ++i) {
        const int idx = start + i;
        const DevInfo &d = devices[idx];
        const int y = bodyTop + i * (rowH + gap);
        const bool isActive = (idx == active);
        const uint16_t rowBg = isActive ? colAccent() : colPanel();

        M5.Display.fillRoundRect(rowX, y, rowW, rowH, 6, rowBg);

        // 左侧序号徽标
        const int cx = rowX + 13, cy = y + rowH / 2;
        M5.Display.fillCircle(cx, cy, 8, isActive ? colText() : colDim());
        M5.Display.setFont(&fonts::efontCN_12);
        M5.Display.setTextColor(isActive ? colAccent() : colBg(),
                                isActive ? colText() : colDim());
        M5.Display.setTextDatum(middle_center);
        M5.Display.drawNumber(idx + 1, cx, cy);
        M5.Display.setTextDatum(top_left);

        const int textX = rowX + 26;
        const int textW = rowW - 26 - 8;
        const uint16_t nameCol = d.available ? colText() : colDim();
        const uint16_t subCol = isActive ? colText() : colSub();

        String name = d.name.length() ? d.name : String("(未命名)");
        String sub = !d.available ? String("离线")
                   : (d.detail.length() ? d.detail : String("就绪"));
        if (g_gyroMouseMode && idx == active) {
            if (g_mouseCalibrationSamples > 0) {
                sub = "保持自然指向 正在校准";
            } else if (g_gyroMouseSuspended) {
                sub = "已临时脱开 按B恢复";
            } else if (!g_hidSecured) {
                sub = "请在系统蓝牙中重新配对";
            } else if (!mouseHostReady()) {
                sub = "鼠标服务未就绪 请重新配对";
            } else if (g_mouseCalibrationCompletedAt != 0
                       && millis() - g_mouseCalibrationCompletedAt < 1600) {
                sub = "已居中 慢移精准 快甩加速";
            } else {
                sub = "像电视飞鼠一样转动手腕";
            }
        }

        M5.Display.setFont(&fonts::efontCN_14);
        M5.Display.setTextColor(nameCol, rowBg);
        M5.Display.drawString(fitText(name, textW, &fonts::efontCN_14), textX, y + 6);

        M5.Display.setFont(&fonts::efontCN_12);
        M5.Display.setTextColor(subCol, rowBg);
        M5.Display.drawString(fitText(sub, textW, &fonts::efontCN_12), textX, y + rowH - 19);
    }
}

static void drawScreen() {
    int W = M5.Display.width();
    int H = M5.Display.height();
    M5.Display.fillScreen(colBg());
    drawHeader(W);
    drawFooter(W, H);

    bool empty;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        empty = g_devices.empty();
    }
    if (empty) drawCenterHint(W, H);
    else drawRows(W, H);
}

// 按键选择和 Mac 状态回写只更新正文区域，避免整屏清空产生肉眼可见的闪烁。
static void drawBody(int W, int H) {
    M5.Display.fillRect(0, HEADER_H, W, H - HEADER_H - FOOTER_H, colBg());
    bool empty;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        empty = g_devices.empty();
    }
    if (empty) drawCenterHint(W, H);
    else drawRows(W, H);
}

// MARK: - 自动休眠 / 唤醒

static const uint32_t DIM_AFTER_MS = 8000;                // 8 s 无操作 → 调暗
static const uint32_t SCREEN_OFF_AFTER_MS = 30000;        // 30 s 无操作 → 息屏（BLE 保持连接）
static const uint32_t SLEEP_AFTER_MS = 10 * 60 * 1000UL;  // 10 min 无操作 → 深度休眠
static const uint8_t BRIGHT_ACTIVE = 105;
static const uint8_t BRIGHT_DIM = 24;

enum PowerState { PS_ACTIVE, PS_DIM, PS_OFF };
static PowerState g_powerState = PS_ACTIVE;
static uint32_t g_lastActivity = 0;

static inline void noteActivity() { g_lastActivity = millis(); }

static void applyPowerState(PowerState next) {
    if (next == g_powerState) return;
    g_powerState = next;
    switch (next) {
        case PS_ACTIVE:
            setCpuFrequencyMhz(80);
            applyBLEConnectionProfile(false);
            M5.Display.setBrightness(BRIGHT_ACTIVE);
            g_dirty = true;             // 重新点亮时重绘，避免残留旧内容
            break;
        case PS_DIM:
            applyBLEConnectionProfile(true);
            setCpuFrequencyMhz(80);
            M5.Display.setBrightness(BRIGHT_DIM);
            break;
        case PS_OFF:
            applyBLEConnectionProfile(true);
            setCpuFrequencyMhz(80);
            M5.Display.setBrightness(0);
            break;
    }
}

// 深度休眠：GPIO11/12（BtnA/BtnB）低电平唤醒。
// M5Unified 对 StickS3 未设置唤醒脚，这里直接配置 RTC GPIO + ext1。
static void enterDeepSleep() {
    Serial.println("[M5] deep sleep - press A/B to wake");
    Serial.flush();

    M5.Display.setBrightness(BRIGHT_ACTIVE);
    M5.Display.fillScreen(colBg());
    M5.Display.setTextDatum(middle_center);
    M5.Display.setFont(&fonts::efontCN_16);
    M5.Display.setTextColor(colText(), colBg());
    M5.Display.drawString("进入休眠", M5.Display.width() / 2, M5.Display.height() / 2 - 16);
    M5.Display.setFont(&fonts::efontCN_12);
    M5.Display.setTextColor(colSub(), colBg());
    M5.Display.drawString("按 A 或 B 唤醒", M5.Display.width() / 2, M5.Display.height() / 2 + 14);
    M5.Display.setTextDatum(top_left);
    delay(1200);

    releaseHIDModifiers();
    releaseGyroMouseButtons();
    NimBLEDevice::stopAdvertising();
    delay(50);

    rtc_gpio_pullup_en((gpio_num_t)11);
    rtc_gpio_pulldown_dis((gpio_num_t)11);
    rtc_gpio_pullup_en((gpio_num_t)12);
    rtc_gpio_pulldown_dis((gpio_num_t)12);

    esp_sleep_enable_ext1_wakeup((1ULL << 11) | (1ULL << 12), ESP_EXT1_WAKEUP_ANY_LOW);
    M5.Display.setBrightness(0);
    esp_deep_sleep_start();   // 不返回；唤醒后从 setup() 重新开始
}

static void updateSleep() {
    const uint32_t now = millis();

    // 按住按键视为正在操作，不计入空闲
    if (M5.BtnA.isPressed() || M5.BtnB.isPressed()) {
        noteActivity();
        return;
    }

    const uint32_t idle = now - g_lastActivity;
    if (g_powerState == PS_ACTIVE && idle > DIM_AFTER_MS) applyPowerState(PS_DIM);
    else if (g_powerState == PS_DIM && idle > SCREEN_OFF_AFTER_MS) applyPowerState(PS_OFF);

    // 深度休眠：长时间空闲、未接 USB（充电或插着线都不睡）
    const bool onUsb = g_charging || g_vbusPresent;
    if (idle > SLEEP_AFTER_MS && !onUsb) enterDeepSleep();
}

static void refreshBattery() {
    const uint32_t now = millis();
    if (now < g_batteryNextRead) return;
    g_batteryNextRead = now + 10000;

    // M5PM1 的电压读数噪声极大（充电时单次采样会在 60~97 之间乱跳），
    // 这里降低 I2C 读取频率，以 4 个样本取平均并限制单次更新幅度。
    int sum = 0, n = 0;
    for (int i = 0; i < 4; ++i) {
        int v = M5.Power.getBatteryLevel();
        if (v >= 0) {
            sum += v;
            ++n;
        }
    }
    int pct = (n > 0) ? (sum + n / 2) / n : -1;
    if (pct >= 0 && g_batteryPct >= 0) {
        int d = pct - g_batteryPct;
        if (d > 4) pct = g_batteryPct + 4;
        else if (d < -4) pct = g_batteryPct - 4;
    }
#if M5_DIAG
    g_diagPctRaw = (n > 0) ? (sum + n / 2) / n : -1;
#endif

    bool chg = (M5.Power.isCharging() == m5::Power_Class::is_charging_t::is_charging);
    bool vbus = M5.Power.getVBUSVoltage() > 4000;

    // PM1 的充电状态读数会抖动，连续 3 次读到同一新值才切换，避免指示颜色闪烁
    bool chgChanged = false;
    if (chg == g_charging) {
        g_chgStreak = 0;
    } else if (chg == g_chgRaw) {
        if (++g_chgStreak >= 2) {
            g_charging = chg;
            g_chgStreak = 0;
            chgChanged = true;
        }
    } else {
        g_chgRaw = chg;
        g_chgStreak = 1;
    }

    if (pct != g_batteryPct || vbus != g_vbusPresent || chgChanged) {
        g_batteryPct = pct;
        g_vbusPresent = vbus;
        g_headerDirty = true;
    }
}

// MARK: - Arduino 入口

void setup() {
    auto cfg = M5.config();
    cfg.internal_spk = true;
    M5.begin(cfg);
    loadMenuManifest();
    // StickS3 扬声器体积很小；72/255 在手持距离也偏弱，提高到清晰且不易破音的档位。
    M5.Speaker.setVolume(180);
    setCpuFrequencyMhz(80);

    Serial.begin(115200);
    Serial.printf("[M5] board=%d  display=%dx%d  imu=%d  wakeup=%d\n",
                  (int)M5.getBoard(), M5.Display.width(), M5.Display.height(),
                  (int)M5.Imu.getType(), (int)esp_sleep_get_wakeup_cause());

    // 竖屏（135×240）为 StickS3 自然持握方向；若面板报横向则旋正
    if (M5.Display.width() > M5.Display.height()) {
        M5.Display.setRotation((M5.Display.getRotation() + 1) & 3);
    }

    M5.Display.setBrightness(BRIGHT_ACTIVE);
    M5.Display.fillScreen(colBg());
    M5.Display.setFont(&fonts::efontCN_14);
    M5.Display.setTextColor(colText(), colBg());
    M5.Display.setTextDatum(middle_center);
    M5.Display.drawString("启动蓝牙…", M5.Display.width() / 2, M5.Display.height() / 2);
    M5.Display.setTextDatum(top_left);

    g_batteryPct = M5.Power.getBatteryLevel();
    g_charging = (M5.Power.isCharging() == m5::Power_Class::is_charging_t::is_charging);
    g_vbusPresent = M5.Power.getVBUSVoltage() > 4000;
    g_chgRaw = g_charging;
    Serial.printf("[M5] battery level=%d charging=%d vbus=%d\n",
                  g_batteryPct, (int)g_charging, (int)g_vbusPresent);

    setupBLE();

    g_lastActivity = millis();
    g_dirty = true;
    drawScreen();
}

void loop() {
    M5.update();
    const bool fresh = pollImu();
    const bool pointerMoved = fresh && g_gyroMouseMode && processGyroMouse();

    // 物理交互或 Mac 写入 → 唤醒屏幕并重置休眠计时
    const bool moved = fresh && g_mag > SHAKE_G;
    const bool touched = M5.BtnA.wasPressed() || M5.BtnB.wasPressed();
    bool pinged = false;
    if (g_blePing) {
        g_blePing = false;
        pinged = true;
    }

    if (touched || moved || pointerMoved || pinged) {
        noteActivity();
        if (g_powerState != PS_ACTIVE) {
            const bool wasOff = (g_powerState == PS_OFF);
            applyPowerState(PS_ACTIVE);
            // 息屏时摇动只用来点亮屏幕，不误触发翻页
            if (wasOff && moved) {
                g_inShake = false;
                g_lastShake = millis();
            }
        }
    }

    if (g_powerState != PS_OFF) {
        handleButtons();
        if (fresh && !g_gyroMouseMode) processShake();
    } else {
        g_inShake = false;
    }

    refreshBattery();
    reportHIDStateIfChanged();
    if (g_mouseCalibrationCompletedAt != 0
        && millis() - g_mouseCalibrationCompletedAt >= 1600) {
        g_mouseCalibrationCompletedAt = 0;
        g_bodyDirty = true;
    }

    if (g_powerState != PS_OFF) {
        if (g_dirty) {
            g_dirty = false;
            g_headerDirty = false;
            g_bodyDirty = false;
            g_footerDirty = false;
            M5.Display.startWrite();
            drawScreen();
            M5.Display.endWrite();
        } else if (g_headerDirty || g_bodyDirty || g_footerDirty) {
            const bool header = g_headerDirty;
            const bool body = g_bodyDirty;
            const bool footer = g_footerDirty;
            g_headerDirty = false;
            g_bodyDirty = false;
            g_footerDirty = false;
            M5.Display.startWrite();
            if (header) drawHeader(M5.Display.width());
            if (body) drawBody(M5.Display.width(), M5.Display.height());
            if (footer) drawFooter(M5.Display.width(), M5.Display.height());
            M5.Display.endWrite();
        }
    }

    updateSleep();

#if M5_DIAG
    static uint32_t nextDiag = 0;
    if (millis() >= nextDiag) {
        nextDiag = millis() + 5000;
        int count, active;
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            count = (int)g_devices.size();
            active = g_active;
        }
        Serial.printf("[M5] diag t=%lus batt=%d raw=%d chg=%d chgraw=%d vbus=%d conn=%d dev=%d active=%d pwr=%d idle=%lums\n",
                      (unsigned long)(millis() / 1000), g_batteryPct, g_diagPctRaw, (int)g_charging,
                      (int)g_chgRaw, (int)g_vbusPresent, (int)g_connected, count, active,
                      (int)g_powerState, (unsigned long)(millis() - g_lastActivity));
    }
#endif

    // 活跃时保证按键/摇晃响应；调暗和息屏后主动降低轮询频率。
    if (g_powerState == PS_ACTIVE) delay(20);
    else if (g_powerState == PS_DIM) delay(80);
    else delay(200);
}
