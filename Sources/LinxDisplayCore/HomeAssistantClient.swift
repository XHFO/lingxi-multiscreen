import Foundation

/// Home Assistant 拉取错误分类（每条都给出人话原因与下一步检查项）
public enum HAError: LocalizedError, Equatable {
    case invalidURL
    case cannotConnect
    case unauthorized
    case forbidden
    case timedOut
    case invalidResponse
    case serverError(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址格式不正确：请填写 Home Assistant 的完整地址，例如 http://192.168.1.20:8123"
        case .cannotConnect:
            return "无法连接 Home Assistant：请确认它已开机、地址与端口正确，并与本机在同一网络"
        case .unauthorized:
            return "访问被拒绝（HTTP 401）：长期访问令牌无效或已过期，请在 Home Assistant「个人资料 → 安全 → 长期访问令牌」重新生成"
        case .forbidden:
            return "没有访问权限（HTTP 403）：该令牌读不到实体状态，请重新生成具备完整读取权限的长期访问令牌"
        case .timedOut:
            return "连接超时：Home Assistant 未在 8 秒内响应，请检查地址、网络，以及是否需要 https://"
        case .invalidResponse:
            return "服务器返回的内容无法解析：请确认地址指向 Home Assistant 本体，而不是某个插件页或登录页"
        case .serverError(let status):
            return "服务器返回异常（HTTP \(status)）：请确认地址指向 Home Assistant 本体且服务正常"
        }
    }
}

/// 异常监控判定结果
public struct HAMonitorResult: Equatable {
    public var isAbnormal: Bool
    public var reason: String?

    public init(isAbnormal: Bool, reason: String?) {
        self.isAbnormal = isAbnormal
        self.reason = reason
    }

    public static let normal = HAMonitorResult(isAbnormal: false, reason: nil)
}

/// Bambu Lab 打印机卡片布局样式（详情页可切换；渲染层按布局调整排版）
public enum BambuCardLayout: Int, CaseIterable, Identifiable, Codable {
    case standard = 0
    case compact = 1
    case large = 2

    public var id: Int { rawValue }

    /// “紧凑”仅为旧设置解码兼容保留，不再提供给用户选择。
    public static let selectableCases: [BambuCardLayout] = [.standard, .large]

    public var selectableValue: BambuCardLayout {
        self == .compact ? .standard : self
    }

    public var title: String {
        switch self {
        case .standard: return "标准"
        case .compact: return "紧凑"
        case .large: return "大字"
        }
    }
}

/// 打印机卡片主题色：跟随全局主题强调色，或固定使用 Bambu Lab 品牌青绿
public enum BambuThemeAccent: Int, CaseIterable, Identifiable, Codable {
    case global = 0
    case bambuLab = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .global: return "跟随全局"
        case .bambuLab: return "Bambu Lab 强调色"
        }
    }
}

/// Bambu 卡片图片区块的内容来源。两个实体都保存在打印机设备中，切换时只读取所选来源。
public enum BambuImageSource: Int, CaseIterable, Identifiable, Codable {
    case camera = 0
    case taskCover = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .camera: return "摄像头"
        case .taskCover: return "任务图片"
        }
    }
}

/// Bambu Lab 打印机卡片字段配置（实体映射 + 告警 + 显示选项；每台打印机独立）
public struct BambuLabCardSettings: Codable, Equatable {
    /// 打印机名称（多打印机时区分；如「客厅 A1」「工作室 P1S」）
    public var name: String
    public var enableAlert: Bool
    public var statusEntityID: String
    public var progressEntityID: String
    public var taskEntityID: String
    public var nozzleTempEntityID: String
    public var bedTempEntityID: String
    public var remainingEntityID: String
    public var errorEntityID: String
    /// 摄像头实体（兼容旧版 imageEntityID 字段名；支持 image.* / camera.* 静态帧）
    public var imageEntityID: String
    /// 当前打印任务封面实体（通常为 image.*）
    public var taskImageEntityID: String
    /// 卡片当前选择显示摄像头还是打印任务封面
    public var imageSource: BambuImageSource
    /// 卡片布局样式（标准 / 紧凑 / 大字）
    public var layout: BambuCardLayout
    /// 卡片主题色（跟随全局 / Bambu Lab 强调色）
    public var themeAccent: BambuThemeAccent
    /// 各区块显示开关（关闭后该区块不渲染；实体未映射时本就自动隐藏）
    public var showStatus: Bool
    public var showProgress: Bool
    public var showTask: Bool
    public var showTemperature: Bool
    public var showRemaining: Bool
    public var showError: Bool
    /// 画面区块（状态下方独立图片区块；需已映射画面实体且本轮拉到图片）
    public var showImage: Bool

    public init(name: String = "打印机",
                enableAlert: Bool = true,
                statusEntityID: String = "", progressEntityID: String = "",
                taskEntityID: String = "", nozzleTempEntityID: String = "",
                bedTempEntityID: String = "", remainingEntityID: String = "",
                errorEntityID: String = "", imageEntityID: String = "",
                taskImageEntityID: String = "",
                imageSource: BambuImageSource = .camera,
                layout: BambuCardLayout = .standard,
                themeAccent: BambuThemeAccent = .global,
                showStatus: Bool = true, showProgress: Bool = true, showTask: Bool = true,
                showTemperature: Bool = true, showRemaining: Bool = true, showError: Bool = true,
                showImage: Bool = true) {
        self.name = name
        self.enableAlert = enableAlert
        self.statusEntityID = statusEntityID
        self.progressEntityID = progressEntityID
        self.taskEntityID = taskEntityID
        self.nozzleTempEntityID = nozzleTempEntityID
        self.bedTempEntityID = bedTempEntityID
        self.remainingEntityID = remainingEntityID
        self.errorEntityID = errorEntityID
        self.imageEntityID = imageEntityID
        self.taskImageEntityID = taskImageEntityID
        self.imageSource = imageSource
        self.layout = layout.selectableValue
        self.themeAccent = themeAccent
        self.showStatus = showStatus
        self.showProgress = showProgress
        self.showTask = showTask
        self.showTemperature = showTemperature
        self.showRemaining = showRemaining
        self.showError = showError
        self.showImage = showImage
    }

    public static let empty = BambuLabCardSettings()

    /// 当前卡片选中的画面实体。未配置所选来源时保持空白，不暗中切换到另一来源。
    public var selectedImageEntityID: String {
        switch imageSource {
        case .camera: return imageEntityID
        case .taskCover: return taskImageEntityID
        }
    }

    /// 从设备快照读取（旧版单台字段 + 显示选项）
    public static func from(_ s: DeviceSettings) -> BambuLabCardSettings {
        BambuLabCardSettings(name: s.bambuPrinterName ?? "打印机",
                             enableAlert: s.bambuEnableAlert ?? true,
                             statusEntityID: s.bambuStatusEntityID ?? "",
                             progressEntityID: s.bambuProgressEntityID ?? "",
                             taskEntityID: s.bambuTaskEntityID ?? "",
                             nozzleTempEntityID: s.bambuNozzleTempEntityID ?? "",
                             bedTempEntityID: s.bambuBedTempEntityID ?? "",
                             remainingEntityID: s.bambuRemainingEntityID ?? "",
                             errorEntityID: s.bambuErrorEntityID ?? "",
                             imageEntityID: s.bambuImageEntityID ?? "",
                             taskImageEntityID: s.bambuTaskImageEntityID ?? "",
                             imageSource: s.bambuImageSource ?? .camera,
                             layout: (s.bambuLayout ?? .standard).selectableValue,
                             themeAccent: s.bambuThemeAccent ?? .global,
                             showStatus: s.bambuShowStatus ?? true,
                             showProgress: s.bambuShowProgress ?? true,
                             showTask: s.bambuShowTask ?? true,
                             showTemperature: s.bambuShowTemperature ?? true,
                             showRemaining: s.bambuShowRemaining ?? true,
                             showError: s.bambuShowError ?? true,
                             showImage: s.bambuShowImage ?? true)
    }

