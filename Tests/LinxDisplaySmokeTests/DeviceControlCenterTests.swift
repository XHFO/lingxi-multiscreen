import Foundation
import LinxDisplayCore

func testDeviceControlCenterPolicy() {
    var devices = DeviceType.allCases.map { ManagedDevice(type: $0, name: "相同名称", settings: DeviceSettings()) }
    devices[0].isEnabled = false
    let snapshot = devices
    let cards = DeviceControlCenterPolicy.devices(devices)
    checkEqual(cards.map(\.id), devices.map(\.id), "中控保留所有设备原顺序与稳定ID，不按同名或启用状态丢卡片")
    checkEqual(cards.filter { !$0.isEnabled }.count, 1, "停用设备保留可进入的设置卡片")
    checkEqual(DeviceControlCenterPolicy.destination(for: devices[0]), .deviceSettings, "停用设备进入档案设置而不重新激活")
    let destinations: [DeviceType: DeviceControlCenterPolicy.Destination] = [
        .keyboard: .keyboard, .oracle: .oracle, .excerpt: .excerpt, .aiMacScreen: .colorScreen,
        .c6Screen: .c6, .awtrix: .awtrix, .readPico: .pico, .m5Controller: .controller,
        .homeAssistant: .deviceSettings, .bambuLab: .deviceSettings, .formlabs: .deviceSettings]
    for device in devices.dropFirst() {
        checkEqual(DeviceControlCenterPolicy.destination(for: device), destinations[device.type]!, "各设备进入所属详情，服务设备仍可设置")
    }
    for type in DeviceType.allCases {
        let actual = DeviceControlCenterPolicy.hasDisplay(type)
        checkEqual(actual, [.keyboard, .oracle, .excerpt, .aiMacScreen, .c6Screen, .awtrix, .readPico, .m5Controller].contains(type), "无屏幕服务不伪造预览")
    }
    check(DeviceControlCenterPolicy.hasDisplay(.m5Controller), "StickS3 控制器的135×240屏幕具有中控预览路径")
    checkEqual(devices, snapshot, "读取中控卡片和导航策略不会改写档案")
    check(DeviceControlCenterPolicy.devices([]).isEmpty, "首次使用保留空设备引导")
}
