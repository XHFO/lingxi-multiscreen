# 多屏灵犀 M5 控制器固件（M5Stack StickS3）

把一台 **M5Stack StickS3（ESP32-S3-PICO-1）** 变成多屏灵犀主应用（Mac）的**蓝牙控制器**：

- **主菜单** → Vibe Coding 为第一项，多屏设备、Home Assistant 与 Mac 快捷键使用同一套卡片导航。
- **按键 A / B** → 下一项 / 上一项；**长按 A** → 进入、确认或执行；**长按 B** → 返回。
- **摇晃设备** → 仅在多屏设备页翻页当前被控设备的内容。
- **Mac 快捷键** → 包含多媒体控制、陀螺仪鼠标、演示翻页器和自定义动作；Vibe Coding 保留主菜单快捷入口。电脑端配置的动作由控制器作为蓝牙输入设备直接执行。
- **多媒体控制** → 合并为播放控制与音量控制两张卡：播放卡左摇上一曲、右摇下一曲、长按 A 播放/暂停；音量卡左摇音量减、右摇音量加、长按 A 静音/恢复。全部由 BLE HID Consumer Control 直接执行。
- **飞鼠指针** → 参考 LG 电视飞鼠：进入页面后连续静止约半秒完成校准，并把 Mac 指针放到当前显示器中央；随后采用相对位移，不受固定物理中心限制。慢速转腕精确移动，快速扫腕非线性加速，停手立即停止。重力方向会自动适配竖握与平握：左右转腕控制水平、前后俯仰控制垂直。A 短按左键、A 长按并保持可拖拽；B 默认短按右键、长按返回。开启“短按 B 临时脱开”后，B 短按改为暂停/恢复指针跟随，便于调整握姿。A+B 或软件中的“重新居中”可随时重新校准。仅在飞鼠页启用高频 IMU 采样，静止后自动降频和息屏。
- **屏幕** → 每页最多三张固定高度卡片；不足三张时不拉伸填满。
- **蜂鸣器** → 选择、确认和返回提供清晰的短音反馈，可在每台控制器的设备设置中关闭。
- **菜单与软件同步** → 只显示电脑端已勾选且有实际内容的功能；多媒体控制也可独立关闭。
  精简后的菜单清单会写入设备 NVS，控制器重启后无需等待 Mac 回传即可直接显示上次同步的本地主菜单。

控制器与 Mac 之间**只走蓝牙 BLE**，无需给设备配 Wi-Fi。

## 硬件

- M5Stack StickS3：ESP32-S3-PICO-1（8MB Flash + 8MB PSRAM），1.14 英寸 135×240 彩色屏，
  内置 BMI270 IMU，正面屏幕下方两个按键（BtnA=GPIO11 / BtnB=GPIO12），
  只引出一个 USB-C 原生 USB 口（USB-Serial/JTAG，没有 USB-UART 桥，也没有 BOOT/RST 按键）。
- 一根 USB-C 数据线。

> PlatformIO 官方板级列表暂无 StickS3，`platformio.ini` 用同为 ESP32-S3-PICO-1 的
> `m5stack-stamps3` 作为编译目标，并按 StickS3 的 8MB Flash 指定分区表；
> M5Unified 在运行时自动识别 StickS3，配置对应的 135×240 屏、BMI270 IMU 与两个按键。
> 若换成 CoreS3 等其它 ESP32-S3 + 屏 + IMU 的组合，需要调整 `board` 与屏幕相关代码。

## 构建与刷写

