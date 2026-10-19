import Foundation

public enum C6FlashNetworkMode: String, CaseIterable, Identifiable, Sendable {
    case preserve, replace
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .preserve: return "保留设备现有网络配置（无需密码）"
        case .replace: return "写入新的 2.4 GHz Wi-Fi 配置"
        }
    }
}

public enum C6WiFiProvisioningError: Error, LocalizedError, Equatable {
    case emptySSID, ssidTooLong, invalidSSID, invalidPassword, invalidImage, overlappingFlashRegion

    public var errorDescription: String? {
        switch self {
        case .emptySSID: return "请选择或填写 2.4 GHz Wi-Fi 名称（SSID）。"
        case .ssidTooLong: return "Wi-Fi 名称不能超过 32 个 UTF-8 字节。"
        case .invalidSSID: return "Wi-Fi 名称不能包含空字符。"
        case .invalidPassword: return "密码可留空（开放网络），或为 8–63 个 UTF-8 字节；64 位密码须为十六进制 PSK。"
        case .invalidImage: return "C6 临时 Wi-Fi 配网数据无效，已停止刷写。"
        case .overlappingFlashRegion: return "C6 配网区与固件区域重叠，已停止刷写。"
        }
    }
}

/// Dedicated, one-use C6 provisioning sector. It is not part of the embedded
/// firmware resource and does not replace NVS, pairing or standalone settings.
public enum C6WiFiProvisioning {
    public static let flashAddress = 0x3f0000
    public static let sectorBytes = 4096
    public static let recordBytes = 116
    private static let magic = Data("LXC6WF01".utf8)

    /// Preserve mode deliberately ignores any stale form input and produces
    /// no provisioning sector. Never read Wi-Fi passwords from the Mac.
    public static func makeImage(networkMode: C6FlashNetworkMode, ssid: String, password: String) throws -> Data? {
        guard networkMode == .replace else { return nil }
        return try makeImage(ssid: ssid, password: password)
    }

    public static func validateCredentials(ssid: String, password: String) throws {
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        guard !ssidBytes.isEmpty else { throw C6WiFiProvisioningError.emptySSID }
        guard ssidBytes.count <= 32 else { throw C6WiFiProvisioningError.ssidTooLong }
        guard !ssidBytes.contains(0) else { throw C6WiFiProvisioningError.invalidSSID }
        guard !passwordBytes.contains(0), passwordBytes.isEmpty
                || (8...63).contains(passwordBytes.count)
                || (passwordBytes.count == 64 && passwordBytes.allSatisfy(isHexDigit)) else {
            throw C6WiFiProvisioningError.invalidPassword
        }
    }

    public static func makeImage(ssid: String, password: String) throws -> Data {
        try validateCredentials(ssid: ssid, password: password)
        let ssidBytes = Data(ssid.utf8), passwordBytes = Data(password.utf8)
        var record = magic
        record.append(contentsOf: [1, UInt8(ssidBytes.count), UInt8(passwordBytes.count), 0])
        record.append(fixedField(ssidBytes, count: 33))
        record.append(fixedField(passwordBytes, count: 65))
        record.append(contentsOf: [0, 0])
        let checksum = crc32(record)
        for shift in stride(from: 0, through: 24, by: 8) {
            record.append(UInt8(truncatingIfNeeded: checksum >> UInt32(shift)))
        }
        precondition(record.count == recordBytes)
        record.append(Data(repeating: 0xff, count: sectorBytes - recordBytes))
        return record
    }

    public static func validateImage(_ image: Data) -> Bool {
        guard image.count == sectorBytes, image.prefix(8) == magic,
              image[8] == 1, (1...32).contains(Int(image[9])), image[11] == 0,
              image[110] == 0, image[111] == 0,
              image[recordBytes...].allSatisfy({ $0 == 0xff }) else { return false }
        let ssidLength = Int(image[9]), passwordLength = Int(image[10])
        guard passwordLength <= 64,
              image[(12 + ssidLength)..<45].allSatisfy({ $0 == 0 }),
              image[(45 + passwordLength)..<110].allSatisfy({ $0 == 0 }),
              let ssid = String(data: image.subdata(in: 12..<(12 + ssidLength)), encoding: .utf8),
              let password = String(data: image.subdata(in: 45..<(45 + passwordLength)), encoding: .utf8),
              (try? validateCredentials(ssid: ssid, password: password)) != nil else { return false }
        let stored = UInt32(image[112]) | UInt32(image[113]) << 8
            | UInt32(image[114]) << 16 | UInt32(image[115]) << 24
        return stored == crc32(image.prefix(112))
    }

    /// Keeps the existing segmented, NVS-preserving USB flash plan. Only the
    /// dedicated sector is appended when the user chooses Wi-Fi provisioning.
    public static func flashRegions(from firmware: Data, image: Data?) throws -> [(address: Int, data: Data)] {
        var regions = try EmbeddedC6Firmware.flashRegions(from: firmware)
        guard let image else { return regions }
        guard validateImage(image) else { throw C6WiFiProvisioningError.invalidImage }
        guard regions.allSatisfy({ $0.address + $0.data.count <= flashAddress
            || $0.address >= flashAddress + sectorBytes }) else {
            throw C6WiFiProvisioningError.overlappingFlashRegion
        }
        regions.append((flashAddress, image))
        return regions
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
    private static func fixedField(_ value: Data, count: Int) -> Data {
        var result = Data(repeating: 0, count: count)
        result.replaceSubrange(0..<value.count, with: value)
        return result
    }
    private static func crc32<T: DataProtocol>(_ data: T) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ UInt32.max
    }
}