    /// 从打印机设备读取：卡片徽标优先用设备名（设备重命名即同步卡片显示；与侧栏分组一致）
    public static func from(_ device: ManagedDevice) -> BambuLabCardSettings {
        var config = from(device.settings)
        let deviceName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceName.isEmpty {
            config.name = deviceName
        }
        return config
    }

    /// 写入设备快照（旧版单台字段 + 显示选项）
    public func apply(to s: inout DeviceSettings) {
        s.bambuPrinterName = name
        s.bambuEnableAlert = enableAlert
        s.bambuStatusEntityID = statusEntityID
        s.bambuProgressEntityID = progressEntityID
        s.bambuTaskEntityID = taskEntityID
        s.bambuNozzleTempEntityID = nozzleTempEntityID
        s.bambuBedTempEntityID = bedTempEntityID
        s.bambuRemainingEntityID = remainingEntityID
        s.bambuErrorEntityID = errorEntityID
        s.bambuImageEntityID = imageEntityID
        s.bambuTaskImageEntityID = taskImageEntityID
        s.bambuImageSource = imageSource
        s.bambuLayout = layout
        s.bambuThemeAccent = themeAccent
        s.bambuShowStatus = showStatus
        s.bambuShowProgress = showProgress
        s.bambuShowTask = showTask
        s.bambuShowTemperature = showTemperature
        s.bambuShowRemaining = showRemaining
        s.bambuShowError = showError
        s.bambuShowImage = showImage
    }

    // 兼容旧档案：早期持久化的 BambuLabCardSettings 没有显示选项字段，
    // 解码时缺失键回退默认值，避免老配置崩溃
    private enum CodingKeys: String, CodingKey {
        case name, enableAlert, statusEntityID, progressEntityID, taskEntityID,
             nozzleTempEntityID, bedTempEntityID, remainingEntityID, errorEntityID,
             imageEntityID, taskImageEntityID, imageSource,
             layout, themeAccent, showStatus, showProgress, showTask,
             showTemperature, showRemaining, showError, showImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "打印机"
        enableAlert = try c.decodeIfPresent(Bool.self, forKey: .enableAlert) ?? true
        statusEntityID = try c.decodeIfPresent(String.self, forKey: .statusEntityID) ?? ""
        progressEntityID = try c.decodeIfPresent(String.self, forKey: .progressEntityID) ?? ""
        taskEntityID = try c.decodeIfPresent(String.self, forKey: .taskEntityID) ?? ""
        nozzleTempEntityID = try c.decodeIfPresent(String.self, forKey: .nozzleTempEntityID) ?? ""
        bedTempEntityID = try c.decodeIfPresent(String.self, forKey: .bedTempEntityID) ?? ""
        remainingEntityID = try c.decodeIfPresent(String.self, forKey: .remainingEntityID) ?? ""
        errorEntityID = try c.decodeIfPresent(String.self, forKey: .errorEntityID) ?? ""
        imageEntityID = try c.decodeIfPresent(String.self, forKey: .imageEntityID) ?? ""
        taskImageEntityID = try c.decodeIfPresent(String.self, forKey: .taskImageEntityID) ?? ""
        imageSource = try c.decodeIfPresent(BambuImageSource.self, forKey: .imageSource) ?? .camera
        layout = (try c.decodeIfPresent(BambuCardLayout.self, forKey: .layout) ?? .standard)
            .selectableValue
        themeAccent = try c.decodeIfPresent(BambuThemeAccent.self, forKey: .themeAccent) ?? .global
        showStatus = try c.decodeIfPresent(Bool.self, forKey: .showStatus) ?? true
        showProgress = try c.decodeIfPresent(Bool.self, forKey: .showProgress) ?? true
        showTask = try c.decodeIfPresent(Bool.self, forKey: .showTask) ?? true
        showTemperature = try c.decodeIfPresent(Bool.self, forKey: .showTemperature) ?? true
        showRemaining = try c.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? true
        showError = try c.decodeIfPresent(Bool.self, forKey: .showError) ?? true
        showImage = try c.decodeIfPresent(Bool.self, forKey: .showImage) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enableAlert, forKey: .enableAlert)
        try c.encode(statusEntityID, forKey: .statusEntityID)
        try c.encode(progressEntityID, forKey: .progressEntityID)
        try c.encode(taskEntityID, forKey: .taskEntityID)
        try c.encode(nozzleTempEntityID, forKey: .nozzleTempEntityID)
        try c.encode(bedTempEntityID, forKey: .bedTempEntityID)
        try c.encode(remainingEntityID, forKey: .remainingEntityID)
        try c.encode(errorEntityID, forKey: .errorEntityID)
        try c.encode(imageEntityID, forKey: .imageEntityID)
        try c.encode(taskImageEntityID, forKey: .taskImageEntityID)
        try c.encode(imageSource, forKey: .imageSource)
        try c.encode(layout, forKey: .layout)
        try c.encode(themeAccent, forKey: .themeAccent)
        try c.encode(showStatus, forKey: .showStatus)
        try c.encode(showProgress, forKey: .showProgress)
        try c.encode(showTask, forKey: .showTask)
        try c.encode(showTemperature, forKey: .showTemperature)
        try c.encode(showRemaining, forKey: .showRemaining)
        try c.encode(showError, forKey: .showError)
        try c.encode(showImage, forKey: .showImage)
    }

    /// 自动识别：从实体列表匹配 printer/bambu 相关实体，按关键词归类到各字段
    public static func autoDetect(entities: [HAEntity]) -> BambuLabCardSettings {
        // 只从打印机相关域（sensor/binary_sensor/number/select/switch 等）中按关键词匹配，
        // 自动化/脚本/场景等无关类型不参与
        let relevant = HAEntityPicker.printerRelevant(entities)
        let printer = relevant.filter { e in
            let id = e.entityId.lowercased()
            return id.contains("bambu") || id.contains("printer")
        }
        var s = BambuLabCardSettings()
        func match(_ keywords: [String], domains: Set<String>) -> String? {
            printer.first { e in
                guard domains.contains(HAEntityPicker.domain(of: e.entityId)) else { return false }
                let id = e.entityId.lowercased()
                return keywords.contains { id.contains($0) }
            }?.entityId
        }
        let valueDomains: Set<String> = ["sensor", "number"]
        s.statusEntityID = match(["status", "state"], domains: ["sensor"]) ?? ""
        s.progressEntityID = match(["progress"], domains: valueDomains) ?? ""
        s.taskEntityID = match(
            ["current_task", "print_task", "task_name", "job_name", "current_job"],
            domains: ["sensor", "text", "select"]) ?? ""
        s.nozzleTempEntityID = match(
            ["nozzle_temp", "temp_nozzle", "nozzle_temperature", "hotend_temp"],
            domains: valueDomains) ?? ""
        s.bedTempEntityID = match(
            ["bed_temp", "temp_bed", "bed_temperature"], domains: valueDomains) ?? ""
        s.remainingEntityID = match(
            ["remaining_time", "remaining"], domains: valueDomains) ?? ""
        s.errorEntityID = match(
            ["hms_error", "hms_errors", "error", "err"],
            domains: ["sensor", "binary_sensor"]) ?? ""
        // 摄像头与任务封面分别匹配并同时保存，卡片里可以即时切换来源。
        let base = s.statusEntityID.isEmpty ? "sensor.bambu_printer" :
            BambuEntityMatcher.prefix(of: s.statusEntityID)
        s.imageEntityID = BambuEntityMatcher.matchPicture(
            base: base, allEntities: relevant, source: .camera)
        s.taskImageEntityID = BambuEntityMatcher.matchPicture(
            base: base, allEntities: relevant, source: .taskCover)
        return s
    }
}

