import Darwin
import Foundation

public struct AIMacDiscoveredDevice: Identifiable, Equatable, Sendable {
    public let ip: String
    public let hostname: String
    public let firmwareVersion: String

    public init(ip: String, hostname: String, firmwareVersion: String) {
        self.ip = ip
        self.hostname = hostname
        self.firmwareVersion = firmwareVersion
    }

    public var id: String { ip }

    public var displayName: String {
        let suffix = hostname
            .replacingOccurrences(of: "lingxi-aimac-", with: "", options: [.caseInsensitive])
            .uppercased()
        return suffix.isEmpty || suffix == hostname.uppercased()
            ? "AI Mac 小屏幕" : "AI Mac \(suffix)"
    }
}

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

    /// 严格解析设备信息。局域网扫描只接受内置固件返回的设备标识与 240×240 屏幕，
    /// 避免把恰好提供 `/api/info` 的其他局域网服务显示为小屏幕。
    public static func discoveredDevice(from data: Data, fallbackIP: String) -> AIMacDiscoveredDevice? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["device"] as? String == "esp8266-ai-screen",
              let screen = object["screen"] as? [String: Any],
              screen["width"] as? Int == 240,
              screen["height"] as? Int == 240 else { return nil }
        let ip = discoveredIP(from: data) ?? fallbackIP
        guard isValidIPv4(ip) else { return nil }
        return AIMacDiscoveredDevice(
            ip: ip,
            hostname: object["hostname"] as? String ?? "",
            firmwareVersion: object["fw"] as? String ?? "未知版本")
    }

    /// 把当前活动 IPv4 接口转换为待扫描的 /24 地址。家庭路由器绝大多数使用
    /// /24；限制到 254 个地址可避免在较大企业网段中产生过量请求。
    public static func scanCandidateHosts(localIPv4s: [String]) -> [String] {
        var prefixes: [String] = []
        for address in localIPv4s where isValidIPv4(address) {
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        let own = Set(localIPv4s)
        return prefixes.flatMap { prefix in
            (1...254).map { "\(prefix).\($0)" }.filter { !own.contains($0) }
        }
    }

    /// 扫描当前 Mac 所在局域网中已经刷好固件且完成联网的小屏幕。
    /// 每批最多并发 32 个短请求，兼顾发现速度与路由器负载。
    public static func scanLocalNetwork() async -> [AIMacDiscoveredDevice] {
        let hosts = scanCandidateHosts(localIPv4s: localIPv4Addresses())
        guard !hosts.isEmpty else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 0.9
        configuration.timeoutIntervalForResource = 1.1
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var found: [AIMacDiscoveredDevice] = []
        for start in stride(from: 0, to: hosts.count, by: 32) {
            if Task.isCancelled { break }
            let end = min(start + 32, hosts.count)
            let batch = Array(hosts[start..<end])
            let results = await withTaskGroup(of: AIMacDiscoveredDevice?.self) { group in
                for host in batch {
                    group.addTask {
                        guard let url = URL(string: "http://\(host)/api/info") else { return nil }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 0.9
                        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                        guard let (data, response) = try? await session.data(for: request),
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else { return nil }
                        return discoveredDevice(from: data, fallbackIP: host)
                    }
                }
                var batchResults: [AIMacDiscoveredDevice] = []
                for await result in group {
                    if let result { batchResults.append(result) }
                }
                return batchResults
            }
            found.append(contentsOf: results)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.ip).inserted }
            .sorted { lhs, rhs in
                lhs.ip.compare(rhs.ip, options: .numeric) == .orderedAscending
            }
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        } && value != "0.0.0.0"
    }

    /// 当前可用于局域网设备发现的活动 IPv4 地址。
    public static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let interface = String(cString: item.pointee.ifa_name)
            guard interface.hasPrefix("en") || interface.hasPrefix("bridge") else { continue }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            guard isValidIPv4(value), !value.hasPrefix("169.254.") else { continue }
            if !addresses.contains(value) { addresses.append(value) }
        }
        return addresses
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
