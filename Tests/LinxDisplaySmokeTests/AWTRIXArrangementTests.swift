import Foundation
import LinxDisplayCore

func testAWTRIXArrangementRecovery() throws {
    let apps = try JSONDecoder().decode([AWTRIXAppInfo].self, from: Data(#"[{"name":"Time","enabled":true,"inLoop":true},{"name":"Time","enabled":true,"inLoop":true},{"name":"lingxi_home","enabled":false,"inLoop":false},{"name":"background","enabled":true,"inLoop":false,"headless":true},{"name":"off_script","enabled":false,"inLoop":false,"headless":true}]"#.utf8))
    let original = AWTRIXAppArrangement(apps: apps)
    var requests = AWTRIXLatestDisplayRequestPolicy()
    let device = UUID()
    let old = requests.issue(for: device)
    checkEqual(requests.currentGeneration(for: device), old, "AWTRIX 驻留计时器记住创建时的显示代次")
    _ = requests.issue(for: device)
    check(requests.currentGeneration(for: device) != old, "新请求尚在取数时，旧归还计时器不能清空它")
    checkEqual(original.order, ["Time", "Time"], "AWTRIX 保留固件重复轮播槽位")
    checkEqual(original.disabled, ["lingxi_home", "off_script"], "AWTRIX 不能把不显示的后台脚本当作停用")
    let changed = original.settingVisibleOrder(["lingxi_home", "lingxi_home"], apps: apps)
    checkEqual(changed.order, ["lingxi_home", "lingxi_home"], "AWTRIX 保存轮播时不折叠重复槽位")
    checkEqual(changed.disabled, ["Time", "off_script"], "AWTRIX 修改可见轮播不能更改后台脚本启用状态")
    var settings = AWTRIXSettings()
    settings.baseURL = "http://test.invalid"
    settings.manualDisplaySession = AWTRIXManualDisplaySession(appName: "lingxi_home",
        order: original.order, disabled: original.disabled, autoTransition: true,
        baseURL: settings.baseURL, username: "tester")
    let restored = try JSONDecoder().decode(AWTRIXSettings.self, from: JSONEncoder().encode(settings))
    checkEqual(restored.manualDisplaySession, settings.manualDisplaySession,
               "AWTRIX 临时显示保留设备身份与完整恢复点，重启后可恢复")
    let legacy = try JSONDecoder().decode(AWTRIXSettings.self, from: Data("{}".utf8))
    check(legacy.manualDisplaySession == nil, "旧AWTRIX配置不会虚构恢复点")
    print("  AWTRIX 原生轮播隔离与临时显示恢复通过")
}
