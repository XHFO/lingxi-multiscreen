import Darwin
import Foundation

/// 基于 Darwin 系统调用的 CPU / 内存 / 网络 / 运行时间采样器（macOS 专用）。
public final class SystemMonitor {
    private var previousIdle: UInt64 = 0
    private var previousTotal: UInt64 = 0
    private var previousReceived: UInt64 = 0
    private var previousSent: UInt64 = 0
    private var previousSampledAt: Date?
    private var hasBaseline = false

    /// 网络速率历史（最多 60 个采样点，供折线图渲染；时间升序，最新在末尾）
    public private(set) var networkHistory: [NetworkSample] = []
    private static let historyCapacity = 60

    public init() {}

    public func sample(now: Date = Date()) -> SystemSnapshot {
        let (idle, total) = readCpuTimes()
        let (received, sent) = readNetworkTotals()
        let (usedMemory, totalMemory) = readMemory()

        var cpu = 0.0
        var download = 0.0
        var upload = 0.0
        if hasBaseline, let previousSampledAt {
            let totalDelta = total >= previousTotal ? total - previousTotal : 0
            let idleDelta = idle >= previousIdle ? idle - previousIdle : 0
            if totalDelta > 0 {
                let busyDelta = totalDelta - min(idleDelta, totalDelta)
                cpu = Double(min(max(busyDelta * 100 / totalDelta, 0), 100))
            }
            let seconds = max(0.001, now.timeIntervalSince(previousSampledAt))
            download = max(0, Double(received - previousReceived)) / seconds
            upload = max(0, Double(sent - previousSent)) / seconds
        }

        previousIdle = idle
        previousTotal = total
        previousReceived = received
        previousSent = sent
        previousSampledAt = now
        hasBaseline = true

        networkHistory.append(NetworkSample(downloadBytesPerSecond: download,
                                            uploadBytesPerSecond: upload))
        if networkHistory.count > Self.historyCapacity {
            networkHistory.removeFirst(networkHistory.count - Self.historyCapacity)
        }

        let memoryPercent = totalMemory == 0 ? 0 : Double(usedMemory) * 100 / Double(totalMemory)
        return SystemSnapshot(
            cpuPercent: cpu,
            memoryPercent: memoryPercent,
            usedMemoryBytes: usedMemory,
            totalMemoryBytes: totalMemory,
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            uptime: readUptime(),
            sampledAt: now
        )
    }

    // MARK: - CPU

    private func readCpuTimes() -> (idle: UInt64, total: UInt64) {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let ticks = cpuInfo.cpu_ticks
        // cpu_ticks 顺序：0=user, 1=system, 2=idle, 3=nice
        let user = UInt64(ticks.0)
        let system = UInt64(ticks.1)
        let idle = UInt64(ticks.2)
        let nice = UInt64(ticks.3)
        return (idle, user + system + idle + nice)
    }

    // MARK: - 内存

    private func readMemory() -> (used: UInt64, total: UInt64) {
        let total = totalPhysicalMemory()

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return (0, total) }

        let pageSize = UInt64(vm_kernel_page_size)
        // 可用内存 ≈ 空闲 + 非活动页（与原版“可用物理内存”语义一致）
        let freePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        let freeBytes = freePages * pageSize
        let used = freeBytes >= total ? 0 : total - freeBytes
        return (used, total)
    }

    private func totalPhysicalMemory() -> UInt64 {
        var size = 0
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var value: UInt64 = 0
        var valueSize = MemoryLayout<UInt64>.size
        if sysctl(&mib, u_int(mib.count), &value, &valueSize, nil, 0) == 0 {
            return value
        }
        _ = size
        return 0
    }

    // MARK: - 网络

    private func readNetworkTotals() -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0

        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }

        var cursor = head
        while let current = cursor {
            let addr = current.pointee
            defer { cursor = addr.ifa_next }

            guard let namePointer = addr.ifa_name else { continue }
            let name = String(cString: namePointer)
            guard !isExcludedInterface(name) else { continue }

            let flags = addr.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  addr.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let dataPointer = addr.ifa_data else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }

    private func isExcludedInterface(_ name: String) -> Bool {
        let excluded = ["lo", "utun", "gif", "stf", "awdl", "llw", "ap1", "en6"]
        for prefix in excluded where name.hasPrefix(prefix) { return true }
        return false
    }

    // MARK: - 运行时间

    private func readUptime() -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootDate = Date(timeIntervalSince1970: Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(bootDate)
    }
}
