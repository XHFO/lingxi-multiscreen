import Foundation
import LinxDisplayCore

func testC6WiFiProvisioning() throws {
    let retained = try C6WiFiProvisioning.makeImage(networkMode: .preserve, ssid: "", password: "")
    checkEqual(retained, nil, "保留网络无需SSID或密码且不产生配网数据")
    checkEqual(try C6WiFiProvisioning.makeImage(networkMode: .preserve, ssid: "stale\0ssid", password: "short"), nil,
        "保留网络忽略此前未提交的无效网络输入，不写入旧密码")
    check((try? C6WiFiProvisioning.makeImage(networkMode: .replace, ssid: "", password: "")) == nil,
        "更换网络仍要求有效SSID，不把空输入当成保留配置")
    check((try? C6WiFiProvisioning.makeImage(networkMode: .replace, ssid: "Test24", password: "short")) == nil,
        "更换网络仍校验密码")
    let image = try C6WiFiProvisioning.makeImage(ssid: "Test24", password: "password123")
    checkEqual(try C6WiFiProvisioning.makeImage(networkMode: .replace, ssid: "Test24", password: "password123"), image,
        "更换网络使用相同的完整校验一次性配网镜像")
    checkEqual(image.count, 4096, "C6 USB 配网区固定为独立 4KB 扇区")
    checkEqual(C6WiFiProvisioning.flashAddress, 0x3f0000, "C6 配网地址不与 NVS 或 OTA 应用区重叠")
    checkEqual(String(decoding: image.prefix(8), as: UTF8.self), "LXC6WF01", "C6 配网格式不误用 ESP8266 协议")
    checkEqual(Array(image[8..<12]), [1, 6, 11, 0], "C6 配网版本与字节长度明确")
    checkEqual(Array(image[112..<116]), [0x71, 0x8a, 0xd8, 0x6e], "C6 配网 CRC 与 IEEE 固件协议一致")
    check(C6WiFiProvisioning.validateImage(image), "C6 配网数据通过完整性校验")
    check(image[116...].allSatisfy { $0 == 0xff }, "C6 配网扇区剩余数据为 FF")
    check(C6WiFiProvisioning.validateImage(try C6WiFiProvisioning.makeImage(ssid: "开放网络", password: "")), "C6 支持开放网络空密码")
    check(C6WiFiProvisioning.validateImage(try C6WiFiProvisioning.makeImage(ssid: String(repeating: "A", count: 32), password: String(repeating: "a", count: 63))), "C6 支持最大普通密码和32字节SSID")
    check(C6WiFiProvisioning.validateImage(try C6WiFiProvisioning.makeImage(ssid: "2.4G", password: String(repeating: "a0", count: 32))), "C6 支持64位十六进制PSK")
    check(C6WiFiProvisioning.validateImage(try C6WiFiProvisioning.makeImage(ssid: "家中网络", password: "中文密码abcd")), "C6 密码与SSID以UTF8字节计算")
    for (ssid, password) in [("", "password123"), (String(repeating: "中", count: 11), "password123"),
        ("Test24", "short"), ("Test24", String(repeating: "中", count: 22)),
        ("Test24", String(repeating: "z", count: 64)), ("A\0B", "password123"), ("Test24", "pass\0word")] {
        check((try? C6WiFiProvisioning.makeImage(ssid: ssid, password: password)) == nil, "C6 拒绝无效SSID或密码字节边界")
    }
    for offset in [0, 8, 9, 10, 11, 12, 44, 109, 110, 111, 112, 4095] {
        var changed = image; changed[offset] ^= 1
        check(!C6WiFiProvisioning.validateImage(changed), "C6 拒绝损坏或未知格式配网记录")
    }
    check(!C6WiFiProvisioning.validateImage(image.prefix(115)), "C6 拒绝截断配网记录")
    check(!C6WiFiProvisioning.validateImage(try AIMacWiFiProvisioning.makeImage(ssid: "Test24", password: "password123")), "C6 拒绝 ESP8266 配网记录")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Firmware")
    let firmware = try Data(contentsOf: root.appendingPathComponent(EmbeddedC6Firmware.fullName))
    let original = try EmbeddedC6Firmware.flashRegions(from: firmware)
    let unchanged = try C6WiFiProvisioning.flashRegions(from: firmware, image: retained)
    checkEqual(unchanged.map(\.address), original.map(\.address), "不配网时保留原USB分段刷写逻辑")
    checkEqual(unchanged.map(\.data), original.map(\.data), "保留网络不修改任何固件分段内容")
    for region in unchanged {
        // esptool erases whole 4KB sectors; test the erased span, not just bytes.
        let eraseStart = region.address / 4096 * 4096
        let eraseEnd = (region.address + region.data.count + 4095) / 4096 * 4096
        check(eraseEnd <= 0x9000 || eraseStart >= 0x10000, "保留网络的扇区擦除范围避开全部NVS与PHY")
        check(eraseEnd <= C6WiFiProvisioning.flashAddress || eraseStart >= C6WiFiProvisioning.flashAddress + 4096,
            "保留网络不擦除或写入一次性Wi-Fi配网区")
    }
    let provisioned = try C6WiFiProvisioning.flashRegions(from: firmware, image: image)
    checkEqual(provisioned.map(\.address), [0, 0x8000, 0x10000, 0x20000, 0x3f0000], "配网仅追加C6专用扇区")
    checkEqual(provisioned.last?.data, image, "C6 配网记录传给独立刷写分段")
    for region in provisioned {
        check(region.address + region.data.count <= 0x9000 || region.address >= 0x10000, "C6 配网刷写保留NVS与PHY")
    }
    check((try? C6WiFiProvisioning.flashRegions(from: firmware, image: Data(repeating: 0, count: 4096))) == nil, "C6 刷写前拒绝无效配网镜像")

    let networks = WiFiNetworkDiscovery.normalized([
        .init(ssid: "Network", signal: -70, isOpen: false), .init(ssid: "Network", signal: -30, isOpen: false),
        .init(ssid: "Guest", signal: -60, isOpen: true), .init(ssid: "", signal: -10, isOpen: true)])
    checkEqual(networks.map(\.ssid), ["Network", "Guest"], "扫描同名网络去重且按信号排序，不显示无名称网络")
    checkEqual(networks.first?.signal, -30, "同名网络采用最强2.4GHz接入点")
    checkEqual(networks.last?.isOpen, true, "扫描保留开放网络标识")
}
