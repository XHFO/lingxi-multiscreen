import Foundation
import CoreGraphics
import ImageIO

private var assertions = 0
private func check(_ value: Bool, _ note: String) {
    assertions += 1
    if !value { fatalError(note) }
}
private func reject(_ note: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: " + note) } catch { assertions += 1 }
}
private func put(_ data: inout Data, _ offset: Int, _ value: UInt32) { for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) } }
private func word(_ data: Data, _ offset: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) } }
private func package(id: String = "drawing-notes", kind: UInt32 = 128, target: String = "esp32s3-xtensa") -> Data {
    var data = Data(repeating: 0, count: 516); data.replaceSubrange(0..<8, with: Data("PICOAPP1".utf8))
    put(&data, 8, 1); put(&data, 12, 512); put(&data, 16, 516); put(&data, 20, 1); put(&data, 24, 10001); put(&data, 28, kind)
    for (offset, string) in [(32, id), (64, "画板"), (128, "笔迹工具"), (256, target)] { data.replaceSubrange(offset..<(offset + string.utf8.count), with: Data(string.utf8)) }
    put(&data, 228, 1); put(&data, 272, 512); put(&data, 276, 4); data.replaceSubrange(512..<516, with: [1, 2, 3, 4]); put(&data, 280, readPicoCRC32(data.subdata(in: 512..<516)))
    put(&data, 232, readPicoCRC32(data.subdata(in: 0..<512))); return data
}
private func headerCRC(_ data: inout Data) { put(&data, 232, 0); put(&data, 232, readPicoCRC32(data.subdata(in: 0..<512))) }
private func drawing() -> Data {
    var data = Data(repeating: 0, count: 12 + 49168); put(&data, 0, 0x31535058); put(&data, 4, 49168); put(&data, 12, 0x314e4450)
    data[16] = 1; data[18] = 232; data[19] = 3; data[20] = 120; data[21] = 5; data[22] = 3
    for (index, point) in [(100, 120, 5, 1), (500, 640, 5, 0), (900, 1200, 12, 3)].enumerated() {
        let offset = 28 + index * 6; data[offset] = UInt8(truncatingIfNeeded: point.0); data[offset + 1] = UInt8(point.0 >> 8); data[offset + 2] = UInt8(truncatingIfNeeded: point.1); data[offset + 3] = UInt8(point.1 >> 8); data[offset + 4] = UInt8(point.2); data[offset + 5] = UInt8(point.3)
    }
    put(&data, 8, readPicoCRC32(data.subdata(in: 12..<data.count))); return data
}
private final class FakeHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor AcceptedEvents {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}
@main struct ReadPicoTests {
    static func main() async throws {
        check(readPicoCRC32(Data("123456789".utf8)) == 0xcbf43926, "IEEE CRC32")
        let valid = package(), metadata = try ReadPicoPackage(data: valid)
        check(metadata.id == "drawing-notes" && metadata.isTool && metadata.title == "画板" && metadata.versionLabel == "1.0.1", "PGA metadata")
        for bytes in 0..<512 { reject("short PGA") { _ = try ReadPicoPackage(data: valid.prefix(bytes)) } }
        for offset in 0..<512 { var damaged = valid; damaged[offset] ^= 0x80; reject("header checksum") { _ = try ReadPicoPackage(data: damaged) } }
        var bad = valid; bad[512] ^= 1; reject("payload checksum") { _ = try ReadPicoPackage(data: bad) }
        bad = valid; put(&bad, 272, 0xfffffff0); headerCRC(&bad); reject("payload overflow") { _ = try ReadPicoPackage(data: bad) }
        bad = valid; put(&bad, 228, 0xffffffff); headerCRC(&bad); reject("payload count") { _ = try ReadPicoPackage(data: bad) }
        bad = valid; bad[236] = 1; headerCRC(&bad); reject("reserved") { _ = try ReadPicoPackage(data: bad) }
        bad = valid; bad[33] = 0; headerCRC(&bad); reject("string padding") { _ = try ReadPicoPackage(data: bad) }
        reject("invalid stable ID") { _ = try ReadPicoPackage(data: package(id: "../oops")) }
        reject("native-only") { _ = try ReadPicoPackage(data: package(target: "macos-arm64")) }
        check(try ReadPicoPackage(data: package(target: "macos-arm64"), requireDevice: false).targets == ["macos-arm64"], "explicit native parsing")
        let vector = try ReadPicoDrawing(data: drawing())
        check(vector.width == 1000 && vector.height == 1400 && vector.points.count == 3 && vector.points[2].eraser, "drawing layout")
        let svg = String(data: vector.svg(), encoding: .utf8)!
        check(svg.contains("stroke=\"black\"") && svg.contains("fill=\"white\"") && svg.contains("M100 120L500 640"), "SVG pens/erasers")
        let png = try vector.png(); check(png.starts(with: [137, 80, 78, 71]), "PNG export")
        for offset in [0, 4, 8, 12, 16, 18, 20, 22, 28, 32] { var data = drawing(); data[offset] ^= 128; reject("drawing corruption") { _ = try ReadPicoDrawing(data: data) } }
        let files = FileManager.default, temporary = files.temporaryDirectory.appendingPathComponent("readpico-test-" + UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true); defer { try? files.removeItem(at: temporary) }
        let card = temporary.appendingPathComponent("card"), input = temporary.appendingPathComponent("input")
        try files.createDirectory(at: card, withIntermediateDirectories: true); try files.createDirectory(at: input, withIntermediateDirectories: true)
        let store = try ReadPicoTFStore(rootURL: card), book = input.appendingPathComponent("阅读测试.txt"), app = input.appendingPathComponent("arbitrary.pga")
        try Data("第一章\n你好".utf8).write(to: book); try valid.write(to: app)
        check(try await store.importFile(book, kind: .book) == "books/阅读测试.txt", "book install")
        check(try await store.importFile(app, kind: .application) == "apps/tools/drawing-notes.pga", "stable ID/category install")
        do { try await store.importFile(book, kind: .book); fatalError("unconfirmed replace") } catch { assertions += 1 }
        try Data("新的正文".utf8).write(to: book); try await store.importFile(book, kind: .book, replace: true)
        check(try Data(contentsOf: card.appendingPathComponent("books/阅读测试.txt")) == Data("新的正文".utf8), "verified replace")
        let saves = card.appendingPathComponent("apps/data/drawing-notes"); try files.createDirectory(at: saves, withIntermediateDirectories: true)
        let original = drawing(); try original.write(to: saves.appendingPathComponent("board01.dat"))
        try Data("保留".utf8).write(to: card.appendingPathComponent("progress.dat"))
        var items = try await store.scan(); check(items.count == 3 && items.allSatisfy(\.valid), "scan books/app/drawing")
        let drawingFile = items.first { $0.kind == .drawing }!; try await store.export(drawingFile, to: temporary.appendingPathComponent("drawing.svg"), format: "svg")
        check(try Data(contentsOf: temporary.appendingPathComponent("drawing.svg")) == vector.svg(), "real SVG export")
        try await store.export(drawingFile, to: temporary.appendingPathComponent("original.dat")); check(try Data(contentsOf: temporary.appendingPathComponent("original.dat")) == original, "raw original exact")
        let appFile = items.first { $0.kind == .application }!; try valid.write(to: card.appendingPathComponent(appFile.relativePath + ".bak")); try await store.remove(appFile)
        check(!files.fileExists(atPath: card.appendingPathComponent(appFile.relativePath).path) && !files.fileExists(atPath: card.appendingPathComponent(appFile.relativePath + ".bak").path), "app remove cannot resurrect backup")
        check(try Data(contentsOf: saves.appendingPathComponent("board01.dat")) == original && files.fileExists(atPath: card.appendingPathComponent("progress.dat").path), "saves preserved")
        try files.removeItem(at: card.appendingPathComponent("books")); try files.createSymbolicLink(at: card.appendingPathComponent("books"), withDestinationURL: input)
        do { try await store.importFile(book, kind: .book); fatalError("symlink escaped card") } catch { assertions += 1 }
        let key = String(repeating: "a", count: 32), connection = try ReadPicoConnection(address: "http://127.0.0.1:8783/manage?session=" + String(repeating: "b", count: 32) + "#key=" + key)
        check(connection.baseURL.absoluteString == "http://127.0.0.1:8783" && connection.setupKey == key && connection.managementURL.fragment == "key=" + key, "ephemeral connection parses QR")
        reject("missing setup key") { _ = try ReadPicoConnection(address: "http://192.168.1.5") }
        reject("credential URL") { _ = try ReadPicoConnection(address: "http://user:password@localhost/#key=" + key) }
        reject("foreign scheme") { _ = try ReadPicoConnection(address: "file:///tmp/#key=" + key) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakeHTTP.self]
        let client = ReadPicoHTTPClient(connection: connection, session: URLSession(configuration: config))
        FakeHTTP.handler = { request in
            check(request.value(forHTTPHeaderField: "X-Pico-Setup-Key") == key, "setup key header")
            check(request.value(forHTTPHeaderField: "X-Pico-Preview-Session") == String(repeating: "b", count: 32), "preview isolation header")
            if request.url!.path == "/api/manage/home" && request.httpMethod == "GET" { return (200, Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":true},"saved_wifi":["Home"],"network_online":true}"#.utf8)) }
            if request.url!.path == "/api/manage/home" { return (200, Data(#"{"ok":true}"#.utf8)) }
            return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
        let snapshot = try await client.home(); check(snapshot.savedWifi == ["Home"] && snapshot.config.hasToken, "real home decoder")
        try await client.saveHome(snapshot.config, token: "transient-secret")
        do { _ = try await client.capabilities(); fatalError("invented capability") } catch { assertions += 1 }
        for landscape in [false, true] {
            let width = landscape ? 1216 : 684, height = landscape ? 684 : 1216
            let bmp = try ReadPicoBitmap.make(image: vector.image(), width: width, height: height)
            check(bmp.count == 62 + ((width + 31) / 32 * 4) * height && bmp.count <= 110000 && word(bmp, 18) == width && word(bmp, 22) == height && bmp[28] == 1 && word(bmp, 30) == 0, "exact BMP protocol")
            check(CGImageSourceCreateWithData(bmp as CFData, nil) != nil, "BMP decodes")
            let caps = try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data("{\"protocol\":1,\"canvas\":{\"supported\":true,\"width\":\(width),\"height\":\(height),\"formats\":[\"image/bmp\"],\"max_bytes\":110000}}".utf8))
            FakeHTTP.handler = { request in check(request.url!.path == "/api/manage/pico/canvas" && request.value(forHTTPHeaderField: "Content-Type") == "image/bmp", "canvas request protocol"); return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            try await client.pushCanvas(bmp, capability: caps.canvas)
        }
        var polls = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "PUT" {
                check(request.url!.path == "/api/manage/pico/config", "real device config route")
                return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
            }
            polls += 1
            let state = polls > 2 ? 2 : polls == 2 ? 1 : 0, revision = polls > 2 ? 8 : 7
            return (200, Data("{\"protocol\":1,\"canvas\":{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"max_bytes\":110000},\"config\":{\"auto_sleep_minutes\":10,\"double_tap_wake\":true,\"state\":\(state),\"revision\":\(revision)}}".utf8))
        }
        let committed = try await client.saveDeviceConfiguration(ReadPicoDeviceConfiguration(autoSleepMinutes: 10))
        check(committed.config?.state == 2 && committed.config?.revision == 8 && polls == 3, "202 acceptance waits for committed revision")
        polls = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "PUT" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            if polls > 1 { throw URLError(.notConnectedToInternet) }
            return (200, Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":110000},"config":{"auto_sleep_minutes":3,"double_tap_wake":true,"state":0,"revision":7}}"#.utf8))
        }
        do { _ = try await client.saveDeviceConfiguration(ReadPicoDeviceConfiguration(autoSleepMinutes: 10)); fatalError("disconnected accepted settings reported saved") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("已提交") && message.contains("尚未确认"), "post-acceptance connection loss keeps settings unconfirmed") }
        check(polls == 2, "settings connection failure is reported after acceptance without resubmission")
        var pixels = Data(repeating: 255, count: 684 * 1216); pixels.replaceSubrange(0..<(684 * 608), with: repeatElement(UInt8(0), count: 684 * 608))
        let source = CGImage(width: 684, height: 1216, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 684, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let oriented = try ReadPicoBitmap.make(image: source, width: 684, height: 1216, dither: false), stride = ((684 + 31) / 32 * 4)
        check(oriented[62 + 1215 * stride + 40] == 0 && oriented[62 + 40] == 255, "BMP preserves top/bottom image orientation")
        func canvasStatus(_ state: String?, revision: UInt32?) -> Data {
            var canvas: [String: Any] = ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 110000]
            if let state { canvas["state"] = state }
            if let revision { canvas["revision"] = revision }
            return try! JSONSerialization.data(withJSONObject: ["protocol": 1, "canvas": canvas])
        }
        let initialCanvas = try JSONDecoder().decode(ReadPicoCapabilities.self, from: canvasStatus("idle", revision: 20)).canvas
        polls = 0
        let events = AcceptedEvents()
        FakeHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            // A stale "displayed" must never confirm this new submission.
            return (200, canvasStatus(polls == 1 ? "idle" : polls == 3 ? "pending" : "displayed", revision: polls < 3 ? 20 : 21))
        }
        let shown = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas) { await events.record() }
        check(shown.canvas.state == "displayed" && shown.canvas.revision == 21 && polls == 4, "canvas waits for new revision and actual presentation")
        check(await events.count() == 1, "submission progress is separate from display confirmation")
        polls = 0
        var savedPosts = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "POST" { savedPosts += 1; return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            return (200, canvasStatus(polls == 1 ? "idle" : "saved", revision: polls < 3 ? 20 : 21))
        }
        let savedCanvas = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas)
        check(savedCanvas.canvas.state == "saved" && savedCanvas.canvas.revision == 21 && polls == 3 && savedPosts == 1,
              "Saved returns delivery without inventing display; stale saved revision cannot confirm a new POST")
        polls = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            return (200, canvasStatus(polls == 1 ? "idle" : "error", revision: polls == 1 ? 20 : 21))
        }
        do { _ = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas); fatalError("display failure reported success") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("未完成画布显示"), "display error is actionable") }
        polls = 0
        FakeHTTP.handler = { request in
            check(request.httpMethod == "GET", "older status cannot submit an unconfirmable canvas")
            return (200, canvasStatus(nil, revision: nil))
        }
        do { _ = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas); fatalError("legacy capability invented confirmation") }
        catch ReadPicoManagerError.unavailable { assertions += 1 }
        polls = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            return (200, canvasStatus(polls == 1 ? "idle" : "pending", revision: polls == 1 ? 20 : 21))
        }
        do { _ = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas); fatalError("pending canvas reported success") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("已提交") && message.contains("尚未确认"), "timeout explicitly preserves accepted versus displayed distinction") }
        check(polls == 49, "bounded display confirmation polling")
        polls = 0
        FakeHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            if polls > 1 { throw URLError(.notConnectedToInternet) }
            return (200, canvasStatus("idle", revision: 20))
        }
        do { _ = try await client.pushCanvasConfirmed(oriented, capability: initialCanvas); fatalError("disconnected accepted canvas reported displayed") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("已提交") && message.contains("尚未确认"), "post-acceptance connection loss keeps canvas display unconfirmed") }
        check(polls == 2, "canvas connection failure is reported after acceptance without resubmission")
        FakeHTTP.handler = { _ in (401, Data("{}".utf8)) }
        do { _ = try await client.home(); fatalError("expired setup success") } catch ReadPicoManagerError.expired { assertions += 1 }
        items = []; print("PASS: \(assertions) Read Pico package, TF transaction, original export, authenticated HTTP and BMP checks; no physical device modified.")
    }
}
