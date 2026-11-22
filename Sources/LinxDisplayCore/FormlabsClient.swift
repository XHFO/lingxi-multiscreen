import Foundation

public enum FormlabsDataSource: String, Codable, CaseIterable {
    case developerAPI
    case dashboard
}

/// Formlabs Dashboard API 的持久化配置。
public struct FormlabsConnectionSettings: Codable, Equatable {
    public var dataSource: FormlabsDataSource
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
                showMaterial: Bool = true, useBrandAccent: Bool = true,
                dataSource: FormlabsDataSource = .developerAPI) {
        self.dataSource = dataSource
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
             useBrandAccent, dataSource
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
        dataSource = try c.decodeIfPresent(FormlabsDataSource.self, forKey: .dataSource) ?? .developerAPI
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
        try c.encode(dataSource, forKey: .dataSource)
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
    public var lastPingedAt: Date?
    public var lastModified: Date?

    public init(id: String, productName: String = "Formlabs 打印机", status: String = "unknown",
                isConnected: Bool = false, connectionType: String = "", ipAddress: String = "",
                firmwareVersion: String = "", readyToPrintNow: Bool? = nil,
                estimatedPrintTimeRemainingMS: Double? = nil,
                lastPingedAt: Date? = nil, lastModified: Date? = nil) {
        self.id = id
        self.productName = productName
        self.status = status
        self.isConnected = isConnected
        self.connectionType = connectionType
        self.ipAddress = ipAddress
        self.firmwareVersion = firmwareVersion
        self.readyToPrintNow = readyToPrintNow
        self.estimatedPrintTimeRemainingMS = estimatedPrintTimeRemainingMS
        self.lastPingedAt = lastPingedAt
        self.lastModified = lastModified
    }

    /// 缺少连接字段时，UNKNOWN 不能作为在线证据。未收录但有意义的新状态仍保守展示。
    /// API 明确返回的布尔值始终优先。
    public static func resolvedIsConnected(explicit: Bool?, status: String) -> Bool {
        if let explicit { return explicit }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return !["", "unknown", "off", "offline", "disconnected", "unavailable"].contains(normalized)
    }
}

public struct FormlabsPrintInfo: Codable, Equatable {
    /// Dashboard 当前 print run 的稳定标识。旧缓存或部分机型可能没有此字段；此时
    /// 身份策略会使用名称/缩略图作保守回退，而不会把“无法确认”误当成新任务。
    public var runID: String?
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

