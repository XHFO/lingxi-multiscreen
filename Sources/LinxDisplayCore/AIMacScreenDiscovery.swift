import Foundation

public enum AIMacScreenDiscoveryError: Error, LocalizedError, Equatable {
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let hostname):
            return "固件已成功刷入，但暂未在局域网发现 \(hostname).local。请确认 Wi-Fi 密码、2.4 GHz 网络及 macOS 的“本地网络”权限。"
        }
    }
}

/// 刷写完成后的定向发现。固件的 mDNS 名称由芯片 MAC 唯一推导，因此不会把
/// 同一网络上的另一台 AI Mac 小屏幕误添加到当前设备档案。
public enum AIMacScreenDiscovery {
    public static func discoveredIP(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["device"] as? String == "esp8266-ai-screen",
              let ip = object["ip"] as? String else { return nil }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }), ip != "0.0.0.0" else { return nil }
        return ip
    }

    public static func waitForDevice(
        hostname: String,
        timeoutSeconds: TimeInterval = 90,
        attempt: (@Sendable (Int) -> Void)? = nil
    ) async throws -> String {
        let cleanHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHostname.isEmpty,
              let url = URL(string: "http://\(cleanHostname).local/api/info") else {
            throw AIMacScreenDiscoveryError.timedOut(cleanHostname)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 1))
        var attemptNumber = 0
        while Date() < deadline {
            try Task.checkCancellation()
            attemptNumber += 1
            attempt?(attemptNumber)
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let ip = discoveredIP(from: data) {
                return ip
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw AIMacScreenDiscoveryError.timedOut(cleanHostname)
    }
}
