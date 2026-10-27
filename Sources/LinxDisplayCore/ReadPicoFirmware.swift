import CryptoKit
import Darwin
import Foundation

/// 中文：日常仅更新 APP；有效分区不匹配时须另行确认内置包的首次安装。
/// English: APP-only updates by default; a valid layout mismatch requires separate first-install consent.
public enum ReadPicoFirmwareError: Error, LocalizedError, Equatable {
    case invalid(String), helper(String), partitionMismatch(ReadPicoPartitionMismatch), busy, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "安全检查未通过：\(reason)"
        case .helper(let reason): return "刷写助手：\(reason)"
        case .partitionMismatch: return "设备分区与新固件不匹配，尚未写入任何数据。可选择首次全新安装。"
        case .busy: return "该串口正在执行另一项操作。"
        case .cancelled: return "操作已停止，尚未开始写入固件。设备若未恢复运行，请按电源键重新开机。"
        }
    }
}

/// 中文：只能由成功的芯片、容量、安全状态及有效分区检查生成，供确认后绑定原设备。
/// English: Produced only after chip, capacity, security and valid partition checks; binds consent to that device.
public struct ReadPicoPartitionMismatch: Equatable, Sendable {
    public let portPath: String
    public let macAddress: String
    public let partitionSHA256: String
    public let partitions: [ReadPicoPartition]
    public let targetBundleSHA256: String?
    fileprivate init(portPath: String, macAddress: String, partitionSHA256: String, partitions: [ReadPicoPartition], targetBundleSHA256: String?) {
        self.portPath = portPath; self.macAddress = macAddress
        self.partitionSHA256 = partitionSHA256; self.partitions = partitions; self.targetBundleSHA256 = targetBundleSHA256
    }
}

public struct ReadPicoFreshInstallManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let role: String
        public let file: String
        public let address: UInt32
        public let bytes: Int
        public let sha256: String
    }
    public let schema: Int
    public let kind: String
    public let board: String
    public let chip: String
    public let version: String
    public let flashBytes: Int
    public let eraseFlash: Bool
    public let erasedPartitions: [String]
    public let files: [File]
    enum CodingKeys: String, CodingKey {
        case schema, kind, board, chip, version, files
        case flashBytes = "flash_bytes", eraseFlash = "erase_flash", erasedPartitions = "erased_partitions"
    }
}

public struct ReadPicoFreshInstallBundle: Sendable {
    public let manifest: ReadPicoFreshInstallManifest
    public let appInfo: ReadPicoImageInfo
    public let sha256: String
    public let segments: [(file: ReadPicoFreshInstallManifest.File, data: Data)]
}

public struct ReadPicoFirmwareManifest: Codable, Equatable, Sendable {
    public var board: String
    public var chip: String
    public var version: String
    public var appAddress: UInt32
    public var slotBytes: Int
    public var imageBytes: Int
    public var sha256: String
    public var kind: String
    public var deviceMAC: String?
    public var partitionSHA256: String?
    public var appBytes: Int?
    public var appSHA256: String?

