import Foundation
import Darwin

private var checks = 0
private func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
private func reject(_ action: () async throws -> Void) async { do { try await action(); fatalError("Expected eject rejection") } catch { checks += 1 } }
private final class EjectFixture: @unchecked Sendable {
    private let lock = NSLock()
    let root: URL
    private var mounted = true, commands: [[String]] = [], waits = 0
    var infoOverride: [String: Any] = [:], secondOverride: [String: Any] = [:], actualSchema: [String: Any]?
    var foundationCapacity: Int64 = 12345678
    var commandStatus: Int32 = 0, failingCommand = "eject", keepMounted = false, busy = false, changeCapacity = false
    var commandErrorOutput: String?
    init(_ root: URL) { self.root = root }
    var volume: ReadPicoMountedVolume { .init(rootURL: root, name: "Disposable TF", capacity: foundationCapacity, free: 9999999, readOnly: false, hasPicoFolders: true, identity: "TF-UUID") }
    func volumes() -> [ReadPicoMountedVolume] { lock.withLock {
        guard mounted else { return [] }
        if changeCapacity && !commands.isEmpty { return [.init(rootURL: root, name: volume.name, capacity: volume.capacity + 1, free: 1, readOnly: false, hasPicoFolders: true, identity: volume.identity)] }
        return [volume]
    } }
    func observed() -> ([[String]], Int) { lock.withLock { (commands, waits) } }
    func settle() { lock.withLock { waits += 1 } }
    func run(_ args: [String]) throws -> ReadPicoSafeEject.CommandResult { try lock.withLock {
        commands.append(args)
        if args[0] == failingCommand && commandStatus != 0 { return .init(status: commandStatus, output: Data(), error: Data((commandErrorOutput ?? (busy ? "Resource busy" : "Operation failed")).utf8)) }
        if args[0] == "eject" { if !keepMounted { mounted = false }; return .init(status: 0, output: Data("Disk ejected\n".utf8)) }
        var info: [String: Any] = ["DeviceIdentifier": "disk42s1", "ParentWholeDisk": "disk42", "WholeDisk": false, "MountPoint": root.path, "VolumeUUID": "tf-uuid", "TotalSize": volume.capacity, "Internal": false]
        if let actualSchema { info = actualSchema; info["MountPoint"] = root.path; info["VolumeUUID"] = "TF-UUID" }
        for (key, value) in infoOverride { info[key] = value }
        if commands.count == 2 { for (key, value) in secondOverride { info[key] = value } }
        return .init(status: 0, output: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
    } }
    func client() -> ReadPicoSafeEject { .init(environment: .init(volumes: { self.volumes() }, run: { try self.run($0) }, settle: { self.settle() })) }
}
private actor Entered { var value = false; func enter() { value = true } }
@main struct SafeEjectTests {
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pico-safe-eject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        func fixture(_ name: String) throws -> EjectFixture { let root = base.appendingPathComponent(name); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return EjectFixture(root) }
        let success = try fixture("success with spaces;$(literal)")
        try await success.client().eject(success.root, expectedVolume: success.volume)
        check(success.observed().0 == [["info", "-plist", success.root.path], ["info", "-plist", "/dev/disk42s1"], ["eject", "/dev/disk42s1"]], "Exact structured system arguments; mount names never become shell code")
        check(success.observed().1 == 0 && success.volumes().isEmpty, "Only absent original mounted volume confirms ejection")
        let captured = try fixture("captured-real-schema")
        captured.actualSchema = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Tools/ReadPicoManagerTests/Fixtures/SafeEject-FSKit-FAT.plist")), format: nil) as? [String: Any]
        captured.foundationCapacity = 62584684544
        check(captured.actualSchema?["Whole"] == nil && captured.actualSchema?["WholeDisk"] as? Bool == false, "Real FSKit diskutil uses WholeDisk, not Whole")
        check(captured.actualSchema?["IOKitSize"] as? Int64 != captured.foundationCapacity && captured.actualSchema?["TotalSize"] as? Int64 == captured.foundationCapacity, "Real filesystem capacity is distinct from raw IOKit sector capacity")
        try await captured.client().eject(captured.root, expectedVolume: captured.volume)
        check(captured.observed().0.count == 3 && captured.volumes().isEmpty, "Sanitized real FSKit FAT schema passes strict production preflight")
        for (name, changed) in [("uuid", ["VolumeUUID": "another-card"]), ("whole", ["WholeDisk": true]), ("internal", ["Internal": true]), ("mount", ["MountPoint": "/Volumes/another"]), ("device", ["DeviceIdentifier": "disk42;rm"]), ("parent", ["ParentWholeDisk": "disk1"]), ("size", ["TotalSize": 0]), ("capacity", ["TotalSize": 13000000])] as [(String, [String: Any])] {
            let bad = try fixture("bad-" + name); bad.infoOverride = changed
            await reject { try await bad.client().eject(bad.root) }
            check(bad.observed().0.count == 1 && bad.observed().0[0][0] == "info", "Unmatched \(name) is rejected before eject")
        }
        for (name, changed) in [("device", ["DeviceIdentifier": "disk43s1", "ParentWholeDisk": "disk43"]), ("size", ["TotalSize": 12345679])] as [(String, [String: Any])] {
            let changedDisk = try fixture("changed-" + name); changedDisk.secondOverride = changed
            await reject { try await changedDisk.client().eject(changedDisk.root) }
            check(changedDisk.observed().0.count == 2, "Original device and physical capacity are rechecked before eject")
        }
        let capacity = try fixture("capacity-changed"); capacity.changeCapacity = true
        await reject { try await capacity.client().eject(capacity.root) }
        check(capacity.observed().0.count == 1, "Foundation volume capacity change stops eject before device command")
        let expected = try fixture("expected-card")
        let wrong = ReadPicoMountedVolume(rootURL: expected.root, name: "wrong", capacity: expected.volume.capacity, free: 1, readOnly: false, hasPicoFolders: true, identity: "other")
        await reject { try await expected.client().eject(expected.root, expectedVolume: wrong) }
        check(expected.observed().0.isEmpty, "Explicit original TF identity is required before system queries")
        let failed = try fixture("nonzero-eject"); failed.commandStatus = 1
        await reject { try await failed.client().eject(failed.root) }
        check(failed.observed().0.count == 3 && !failed.volumes().isEmpty, "Nonzero diskutil status never counts as success")
        let failedInfo = try fixture("nonzero-info"); failedInfo.commandStatus = 1; failedInfo.failingCommand = "info"
        await reject { try await failedInfo.client().eject(failedInfo.root) }
        check(failedInfo.observed().0.count == 1, "Failed disk identity query cannot eject")
        let busy = try fixture("busy"); busy.commandStatus = 1; busy.busy = true
        do { try await busy.client().eject(busy.root); fatalError("Expected busy") }
        catch let error as POSIXError { check(error.code == .EBUSY, "Explicit system resource-busy maps to bounded caller retry") }
        let dissented = try fixture("mdsync-dissent"); dissented.commandStatus = 1
        dissented.commandErrorOutput = "Unmount of disk42 failed: at least one volume could not be unmounted\nUnmount was dissented by PID 1234 (/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mdsync)\nDissenter parent PPID 1 (/sbin/launchd)"
        do { try await dissented.client().eject(dissented.root); fatalError("Expected host indexer dissent") }
        catch let error as POSIXError { check(error.code == .EBUSY, "Actual diskutil mdsync dissent is reported as retryable resource-busy") }
        check(dissented.observed().0.count == 3 && dissented.volumes().count == 1 && dissented.observed().1 == 0,
              "Host indexer dissent leaves the mounted TF untouched without forced eject or automatic retries")
        let stillMounted = try fixture("false-success"); stillMounted.keepMounted = true
        await reject { try await stillMounted.client().eject(stillMounted.root) }
        check(stillMounted.observed().1 == 20, "Exit zero with original TF still mounted is bounded and rejected")
        let swapped = try fixture("replaced-root"), old = base.appendingPathComponent("old-root")
        let swapClient = ReadPicoSafeEject(environment: .init(volumes: { swapped.volumes() }, run: { args in
            let result = try swapped.run(args)
            if swapped.observed().0.count == 2 { try FileManager.default.moveItem(at: swapped.root, to: old); try FileManager.default.createDirectory(at: swapped.root, withIntermediateDirectories: false) }
            return result
        }, settle: {}))
        await reject { try await swapClient.eject(swapped.root) }
        check(swapped.observed().0.count == 2, "Replaced mount inode is rejected even with matching supplied UUID and capacity")
        let cancelled = try fixture("cancelled"), entered = Entered()
        let cancelling = Task {
            try await ReadPicoSafeEject(environment: .init(volumes: { cancelled.volumes() }, run: { args in
                if args[0] == "eject" { await entered.enter(); try await Task.sleep(nanoseconds: 60_000_000_000) }
                return try cancelled.run(args)
            }, settle: {})).eject(cancelled.root)
        }
        while !(await entered.value) { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelling.cancel()
        do { try await cancelling.value; fatalError("Expected cancellation") } catch is CancellationError { checks += 1 }
        check(cancelled.observed().0.count == 2 && !cancelled.volumes().isEmpty, "Cancellation does not falsely acknowledge a pending eject")
        for args in [["eject", "force", "/dev/disk42"], ["eraseDisk", "/dev/disk42"], ["eject", "/dev/disk0"], ["eject", "/dev/disk42s1;sh"]] {
            await reject { _ = try await ReadPicoSafeEject.runDiskutil(args) }
        }
        print("PASS safe eject: \(checks) checks; structured info/plist→original UUID/capacity/device/inode→normal eject→confirmed absent; no hardware accessed")
    }
}
