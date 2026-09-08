import Foundation

/// Formlabs Dashboard API 的持久化配置。
public struct FormlabsConnectionSettings: Codable, Equatable {
    public var printerSerial: String
    public var clientID: String
    public var clientSecret: String
    public var showThumbnail: Bool
    public var showLayers: Bool
    public var showMaterial: Bool
    /// 独立卡片强调色：true 使用 Formlabs 品牌蓝，false 跟随全局主题。
    public var useBrandAccent: Bool

    public init(printerSerial: String = "",
                clientID: String = "", clientSecret: String = "",
                showThumbnail: Bool = true, showLayers: Bool = true,
                showMaterial: Bool = true, useBrandAccent: Bool = true) {
        self.printerSerial = printerSerial
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.showThumbnail = showThumbnail
        self.showLayers = showLayers
        self.showMaterial = showMaterial
        self.useBrandAccent = useBrandAccent
    }

    private enum CodingKeys: String, CodingKey {
        case printerSerial, clientID, clientSecret, showThumbnail, showLayers, showMaterial,
             useBrandAccent
    }

    /// 旧版配置没有强调色开关；回退为旧版始终使用的品牌蓝。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printerSerial = try c.decodeIfPresent(String.self, forKey: .printerSerial) ?? ""
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        showThumbnail = try c.decodeIfPresent(Bool.self, forKey: .showThumbnail) ?? true
        showLayers = try c.decodeIfPresent(Bool.self, forKey: .showLayers) ?? true
        showMaterial = try c.decodeIfPresent(Bool.self, forKey: .showMaterial) ?? true
        useBrandAccent = try c.decodeIfPresent(Bool.self, forKey: .useBrandAccent) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(printerSerial, forKey: .printerSerial)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(clientSecret, forKey: .clientSecret)
        try c.encode(showThumbnail, forKey: .showThumbnail)
        try c.encode(showLayers, forKey: .showLayers)
        try c.encode(showMaterial, forKey: .showMaterial)
        try c.encode(useBrandAccent, forKey: .useBrandAccent)
    }
}

public struct FormlabsDeviceInfo: Codable, Equatable, Identifiable {
    public var id: String
    public var productName: String
    public var status: String
    public var isConnected: Bool
    public var connectionType: String
    public var ipAddress: String
    public var firmwareVersion: String
    public var readyToPrintNow: Bool?
    public var estimatedPrintTimeRemainingMS: Double?

    public init(id: String, productName: String = "Formlabs 打印机", status: String = "unknown",
                isConnected: Bool = false, connectionType: String = "", ipAddress: String = "",
                firmwareVersion: String = "", readyToPrintNow: Bool? = nil,
                estimatedPrintTimeRemainingMS: Double? = nil) {
        self.id = id
        self.productName = productName
        self.status = status
        self.isConnected = isConnected
        self.connectionType = connectionType
        self.ipAddress = ipAddress
        self.firmwareVersion = firmwareVersion
        self.readyToPrintNow = readyToPrintNow
        self.estimatedPrintTimeRemainingMS = estimatedPrintTimeRemainingMS
    }
}

public struct FormlabsPrintInfo: Codable, Equatable {
    public var name: String
    public var status: String
    public var currentLayer: Int?
    public var layerCount: Int?
    public var elapsedDurationMS: Double?
    public var estimatedDurationMS: Double?
    public var estimatedTimeRemainingMS: Double?
    public var materialName: String
    public var layerThicknessMM: Double?
    public var message: String
    public var thumbnailURL: String

    public init(name: String = "", status: String = "", currentLayer: Int? = nil,
                layerCount: Int? = nil, elapsedDurationMS: Double? = nil,
                estimatedDurationMS: Double? = nil, estimatedTimeRemainingMS: Double? = nil,
                materialName: String = "", layerThicknessMM: Double? = nil,
                message: String = "", thumbnailURL: String = "") {
        self.name = name
        self.status = status
        self.currentLayer = currentLayer
        self.layerCount = layerCount
        self.elapsedDurationMS = elapsedDurationMS
        self.estimatedDurationMS = estimatedDurationMS
        self.estimatedTimeRemainingMS = estimatedTimeRemainingMS
        self.materialName = materialName
        self.layerThicknessMM = layerThicknessMM
        self.message = message
        self.thumbnailURL = thumbnailURL
    }

