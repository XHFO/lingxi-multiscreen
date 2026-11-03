import Foundation
import LinxDisplayCore

/// 小米 OAuth 只接受 `homeassistant.local:8123` 下的回调地址。
/// 浏览器完成授权后，把地址栏里的完整回调 URL 粘贴回软件即可完成登录，
/// 不要求本机真的运行 Home Assistant。
enum XiaomiOAuthLogin {
    static let redirectURL = "http://homeassistant.local:8123/api/webhook/lingxi-xiaomi-oauth"

    static func authorizationURL(region: XiaomiCloudRegion, deviceID: String) -> URL? {
        XiaomiCloudClient.authorizationURL(region: region, redirectURL: redirectURL,
                                           deviceID: deviceID,
                                           state: UUID().uuidString)
    }

    static func complete(callback: String, region: XiaomiCloudRegion,
                         deviceID: String) async throws -> XiaomiAccount {
        let trimmed = callback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw XiaomiCloudError.server("没有在回调地址中找到 code。请粘贴浏览器地址栏中的完整地址。")
        }
        let client = XiaomiCloudClient()
        return try await client.exchangeCode(code, redirectURL: redirectURL,
                                             deviceID: deviceID, region: region)
    }
}
