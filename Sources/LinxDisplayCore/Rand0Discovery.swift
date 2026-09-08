import Foundation

public struct Rand0DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let ip: String

    public init(ip: String) { self.ip = ip }
    public var id: String { ip }
    public var displayName: String { "口袋先知 \(ip.split(separator: ".").last ?? "")" }
}

/// 口袋先知未提供稳定的设备清单接口，因此用其专属 `/display/bw` WebSocket
/// 握手来确认设备身份；不发送图像帧，也不会改变屏幕内容。
public enum Rand0Discovery {
    public static func scanLocalNetwork(excluding excludedHosts: Set<String> = []) async
        -> [Rand0DiscoveredDevice] {
        let local = AIMacScreenDiscovery.localIPv4Addresses()
        let hosts = AIMacScreenDiscovery.scanCandidateHosts(localIPv4s: local)
            .filter { !excludedHosts.contains($0) }
        guard !hosts.isEmpty else { return [] }
        var found: [Rand0DiscoveredDevice] = []
        // 较短握手按批次执行，避免一次创建数百条连接压高路由器和本机占用。
        for start in stride(from: 0, to: hosts.count, by: 24) {
            if Task.isCancelled { break }
            let batch = Array(hosts[start..<min(start + 24, hosts.count)])
            let values = await withTaskGroup(of: Rand0DiscoveredDevice?.self) { group in
                for host in batch {
                    group.addTask {
                        await Rand0DisplaySession.probe(ip: host, timeout: 0.65)
                            ? Rand0DiscoveredDevice(ip: host) : nil
                    }
                }
                var values: [Rand0DiscoveredDevice] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            found.append(contentsOf: values)
        }
        return found.sorted {
            $0.ip.compare($1.ip, options: .numeric) == .orderedAscending
        }
    }
}
