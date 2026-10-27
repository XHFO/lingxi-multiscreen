import Foundation

/// 中文：模拟全新安装的 Flash，测试不访问真实串口。
/// English: Emulate first-install Flash; these tests never access hardware.
final class FreshInstallFake: @unchecked Sendable {
    let directory: URL
    var modern = false
    var chip = "ESP32-S3", flashSize = "16MB", encrypted = false, badTable = false, badAPP = false
    var mac = "aa:bb:cc:dd:ee:ff"
    var changedLayout = false, verifyBad = false, clearedBad = false
    var cancelOnIdentity = false
    weak var flasher: ReadPicoFirmwareFlasher?
    var calls: [[String]] = [], erases = 0, writes = 0, runs = 0
    var written: [UInt32: Data] = [:]
    init(_ directory: URL) { self.directory = directory }
    func run(_ helper: URL, _ arguments: [String], _ timeout: TimeInterval, _ log: @escaping ReadPicoFirmwareFlasher.Log) async throws -> ReadPicoProcessResult {
        calls.append(arguments)
        if arguments == ["version"] { return .init(status: 0, output: modern ? "esptool v5.1.0" : "esptool.py v4.11.0") }
        if arguments == ["--help"] {
            return .init(status: 0, output: ["read_mac", "get_security_info", "flash_id", "read_flash", "verify_flash", "write_flash", "erase_flash", "run"].map { modern ? $0.replacingOccurrences(of: "_", with: "-") : $0 }.joined(separator: " "))
        }
        check(arguments[0...3] == ["--chip", "esp32s3", "--port", "/dev/cu.usbmodemFAKE"], "first install fixed chip and serial")
        let command = arguments[12].replacingOccurrences(of: "-", with: "_")
        switch command {
        case "read_mac": return .init(status: 0, output: "Chip is \(chip)\nMAC: \(mac)")
        case "get_security_info": return .init(status: 0, output: "Flags: 0x00000000\nSecure Boot: Disabled\nFlash Encryption: \(encrypted ? "Enabled" : "Disabled")")
        case "flash_id": return .init(status: 0, output: "Detected flash size: \(flashSize)")
        case "run": runs += 1
        case "erase_flash": erases += 1; written = [:]
        case "write_flash":
            check(erases == 1 && writes == 0, "first install erases only after explicit confirmation")
            check(arguments.count == 29, "five independently addressed first install files")
            for index in stride(from: 19, to: arguments.count, by: 2) {
                let address = UInt32(arguments[index].dropFirst(2), radix: 16)!
                written[address] = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            }
            check(Set(written.keys) == Set([0, 0x8000, 0xf000, 0x20000, 0xb00000]), "first install fixed addresses")
            writes += 1
        case "read_flash":
            let address = UInt32(arguments[13].dropFirst(2), radix: 16)!, count = Int(arguments[14])!
            let url = URL(fileURLWithPath: arguments[15])
            var data: Data
            if erases > 0 {
                data = written[address] ?? Data(repeating: 0xff, count: count)
                if verifyBad && address == 0x20000 { data[0] ^= 1 }
                if clearedBad && address == 0x9000 { data[0] = 0 }
            } else if address == 0x8000 {
                data = try Data(contentsOf: directory.appendingPathComponent(changedLayout ? "pt.bin" : "different-pt.bin"))
                if badTable { data[10] ^= 1 }
            } else {
                data = try Data(contentsOf: directory.appendingPathComponent("app.bin"))
                data.append(Data(repeating: 255, count: count - data.count))
                if badAPP { data[80] = 0 }
            }
            check(data.count == count, "first install readback length")
            try data.write(to: url)
        default: fatalError("Unexpected first install command \(arguments)")
        }
        return .init(status: 0, output: "OK")
    }
}

