import Foundation

public enum ImageApiError: Error, LocalizedError {
    case invalidEndpoint
    case timeout
    case cannotConnect
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "图像 API 地址无效。"
        case .timeout:
            return "连接键盘超时，请检查局域网和设备地址。"
        case .cannotConnect:
            return "无法连接键盘，请确认设备在线且 API 地址正确。"
        case .httpStatus(let code, let body):
            if body.isEmpty {
                return "图像 API 返回 HTTP \(code)。"
            }
            return "图像 API 返回 HTTP \(code)：\(body)"
        }
    }
}

/// 以 Content-Type: image/jpeg 把 JPEG 字节流 POST 到键盘的图像 API。
public struct ImageApiClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    public func upload(jpeg: Data, endpoint: String, timeout: TimeInterval = 20) async throws -> Int {
        try await upload(bytes: jpeg, contentType: "image/jpeg", endpoint: endpoint, timeout: timeout)
    }

    /// 240x240 RGB565 无损帧，每个像素为大端字节序。
    public func upload(rgb565: Data, endpoint: String,
                       timeout: TimeInterval = 20) async throws -> Int {
        try await upload(bytes: rgb565, contentType: "application/x-rgb565",
                         endpoint: endpoint, timeout: timeout)
    }

    /// 无损 PNG 推送（无压缩痕迹；需键盘设备支持 PNG 解码）
    public func upload(png: Data, endpoint: String, timeout: TimeInterval = 20) async throws -> Int {
        try await upload(bytes: png, contentType: "image/png", endpoint: endpoint, timeout: timeout)
    }

    /// 通用推送：按 contentType 指定图像编码。
    public func upload(_ bytes: Data, contentType: String, endpoint: String,
                       timeout: TimeInterval = 20) async throws -> Int {
        try await upload(bytes: bytes, contentType: contentType, endpoint: endpoint, timeout: timeout)
    }

    private func upload(bytes: Data, contentType: String, endpoint: String,
                        timeout: TimeInterval = 20) async throws -> Int {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ImageApiError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: bytes)
        } catch let error as URLError where error.code == .timedOut {
            throw ImageApiError.timeout
        } catch {
            throw ImageApiError.cannotConnect
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImageApiError.cannotConnect
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw ImageApiError.httpStatus(http.statusCode, body)
        }
        return http.statusCode
    }
}
