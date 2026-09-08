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

1. 给 ESP8266 刷入 `0.8.1-wifi-portal-fix` 精简固件。
2. 运行 `scripts/make-aimac-screen-app.sh` 构建实验应用。
3. 打开 `dist/灵犀小屏实验版.app`，填写设备 IP 并点击“连接测试”。
4. 选择系统仪表盘、桌面时钟或自定义图片，点击“立即推送”或开启自动推送。

应用先通过 `/api/info` 发现设备能力。新固件优先使用 240×240 RGB565
无损帧（115,200 字节、大端字节序），避免 JPEG 宏块和彩色边缘。旧固件则
自动回退到 24KB 以内 JPEG。画面未变化时不会重复上传。

当前主应用的设备管理页可在刷写前填写 2.4 GHz Wi-Fi，并将临时配网区与
固件一并写入。设备成功联网后会擦除临时配网区，通过唯一 mDNS 名称把 IP
返回主应用并自动创建设备档案。ESP8266 不支持 5 GHz/6 GHz；若自动连接失败，
设备热点的配网页面仍可点击扫描结果或手动填写 SSID 与密码。

无损推送只存在于独立实验应用，不读写多屏灵犀主版的设备或图片数据。
