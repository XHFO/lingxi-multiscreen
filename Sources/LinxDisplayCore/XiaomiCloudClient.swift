import Foundation

/// 小米云区域。与 Xiaomi Home 官方集成使用同一组区域。
public enum XiaomiCloudRegion: String, CaseIterable, Codable, Identifiable, Sendable {
    case cn, de, i2, ru, sg, us

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cn: return "中国大陆"
        case .de: return "欧洲"
        case .i2: return "印度"
        case .ru: return "俄罗斯"
        case .sg: return "新加坡"
        case .us: return "美国"
        }
    }

    public var oauthHost: String {
        self == .cn ? "ha.api.io.mi.com" : "\(rawValue).ha.api.io.mi.com"
    }
}

public struct XiaomiAccount: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceID: String
    public var region: XiaomiCloudRegion
    public var expiresAt: Date
    public var userID: String?
    public var nickname: String?
    public var redirectURL: String?

    public init(accessToken: String, refreshToken: String, deviceID: String,
                region: XiaomiCloudRegion, expiresAt: Date,
                userID: String? = nil, nickname: String? = nil,
                redirectURL: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceID = deviceID
        self.region = region
        self.expiresAt = expiresAt
        self.userID = userID
        self.nickname = nickname
        self.redirectURL = redirectURL
    }

    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
}

public struct XiaomiDevice: Identifiable, Codable, Equatable, Sendable {
    public var did: String
    public var name: String
    public var model: String
    public var urn: String
    public var online: Bool
    public var roomName: String?
    public var homeName: String?
    public var icon: String?
    public var localIP: String?

    public var id: String { did }

    public init(did: String, name: String, model: String, urn: String, online: Bool,
                roomName: String? = nil, homeName: String? = nil,
                icon: String? = nil, localIP: String? = nil) {
        self.did = did
        self.name = name
        self.model = model
        self.urn = urn
        self.online = online
        self.roomName = roomName
        self.homeName = homeName
        self.icon = icon
        self.localIP = localIP
    }

    public var category: String {
        let parts = urn.split(separator: ":").map(String.init)
        if parts.count > 3 { return parts[3] }
        return model.split(separator: ".").first.map(String.init) ?? "device"
    }

    public var subtitle: String {
        [roomName, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum XiaomiCloudError: Error, LocalizedError, Equatable {
    case unauthorized
    case invalidURL
    case invalidResponse
    case server(String)
    case notLoggedIn
    case noDevices

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "小米登录已失效，请重新登录。"
        case .invalidURL: return "小米云地址无效。"
        case .invalidResponse: return "小米云返回了无法识别的数据。"
        case .server(let message): return message
        case .notLoggedIn: return "尚未登录小米账号。"
        case .noDevices: return "账号下没有可导入的小米设备。"
        }
    }
}

/// 账号令牌单独封装，不写入普通 settings.json。
public enum XiaomiAccountStore {
    private static let account = "account"
    private static let subdirectory = "Xiaomi"

    public static func load() -> XiaomiAccount? {
        let text = SealedCredentialStore.read(account: account, subdirectory: subdirectory)
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(XiaomiAccount.self, from: data)
    }

    @discardableResult
    public static func save(_ value: XiaomiAccount?) -> Bool {
        guard let value else {
            return SealedCredentialStore.save("", account: account, subdirectory: subdirectory)
        }
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return false }
        return SealedCredentialStore.save(text, account: account, subdirectory: subdirectory)
    }
}

/// 小米云 OAuth + 设备列表客户端。设备属性/控制将在规格映射完成后接入。
public final class XiaomiCloudClient {
    public static let clientID = "2882303761520251711"
    public static let authEndpoint = URL(string: "https://account.xiaomi.com/oauth2/authorize")!

    private let session: URLSession

    public init(session: URLSession = EphemeralJSONSession.make()) {
        self.session = session
    }

