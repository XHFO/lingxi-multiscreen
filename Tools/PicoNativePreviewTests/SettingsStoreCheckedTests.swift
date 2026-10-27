import Foundation
import LinxDisplayCore

/// Links the actual current Release Core product. All paths are temporary and isolated.
@main struct SettingsStoreCheckedTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("lingxi-settings-checked-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        var checks = 0
        var failures = [[String: Any]]()
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS " + message)
        }
        func expectFailure(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(name + " unexpectedly succeeded") }
            catch {
                let failure = error as NSError
                failures.append(["case": name, "domain": failure.domain, "code": failure.code])
                checks += 1; print("PASS " + name + " throws " + failure.domain + ":" + String(failure.code))
            }
        }
        let store = SettingsStore(dataDirectory: temporary.appendingPathComponent("settings-root", isDirectory: true))
        check(store.dataDirectory.path.hasPrefix(temporary.path + "/"), "all settings paths stay inside the temporary root")
        check(!fm.fileExists(atPath: store.dataDirectory.path), "success case starts without an existing settings folder")
        let settings = AppSettings()
        settings.endpoint = "http://checked-save.offline.invalid/image/upload"
        settings.customImagePath = "/temporary-only/original.png"
        settings.customImageName = "独立原稿"
        settings.canvasText = "原始配置"
        try store.saveChecked(settings)
        check(fm.fileExists(atPath: store.settingsURL.path), "saveChecked creates its folder and settings.json")
        let firstBytes = try Data(contentsOf: store.settingsURL)
        let firstReload = SettingsStore(dataDirectory: temporary.appendingPathComponent("settings-root", isDirectory: true)).load()
        check(firstReload.endpoint == settings.endpoint && firstReload.customImagePath == settings.customImagePath && firstReload.customImageName == settings.customImageName,
              "successful checked save reopens the actual image path and display name")
        check(firstReload.canvasText == "原始配置", "successful checked save reopens canvas configuration")
        settings.canvasText = "已更新配置"
        try store.saveChecked(settings)
        let baseline = try Data(contentsOf: store.settingsURL)
        check(firstBytes != baseline && store.load().canvasText == "已更新配置", "a subsequent checked save atomically replaces the prior configuration")
        check((try JSONSerialization.jsonObject(with: baseline) as? [String: Any])?["customImageName"] as? String == "独立原稿",
              "the written file is valid production settings JSON")

        // A failed encode must leave the real existing settings.json untouched.
        settings.qwenQuotaBaseline = .nan
        expectFailure("non-finite setting") { try store.saveChecked(settings) }
        check(try Data(contentsOf: store.settingsURL) == baseline, "encode failure preserves existing settings.json byte for byte")
        settings.qwenQuotaBaseline = nil

        // A directory at the target may contain valuable prior data; never replace or clear it.
        let previousFile = store.dataDirectory.appendingPathComponent("previous-settings.json")
        try fm.moveItem(at: store.settingsURL, to: previousFile)
        try fm.createDirectory(at: store.settingsURL, withIntermediateDirectories: false)
        let targetSentinel = store.settingsURL.appendingPathComponent("retained.txt")
        let targetSentinelBytes = Data("keep-directory-content".utf8)
        try targetSentinelBytes.write(to: targetSentinel)
        settings.canvasText = "不得伪装已保存"
        expectFailure("settings.json is a directory") { try store.saveChecked(settings) }
        var directoryFlag: ObjCBool = false
        check(fm.fileExists(atPath: store.settingsURL.path, isDirectory: &directoryFlag) && directoryFlag.boolValue,
              "target-directory failure keeps the blocking directory intact")
        check(try Data(contentsOf: targetSentinel) == targetSentinelBytes, "target-directory failure preserves its contents")
        check(try Data(contentsOf: previousFile) == baseline, "target-directory failure preserves the prior settings file")
        try fm.removeItem(at: store.settingsURL)
        try fm.moveItem(at: previousFile, to: store.settingsURL)
        check(store.load().canvasText == "已更新配置", "removing a target blocker reopens the unchanged previous configuration")

        // A file at the required parent path must produce a visible error, not a swallowed write.
        let previousDirectory = temporary.appendingPathComponent("retained-settings-directory", isDirectory: true)
        try fm.moveItem(at: store.dataDirectory, to: previousDirectory)
        let parentBlocker = Data("keep-parent-file".utf8)
        try parentBlocker.write(to: store.dataDirectory)
        expectFailure("settings parent is a file") { try store.saveChecked(settings) }
        check(try Data(contentsOf: store.dataDirectory) == parentBlocker, "parent-file failure preserves the blocking file byte for byte")
        check(try Data(contentsOf: previousDirectory.appendingPathComponent("settings.json")) == baseline,
              "parent-file failure preserves the prior settings file in its retained directory")
        try fm.removeItem(at: store.dataDirectory)
        try fm.moveItem(at: previousDirectory, to: store.dataDirectory)
        check(store.load().canvasText == "已更新配置", "restoring the original parent reopens the unchanged previous settings")

        // Existing file with a non-writable parent exercises the actual atomic replacement failure.
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: store.dataDirectory.path)
        defer { try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: store.dataDirectory.path) }
        expectFailure("settings parent is read-only") { try store.saveChecked(settings) }
        check(try Data(contentsOf: store.settingsURL) == baseline, "atomic write failure preserves the existing settings.json byte for byte")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: store.dataDirectory.path)
        try store.saveChecked(settings)
        check(store.load().canvasText == "不得伪装已保存", "checked save recovers after the filesystem obstruction is removed")
        check(failures.count == 4, "every obstructed or invalid save reports an explicit failure")
        print("SettingsStore.saveChecked: \(checks) checks passed")
        if CommandLine.arguments.count > 1 {
            let report = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("report.json")
            let values: [String: Any] = ["result": "PASS", "checks": checks, "failure_cases": failures,
                "production_save_checked_linked": true, "old_save_or_write_called": false,
                "user_settings_accessed": false, "physical_device_accessed": false, "network_accessed": false]
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        }
    }
}
