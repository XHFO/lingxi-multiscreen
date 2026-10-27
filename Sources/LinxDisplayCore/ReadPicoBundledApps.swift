import Foundation
import CryptoKit

public struct ReadPicoBundledApplication: Identifiable, Sendable {
    public let package: ReadPicoPackage
    public let url: URL
    public let relativePath: String
    public var id: String { package.id }
}

/// Uses the package header and checked resource manifest, rather than a second app-name registry.
public enum ReadPicoBundledApps {
    private struct FirmwareVersion: Decodable { let version: String }
    private struct Manifest: Decodable {
        struct Item: Decodable { let path: String, id: String, bytes: Int, sha256: String, kind: Int, targets: [String] }
        let version: String, packages: [Item]
    }
    public static func load(directory: URL) throws -> [ReadPicoBundledApplication] {
        let firmware = try JSONDecoder().decode(FirmwareVersion.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("tf-manifest.json")))
        guard firmware.version == manifest.version, !manifest.packages.isEmpty, manifest.packages.count <= 64 else {
            throw ReadPicoManagerError.invalid("内置功能包与固件版本不一致，请重新下载完整测试软件。")
        }
        let root = directory.appendingPathComponent("tf-card", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var ids = Set<String>(), paths = Set<String>()
        return try manifest.packages.map { item in
            let path = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 3, path[0] == "apps", ["games", "tools"].contains(String(path[1])),
                  path[2] == Substring(item.id + ".pga"), ids.insert(item.id).inserted, paths.insert(item.path).inserted else {
                throw ReadPicoManagerError.invalid("内置功能包目录无效。")
            }
            let url = root.appendingPathComponent(item.path)
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true, value.fileSize == item.bytes,
                  (512...4 * 1024 * 1024).contains(item.bytes),
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw ReadPicoManagerError.invalid("内置功能包缺失或路径无效。")
            }
            let data = try Data(contentsOf: url)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256.lowercased() else {
                throw ReadPicoManagerError.invalid("内置功能包校验失败，请重新下载软件。")
            }
            let package = try ReadPicoPackage(data: data)
            guard package.id == item.id, package.kind == item.kind, package.targets == item.targets,
                  String(path[1]) == (package.isTool ? "tools" : "games") else {
                throw ReadPicoManagerError.invalid("内置功能包身份或设备目标不匹配。")
            }
            return ReadPicoBundledApplication(package: package, url: url, relativePath: item.path)
        }
    }
}
