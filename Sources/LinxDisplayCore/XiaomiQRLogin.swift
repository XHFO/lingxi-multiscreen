import Foundation

public struct XiaomiQRLoginSession: Sendable {
    public var qrImageURL: URL
    public var pollURL: URL
    public var expiresAt: Date
}

public enum XiaomiQRError: Error, LocalizedError {
    case invalidResponse
    case expired
    case consentRequired

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "小米扫码登录返回了无法识别的数据。"
        case .expired: return "二维码已过期，请重新获取。"
        case .consentRequired: return "扫码成功，但小米仍要求确认授权，请改用网页登录。"
        }
    }
}

/// 小米扫码登录。二维码接口返回一张 PNG，轮询接口在扫码确认后返回跳转地址。
/// 登录 Cookie 会保留在该客户端自己的 Cookie 存储中，用于随后自动完成 OAuth 授权。
public final class XiaomiQRLoginClient {
    private let cookieStorage = HTTPCookieStorage.shared
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 50
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func start() async throws -> XiaomiQRLoginSession {
        guard let url = URL(string: "https://account.xiaomi.com/longPolling/loginUrl?sid=xiaomiio&_json=true") else {
            throw XiaomiQRError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let text = String(data: data, encoding: .utf8) ?? ""
        let jsonText = text.hasPrefix("&&&START&&&") ? String(text.dropFirst("&&&START&&&".count)) : text
        guard let root = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let qr = root["qr"] as? String, let qrURL = URL(string: qr),
              let lp = root["lp"] as? String, let pollURL = URL(string: lp) else {
            throw XiaomiQRError.invalidResponse
        }
        let timeout = (root["timeout"] as? Double) ?? 300
        return XiaomiQRLoginSession(qrImageURL: qrURL, pollURL: pollURL,
                                    expiresAt: Date().addingTimeInterval(timeout))
    }

    /// 二维码未确认时返回 nil；扫码确认后返回服务端跳转地址。
    public func poll(_ sessionInfo: XiaomiQRLoginSession) async throws -> URL? {
        if Date() > sessionInfo.expiresAt { throw XiaomiQRError.expired }
        let catcher = RedirectCatcher()
        let pollSession = URLSession(configuration: session.configuration, delegate: catcher, delegateQueue: nil)
        var request = URLRequest(url: sessionInfo.pollURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await pollSession.data(for: request)
        pollSession.invalidateAndCancel()
        if let location = catcher.location {
            _ = try? await session.data(from: location)
            return location
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let jsonText = text.hasPrefix("&&&START&&&") ? String(text.dropFirst("&&&START&&&".count)) : text
        if let root = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any] {
            if let location = root["location"] as? String, let url = URL(string: location) {
                _ = try? await session.data(from: url)
                return url
            }
            if let code = root["code"] as? Int, code != 0, let desc = root["desc"] as? String {
                throw XiaomiQRError.invalidResponse
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw XiaomiQRError.invalidResponse }
        return nil
    }

    /// 使用扫码得到的登录 Cookie 自动走 OAuth，并截取回调 code。
    public func oauthCode(authURL: URL, redirectURL: String) async throws -> String {
        let catcher = RedirectCatcher()
        let oauthSession = URLSession(configuration: session.configuration, delegate: catcher, delegateQueue: nil)
        var request = URLRequest(url: authURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await oauthSession.data(for: request)
        oauthSession.invalidateAndCancel()
        if let location = catcher.location,
           let components = URLComponents(url: location, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }
        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("确认授权") || text.contains("授权登录") { throw XiaomiQRError.consentRequired }
        }
        throw XiaomiQRError.consentRequired
    }
}

private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    var location: URL?
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        location = request.url
        completionHandler(nil)
    }
}
