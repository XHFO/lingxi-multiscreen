import CoreGraphics
import Foundation
import Darwin

private var checks = 0
private func check(_ value: Bool, _ description: String) { checks += 1; precondition(value, description) }
private func reject(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch { checks += 1 } }
private func rejectAsync(_ body: () async throws -> Void) async { do { try await body(); fatalError("Expected rejection") } catch { checks += 1 } }
private actor Updates {
    var values: [ReadPicoUSBBoardProgress] = []
    func add(_ value: ReadPicoUSBBoardProgress) { values.append(value) }
}
private actor Pause {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func stop() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
private actor RetryWaits {
    var attempts: [Int] = []
    func record(_ attempt: Int) { attempts.append(attempt) }
}
private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    var card: ReadPicoMountedVolume
    private var mounted = true, ejections = 0, completedEjections = 0, starts = 0, statusReads = 0
    private var ejectionFailures: [Int: NSError] = [:], failedCommitSnapshots: [Bool] = []
    private var returned: [ReadPicoUSBBoardStatus] = []
    private var terminal: ReadPicoUSBBoardStatus?
    private var diskutilCommands: [[String]] = []
    var oldFirmware = false, wrongTaskThenError = false, saved = false
    let native: String?
    init(root: URL, native: String? = nil) {
        self.native = native
        card = .init(rootURL: root, name: "Disposable test card", capacity: 32_000_000_000,
                     free: 20_000_000_000, readOnly: false, hasPicoFolders: true, identity: "disposable-card")
    }
    func volumes() -> [ReadPicoMountedVolume] { lock.withLock { mounted ? [card] : [] } }
    func counts() -> (Int, Int, Int) { lock.withLock { (ejections, starts, statusReads) } }
    func failEjections(_ failures: [Int: NSError]) { lock.withLock { ejectionFailures = failures } }
    func failedSnapshots() -> [Bool] { lock.withLock { failedCommitSnapshots } }
    func systemCommands() -> [[String]] { lock.withLock { diskutilCommands } }
    func replaceIdentity() { lock.withLock {
        card = .init(rootURL: card.rootURL, name: card.name, capacity: card.capacity, free: card.free,
                     readOnly: false, hasPicoFolders: true, identity: "replacement-card")
    } }
    func status() throws -> ReadPicoUSBBoardStatus {
        try lock.withLock {
            statusReads += 1
            if oldFirmware { throw ReadPicoManagerError.unavailable("Old firmware") }
            if !returned.isEmpty { terminal = returned.removeFirst(); return terminal! }
            if let terminal { return terminal }
            return .init(taskID: "", state: "idle")
        }
    }
    func start() { lock.withLock { starts += 1; mounted = true } }
    func eject() throws {
        try lock.withLock {
            ejections += 1
            if let failure = ejectionFailures[ejections] {
                failedCommitSnapshots.append(FileManager.default.fileExists(atPath: card.rootURL.appendingPathComponent("readpico/desktop/usb-board.pcb").path))
                throw failure
            }
            completedEjections += 1; mounted = false
            if let native {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: native)
                process.arguments = [card.rootURL.path, "consume-usb"]
                process.standardOutput = output
                try process.run(); process.waitUntilExit()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
                guard lines.count == 2 else { fatalError("Actual C did not emit two state boundaries") }
                returned = try lines.map { try ReadPicoUSBBoardStatus(line: "RPICO " + $0 + "\n") }
                check(process.terminationStatus == (completedEjections == 1 ? 2 : 0), "Actual C consumer exit")
            } else if completedEjections == 2 {
                let data = try Data(contentsOf: card.rootURL.appendingPathComponent("readpico/desktop/usb-board.pcb"))
                let task = String(decoding: data[24..<56], as: UTF8.self)
                returned = wrongTaskThenError ? [.init(taskID: String(repeating: "b", count: 32), state: "displayed"), .init(taskID: task, state: "error")] : [.init(taskID: task, state: saved ? "saved" : "displayed")]
            }
        }
    }
    func publish(_ status: ReadPicoUSBBoardStatus) { lock.withLock { terminal = status } }
    func client(ejectRetryWait: @escaping @Sendable (Int) async throws -> Void = { _ in }) -> ReadPicoUSBBoardClient {
        .init(environment: .init(ports: { ["/dev/cu.usbmodem-disposable-test"] }, identity: { _ in "disposable-reader" },
            volumes: { self.volumes() }, status: { _ in try self.status() }, start: { _ in self.start() }, ejectRetryWait: ejectRetryWait))
    }
    func safelyEject(_ root: URL) async throws {
        try await ReadPicoSafeEject(environment: .init(volumes: { self.volumes() }, run: { args in
            self.lock.withLock { self.diskutilCommands.append(args) }
            if args[0] == "eject" { try self.eject(); return .init(status: 0, output: Data()) }
            let card = self.lock.withLock { self.card }
            let info: [String: Any] = ["DeviceIdentifier": "disk42s1", "ParentWholeDisk": "disk42", "WholeDisk": false,
                "MountPoint": card.rootURL.path, "VolumeUUID": card.identity!, "TotalSize": card.capacity, "Internal": false]
            return .init(status: 0, output: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        }, settle: {})).eject(root)
    }
}