/// Home Assistant 客户端：REST 拉取实体状态（GET /api/states，Bearer 认证）。
/// 不持久化任何令牌；令牌仅存在于调用方设置中。
public enum HomeAssistantClient {

    private struct RawState: Decodable {
        let entity_id: String
        let state: String
        let last_changed: String?
        let attributes: Attributes?

        struct Attributes: Decodable {
            let friendly_name: String?
            let unit_of_measurement: String?
            let icon: String?
            let model: String?
            let series: String?
            let entity_picture: String?
        }
    }

    /// 拉取全部实体状态。serverURL 形如 http://192.168.x.x:8123（自动补 /api/states）
    public static func fetchStates(serverURL: String, token: String,
                                   timeout: TimeInterval = 8) async throws -> [HAEntity] {
        guard let request = makeStatesRequest(server: serverURL, token: token, timeout: timeout) else {
            throw HAError.invalidURL
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw HAError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed:
                throw HAError.cannotConnect
            default:
                throw HAError.cannotConnect
            }
        } catch {
            throw HAError.cannotConnect
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw HAError.unauthorized
            case 403: throw HAError.forbidden
            default: throw HAError.serverError(status: http.statusCode)
            }
        }
        return try parseStates(data: data)
    }

    /// 只拉取指定实体。Bambu 卡片进入时通常仅有 7–8 个已映射实体，
    /// 并发访问 `/api/states/<entity_id>` 可避免下载、解析整个 HA 实体库。
    public static func fetchStates(serverURL: String, token: String,
                                   entityIDs: [String], timeout: TimeInterval = 8) async throws -> [HAEntity] {
        let ids = Array(Set(entityIDs.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return [] }
        let outcome = await withTaskGroup(of: (Int, Result<HAEntity, HAError>).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await fetchState(
                            serverURL: serverURL, token: token, entityID: id, timeout: timeout)))
                    } catch let error as HAError {
                        return (index, .failure(error))
                    } catch {
                        return (index, .failure(.cannotConnect))
                    }
                }
            }
            var fetched: [(Int, HAEntity)] = []
            var firstError: HAError?
            fetched.reserveCapacity(ids.count)
            for await (index, result) in group {
                switch result {
                case .success(let entity): fetched.append((index, entity))
                case .failure(let error): firstError = firstError ?? error
                }
            }
            // 某一个旧映射已被用户改名/删除时仍更新其余有效字段；全部失败才报告连接错误。
            return (fetched.sorted { $0.0 < $1.0 }.map(\.1), firstError)
        }
        if outcome.0.isEmpty, let error = outcome.1 { throw error }
        return outcome.0
    }

    public static func fetchState(serverURL: String, token: String, entityID: String,
                                  timeout: TimeInterval = 8) async throws -> HAEntity {
        guard let root = statesURL(server: serverURL) else { throw HAError.invalidURL }
        var request = URLRequest(url: root.appendingPathComponent(entityID))
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? HAError.timedOut : HAError.cannotConnect
        } catch {
            throw HAError.cannotConnect
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw HAError.unauthorized
            case 403: throw HAError.forbidden
            default: throw HAError.serverError(status: http.statusCode)
            }
        }
        return try parseState(data: data)
    }

    /// 连接参数本地校验：返回给用户的原因（nil = 参数看起来可用）
    public static func validate(serverURL: String, token: String) -> String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "尚未填写 Home Assistant 服务器地址" }
        guard statesURL(server: trimmed) != nil else {
            return "服务器地址格式不正确：请填写完整地址，例如 http://192.168.1.20:8123"
        }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "尚未填写长期访问令牌"
        }
        return nil
    }

    /// 解析实体画面地址：entity_picture 多为相对 Home Assistant 的路径（如 /api/…、/media-content://…），
    /// 需要补全为绝对地址；服务器相对路径额外带 access_token 查询参数（HA 媒体代理对该路径只认查询参数鉴权）。
    /// 缺协议时自动补 http://；无法解析时返回 nil。
    public static func imageURL(server: String, picture: String, token: String? = nil) -> URL? {
        let path = picture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        var root = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        if !root.contains("://") { root = "http://" + root }
        while root.hasSuffix("/") { root.removeLast() }
        var suffix = path.hasPrefix("/") ? path : "/" + path
        let accessToken = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !accessToken.isEmpty {
            suffix += (suffix.contains("?") ? "&" : "?") + "access_token=" + accessToken
        }
        return URL(string: root + suffix)
    }

    /// 解析实体的静态帧地址。优先使用 HA 返回的 entity_picture；camera.* 没有该属性时，
    /// 回退到官方 camera_proxy 接口，键盘端最终仍只会收到一张静态图片。
    public static func imageURL(server: String, entity: HAEntity, token: String? = nil) -> URL? {
        let picture = (entity.entityPicture ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !picture.isEmpty {
            return imageURL(server: server, picture: picture, token: token)
        }
        guard entity.domain == "camera", let states = statesURL(server: server) else { return nil }
        return states.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("api")
            .appendingPathComponent("camera_proxy")
            .appendingPathComponent(entity.entityId)
    }

    /// 拉取实体画面字节（超时与体积上限保护；仅接受图片响应）
    public static func fetchImage(url: URL, token: String,
                                  timeout: TimeInterval = 8,
                                  maxBytes: Int = 2_000_000) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? HAError.timedOut : HAError.cannotConnect
        } catch {
            throw HAError.cannotConnect
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw HAError.unauthorized
            case 403: throw HAError.forbidden
            default: throw HAError.serverError(status: http.statusCode)
            }
            if let type = http.value(forHTTPHeaderField: "Content-Type"),
               !type.lowercased().hasPrefix("image/") {
                throw HAError.invalidResponse
            }
        }
        guard !data.isEmpty, data.count <= maxBytes else { throw HAError.invalidResponse }
        return data
    }

    /// 构造实体列表请求（GET {server}/api/states，Authorization: Bearer <token>）
    public static func makeStatesRequest(server: String, token: String,
                                         timeout: TimeInterval = 8) -> URLRequest? {
        guard let url = statesURL(server: server) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// 构造实体列表地址：去空白与尾部斜杠、缺协议时自动补 http://、避免重复拼 /api/states；
    /// 不是 http/https 或缺少主机名时返回 nil（供校验与错误提示使用）
    public static func statesURL(server: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard base.lowercased().hasPrefix("http://") || base.lowercased().hasPrefix("https://") else {
            return nil
        }
        guard let url = URL(string: base + "/api/states"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 通用异常监控判定：状态实体状态 != 期望值，或错误码实体状态非空且非正常值即异常。
    /// 任何 HA 实体都可配置（Bambu Lab 打印机等为典型用例）；任一条件触发即视为异常。
    public static func monitor(entities: [HAEntity],
                               monitorEntityID: String, expectedState: String,
                               errorEntityID: String,
                               staleErrorSeconds: TimeInterval? = nil,
                               now: Date = Date()) -> HAMonitorResult {
        let trimmedExpected = expectedState.trimmingCharacters(in: .whitespacesAndNewlines)
        // 状态实体判定：状态 != 期望值即异常（未设期望值则跳过状态判定）
        if !monitorEntityID.isEmpty, !trimmedExpected.isEmpty,
           let entity = entities.first(where: { $0.entityId == monitorEntityID }) {
            if entity.state.trimmingCharacters(in: .whitespaces).lowercased() != trimmedExpected.lowercased() {
                return HAMonitorResult(isAbnormal: true,
                                       reason: "\(entity.displayName) 状态 \(entity.displayState)（期望 \(trimmedExpected)）")
            }
        }
        // 错误码实体判定：状态非空且非正常值（none/无/normal/ok/off/0）即异常；
        // binary_sensor 类 HMS 错误实体 off = 无错误、on = 有错误；"off" 必须视为正常
        // 超过 staleErrorSeconds 的旧错误码视为已恢复（忽略），避免残留旧值误报
        if !errorEntityID.isEmpty,
           let entity = entities.first(where: { $0.entityId == errorEntityID }) {
            let state = entity.state.trimmingCharacters(in: .whitespaces).lowercased()
            if !state.isEmpty && !["none", "无", "normal", "ok", "0", "off", "unavailable", "unknown"].contains(state),
               HAErrorCodePolicy.isFresh(entity: entity, now: now, staleSeconds: staleErrorSeconds) {
                return HAMonitorResult(isAbnormal: true,
                                       reason: "\(entity.displayName) 错误码 \(entity.state)")
            }
        }
        return .normal
    }

    /// 解析 /api/states 响应 JSON（独立函数便于测试）
    public static func parseStates(data: Data) throws -> [HAEntity] {
        do {
            return try JSONDecoder().decode([RawState].self, from: data).map(makeEntity)
        } catch {
            throw HAError.invalidResponse
        }
    }

    /// 解析 `/api/states/<entity_id>` 返回的单个实体。
    public static func parseState(data: Data) throws -> HAEntity {
        do {
            return makeEntity(try JSONDecoder().decode(RawState.self, from: data))
        } catch {
            throw HAError.invalidResponse
        }
    }

    private static func makeEntity(_ raw: RawState) -> HAEntity {
        HAEntity(entityId: raw.entity_id,
                 friendlyName: raw.attributes?.friendly_name ?? "",
                 state: raw.state,
                 unitOfMeasurement: raw.attributes?.unit_of_measurement,
                 icon: Self.mdiName(from: raw.attributes?.icon),
                 lastChanged: Self.parseHADate(raw.last_changed),
                 model: raw.attributes?.model ?? raw.attributes?.series,
                 entityPicture: raw.attributes?.entity_picture)
    }

    /// 解析 HA 时间戳（ISO8601；兼容带/不带小数秒）
    static func parseHADate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// 从 attributes.icon 提取 Material Design 图标名（"mdi:thermometer" → "thermometer"；
    /// 无 mdi: 前缀原样返回；空值返回 nil）
    static func mdiName(from icon: String?) -> String? {
        guard let icon, !icon.isEmpty else { return nil }
        if icon.hasPrefix("mdi:") {
            let name = String(icon.dropFirst(4))
            return name.isEmpty ? nil : name
        }
        return icon
    }
}

/// HA 实体图标映射：Material Design 图标名 / 实体域 → SF Symbol 名称。
/// 卡片与画板模块绘制实体图标时使用；映射不到的域回退通用图标。
public enum SFIconMapper {

    /// 取实体的 SF Symbol：优先实体自带的 mdi 图标名匹配，其次按实体域默认图标，最后回退通用图标
    public static func symbol(for entity: HAEntity) -> String {
        symbol(icon: entity.icon, domain: entity.domain)
    }

    /// mdi 图标名 → SF Symbol（精确映射）
    public static func symbol(icon: String?, domain: String) -> String {
        // 开关/灯光类优先按域（用户要求：switch/input_boolean → 开关样式，light → 灯泡样式；
        // 即使实体带 mdi 图标也保持域语义，避免映射成无关符号）
        if domain == "switch" || domain == "input_boolean" {
            return "switch.2"
        }
        if domain == "light" {
            return "lightbulb"
        }
        if let icon, let matched = mdiToSymbol[icon] {
            return matched
        }
        return domainDefault[domain] ?? "questionmark.circle"
    }

    /// mdi 名 → SF Symbol 精确映射（常用）
    static let mdiToSymbol: [String: String] = [
        "thermometer": "thermometer.medium",
        "lightbulb": "lightbulb",
        "lightbulb-outline": "lightbulb",
        "power": "power",
        "power-socket": "powerplug",
        "power-plug": "powerplug",
        "fan": "fan",
        "fan-off": "fan.slash",
        "snowflake": "snowflake",
        "water": "drop.fill",
        "water-percent": "drop",
        "weather-partly-cloudy": "cloud.sun",
        "weather-cloudy": "cloud",
        "weather-sunny": "sun.max",
        "weather-rainy": "cloud.rain",
        "weather-night": "moon.stars",
        "weather-windy": "wind",
        "motion-sensor": "sensor.tag.radiowaves.forward",
        "motion": "sensor",
        "door": "door.left.hand.closed",
        "door-closed": "door.left.hand.closed",
        "door-open": "door.left.hand.open",
        "lock": "lock",
        "lock-open": "lock.open",
        "camera": "camera",
        "cctv": "cctv",
        "bell": "bell",
        "bell-outline": "bell",
        "music": "music.note",
        "television": "tv",
        "television-classic": "tv",
        "vacuum": "vacuum.robot",
        "robot-vacuum": "vacuum.robot",
        "battery": "battery.100",
        "battery-outline": "battery.50",
        "alert": "exclamationmark.triangle",
        "alert-outline": "exclamationmark.triangle",
        "check": "checkmark.circle",
        "check-circle": "checkmark.circle",
        "close": "xmark.circle",
        "plus": "plus.circle",
        "minus": "minus.circle",
        "play": "play.fill",
        "pause": "pause.fill",
        "stop": "stop.fill",
        "volume-high": "speaker.wave.3",
        "volume-low": "speaker.wave.1",
        "volume-off": "speaker.slash",
        "wifi": "wifi",
        "network": "network",
        "access-point": "wifi",
        "database": "cylinder",
        "memory": "memorychip",
        "cpu": "cpu",
        "harddisk": "internaldrive",
        "update": "arrow.triangle.2.circlepath",
        "package": "shippingbox",
        "clock": "clock",
        "timer": "timer",
        "calendar": "calendar",
        "account": "person",
        "human": "person",
        "people": "person.2",
        "shield": "shield",
        "shield-check": "shield.checkered",
        "shield-alert": "exclamationmark.shield",
        "home": "house",
        "home-outline": "house",
        "map-marker": "mappin",
        "gauge": "gauge",
        "speedometer": "speedometer",
        "ruler": "ruler",
        "scale": "scalemass",
        "pulse": "waveform.path.ecg",
        "heart": "heart",
        "leaf": "leaf",
        "flower": "leaf",
        "fire": "flame",
        "gas-cylinder": "cylinder",
        "oil": "drop",
        "eye": "eye",
        "eye-off": "eye.slash",
        "video": "video",
        "video-outline": "video",
        "microphone": "mic",
        "remote": "appletvremote.gen4",
        "gamepad": "gamecontroller",
        "printer": "printer",
        "printer-3d": "printer",
        "thermometer-lines": "thermometer",
        "bluetooth": "bluetooth",
        "lan": "network",
        "air-filter": "air.purifier",
        "air-conditioner": "air.conditioner.horizontal",
        "washing-machine": "washer",
        "fridge": "refrigerator",
        "toaster": "toaster",
        "coffee": "cup.and.saucer",
        "kettle": "kettle",
        "pot": "cooktop",
        "micro-wave": "microwave",
        "stove": "stove",
        "dishwasher": "dishwasher",
        "dryer": "dryer",
        "heat-pump": "heatelements.vertical",
        "radiator": "radiator",
        "fireplace": "fireplace",
        "floor-lamp": "lamp.floor",
        "lamp": "lamp",
        "desk-lamp": "lamp.desk",
        "wall-sconce": "lamp.desk",
        "ceiling-light": "light.recessed.3",
        "led-strip": "light.strip.2",
        "light-switch": "lightswitch",
        "socket": "powerplug",
        "router": "router",
        "server": "server.rack",
        "nas": "server.rack",
        "raspberry-pi": "cpu",
        "speaker": "speaker",
        "audio": "speaker.wave.2",
        "headphones": "headphones",
        "cellphone": "smartphone",
        "tablet": "ipad",
        "laptop": "laptopcomputer",
        "keyboard": "keyboard",
        "mouse": "computermouse",
        "monitor": "display",
        "webcam": "web.camera",
        "leak": "drop.triangle",
        "water-pump": "waterpump",
        "sprinkler": "sprinkler",
        "pool": "figure.pool.swim",
        "weather-sunset": "sunset",
        "weather-fog": "cloud.fog",
        "weather-hail": "cloud.hail",
        "weather-lightning": "cloud.bolt.rain",
        "weather-lightning-rainy": "cloud.bolt.rain",
        "weather-pouring": "cloud.heavyrain",
        "weather-snowy": "cloud.snow",
        "weather-snowy-rainy": "cloud.sleet",
        "weather-partly-rainy": "cloud.sun.rain",
        "weather-tornado": "tornado",
        "weather-cloudy-alert": "exclamationmark.cloud",
    ]

    /// 实体域 → SF Symbol 默认图标
    static let domainDefault: [String: String] = [
        "sensor": "thermometer.medium",
        "binary_sensor": "switch.2",
        "switch": "switch.2",
        "light": "lightbulb",
        "climate": "thermostat",
        "number": "number",
        "select": "menucircle",
        "input_boolean": "switch.2",
        "input_button": "button.programmable",
        "input_select": "menucircle",
        "cover": "door.left.hand.closed",
        "media_player": "play.tv",
        "fan": "fan",
        "vacuum": "vacuum.robot",
        "update": "arrow.triangle.2.circlepath",
        "scene": "sparkles",
        "script": "terminal",
        "automation": "bolt",
        "button": "button.programmable",
        "camera": "camera",
        "cctv": "cctv",
        "device_tracker": "location",
        "event": "bell",
        "image": "photo",
        "siren": "bell",
        "lock": "lock",
        "alarm_control_panel": "alarm",
        "person": "person",
        "sun": "sun.max",
        "weather": "cloud.sun",
        "unknown": "questionmark.circle",
    ]
}

/// HA 刷新节流判定（后台轮询触发；独立纯函数便于冒烟测试）：
/// 未配置服务器不轮询 / 首次即轮询 / 间隔内不轮询 / 超过间隔触发轮询
public enum HARefreshPolicy {
    public static func isDue(now: Date, serverURL: String, minutes: Int, lastRefresh: Date?) -> Bool {
        guard !serverURL.isEmpty else { return false }
        guard let last = lastRefresh else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(max(1, minutes) * 60)
    }
}

/// HA 多实体列表编辑辅助（多选批量添加去重；独立纯函数便于冒烟测试）
public enum HAEntityListEditor {
    /// 把新实体批量并入现有列表：去空、去重（相对现有列表），保持现有顺序后按传入顺序追加
    public static func merge(_ current: [String], adding new: [String]) -> [String] {
        var out = current
        var seen = Set(current)
        for eid in new {
            let t = eid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !seen.contains(t) {
                out.append(t)
                seen.insert(t)
            }
        }
        return out
    }
}

/// 错误码新鲜度判定：错误码实体状态变化时间超过阈值视为已恢复（旧值忽略）。
/// 无时间戳的实体视为新鲜（兼容旧数据源）；staleSeconds 为 nil 时不做时间过滤。
public enum HAErrorCodePolicy {
    public static func isFresh(entity: HAEntity, now: Date = Date(),
                               staleSeconds: TimeInterval?) -> Bool {
        guard let staleSeconds else { return true }
        guard let lastChanged = entity.lastChanged else { return true }
        return now.timeIntervalSince(lastChanged) < staleSeconds
    }
}

/// Bambu Lab HMS 错误码 → 中文故障原因映射。
/// 完整错误码表见 Bambu Lab 官方文档 https://wiki.bambulab.com/zh/hms/home；
/// 此处内置常见码，未收录的显示通用提示引导查阅文档。
public enum BambuHMSCode {
    /// 常见错误码 → 故障原因（来源：Bambu Lab wiki 公开资料）
    static let known: [String: String] = [
        "07FE-4500-0002-0003": "切刀刀柄未松开：刀柄或刀片可能被卡住，或耗材霍尔接线异常",
        "07FE-0100-0001-0001": "主控板通讯异常",
        "07FE-0100-0001-0002": "主板异常：请重启打印机",
        "07FE-0200-0001-0001": "热床加热异常：检查热床线缆与温度传感器",
        "07FE-0200-0001-0002": "热床温度传感器异常",
        "07FE-0300-0001-0001": "喷嘴加热异常：检查热端线缆与温度传感器",
        "07FE-0300-0001-0002": "喷嘴温度传感器异常",
        "07FE-0300-0001-0003": "喷嘴加热温度超限",
        "07FE-0400-0001-0001": "打印平台调平异常：清洁平台并重试",
        "07FE-0500-0001-0001": "挤出机异常：检查堵料或电机",
        "07FE-0600-0001-0001": "耗材传感器异常：检查 AMS 耗材",
        "07FE-0700-0001-0001": "电机过流：检查线缆与电机",
    ]

    /// 取错误码对应的故障原因（未收录返回 nil，由调用方显示通用提示）
    public static func reason(for code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 直接匹配（如 07FE-4500-0002-0003）
        if let r = known[trimmed] { return r }
        // 兼容 0x 前缀与无连字符格式：归一化后匹配
        let norm = trimmed
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        if norm.count == 16 {
            let p1 = norm.prefix(4)
            let p2 = norm.dropFirst(4).prefix(4)
            let p3 = norm.dropFirst(8).prefix(4)
            let p4 = norm.dropFirst(12)
            let formatted = "\(p1)-\(p2)-\(p3)-\(p4)"
            if let r = known[formatted] { return r }
        }
        return nil
    }
}

/// Bambu Lab 实体自动匹配：从任意一个打印机实体（如状态实体）推导其余状态实体映射。
/// 原理：实体命名有规律（同一打印机共享前缀，如 sensor.bambu_01h08c0a0001_status /
/// sensor.bambu_01h08c0a0001_progress / ...），按前缀 + 关键词在全部实体中匹配。
public enum BambuEntityMatcher {
    /// 已知关键词后缀（用于提取打印机实体前缀）
    static let suffixes: [String] = [
        "printer_status", "print_status",
        "current_task", "print_task", "job_name", "current_job",
        "nozzle_temperature", "hotend_temp", "nozzle_temp", "temp_nozzle",
        "bed_temperature", "bed_temp", "temp_bed",
        "remaining_time", "hms_error", "hms_errors", "current_stage",
        "cooling_fan_speed", "aux_fan_speed", "chamber_temperature",
        // 画面实体跨 image/camera 域时也按相同设备根名称比较。
        "cover_image", "task_cover", "print_cover", "model_preview",
        "camera_image", "camera_snapshot", "snapshot", "camera",
        "thumbnail", "thumb", "preview", "cover",
        "status", "state", "progress", "task", "remaining", "error", "err", "hms",
    ]

    /// 自动匹配只允许从打印机的“打印状态实体”开始。
    /// `_print_status` / `_printer_status` 是 Bambu 集成最稳定的命名；兼容旧集成的
    /// `_status` / `_state` 时，还要求名称或型号带有明确的打印机特征，避免把普通状态传感器列入候选。
    public static func isPrintStatusEntity(_ entity: HAEntity) -> Bool {
        guard HAEntityPicker.domain(of: entity.entityId) == "sensor" else { return false }
        let id = entity.entityId.lowercased()
        if id.hasSuffix("_print_status") || id.hasSuffix("_printer_status") { return true }
        guard id.hasSuffix("_status") || id.hasSuffix("_state") else { return false }
        if BambuModelDetector.model(of: entity) != nil { return true }
        let text = "\(id) \(entity.friendlyName.lowercased())"
        return text.contains("bambu") || text.contains("printer")
            || text.contains("打印机") || text.contains("打印状态")
    }

    /// 打印机常见运行状态。用户即使改掉实体显示名称或 entity_id 后缀，状态值仍可作为候选线索。
    static let printerStateValues: Set<String> = [
        "idle", "printing", "paused", "error", "standby", "completed", "finish",
        "running", "busy", "preparing", "unloading", "loading", "cooling", "heating",
        "calibrating", "failed",
    ]

    /// 可作为同一打印机证据的兄弟实体分组。
    private static let siblingEvidenceGroups: [[String]] = [
        ["print_progress", "progress"],
        ["current_task", "print_task", "task_name", "job_name", "current_job"],
        ["nozzle_temp", "hotend_temp", "nozzle_temperature", "temp_nozzle"],
        ["bed_temp", "bed_temperature", "temp_bed"],
        ["remaining_time", "remaining"],
        ["hms_error", "hms_errors", "error", "err"],
    ]

    private static func prefixObject(of entityID: String) -> String {
        let base = prefix(of: entityID)
        return base.split(separator: ".", maxSplits: 1).last.map(String.init) ?? base
    }

    /// 一次扫描建立「打印机前缀 → 兄弟证据组数量」索引。
    /// 旧实现为每个候选再次遍历全部实体，并在排序比较器中反复评分；大量 HA 实体会让
    /// SwiftUI 主线程接近 O(n³)。索引后候选生成约为 O(n log n)。
    private typealias SiblingEvidenceIndex = [String: [Int: Int]]

    private static func evidenceGroupIndices(for entityID: String) -> [Int] {
        let id = entityID.lowercased()
        return siblingEvidenceGroups.indices.filter { index in
            siblingEvidenceGroups[index].contains(where: { id.contains($0) })
        }
    }

    private static func siblingEvidenceIndex(_ allEntities: [HAEntity]) -> SiblingEvidenceIndex {
        var groupCountsByPrefix: SiblingEvidenceIndex = [:]
        for entity in allEntities {
            let id = entity.entityId.lowercased()
            let baseObject = prefixObject(of: id)
            guard !baseObject.isEmpty else { continue }
            for index in evidenceGroupIndices(for: id) {
                groupCountsByPrefix[baseObject, default: [:]][index, default: 0] += 1
            }
        }
        return groupCountsByPrefix
    }

    /// 从预建索引读取兄弟证据数量，并扣除候选实体自身贡献的证据组。
    private static func siblingEvidenceCount(for entity: HAEntity,
                                             index: SiblingEvidenceIndex) -> Int {
        guard var counts = index[prefixObject(of: entity.entityId)] else { return 0 }
        for group in evidenceGroupIndices(for: entity.entityId) {
            counts[group, default: 0] -= 1
        }
        return counts.values.filter { $0 > 0 }.count
    }

    /// 同一打印机前缀下的兄弟实体证据。只看稳定 entity_id，不依赖用户可修改的 friendly_name。
    static func siblingEvidenceCount(for entity: HAEntity, allEntities: [HAEntity]) -> Int {
        siblingEvidenceCount(for: entity, index: siblingEvidenceIndex(allEntities))
    }

    /// 自动匹配候选可信度：标准后缀最高，其次是型号/通用状态后缀与同前缀兄弟实体，
    /// 再其次是当前状态值；friendly_name 仅作低优先级兜底，改名不会让可靠候选消失。
    private static func printStatusCandidateScore(_ entity: HAEntity, siblingCount: Int) -> Int {
        guard HAEntityPicker.domain(of: entity.entityId) == "sensor" else { return 0 }
        let id = entity.entityId.lowercased()
        if id.hasSuffix("_print_status") || id.hasSuffix("_printer_status") { return 100 }

        let hasStatusSuffix = id.hasSuffix("_status") || id.hasSuffix("_state")
        let modelKnown = BambuModelDetector.model(of: entity) != nil
        let stateKnown = printerStateValues.contains(entity.state.lowercased())
        let nameText = entity.friendlyName.lowercased()
        let nameHint = nameText.contains("bambu") || nameText.contains("printer")
            || nameText.contains("打印机") || nameText.contains("打印状态")

        guard stateKnown || siblingCount >= 2 || nameHint || (hasStatusSuffix && modelKnown) else { return 0 }
        var score = 0
        if hasStatusSuffix { score += 35 }
        if modelKnown { score += 25 }
        score += min(siblingCount, 6) * 8
        if stateKnown { score += 12 }
        if nameHint { score += 4 }
        // 没有明确后缀时至少需要型号、打印状态值或两个兄弟实体，避免普通传感器误入。
        if !hasStatusSuffix && !stateKnown && siblingCount < 2 && !nameHint { return 0 }
        return score
    }

    static func printStatusCandidateScore(_ entity: HAEntity, allEntities: [HAEntity]) -> Int {
        let siblingCount = siblingEvidenceCount(for: entity,
                                                index: siblingEvidenceIndex(allEntities))
        return printStatusCandidateScore(entity, siblingCount: siblingCount)
    }

    public static func printStatusCandidates(_ entities: [HAEntity]) -> [HAEntity] {
        let relevant = HAEntityPicker.printerRelevant(entities)
        let evidence = siblingEvidenceIndex(relevant)
        var scored: [(entity: HAEntity, score: Int)] = []
        scored.reserveCapacity(relevant.count)
        for entity in relevant where HAEntityPicker.domain(of: entity.entityId) == "sensor" {
            let score = printStatusCandidateScore(
                entity, siblingCount: siblingEvidenceCount(for: entity, index: evidence))
            if score > 0 { scored.append((entity, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entity.entityId.localizedStandardCompare(rhs.entity.entityId) == .orderedAscending
        }
        return scored.map(\.entity)
    }

    /// 打印状态选择器的最终候选集。关闭默认筛选时仅保留类型约束，列出全部 sensor；
    /// 具体选中的实体会作为用户明确指定的自动匹配起点。
    public static func printStatusCandidates(_ entities: [HAEntity],
                                             useDefaultFilter: Bool) -> [HAEntity] {
        if useDefaultFilter {
            return printStatusCandidates(entities)
        }
        return HAEntityPicker.printerRelevant(entities)
            .filter { HAEntityPicker.domain(of: $0.entityId) == "sensor" }
            .sorted {
                $0.entityId.localizedStandardCompare($1.entityId) == .orderedAscending
            }
    }

    /// 从实体 id 提取前缀：去掉已知关键词后缀（sensor.bambu_xxx_status → sensor.bambu_xxx）
    public static func prefix(of entityID: String) -> String {
        let lower = entityID.lowercased()
        var best: (suffix: String, range: Range<String.Index>)?
        for suffix in suffixes {
            let pattern = "_" + suffix
            if let r = lower.range(of: pattern, options: .backwards),
               r.upperBound == lower.endIndex {
                if best == nil || suffix.count > best!.suffix.count {
                    best = (suffix, r)
                }
            }
        }
        if let b = best {
            return String(lower[..<b.range.lowerBound])
        }
        // 无已知后缀：去掉最后一个下划线段
        if let r = lower.range(of: "_", options: .backwards) {
            return String(lower[..<r.lowerBound])
        }
        return lower
    }

    private static let cameraPictureHints = [
        "camera", "摄像头", "webcam", "live_view", "liveview", "stream", "snapshot", "监控",
    ]
    private static let taskCoverPictureHints = [
        "cover", "封面", "thumbnail", "thumb", "preview", "预览", "model", "模型",
        "plate", "盘", "gcode", "3mf", "task", "任务", "job", "print_image",
    ]

    private static func containsPictureHint(_ text: String, hints: [String]) -> Bool {
        hints.contains { text.contains($0) }
    }

    /// 画面实体候选：把 camera.* 和 image.* 摄像头归到“摄像头”，其余 image.*
    ///（尤其 cover/thumbnail/preview）归到“任务封面”。返回值稳定排序，供自动匹配与手动选择共用。
    public static func pictureCandidates(_ entities: [HAEntity],
                                         source: BambuImageSource? = nil,
                                         requireAvailablePicture: Bool = true) -> [HAEntity] {
        entities.filter { entity in
            let domain = HAEntityPicker.domain(of: entity.entityId)
            guard domain == "image" || domain == "camera" else { return false }
            if requireAvailablePicture, !entity.hasPicture { return false }
            guard let source else { return true }
            let text = "\(entity.entityId) \(entity.friendlyName)".lowercased()
            let looksLikeCamera = domain == "camera"
                || containsPictureHint(text, hints: cameraPictureHints)
            let looksLikeTaskCover = containsPictureHint(text, hints: taskCoverPictureHints)
            switch source {
            case .camera: return looksLikeCamera
            case .taskCover:
                guard domain == "image" else { return false }
                // 明确带摄像头词的 image.* 不混入封面；同时出现封面词时以封面身份保留，
                // 兼容部分集成的 camera_cover / camera_preview 命名。
                return looksLikeTaskCover || !looksLikeCamera
            }
        }.sorted {
            $0.entityId.localizedStandardCompare($1.entityId) == .orderedAscending
        }
    }

    /// 无区分度的通用词（域前缀、状态词、品牌词），不参与打印机与画面实体的标识词匹配
    static let genericTokens: Set<String> = [
        "sensor", "binary", "image", "camera", "number", "select", "switch", "input", "text",
        "status", "state", "print", "printer", "device", "entity", "bambu", "lab", "current",
        "camera", "snapshot", "webcam", "image", "picture", "cover", "thumbnail", "thumb",
        "preview", "model", "plate", "task", "job",
    ]

    /// 实体 id 的标识词集合（去掉通用词与短词）
    static func identifierTokens(of entityID: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        // 型号类标识词常只有 2 个字符（a1 / p1s / x1），按 >=2 取词才能跨域匹配画面实体
        return Set(entityID.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count >= 2 && !genericTokens.contains($0) })
    }

    /// 画面实体命名偏好加分；仅用于同一台打印机多个同类画面时稳定排序。
    static func pictureSuffixBonus(_ entityID: String, source: BambuImageSource) -> Int {
        let id = entityID.lowercased()
        switch source {
        case .camera:
            if HAEntityPicker.domain(of: id) == "camera" { return 8 }
            if id.contains("camera") { return 6 }
            if id.contains("snapshot") || id.contains("webcam") { return 4 }
        case .taskCover:
            if id.contains("cover_image") || id.contains("task_cover") { return 8 }
            if id.contains("cover") { return 6 }
            if id.contains("thumbnail") || id.contains("thumb") { return 5 }
            if id.contains("preview") || id.contains("model") { return 4 }
        }
        return 0
    }

    /// 为本打印机挑选画面实体：优先与打印机前缀共享标识词的 image 实体（多台打印机不会互相错绑），
    /// 同分时摄像头/封面优先；实体池里只有一张画面时兜底绑定（单打印机常见布局的命名不统一）
    static func matchPicture(base: String, knownEntity: HAEntity? = nil,
                             allEntities: [HAEntity],
                             source: BambuImageSource = .camera) -> String {
        let candidates = pictureCandidates(allEntities, source: source)
        guard !candidates.isEmpty else { return "" }
        let baseObject = base.split(separator: ".", maxSplits: 1).last.map(String.init) ?? base
        var baseTokens = identifierTokens(of: base)
        if let knownEntity {
            baseTokens.formUnion(identifierTokens(of: knownEntity.friendlyName))
            if let model = knownEntity.model {
                baseTokens.formUnion(identifierTokens(of: model))
            }
        }
        let knownModel = knownEntity.flatMap(BambuModelDetector.model(of:))
        var ranked: [(id: String, score: Int)] = []
        ranked.reserveCapacity(candidates.count)
        for candidate in candidates {
            // 第一优先级：跨域去掉字段后缀后，设备根名称完全一致。
            let candidateBase = prefix(of: candidate.entityId)
            let candidateObject = candidateBase.split(separator: ".", maxSplits: 1)
                .last.map(String.init) ?? candidateBase
            let candidateTokens = identifierTokens(of: candidate.entityId)
                .union(identifierTokens(of: candidate.friendlyName))
                .union(identifierTokens(of: candidate.model ?? ""))
            let shared = baseTokens.intersection(candidateTokens).count
            var score = shared * 20 + pictureSuffixBonus(candidate.entityId, source: source)
            if candidateObject == baseObject {
                score += 200
            } else if candidateObject.hasPrefix(baseObject + "_")
                        || baseObject.hasPrefix(candidateObject + "_") {
                score += 80
            }
            if let knownModel, BambuModelDetector.model(of: candidate) == knownModel {
                score += 35
            }
            if score > 0 { ranked.append((candidate.entityId, score)) }
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        if let best = ranked.first {
            // 两个候选证据完全相同时不武断错绑，交给用户在已分流的选择器里手动指定。
            if ranked.count > 1, ranked[1].score == best.score { return "" }
            return best.id
        }
        // 只有一个同类画面时仍保留兜底，支持完全自定义 entity_id 的单打印机场景。
        return candidates.count == 1 ? candidates[0].entityId : ""
    }

    /// 推导：给定一个已知打印机实体，在全部实体中按前缀+关键词匹配各字段
    public static func detect(from knownEntity: HAEntity, allEntities: [HAEntity],
                              allowUnfilteredSeed: Bool = false) -> BambuLabCardSettings {
        guard HAEntityPicker.domain(of: knownEntity.entityId) == "sensor",
              allowUnfilteredSeed
                || printStatusCandidateScore(knownEntity, allEntities: allEntities) > 0 else {
            return BambuLabCardSettings(name: BambuModelDetector.modelName(of: knownEntity) ?? "打印机")
        }
        // 候选集先过滤为打印机相关域（sensor/binary_sensor/number/select/switch/image 等），
        // 自动化/脚本/场景等无关类型不参与匹配
        let candidates = HAEntityPicker.printerRelevant(allEntities)
        let base = prefix(of: knownEntity.entityId)
        let baseObject = base.split(separator: ".", maxSplits: 1).last.map(String.init) ?? base
        func match(_ keywords: [String], domains: Set<String>) -> String {
            for keyword in keywords {
                if let entity = candidates.first(where: { e in
                    guard domains.contains(HAEntityPicker.domain(of: e.entityId)) else {
                        return false
                    }
                    let id = e.entityId.lowercased()
                    let object = id.split(separator: ".", maxSplits: 1).last.map(String.init) ?? id
                    let samePrinter = baseObject.isEmpty || object == baseObject
                        || object.hasPrefix(baseObject + "_")
                    return samePrinter && id.contains(keyword)
                }) {
                    return entity.entityId
                }
            }
            return ""
        }
        let valueDomains: Set<String> = ["sensor", "number"]
        return BambuLabCardSettings(
            name: BambuModelDetector.modelName(of: knownEntity) ?? "打印机",
            statusEntityID: knownEntity.entityId,
            progressEntityID: match(["print_progress", "progress"], domains: valueDomains),
            taskEntityID: match(
                ["current_task", "print_task", "task_name", "job_name", "current_job", "task"],
                domains: ["sensor", "text", "select"]),
            nozzleTempEntityID: match(
                ["nozzle_temp", "hotend_temp", "nozzle_temperature", "temp_nozzle"],
                domains: valueDomains),
            bedTempEntityID: match(
                ["bed_temp", "bed_temperature", "temp_bed"], domains: valueDomains),
            remainingEntityID: match(
                ["remaining_time", "remaining"], domains: valueDomains),
            errorEntityID: match(
                ["hms_error", "hms_errors", "error", "err"],
                domains: ["sensor", "binary_sensor"]),
            imageEntityID: matchPicture(base: base, knownEntity: knownEntity,
                                        allEntities: allEntities, source: .camera),
            taskImageEntityID: matchPicture(base: base, knownEntity: knownEntity,
                                            allEntities: allEntities, source: .taskCover))
    }
}

/// Bambu Lab 打印机型号识别：从实体属性/名称/entity_id 匹配型号（A1 mini/A1/P1S/X1C 等）
public enum BambuModelDetector {
    // 注意：长模式必须排在短模式之前（如 "x1 carbon" 先于 "x1"），否则子串会误匹配
    static let models: [(pattern: String, name: String)] = [
        ("a1 mini", "A1 mini"), ("a1mini", "A1 mini"), ("a1", "A1"),
        ("p1s", "P1S"), ("p1p", "P1P"), ("p1", "P1"),
        ("x1e", "X1E"), ("x1 carbon", "X1C"), ("x1c", "X1C"), ("x1", "X1"),
        ("x2d", "X2D"), ("x2", "X2"),
        ("h2dr", "H2DR"), ("h2d", "H2D"),
    ]

    /// 识别型号（返回标准名，如 "A1"；未识别返回 nil）
    public static func model(of entity: HAEntity) -> String? {
        let candidates = [entity.model ?? "", entity.displayName, entity.entityId]
        for text in candidates {
            let lower = text.lowercased()
            for (pattern, name) in models where lower.contains(pattern) {
                return name
            }
        }
        return nil
    }

    /// 识别型号并组合打印机名（如 "A1"；nil 时返回 "打印机"）
    public static func modelName(of entity: HAEntity) -> String? {
        model(of: entity)
    }
}

/// Bambu Lab 打印状态汉化：空闲/打印中/已完成…（卡片与画板模块共用，未知状态原样返回）
public enum BambuStatusText {
    public static func map(_ state: String) -> String {
        switch state.lowercased() {
        case "idle": return "空闲"
        case "printing": return "打印中"
        case "paused": return "已暂停"
        case "error": return "报错"
        case "standby": return "待机"
        case "off": return "关机"
        case "completed", "finish": return "已完成"
        case "running": return "运行中"
        case "busy": return "忙碌"
        case "preparing": return "准备中"
        case "unloading": return "退料中"
        case "loading": return "进料中"
        case "cooling": return "冷却中"
        case "heating": return "加热中"
        case "calibrating": return "校准中"
        case "failed": return "失败"
        case "unknown": return "未知"
        default: return state
        }
    }
}

/// HA 实体选择辅助：实体域（domain）分组 + 关键字过滤。
/// 设置页两级实体选择器（第一级 = 实体域分类，第二级 = 实体列表）复用；
/// 独立纯函数便于冒烟测试。数据模型不变（仍以 entity_id 字符串为准）。
public enum HAEntityPicker {

    /// 实体域：entity_id 第一个点之前的部分（无点视为 unknown，大小写不敏感）
    public static func domain(of entityID: String) -> String {
        let lower = entityID.lowercased()
        if let dot = lower.firstIndex(of: ".") {
            return String(lower[..<dot])
        }
        return "unknown"
    }

    /// 从用户选择的实体 ID 中提取可显示静态帧的 camera/image 实体。
    /// 去除空白、去重并保持用户在卡片中的排列顺序。
    public static func pictureEntityIDs(in entityIDs: [String]) -> [String] {
        entityIDs.reduce(into: []) { result, rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let entityDomain = domain(of: id)
            guard (entityDomain == "camera" || entityDomain == "image"),
                  !result.contains(id) else { return }
            result.append(id)
        }
    }

    /// 按实体域分组：域按字母序、组内按 entity_id 排序（空输入返回空数组）
    public static func groupByDomain(_ entities: [HAEntity]) -> [(domain: String, entities: [HAEntity])] {
        let grouped = Dictionary(grouping: entities) { domain(of: $0.entityId) }
        return grouped.keys.sorted().map { domain in
            (domain, grouped[domain]!.sorted { $0.entityId < $1.entityId })
        }
    }

    /// 关键字过滤：匹配 friendly_name、entity_id 或实体域中文名（大小写不敏感；空白关键字返回全部）
    public static func filter(_ entities: [HAEntity], keyword: String) -> [HAEntity] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return entities }
        return entities.filter { e in
            let id = e.entityId.lowercased()
            return id.contains(kw)
                || e.displayName.lowercased().contains(kw)
                || chineseDomain(of: e).lowercased().contains(kw)
        }
    }

    /// Home Assistant 实体域中文名（覆盖常见域；未收录的域原样返回英文）
    public static let domainChineseNames: [String: String] = [
        "sensor": "传感器",
        "binary_sensor": "二进制传感器",
        "number": "数字",
        "select": "选择",
        "switch": "开关",
        "text": "文本",
        "boolean": "布尔",
        "light": "灯",
        "fan": "风扇",
        "climate": "空调温控",
        "humidifier": "加湿器",
        "cover": "窗帘",
        "lock": "门锁",
        "alarm_control_panel": "安防面板",
        "vacuum": "吸尘器",
        "siren": "警报器",
        "valve": "阀门",
        "water_heater": "热水器",
        "appliance": "家电",
        "media_player": "媒体播放",
        "camera": "摄像头",
        "image": "图片",
        "button": "按钮",
        "automation": "自动化",
        "script": "脚本",
        "scene": "场景",
        "timer": "计时器",
        "schedule": "日程计划",
        "counter": "计数器",
        "input_boolean": "输入开关",
        "input_number": "输入数值",
        "input_select": "输入选项",
        "input_text": "输入文本",
        "input_button": "输入按钮",
        "input_datetime": "输入日期时间",
        "person": "人员",
        "zone": "区域",
        "device_tracker": "设备追踪",
        "weather": "天气",
        "sun": "太阳",
        "moon": "月亮",
        "calendar": "日历",
        "todo": "待办清单",
        "update": "更新",
        "notify": "通知",
        "event": "事件",
        "stt": "语音转文字",
        "tts": "文字转语音",
        "wake_word": "唤醒词",
        "image_processing": "图像处理",
        "homeassistant": "HomeAssistant 核心",
        "homekit": "HomeKit 桥接",
        "mqtt": "MQTT",
        "unknown": "未知",
    ]

    /// 实体域中文名：未收录的域返回原始英文名
    public static func chineseDomain(_ domain: String) -> String {
        domainChineseNames[domain.lowercased()] ?? domain
    }

    /// 实体所属域的中文名
    public static func chineseDomain(of entity: HAEntity) -> String {
        chineseDomain(domain(of: entity.entityId))
    }

    /// 打印机可映射的实体域白名单（Bambu Lab 集成暴露的数值/状态/开关类实体；
    /// 自动化 automation、脚本 script、场景 scene、灯 light 等无关类型一律排除）
    public static let printerDomains: Set<String> = [
        "sensor", "binary_sensor", "number", "select", "switch",
        "input_number", "input_select", "input_boolean",
        // 画面实体（打印机摄像头快照 / 模型封面）也归入打印机可选域
        "image", "camera",
    ]

    /// 过滤出打印机相关实体（仅保留白名单域；用于打印机实体选择器与自动匹配的候选集）
    public static func printerRelevant(_ entities: [HAEntity]) -> [HAEntity] {
        entities.filter { printerDomains.contains(domain(of: $0.entityId)) }
    }
}