    public init(runID: String? = nil, name: String = "", status: String = "", currentLayer: Int? = nil,
                layerCount: Int? = nil, elapsedDurationMS: Double? = nil,
                estimatedDurationMS: Double? = nil, estimatedTimeRemainingMS: Double? = nil,
                materialName: String = "", layerThicknessMM: Double? = nil,
                message: String = "", thumbnailURL: String = "") {
        self.runID = runID
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
    /// 成功收到 HTTP 响应并不代表设备数据新鲜；与网络/授权错误分别保存。
    public var dataIssue: String?
    /// nil 兼容旧缓存；false 表示任务内容只是保留的最近任务。
    public var hasCurrentPrint: Bool?
    /// App 在一次可信的活动→成功完成转换中写入的绝对时间。持久化该原始时间，
    /// 重启后只恢复剩余宽限，不会因重复刷新或加载 finished 缓存重新计时。
    public var completionObservedAt: Date?

    public init(device: FormlabsDeviceInfo? = nil, print: FormlabsPrintInfo? = nil,
                thumbnail: Data? = nil, sampledAt: Date? = nil,
                cloudError: String? = nil, completionObservedAt: Date? = nil,
                dataIssue: String? = nil, hasCurrentPrint: Bool? = nil) {
        self.device = device
        self.print = print
        self.thumbnail = thumbnail
        self.sampledAt = sampledAt
        self.cloudError = cloudError
        self.completionObservedAt = completionObservedAt
        self.dataIssue = dataIssue
        self.hasCurrentPrint = hasCurrentPrint
    }

    public static let empty = FormlabsSnapshot()
    public var hasData: Bool { device != nil || print != nil }
    public var isRealtimeAvailable: Bool {
        cloudError == nil && dataIssue == nil && device?.isConnected == true
    }

    /// 当前设备状态和错误优先于历史任务，避免离线/失败被缓存的成功状态覆盖。
    public var displayStatus: String {
        let deviceStatus = device?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["offline", "off", "disconnected", "unavailable"].contains(deviceStatus) { return "offline" }
        if cloudError != nil || dataIssue != nil { return "data_unavailable" }
        if device?.isConnected == false { return "offline" }
        if ["failed", "error", "cancelled", "canceled", "aborted"].contains(deviceStatus) { return deviceStatus }
        if hasCurrentPrint == false {
            if ["idle", "ready"].contains(deviceStatus),
               let status = print?.status.lowercased(),
               ["finished", "completed", "complete", "failed", "error", "cancelled", "canceled", "aborted"].contains(status) {
                return status
            }
            return deviceStatus.isEmpty ? "unknown" : deviceStatus
        }
        if let status = print?.status, !status.isEmpty { return status }
        return deviceStatus.isEmpty ? "unknown" : deviceStatus
    }
}

/// Formlabs Dashboard 在任务结束后可能立即把 `current_print_run` 置空。
/// 卡片只保留一份最近任务：空闲响应沿用它，新任务出现时立即整体替换。
public enum FormlabsTaskCachePolicy {
    private static func normalizedRunID(_ print: FormlabsPrintInfo) -> String {
        print.runID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func normalizedName(_ print: FormlabsPrintInfo) -> String {
        print.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedThumbnailPath(_ print: FormlabsPrintInfo) -> String {
        let thumbnail = print.thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thumbnail.isEmpty else { return "" }
        if let components = URLComponents(string: thumbnail) {
            let value = "\(components.host?.lowercased() ?? "")\(components.path.lowercased())"
            if !value.isEmpty { return value }
        }
        return thumbnail.lowercased()
    }

    public static func taskIdentity(_ print: FormlabsPrintInfo) -> String {
        let runID = normalizedRunID(print)
        if !runID.isEmpty { return "run:\(runID)" }
        let name = normalizedName(print)
        if !name.isEmpty { return "name:\(name)" }
        // 缩略图常是会更新签名参数的对象存储 URL；只用不含 query 的路径识别，
        // 避免同一任务每次刷新都被误判成新任务。
        let thumbnail = normalizedThumbnailPath(print)
        return thumbnail.isEmpty ? "" : "thumbnail:\(thumbnail)"
    }

    public static func isSameTask(_ lhs: FormlabsPrintInfo?, _ rhs: FormlabsPrintInfo?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let leftRunID = normalizedRunID(lhs)
        let rightRunID = normalizedRunID(rhs)
        if !leftRunID.isEmpty, !rightRunID.isEmpty { return leftRunID == rightRunID }
        let leftName = normalizedName(lhs)
        let rightName = normalizedName(rhs)
        if !leftName.isEmpty, !rightName.isEmpty { return leftName == rightName }
        let leftThumbnail = normalizedThumbnailPath(lhs)
        let rightThumbnail = normalizedThumbnailPath(rhs)
        return !leftThumbnail.isEmpty && leftThumbnail == rightThumbnail
    }

    /// 只有双方都有可比较的稳定证据且证据不同时，才确认这是新任务。
    /// 无名称/无缩略图、或某一轮元数据尚未补齐，都属于“未知”，不能据此清除
    /// 正在进行的完成宽限计时。
    public static func isDefinitelyDifferentTask(
        _ lhs: FormlabsPrintInfo?, _ rhs: FormlabsPrintInfo?
    ) -> Bool {
        guard let lhs, let rhs else { return (lhs == nil) != (rhs == nil) }
        let leftRunID = normalizedRunID(lhs)
        let rightRunID = normalizedRunID(rhs)
        if !leftRunID.isEmpty, !rightRunID.isEmpty { return leftRunID != rightRunID }
        let leftName = normalizedName(lhs)
        let rightName = normalizedName(rhs)
        if !leftName.isEmpty, !rightName.isEmpty { return leftName != rightName }
        let leftThumbnail = normalizedThumbnailPath(lhs)
        let rightThumbnail = normalizedThumbnailPath(rhs)
        return !leftThumbnail.isEmpty && !rightThumbnail.isEmpty
            && leftThumbnail != rightThumbnail
    }

    /// 任务消失只表示缺少当前任务；只有明确的成功终态才能补齐到 100%。
    public static func retainedPrint(previous: FormlabsPrintInfo?,
                                     latest: FormlabsPrintInfo?,
                                     deviceStatus: String? = nil) -> FormlabsPrintInfo? {
        let reported = deviceStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "-", with: "_") ?? ""
        let failureStates = ["failed", "error", "cancelled", "canceled", "aborted"]
        if var latest {
            // Device failures can arrive before the nested run catches up.
            if failureStates.contains(reported) {
                latest.status = reported
                latest.estimatedTimeRemainingMS = 0
            }
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
        let terminalStates = ["finished", "completed", "complete", "failed", "error", "cancelled", "canceled", "aborted"]
        if terminalStates.contains(reported) { cached.status = reported }
        let terminal = cached.status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "-", with: "_")
        let successful = ["finished", "completed", "complete"].contains(terminal)
        if successful {
            if let total = cached.layerCount, total > 0 { cached.currentLayer = total }
            if let estimated = cached.estimatedDurationMS, estimated > 0 {
                cached.elapsedDurationMS = estimated
            }
        }
        if terminalStates.contains(terminal) { cached.estimatedTimeRemainingMS = 0 }
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
    case unavailableData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Formlabs 返回了无法识别的数据"
        case .http(let code, let detail): return "Formlabs 请求失败（HTTP \(code)）\(detail.isEmpty ? "" : "：\(detail)")"
        case .missingCloudCredentials: return "尚未填写 Dashboard API 的 Client ID 和 Client Secret"
        case .printerNotFound: return "Dashboard API 中没有找到对应序列号的打印机"
        case .unavailableData(let reason): return reason
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
    private let now: () -> Date
    private var tokens: [String: OAuthToken] = [:]
    private let cloudBaseURL = URL(string: "https://api.formlabs.com")!

    public init(session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    /// 使用 Dashboard API 列出当前账号可访问的打印机，供设备管理选择序列号。
    public func cloudPrinters(clientID: String, clientSecret: String) async throws -> [FormlabsDeviceInfo] {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { throw FormlabsError.missingCloudCredentials }
        let url = cloudBaseURL.appendingPathComponent("developer/v1/printers/")
        let (payload, _) = try await authorizedData(url: url, clientID: id, clientSecret: secret)
        let root = try jsonObject(payload)
        return objectArray(root, preferredKeys: ["printers", "results", "data", "items"])
            .compactMap { Self.parseCloudDevice($0) }
    }

    public func refresh(settings: FormlabsConnectionSettings,
                        previous: FormlabsSnapshot = .empty) async -> FormlabsSnapshot {
        var result = previous
        do {
            let cloud = try await cloudPrinter(settings: settings)
            result = await snapshot(from: cloud, settings: settings, previous: previous)
        } catch {
            result.cloudError = error.localizedDescription
        }
        return result
    }

    public func testCloud(settings: FormlabsConnectionSettings) async throws -> FormlabsPrintInfo? {
        let reading = try await cloudPrinter(settings: settings)
        if let issue = reading.dataIssue { throw FormlabsError.unavailableData(issue) }
        return reading.print
    }

    /// Payload is observed inside the user's explicitly connected official Dashboard WebView.
    /// This client never imports browser cookies or attempts to use developer tokens on private endpoints.
    public func refreshDashboard(settings: FormlabsConnectionSettings,
                                 previous: FormlabsSnapshot = .empty,
                                 payload: Data) async -> FormlabsSnapshot {
        var result = previous
        do {
            let root = try jsonObject(payload)
            let serial = settings.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serial.isEmpty else { throw FormlabsError.printerNotFound }
            let printer: [String: Any]
            if let array = root as? [[String: Any]] {
                guard let match = array.first(where: { Self.serial($0)?.caseInsensitiveCompare(serial) == .orderedSame }) else {
                    throw FormlabsError.printerNotFound
                }
                printer = match
            } else if let object = root as? [String: Any] {
                printer = object["printer"] as? [String: Any] ?? object
            } else { throw FormlabsError.invalidResponse }
            var reading = try parseReading(printer, expectedSerial: serial, token: "")
            reading.device.connectionType = "dashboard"
            result = await snapshot(from: reading, settings: settings, previous: previous)
        } catch {
            result.cloudError = error.localizedDescription
        }
        return result
    }

    private struct Reading {
        var device: FormlabsDeviceInfo
        var print: FormlabsPrintInfo?
        var token: String
        var dataIssue: String?
    }

    private func snapshot(from reading: Reading, settings: FormlabsConnectionSettings,
                          previous: FormlabsSnapshot) async -> FormlabsSnapshot {
        var result = previous
        result.device = reading.device
        result.cloudError = nil
        result.dataIssue = reading.dataIssue
        result.hasCurrentPrint = reading.print != nil
        // An old heartbeat or unavailable state must not overwrite the last trustworthy task,
        // renew its sample time, or create a completion event.
        guard reading.dataIssue == nil, reading.device.isConnected else { return result }
        result.print = FormlabsTaskCachePolicy.retainedPrint(
            previous: previous.print, latest: reading.print, deviceStatus: reading.device.status)
        if reading.device.isConnected { result.sampledAt = now() }
        if reading.print != nil,
           FormlabsTaskCachePolicy.isDefinitelyDifferentTask(previous.print, reading.print) {
            result.thumbnail = nil
            result.completionObservedAt = nil
        }
        if settings.showThumbnail, let current = reading.print,
           let request = thumbnailRequest(urlString: current.thumbnailURL, token: reading.token),
           let bytes = try? await data(for: request), !bytes.isEmpty {
            result.thumbnail = bytes
        }
        return result
    }

    private func cloudPrinter(settings: FormlabsConnectionSettings) async throws
        -> Reading {
        let clientID = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = settings.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !secret.isEmpty else { throw FormlabsError.missingCloudCredentials }
        let serial = settings.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty else { throw FormlabsError.printerNotFound }
        let url = cloudBaseURL.appendingPathComponent("developer/v1/printers")
            .appendingPathComponent(serial).appendingPathComponent("")
        let (data, token) = try await authorizedData(url: url, clientID: clientID, clientSecret: secret)
        guard let root = try jsonObject(data) as? [String: Any] else { throw FormlabsError.invalidResponse }
        let printer = root["printer"] as? [String: Any] ?? root
        return try parseReading(printer, expectedSerial: serial, token: token)
    }

    private func parseReading(_ printer: [String: Any], expectedSerial: String, token: String) throws -> Reading {
        guard let actualSerial = Self.serial(printer),
              actualSerial.caseInsensitiveCompare(expectedSerial) == .orderedSame else {
            throw FormlabsError.invalidResponse
        }
        let status = printer["printer_status"] as? [String: Any]
            ?? printer["status"] as? [String: Any]
            ?? printer
        guard Self.string(status["status"]) != nil || Self.string(status["state"]) != nil
                || status["current_print_run"] is [String: Any]
                || printer["current_print_run"] is [String: Any] else { throw FormlabsError.invalidResponse }
        let run = status["current_print_run"] as? [String: Any]
            ?? printer["current_print_run"] as? [String: Any]
        guard var device = Self.parseCloudDevice(printer) else {
            throw FormlabsError.invalidResponse
        }
        let printerMaterial = Self.installedMaterialName(printer: printer,
                                                         status: status,
                                                         run: run)
        let print = run.map { Self.parsePrint($0, printerMaterial: printerMaterial) }
        if printer["is_connected"] == nil, let status = print?.status,
           !["", "unknown"].contains(status.lowercased()), device.status.lowercased() == "unknown" {
            device.isConnected = true
        }
        let issue: String?
        if let heartbeat = device.lastPingedAt,
           now().timeIntervalSince(heartbeat) > 300 || heartbeat.timeIntervalSince(now()) > 300 {
            issue = "Formlabs 设备数据未更新，当前显示最近缓存"
        } else if status["last_pinged_at"] is String && device.lastPingedAt == nil {
            issue = "Formlabs 返回的设备更新时间无法识别"
        } else if ["", "unknown"].contains(device.status.lowercased()),
                  print == nil || ["", "unknown"].contains(print?.status.lowercased() ?? "") {
            issue = "Formlabs 暂未提供实时状态，请连接 Dashboard 或稍后重试"
        } else {
            issue = nil
        }
        return Reading(device: device, print: print, token: token, dataIssue: issue)
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
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url)
        if url.host?.caseInsensitiveCompare(cloudBaseURL.host ?? "") == .orderedSame {
            guard !token.isEmpty else { return nil }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 12
        return request
    }

    private func authorizedData(url: URL, clientID: String, clientSecret: String) async throws -> (Data, String) {
        let token = try await accessToken(clientID: clientID, clientSecret: clientSecret)
        func request(_ value: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 12
            return request
        }
        do { return (try await data(for: request(token)), token) }
        catch FormlabsError.http(let code, _) where code == 401 {
            // Another in-flight request may already have refreshed this credential's token.
            let key = clientID + "\u{0}" + clientSecret
            if tokens[key]?.value == token { tokens[key] = nil }
            let refreshed = try await accessToken(clientID: clientID, clientSecret: clientSecret)
            do { return (try await data(for: request(refreshed)), refreshed) }
            catch FormlabsError.http(let retryCode, let detail) where retryCode == 401 {
                if tokens[key]?.value == refreshed { tokens[key] = nil }
                throw FormlabsError.http(retryCode, detail)
            }
        }
    }

    private func accessToken(clientID: String, clientSecret: String) async throws -> String {
        let key = clientID + "\u{0}" + clientSecret
        if let cached = tokens[key], cached.expiresAt.timeIntervalSince(now()) > 120 {
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
        guard expires.isFinite, expires > 0 else { throw FormlabsError.invalidResponse }
        tokens[key] = OAuthToken(value: value, expiresAt: now().addingTimeInterval(expires))
        return value
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FormlabsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Error bodies may echo request credentials; only the status code enters UI/cache.
            throw FormlabsError.http(http.statusCode, "")
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

    private static func serial(_ object: [String: Any]) -> String? {
        let value = string(object["serial"]) ?? string(object["printer_serial"])
            ?? string(object["serial_number"]) ?? string(object["machine_id"]) ?? string(object["id"])
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func parseCloudDevice(_ object: [String: Any]) -> FormlabsDeviceInfo? {
        guard let id = serial(object) else { return nil }
        let statusObject = object["printer_status"] as? [String: Any]
            ?? object["status"] as? [String: Any]
        let rawStatus = string(statusObject?["status"])
            ?? string(statusObject?["state"])
            ?? string(object["status"])
            ?? "unknown"
        let run = statusObject?["current_print_run"] as? [String: Any]
            ?? object["current_print_run"] as? [String: Any]
        let online = FormlabsDeviceInfo.resolvedIsConnected(
            explicit: bool(object["is_connected"]), status: rawStatus)
        return FormlabsDeviceInfo(
            id: id,
            productName: string(object["alias"]).flatMap { $0.isEmpty ? nil : $0 }
                ?? string(object["user_facing_name"])
                ?? string(object["name"])
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
                ?? number(object["estimated_print_time_remaining_ms"]),
            lastPingedAt: date(statusObject?["last_pinged_at"] ?? object["last_pinged_at"]),
            lastModified: date(statusObject?["last_modified"] ?? object["last_modified"])
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
            runID: string(object["guid"])
                ?? string(object["print_run_id"])
                ?? string(object["run_id"])
                ?? string(object["uuid"])
                ?? string(object["id"]),
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
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number?.isFinite == true ? number : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 0, number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
