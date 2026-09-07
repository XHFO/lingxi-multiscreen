# AI Mac 240×240 小屏实验版

此版本位于 `feature/esp8266-ai-screen` 分支，是与多屏灵犀主应用隔离的实验目标。

## 数据隔离

- 独立可执行目标：`AIMacScreenApp`
- 独立应用名称：`灵犀小屏实验版.app`
- 独立 Bundle ID：`com.lingxi.multiscreen.aimac.experimental`
- 独立数据目录：`~/Library/Application Support/LingxiAIMacScreenExperimental`
- 不使用 `LinxDisplayCore.SettingsStore`，不会迁移或读取 `LinxDisplay` 的配置
- 不创建主应用的登录启动项，也不复用主应用的窗口状态名称

## 使用

1. 给 ESP8266 刷入支持图片 API 的 `0.5.0-image-api` 固件。
2. 运行 `scripts/make-aimac-screen-app.sh` 构建实验应用。
3. 打开 `dist/灵犀小屏实验版.app`，填写设备 IP 并点击“连接测试”。
4. 选择系统仪表盘、桌面时钟或自定义图片，点击“立即推送”或开启自动推送。

应用始终生成严格的 240×240 JPEG，并在必要时自动降低质量，使图片不超过固件的
24KB 安全上限。画面未变化时不会重复上传。