    public var progress: Double? {
        if let currentLayer, let layerCount, layerCount > 0 {
            return min(max(Double(currentLayer) / Double(layerCount), 0), 1)
        }
        if let elapsedDurationMS, let estimatedDurationMS, estimatedDurationMS > 0 {
            return min(max(elapsedDurationMS / estimatedDurationMS, 0), 1)
        }
        return nil
    }

    /// Formlabs 不同机型/固件可能把打印配置所用耗材放在不同字段中。
    /// 优先采用面向用户的材料名；任务未分配材料名时，打印配置名称通常比
    /// `RDGPCL06` 一类内部材料代码更适合直接展示；若配置也只是 `Default`，优先采用
    /// 打印机料盒/树脂槽报告的名称，最后才回退到原始任务材料代码。
    public static func configuredMaterialName(materialName: String?,
                                              material: String?,
                                              printSettingsName: String?,
                                              printerMaterial: String? = nil) -> String {
        for candidate in [materialName, printSettingsName, printerMaterial, material] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { continue }
            if !isUnavailableMaterialName(value) { return value }
        }
        return ""
    }

    /// Dashboard 会把尚未关联材料的任务/料斗也编码成普通字符串。它们只是占位值，
    /// 不能阻断后续 `material`、打印配置名或料斗材料的有效回退。
    public static func isUnavailableMaterialName(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if normalized.hasSuffix(" unspecified") || normalized.hasSuffix(" not supported") {
            return true
        }
        return [
            "", "—", "–", "unknown", "unknown material", "none", "null", "n/a",
            "not assigned", "not set", "not available", "unassigned", "default",
            "未分配", "未指定", "未设置", "未知", "暂无", "默认"
        ].contains(normalized)
    }
}

public struct FormlabsSnapshot: Codable, Equatable {
    public var device: FormlabsDeviceInfo?
    public var print: FormlabsPrintInfo?
    public var thumbnail: Data?
    public var sampledAt: Date?
    public var cloudError: String?

    public init(device: FormlabsDeviceInfo? = nil, print: FormlabsPrintInfo? = nil,
                thumbnail: Data? = nil, sampledAt: Date? = nil,
                cloudError: String? = nil) {
        self.device = device
        self.print = print
        self.thumbnail = thumbnail
        self.sampledAt = sampledAt
        self.cloudError = cloudError
    }

    public static let empty = FormlabsSnapshot()
    public var hasData: Bool { device != nil || print != nil }
}

/// Formlabs Dashboard 在任务结束后可能立即把 `current_print_run` 置空。
/// 卡片只保留一份最近任务：空闲响应沿用它，新任务出现时立即整体替换。
public enum FormlabsTaskCachePolicy {
    public static func taskIdentity(_ print: FormlabsPrintInfo) -> String {
        let thumbnail = print.thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = print.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            // 材料字段可能在打印开始后才由 Dashboard 补齐，也可能短暂回落为“未分配”。
            // 它不是任务身份的一部分，否则同一任务会被误判为新任务并丢失缓存封面。
            return "\(name.lowercased())|\(print.layerCount ?? -1)|\(Int(print.estimatedDurationMS ?? -1))"
        }
        // 缩略图常是会更新签名参数的对象存储 URL；只用不含 query 的路径识别，
        // 避免同一任务每次刷新都被误判成新任务。
        if let components = URLComponents(string: thumbnail) {
            return "\(components.host?.lowercased() ?? "")\(components.path.lowercased())"
        }
        return thumbnail.lowercased()
    }

    public static func isSameTask(_ lhs: FormlabsPrintInfo?, _ rhs: FormlabsPrintInfo?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let left = taskIdentity(lhs)
        let right = taskIdentity(rhs)
        return !left.isEmpty && left == right
    }

    /// 云端不再返回当前任务时，把最后一次活动快照固化为已完成；失败、取消等
    /// 已经明确终止的状态保持原义，不误改为成功完成。
    public static func retainedPrint(previous: FormlabsPrintInfo?,
                                     latest: FormlabsPrintInfo?) -> FormlabsPrintInfo? {
        if var latest {
            // 同一任务的新响应缺少有效耗材时，保留最近一次已确认的材料名称；
            // “未分配”等占位字符串不会污染后续显示。
            if let previous, isSameTask(previous, latest),
               FormlabsPrintInfo.isUnavailableMaterialName(latest.materialName) {
                let previousMaterial = FormlabsPrintInfo.configuredMaterialName(
                    materialName: previous.materialName, material: nil,
                    printSettingsName: nil)
                if !previousMaterial.isEmpty { latest.materialName = previousMaterial }
            }
            return latest
        }
        guard var cached = previous else { return nil }
        let terminal = cached.status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "-", with: "_")
        let successful = ["finished", "completed", "complete"].contains(terminal)
        let keepStatus = successful || ["failed", "error", "cancelled", "canceled", "aborted"]
            .contains(terminal)
        if !keepStatus { cached.status = "finished" }
        if successful || !keepStatus {
            if let total = cached.layerCount, total > 0 { cached.currentLayer = total }
            if let estimated = cached.estimatedDurationMS, estimated > 0 {
                cached.elapsedDurationMS = estimated
            }
        }
        cached.estimatedTimeRemainingMS = 0
        return cached
    }
}