    enum CodingKeys: String, CodingKey {
        case board, chip, version, sha256, kind
        case appAddress = "app_address", slotBytes = "slot_bytes", imageBytes = "image_bytes"
        case deviceMAC = "device_mac", partitionSHA256 = "partition_sha256"
        case appBytes = "app_bytes", appSHA256 = "app_sha256"
    }
    public init(version: String, imageBytes: Int, sha256: String, kind: String = "application",
                deviceMAC: String? = nil, partitionSHA256: String? = nil,
                appBytes: Int? = nil, appSHA256: String? = nil) {
        self.board = "read-pico-esp32s3"; self.chip = "esp32s3"; self.version = version
        self.appAddress = 0x20000; self.slotBytes = 0x400000
        self.imageBytes = imageBytes; self.sha256 = sha256; self.kind = kind
        self.deviceMAC = deviceMAC; self.partitionSHA256 = partitionSHA256
        self.appBytes = appBytes; self.appSHA256 = appSHA256
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decode(String.self, forKey: .board); chip = try c.decode(String.self, forKey: .chip)
        version = try c.decode(String.self, forKey: .version)
        if let number = try? c.decode(UInt32.self, forKey: .appAddress) { appAddress = number }
        else {
            let text = try c.decode(String.self, forKey: .appAddress).lowercased()
            guard let number = UInt32(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text,
                                      radix: text.hasPrefix("0x") ? 16 : 10) else {
                throw ReadPicoFirmwareError.invalid("manifest 应用地址无效。")
            }
            appAddress = number
        }
        slotBytes = try c.decode(Int.self, forKey: .slotBytes)
        imageBytes = try c.decode(Int.self, forKey: .imageBytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "application"
        deviceMAC = try c.decodeIfPresent(String.self, forKey: .deviceMAC)
        partitionSHA256 = try c.decodeIfPresent(String.self, forKey: .partitionSHA256)
        appBytes = try c.decodeIfPresent(Int.self, forKey: .appBytes)
        appSHA256 = try c.decodeIfPresent(String.self, forKey: .appSHA256)
    }
}

public struct ReadPicoImageInfo: Equatable, Sendable {
    public let version: String
    public let project: String
    public let imageBytes: Int
    public let segments: Int
    public let minimumRevision: UInt16
    public let maximumRevision: UInt16
}

public struct ReadPicoPartition: Equatable, Sendable {
    public let name: String
    public let type: UInt8
    public let subtype: UInt8
    public let offset: UInt32
    public let size: UInt32
    public let flags: UInt32
}

public enum ReadPicoFirmwareValidator {
    public static let appAddress: UInt32 = 0x20000
    public static let slotBytes = 0x400000
    public static let expectedPartitions: [ReadPicoPartition] = [
        .init(name: "nvs", type: 1, subtype: 2, offset: 0x9000, size: 0x6000, flags: 0),
        .init(name: "otadata", type: 1, subtype: 0, offset: 0xf000, size: 0x2000, flags: 0),
        .init(name: "ota_0", type: 0, subtype: 16, offset: 0x20000, size: 0x400000, flags: 0),
        .init(name: "ota_1", type: 0, subtype: 17, offset: 0x420000, size: 0x80000, flags: 0),
        .init(name: "assets", type: 1, subtype: 130, offset: 0x4a0000, size: 0x660000, flags: 0),
        .init(name: "storage", type: 1, subtype: 130, offset: 0xb00000, size: 0x500000, flags: 0)
    ]
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func require(_ ok: Bool, _ reason: String) throws {
        if !ok { throw ReadPicoFirmwareError.invalid(reason) }
    }
    private static func u16(_ a: [UInt8], _ p: Int) -> UInt16 { UInt16(a[p]) | UInt16(a[p + 1]) << 8 }
    private static func u32(_ a: [UInt8], _ p: Int) -> UInt32 {
        UInt32(a[p]) | UInt32(a[p + 1]) << 8 | UInt32(a[p + 2]) << 16 | UInt32(a[p + 3]) << 24
    }
    private static func field(_ a: [UInt8], _ range: Range<Int>) throws -> String {
        let bytes = Array(a[range].prefix(while: { $0 != 0 }))
        guard !bytes.isEmpty, let value = String(bytes: bytes, encoding: .utf8) else {
            throw ReadPicoFirmwareError.invalid("镜像文本字段无效。")
        }
        return value
    }
    /// 中文：验证真实 ESP APP，检查 XOR、附加 SHA、描述符及 64 KiB MMU 地址对齐。
    /// English: Validate ESP APP XOR, appended SHA, descriptor and 64 KiB MMU alignment.
    public static func image(_ data: Data, allowSlotTail: Bool = false) throws -> ReadPicoImageInfo {
        let a = [UInt8](data)
        try require(a.count >= 24 && a.count <= slotBytes, "只接受 4 MiB 槽内的单独 APP 镜像。")
        try require(a[0] == 0xe9 && (1...16).contains(Int(a[1])), "不是有效的 ESP 应用镜像。")
        try require(u16(a, 12) == 9, "镜像不是 ESP32-S3；禁止使用 C6 或其他板卡固件。")
        let minimum = u16(a, 15), maximum = u16(a, 17)
        try require(minimum <= 2 && maximum >= 2, "镜像不支持小纸 Pico 使用的芯片版本。")
        try require(a[2] == 2 && a[3] == 0x4f && a[23] == 1, "需要 DIO / 16 MiB / 80 MHz 并附 SHA 的 Pico APP。")
        var position = 24, checksum: UInt8 = 0xef
        var descriptor: (String, String)?
        for _ in 0..<Int(a[1]) {
            try require(position <= a.count - 8, "镜像分段头被截断。")
            let address = u32(a, position), size = Int(u32(a, position + 4)); position += 8
            try require(size <= a.count - position, "镜像分段越界。")
            let mapped = (0x3c000000..<0x3e000000).contains(address) || (0x42000000..<0x44000000).contains(address)
            try require(!mapped || address & 0xffff == (appAddress + UInt32(position)) & 0xffff,
                        "APP 与 0x20000 写入地址的 MMU 映射不匹配。")
            if size >= 4 && u32(a, position) == 0xabcd5432 {
                try require(size >= 256 && descriptor == nil, "缺少唯一完整的应用描述符。")
                try require(u32(a, position + 4) == 0 && a[position + 180] == 16, "安全版本或 MMU 页尺寸不兼容。")
                descriptor = (try field(a, position + 16..<position + 48), try field(a, position + 48..<position + 80))
            }
            for byte in a[position..<position + size] { checksum ^= byte }
            position += size
        }
        let checksumAt = position | 15
        try require(checksumAt < a.count && a[checksumAt] == checksum, "APP XOR 校验失败。")
        try require(a[position..<checksumAt].allSatisfy { $0 == 0 }, "APP 对齐填充无效。")
        let end = checksumAt + 1
        try require(a.count >= end + 32, "缺少 APP 附加 SHA-256。")
        try require(Data(SHA256.hash(data: Data(a[..<end]))) == Data(a[end..<end + 32]), "APP 内部 SHA-256 校验失败。")
        let imageEnd = end + 32
        try require(a.count == imageEnd || (allowSlotTail && a.count == slotBytes),
                    "APP 尾部含额外数据，不能把完整 Flash 镜像当作 APP。")
        guard let descriptor, descriptor.1 == "Read_Pico" else {
            throw ReadPicoFirmwareError.invalid("应用身份不是 Read_Pico。")
        }
        return .init(version: descriptor.0, project: descriptor.1, imageBytes: imageEnd,
                     segments: Int(a[1]), minimumRevision: minimum, maximumRevision: maximum)
    }
    public static func validate(_ data: Data, manifest: ReadPicoFirmwareManifest, backup: Bool = false) throws -> ReadPicoImageInfo {
        try require(manifest.board == "read-pico-esp32s3" && manifest.chip == "esp32s3" &&
                    manifest.appAddress == appAddress && manifest.slotBytes == slotBytes, "manifest 不是固定布局的小纸 Pico 固件。")
        try require(manifest.kind == (backup ? "backup" : "application"), "请选择对应的 APP 或备份清单。")
        try require(manifest.imageBytes == data.count && manifest.sha256.lowercased() == sha256(data), "文件大小或 manifest SHA-256 不匹配。")
        let info = try image(data, allowSlotTail: backup)
        try require(info.version == manifest.version, "镜像版本与 manifest 不匹配。")
        if backup {
            try require(data.count == slotBytes && manifest.appBytes == info.imageBytes &&
                        manifest.appSHA256 == sha256(data.prefix(info.imageBytes)) &&
                        manifest.deviceMAC != nil && manifest.partitionSHA256 != nil, "备份缺少完整槽或设备绑定信息。")
        }
        return info
    }
    /// 中文：限制本地文件大小；拒绝特殊文件，避免验证前把任意大文件读进内存。
    /// English: Bound local file reads and reject special files before allocating image memory.
    public static func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try require(maximumBytes > 0 && maximumBytes <= slotBytes, "文件读取上限无效。")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(url.isFileURL && attributes[.type] as? FileAttributeType == .typeRegular &&
                    ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes,
                    "请选择大小合适的普通本地固件文件。")
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        try require(data.count <= maximumBytes, "文件超过大小上限。")
        return data
    }
    /// 中文：先验证结构与 MD5；有效的不同布局与损坏的分区表必须区别处理。
    /// English: Validate structure and MD5 first; distinguish a different valid layout from corruption.
    public static func partitionLayout(_ data: Data) throws -> [ReadPicoPartition] {
        let a = [UInt8](data); try require(a.count == 0x1000, "分区表必须完整读取 4096 字节。")
        var result: [ReadPicoPartition] = []
        for p in stride(from: 0, to: a.count, by: 32) {
            let magic = u16(a, p)
            if magic == 0xebeb {
                try require(!result.isEmpty && a[p + 2..<p + 16].allSatisfy { $0 == 0xff } &&
                            Data(Insecure.MD5.hash(data: Data(a[..<p]))) == Data(a[p + 16..<p + 32]), "分区表 MD5 校验失败。")
                try require(a[(p + 32)...].allSatisfy { $0 == 0xff }, "分区表尾部无效。")
                return result
            }
            try require(magic == 0x50aa, "分区条目无效或缺少 MD5。")
            let entry = ReadPicoPartition(name: try field(a, p + 12..<p + 28), type: a[p + 2], subtype: a[p + 3],
                                         offset: u32(a, p + 4), size: u32(a, p + 8), flags: u32(a, p + 28))
            let end = UInt64(entry.offset) + UInt64(entry.size)
            try require(entry.offset >= 0x9000 && entry.offset % 4096 == 0 && entry.size > 0 && entry.size % 4096 == 0 &&
                        end <= 0x1000000 && entry.flags == 0 && (entry.type != 0 || entry.offset % 65536 == 0), "分区地址、容量或加密标记无效。")
            try require(!result.contains { $0.name == entry.name || UInt64($0.offset) < end && UInt64(entry.offset) < UInt64($0.offset) + UInt64($0.size) }, "分区名称重复或地址重叠。")
            result.append(entry)
        }
        throw ReadPicoFirmwareError.invalid("分区表缺少 MD5。")
    }
    public static func partitions(_ data: Data) throws -> [ReadPicoPartition] {
        let layout = try partitionLayout(data)
        try require(layout == expectedPartitions, "设备分区布局不是已支持的小纸 Pico 0x20000 / 4 MiB 布局。")
        return layout
    }
    /// 中文：首次安装只接受固定地址、逐文件校验的专用资源，不接受未知的全片转储。
    /// English: First install accepts a fixed-address, individually verified bundle, never an unknown dump.
    public static func freshInstallBundle(_ directory: URL) throws -> ReadPicoFreshInstallBundle {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let raw = try readFile(root.appendingPathComponent("fresh-install.json"), maximumBytes: 65536)
        let manifest = try JSONDecoder().decode(ReadPicoFreshInstallManifest.self, from: raw)
        try require(manifest.schema == 1 && manifest.kind == "first-install" && manifest.board == "read-pico-esp32s3" &&
                    manifest.chip == "esp32s3" && manifest.flashBytes == 0x1000000 && manifest.eraseFlash,
                    "首次安装清单的板卡、容量或安装类型不受支持。")
        let specifications: [String: (String, UInt32, Int)] = [
            "bootloader": ("bootloader.bin", 0, 0x8000), "partitions": ("partition-table.bin", 0x8000, 0x1000),
            "otadata": ("ota-data.bin", 0xf000, 0x2000), "application": ("read-pico-app.bin", appAddress, slotBytes),
            "assets": ("assets.bin", 0x4a0000, 0x660000), "storage": ("storage.bin", 0xb00000, 0x500000)]
        try require((4...6).contains(manifest.files.count) && Set(manifest.files.map(\.role)).count == manifest.files.count,
                    "首次安装文件缺失或重复。")
        let present = Set(manifest.files.map(\.role))
        try require(Set(["bootloader", "partitions", "otadata", "application"]).isSubset(of: present), "首次安装缺少启动或应用资源。")
        let erased = Set(manifest.erasedPartitions)
        try require(erased.count == manifest.erasedPartitions.count && erased == Set(["nvs", "ota_1"] + ["assets", "storage"].filter { !present.contains($0) }), "首次安装的清空分区声明不完整。")
        var segments: [(file: ReadPicoFreshInstallManifest.File, data: Data)] = []
        var appInfo: ReadPicoImageInfo?
        let rawAPPManifest = try readFile(root.appendingPathComponent("manifest.json"), maximumBytes: 65536)
        let appManifest = try JSONDecoder().decode(ReadPicoFirmwareManifest.self, from: rawAPPManifest)
        for file in manifest.files {
            guard let specification = specifications[file.role] else { throw ReadPicoFirmwareError.invalid("首次安装包含未知的写入区域。") }
            try require(file.file == specification.0 && file.address == specification.1 && file.bytes > 0 && file.bytes <= specification.2,
                        "首次安装文件地址或大小不匹配。")
            let url = root.appendingPathComponent(file.file)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try require(attributes[.type] as? FileAttributeType == .typeRegular && url.resolvingSymlinksInPath().deletingLastPathComponent() == root,
                        "首次安装资源必须为内置目录中的普通文件。")
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: specification.2 + 1) ?? Data()
            try require(data.count == file.bytes && sha256(data) == file.sha256.lowercased(), "首次安装资源大小或 SHA-256 不匹配。")
            switch file.role {
            case "application": appInfo = try validate(data, manifest: appManifest)
            case "partitions": _ = try partitions(data)
            case "otadata": try require(try otaSequence(data) == 1, "首次安装 OTA 必须选择首个应用槽。")
            case "bootloader": try bootloader(data)
            case "assets", "storage": try require(data.count == specification.2, "初始存储映像必须覆盖完整分区。")
            default: break
            }
            segments.append((file, data))
        }
        guard let appInfo, appInfo.version == manifest.version else { throw ReadPicoFirmwareError.invalid("首次安装版本与 APP 不一致。") }
        return .init(manifest: manifest, appInfo: appInfo, sha256: sha256(raw + rawAPPManifest), segments: segments.sorted { $0.file.address < $1.file.address })
    }
    private static func bootloader(_ data: Data) throws {
        let a = [UInt8](data)
        try require(a.count >= 24 && a.count <= 0x8000 && a[0] == 0xe9 && (1...16).contains(Int(a[1])) &&
                    u16(a, 12) == 9 && a[2] == 2 && a[3] == 0x4f && a[23] == 1 && u16(a, 15) <= 2 && u16(a, 17) >= 2,
                    "启动加载程序不是兼容的 ESP32-S3 / 16 MiB 镜像。")
        var position = 24, checksum: UInt8 = 0xef
        for _ in 0..<Int(a[1]) {
            try require(position <= a.count - 8, "启动加载程序分段被截断。")
            let size = Int(u32(a, position + 4)); position += 8
            try require(size <= a.count - position, "启动加载程序分段越界。")
            for byte in a[position..<position + size] { checksum ^= byte }; position += size
        }
        let end = (position | 15) + 1
        try require(end + 32 == a.count && a[end - 1] == checksum && a[position..<end - 1].allSatisfy { $0 == 0 } &&
                    Data(SHA256.hash(data: Data(a[..<end]))) == Data(a[end...]), "启动加载程序内部校验失败。")
    }
    /// 中文：遵循 IDF 的有效副本及最大序号选择；不写 OTA 元数据，也不改变启动槽。
    /// English: Follow IDF valid-copy/highest-sequence selection without writing OTA metadata.
    public static func otaSequence(_ data: Data) throws -> UInt32 {
        let a = [UInt8](data); try require(a.count == 0x2000, "OTA 元数据读取不完整。")
        var valid: [(UInt32, UInt32)] = []
        for p in [0, 0x1000] {
            let seq = u32(a, p), state = u32(a, p + 24), stored = u32(a, p + 28)
            var crc: UInt32 = 0
            for byte in a[p..<p + 4] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            }
            crc ^= UInt32.max
            if seq != UInt32.max && [0, 1, 2, UInt32.max].contains(state) && stored == crc { valid.append((seq, state)) }
        }
        guard let active = valid.max(by: { $0.0 < $1.0 }) else { throw ReadPicoFirmwareError.invalid("OTA 没有可确认的有效启动记录。") }
        try require(active.0 > 0 && (active.0 - 1) % 2 == 0 && active.1 != 1, "设备未稳定选择 ota_0，不能在不改 OTA 状态下安全更新。")
        return active.0
    }
    public static func security(_ text: String) throws {
        try require(text.range(of: #"(?im)^\s*Secure Boot:\s*Disabled\s*$"#, options: .regularExpression) != nil &&
                    text.range(of: #"(?im)^\s*Flash Encryption:\s*Disabled\s*$"#, options: .regularExpression) != nil,
                    "无法确认安全启动和 Flash 加密均已关闭。")
        guard let flags = capture(#"(?im)^\s*Flags:\s*0x([0-9a-f]+)"#, in: text), let value = UInt32(flags, radix: 16) else {
            throw ReadPicoFirmwareError.invalid("缺少安全状态标志。")
        }
        try require(value & 5 == 0, "设备处于安全启动或受限下载模式。")
    }
    public static func macAddress(_ text: String) throws -> String {
        guard let mac = capture(#"(?i)\bMAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b"#, in: text) else {
            throw ReadPicoFirmwareError.invalid("未能读取设备 MAC 身份。")
        }
        return mac.lowercased()
    }
    fileprivate static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

public struct ReadPicoProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}
public struct ReadPicoDeviceInfo: Equatable, Sendable {
    public let macAddress: String
    public let version: String
    public let partitionSHA256: String
    public let otaSequence: UInt32
    public let helperVersion: String
}
public struct ReadPicoFirmwareResult: Sendable {
    public let device: ReadPicoDeviceInfo
    public let imageSHA256: String
    public let bytes: Int
    public let restartError: String?
}
public struct ReadPicoFirmwareBackupResult: Sendable {
    public let directory: URL
    public let restartError: String?
}
public enum ReadPicoFirmwarePhase: Equatable, Sendable {
    case idle, preparing, readingBackup, savingBackup, writing, verifying, restarting
    public var allowsCancellation: Bool {
        self == .preparing || self == .readingBackup
    }
    public var message: String {
        switch self {
        case .idle: return ""
        case .preparing: return "正在核对文件与设备身份…"
        case .readingBackup: return "正在读取固件备份，可安全停止…"
        case .savingBackup: return "正在保存并校验备份，请稍候…"
        case .writing: return "正在写入固件，请保持 USB 连接；此阶段不能停止。"
        case .verifying: return "正在独立回读校验，请保持 USB 连接；此阶段不能停止。"
        case .restarting: return "正在请求设备启动，请稍候…"
        }
    }
}

/// 中文：可注入无设备 runner；真实执行仅使用应用内已打包的 esptool。
/// English: An injectable runner supports device-free tests; production uses bundled esptool only.
public final class ReadPicoFirmwareFlasher: @unchecked Sendable {
    public typealias Log = @Sendable (String) -> Void
    public typealias Progress = @Sendable (Double) -> Void
    public typealias PhaseHandler = @Sendable (ReadPicoFirmwarePhase) -> Void
    public typealias Runner = @Sendable (URL, [String], TimeInterval, @escaping Log) async throws -> ReadPicoProcessResult
    private let runner: Runner?
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var active = false
    private var protectedOperation = false
    private var operationPhase: ReadPicoFirmwarePhase = .idle
    private var phaseHandler: PhaseHandler = { _ in }
    private static let portsLock = NSLock()
    private static var occupiedPorts = Set<String>()
    private var usbSerialLease: ReadPicoUSBSerialLease?
    private final class WeakOperation {
        weak var value: ReadPicoFirmwareFlasher?
        init(_ value: ReadPicoFirmwareFlasher) { self.value = value }
    }
    private static var operations: [String: WeakOperation] = [:]
    private static var applicationTerminationPrepared = false
    public init(runner: Runner? = nil) { self.runner = runner }
    public static func discoverSerialPorts() -> [ESPSerialPort] {
        ESP8266FirmwareFlasher.discoverM5StickS3SerialPorts()
    }
    public static func helperURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.resourceURL?.appendingPathComponent("Firmware/lingxi-esptool"),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw ReadPicoFirmwareError.helper("缺少内置 lingxi-esptool。") }
        return url
    }
    public var phase: ReadPicoFirmwarePhase {
        lock.lock(); defer { lock.unlock() }; return operationPhase
    }
    public var canCancel: Bool {
        lock.lock(); defer { lock.unlock() }; return active && !protectedOperation && !cancelled
    }
    /// 中文：锁顺序与 begin/end 一致；写前原子门禁生效到写入、回读及启动结束。
    /// English: Use begin/end lock ordering; the atomic pre-write gate spans write, verification and run.
    public static var hasNonCancellableOperations: Bool {
        portsLock.lock(); defer { portsLock.unlock() }
        return operations.values.compactMap(\.value).contains { operation in
            operation.lock.lock(); defer { operation.lock.unlock() }
            return operation.active && operation.protectedOperation
        }
    }
    /// 中文：拒绝退出无副作用；同意时原子取消准备操作并永久阻止本次进程再注册刷写。
    /// English: Refusal has no side effects; acceptance cancels preparation and blocks future registration.
    public static func prepareForApplicationTermination() -> Bool {
        portsLock.lock()
        let current = operations.keys.sorted().compactMap { operations[$0]?.value }
        for operation in current { operation.lock.lock() }
        if current.contains(where: { $0.active && $0.protectedOperation }) {
            for operation in current.reversed() { operation.lock.unlock() }
            portsLock.unlock()
            return false
        }
        applicationTerminationPrepared = true
        var processes: [Process] = []
        for operation in current where operation.active {
            operation.cancelled = true
            if let process = operation.process { processes.append(process) }
        }
        for operation in current.reversed() { operation.lock.unlock() }
        portsLock.unlock()
        for process in processes { terminate(process) }
        return true
    }
    private static func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    @discardableResult public func cancel() -> Bool {
        lock.lock()
        guard active && !protectedOperation else { lock.unlock(); return false }
        cancelled = true; let current = process; lock.unlock()
        if let current { Self.terminate(current) }
        return true
    }
    /// 中文：应用退出钩子应调用此入口，避免辅助进程留在后台占用串口。
    /// English: Stop cancellable helpers; the quit gate must first check hasNonCancellableOperations.
    public static func cancelAllOperations() {
        portsLock.lock(); let current = operations.values.compactMap(\.value); portsLock.unlock()
        for operation in current { operation.cancel() }
    }
    private func checkCancelled() throws {
        lock.lock(); let stopped = cancelled, protected = protectedOperation; lock.unlock()
        if protected { return }
        if stopped || Task.isCancelled { throw ReadPicoFirmwareError.cancelled }
    }
    private func setPhase(_ value: ReadPicoFirmwarePhase, protect: Bool = false) throws {
        lock.lock()
        if !protectedOperation && (cancelled || Task.isCancelled) {
            lock.unlock(); throw ReadPicoFirmwareError.cancelled
        }
        if protect { protectedOperation = true }
        operationPhase = value; let handler = phaseHandler
        lock.unlock()
        handler(value)
    }
    private func begin(_ port: ESPSerialPort, phase: @escaping PhaseHandler) throws {
        guard port.path.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port.path).deletingLastPathComponent().path == "/dev" else {
            throw ReadPicoFirmwareError.invalid("请选择小纸 Pico 的原生 USB 串口。")
        }
        if runner == nil && !FileManager.default.fileExists(atPath: port.path) { throw ReadPicoFirmwareError.invalid("设备串口已断开。") }
        Self.portsLock.lock(); lock.lock()
        guard !Self.applicationTerminationPrepared else {
            lock.unlock(); Self.portsLock.unlock(); throw ReadPicoFirmwareError.cancelled
        }
        guard !active && Self.occupiedPorts.insert(port.path).inserted else {
            lock.unlock(); Self.portsLock.unlock(); throw ReadPicoFirmwareError.busy
        }
        do { usbSerialLease = try ReadPicoUSBSerialLease.acquire(path: port.path) }
        catch {
            Self.occupiedPorts.remove(port.path)
            lock.unlock(); Self.portsLock.unlock(); throw ReadPicoFirmwareError.busy
        }
        cancelled = false; active = true; protectedOperation = false
        operationPhase = .preparing; phaseHandler = phase
        Self.operations[port.path] = WeakOperation(self)
        lock.unlock(); Self.portsLock.unlock()
        phase(.preparing)
    }
    private func end(_ port: ESPSerialPort) {
        Self.portsLock.lock(); lock.lock()
        Self.occupiedPorts.remove(port.path); Self.operations.removeValue(forKey: port.path); active = false
        usbSerialLease?.release(); usbSerialLease = nil
        protectedOperation = false; operationPhase = .idle
        let handler = phaseHandler; phaseHandler = { _ in }
        lock.unlock(); Self.portsLock.unlock()
        handler(.idle)
    }
    private struct Tool {
        let version: String
        let modern: Bool
        func command(_ value: String) -> String { modern ? value.replacingOccurrences(of: "_", with: "-") : value }
        func base(_ port: ESPSerialPort, initial: Bool = false) -> [String] {
            ["--chip", "esp32s3", "--port", port.path, "--baud", "460800", "--before", command(initial ? "usb_reset" : "no_reset"),
             "--after", command("no_reset"), "--connect-attempts", "3"]
        }
    }
    private func execute(_ helper: URL, _ args: [String], timeout: TimeInterval = 90, log: @escaping Log) async throws -> String {
        try checkCancelled()
        let result: ReadPicoProcessResult
        result = try await withTaskCancellationHandler {
            if let runner { return try await runner(helper, args, timeout, log) }
            return try await runProcess(helper, args, timeout, log)
        } onCancel: { self.cancel() }
        try checkCancelled()
        guard result.status == 0 else { throw ReadPicoFirmwareError.helper(result.output.split(whereSeparator: \.isNewline).suffix(6).joined(separator: " ")) }
        return result.output
    }
    private func tool(_ helper: URL, log: @escaping Log) async throws -> Tool {
        if runner == nil && !FileManager.default.isExecutableFile(atPath: helper.path) { throw ReadPicoFirmwareError.helper("内置助手不可执行。") }
        let output = try await execute(helper, ["version"], timeout: 15, log: log)
        guard let version = ReadPicoFirmwareValidator.capture(#"(?i)(?:^|[\s:])v?([45]\.\d+(?:\.\d+)?)\b"#, in: output) else {
            throw ReadPicoFirmwareError.helper("仅支持已核对命令格式的 esptool 4.x / 5.x。")
        }
        let modern = version.hasPrefix("5.")
        let help = try await execute(helper, ["--help"], timeout: 15, log: { _ in })
        let result = Tool(version: version, modern: modern)
        for command in ["read_mac", "get_security_info", "flash_id", "read_flash", "verify_flash", "write_flash", "run"] {
            guard help.contains(result.command(command)) else { throw ReadPicoFirmwareError.helper("助手缺少必要命令 \(command)。") }
        }
        return result
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-pico-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func command(_ tool: Tool, _ helper: URL, _ port: ESPSerialPort, _ name: String, _ args: [String] = [], initial: Bool = false, timeout: TimeInterval = 90, log: @escaping Log) async throws -> String {
        try await execute(helper, tool.base(port, initial: initial) + [tool.command(name)] + args, timeout: timeout, log: log)
    }
    private func read(_ tool: Tool, _ helper: URL, _ port: ESPSerialPort, address: UInt32, bytes: Int, to url: URL, log: @escaping Log) async throws -> Data {
        _ = try await command(tool, helper, port, "read_flash", [String(format: "0x%x", address), String(bytes), url.path], timeout: bytes > 0x2000 ? 240 : 60, log: log)
        let data = try Data(contentsOf: url)
        guard data.count == bytes else { throw ReadPicoFirmwareError.invalid("设备读取长度不符。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }
    private func inspectLayout(_ tool: Tool, _ helper: URL, _ port: ESPSerialPort, _ dir: URL, log: @escaping Log) async throws -> (String, Data, [ReadPicoPartition]) {
        let identity = try await command(tool, helper, port, "read_mac", initial: true, log: log)
        guard identity.range(of: #"(?i)\bChip(?: is| type:)?\s*ESP32-S3\b"#, options: .regularExpression) != nil else {
            throw ReadPicoFirmwareError.invalid("未确认设备芯片为 ESP32-S3。")
        }
        let mac = try ReadPicoFirmwareValidator.macAddress(identity)
        try ReadPicoFirmwareValidator.security(try await command(tool, helper, port, "get_security_info", log: log))
        let flash = try await command(tool, helper, port, "flash_id", log: log)
        guard flash.range(of: #"(?i)Detected flash size:\s*16\s*MB\b"#, options: .regularExpression) != nil else {
            throw ReadPicoFirmwareError.invalid("未确认设备具备 16 MiB Flash。")
        }
        let table = try await read(tool, helper, port, address: 0x8000, bytes: 0x1000, to: dir.appendingPathComponent("partitions.bin"), log: log)
        let layout = try ReadPicoFirmwareValidator.partitionLayout(table)
        // 中文：不同分区也必须从真实应用描述符确认 Pico，不能只靠通用芯片型号。
        // English: Even a different layout must carry an actual Pico APP descriptor, not merely the same chip.
        if layout != ReadPicoFirmwareValidator.expectedPartitions {
            var picoConfirmed = false
            for entry in layout.filter({ $0.type == 0 }) {
                let header = try await read(tool, helper, port, address: entry.offset, bytes: 0x1000,
                                            to: dir.appendingPathComponent("old-app-\(entry.offset).bin"), log: log)
                let a = [UInt8](header)
                if a[0] == 0xe9 && a[12] == 9 && a[13] == 0 && Array(a[32..<36]) == [0x32, 0x54, 0xcd, 0xab] &&
                    String(bytes: a[80..<112].prefix(while: { $0 != 0 }), encoding: .utf8) == "Read_Pico" {
                    picoConfirmed = true; break
                }
            }
            guard picoConfirmed else { throw ReadPicoFirmwareError.invalid("不同分区中的应用身份无法确认为 Read_Pico，不能提供首次安装。") }
        }
        return (mac, table, layout)
    }
    private func inspect(_ tool: Tool, _ helper: URL, _ port: ESPSerialPort, _ dir: URL, targetBundleSHA256: String? = nil, log: @escaping Log) async throws -> (ReadPicoDeviceInfo, Data, Data) {
        let (mac, table, layout) = try await inspectLayout(tool, helper, port, dir, log: log)
        if layout != ReadPicoFirmwareValidator.expectedPartitions {
            throw ReadPicoFirmwareError.partitionMismatch(.init(portPath: port.path, macAddress: mac,
                partitionSHA256: ReadPicoFirmwareValidator.sha256(table), partitions: layout, targetBundleSHA256: targetBundleSHA256))
        }
        let ota = try await read(tool, helper, port, address: 0xf000, bytes: 0x2000, to: dir.appendingPathComponent("ota.bin"), log: log)
        let sequence = try ReadPicoFirmwareValidator.otaSequence(ota)
        let header = try await read(tool, helper, port, address: 0x20000, bytes: 0x1000, to: dir.appendingPathComponent("identity.bin"), log: log)
        let a = [UInt8](header)
        // 中文：真实现有 APP 的首个数据段是 esp_app_desc，不用 USB VID/PID 猜测板卡。
        // English: Identify the board from its existing first-segment esp_app_desc, never USB VID/PID.
        guard a[0] == 0xe9, a[12] == 9, a[13] == 0, Array(a[32..<36]) == [0x32, 0x54, 0xcd, 0xab],
              String(bytes: a[80..<112].prefix(while: { $0 != 0 }), encoding: .utf8) == "Read_Pico",
              let version = String(bytes: a[48..<80].prefix(while: { $0 != 0 }), encoding: .utf8), !version.isEmpty else {
            throw ReadPicoFirmwareError.invalid("设备现有 APP 身份不是 Read_Pico，已停止。")
        }
        return (.init(macAddress: mac, version: version, partitionSHA256: ReadPicoFirmwareValidator.sha256(table), otaSequence: sequence, helperVersion: tool.version), table, ota)
    }
    public func inspect(port: ESPSerialPort, helperURL: URL, phase: @escaping PhaseHandler = { _ in }, log: @escaping Log = { _ in }) async throws -> ReadPicoDeviceInfo {
        try begin(port, phase: phase); defer { end(port) }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = try await tool(helperURL, log: log)
        let info = try await inspect(t, helperURL, port, dir, log: log).0
        try setPhase(.restarting, protect: true)
        _ = try await command(t, helperURL, port, "run", log: log)
        return info
    }
    public func flash(port: ESPSerialPort, helperURL: URL, imageURL: URL, manifestURL: URL, freshInstallDirectory: URL? = nil,
                      progress: @escaping Progress = { _ in }, phase: @escaping PhaseHandler = { _ in }, log: @escaping Log = { _ in }) async throws -> ReadPicoFirmwareResult {
        try await install(port: port, helperURL: helperURL, imageURL: imageURL, manifestURL: manifestURL, restoring: false, freshInstallDirectory: freshInstallDirectory, progress: progress, phase: phase, log: log)
    }
    public func restore(port: ESPSerialPort, helperURL: URL, imageURL: URL, manifestURL: URL,
                        progress: @escaping Progress = { _ in }, phase: @escaping PhaseHandler = { _ in }, log: @escaping Log = { _ in }) async throws -> ReadPicoFirmwareResult {
        try await install(port: port, helperURL: helperURL, imageURL: imageURL, manifestURL: manifestURL, restoring: true, progress: progress, phase: phase, log: log)
    }
    private func install(port: ESPSerialPort, helperURL: URL, imageURL: URL, manifestURL: URL, restoring: Bool, freshInstallDirectory: URL? = nil,
                         progress: @escaping Progress, phase: @escaping PhaseHandler, log: @escaping Log) async throws -> ReadPicoFirmwareResult {
        try begin(port, phase: phase); defer { end(port) }
        let manifest = try JSONDecoder().decode(ReadPicoFirmwareManifest.self, from: ReadPicoFirmwareValidator.readFile(manifestURL, maximumBytes: 65536))
        let data = try ReadPicoFirmwareValidator.readFile(imageURL, maximumBytes: ReadPicoFirmwareValidator.slotBytes)
        let image = try ReadPicoFirmwareValidator.validate(data, manifest: manifest, backup: restoring)
        var targetBundleSHA256: String?
        if let freshInstallDirectory, !restoring {
            let fresh = try ReadPicoFirmwareValidator.freshInstallBundle(freshInstallDirectory)
            guard fresh.appInfo.version == image.version && fresh.segments.first(where: { $0.file.role == "application" })?.data == data else {
                throw ReadPicoFirmwareError.invalid("首次安装资源与所选 APP 不一致。")
            }
            targetBundleSHA256 = fresh.sha256
        }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("app.bin")
        let app = data.prefix(image.imageBytes)
        try app.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        progress(0.05)
        let t = try await tool(helperURL, log: log)
        let (device, table, ota) = try await inspect(t, helperURL, port, dir, targetBundleSHA256: targetBundleSHA256, log: log)
        if restoring && (manifest.deviceMAC?.lowercased() != device.macAddress || manifest.partitionSHA256 != device.partitionSHA256) {
            throw ReadPicoFirmwareError.invalid("备份属于另一台设备或不同分区布局。")
        }
        progress(0.2)
        guard try Data(contentsOf: staged) == app else { throw ReadPicoFirmwareError.invalid("暂存 APP 校验失败。") }
        let beforeWriteMAC = try ReadPicoFirmwareValidator.macAddress(try await command(t, helperURL, port, "read_mac", log: log))
        guard beforeWriteMAC == device.macAddress else { throw ReadPicoFirmwareError.invalid("准备期间设备已更换，已停止写入。") }
        try setPhase(.writing, protect: true)
        _ = try await command(t, helperURL, port, "write_flash", [t.command("--flash_mode"), "keep", t.command("--flash_freq"), "keep", t.command("--flash_size"), "keep", "0x20000", staged.path], timeout: 240, log: log)
        progress(0.75)
        try setPhase(.verifying)
        // 中文：独立回读逐字节比较 APP；再回读 PT 与 OTA，写入成功不等于校验成功。
        // English: Independently read/compare APP, PT and OTA; a successful write is not verification.
        let verified = try await read(t, helperURL, port, address: 0x20000, bytes: app.count, to: dir.appendingPathComponent("verify-app.bin"), log: log)
        guard verified == app else { throw ReadPicoFirmwareError.invalid("APP 回读校验失败，不启动设备。") }
        let tableAfter = try await read(t, helperURL, port, address: 0x8000, bytes: 0x1000, to: dir.appendingPathComponent("verify-partitions.bin"), log: log)
        let otaAfter = try await read(t, helperURL, port, address: 0xf000, bytes: 0x2000, to: dir.appendingPathComponent("verify-ota.bin"), log: log)
        guard tableAfter == table && otaAfter == ota else { throw ReadPicoFirmwareError.invalid("分区或 OTA 元数据发生变化，不启动设备。") }
        progress(0.95)
        try setPhase(.restarting)
        var restartError: String?
        do { _ = try await command(t, helperURL, port, "run", log: log) }
        catch { restartError = error.localizedDescription }
        progress(1)
        return .init(device: device, imageSHA256: ReadPicoFirmwareValidator.sha256(app), bytes: app.count, restartError: restartError)
    }
    /// 中文：仅在用户确认分区不匹配提示后调用；再次核对确认时的设备和分区，擦除前仍可停止。
    /// English: Call only after explicit mismatch consent; recheck the bound device and layout before erasing.
    public func freshInstall(port: ESPSerialPort, helperURL: URL, bundleDirectory: URL, confirmation: ReadPicoPartitionMismatch,
                             progress: @escaping Progress = { _ in }, phase: @escaping PhaseHandler = { _ in }, log: @escaping Log = { _ in }) async throws -> ReadPicoFirmwareResult {
        try begin(port, phase: phase); defer { end(port) }
        guard confirmation.portPath == port.path else { throw ReadPicoFirmwareError.invalid("确认的串口已更换，请重新核对设备。") }
        let bundle = try ReadPicoFirmwareValidator.freshInstallBundle(bundleDirectory)
        guard confirmation.targetBundleSHA256 == bundle.sha256 else {
            throw ReadPicoFirmwareError.invalid("首次安装资源已变化，请重新核对并确认。")
        }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var staged: [(ReadPicoFreshInstallManifest.File, Data, URL)] = []
        for segment in bundle.segments {
            let url = dir.appendingPathComponent(segment.file.file)
            try segment.data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            staged.append((segment.file, segment.data, url))
        }
        let t = try await tool(helperURL, log: log)
        let help = try await execute(helperURL, ["--help"], timeout: 15, log: { _ in })
        guard help.contains(t.command("erase_flash")) else { throw ReadPicoFirmwareError.helper("助手不支持首次全新安装。") }
        let (mac, table, layout) = try await inspectLayout(t, helperURL, port, dir, log: log)
        guard mac == confirmation.macAddress && ReadPicoFirmwareValidator.sha256(table) == confirmation.partitionSHA256 &&
                layout == confirmation.partitions && layout != ReadPicoFirmwareValidator.expectedPartitions else {
            throw ReadPicoFirmwareError.invalid("设备身份或分区已变化，请重新核对并确认首次全新安装。")
        }
        for (_, data, url) in staged {
            guard try Data(contentsOf: url) == data else { throw ReadPicoFirmwareError.invalid("首次安装暂存文件校验失败。") }
        }
        let finalMAC = try ReadPicoFirmwareValidator.macAddress(try await command(t, helperURL, port, "read_mac", log: log))
        guard finalMAC == mac else { throw ReadPicoFirmwareError.invalid("准备期间设备已更换，已停止。") }
        progress(0.1)
        try setPhase(.writing, protect: true)
        _ = try await command(t, helperURL, port, "erase_flash", timeout: 240, log: log)
        var arguments = [t.command("--flash_mode"), "keep", t.command("--flash_freq"), "keep", t.command("--flash_size"), "keep"]
        for (file, _, url) in staged { arguments += [String(format: "0x%x", file.address), url.path] }
        _ = try await command(t, helperURL, port, "write_flash", arguments, timeout: 480, log: log)
        progress(0.7); try setPhase(.verifying)
        for (index, segment) in staged.enumerated() {
            let (file, data, _) = segment
            let verified = try await read(t, helperURL, port, address: file.address, bytes: data.count,
                                          to: dir.appendingPathComponent("verify-" + file.file), log: log)
            guard verified == data else { throw ReadPicoFirmwareError.invalid("首次安装 \(file.role) 回读失败，不启动设备。") }
            progress(0.7 + 0.25 * Double(index + 1) / Double(staged.count))
        }
        for name in bundle.manifest.erasedPartitions {
            let partition = ReadPicoFirmwareValidator.expectedPartitions.first { $0.name == name }!
            let cleared = try await read(t, helperURL, port, address: partition.offset, bytes: Int(partition.size),
                                         to: dir.appendingPathComponent("verify-erased-" + name + ".bin"), log: log)
            guard cleared.allSatisfy({ $0 == 0xff }) else { throw ReadPicoFirmwareError.invalid("首次安装内部数据清理校验失败，不启动设备。") }
        }
        let app = staged.first { $0.0.role == "application" }!.1
        let installedPT = staged.first { $0.0.role == "partitions" }!.1
        let device = ReadPicoDeviceInfo(macAddress: mac, version: bundle.manifest.version,
            partitionSHA256: ReadPicoFirmwareValidator.sha256(installedPT), otaSequence: 1, helperVersion: t.version)
        try setPhase(.restarting)
        var restartError: String?
        do { _ = try await command(t, helperURL, port, "run", log: log) } catch { restartError = error.localizedDescription }
        progress(1)
        return .init(device: device, imageSHA256: ReadPicoFirmwareValidator.sha256(app), bytes: staged.reduce(0) { $0 + $1.1.count }, restartError: restartError)
    }
    public func backup(port: ESPSerialPort, helperURL: URL, directory: URL,
                       progress: @escaping Progress = { _ in }, phase: @escaping PhaseHandler = { _ in }, log: @escaping Log = { _ in }) async throws -> ReadPicoFirmwareBackupResult {
        try begin(port, phase: phase); defer { end(port) }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = try await tool(helperURL, log: log)
        let (device, _, _) = try await inspect(t, helperURL, port, dir, log: log)
        progress(0.15)
        try setPhase(.readingBackup)
        let data = try await read(t, helperURL, port, address: 0x20000, bytes: ReadPicoFirmwareValidator.slotBytes, to: dir.appendingPathComponent("slot.bin"), log: log)
        let image = try ReadPicoFirmwareValidator.image(data, allowSlotTail: true)
        let manifest = ReadPicoFirmwareManifest(version: image.version, imageBytes: data.count,
            sha256: ReadPicoFirmwareValidator.sha256(data), kind: "backup", deviceMAC: device.macAddress,
            partitionSHA256: device.partitionSHA256, appBytes: image.imageBytes,
            appSHA256: ReadPicoFirmwareValidator.sha256(data.prefix(image.imageBytes)))
        let destination = directory.appendingPathComponent("ReadPico-backup-\(device.macAddress.replacingOccurrences(of: ":", with: ""))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try setPhase(.savingBackup, protect: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let imageURL = destination.appendingPathComponent("ota_0.bin")
            try data.write(to: imageURL, options: .atomic)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestURL = destination.appendingPathComponent("manifest.json")
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            for url in [imageURL, manifestURL] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            _ = try ReadPicoFirmwareValidator.validate(Data(contentsOf: imageURL), manifest: JSONDecoder().decode(ReadPicoFirmwareManifest.self, from: Data(contentsOf: manifestURL)), backup: true)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        progress(0.95)
        try setPhase(.restarting)
        var restartError: String?
        do { _ = try await command(t, helperURL, port, "run", log: log) }
        catch { restartError = error.localizedDescription }
        progress(1); return .init(directory: destination, restartError: restartError)
    }
    // 中文：模块内也供离线子进程故障测试复用，不开放串口测试旁路。
    // English: Reuse the process path in offline fault tests without exposing a serial bypass.
    func runProcess(_ helper: URL, _ arguments: [String], _ timeout: TimeInterval, _ log: @escaping Log) async throws -> ReadPicoProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process(), pipe = Pipe()
                task.executableURL = helper; task.arguments = arguments
                task.standardOutput = pipe; task.standardError = pipe
                self.lock.lock(); self.process = task; let stopped = self.cancelled; self.lock.unlock()
                defer { self.lock.lock(); if self.process === task { self.process = nil }; self.lock.unlock() }
                if stopped { continuation.resume(throwing: ReadPicoFirmwareError.cancelled); return }
                do { try task.run() } catch { continuation.resume(throwing: ReadPicoFirmwareError.helper(error.localizedDescription)); return }
                self.lock.lock(); let cancelledAfterLaunch = self.cancelled; self.lock.unlock()
                if cancelledAfterLaunch { self.cancel() }
                let deadline = DispatchWorkItem {
                    if task.isRunning {
                        task.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                var output = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    output.append(chunk); log(String(decoding: chunk, as: UTF8.self))
                }
                task.waitUntilExit(); deadline.cancel()
                continuation.resume(returning: .init(status: task.terminationStatus, output: String(decoding: output, as: UTF8.self)))
            }
        }
    }
}
