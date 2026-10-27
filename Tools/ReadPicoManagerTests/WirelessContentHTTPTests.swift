import Foundation

private final class NetworkProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var sentBytes: Int64 = 0, verifying = false
    func receive(_ bytes: Int64, _ total: Int64, _ stage: String) {
        lock.lock(); defer { lock.unlock() }
        if stage == "sending" { sentBytes = max(sentBytes, bytes) }
        if stage == "verifying" { verifying = true }
    }
    func confirmed(_ bytes: Int64) -> Bool { lock.lock(); defer { lock.unlock() }; return sentBytes == bytes && verifying }
}

@main struct WirelessContentHTTPTests {
    static func main() async throws {
        let address = CommandLine.arguments[1], key = String(repeating: "a", count: 32)
        let connection = try ReadPicoConnection(address: address + "/manage#key=" + key)
        let client = ReadPicoHTTPClient(connection: connection)
        var checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        func mode(_ value: String) async throws {
            var request = URLRequest(url: URL(string: address + "/_fixture?mode=" + value)!)
            request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wireless-content-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("阅读+原稿 & 中文.txt")
        let original = Data("第一章\n无线同步不经过 USB。".utf8)
        try original.write(to: source)
        check(try await client.capabilities().content?.isUsable == true, "negotiated content capability")
        let initial = try await client.scan()
        check(initial.count == 3 && initial.contains { $0.kind == .drawing }, "multiple real HTTP list pages decode books and drawing originals")
        let progress = NetworkProgress()
        let path = try await client.importFile(source, kind: .book, progress: { progress.receive($0, $1, $2) })
        check(path == "books/阅读+原稿 & 中文.txt", "query preserves Chinese plus ampersand and spaces")
        check(progress.confirmed(Int64(original.count)), "actual HTTP upload reports sent bytes separately from verification")
        check(try await client.isIdentical(source, kind: .book), "server metadata digest matches local content")
        do { _ = try await client.importFile(source, kind: .book); preconditionFailure("same-name overwrite without consent") }
        catch ReadPicoManagerError.conflict { checks += 1 }
        try Data("更新正文".utf8).write(to: source)
        check(try await !client.isIdentical(source, kind: .book), "different content is never silently skipped")
        _ = try await client.importFile(source, kind: .book, replace: true)
        check(try await client.isIdentical(source, kind: .book), "explicit replacement confirms exact saved digest")
        let item = try await client.scan().first { $0.relativePath == path }!
        let exported = root.appendingPathComponent("export.txt")
        try await client.export(item, to: exported)
        check(try Data(contentsOf: exported) == Data("更新正文".utf8), "actual HTTP download exports exact file")
        let drawing = initial.first { $0.kind == .drawing }!
        let svg = root.appendingPathComponent("drawing.svg")
        try await client.export(drawing, to: svg, format: "svg")
        check(try String(contentsOf: svg, encoding: .utf8).contains("<svg"), "wireless drawing download validates and converts to SVG")
        do { try await client.remove(drawing); preconditionFailure("drawing deletion") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        let settings = ReadPicoCardFile(relativePath: "readpico/settings.dat", title: "settings", kind: .book, bytes: 4)
        do { try await client.remove(settings); preconditionFailure("settings deletion") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        try await client.remove(item)
        check(try await !client.scan().contains { $0.relativePath == path }, "wireless removal is confirmed and refreshes")
        check(try await client.scan().contains { $0.relativePath == drawing.relativePath }, "unrelated app saves remain present")
        for value in ["badlist", "duplicate", "changedtotal"] {
            try await mode(value)
            do { _ = try await client.scan(); preconditionFailure("invalid page accepted " + value) }
            catch ReadPicoManagerError.invalid { checks += 1 }
        }
        try await mode("normal")
        _ = try await client.importFile(source, kind: .book)
        try await mode("badmetadata")
        do { _ = try await client.isIdentical(source, kind: .book); preconditionFailure("wrong path receipt accepted") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        try await mode("badreceipt")
        do { _ = try await client.importFile(source, kind: .book, replace: true); preconditionFailure("wrong digest accepted") }
        catch ReadPicoManagerError.unavailable { checks += 1 }
        try await mode("busy")
        do { _ = try await client.importFile(source, kind: .book); preconditionFailure("TF exclusive ownership ignored") }
        catch ReadPicoManagerError.unavailable { checks += 1 }
        try await mode("expired")
        do { _ = try await client.scan(); preconditionFailure("expired key accepted") }
        catch ReadPicoManagerError.expired { checks += 1 }
        try await mode("redirect")
        do { _ = try await client.isIdentical(source, kind: .book); preconditionFailure("redirect accepted") }
        catch ReadPicoManagerError.http(302) { checks += 1 }
        try await mode("normal")
        let wrong = ReadPicoHTTPClient(connection: try ReadPicoConnection(address: address, setupKey: String(repeating: "b", count: 32)))
        do { _ = try await wrong.scan(); preconditionFailure("wrong key accepted") }
        catch ReadPicoManagerError.expired { checks += 1 }
        let badFont = root.appendingPathComponent("bad.otf")
        try original.write(to: badFont)
        do { _ = try await client.importFile(badFont, kind: .font); preconditionFailure("unsupported font accepted") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        do { _ = try await client.importFile(symlink, kind: .book); preconditionFailure("symlink uploaded") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        let library = try ReadPicoLocalLibrary(rootURL: root.appendingPathComponent("library"))
        let note = root.appendingPathComponent("笔记.md")
        try Data("# 无线笔记\n预览后勾选同步。".utf8).write(to: note)
        let localNote = try await library.importFile(note, kind: .note)
        let first = try await library.sync([localNote], to: client)
        check(first.count == 1 && !first[0].alreadyPresent && first[0].relativePath == "books/灵犀笔记-笔记.txt", "local staged normalized note synchronizes over Wi-Fi")
        let second = try await library.sync([localNote], to: client)
        check(second[0].alreadyPresent, "repeated local library sync skips identical file over Wi-Fi")
        print("PASS wireless Core real localhost HTTP: \(checks) checks")
    }
}
