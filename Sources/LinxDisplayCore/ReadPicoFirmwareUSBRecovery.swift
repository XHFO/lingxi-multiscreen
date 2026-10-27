import Foundation
import DiskArbitration
import IOKit

/// Restores the ordinary CDC connection after a user-requested, normal TF eject.
/// Never opens a serial port, resets hardware, or starts a firmware helper.
public struct ReadPicoFirmwareUSBRecovery: Sendable {
    public struct USBDescriptor: Equatable, Sendable {
        public let vendorID: Int, productID: Int, product: String, serial: String
        public init(vendorID: Int, productID: Int, product: String, serial: String) {
            self.vendorID = vendorID; self.productID = productID; self.product = product; self.serial = serial
        }
        public var picoIdentity: String? {
            guard vendorID == 0x303a, productID == 0x4002, product == "Read Pico TF" else { return nil }
            return ReadPicoUSBWirelessClient.normalizedIdentity(serial)
        }
    }
    public struct Candidate: Identifiable, Equatable, Sendable {
        public let volume: ReadPicoMountedVolume, deviceIdentity: String
        public var id: String { deviceIdentity + ":" + (volume.identity ?? "") + ":" + volume.rootURL.path }
        public var displayName: String { volume.name + " · " + deviceIdentity }
    }
    public enum RecoveryError: LocalizedError, Equatable {
        case changedDevice, ambiguousSerial, diskBusy, timeout
        public var errorDescription: String? {
            switch self {
            case .changedDevice: return "TF 磁盘或 USB 设备身份已改变，尚未结束传输。请刷新后重新选择。"
            case .ambiguousSerial: return "发现多个相同身份的 USB 串口，无法确认目标 Pico。请仅保留需要连接的设备后重试。"
            case .diskBusy: return "TF 磁盘正在被电脑使用，尚未结束传输。请等待索引完成或关闭访问磁盘的文件后，重试连接。"
            case .timeout: return "TF 卡已安全弹出，但原 Pico 的 USB 串口尚未恢复。请在设备上安全结束传输，唤醒后刷新；尚未开始刷写。"
            }
        }
    }
    public struct Environment: Sendable {
        public var volumes: @Sendable () -> [ReadPicoMountedVolume]
        public var descriptor: @Sendable (URL) -> USBDescriptor?
        public var ports: @Sendable () -> [String]
        public var serialIdentity: @Sendable (String) -> String?
        public var eject: @Sendable (ReadPicoMountedVolume) async throws -> Void
        public var now: @Sendable () -> TimeInterval
        public var wait: @Sendable () async throws -> Void
        public init(volumes: @escaping @Sendable () -> [ReadPicoMountedVolume] = { ReadPicoMountedVolume.discover() },
                    descriptor: @escaping @Sendable (URL) -> USBDescriptor? = { ReadPicoFirmwareUSBRecovery.descriptor(forVolume: $0) },
                    ports: @escaping @Sendable () -> [String] = { ReadPicoUSBTransferClient.discoverPorts() },
                    serialIdentity: @escaping @Sendable (String) -> String? = { ReadPicoUSBTransferClient.serialIdentity(port: $0) },
                    eject: @escaping @Sendable (ReadPicoMountedVolume) async throws -> Void = {
                        try await ReadPicoSafeEject().eject($0.rootURL, expectedVolume: $0)
                    },
                    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) }) {
            self.volumes = volumes; self.descriptor = descriptor; self.ports = ports
            self.serialIdentity = serialIdentity; self.eject = eject; self.now = now; self.wait = wait
        }
    }
    private let environment: Environment
    public init(environment: Environment = .init()) { self.environment = environment }

    public func candidates() -> [Candidate] {
        environment.volumes().compactMap { volume in
            guard let uuid = volume.identity, !uuid.isEmpty, volume.capacity > 0,
                  let identity = environment.descriptor(volume.rootURL)?.picoIdentity else { return nil }
            return Candidate(volume: volume, deviceIdentity: identity)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func recover(_ selected: Candidate, timeout: TimeInterval = 30) async throws -> String {
        try Task.checkCancellation()
        // Re-read the disk's IOMedia ancestry immediately before safe eject. UUID,
        // capacity, mount and complete USB serial must still describe this choice.
        let matches = candidates().filter {
            $0.deviceIdentity == selected.deviceIdentity && $0.volume.rootURL == selected.volume.rootURL &&
            $0.volume.identity == selected.volume.identity && $0.volume.capacity == selected.volume.capacity
        }
        guard matches.count == 1, let current = matches.first else { throw RecoveryError.changedDevice }
        do { try await environment.eject(current.volume) }
        catch let error as POSIXError where error.code == .EBUSY { throw RecoveryError.diskBusy }
        try Task.checkCancellation()
        let limit = timeout.isFinite ? min(30, max(0.1, timeout)) : 30
        let deadline = environment.now() + limit
        repeat {
            try Task.checkCancellation()
            let ports = Set(environment.ports()).filter { port in
                guard port.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev",
                      let serial = environment.serialIdentity(port) else { return false }
                return ReadPicoUSBWirelessClient.normalizedIdentity(serial) == selected.deviceIdentity
            }
            guard ports.count <= 1 else { throw RecoveryError.ambiguousSerial }
            if let port = ports.first { return port }
            if environment.now() >= deadline { throw RecoveryError.timeout }
            try await environment.wait()
        } while true
    }

    /// USB identity must come from the selected disk's IOMedia parent chain.
    /// Names/folders in the filesystem and unrelated USB devices are not evidence.
    public static func descriptor(forVolume url: URL) -> USBDescriptor? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        var entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        for _ in 0..<24 {
            if let vendor = property("idVendor") as? NSNumber, let productID = property("idProduct") as? NSNumber,
               let product = (property("USB Product Name") ?? property("kUSBProductString")) as? String,
               let serial = (property("USB Serial Number") ?? property("kUSBSerialNumberString")) as? String {
                let descriptor = USBDescriptor(vendorID: vendor.intValue, productID: productID.intValue, product: product, serial: serial)
                if descriptor.picoIdentity != nil { return descriptor }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry); entry = parent
        }
        return nil
    }
}