    public static func authorizationURL(region: XiaomiCloudRegion, redirectURL: String,
                                        deviceID: String, state: String) -> URL? {
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURL),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "skip_confirm", value: "true")
        ]
        return components?.url
    }

    public func exchangeCode(_ code: String, redirectURL: String,
                             deviceID: String, region: XiaomiCloudRegion) async throws -> XiaomiAccount {
        let payload: [String: Any] = [
            "client_id": Self.clientID,
            "redirect_uri": redirectURL,
            "code": code,
            "device_id": deviceID
        ]
        let token = try await requestToken(payload, region: region)
        return XiaomiAccount(accessToken: token.accessToken, refreshToken: token.refreshToken,
                             deviceID: deviceID, region: region, expiresAt: token.expiresAt,
                             redirectURL: redirectURL)
    }

    public func refresh(_ account: XiaomiAccount) async throws -> XiaomiAccount {
        let payload: [String: Any] = [
            "client_id": Self.clientID,
            "redirect_uri": account.redirectURL ?? "http://127.0.0.1/",
            "refresh_token": account.refreshToken
        ]
        let token = try await requestToken(payload, region: account.region)
        var updated = account
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken
        updated.expiresAt = token.expiresAt
        return updated
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private func requestToken(_ payload: [String: Any], region: XiaomiCloudRegion) async throws -> TokenResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              var components = URLComponents(string: "https://\(region.oauthHost)/app/v2/ha/oauth/get_token") else {
            throw XiaomiCloudError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "data", value: text)]
        guard let url = components.url else { throw XiaomiCloudError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("LingxiMultiScreen/2.0", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw XiaomiCloudError.unauthorized }
        guard (200...299).contains(status) else {
            throw XiaomiCloudError.server("小米登录接口返回 HTTP \(status)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (root["code"] as? Int) == 0,
              let result = root["result"] as? [String: Any],
              let access = result["access_token"] as? String,
              let refresh = result["refresh_token"] as? String else {
            throw XiaomiCloudError.invalidResponse
        }
        let expiresIn = (result["expires_in"] as? Double) ?? 7200
        return TokenResponse(accessToken: access, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(expiresIn * 0.7))
    }

    public func fetchDevices(account: XiaomiAccount) async throws -> [XiaomiDevice] {
        var all: [XiaomiDevice] = []
        var startDID: String?
        repeat {
            var payload: [String: Any] = [
                "limit": 200,
                "get_split_device": true,
                "get_third_device": true,
                "dids": []
            ]
            if let startDID { payload["start_did"] = startDID }
            let result = try await post(path: "/app/v2/home/device_list_page",
                                        payload: payload, account: account)
            guard let page = result["result"] as? [String: Any] else { break }
            for raw in page["list"] as? [[String: Any]] ?? [] {
                guard let did = raw["did"] as? String,
                      let name = raw["name"] as? String,
                      let urn = raw["spec_type"] as? String,
                      let model = raw["model"] as? String else { continue }
                all.append(XiaomiDevice(did: did, name: name, model: model, urn: urn,
                                        online: (raw["isOnline"] as? Bool) ?? false,
                                        icon: raw["icon"] as? String,
                                        localIP: raw["local_ip"] as? String))
            }
            startDID = page["has_more"] as? Bool == true ? page["next_start_did"] as? String : nil
        } while startDID != nil
        guard !all.isEmpty else { throw XiaomiCloudError.noDevices }
        return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func post(path: String, payload: [String: Any],
                      account: XiaomiAccount) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://\(account.region.oauthHost)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("haapi", forHTTPHeaderField: "X-Client-BizId")
        request.setValue(Self.clientID, forHTTPHeaderField: "X-Client-AppId")
        request.setValue("LingxiMultiScreen/2.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw XiaomiCloudError.unauthorized }
        guard (200...299).contains(status) else {
            throw XiaomiCloudError.server("小米云返回 HTTP \(status)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XiaomiCloudError.invalidResponse
        }
        if let code = root["code"] as? Int, code != 0 {
            throw XiaomiCloudError.server("小米云错误码 \(code)")
        }
        return root
    }
}
