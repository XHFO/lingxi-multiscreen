import Foundation
import LinxDisplayCore

private actor WirelessDevice: ReadPicoManagerDeviceClient {
    private var files: [ReadPicoCardFile] = []
    private var imports = 0, scans = 0
    private var failNext = false
    private var hold = false, entered = false
    func fail() { failNext = true }
    func holdNext() { hold = true; entered = false }
    func release() { hold = false }
    func waitForImport() async throws { while !entered { try await Task.sleep(nanoseconds: 1_000_000) } }
    func counts() -> (Int, Int) { (imports, scans) }
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":false},"saved_wifi":[],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4],"state":"displayed","revision":1},"content":{"supported":true,"max_bytes":268435456,"max_page_items":64}}"#.utf8))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
    func scan() async throws -> [ReadPicoCardFile] { scans += 1; return files }
    func proposedPath(for source: URL, kind: ReadPicoFileKind) async throws -> String { "books/" + source.lastPathComponent }
    func isIdentical(_ source: URL, kind: ReadPicoFileKind) async throws -> Bool { files.contains { $0.relativePath == "books/" + source.lastPathComponent } }
    func importFile(_ source: URL, kind: ReadPicoFileKind, replace: Bool, progress: (@Sendable (Int64, Int64, String) -> Void)?) async throws -> String {
        entered = true
        while hold { try await Task.sleep(nanoseconds: 1_000_000) }
        try Task.checkCancellation()
        if failNext { failNext = false; throw ReadPicoManagerError.unavailable("TF 正由 USB 独占") }
        imports += 1
        let path = "books/" + source.lastPathComponent, size = Int64(try Data(contentsOf: source).count)
        files.removeAll { $0.relativePath == path }
        files.append(.init(relativePath: path, title: source.lastPathComponent, kind: kind, bytes: size))
        progress?(size, size, "completed")
        return path
    }
    func remove(_ item: ReadPicoCardFile) async throws { files.removeAll { $0.id == item.id } }
    func export(_ item: ReadPicoCardFile, to destination: URL, format: String) async throws { try Data("wireless-export".utf8).write(to: destination) }
}

@MainActor private func idle(_ model: ReadPicoManagerModel) async throws {
    for _ in 0..<2000 { if !model.busy { return }; try await Task.sleep(nanoseconds: 1_000_000) }
    preconditionFailure("wireless model did not settle")
}

@main struct WirelessContentModelTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ text: String) { checks += 1; precondition(condition, text) }
        let device = WirelessDevice()
        let model = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { ["/fixture/never-open"] },
                                       identifyUSBPort: { _ in "fixture-device" }, makeClient: { _ in device })
        let address = "http://fixture.invalid/manage#key=" + String(repeating: "a", count: 32)
        check(model.connect(address: address, key: ""), "valid Wi-Fi begins pairing")
        try await idle(model)
        check(model.canManageContent && model.usesWirelessContent && model.store == nil, "validated Wi-Fi enables content without USB")
        check(model.automaticUSBPreparationCandidate(selectedPort: "") == nil, "Wi-Fi pairing prevents eager automatic USB handoff")
        let identity = model.boardConnectionIdentity
        model.prepareUSBBoardConnection()
        check(!model.busy && model.connection != nil, "board connection preparation preserves valid Wi-Fi")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wireless-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("demo.txt")
        try Data("正文".utf8).write(to: book)
        model.install([book], kind: .book, replace: false)
        try await idle(model)
        check(!model.isError && model.files.count == 1 && model.message.contains("无需 USB"), "install uses existing wireless client and refreshes")
        check(model.connection != nil && model.boardConnectionIdentity == identity, "content operation preserves same authenticated session")
        let exported = root.appendingPathComponent("export.txt")
        model.export(model.files[0], to: exported, format: "dat")
        try await idle(model)
        check(try String(contentsOf: exported, encoding: .utf8) == "wireless-export", "export chooses same Wi-Fi content client")
        model.remove(model.files[0]); try await idle(model)
        check(model.files.isEmpty && model.connection != nil, "remove and refresh reuse pairing")
        let library = try ReadPicoLocalLibrary(rootURL: root.appendingPathComponent("library"))
        let item = try await library.importFile(book, kind: .book)
        var completed: Bool?, progressCount = 0
        model.synchronizeLibrary([item], library: library, progress: { _ in progressCount += 1 }, completion: { completed = $0 })
        try await idle(model)
        check(completed == true && !model.isError && model.files.count == 1, "staged local library synchronizes wirelessly")
        check(progressCount > 0, "wireless sync publishes per-file progress")
        let installed = await device.counts().0
        completed = nil
        model.synchronizeLibrary([item], library: library, progress: { _ in }, completion: { completed = $0 })
        try await idle(model)
        let afterRepeat = await device.counts().0
        check(completed == true && afterRepeat == installed && model.message.contains("跳过相同内容 1"), "repeated sync skips same remote content")
        await device.fail()
        model.install([book], kind: .book, replace: true); try await idle(model)
        check(model.isError && model.message.contains("独占") && model.connection != nil, "503-style storage failure retains pairing without USB fallback")
        let card = root.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        model.selectCard(card); try await idle(model)
        check(model.usesWirelessContent && model.boardConnectionIdentity == identity, "auto keeps validated Wi-Fi even when a TF folder is selected")
        model.transportPreference = .usb; model.reload(); try await idle(model)
        check(model.canManageContent && !model.usesWirelessContent && model.files.isEmpty, "forced USB reads mounted TF without touching Wi-Fi client")
        model.transportPreference = .wifi; model.reload(); try await idle(model)
        check(model.usesWirelessContent && model.files.count == 1 && model.boardConnectionIdentity == identity, "forced Wi-Fi returns to same paired session")
        await device.holdNext()
        model.install([book], kind: .book, replace: true)
        try await device.waitForImport()
        model.cancelOperation(); await device.release(); try await idle(model)
        check(!model.busy && model.connection != nil && model.message.contains("已停止"), "cancel stops upload wait and preserves confirmed session")
        model.disconnect()
        check(model.connection == nil && !model.canManageContent && model.files.isEmpty, "Wi-Fi-only disconnect clears stale list and has no implicit USB fallback")
        model.install([book], kind: .book, replace: false)
        check(!model.busy && model.isError, "disconnected explicit Wi-Fi preference cannot write selected USB folder")
        print("PASS wireless Manager model: \(checks) checks; injected device and temporary library/card only")
    }
}
