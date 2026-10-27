import Foundation
import CoreGraphics
import Darwin

private final class FakeDirectPico: @unchecked Sendable {
    private var master: Int32 = -1
    let path: String
    private let queue = DispatchQueue(label: "pico.board.direct.pty")
    private let lock = NSLock()
    private var stopped = false
    private var failure: String?
    private var commands: [String] = []
    private var payload = Data()
    private var committed = false
    private var display = false
    private let wrongOffset: Bool
    private let old: Bool
    private let terminalState: String
    private let dualOrientation: Bool
    private let appSupported: Bool
    private let wrongChannel: Bool

    init(wrongOffset: Bool = false, old: Bool = false, terminalState: String = "saved", dualOrientation: Bool = true,
         appSupported: Bool = false, wrongChannel: Bool = false) throws {
        self.wrongOffset = wrongOffset; self.old = old; self.terminalState = terminalState; self.dualOrientation = dualOrientation
        self.appSupported = appSupported; self.wrongChannel = wrongChannel
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0, let raw = ttyname(slave) else { throw POSIXError(.EIO) }
        path = String(cString: raw); Darwin.close(slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.async { self.run() }
    }
    func finish() throws -> ([String], Data, Bool, Bool) {
        lock.withLock { stopped = true }; queue.sync {}
        return try lock.withLock {
            defer { Darwin.close(master) }
            if let failure { throw ReadPicoManagerError.invalid(failure) }
            return (commands, payload, committed, display)
        }
    }
    func waitForAbort() async throws {
        for _ in 0..<1000 {
            if lock.withLock({ commands.contains { $0.hasPrefix("RPICO BOARD ABORT ") } }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Client did not release its uncommitted transaction: \(lock.withLock { commands })")
    }
    private func run() {
        var incoming = Data(), remaining = 0, expected = 0, crc: UInt32 = 0, task = "", contentChannel = "canvas"
        let end = Date().addingTimeInterval(25)
        while Date() < end && !lock.withLock({ stopped }) {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 { incoming.append(contentsOf: bytes.prefix(count)) }
            while true {
                if remaining > 0 {
                    guard incoming.count >= remaining else { break }
                    lock.withLock { payload.append(incoming.prefix(remaining)) }
                    incoming.removeFirst(remaining); remaining = 0
                    let offset = lock.withLock { payload.count } + (wrongOffset ? 1 : 0)
                    send(["board_direct": true, "protocol": 1, "task": task, "phase": "chunk", "accepted": true, "next_offset": offset])
                    continue
                }
                guard let newline = incoming.firstIndex(of: 10) else { break }
                let command = String(decoding: incoming.prefix(upTo: newline), as: UTF8.self); incoming.removeSubrange(...newline)
                if command.isEmpty { continue }
                lock.withLock { commands.append(command) }
                if command == "RPICO BOARD STATUS" {
                    var result: [String: Any] = ["usb_board": true, "protocol": 1, "gray_levels": 16, "max_bytes": 420000,
                        "task": committed ? task : "", "state": committed ? terminalState : "idle"]
                    if !old { result["direct_protocol"] = 1; result["chunk_bytes"] = 1024; result["display_intent"] = true }
                    result["dual_orientation"] = dualOrientation; result["pair_max_bytes"] = dualOrientation ? ReadPicoCanvasPair.maximumBytes : 0
                    result["revision"] = committed ? 4 : 3; result["orientation"] = "landscape"
                    result["channel"] = committed && wrongChannel ? "canvas" : contentChannel
                    if appSupported { result["app_channels"] = ["cloudflare"] }
                    send(result)
                } else if command.hasPrefix("RPICO BOARD BEGIN ") || command.hasPrefix("RPICO BOARD BEGINPAIR ") {
                    let parts = command.split(separator: " ")
                    guard parts.count == 7, let amount = Int(parts[4]), let checksum = UInt32(parts[5], radix: 16) else { fail("Bad BEGIN"); return }
                    guard parts[2] != "BEGINPAIR" || dualOrientation else { fail("BEGINPAIR without capability"); return }
                    task = String(parts[3]); expected = amount; crc = checksum
                    lock.withLock { display = parts[6] == "1" }
                    send(["board_direct": true, "protocol": 1, "task": task, "phase": "ready", "accepted": true, "next_offset": 0])
                } else if command.hasPrefix("RPICO BOARD BEGINAPP ") {
                    let parts = command.split(separator: " ")
                    guard appSupported, parts.count == 8, parts[3] == "cloudflare", let amount = Int(parts[5]),
                          let checksum = UInt32(parts[6], radix: 16) else { fail("Bad BEGINAPP"); return }
                    contentChannel = String(parts[3]); task = String(parts[4]); expected = amount; crc = checksum
                    lock.withLock { display = parts[7] == "1" }
                    send(["board_direct": true, "protocol": 1, "task": task, "phase": "ready", "accepted": true, "next_offset": 0])
                } else if command.hasPrefix("RPICO BOARD CHUNK ") {
                    let parts = command.split(separator: " ")
                    guard parts.count == 6, parts[3] == task, let offset = Int(parts[4]), offset == lock.withLock({ payload.count }),
                          let count = Int(parts[5]), (1...1024).contains(count), offset + count <= expected else { fail("Bad CHUNK"); return }
                    remaining = count
                } else if command == "RPICO BOARD COMMIT " + task {
                    let valid = lock.withLock { payload.count == expected && readPicoCRC32(payload) == crc }
                    guard valid else { fail("Commit payload/CRC mismatch"); return }
                    lock.withLock { committed = true }
                    send(["board_direct": true, "protocol": 1, "task": task, "phase": "committed", "accepted": true])
                } else if command == "RPICO BOARD ABORT " + task {
                    guard !committed else { fail("Client aborted after commit"); return }
                    send(["board_direct": true, "protocol": 1, "task": task, "phase": "aborted", "accepted": true])
                } else { fail("Unexpected command " + command); return }
            }
            usleep(200)
        }
    }
    private func fail(_ value: String) { lock.withLock { failure = value } }
    private func send(_ json: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let bytes = Data("noise from IDF log\r\nRPICO ".utf8) + body + Data("\r\n".utf8)
        var offset = 0
        for size in [1, 7, 23, 4096].cycled(until: bytes.count) {
            if offset >= bytes.count { break }
            let n = min(size, bytes.count - offset)
            let written = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress!.advanced(by: offset), n) }
            if written > 0 { offset += written }
            else if errno == EAGAIN || errno == EINTR { usleep(200) }
            else { fail("PTY response failed"); return }
        }
    }
}
private extension Array where Element == Int {
    func cycled(until count: Int) -> [Int] { Array((0..<count).map { self[$0 % self.count] }) }
}
private final class DirectClientFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var currentIdentity = "aabbccddeeff", deliveries = 0, statusCalls = 0
    var supportsPair = true, failFirst = false, replaceDuringDelivery = false
    func identity() -> String { lock.withLock { currentIdentity } }
    func status() -> ReadPicoUSBBoardStatus {
        lock.withLock { statusCalls += 1 }
        return .init(taskID: "", state: "idle", directProtocol: 1, chunkBytes: 1024, displayIntent: true,
                     dualOrientation: supportsPair, pairMaxBytes: supportsPair ? ReadPicoCanvasPair.maximumBytes : 0)
    }
    func deliver(_ data: Data) throws -> ReadPicoUSBBoardReceipt {
        try ReadPicoCanvasPair.validate(data)
        let count = lock.withLock { deliveries += 1; return deliveries }
        if failFirst && count == 1 { throw CancellationError() }
        if replaceDuringDelivery { lock.withLock { currentIdentity = "112233445566" } }
        return .init(taskID: String(repeating: "a", count: 32), state: "saved", revision: 7, orientation: "landscape")
    }
    func counts() -> (Int, Int) { lock.withLock { (deliveries, statusCalls) } }
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.withLock { value = true } }
    func cancelled() -> Bool { lock.withLock { value } }
}
private final class ProductionDirectPico {
    private var master: Int32 = -1
    private var heldSlave: Int32 = -1
    let path: String
    let root: URL
    private let process = Process()
    private let errors = Pipe()
    init(executable: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-c-receiver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard openpty(&master, &heldSlave, nil, nil, nil) == 0, let raw = ttyname(heldSlave) else { throw POSIXError(.EIO) }
        path = String(cString: raw)
        var config = termios()
        guard tcgetattr(heldSlave, &config) == 0 else { throw POSIXError(.EIO) }
        cfmakeraw(&config)
        guard tcsetattr(heldSlave, TCSANOW, &config) == 0 else { throw POSIXError(.EIO) }
        let stream = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [root.path, "direct"]
        process.standardInput = stream; process.standardOutput = stream; process.standardError = errors
        try process.run()
    }
    func finish(bmp: Data) throws {
        let persisted = try Data(contentsOf: root.appendingPathComponent("readpico/desktop/canvas.bmp"))
        precondition(persisted == bmp, "Production C receiver persisted every bitmap byte")
        Darwin.close(heldSlave); heldSlave = -1
        process.waitUntilExit()
        Darwin.close(master); master = -1
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        precondition(errorData.isEmpty, String(decoding: errorData, as: UTF8.self))
        // Closing the last PTY slave gives C stdio EOF or EIO according to the host platform.
        precondition([0, 5].contains(process.terminationStatus) && process.terminationReason == .exit)
        try FileManager.default.removeItem(at: root)
    }
    deinit {
        if process.isRunning { process.terminate() }
        if heldSlave >= 0 { Darwin.close(heldSlave) }
        if master >= 0 { Darwin.close(master) }
        try? FileManager.default.removeItem(at: root)
    }
}
@main struct USBDirectBoardPTYTests {
    static func clientLifecycle(pair: Data) async throws {
        let port = "/dev/cu.usbmodem-dual-fixture"
        func client(_ fixture: DirectClientFixture) -> ReadPicoUSBBoardClient {
            .init(environment: .init(ports: { [port] }, identity: { _ in fixture.identity() },
                volumes: { preconditionFailure("Direct pair cannot enumerate TF mounts") }, status: { _ in fixture.status() },
                start: { _ in preconditionFailure("Direct pair cannot request USB file transfer") },
                direct: { _, data, _, _ in try fixture.deliver(data) }))
        }
        let fixture = DirectClientFixture(), direct = client(fixture)
        let receipt = try await direct.pushDirect(pair, port: port, expectedIdentity: "AA:BB:CC:DD:EE:FF", progress: { _ in })
        precondition(receipt.revision == 7 && receipt.orientation == "landscape" && receipt.deviceIdentity == "aabbccddeeff")
        precondition(fixture.counts().0 == 1 && fixture.counts().1 == 1)
        let unsupported = DirectClientFixture(); unsupported.supportsPair = false
        do { _ = try await client(unsupported).pushDirect(pair, port: port, progress: { _ in }); preconditionFailure("Pair was downgraded") } catch {}
        precondition(unsupported.counts().0 == 0 && unsupported.counts().1 == 1)
        var corrupt = pair; corrupt[corrupt.count - 1] ^= 1
        let invalid = DirectClientFixture()
        do { _ = try await client(invalid).pushDirect(corrupt, port: port, progress: { _ in }); preconditionFailure("Bad inner CRC accepted") } catch {}
        precondition(invalid.counts().0 == 0 && invalid.counts().1 == 0)
        let retried = DirectClientFixture(); retried.failFirst = true
        let retryClient = client(retried)
        do { _ = try await retryClient.pushDirect(pair, port: port, progress: { _ in }); preconditionFailure("Cancellation acknowledged") } catch is CancellationError {}
        _ = try await retryClient.pushDirect(pair, port: port, progress: { _ in })
        precondition(retried.counts().0 == 2, "Cancellation releases serial lease for a later transfer")
        let swapped = DirectClientFixture(); swapped.replaceDuringDelivery = true
        do { _ = try await client(swapped).pushDirect(pair, port: port, progress: { _ in }); preconditionFailure("A replacement device confirmed the prior transaction") } catch {}
        let appTask = String(repeating: "b", count: 32)
        let appClient = ReadPicoUSBBoardClient(environment: .init(ports: { [port] }, identity: { _ in "aabbccddeeff" },
            volumes: { preconditionFailure("App push cannot enumerate TF") },
            status: { _ in .init(taskID: appTask, state: "saved", directProtocol: 1, chunkBytes: 1024,
                displayIntent: true, dualOrientation: true, pairMaxBytes: ReadPicoCanvasPair.maximumBytes,
                contentChannel: .cloudflare, appChannels: ["cloudflare"]) },
            start: { _ in preconditionFailure("App push cannot start MSC") },
            directChannel: { _, data, display, channel, _ in
                precondition(data == pair && !display && channel == .cloudflare)
                return .init(taskID: appTask, state: "saved", contentChannel: channel)
            }))
        let appReceipt = try await appClient.pushDirect(pair, port: port, display: false, contentChannel: .cloudflare, progress: { _ in })
        precondition(appReceipt.contentChannel == .cloudflare && appReceipt.deviceIdentity == "aabbccddeeff")
        let savedAppStatus = try await appClient.receiptStatus(taskID: appTask, expectedIdentity: "AA:BB:CC:DD:EE:FF", contentChannel: .cloudflare)
        precondition(savedAppStatus?.contentChannel == .cloudflare)
        do { _ = try await appClient.receiptStatus(taskID: appTask, expectedIdentity: "aabbccddeeff"); preconditionFailure("App receipt mistaken for canvas") } catch {}
        print("PASS direct pair client lifecycle: one delivery, no TF/MSC operations, capability/inner CRC rejection, cancellation lease release, transaction identity continuity and revision/orientation receipt")
        print("PASS app direct runner and saved receipt are scoped to channel plus live device identity")
    }
    static func main() async throws {
        let image = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        image.setFillColor(CGColor(gray: 0.4, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let bmp = try ReadPicoBitmap.makeGray16(image: image.makeImage()!, width: 684, height: 1216)
        let landscape = try ReadPicoBitmap.makeGray16(image: image.makeImage()!, width: 1216, height: 684)
        let pair = try ReadPicoCanvasPair.encode(portrait: bmp, landscape: landscape)
        let slicedPair = (Data([0xff]) + pair).dropFirst()
        precondition(slicedPair.startIndex != 0 && slicedPair == pair)
        for (display, state) in [(false, "saved"), (true, "displayed")] {
            let fake = try FakeDirectPico(terminalState: state)
            let receipt = try await ReadPicoUSBBoardClient.directExchange(port: fake.path, bmp: bmp, display: display, cancelled: { false }, progress: { _ in })
            let (commands, data, committed, mode) = try fake.finish()
            precondition(receipt.state == state && data == bmp && committed && mode == display)
            precondition(commands.first == "RPICO BOARD STATUS" && commands.last == "RPICO BOARD STATUS")
            precondition(commands.filter { $0.hasPrefix("RPICO BOARD CHUNK ") }.count == (bmp.count + 1023) / 1024)
            precondition(commands.allSatisfy { !$0.contains("USB START") })
            print("PASS direct USB PTY: exact \(bmp.count) bytes + CRC; 409 bounded chunk ACKs; display=\(display), receipt=\(state); no MSC commands")
        }
        let old = try FakeDirectPico(old: true)
        do { _ = try await ReadPicoUSBBoardClient.directExchange(port: old.path, bmp: bmp, display: false, cancelled: { false }, progress: { _ in }); preconditionFailure("Old firmware accepted") } catch {}
        let oldResult = try old.finish()
        precondition(oldResult.0 == ["RPICO BOARD STATUS"] && oldResult.1.isEmpty && !oldResult.2)
        let mismatch = try FakeDirectPico(wrongOffset: true)
        do { _ = try await ReadPicoUSBBoardClient.directExchange(port: mismatch.path, bmp: bmp, display: false, cancelled: { false }, progress: { _ in }); preconditionFailure("Wrong offset accepted") } catch {}
        let mismatchResult = try mismatch.finish()
        precondition(mismatchResult.1.count == 1024 && !mismatchResult.2 && !mismatchResult.0.contains(where: { $0.hasPrefix("RPICO BOARD COMMIT") }))
        print("PASS direct USB PTY rejection: old capability before BEGIN, malformed ACK before next chunk/COMMIT; no physical device, user file, volume or network access")
        for (display, state) in [(false, "saved"), (true, "displayed")] {
            let fake = try FakeDirectPico(terminalState: state)
            let receipt = try await ReadPicoUSBBoardClient.directExchange(port: fake.path, bmp: display ? slicedPair : pair, display: display, cancelled: { false }, progress: { _ in })
            let (commands, data, committed, mode) = try fake.finish()
            precondition(data == pair && committed && mode == display && receipt.state == state)
            precondition(receipt.revision == 4 && receipt.orientation == "landscape")
            precondition(commands.filter { $0.hasPrefix("RPICO BOARD BEGINPAIR ") }.count == 1)
            precondition(!commands.contains { $0.hasPrefix("RPICO BOARD BEGIN ") || $0.contains("USB START") })
            precondition(commands.filter { $0.hasPrefix("RPICO BOARD COMMIT ") }.count == 1)
            precondition(commands.filter { $0.hasPrefix("RPICO BOARD CHUNK ") }.count == (pair.count + 1023) / 1024)
            print("PASS paired direct USB PTY: one atomic \(pair.count)-byte payload + outer CRC, display=\(display), exact receipt=\(state), revision/orientation retained")
        }
        for (display, state) in [(false, "saved"), (true, "displayed")] {
            let fake = try FakeDirectPico(terminalState: state, appSupported: true)
            let receipt = try await ReadPicoUSBBoardClient.directExchange(port: fake.path, bmp: pair, display: display,
                contentChannel: .cloudflare, cancelled: { false }, progress: { _ in })
            let (commands, data, committed, mode) = try fake.finish()
            precondition(receipt.contentChannel == .cloudflare && receipt.state == state && data == pair && committed && mode == display)
            precondition(commands.filter { $0.hasPrefix("RPICO BOARD BEGINAPP cloudflare ") }.count == 1)
            precondition(!commands.contains { $0.hasPrefix("RPICO BOARD BEGINPAIR ") || $0.contains("USB START") })
            print("PASS Cloudflare USB app channel: exact PICOPAIR, BEGINAPP, display=\(display), channel-scoped receipt")
        }
        let noApp = try FakeDirectPico()
        do { _ = try await ReadPicoUSBBoardClient.directExchange(port: noApp.path, bmp: pair, display: false, contentChannel: .cloudflare,
            cancelled: { false }, progress: { _ in }); preconditionFailure("App sent without negotiation") } catch {}
        let noAppResult = try noApp.finish()
        precondition(noAppResult.0 == ["RPICO BOARD STATUS"] && noAppResult.1.isEmpty && !noAppResult.2)
        let wrongApp = try FakeDirectPico(appSupported: true, wrongChannel: true)
        do { _ = try await ReadPicoUSBBoardClient.directExchange(port: wrongApp.path, bmp: pair, display: false, contentChannel: .cloudflare,
            cancelled: { false }, progress: { _ in }); preconditionFailure("Ordinary board receipt acknowledged app") } catch {}
        let wrongAppResult = try wrongApp.finish()
        precondition(wrongAppResult.2 && !wrongAppResult.0.contains { $0.hasPrefix("RPICO BOARD ABORT ") })
        print("PASS app capability rejection before BEGIN and wrong-channel receipt rejection after COMMIT")
        let singleOnly = try FakeDirectPico(dualOrientation: false)
        do { _ = try await ReadPicoUSBBoardClient.directExchange(port: singleOnly.path, bmp: pair, display: false, cancelled: { false }, progress: { _ in }); preconditionFailure("Single-only firmware accepted pair") } catch {}
        let singleOnlyResult = try singleOnly.finish()
        precondition(singleOnlyResult.0 == ["RPICO BOARD STATUS"] && singleOnlyResult.1.isEmpty && !singleOnlyResult.2)
        let flag = CancellationFlag(), cancelledPair = try FakeDirectPico()
        do {
            _ = try await ReadPicoUSBBoardClient.directExchange(port: cancelledPair.path, bmp: pair, display: false,
                cancelled: { flag.cancelled() }, progress: { value in if value.fraction == 0 { flag.cancel() } })
            preconditionFailure("Cancelled pair accepted")
        } catch is CancellationError {}
        try await cancelledPair.waitForAbort()
        let cancelledResult = try cancelledPair.finish()
        precondition(cancelledResult.1.isEmpty && !cancelledResult.2 && cancelledResult.0.contains { $0.hasPrefix("RPICO BOARD ABORT ") })
        try await clientLifecycle(pair: pair)
        if CommandLine.arguments.count > 1 {
            for (display, state) in [(false, "saved"), (true, "displayed")] {
                let real = try ProductionDirectPico(executable: CommandLine.arguments[1])
                let receipt = try await ReadPicoUSBBoardClient.directExchange(port: real.path, bmp: bmp, display: display, cancelled: { false }, progress: { _ in })
                precondition(receipt.state == state)
                try real.finish(bmp: bmp)
                print("PASS Swift-to-production-C direct USB: \(bmp.count) exact bytes on PTY, display=\(display), receipt=\(state); firmware file persisted, reader route retained for background save")
            }
            for (display, state) in [(false, "saved"), (true, "displayed")] {
                let real = try ProductionDirectPico(executable: CommandLine.arguments[1])
                let receipt = try await ReadPicoUSBBoardClient.directExchange(port: real.path, bmp: display ? slicedPair : pair, display: display, cancelled: { false }, progress: { _ in })
                precondition(receipt.state == state && receipt.revision != nil && receipt.orientation == "portrait")
                try real.finish(bmp: pair)
                print("PASS Swift-to-production-C paired USB: \(pair.count) exact bytes atomically persisted, display=\(display), receipt=\(state); both directions in one transaction")
            }
        }
    }
}
