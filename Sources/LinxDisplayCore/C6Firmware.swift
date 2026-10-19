import Foundation
import CryptoKit

public enum EmbeddedC6Firmware {
    public static let version = "2.0.0-alpha.20"
    public static let fullName = "lingxi-c6-2.0.0-full.bin"
    public static let otaName = "lingxi-c6-2.0.0-ota.bin"
    public static func resource(ota: Bool, bundle: Bundle = .main) throws -> (url: URL, data: Data, sha256: String) {
        guard let directory = bundle.resourceURL?.appendingPathComponent("Firmware"),
              let manifestData = try? Data(contentsOf: directory.appendingPathComponent("c6-manifest.json")),
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: String],
              manifest["version"] == version,
              let expected = manifest[ota ? "ota_sha256" : "full_sha256"] else {
            throw ESP8266FlashError.missingResource("C6 内置固件")
        }
        let url = directory.appendingPathComponent(ota ? otaName : fullName)
        let data = try Data(contentsOf: url)
        guard validate(data, ota: ota, sha256: expected) else { throw ESP8266FlashError.invalidFirmware }
        return (url, data, expected)
    }
    public static func validate(_ data: Data, ota: Bool, sha256: String) -> Bool {
        let appOffset = ota ? 0 : 0x20000
        guard data.count > appOffset + 24, data[appOffset] == 0xe9,
              data[appOffset + 12] == 13, data[appOffset + 13] == 0,
              ota || (data[0] == 0xe9 && data[0x8000] == 0xaa && data[0x8001] == 0x50) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
    /// Never write the merged-image padding over NVS (0x9000...0xefff).
    public static func flashRegions(from data: Data) throws -> [(address: Int, data: Data)] {
        guard data.count > 0x20018, data.count <= 0x20000 + 0x1e0000,
              data[0] == 0xe9, data[0x8000] == 0xaa, data[0x8001] == 0x50,
              data[0x20000] == 0xe9, data[0x2000c] == 13 else { throw ESP8266FlashError.invalidFirmware }
        return [(0, data.subdata(in: 0..<0x8000)),
                (0x8000, data.subdata(in: 0x8000..<0x9000)),
                (0x10000, data.subdata(in: 0x10000..<0x12000)),
                (0x20000, data.subdata(in: 0x20000..<data.count))]
    }
}