func runFreshInstallTests(directory: URL, port: ESPSerialPort, helper: URL) async throws {
    let bundleDirectory = directory.appendingPathComponent("fresh")
    let app = bundleDirectory.appendingPathComponent("read-pico-app.bin")
    let manifest = bundleDirectory.appendingPathComponent("manifest.json")
    let parsed = try ReadPicoFirmwareValidator.freshInstallBundle(bundleDirectory)
    check(parsed.segments.count == 5 && parsed.appInfo.project == "Read_Pico", "complete curated first install bundle")

    func detect(_ fake: FreshInstallFake, _ flasher: ReadPicoFirmwareFlasher) async throws -> ReadPicoPartitionMismatch? {
        do {
            _ = try await flasher.flash(port: port, helperURL: helper, imageURL: app, manifestURL: manifest, freshInstallDirectory: bundleDirectory)
        } catch ReadPicoFirmwareError.partitionMismatch(let evidence) {
            check(fake.erases == 0 && fake.writes == 0, "partition mismatch is read-only until consent")
            return evidence
        } catch { return nil }
        return nil
    }
    for modern in [false, true] {
        let fake = FreshInstallFake(directory); fake.modern = modern
        let flasher = ReadPicoFirmwareFlasher(runner: { h,a,t,l in try await fake.run(h,a,t,l) })
        guard let evidence = try await detect(fake, flasher) else { fatalError("valid old Pico partition must offer first install") }
        check(evidence.macAddress == fake.mac && evidence.targetBundleSHA256 == parsed.sha256, "consent binds MAC, source partition and target bundle")
        check(fake.erases == 0 && fake.writes == 0, "declining or closing confirmation leaves Flash unchanged")
        let result = try await flasher.freshInstall(port: port, helperURL: helper, bundleDirectory: bundleDirectory, confirmation: evidence)
        check(fake.erases == 1 && fake.writes == 1 && fake.runs == 1 && result.restartError == nil, "confirmed first install and independent verification")
        check(fake.written[0x20000] == (try Data(contentsOf: app)), "first install preserves exact APP bytes")
        let readNames = fake.calls.filter { $0.count > 12 && $0[12] == (modern ? "read-flash" : "read_flash") }.map { $0.last! }
        check(readNames.filter { $0.contains("verify-") }.count == 8, "verify five images and three erased internal partitions")
    }
    for reason in ["chip", "flash", "security", "table", "app"] {
        let fake = FreshInstallFake(directory)
        if reason == "chip" { fake.chip = "ESP32-C6" }
        if reason == "flash" { fake.flashSize = "8MB" }
        fake.encrypted = reason == "security"; fake.badTable = reason == "table"; fake.badAPP = reason == "app"
        let flasher = ReadPicoFirmwareFlasher(runner: { h,a,t,l in try await fake.run(h,a,t,l) })
        check(try await detect(fake, flasher) == nil, "unsafe \(reason) never offers first install")
        check(fake.erases == 0 && fake.writes == 0, "unsafe \(reason) never mutates Flash")
    }
    for change in ["mac", "partition", "bundle", "cancel", "verify", "cleared"] {
        let fake = FreshInstallFake(directory)
        let flasher = ReadPicoFirmwareFlasher(runner: { h,a,t,l in
            if fake.cancelOnIdentity && a.count > 12 && a[12] == "read_mac" { _ = fake.flasher?.cancel() }
            return try await fake.run(h,a,t,l)
        })
        fake.flasher = flasher
        guard let evidence = try await detect(fake, flasher) else { fatalError("missing consent fixture") }
        let raw = try Data(contentsOf: bundleDirectory.appendingPathComponent("fresh-install.json"))
        if change == "mac" { fake.mac = "00:11:22:33:44:55" }
        if change == "partition" { fake.changedLayout = true }
        if change == "bundle" {
            // Whitespace changes preserve valid JSON but invalidate the exact consent binding.
            try (raw + Data("\n".utf8)).write(to: bundleDirectory.appendingPathComponent("fresh-install.json"))
        }
        if change == "cancel" { fake.cancelOnIdentity = true }
        fake.verifyBad = change == "verify"; fake.clearedBad = change == "cleared"
        await asyncRejects("first install rejects changed \(change)") {
            _ = try await flasher.freshInstall(port: port, helperURL: helper, bundleDirectory: bundleDirectory, confirmation: evidence)
        }
        try raw.write(to: bundleDirectory.appendingPathComponent("fresh-install.json"))
        check(fake.runs == 0 && fake.erases == (["verify", "cleared"].contains(change) ? 1 : 0), "changed \(change) fails at correct side of erase boundary")
    }
    let fake = FreshInstallFake(directory), gate = Gate()
    let flasher = ReadPicoFirmwareFlasher(runner: { h,a,t,l in
        if a.count > 12 && a[12] == "erase_flash" { await gate.pause() }
        return try await fake.run(h,a,t,l)
    })
    guard let evidence = try await detect(fake, flasher) else { fatalError("missing protected fixture") }
    let operation = Task { try await flasher.freshInstall(port: port, helperURL: helper, bundleDirectory: bundleDirectory, confirmation: evidence) }
    for _ in 0..<2000 { if await gate.started { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    check(await gate.started && !flasher.cancel() && !ReadPicoFirmwareFlasher.prepareForApplicationTermination(), "erase-through-verification blocks cancellation and app exit")
    operation.cancel(); await gate.release()
    _ = try await operation.value
    check(fake.runs == 1 && !ReadPicoFirmwareFlasher.hasNonCancellableOperations, "protected first install completes verified boot request after cancellation")
}
