import Foundation
import Darwin

// Exercise the actual POSIX exchange over generated pseudo-terminals only.
// The runner exposes the private method in a temporary source copy; production
// access control, port selection and serial control-line behavior stay unchanged.
private final class FakePico: @unchecked Sendable {
    private var master: Int32 = -1
    let path: String
    private let queue = DispatchQueue(label: "readpico.usb.native-pty-tests")
    private let lock = NSLock()
    private var commands: [String] = []
    private var failure: String?

    init(status: String, acknowledgement: String, chunkSizes: [Int], startCommand: String = "RPICO USB START", readOnly: Bool = false) throws {
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0, let raw = ttyname(slave) else {
            throw POSIXError(.EIO)
        }
        path = String(cString: raw)
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.async { [self] in
            var buffer = Data()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                while let index = buffer.firstIndex(of: 10) {
                    let command = String(data: buffer.prefix(upTo: index), encoding: .utf8) ?? ""
                    buffer.removeSubrange(...index)
                    if command.isEmpty { continue }
                    lock.lock(); commands.append(command); lock.unlock()
                    if command == "RPICO STATUS" {
                        // A log line containing valid-looking protocol JSON is not a frame.
                        trySend("old idf log RPICO {\"accepted\":true}\r\n" + status, chunkSizes: chunkSizes)
                        if readOnly { return }
                    } else if command == startCommand {
                        trySend("old idf log RPICO {\"accepted\":true}\r\n" + acknowledgement, chunkSizes: chunkSizes)
                        return
                    } else {
                        fail("unexpected command: " + command); return
                    }
                }
                usleep(1000)
            }
            fail("fake device timed out")
        }
    }

    private func fail(_ text: String) {
        lock.lock(); failure = text; lock.unlock()
    }

    private func trySend(_ text: String, chunkSizes: [Int]) {
        let bytes = Array(text.utf8)
        var offset = 0
        var chunkIndex = 0
        while offset < bytes.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], bytes.count - offset)
            let count = bytes.withUnsafeBytes {
                Darwin.write(master, $0.baseAddress!.advanced(by: offset), size)
            }
            if count > 0 { offset += count; chunkIndex += 1 }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000); continue }
            else { fail("fake device write failed"); return }
            usleep(700)
        }
    }

    func finish() throws -> [String] {
        queue.sync {}
        lock.lock(); defer { lock.unlock(); Darwin.close(master) }
        if let failure { throw ReadPicoUSBTransferError.invalid(failure) }
        return commands
    }
}

@main private struct USBNativePTYTests {
    static func main() throws {
        let legacy = "{\"route\":0,\"storage_busy\":false,\"mounted\":true,\"read_verified\":true,\"write_verified\":true}"
        let coldBoot = "{\"device\":\"read-pico\",\"version\":\"0.28.3-dev45\",\"route\":0,\"storage_busy\":false,\"present\":true,\"mounted\":true,\"state\":3,\"stage\":7,\"error\":0,\"read_verified\":false,\"write_verified\":false,\"usb_active\":false,\"usb_held\":false,\"usb_serial\":\"pty-test-only\"}"
        let fixtures: [(String, String, String, [Int], String?)] = [
            ("legacy LF", legacy, "\n", [7], nil),
            ("cold boot LF", coldBoot, "\n", [1, 31, 3, 64], "pty-test-only"),
            ("cold boot CRLF fragmented bytewise", coldBoot, "\r\n", [1], "pty-test-only"),
            ("cold boot CRLF uneven chunks", coldBoot, "\r\n", [64, 2, 13, 1, 5], "pty-test-only")
        ]
        for (name, json, ending, chunks, identity) in fixtures {
            let fake = try FakePico(status: "RPICO " + json + ending,
                                    acknowledgement: "RPICO {\"accepted\":true,\"busy\":false}" + ending,
                                    chunkSizes: chunks)
            let result = try ReadPicoUSBTransferClient.exchange(port: fake.path, cancelled: { false })
            let commands = try fake.finish()
            precondition(result.deviceIdentity == identity, "wrong identity: " + name)
            precondition(commands == ["RPICO STATUS", "RPICO USB START"], "wrong command sequence: " + name)
            print("PASS: \(name); native exchange, exclusive protocol lines, one STATUS then one START")
        }
        let capable = String(coldBoot.dropLast()) + ",\"usb_background_supported\":true,\"usb_background\":false}"
        let disabled = String(coldBoot.dropLast()) + ",\"usb_background_supported\":false}"
        for (json, background) in [(capable, true), (disabled, false)] {
            let command = background ? "RPICO USB START BACKGROUND" : "RPICO USB START"
            let fake = try FakePico(status: "RPICO " + json + "\r\n",
                acknowledgement: "RPICO {\"accepted\":true,\"usb_background\":\(background)}\r\n",
                chunkSizes: [1, 3, 64, 2], startCommand: command)
            let result = try ReadPicoUSBTransferClient.exchange(port: fake.path, cancelled: { false })
            let commands = try fake.finish()
            precondition(result.backgroundSupported == background)
            precondition(commands == ["RPICO STATUS", command])
            print("PASS: negotiated background=\(background); actual fragmented native exchange")
        }
        for bad in ["{\"accepted\":true}", "{\"accepted\":true,\"usb_background\":false}", "{\"accepted\":true,\"usb_background\":1}"] {
            let fake = try FakePico(status: "RPICO " + capable + "\n", acknowledgement: "RPICO " + bad + "\n",
                chunkSizes: [7, 1, 5], startCommand: "RPICO USB START BACKGROUND")
            do {
                _ = try ReadPicoUSBTransferClient.exchange(port: fake.path, cancelled: { false })
                preconditionFailure("accepted missing, contradictory or non-boolean background acknowledgement")
            } catch {}
            let commands = try fake.finish()
            precondition(commands == ["RPICO STATUS", "RPICO USB START BACKGROUND"])
        }
        for fixture in ["{\"known\":true,\"charging\":true,\"external_power\":true,\"battery_percent\":86,\"revision\":9}",
                        "{\"known\":true,\"charging\":false,\"external_power\":true,\"battery_percent\":100,\"revision\":10}",
                        "{\"known\":false,\"charging\":false,\"external_power\":false,\"battery_percent\":-1,\"revision\":11}"] {
            let body = String(coldBoot.dropLast()) + ",\"power\":" + fixture + "}"
            let fake = try FakePico(status: "RPICO " + body + "\r\n", acknowledgement: "", chunkSizes: [1, 3, 7], readOnly: true)
            let result = try ReadPicoUSBTransferClient.exchange(port: fake.path, cancelled: { false }, start: false)
            precondition(result.power != nil)
            let commands = try fake.finish()
            precondition(commands == ["RPICO STATUS"], "read-only power sampling issued a START or other mutation")
        }
        print("PASS: read-only power samples use one STATUS, zero START/reset; fragmented actual POSIX exchange over private PTYs")
        print("PASS: 12 native PTY exchanges; generated pseudo-terminals only. No physical serial port, mounted disk or user settings accessed.")
    }
}