@main struct USBBoardTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-usb-board-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
        }
        let valid = "RPICO {\"usb_board\":true,\"protocol\":1,\"gray_levels\":16,\"max_bytes\":420000,\"task\":\"\",\"state\":\"idle\"}\n"
        check(try ReadPicoUSBBoardStatus(line: valid).state == "idle", "Capability state")
        check(try ReadPicoUSBBoardStatus(line: valid.replacingOccurrences(of: "\"idle\"", with: "\"saved\"")).state == "saved", "Saved is a supported non-display receipt")
        check(try ReadPicoUSBBoardStatus(line: valid.replacingOccurrences(of: "\n", with: "\r\n")).state == "idle", "CRLF capability")
        for bad in [valid.trimmingCharacters(in: .newlines), "log:" + valid, valid + valid,
                    valid.replacingOccurrences(of: "\n", with: "\r\r\n"), valid.replacingOccurrences(of: "true", with: "1"),
                    valid.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":true"),
                    valid.replacingOccurrences(of: "\"gray_levels\":16", with: "\"gray_levels\":2"),
                    valid.replacingOccurrences(of: "420000", with: "419999"),
                    valid.replacingOccurrences(of: "\"task\":\"\"", with: "\"task\":\"../outside\""),
                    valid.replacingOccurrences(of: "\"idle\"", with: "\"complete\"")] { reject { _ = try ReadPicoUSBBoardStatus(line: bad) } }
        let width = 684, height = 1216
        let pixels = (0..<(width * height)).map { UInt8(($0 % 16) * 17) }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bmp = try ReadPicoBitmap.makeGray16(image: image, width: width, height: height)
        let taskID = String(repeating: "a", count: 32), updates = Updates(), card = try folder("atomic")
        let store = try ReadPicoTFStore(rootURL: card)
        try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: store) { await updates.add($0) }
        let target = card.appendingPathComponent("readpico/desktop/usb-board.pcb"), packet = try Data(contentsOf: target)
        check(packet.count == bmp.count + 64 && String(decoding: packet[0..<8], as: UTF8.self) == "PICOBRD1", "Header size/magic")
        func u32(_ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(packet[p + $1]) << ($1 * 8) } }
        check(u32(8) == 1 && u32(12) == 64 && u32(16) == bmp.count, "Version/length")
        check(u32(20) == readPicoCRC32(bmp) && String(decoding: packet[24..<56], as: UTF8.self) == taskID, "CRC/task")
        check(packet[56..<64].allSatisfy { $0 == 0 } && packet.dropFirst(64) == bmp, "Exact native gray16 payload")
        let fractions = await updates.values.compactMap(\.fraction)
        check(fractions.count > 40 && fractions.last == 1 && zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 }, "Actual monotonic byte progress")
        await rejectAsync { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: store) { _ in } }
        check(try Data(contentsOf: target) == packet, "Existing committed job remains unchanged")
        await rejectAsync { try await ReadPicoUSBBoardClient.commit(Data("bad".utf8), taskID: taskID, store: store) { _ in } }
        let repeatedRoot = try folder("repeated-existing-directories"), repeatedStore = try ReadPicoTFStore(rootURL: repeatedRoot)
        let repeatedParent = repeatedRoot.appendingPathComponent("readpico"), repeatedTarget = repeatedParent.appendingPathComponent("desktop/usb-board.pcb")
        try FileManager.default.createDirectory(at: repeatedParent, withIntermediateDirectories: false)
        let sentinel = Data("existing reader settings remain unchanged".utf8)
        try sentinel.write(to: repeatedParent.appendingPathComponent("settings.fixture"))
        try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: repeatedStore) { _ in }
        check(try Data(contentsOf: repeatedParent.appendingPathComponent("settings.fixture")) == sentinel, "Preexisting readpico directory is reused without changing its files")
        try FileManager.default.removeItem(at: repeatedTarget)
        let repeatedTask = String(repeating: "c", count: 32)
        try await ReadPicoUSBBoardClient.commit(bmp, taskID: repeatedTask, store: repeatedStore) { _ in }
        let repeatedPacket = try Data(contentsOf: repeatedTarget)
        check(String(decoding: repeatedPacket[24..<56], as: UTF8.self) == repeatedTask && repeatedPacket.dropFirst(64) == bmp, "Repeated commit reuses both existing TF directories after prior job consumption")
        check(try Data(contentsOf: repeatedParent.appendingPathComponent("settings.fixture")) == sentinel, "Repeated commit preserves unrelated reader settings")
        var descriptors = 0
        for fd in 0..<1024 {
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            if fcntl(Int32(fd), F_GETPATH, &path) == 0 && String(cString: path).hasPrefix(repeatedRoot.path) { descriptors += 1 }
        }
        check(descriptors == 0, "Commit returns with no open TF root, desktop, staging, or packet descriptors")
        let fileParentRoot = try folder("file-instead-of-readpico"), fileParentStore = try ReadPicoTFStore(rootURL: fileParentRoot)
        try sentinel.write(to: fileParentRoot.appendingPathComponent("readpico"))
        await rejectAsync { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: fileParentStore) { _ in } }
        check(try Data(contentsOf: fileParentRoot.appendingPathComponent("readpico")) == sentinel, "A file in place of the TF directory is rejected intact")
        let linked = try folder("symlink"), outside = try folder("outside")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("readpico"), withDestinationURL: outside)
        let linkedStore = try ReadPicoTFStore(rootURL: linked)
        await rejectAsync { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: linkedStore) { _ in } }
        check(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Symlink never receives data")
        let nestedLink = try folder("nested-symlink"), nestedLinkStore = try ReadPicoTFStore(rootURL: nestedLink)
        try FileManager.default.createDirectory(at: nestedLink.appendingPathComponent("readpico"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: nestedLink.appendingPathComponent("readpico/desktop"), withDestinationURL: outside)
        await rejectAsync { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: nestedLinkStore) { _ in } }
        check(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Nested desktop symlink is rejected through anchored no-follow traversal")
        let cancelledRoot = try folder("cancelled"), cancelledStore = try ReadPicoTFStore(rootURL: cancelledRoot), pause = Pause()
        let transfer = Task { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: cancelledStore) { value in if value.fraction ?? 0 < 0.1 { await pause.stop() } } }
        while !(await pause.waiting) { try await Task.sleep(nanoseconds: 1_000_000) }
        transfer.cancel(); await pause.resume(); await rejectAsync { try await transfer.value }
        check(try FileManager.default.contentsOfDirectory(atPath: cancelledRoot.appendingPathComponent("readpico/desktop").path).isEmpty, "Cancellation cleans staging and never commits")
        let replacedRoot = try folder("replaced"), replacedStore = try ReadPicoTFStore(rootURL: replacedRoot), moved = root.appendingPathComponent("old-card")
        let replaced = Task { try await ReadPicoUSBBoardClient.commit(bmp, taskID: taskID, store: replacedStore) { _ in
            if !FileManager.default.fileExists(atPath: moved.path) {
                try! FileManager.default.moveItem(at: replacedRoot, to: moved)
                try! FileManager.default.createDirectory(at: replacedRoot, withIntermediateDirectories: false)
                let fakeDirectory = replacedRoot.appendingPathComponent("readpico/desktop")
                try! FileManager.default.createDirectory(at: fakeDirectory, withIntermediateDirectories: true)
                try! Data("new-card-owned-data".utf8).write(to: fakeDirectory.appendingPathComponent(".usb-board-\(taskID).tmp"))
            }
        } }
        await rejectAsync { try await replaced.value }
        check(try Data(contentsOf: replacedRoot.appendingPathComponent("readpico/desktop/.usb-board-\(taskID).tmp")) == Data("new-card-owned-data".utf8), "New card is neither written nor cleaned through a stale path")
        check(try FileManager.default.contentsOfDirectory(atPath: moved.appendingPathComponent("readpico/desktop").path).isEmpty, "Old card staging cleaned through original directory descriptor")
        let oldRoot = try folder("old-firmware"), old = Fixture(root: oldRoot); old.oldFirmware = true
        await rejectAsync { _ = try await old.client().push(bmp, store: ReadPicoTFStore(rootURL: oldRoot), expectedIdentity: "disposable-reader", eject: { _ in try old.eject() }, progress: { _ in }) }
        check(old.counts().0 == 1 && old.counts().1 == 0 && !FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("readpico").path), "Old firmware rejected before USB export or writing")
        let mismatchRoot = try folder("mismatch"), mismatch = Fixture(root: mismatchRoot); mismatch.wrongTaskThenError = true
        await rejectAsync { _ = try await mismatch.client().push(bmp, store: ReadPicoTFStore(rootURL: mismatchRoot), expectedIdentity: "disposable-reader", eject: { _ in try mismatch.eject() }, progress: { _ in }) }
        check(mismatch.counts().2 == 3, "Wrong-task displayed state does not acknowledge; matching error rejects")
        let savedRoot = try folder("saved-task"), saved = Fixture(root: savedRoot); saved.saved = true
        let savedClient = saved.client()
        let savedReceipt = try await savedClient.push(bmp, store: ReadPicoTFStore(rootURL: savedRoot), expectedIdentity: "disposable-reader", eject: { _ in try saved.eject() }, progress: { _ in })
        check(savedReceipt.state == "saved" && savedReceipt.deviceIdentity == "disposable-reader", "USB saved reports delivery without claiming display")
        let savedStatus = try await savedClient.receiptStatus(taskID: savedReceipt.taskID, expectedIdentity: "disposable-reader")
        check(savedStatus?.state == "saved" && saved.counts().0 == 2 && saved.counts().1 == 1, "Read-only receipt check never exports TF or repeats a committed task")
        saved.publish(.init(taskID: savedReceipt.taskID, state: "displayed"))
        check(try await savedClient.receiptStatus(taskID: savedReceipt.taskID, expectedIdentity: "disposable-reader")?.state == "displayed", "Exact saved task can later confirm actual display")
        saved.publish(.init(taskID: String(repeating: "b", count: 32), state: "displayed"))
        await rejectAsync { _ = try await savedClient.receiptStatus(taskID: savedReceipt.taskID, expectedIdentity: "disposable-reader") }
        let beforeOther = saved.counts().2
        check(try await savedClient.receiptStatus(taskID: savedReceipt.taskID, expectedIdentity: "different-reader") == nil && saved.counts().2 == beforeOther, "A different USB identity cannot confirm or even sample the old receipt")
        let busyOS = NSError(domain: NSOSStatusErrorDomain, code: -47)
        let busyPOSIX = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        let firstBusyRoot = try folder("first-eject-busy"), firstBusy = Fixture(root: firstBusyRoot), firstWaits = RetryWaits(), firstProgress = Updates()
        firstBusy.failEjections([1: busyOS])
        _ = try await firstBusy.client(ejectRetryWait: { await firstWaits.record($0) }).push(bmp, store: ReadPicoTFStore(rootURL: firstBusyRoot), expectedIdentity: "disposable-reader", eject: { _ in try firstBusy.eject() }, progress: { await firstProgress.add($0) })
        check(firstBusy.counts().0 == 3 && firstBusy.counts().1 == 1 && firstBusy.counts().2 == 2, "OSStatus busy retries first safe eject then requires displayed acknowledgement")
        check(await firstWaits.attempts == [1] && firstBusy.failedSnapshots() == [false], "First safe-eject retry cannot write before device capability check")
        check(await firstProgress.values.contains { $0.text.contains("系统占用") && $0.fraction == nil }, "Safe-eject retry has stable actionable progress")
        let secondBusyRoot = try folder("second-eject-busy"), secondBusy = Fixture(root: secondBusyRoot), secondWaits = RetryWaits()
        secondBusy.failEjections([2: busyPOSIX])
        _ = try await secondBusy.client(ejectRetryWait: { await secondWaits.record($0) }).push(bmp, store: ReadPicoTFStore(rootURL: secondBusyRoot), expectedIdentity: "disposable-reader", eject: { _ in try secondBusy.eject() }, progress: { _ in })
        check(secondBusy.counts().0 == 3 && secondBusy.counts().2 == 2, "POSIX busy retries final safe eject and still waits for exact-task display")
        check(await secondWaits.attempts == [1] && secondBusy.failedSnapshots() == [true], "Final busy eject retains committed job pending safe return")
        let exhaustedRoot = try folder("busy-exhausted"), exhausted = Fixture(root: exhaustedRoot), exhaustedWaits = RetryWaits()
        exhausted.failEjections(Dictionary(uniqueKeysWithValues: (1...6).map { ($0, busyOS) }))
        await rejectAsync { _ = try await exhausted.client(ejectRetryWait: { await exhaustedWaits.record($0) }).push(bmp, store: ReadPicoTFStore(rootURL: exhaustedRoot), expectedIdentity: "disposable-reader", eject: { _ in try exhausted.eject() }, progress: { _ in }) }
        check(exhausted.counts().0 == 6 && exhausted.counts().1 == 0 && exhausted.counts().2 == 0, "Busy retry stops at six attempts without USB start")
        check(await exhaustedWaits.attempts == [1, 2, 3, 4, 5] && !FileManager.default.fileExists(atPath: exhaustedRoot.appendingPathComponent("readpico").path), "Busy exhaustion has five bounded waits and no TF writes")
        let pendingRoot = try folder("final-busy-exhausted"), pending = Fixture(root: pendingRoot), pendingWaits = RetryWaits()
        pending.failEjections(Dictionary(uniqueKeysWithValues: (2...7).map { ($0, busyPOSIX) }))
        await rejectAsync { _ = try await pending.client(ejectRetryWait: { await pendingWaits.record($0) }).push(bmp, store: ReadPicoTFStore(rootURL: pendingRoot), expectedIdentity: "disposable-reader", eject: { _ in try pending.eject() }, progress: { _ in }) }
        check(pending.counts().0 == 7 && pending.counts().1 == 1 && pending.counts().2 == 1, "Final busy exhaustion never reports a displayed acknowledgement")
        check(await pendingWaits.attempts == [1, 2, 3, 4, 5] && pending.failedSnapshots() == Array(repeating: true, count: 6), "Final busy exhaustion retains pending packet for a later safe eject")
        for (label, failure) in [("nonbusy-posix", NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), ("nonbusy-osstatus", NSError(domain: NSOSStatusErrorDomain, code: -50))] {
            let nonbusyRoot = try folder(label), nonbusy = Fixture(root: nonbusyRoot), nonbusyWaits = RetryWaits()
            nonbusy.failEjections([1: failure])
            await rejectAsync { _ = try await nonbusy.client(ejectRetryWait: { await nonbusyWaits.record($0) }).push(bmp, store: ReadPicoTFStore(rootURL: nonbusyRoot), expectedIdentity: "disposable-reader", eject: { _ in try nonbusy.eject() }, progress: { _ in }) }
            let recordedWaits = await nonbusyWaits.attempts
            check(nonbusy.counts().0 == 1 && nonbusy.counts().1 == 0 && nonbusy.counts().2 == 0 && recordedWaits.isEmpty, "Nonbusy eject error fails immediately without retry or write")
        }
        let cancelledBusyRoot = try folder("busy-cancelled"), cancelledBusy = Fixture(root: cancelledBusyRoot), cancelledWaits = RetryWaits()
        cancelledBusy.failEjections([1: busyOS])
        let cancelling = Task { try await cancelledBusy.client(ejectRetryWait: { attempt in await cancelledWaits.record(attempt); try await Task.sleep(nanoseconds: 60_000_000_000) }).push(bmp, store: ReadPicoTFStore(rootURL: cancelledBusyRoot), expectedIdentity: "disposable-reader", eject: { _ in try cancelledBusy.eject() }, progress: { _ in }) }
        while await cancelledWaits.attempts.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelling.cancel()
        do { _ = try await cancelling.value; fatalError("Expected cancellation during busy wait") }
        catch is CancellationError { checks += 1 }
        check(cancelledBusy.counts().0 == 1 && cancelledBusy.counts().1 == 0 && !FileManager.default.fileExists(atPath: cancelledBusyRoot.appendingPathComponent("readpico").path), "Cancellation during safe-eject wait cannot retry or write")
        let changedBusyRoot = try folder("busy-replaced-card"), changedBusy = Fixture(root: changedBusyRoot)
        changedBusy.failEjections([1: busyOS])
        await rejectAsync { _ = try await changedBusy.client(ejectRetryWait: { _ in changedBusy.replaceIdentity() }).push(bmp, store: ReadPicoTFStore(rootURL: changedBusyRoot), expectedIdentity: "disposable-reader", eject: { _ in try changedBusy.eject() }, progress: { _ in }) }
        check(changedBusy.counts().0 == 1 && changedBusy.counts().1 == 0 && !FileManager.default.fileExists(atPath: changedBusyRoot.appendingPathComponent("readpico").path), "Retry rechecks original card identity before another eject or write")
        print("PASS USB safe-eject retry: OSStatus -47 / POSIX EBUSY only; both boundaries, six-attempt bound, cancellation, and card identity")
        if CommandLine.arguments.count == 2 {
            let nativeRoot = try folder("native"), native = Fixture(root: nativeRoot, native: CommandLine.arguments[1]), progress = Updates()
            let receipt = try await native.client().push(bmp, store: ReadPicoTFStore(rootURL: nativeRoot), expectedIdentity: "disposable-reader", eject: { try await native.safelyEject($0) }, progress: { await progress.add($0) })
            check(receipt.taskID.count == 32 && native.counts().0 == 2 && native.counts().1 == 1, "Full USB handoff lifecycle")
            check(native.systemCommands() == Array(repeating: [["info", "-plist", nativeRoot.path], ["info", "-plist", "/dev/disk42s1"], ["eject", "/dev/disk42s1"]], count: 2).flatMap { $0 }, "Both USB lifecycle boundaries use the shared production safe-eject command/state validation")
            check(native.counts().2 >= 3, "Actual C pending state observed before displayed")
            let repeatNative = Fixture(root: nativeRoot, native: CommandLine.arguments[1])
            let secondReceipt = try await repeatNative.client().push(bmp, store: ReadPicoTFStore(rootURL: nativeRoot), expectedIdentity: "disposable-reader", eject: { try await repeatNative.safelyEject($0) }, progress: { _ in })
            check(secondReceipt.taskID != receipt.taskID && repeatNative.counts().0 == 2 && repeatNative.counts().2 >= 3, "Second actual-C USB handoff reuses stored readpico/desktop directories and confirms its new exact task")
            check(try Data(contentsOf: nativeRoot.appendingPathComponent("readpico/desktop/canvas.bmp")) == bmp, "Actual C atomic save preserves the Swift native BMP byte-for-byte")
            let actual = try Data(contentsOf: nativeRoot.appendingPathComponent("native-framebuffer.bin"))
            check(actual.count == width * height / 2, "Actual C rendered full-size packed framebuffer")
            let stride = (width * 4 + 31) / 32 * 4
            var levels = Set<UInt8>()
            for y in 0..<height { for x in 0..<width {
                let encoded = bmp[118 + (height - 1 - y) * stride + x / 2]
                let palette = (x & 1) == 0 ? encoded >> 4 : encoded & 15
                let pixel = y * width + x, packed = actual[pixel / 2]
                let value = (pixel & 1) == 0 ? packed & 15 : packed >> 4
                check(value == palette, "Swift BMP→actual C framebuffer pixel")
                levels.insert(value)
            } }
            check(levels.count == 16, "All sixteen native gray levels preserved")
            check(!FileManager.default.fileExists(atPath: nativeRoot.appendingPathComponent("readpico/desktop/usb-board.pcb").path), "Actual C consumes fixed inbox")
            check(await progress.values.contains { $0.fraction == 1 }, "End-to-end byte progress")
            print("PASS Swift→actual C USB native gray16: \(bmp.count) bytes, \(width * height) exact pixels; pending→host display-boundary acknowledgement")
        }
        print("PASS USB board: \(checks) checks; no physical devices or mounted volumes accessed")
    }
}
