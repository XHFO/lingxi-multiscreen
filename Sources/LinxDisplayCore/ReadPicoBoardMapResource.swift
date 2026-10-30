import Foundation
import CryptoKit

/// The same bounded geometry file is embedded in semantic snapshots, never rendered into a screenshot.
public enum ReadPicoBoardMapResource {
    private static let cached: Result<Data, Error> = Result {
        let bundled = Bundle.main.url(forResource: "cloudflare-world-dots", withExtension: "bwm", subdirectory: "PicoBoard")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/PicoBoard/cloudflare-world-dots.bwm")
        guard let url = bundled ?? (Bundle.main.bundleURL.pathExtension != "app" ? source : nil),
              let data = try? Data(contentsOf: url), data.count == 4588,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == "8cbb9e3583e5a452a4c526d860e5ea9d5ea4171d785b789e4e9453c48788dcb1" else {
            throw ReadPicoManagerError.unavailable("世界热区地图资源缺失，请重新安装完整多屏灵犀软件包。")
        }
        return data
    }
    public static func data() throws -> Data { try cached.get() }
}
