import AppKit
import LinxDisplayCore

if CCSwitchQuotaClient.runScriptWorkerIfRequested() {
    exit(0)
}

// 手动引导入口（SPM 可执行 target 的标准做法）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