固件用 [PlatformIO](https://docs.platformio.org/) 构建（Arduino 框架）。

1. 安装 PlatformIO Core（任选其一）：
   - `brew install platformio`
   - 或 `python3 -m pip install --upgrade platformio`
   - 或安装 VS Code 的 PlatformIO IDE 插件，用其打开本目录。
2. 用 USB-C 连接 StickS3，在本目录执行（PlatformIO 会自动识别唯一的 StickS3 串口；如连接了多台串口设备，先用 `pio device list` 查询端口）：

   ```bash
   pio run                 # 编译，并额外生成可供软件一键刷机的 firmware-full.bin
   pio run -t upload       # 编译并刷写到设备（自动识别端口）
   pio device monitor      # 打开串口监视（115200），查看启动日志
   # 多串口环境可分别追加 --upload-port /dev/cu.usbmodemXXXX 或 --port /dev/cu.usbmodemXXXX
   ```

   `.pio/build/m5stack-sticks3/firmware.bin` 只是应写入 `0x10000` 的应用分区，不能交给
   多屏灵犀从 `0x0` 一键刷写。软件内置的必须是构建后自动生成的 `firmware-full.bin`，
   其中包含 bootloader、分区表、boot_app0 与应用；应用和打包脚本都会检查这些关键结构。

   StickS3 没有 BOOT/RST 按键，esptool 通过原生 USB 自动让芯片进入下载模式，直接刷写即可。
   刷完后 `platformio.ini` 里的 `board_upload.after_reset = watchdog_reset` 会用 RTC 看门狗复位芯片，
   让固件立即运行；若沿用默认的 `hard_reset`，StickS3 在原生 USB 下复位后芯片会停在 ROM
   下载模式（屏幕不亮、BLE 不广播），需要手动断电重上电。首次构建会自动下载 espressif32
   工具链与依赖库，耗时较长。

   启动日志应包含 `[M5] board=26  display=135x240  imu=6` 与
   `[M5] advertising as Lingxi-Controller-XXXX`（XXXX 取自设备 MAC 后 4 位）。

3. 依赖库（`platformio.ini` 中已固定版本，自动拉取）：
   - `m5stack/M5Unified`（屏幕、按键、IMU）
   - `h2zero/NimBLE-Arduino`（BLE GATT 外设）
   - `bblanchon/ArduinoJson`（解析 Mac 写来的信息）

## 与 Mac 应用配对

1. 刷写完成后设备开机即广播，广播名为 `Lingxi-Controller-XXXX`（后缀取自设备 MAC 后 4 位，
   例如本机实测为 `Lingxi-Controller-B270`）。
2. 打开 Mac 端**多屏灵犀**，进入 **设备管理 → M5 控制器**，点击 **扫描 M5 控制器**。
   （首次使用会弹出系统蓝牙授权，请允许。）
3. 在扫描结果里找到你的设备，点 **配对**。配对成功后主应用自动连接，并在导航中出现
   「M5 控制器」页面。
   新固件同时提供标准 BLE HID 键盘、多媒体键和鼠标服务；macOS 首次识别时可能另外显示一次蓝牙输入设备
   配对提示，请允许。常用字母、数字、方向键、功能键与左右修饰键都会通过真实蓝牙键盘
   发送，因而不需要辅助功能权限，也可兼容会拒绝软件模拟事件的微信输入法。
   固件会在控制服务连接后主动发起 HID 安全配对。scheme-11 在普通固件升级时保留有效 bond，
   只有用户在多屏灵犀中明确执行“解除配对”或删除控制器时才清理设备端密钥。若屏幕状态胶囊
   显示橙色“待配对”，请先在 macOS“系统设置 → 蓝牙”中忽略旧的 `Lingxi-Controller`，
   再回到软件重新扫描和配对；绿色“已配对”才表示键盘服务可用。
4. 在「M5 控制器」页面勾选**被控设备**（灵犀68 键盘 / 口袋先知 / 摘录 / AI Mac 小屏幕 / AWTRIX NG 的
   已启用实例）。勾选顺序即两个侧键的循环切换顺序。
5. 现在即可从控制器主菜单进入 Vibe Coding、多屏设备、Home Assistant 或 Mac 快捷键；多媒体控制位于
   “Mac 快捷键”内。A/B 选择，长按 A 进入或执行，长按 B 返回。多媒体的两张组合卡使用左右摇
   执行成对动作，长按 A 执行卡片中央动作。多屏设备页仍可摇晃翻页当前目标；停留在 Vibe Coding 的
   “语音输入”动作时，摇一摇会通过真实蓝牙键盘发送 Command+A 与 Delete 清空当前输入框。
   正在长按说话时不会触发清空，避免中断语音快捷键状态。

   陀螺仪鼠标会改变设备的 HID 描述。首次从旧固件升级后，如果键盘可用但指针不动，
   请在 macOS“系统设置 → 蓝牙”中忽略旧的 `Lingxi-Controller`，再回到多屏灵犀重新扫描和配对。

断线后设备会自动重新广播，Mac 端也会自动重连，无需重新配对。

## 蓝牙协议（GATT）

必须与 Mac 端 `Sources/LinxDisplayCore/M5ControllerSupport.swift` 保持一致。

| 项目 | UUID |
| --- | --- |
| 服务 Service | `E0A3C001-5B4C-4D2E-9F8A-6C1D2E3F4A50` |
| 事件特征 Event（设备 notify → Mac 订阅） | `E0A3C002-5B4C-4D2E-9F8A-6C1D2E3F4A50` |
| 信息特征 Info（Mac write → 设备渲染） | `E0A3C003-5B4C-4D2E-9F8A-6C1D2E3F4A50` |

**事件（设备 → Mac，JSON 文本，notify）**

```jsonc
{"type":"shake","dir":1}      // dir=1 下一页 / dir=-1 上一页
{"type":"button","key":"a"}   // 正面按键：下一台设备／下一项
{"type":"button","key":"b"}   // 背面按键：上一台设备／上一项
{"type":"button","key":"a","press":"long"} // 长按开始
{"type":"button","key":"a","press":"up"}   // 长按松开（按住说话结束）
{"type":"button","key":"a","press":"hid-long"} // 已由设备 HID 发送按下
{"type":"button","key":"a","press":"hid-up"}   // 已由设备 HID 发送松开
{"type":"input","action":"clear","source":"hid"} // HID 已完成摇晃清空
{"type":"input","action":"clear"}                  // 请求 Mac 兼容回退
{"type":"media","dir":-1,"source":"hid"}         // 已由 HID 执行左摇媒体动作
{"type":"mouse","action":"recenter"}               // 飞鼠校准完成，请 Mac 置中指针
{"type":"hid","ready":true,"secured":true}         // 系统键盘已配对并订阅
```

**信息（Mac → 设备，JSON 文本，write with response）**

```jsonc
{
  "v": 1,
  "active": 0,                       // 当前选中的被控设备下标
  "buzzer": true,                    // 本机蜂鸣器反馈总开关
  "hidModifiers": 1,                // 可选：BLE HID modifier byte；1=左 Control
  "hidKey": 44,                     // 可选：USB HID Usage；44=Space，0=纯修饰键
  "hidHold": true,                  // 语音输入保持按下；普通动作发送一次按下/松开
  "clearInputOnShake": true,        // 语音输入动作选中时启用摇晃清空
  "consumerUsage": 205,             // 可选：Consumer Control Usage；205=播放/暂停
  "consumerUsageLeft": 182,         // 可选：左摇 Usage；182=上一曲
  "consumerUsageRight": 181,        // 可选：右摇 Usage；181=下一曲
  "gyroMouseActive": true,          // 仅在陀螺仪鼠标页启用
  "gyroMouseSensitivity": 1.0,      // 灵敏度 0.35...2.5
  "gyroMouseDeadZone": 1.4,         // 静止死区 0.4...4.0
  "gyroMouseSmoothing": 0.58,       // 平滑程度 0...0.85
  "gyroMouseInvertX": false,
  "gyroMouseInvertY": false,
  "gyroMouseClutchEnabled": true, // B 短按临时脱开/恢复；false 时为右键
  "gyroMouseRecenterToken": 3,    // 每次软件请求重新居中时递增
  "mainMenuMask": 15,               // 主菜单：Vibe/设备/HA/Mac 快捷键
  "shortcutMenuMask": 15,           // 子菜单：多媒体/鼠标/演示/自定义
  "targetDeviceCount": 3,
  "homeAssistantEntityCount": 2,
  "vibeActionCount": 1,
  "presentationActionCount": 2,
  "customActionCount": 1,
  "devices": [
    {"name": "灵犀68 键盘", "detail": "正在播放", "available": true},
    {"name": "口袋先知",   "detail": "画板 2",   "available": true},
    {"name": "摘录",       "detail": "Dot 内容", "available": false}
  ]
}
```

`devices` 字段为兼容旧协议保留，现可承载任意菜单卡片；`detail` 为卡片副标题，
`available=false` 表示该项目离线或不可执行。快捷键键码不会写入控制器。
`mainMenuMask` 与 `shortcutMenuMask` 是软件勾选状态生成的功能清单；相关计数字段用于设备端直接绘制副标题。
固件仅在清单发生变化时写入 `lingxi-menu` NVS 命名空间，既能在重启后恢复菜单，也避免每次 BLE 更新都写闪存。
只有当前选中的“语音输入”是纯修饰键时，Mac 才会下发 `hidModifiers`。固件检测到
macOS 已订阅 HID 报告后直接发送物理键盘报告；尚未订阅时自动回退原有 Mac 模拟路径。
`clearInputOnShake` 只在当前选中“语音输入”时为 true；固件优先直接发送 HID
Command+A 与 Delete，未完成 HID 订阅时才请求 Mac 使用辅助功能事件回退。
信息载荷可能超过单个 BLE 包长度，Mac 端用带响应的写入触发长写流程，NimBLE 会自动组包后
一次性回调 `onWrite`。

HID 报告 ID：`1` 为键盘，`2` 为 Consumer Control，`3` 为三键相对坐标鼠标（按键 + X/Y + 滚轮）。

## 行为与可调参数（`src/main.cpp`）

- `SHAKE_G`（默认 2.3g）：摇晃触发阈值，越大越不易误触。
- `SHAKE_WINDOW_MS`（默认 150ms）：一次摇晃的采样窗口，取窗口内横向（X 轴）主冲量符号决定方向。
- `SHAKE_COOLDOWN_MS`（默认 600ms）：两次摇晃间的最小间隔，抑制连续误报。
- `ROWS_PER_PAGE`（默认 3）：135×240 屏幕一页最多显示三张固定高度卡片，超出后跟随当前选中项分页。

按键映射：`M5.BtnA` → `key:"a"`（下一台／确认），`M5.BtnB` → `key:"b"`（上一台／返回）。

空闲功耗：CPU 默认运行在 80 MHz；8 秒无交互后调暗屏幕，并把 BLE 从 15–30 ms
活跃连接切换为 60–90 ms、latency 1 的低占空比连接。该档位将首次唤醒操作控制在约
180 ms 内，避免旧版最坏 480 ms 的迟滞。30 秒后关闭屏幕，10 分钟后在未接 USB 时进入深度休眠。

## 排查

- **刷写后屏幕不亮、Mac 扫描不到设备**：芯片停在 ROM 下载模式。正常流程已由
  `board_upload.after_reset = watchdog_reset` 处理；若仍遇到，可再触发一次看门狗复位：

  ```bash
  pio pkg exec -p tool-esptoolpy -- esptool.py --port /dev/cu.usbmodemXXXX \
      --before no_reset --after watchdog_reset read_mac
  ```

  或者直接拔插 USB 线断电重上电（StickS3 没有复位按键）。
- **想确认固件在跑**：`pio device monitor`（115200）应打印
  `[M5] advertising as Lingxi-Controller-XXXX`；设备屏幕会显示「灵犀控制器」。
- **刷写报串口被占用**：先关掉 `pio device monitor` 或其它串口工具。

## 说明

- 中文字体使用 M5GFX 内置的 `efontCN` 位图字体，无需额外字库文件。
- 本固件仅作为控制端，不接收/渲染画面帧；被控设备的实际画面推送仍由 Mac 应用负责。