/// 画板渲染所需的单台 Formlabs 数据。按已启用设备顺序映射到五个画板模块位。
public struct FormlabsCanvasItem: Equatable {
    public var deviceName: String
    public var connection: FormlabsConnectionSettings
    public var snapshot: FormlabsSnapshot

    public init(deviceName: String, connection: FormlabsConnectionSettings,
                snapshot: FormlabsSnapshot) {
        self.deviceName = deviceName
        self.connection = connection
        self.snapshot = snapshot
    }
}

public enum FormlabsError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case missingCloudCredentials
    case printerNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Formlabs 返回了无法识别的数据"
        case .http(let code, let detail): return "Formlabs 请求失败（HTTP \(code)）\(detail.isEmpty ? "" : "：\(detail)")"
        case .missingCloudCredentials: return "尚未填写 Dashboard API 的 Client ID 和 Client Secret"
        case .printerNotFound: return "Dashboard API 中没有找到对应序列号的打印机"
        }
    }

}

/// Formlabs API 客户端。actor 内缓存 OAuth token，Client Secret 与 token 都不会写入日志。
public actor FormlabsClient {
    private struct OAuthToken {
        var value: String
        var expiresAt: Date
    }

    private let session: URLSession
    private var tokens: [String: OAuthToken] = [:]
    private let cloudBaseURL = URL(string: "https://api.formlabs.com")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 使用 Dashboard API 列出当前账号可访问的打印机，供设备管理选择序列号。
    public func cloudPrinters(clientID: String, clientSecret: String) async throws -> [FormlabsDeviceInfo] {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { throw FormlabsError.missingCloudCredentials }
        let token = try await accessToken(clientID: id, clientSecret: secret)
        let url = cloudBaseURL.appendingPathComponent("developer/v1/printers/")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        let payload = try await data(for: request)
        let root = try jsonObject(payload)
        return objectArray(root, preferredKeys: ["printers", "results", "data", "items"])
            .compactMap { Self.parseCloudDevice($0) }
    }

    public func refresh(settings: FormlabsConnectionSettings,
                        previous: FormlabsSnapshot = .empty) async -> FormlabsSnapshot {
        var result = previous
        result.sampledAt = Date()

        do {
            let cloud = try await cloudPrinter(settings: settings)
            result.device = cloud.device
            let previousPrint = previous.print
            let sameTask = FormlabsTaskCachePolicy.isSameTask(previousPrint, cloud.print)
            result.print = FormlabsTaskCachePolicy.retainedPrint(previous: previousPrint,
                                                                 latest: cloud.print)
            result.cloudError = nil
            // 新任务先丢弃上一任务封面；同一任务下载失败则沿用最近有效缩略图。
            if cloud.print != nil, !sameTask { result.thumbnail = nil }
            if settings.showThumbnail, let current = cloud.print,
               let request = thumbnailRequest(urlString: current.thumbnailURL,
                                              token: cloud.token) {
                // 缩略图是附加内容：下载短暂失败时保留上一张有效图片，不能把已经成功
                // 获取的打印机状态一并标记为云端连接异常。
                if let data = try? await data(for: request), !data.isEmpty {
                    result.thumbnail = data
                }
            }
        } catch {
            result.cloudError = error.localizedDescription
        }
        return result
    }

    public func testCloud(settings: FormlabsConnectionSettings) async throws -> FormlabsPrintInfo? {
        try await cloudPrinter(settings: settings).print
    }

    private func cloudPrinter(settings: FormlabsConnectionSettings) async throws
        -> (device: FormlabsDeviceInfo, print: FormlabsPrintInfo?, token: String) {
        let clientID = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = settings.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !secret.isEmpty else { throw FormlabsError.missingCloudCredentials }
        let serial = settings.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty else { throw FormlabsError.printerNotFound }
        let token = try await accessToken(clientID: clientID, clientSecret: secret)
        let encoded = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial
        let url = cloudBaseURL.appendingPathComponent("developer/v1/printers/\(encoded)/")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        let data = try await data(for: request)
        guard let root = try jsonObject(data) as? [String: Any] else { throw FormlabsError.invalidResponse }
        let printer = root["printer"] as? [String: Any] ?? root
        let status = printer["printer_status"] as? [String: Any]
            ?? printer["status"] as? [String: Any]
            ?? printer
        let run = status["current_print_run"] as? [String: Any]
            ?? printer["current_print_run"] as? [String: Any]
        guard let device = Self.parseCloudDevice(printer, fallbackSerial: serial) else {
            throw FormlabsError.invalidResponse
        }
        let printerMaterial = Self.installedMaterialName(printer: printer,
                                                         status: status,
                                                         run: run)
        return (device,
                run.map { Self.parsePrint($0, printerMaterial: printerMaterial) },
                token)
    }

    /// 不同 Form / Fuse 设备分别通过料盒、树脂槽或料斗上报当前耗材。
    /// 优先匹配本次任务引用的料盒，再回退到其余已安装耗材；每个对象先取
    /// `display_name`，避免把内部材料代码直接展示给用户。
    private static func installedMaterialName(printer: [String: Any],
                                              status: [String: Any],
                                              run: [String: Any]?) -> String? {
        let referencedCartridges = [
            string(run?["cartridge"]),
            string(run?["front_cartridge"]),
            string(run?["back_cartridge"])
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cartridgeStatuses = printer["cartridge_status"] as? [[String: Any]] ?? []
        let cartridges = cartridgeStatuses.compactMap { entry -> [String: Any]? in
            entry["cartridge"] as? [String: Any] ?? entry
        }
        let orderedCartridges = cartridges.sorted { lhs, rhs in
            let leftMatches = string(lhs["serial"]).map(referencedCartridges.contains) ?? false
            let rightMatches = string(rhs["serial"]).map(referencedCartridges.contains) ?? false
            return leftMatches && !rightMatches
        }
        for cartridge in orderedCartridges {
            let candidate = FormlabsPrintInfo.configuredMaterialName(
                materialName: string(cartridge["display_name"]),
                material: string(cartridge["material"]),
                printSettingsName: nil,
                printerMaterial: string(cartridge["consumable_type"]))
            if !candidate.isEmpty { return candidate }
        }

        let tankStatus = printer["tank_status"] as? [String: Any]
        let tank = tankStatus?["tank"] as? [String: Any]
        let tankMaterial = FormlabsPrintInfo.configuredMaterialName(
            materialName: string(tank?["display_name"]),
            material: string(tank?["material"]),
            printSettingsName: nil,
            printerMaterial: string(tank?["tank_type"]))
        if !tankMaterial.isEmpty { return tankMaterial }

        return FormlabsPrintInfo.configuredMaterialName(
            materialName: string(status["hopper_material"]),
            material: nil, printSettingsName: nil)
    }

    /// Print API 返回的缩略图通常是带时效签名的对象存储 URL。给这种外部 URL
    /// 额外附加 OAuth Authorization 会让 S3/CloudFront 判定为两套认证并拒绝请求；
    /// 只有相对地址或 api.formlabs.com 自身的地址才使用 Dashboard Bearer token。
    private func thumbnailRequest(urlString: String, token: String) -> URLRequest? {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let url: URL?
        if raw.hasPrefix("//") {
            url = URL(string: "https:\(raw)")
        } else if let parsed = URL(string: raw), parsed.scheme != nil {
            url = parsed
        } else {
            url = URL(string: raw, relativeTo: cloudBaseURL)?.absoluteURL
        }
        guard let url else { return nil }
        var request = URLRequest(url: url)
        if url.host?.caseInsensitiveCompare(cloudBaseURL.host ?? "") == .orderedSame {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 12
        return request
    }

    private func accessToken(clientID: String, clientSecret: String) async throws -> String {
        let key = clientID + "\u{0}" + clientSecret
        if let cached = tokens[key], cached.expiresAt.timeIntervalSinceNow > 120 {
            return cached.value
        }
        let url = cloudBaseURL.appendingPathComponent("developer/v1/o/token/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = ["grant_type": "client_credentials", "client_id": clientID, "client_secret": clientSecret]
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .sorted().joined(separator: "&").data(using: .utf8)
        let data = try await data(for: request)
        guard let json = try jsonObject(data) as? [String: Any],
              let value = json["access_token"] as? String, !value.isEmpty else {
            throw FormlabsError.invalidResponse
        }
        let expires = Self.number(json["expires_in"]) ?? 86_400
        tokens[key] = OAuthToken(value: value, expiresAt: Date().addingTimeInterval(expires))
        return value
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FormlabsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw FormlabsError.http(http.statusCode, String(detail))
        }
        return data
    }

    private func jsonObject(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw FormlabsError.invalidResponse }
    }

    private func objectArray(_ root: Any, preferredKeys: [String]) -> [[String: Any]] {
        if let list = root as? [[String: Any]] { return list }
        guard let dict = root as? [String: Any] else { return [] }
        for key in preferredKeys {
            if let list = dict[key] as? [[String: Any]] { return list }
        }
        return []
    }

    private static func parseCloudDevice(_ object: [String: Any], fallbackSerial: String? = nil) -> FormlabsDeviceInfo? {
        guard let id = string(object["serial"])
                ?? string(object["printer_serial"])
                ?? string(object["serial_number"])
                ?? string(object["machine_id"])
                ?? string(object["id"])
                ?? fallbackSerial else { return nil }
        let statusObject = object["printer_status"] as? [String: Any]
            ?? object["status"] as? [String: Any]
        let rawStatus = string(statusObject?["status"])
            ?? string(statusObject?["state"])
            ?? string(object["status"])
            ?? "unknown"
        let run = statusObject?["current_print_run"] as? [String: Any]
            ?? object["current_print_run"] as? [String: Any]
        let online = bool(object["is_connected"])
            ?? !["offline", "disconnected", "unknown"].contains(rawStatus.lowercased())
        return FormlabsDeviceInfo(
            id: id,
            productName: string(object["name"])
                ?? string(object["printer_name"])
                ?? string(object["product_name"])
                ?? string(object["model"])
                ?? "Formlabs 打印机",
            status: rawStatus,
            isConnected: online,
            connectionType: "cloud",
            ipAddress: "",
            firmwareVersion: string(object["firmware_version"]) ?? "",
            readyToPrintNow: bool(object["ready_to_print_now"]),
            estimatedPrintTimeRemainingMS: number(run?["estimated_time_remaining_ms"])
                ?? number(object["estimated_print_time_remaining_ms"])
        )
    }

    private static func parsePrint(_ object: [String: Any],
                                   printerMaterial: String? = nil) -> FormlabsPrintInfo {
        let thumbnail = object["print_thumbnail"] as? [String: Any]
            ?? object["thumbnail"] as? [String: Any]
        let configuredMaterial = FormlabsPrintInfo.configuredMaterialName(
            materialName: string(object["material_name"]),
            material: string(object["material"]),
            printSettingsName: string(object["print_settings_name"]),
            printerMaterial: printerMaterial)
        return FormlabsPrintInfo(
            name: string(object["name"]) ?? string(object["print_name"]) ?? "",
            status: string(object["status"]) ?? "",
            currentLayer: integer(object["currently_printing_layer"]),
            layerCount: integer(object["layer_count"]),
            elapsedDurationMS: number(object["elapsed_duration_ms"]),
            estimatedDurationMS: number(object["estimated_duration_ms"]),
            estimatedTimeRemainingMS: number(object["estimated_time_remaining_ms"]),
            materialName: configuredMaterial,
            layerThicknessMM: number(object["layer_thickness_mm"]),
            message: string(object["message"]) ?? "",
            thumbnailURL: string(thumbnail?["thumbnail"]) ?? string(object["thumbnail_url"]) ?? ""
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() { case "true", "1", "yes": return true; case "false", "0", "no": return false; default: return nil }
        }
        return nil
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
