import Foundation
import LinxDisplayCore

enum XiaomiOAuthLogin {
    static let redirectURL = "http://homeassistant.local:8123/api/webhook/lingxi-xiaomi-oauth"

    static func authorizationURL(region: XiaomiCloudRegion, deviceID: String) -> URL? {
        XiaomiCloudClient.authorizationURL(region: region, redirectURL: redirectURL,
                                           deviceID: deviceID, state: UUID().uuidString)
    }

    static func code(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        // 少数重定向会把参数放在 fragment 里。
        let fragment = components.fragment ?? ""
        return URLComponents(string: "?" + fragment)?
            .queryItems?.first(where: { $0.name == "code" })?.value
    }

    static func complete(code: String, region: XiaomiCloudRegion,
                         deviceID: String) async throws -> XiaomiAccount {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XiaomiCloudError.server("小米没有返回授权码。")
        }
        return try await XiaomiCloudClient().exchangeCode(code, redirectURL: redirectURL,
                                                          deviceID: deviceID, region: region)
    }
}
