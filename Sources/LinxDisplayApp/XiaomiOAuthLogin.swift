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

    static func code(from callbackURL: URL) -> String? {
        URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
    }

    static func complete(code: String, region: XiaomiCloudRegion,
                         deviceID: String) async throws -> XiaomiAccount {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XiaomiCloudError.server("小米没有返回授权码。")
        }
        let client = XiaomiCloudClient()
        return try await client.exchangeCode(code, redirectURL: redirectURL,
                                             deviceID: deviceID, region: region)
    }

    static func complete(callback: String, region: XiaomiCloudRegion,
                         deviceID: String) async throws -> XiaomiAccount {
        let trimmed = callback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let code = code(from: url) else {
            throw XiaomiCloudError.server("没有在回调地址中找到 code。")
        }
        return try await complete(code: code, region: region, deviceID: deviceID)
    }
}
