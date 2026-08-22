import Foundation

/// Dot. Open Platform 图像推送接口（dot.mindreset.tech）。
/// POST 一张 PNG 图片到设备，直接显示在电子墨水屏上（"摘录"/海报/截图等）。
public enum DotImageAPIClient {
    public enum DotError: Error, LocalizedError {
        case missingCredentials
        case requestFailed(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "请先在「设置」中填写 Dot API Key 与设备序列号。"
            case .requestFailed(let code, let message):
                return message.isEmpty ? "Dot 推送失败（HTTP \(code)）"
                                       : "Dot 推送失败（HTTP \(code)）：\(message)"
            }
        }
    }

    /// 推送结果：HTTP 状态码 + 服务器返回的 message（如「设备离线，将在下次内容切换时显示」）
    public struct DotPushResult {
        public let statusCode: Int
        public let message: String
    }

    /// 把 PNG 数据推送到 Dot 设备。
    /// - Parameters:
    ///   - pngData: 图片 PNG 二进制
    ///   - deviceId: 设备序列号
    ///   - apiKey: API Key
    ///   - refreshNow: 是否立即刷新显示
    ///   - ditherType: 服务器抖动方式（官方：DIFFUSION/ORDERED/NONE；NONE 表示图片已本地抖动，不再处理；nil 走服务器默认）
    ///   - ditherKernel: 服务器抖动核（官方：THRESHOLD/ATKINSON/BURKES/FLOYD_STEINBERG/...；nil 走服务器默认）
    public static func push(pngData: Data, deviceId: String, apiKey: String,
                            refreshNow: Bool = true,
                            ditherType: String? = nil,
                            ditherKernel: String? = nil) async throws -> DotPushResult {
        guard !deviceId.isEmpty, !apiKey.isEmpty else { throw DotError.missingCredentials }
        guard let url = URL(string: "https://dot.mindreset.tech/api/authV2/open/device/\(deviceId)/image") else {
            throw DotError.requestFailed(-1, "")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var payload: [String: Any] = [
            "refreshNow": refreshNow,
            "image": pngData.base64EncodedString(),
        ]
        if let ditherType {
            payload["ditherType"] = ditherType
        }
        if let ditherKernel {
            payload["ditherKernel"] = ditherKernel
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DotError.requestFailed(-1, "") }
        var message = ""
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let msg = obj["message"] as? String {
            message = msg
        }
        guard http.statusCode < 400 else { throw DotError.requestFailed(http.statusCode, message) }
        return DotPushResult(statusCode: http.statusCode, message: message)
    }

    /// 设备状态摘要：在线状态、上次渲染时间、下次刷新窗口
    public struct DotDeviceStatus {
        public let state: String
        public let detail: String
        public let lastRender: String
        public let nextPower: String
        public let nextBattery: String
    }

    /// 设备循环内容列表中的一项（GET /device/:id/loop/list）
    public struct DotTaskItem: Codable, Identifiable, Hashable {
        public let type: String
        public let key: String?
        public let title: String?
        public let message: String?
        public let image: String?

        public var id: String { key ?? "\(type)-\(title ?? "")-\(message ?? "")" }

        /// 内容类型的中文显示名
        public var typeLabel: String {
            switch type {
            case "TEXT_API": return "文本"
            case "IMAGE_API": return "图片"
            case "CANVAS_API": return "画布"
            case "GENERAL": return "通用"
            default: return type
            }
        }
    }

    /// 获取设备循环任务列表（taskType 默认 loop：轮播内容）。
    /// - Returns: 内容项数组（含 key，可作为 image/text/canvas 推送的 taskKey）。
    public static func listTasks(deviceId: String, apiKey: String,
                                 taskType: String = "loop") async throws -> [DotTaskItem] {
        guard !deviceId.isEmpty, !apiKey.isEmpty else { throw DotError.missingCredentials }
        guard let url = URL(string: "https://dot.mindreset.tech/api/authV2/open/device/\(deviceId)/\(taskType)/list") else {
            throw DotError.requestFailed(-1, "")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw DotError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        return (try? JSONDecoder().decode([DotTaskItem].self, from: data)) ?? []
    }

    /// 立即切换到设备内容循环中的下一项（无需等待计划刷新时间）。
    /// - Returns: 服务器返回的 message。
    public static func switchNext(deviceId: String, apiKey: String) async throws -> String {
        guard !deviceId.isEmpty, !apiKey.isEmpty else { throw DotError.missingCredentials }
        guard let url = URL(string: "https://dot.mindreset.tech/api/authV2/open/device/\(deviceId)/next") else {
            throw DotError.requestFailed(-1, "")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DotError.requestFailed(-1, "") }
        var message = ""
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let msg = obj["message"] as? String {
            message = msg
        }
        guard http.statusCode < 400 else { throw DotError.requestFailed(http.statusCode, message) }
        return message
    }

    /// 查询设备状态（在线/离线、上次渲染、下次刷新），用于诊断推送不上屏的问题
    public static func fetchStatus(deviceId: String, apiKey: String) async throws -> DotDeviceStatus {
        guard !deviceId.isEmpty, !apiKey.isEmpty else { throw DotError.missingCredentials }
        guard let url = URL(string: "https://dot.mindreset.tech/api/authV2/open/device/\(deviceId)/status") else {
            throw DotError.requestFailed(-1, "")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw DotError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = obj["status"] as? [String: Any] ?? [:]
        let renderInfo = obj["renderInfo"] as? [String: Any] ?? [:]
        let next = renderInfo["next"] as? [String: Any] ?? [:]
        return DotDeviceStatus(
            state: status["current"] as? String ?? "",
            detail: status["description"] as? String ?? "",
            lastRender: renderInfo["last"] as? String ?? "",
            nextPower: next["power"] as? String ?? "",
            nextBattery: next["battery"] as? String ?? "")
    }
}
