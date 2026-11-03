import Foundation
import LinxDisplayCore

func testXiaomiCloudBasics() throws {
    checkEqual(XiaomiCloudRegion.cn.oauthHost, "ha.api.io.mi.com", "小米中国区 OAuth 主机")
    checkEqual(XiaomiCloudRegion.de.oauthHost, "de.ha.api.io.mi.com", "小米欧洲区 OAuth 主机")
    checkEqual(XiaomiCloudRegion.allCases.count, 6, "小米云支持六个区域")

    let url = XiaomiCloudClient.authorizationURL(region: .cn,
        redirectURL: "http://127.0.0.1:8123/callback",
        deviceID: "ha.test", state: "state")
    let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
    checkEqual(item("client_id"), XiaomiCloudClient.clientID, "小米 OAuth client_id")
    checkEqual(item("redirect_uri"), "http://127.0.0.1:8123/callback", "小米 OAuth 回调")
    checkEqual(item("device_id"), "ha.test", "小米 OAuth 设备标识")

    let light = XiaomiDevice(did: "1", name: "客厅灯", model: "yeelink.light",
                             urn: "urn:miot-spec-v2:device:light:0000A001:yeelink:1", online: true)
    checkEqual(light.category, "light", "小米设备类别")
    checkEqual(light.subtitle, "yeelink.light", "小米设备副标题")

    let account = XiaomiAccount(accessToken: "a", refreshToken: "r", deviceID: "ha.test",
                                region: .cn, expiresAt: Date().addingTimeInterval(3600))
    check(!account.isExpired, "未过期的小米账号")
    let encoded = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(XiaomiAccount.self, from: encoded)
    checkEqual(decoded, account, "小米账号编解码")

    let settings = AppSettings()
    settings.xiaomiRegionRaw = "de"
    settings.xiaomiSelectedDeviceIDs = ["1", "2"]
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    checkEqual(restored.xiaomiRegionRaw, "de", "小米区域设置往返")
    checkEqual(restored.xiaomiSelectedDeviceIDs, ["1", "2"], "小米设备选择往返")
    print("  小米云登录基础通过")
}
