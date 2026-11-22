# Pico 桌面控制台与双机工作区

本次将 Pico 联动开发中尚未上传的 Mac 端改动合入 `test/2.0-c6-alpha20`。以远端最新测试分支为基础，保留已有中控、DeepSeek、小米与 WidgetKit 更新；不创建正式 Release，也不升级用户设备。

## 功能

- Stream Deck 式快捷按键：选择 Mac 应用，调整名称、顺序和所属屏幕；设备接收 16 阶灰度图标、名称与动作 ID，应用路径只保存在 Mac。
- USB 优先，支持已认证的局域网连接；断开后保留设备图标，拒绝过期、离线及重复点击，不补执行旧操作。
- 90° 旋转：由电脑保存方向偏好，随控制台配置发送给支持的固件；退出时由固件恢复原方向。
- 双设备工作区：分别显示电脑连接、Pico 配对和双机连接状态。第二台可保持独立、接收语义画板，或扩展控制台。
- 每台最多 24 个按键，两台合计 48 个；扩展屏动作经既有配对通道回传，Mac 只执行一次。
- 灵犀画板按明确操作同步到另一台，完整接收后才显示；阅读、锁屏或 TF 占用时暂停。纯照片仍使用原有独立图片通道。
- 信息卡改用语义模型；支持增量能力的固件只接收变化数据，旧固件保持完整模型传输。传输失败清除增量基线，下次发送完整模型。
- Pico 导航按内容、桌面工作区、设备分组，提供独立控制台入口。

## 配套固件与 TF 应用

仓库默认固件资源仍由 `Resources/Firmware/ReadPico/manifest.json` 指定。为复现该联动开发候选，另行归档 `Resources/Firmware/ReadPicoDual117`：

| 资源 | 版本 | SHA-256 |
| --- | --- | --- |
| APP | 0.40.0-dual117 | `5c3b88c809c54318759d040c33f31cdb08785b4ed9d83c4999fc398129eff1f2` |
| 桌面控制台 TF | 1.1.0 | `5c48e6804cbe801d0492eb347461d63febe99f2e16660a0aa3374b910c7b0549` |
| 灵犀画板 TF | 1.0.1 | `2ac8eb6da035a3b325e0d4589f052ed89a69110b0a4c2ad4d54edcc2c32f8662` |

这是既有本地候选的原始归档，非此次重新编译的固件，亦不代表最新微信读书诊断版。仅含 APP 更新资源，不含首次安装分区镜像；TF 组件需要显式导入，不随刷固件自动覆盖。两台设备需使用兼容的工作区协议与配套 TF 组件。

需要构建使用这组资源的 Mac 候选时：

```sh
LINGXI_READPICO_FIRMWARE_DIRECTORY="$PWD/Resources/Firmware/ReadPicoDual117" \
LINGXI_APP_OUTPUT_DIRECTORY=/private/tmp/lingxi-pico-candidate \
bash scripts/make-app.sh
```

不要给运行中固件较新的设备降级；先核对版本与分区。此参数只选择打包资源，不执行刷写。

## 本次合并验证

- 合并后完整 Mac `LinxDisplayApp` Release 编译通过（macOS 26.5 SDK，目标最低 macOS 26.0）。
- 控制台协议、24/48 项配置、90° 标记、UTF-8 边界、CRC、离线/旧会话/重复事件及增量完整性检查通过；样例模型 1302 字节缩减至 25 字节差分。
- 画板会话生命周期 97 项检查通过；使用实际生产会话代码与注入设备。
- USB PTY 回归通过：图片、双方向画布、应用通道、CRC/ACK、取消、错误回执和不启用 MSC 的传输。
- dual117 原始 APP 的长度、版本描述与 SHA-256 一致；两个 TF 包及目录通过仓库校验器。
- 本次未运行窗口、未访问设备，也未重做双台实机验收。自动化测试不代替真实无线、触摸、屏幕及长时间运行验收。

## 重现专项测试

当前 CLT 存在 SDK 27 宏依赖缺失，仓库选择器会回退到 macOS 26.5；测试须将同一 SDK 传给编译包装器：

```sh
export SDKROOT="$(scripts/select-macos-sdk)"
export CLANG_MODULE_CACHE_PATH=/private/tmp/lingxi-pico-test-cache
Tools/ReadPicoManagerTests/run-console-data.sh /private/tmp/lingxi-console-tests
Tools/ReadPicoManagerTests/run-board-session.sh /private/tmp/lingxi-board-tests
Tools/ReadPicoManagerTests/run-usb-direct-board.sh /private/tmp/lingxi-usb-tests
python3 scripts/validate-readpico-tf-resources.py Resources/Firmware/ReadPicoDual117
```

测试使用合成数据、模拟设备或 PTY；不读取用户账号，不挂载用户 TF 卡，不启动用户应用。控制台真实唤起计算器此前由用户确认；本轮仅重新验证合并后的源码，不将该历史验收描述为本轮实测。
