import Foundation
import LinxDisplayCore

enum XiaomiOAuthLogin {
    static let redirectURL = "http://homeassistant.local:8123/api/webhook/lingxi-xiaomi-oauth"

    static func authorizationURL(region: XiaomiCloudRegion, deviceID: String) -> URL? {
        XiaomiCloudClient.authorizationURL(region: region, redirectURL: redirectURL,
                                           deviceID: deviceID, state: UUID().uuidString)
    }

    static func code(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
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
