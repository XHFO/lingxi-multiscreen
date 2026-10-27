import Foundation

@main struct BundledAppsTests {
    static func main() async throws {
        let fm = FileManager.default
        let resources = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Firmware/ReadPico")
        let temporary = fm.temporaryDirectory.appendingPathComponent("pico-catalog-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func fixture(_ name: String) throws -> URL {
            let root = temporary.appendingPathComponent(name)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for file in ["manifest.json", "tf-manifest.json", "tf-card"] {
                try fm.copyItem(at: resources.appendingPathComponent(file), to: root.appendingPathComponent(file))
            }
            return root
        }
        func reject(_ label: String, root: URL) {
            do { _ = try ReadPicoBundledApps.load(directory: root); fatalError("accepted " + label) }
            catch { checks += 1 }
        }
        let apps = try ReadPicoBundledApps.load(directory: resources)
        check(apps.count == 7, "seven bundled games/tools")
        check(Set(apps.map(\.id)) == ["gomoku", "go", "xiangqi", "chess", "2048", "snake", "drawing-notes"], "catalog IDs come from real package headers")
        check(apps.allSatisfy { $0.package.targets.contains("esp32s3-xtensa") }, "every package supports physical Pico")
        check(apps.filter { $0.package.isTool }.count == 1, "six games and one drawing tool")
        let card = temporary.appendingPathComponent("card"); try fm.createDirectory(at: card, withIntermediateDirectories: true)
        let store = try ReadPicoTFStore(rootURL: card)
        for app in apps {
            check(try await store.importFile(app.url, kind: .application) == app.relativePath, "stable manifest destination")
            let saves = card.appendingPathComponent("apps/data/" + app.id)
            try fm.createDirectory(at: saves, withIntermediateDirectories: true)
            try Data(("save:" + app.id).utf8).write(to: saves.appendingPathComponent("save.bin"))
            check(try Data(contentsOf: card.appendingPathComponent(app.relativePath)) == Data(contentsOf: app.url), "installed package exact bytes")
        }
        check(try await store.scan().filter { $0.kind == .application && $0.valid }.count == 7, "seven valid TF applications after install")
        for app in apps {
            try await store.importFile(app.url, kind: .application, replace: true)
            check(try Data(contentsOf: card.appendingPathComponent("apps/data/" + app.id + "/save.bin")) == Data(("save:" + app.id).utf8), "update preserves separate save")
        }
        let installed = try await store.scan().filter { $0.kind == .application }
        for file in installed { try await store.remove(file) }
        check(try await store.scan().filter { $0.kind == .application }.isEmpty, "all applications removed")
        for app in apps {
            check(try Data(contentsOf: card.appendingPathComponent("apps/data/" + app.id + "/save.bin")) == Data(("save:" + app.id).utf8), "remove preserves independent game/drawing saves")
        }
        let versionRoot = try fixture("version")
        try Data(#"{"version":"0.0.0-other"}"#.utf8).write(to: versionRoot.appendingPathComponent("manifest.json"))
        reject("mismatching firmware generation", root: versionRoot)
        let corruptRoot = try fixture("hash")
        var corrupt = try Data(contentsOf: corruptRoot.appendingPathComponent("tf-card/" + apps[0].relativePath)); corrupt[512] ^= 1
        try corrupt.write(to: corruptRoot.appendingPathComponent("tf-card/" + apps[0].relativePath))
        reject("damaged package", root: corruptRoot)
        let missingRoot = try fixture("missing")
        try fm.removeItem(at: missingRoot.appendingPathComponent("tf-card/" + apps[0].relativePath))
        reject("missing package", root: missingRoot)
        let symlinkRoot = try fixture("symlink")
        let link = symlinkRoot.appendingPathComponent("tf-card/" + apps[0].relativePath)
        try fm.removeItem(at: link); try fm.createSymbolicLink(at: link, withDestinationURL: apps[0].url)
        reject("symbolic package link", root: symlinkRoot)
        for (name, key, value) in [("path", "path", "../outside.pga" as Any), ("id", "id", "unexpected" as Any), ("kind", "kind", 255 as Any), ("target", "targets", ["macos-arm64"] as Any)] {
            let root = try fixture(name), url = root.appendingPathComponent("tf-manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var packages = manifest["packages"] as! [[String: Any]]
            packages[0][key] = value; manifest["packages"] = packages
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            reject("manifest " + name + " mismatch", root: root)
        }
        print("PASS: \(checks) bundled catalog/header/hash/path validation and seven-package temporary-TF add/update/remove/save-preservation checks; source resources untouched.")
    }
}
