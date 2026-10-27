import Foundation
import Darwin
import IOKit

public enum ReadPicoUSBTransferError: LocalizedError {
    case invalid(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text), .unavailable(let text): return text }
    }
}

public struct ReadPicoMountedVolume: Identifiable, Sendable, Equatable {
    public let rootURL: URL, name: String, capacity: Int64, free: Int64, readOnly: Bool, hasPicoFolders: Bool, identity: String?
    public var id: String { rootURL.path }
    public var detail: String {
        let total = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        return "\(total) · 可用 \(available)" + (readOnly ? " · 只读" : "")
    }
    public init(rootURL: URL, name: String, capacity: Int64, free: Int64, readOnly: Bool, hasPicoFolders: Bool, identity: String? = nil) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath(); self.name = name; self.capacity = capacity; self.free = free
        self.readOnly = readOnly; self.hasPicoFolders = hasPicoFolders
        self.identity = identity
    }
    /// List actual external local mounts, without relying on a TF volume label.
    public static func discover() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeUUIDStringKey]
        let files = FileManager.default
        return (files.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { root in
            guard let values = try? root.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  values.volumeIsInternal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true else { return nil }
            let pico = ["apps/games", "apps/tools", "readpico", ".pico-reader"].contains { files.fileExists(atPath: root.appendingPathComponent($0).path) }
            return Self(rootURL: root.standardizedFileURL, name: values.volumeName ?? root.lastPathComponent,
                        capacity: Int64(values.volumeTotalCapacity ?? 0), free: Int64(values.volumeAvailableCapacity ?? 0),
                        readOnly: values.volumeIsReadOnly == true, hasPicoFolders: pico, identity: values.volumeUUIDString)
        }.sorted { lhs, rhs in
            lhs.hasPicoFolders != rhs.hasPicoFolders ? lhs.hasPicoFolders : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// One owner for an app-controlled serial port, shared by firmware and TF handoff.
/// 中文：固件与TF交接共用串口租约；租约释放前不允许另一条流程打开端口。
public final class ReadPicoUSBSerialLease: @unchecked Sendable {
    private static let lock = NSLock()
    private static var owners: [String: UUID] = [:]
    private let path: String, owner: UUID
    private var released = false
    private init(path: String, owner: UUID) { self.path = path; self.owner = owner }
    public static func acquire(path: String) throws -> ReadPicoUSBSerialLease {
        lock.lock(); defer { lock.unlock() }
        guard owners[path] == nil else { throw ReadPicoUSBTransferError.unavailable("此 USB 端口正在更新固件或准备文件传输，请等待当前操作结束。") }
        let owner = UUID(); owners[path] = owner
        return .init(path: path, owner: owner)
    }
    public func release() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !released else { return }; released = true
        if Self.owners[path] == owner { Self.owners.removeValue(forKey: path) }
    }
    deinit { release() }
}

public struct ReadPicoUSBStartResult: Sendable, Equatable {
    public let deviceIdentity: String?
    public let backgroundSupported: Bool
    public let power: ReadPicoPowerStatus?
    public init(deviceIdentity: String? = nil, backgroundSupported: Bool = false, power: ReadPicoPowerStatus? = nil) {
        self.deviceIdentity = deviceIdentity; self.backgroundSupported = backgroundSupported; self.power = power
    }
}

/// Explicitly requested local handoff only. No reset, esptool, erase, or MSC polling.
/// 中文：先只读核对，再发送START；收到完整确认行后立即关串口，USB磁盘由用户选择。
public final class ReadPicoUSBTransferClient: @unchecked Sendable {
    public typealias Runner = @Sendable (String, @escaping @Sendable () -> Bool) async throws -> ReadPicoUSBStartResult
    private let runner: Runner?
    public init(runner: Runner? = nil) { self.runner = runner }
    public static func discoverPorts() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }
    /// Read registry metadata only; this never opens or changes the serial device.
    public static func serialIdentity(port: String) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard string(service, "IOCalloutDevice") == port else { continue }
            var entry = service; IOObjectRetain(entry)
            defer { IOObjectRelease(entry) }
            for _ in 0..<16 {
                if let serial = string(entry, "USB Serial Number") ?? string(entry, "kUSBSerialNumberString"), !serial.isEmpty { return serial }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(entry); entry = parent
            }
        }
        return nil
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    public func start(port: String, onAccepted: (@Sendable () async -> Void)? = nil) async throws -> ReadPicoUSBStartResult {
        guard port.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev" else {
            throw ReadPicoUSBTransferError.invalid("请选择小纸 Pico 的原生 USB 串口。")
        }
        try Task.checkCancellation()
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: ReadPicoUSBStartResult
            if let runner { result = try await runner(port, { cancellation.isCancelled() }) }
            else { result = try await Task.detached { try Self.exchange(port: port, cancelled: { cancellation.isCancelled() }) }.value }
            // A received ACK remains a real handoff even if its wait was just cancelled.
            await onAccepted?()
            try Task.checkCancellation(); return result
        } onCancel: { cancellation.cancel() }
    }
    /// 中文：只读已选串口的设备报告，不开启MSC、不复位，取消后等待原读取退出再释放独占租约。
    /// English: Read the chosen port without MSC/reset; cancellation waits for the reader before releasing its exclusive lease.
    public func readPowerStatus(port: String) async throws -> ReadPicoPowerStatus? {
        guard port.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev" else {
            throw ReadPicoUSBTransferError.invalid("请选择小纸 Pico 的原生 USB 串口。")
        }
        try Task.checkCancellation()
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached { try Self.exchange(port: port, cancelled: { cancellation.isCancelled() }, start: false) }.value
            try Task.checkCancellation(); return result.power
        } onCancel: { cancellation.cancel() }
    }
    /// Decode only a complete line emitted by the Pico maintenance protocol.
    public static func parseStatus(_ line: String) throws -> ReadPicoUSBStartResult {
        let status = try object(line)
        guard let route = integer(status["route"]), (0..<512).contains(route),
              ["mounted", "read_verified", "write_verified", "storage_busy"].allSatisfy({ boolean(status[$0]) != nil }),
              ["usb_active", "usb_held", "usb_background_supported", "usb_background"].allSatisfy({ status[$0] == nil || boolean(status[$0]) != nil }) else {
            throw ReadPicoUSBTransferError.invalid("此串口没有返回小纸 Pico 的存储状态，请核对所选设备。")
        }
        if status["device"] != nil && status["device"] as? String != "read-pico" {
            throw ReadPicoUSBTransferError.invalid("所选串口不是小纸 Pico。")
        }
        guard status["storage_busy"] as? Bool == false, status["usb_active"] as? Bool != true,
              status["usb_held"] as? Bool != true else {
            throw ReadPicoUSBTransferError.unavailable("设备仍在处理存储或已开启 USB 传输。请先等待磁盘出现，或在设备上结束当前传输。")
        }
        // A failed explicit check unmounts the card. A normal boot mount instead
        // reports READY/COMPLETE with both optional verification flags still false.
        // Explicitly unhealthy fields must never be overridden by stale true flags.
        let hasHealthDescription = ["present", "error", "state", "stage"].contains { status[$0] != nil }
        let healthyDescription = !hasHealthDescription || (boolean(status["present"]) == true
            && integer(status["error"]) == 0 && integer(status["state"]) == 3 && integer(status["stage"]) == 7)
        let hasUSBDescription = status["usb_active"] != nil || status["usb_held"] != nil
        let idleUSBDescription = !hasUSBDescription || (boolean(status["usb_active"]) == false && boolean(status["usb_held"]) == false)
        let verified = boolean(status["read_verified"]) == true && boolean(status["write_verified"]) == true
        let readyAfterBoot = status["device"] as? String == "read-pico"
            && boolean(status["present"]) == true && integer(status["error"]) == 0
            && integer(status["state"]) == 3 && integer(status["stage"]) == 7
            && boolean(status["usb_active"]) == false && boolean(status["usb_held"]) == false
            && boolean(status["read_verified"]) == false && boolean(status["write_verified"]) == false
        guard boolean(status["mounted"]) == true, healthyDescription, idleUSBDescription,
              status["exported"] == nil || boolean(status["exported"]) == false,
              verified || readyAfterBoot else {
            throw ReadPicoUSBTransferError.unavailable("TF 卡尚未就绪或检查未通过，请在阅读器“TF 卡与存储”中检查后重试。")
        }
        return .init(deviceIdentity: status["mac"] as? String ?? status["usb_serial"] as? String,
                     backgroundSupported: boolean(status["usb_background_supported"]) == true,
                     power: ReadPicoPowerStatus.decodeOptional(status["power"]))
    }
    public static func parseAcknowledgement(_ line: String, background: Bool? = nil) throws {
        let response = try object(line)
        guard (response["busy"] == nil || boolean(response["busy"]) != nil),
              (response["usb_background"] == nil || boolean(response["usb_background"]) != nil) else {
            throw ReadPicoUSBTransferError.invalid("设备返回了无效的 USB 传输确认。")
        }
        guard boolean(response["accepted"]) == true, boolean(response["busy"]) != true else {
            throw ReadPicoUSBTransferError.unavailable(response["busy"] as? Bool == true
                ? "设备正在使用 TF 卡，请保存笔记、退出传输后重试。"
                : "设备未能开启 USB 传输，请在阅读器检查 TF 卡并重试。")
        }
        if let background, boolean(response["usb_background"]) != background {
            throw ReadPicoUSBTransferError.unavailable("设备没有确认后台 USB 传输模式，请重新核对连接；尚未确认开启成功。")
        }
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
    private static func object(_ line: String) throws -> [String: Any] {
        // CRLF is one Swift Character, so hasSuffix("\n") rejects a real device
        // line. Frame on LF bytes, accepting CRLF and rejecting joined frames.
        let beforeLF = line.utf8.dropLast()
        guard line.hasPrefix("RPICO "), line.utf8.last == 10, line.utf8.count <= 8192,
              !line.utf8.dropLast().contains(10),
              !beforeLF.dropLast(beforeLF.last == 13 ? 1 : 0).contains(13),
              let data = String(line.dropFirst(6)).data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadPicoUSBTransferError.invalid("设备没有返回完整的 USB 传输确认，请在阅读器检查连接。")
        }
        return value
    }
    private static func exchange(port: String, cancelled: @Sendable () -> Bool, start: Bool = true) throws -> ReadPicoUSBStartResult {
        func check() throws { if cancelled() { throw CancellationError() } }
        try check()
        let descriptor = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReadPicoUSBTransferError.unavailable("无法打开所选 USB 串口。请关闭串口工具，或在设备上结束 USB 传输。") }
        defer { Darwin.close(descriptor) }
        guard Darwin.ioctl(descriptor, TIOCEXCL) == 0 else { throw ReadPicoUSBTransferError.unavailable("USB 串口已被其他程序占用。") }
        var config = termios()
        guard tcgetattr(descriptor, &config) == 0 else { throw POSIXError(.EIO) }
        cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD); config.c_cflag &= ~tcflag_t(HUPCL)
        guard cfsetspeed(&config, speed_t(B115200)) == 0, tcsetattr(descriptor, TCSANOW, &config) == 0 else { throw POSIXError(.EIO) }
        // Do not toggle DTR/RTS: doing so may reset the device or steal USB from MSC.
        var buffered = Data()
        func command(_ value: String) throws {
            try check(); let bytes = Data(value.utf8); var offset = 0
            let deadline = Date().addingTimeInterval(2)
            while offset < bytes.count {
                try check()
                let count = bytes.withUnsafeBytes { raw in Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count > 0 { offset += count; continue }
                guard count < 0 && (errno == EAGAIN || errno == EINTR), Date() < deadline else { throw POSIXError(.EIO) }
                usleep(10_000)
            }
        }
        func response(key: String) throws -> String {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                try check()
                while let newline = buffered.firstIndex(of: 10) {
                    let line = buffered.prefix(through: newline); buffered.removeSubrange(...newline)
                    if let text = String(data: line, encoding: .utf8), text.hasPrefix("RPICO "),
                       let object = try? Self.object(text), object[key] != nil { return text }
                }
                var chunk = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count > 0 { buffered.append(contentsOf: chunk.prefix(count)); if buffered.count > 8192 { buffered.removeAll() }; continue }
                if count < 0 && errno != EAGAIN && errno != EINTR { throw ReadPicoUSBTransferError.unavailable("USB 串口已断开；若设备正在连接电脑，请等待 TF 磁盘出现。") }
                usleep(20_000)
            }
            throw ReadPicoUSBTransferError.unavailable("设备没有及时回应。请唤醒阅读器；若已开启 USB 传输，直接选择 TF 磁盘。")
        }
        try command("\nRPICO STATUS\n")
        let line = try response(key: "mounted")
        if !start {
            let object = try Self.object(line)
            guard object["device"] as? String == "read-pico" else { throw ReadPicoUSBTransferError.invalid("所选串口不是小纸 Pico。") }
            return .init(power: ReadPicoPowerStatus.decodeOptional(object["power"]))
        }
        let result = try parseStatus(line)
        // 仅经设备能力确认后使用后台模式，旧固件继续原有安全交接。
        // Negotiate background handoff explicitly; retain the legacy safe flow on older firmware.
        try check(); try command(result.backgroundSupported ? "RPICO USB START BACKGROUND\n" : "RPICO USB START\n")
        try parseAcknowledgement(response(key: "accepted"), background: result.backgroundSupported ? true : nil)
        return result // descriptor closes before the caller starts waiting for a volume.
    }
}
