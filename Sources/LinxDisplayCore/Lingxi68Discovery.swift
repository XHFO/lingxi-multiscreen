import Foundation

public struct Lingxi68DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let ip: String

    public init(ip: String) { self.ip = ip }

    public var id: String { ip }

    public var displayName: String {
        "灵犀68 键盘 \(ip.split(separator: ".").last ?? "")"
    }
}

/// 灵犀68 固件没有设备清单接口，因此探测其专属 `/image/upload` 路由。
/// 扫描过程只会发送零字节 POST，不上传测试图片，也不会改变键盘当前显示内容。
public enum Lingxi68Discovery {
    /// OPTIONS / HEAD / 空 POST 命中上传路由时，固件通常返回 POST 能力、ESP 标识，
    /// 或固件统一的 CORS/no-store 预检响应。不能把裸 405 当作证据：nginx、
    /// 打印机等大量局域网设备都会对任意未知路径返回 405。
    public static func matchesUploadEndpoint(statusCode: Int,
                                             headers: [String: String],
                                             body: Data) -> Bool {
        let normalized = Dictionary(uniqueKeysWithValues: headers.map {
            ($0.key.lowercased(), $0.value.lowercased())
        })
        let allow = normalized["allow"] ?? ""
        let server = normalized["server"] ?? ""
        let contentType = normalized["content-type"] ?? ""
        let cacheControl = normalized["cache-control"] ?? ""
        let cors = normalized["access-control-allow-origin"] ?? ""
        let text = String(data: body.prefix(2_048), encoding: .utf8)?.lowercased() ?? ""
        let hasSignature = text.contains("lingxi") || text.contains("linxdisplay")
            || text.contains("image/upload") || text.contains("image upload")
        if hasSignature { return true }
        if allow.contains("post") && (200...499).contains(statusCode) { return true }
        if server.contains("esp"), (200...499).contains(statusCode) { return true }
        if statusCode == 204,
           cors == "*", cacheControl.contains("no-store"),
           contentType.contains("text/plain") {
            return true
        }
        if [400, 405, 411, 415].contains(statusCode),
           text.contains("jpeg") || text.contains("image") {
            return true
        }
        return false
    }

    public static func scanLocalNetwork(excluding excludedHosts: Set<String> = []) async
        -> [Lingxi68DiscoveredDevice] {
        let hosts = AIMacScreenDiscovery.scanCandidateHosts(
            localIPv4s: AIMacScreenDiscovery.localIPv4Addresses())
            .filter { !excludedHosts.contains($0) }
        guard !hosts.isEmpty else { return [] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 部分灵犀68固件第一次唤醒 HTTP 服务略慢，0.75 秒会在设备实际响应前超时。
        configuration.timeoutIntervalForRequest = 1.25
        configuration.timeoutIntervalForResource = 1.5
        configuration.httpMaximumConnectionsPerHost = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var found: [Lingxi68DiscoveredDevice] = []
        for start in stride(from: 0, to: hosts.count, by: 32) {
            if Task.isCancelled { break }
            let batch = Array(hosts[start..<min(start + 32, hosts.count)])
            let values = await withTaskGroup(of: Lingxi68DiscoveredDevice?.self) { group in
                for host in batch {
                    group.addTask {
                        // AI Mac 小屏幕也保留 JPEG 上传路由。先读取其严格设备信息，
                        // 命中后排除，避免将彩色小屏误列为灵犀68键盘。
                        if let infoURL = URL(string: "http://\(host)/api/info") {
                            var infoRequest = URLRequest(url: infoURL)
                            infoRequest.timeoutInterval = 1.0
                            infoRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                            if let (infoData, infoResponse) = try? await session.data(for: infoRequest),
                               let infoHTTP = infoResponse as? HTTPURLResponse,
                               (200..<300).contains(infoHTTP.statusCode),
                               AIMacScreenDiscovery.discoveredDevice(
                                from: infoData, fallbackIP: host) != nil {
                                return nil
                            }
                        }
                        guard let url = URL(string: "http://\(host)\(EndpointBuilder.path)") else {
                            return nil
                        }
                        // 实际键盘固件只实现 POST；旧的 OPTIONS/GET 探测因此会漏掉它。
                        // 三种方法并发探测，空 POST 明确声明 JPEG 但不携带任何画面数据，
                        // 固件会返回“not jpeg”等校验错误，而不会进入解码或刷新屏幕。
                        return await withTaskGroup(of: Bool.self) { probes in
                            for method in ["OPTIONS", "HEAD", "POST"] {
                                probes.addTask {
                                    var request = URLRequest(url: url)
                                    request.httpMethod = method
                                    request.timeoutInterval = 1.25
                                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                                    if method == "POST" {
                                        request.httpBody = Data()
                                        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                                        request.setValue("0", forHTTPHeaderField: "Content-Length")
                                    }
                                    guard let (data, response) = try? await session.data(for: request),
                                          let http = response as? HTTPURLResponse else { return false }
                                    var headers: [String: String] = [:]
                                    for (rawKey, rawValue) in http.allHeaderFields {
                                        guard let key = rawKey as? String else { continue }
                                        headers[key] = String(describing: rawValue)
                                    }
                                    return matchesUploadEndpoint(statusCode: http.statusCode,
                                                                 headers: headers, body: data)
                                }
                            }
                            for await matched in probes where matched {
                                probes.cancelAll()
                                return Lingxi68DiscoveredDevice(ip: host)
                            }
                            return nil
                        }
                    }
                }
                var values: [Lingxi68DiscoveredDevice] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            found.append(contentsOf: values)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.ip).inserted }
            .sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }
}
