import Darwin
import Foundation

public struct HomeAssistantDiscoveredService: Identifiable, Equatable, Sendable {
    public let name: String
    public let serverURL: String
    public let host: String
    public let port: Int

    public init(name: String, serverURL: String, host: String, port: Int) {
        self.name = name
        self.serverURL = serverURL
        self.host = host
        self.port = port
    }

    public var id: String { serverURL.lowercased() }
}

/// Home Assistant 官方通过 `_home-assistant._tcp.local.` 发布 Zeroconf 服务。
/// 这里只读取局域网广播，不尝试登录，也不会访问云端账号。
public enum HomeAssistantDiscovery {
    @MainActor
    public static func scan(timeout: TimeInterval = 3) async -> [HomeAssistantDiscoveredService] {
        await DiscoverySession().scan(timeout: timeout)
    }

    /// 将已解析的 Bonjour 服务转换为用户可添加的地址。优先使用 HA 广播的
    /// `internal_url`，否则回退到解析出的主机与端口。
    public static func makeService(name: String, host: String, port: Int,
                                   txt: [String: String] = [:])
        -> HomeAssistantDiscoveredService? {
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleanHost.isEmpty, port > 0, port <= 65_535 else { return nil }
        let internalURL = txt.first { $0.key.lowercased() == "internal_url" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL: String
        if let internalURL, let url = URL(string: internalURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            serverURL = internalURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            let scheme = port == 443 ? "https" : "http"
            let suffix = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
                ? "" : ":\(port)"
            serverURL = "\(scheme)://\(cleanHost)\(suffix)"
        }
        let location = txt.first { $0.key.lowercased() == "location_name" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (location?.isEmpty == false ? location : nil)
            ?? (name.isEmpty ? "Home Assistant" : name)
        return HomeAssistantDiscoveredService(name: displayName, serverURL: serverURL,
                                              host: cleanHost, port: port)
    }
}

private final class DiscoverySession: NSObject, NetServiceBrowserDelegate, NetServiceDelegate,
                                      @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private let lock = NSLock()
    private var retainedServices: [NetService] = []
    private var results: [HomeAssistantDiscoveredService] = []
    private var continuation: CheckedContinuation<[HomeAssistantDiscoveredService], Never>?
    private var finished = false

    @MainActor
    func scan(timeout: TimeInterval) async -> [HomeAssistantDiscoveredService] {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            browser.delegate = self
            browser.searchForServices(ofType: "_home-assistant._tcp.", inDomain: "local.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.5) * 1_000_000_000))
                self?.finish()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        lock.lock()
        retainedServices.append(service)
        lock.unlock()
        service.delegate = self
        service.resolve(withTimeout: 1.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt: [String: String]
        if let data = sender.txtRecordData() {
            txt = NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { partial, item in
                if let value = String(data: item.value, encoding: .utf8) {
                    partial[item.key] = value
                }
            }
        } else {
            txt = [:]
        }
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            ?? ipv4Address(in: sender.addresses ?? [])
            ?? ""
        if let result = HomeAssistantDiscovery.makeService(
            name: sender.name, host: host, port: sender.port, txt: txt) {
            lock.lock()
            if !results.contains(where: { $0.id == result.id }) { results.append(result) }
            lock.unlock()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let services = retainedServices
        let values = results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        lock.unlock()
        browser.stop()
        services.forEach { $0.stop() }
        continuation?.resume(returning: values)
    }

    private func ipv4Address(in addresses: [Data]) -> String? {
        for data in addresses {
            let value = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      base.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(base, socklen_t(data.count), &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            if let value { return value }
        }
        return nil
    }
}
