import AppKit
import Foundation

private final class PairHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct CanvasPairTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func put(_ data: inout Data, _ at: Int, _ value: UInt32) {
            for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        func image(_ width: Int, _ height: Int) throws -> Data {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try ReadPicoBitmap.makeGray16(image: ctx.makeImage()!, width: width, height: height)
        }
        func rejected(_ data: Data, _ label: String) {
            do { try ReadPicoCanvasPair.validate(data); fatalError(label) } catch { checks += 1 }
        }
        func status(dual: Bool = true, state: String = "saved", revision: Int = 1) -> Data {
            try! JSONSerialization.data(withJSONObject: ["protocol": 1, "canvas": ["supported":true,"width":684,"height":1216,
                "formats":["image/bmp"],"max_bytes":420000,"bit_depths":[1,4],"gray_levels":16,"display_intent":true,
                "dual_orientation":dual,"pair_max_bytes":840032,"state":state,"revision":revision,"orientation":"landscape"]])
        }
        let portrait = try image(684, 1216), landscape = try image(1216, 684)
        let pair = try ReadPicoCanvasPair.encode(portrait: portrait, landscape: landscape)
        check(pair.count == 834444 && ReadPicoCanvasPair.isPair(pair), "Both full-resolution layouts share one precise envelope")
        check(pair.subdata(in: 32..<(32 + portrait.count)) == portrait && pair.suffix(landscape.count) == landscape, "Pair carries exact portrait then landscape pixels")
        let cap = try JSONDecoder().decode(ReadPicoCapabilities.self, from: status()).canvas
        check(cap.supportsDualOrientation && cap.orientation == "landscape", "Explicit dual capability retains active device orientation")
        check(!(try JSONDecoder().decode(ReadPicoCapabilities.self, from: status(dual: false))).canvas.supportsDualOrientation, "A byte budget alone never enables a pair")
        let wrappedPair = Data([123]) + pair
        try ReadPicoCanvasPair.validate(wrappedPair.dropFirst())
        check(ReadPicoCanvasPair.isPair(wrappedPair.dropFirst()), "Sliced Data with nonzero startIndex is parsed safely")
        rejected(Data(pair.dropLast()), "Truncation")
        rejected(pair + Data([0]), "Trailing bytes")
        for field in [0, 8, 12, 16, 20, 24, 28, 32 + 118, pair.count - 1] {
            var bad = pair; bad[field] ^= 1; rejected(bad, "Corrupt header or payload at \(field)")
        }
        var overflow = pair; put(&overflow, 16, UInt32.max); rejected(overflow, "Overflow length")
        do { _ = try ReadPicoCanvasPair.encode(portrait: landscape, landscape: portrait); fatalError("Swapped orientation") } catch { checks += 1 }
        do { _ = try ReadPicoCanvasPair.encode(portrait: portrait, landscape: portrait); fatalError("Duplicated portrait") } catch { checks += 1 }
        var binary = landscape; binary[28] = 1
        do { _ = try ReadPicoCanvasPair.encode(portrait: portrait, landscape: binary); fatalError("Non-native depth") } catch { checks += 1 }
        var topDown = portrait; put(&topDown, 22, UInt32(bitPattern: -1216))
        try ReadPicoCanvasPair.validate(ReadPicoCanvasPair.encode(portrait: topDown, landscape: landscape)); checks += 1
        let connection = try ReadPicoConnection(address: "http://fixture.invalid/#key=" + String(repeating: "a", count: 32))
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [PairHTTP.self]
        let client = ReadPicoHTTPClient(connection: connection, session: URLSession(configuration: cfg))
        func body(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(buffer, count: n) }
            return result
        }
        for display in [false, true] {
            var posts = 0, polls = 0
            PairHTTP.handler = { request in
                check(request.value(forHTTPHeaderField: "X-Pico-Setup-Key") == String(repeating: "a", count: 32), "Pair remains authenticated")
                if request.httpMethod == "POST" {
                    posts += 1
                    check(request.url?.path == "/api/manage/pico/canvas/pair" + (display ? "/show" : ""), "Pair uses a single intent-specific endpoint")
                    check(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.readpico.canvas-pair", "Dedicated pair MIME")
                    check(body(request) == pair, "One request contains both exact layouts")
                    return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
                }
                polls += 1
                return (200, status(state: polls == 1 ? "saved" : (display ? "displayed" : "saved"), revision: polls == 1 ? 1 : 2))
            }
            let receipt = try await client.pushCanvasConfirmed(pair, capability: cap, display: display)
            check(posts == 1 && polls == 2 && receipt.canvas.revision == 2, "Only a new atomic revision confirms the pair")
            check(receipt.canvas.state == (display ? "displayed" : "saved"), "Background saving and display receipt stay distinct")
        }
        // A normal board revision must never acknowledge the independent Cloudflare app.
        func appStatus(appRevision: Int, canvasRevision: Int, supported: Bool = true, receipt: Bool = true) -> Data {
            var object = try! JSONSerialization.jsonObject(with: status(revision: canvasRevision)) as! [String: Any]
            var canvas = object["canvas"] as! [String: Any]
            if supported { canvas["app_channels"] = ["cloudflare"] }
            if receipt { canvas["app_receipts"] = ["cloudflare": ["state": "saved", "revision": appRevision, "orientation": "portrait"]] }
            object["canvas"] = canvas
            return try! JSONSerialization.data(withJSONObject: object)
        }
        let appCap = try JSONDecoder().decode(ReadPicoCapabilities.self, from: appStatus(appRevision: 4, canvasRevision: 1)).canvas
        check(appCap.supports(.cloudflare) && cap.supports(.canvas) && !cap.supports(.cloudflare), "App channels require explicit negotiation; old boards remain compatible")
        for display in [false, true] {
            var appPosts = 0, appPolls = 0
            PairHTTP.handler = { request in
                if request.httpMethod == "POST" {
                    appPosts += 1
                    check(request.url?.path == "/api/manage/pico/apps/cloudflare/pair" + (display ? "/show" : ""), "Independent app gets its own intent-specific endpoint")
                    check(body(request) == pair, "App channel preserves the full PICOPAIR envelope")
                    return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
                }
                appPolls += 1
                return (200, appStatus(appRevision: appPolls < 3 ? 4 : 5, canvasRevision: appPolls))
            }
            let receipt = try await client.pushCanvasConfirmed(pair, capability: appCap, display: display, contentChannel: .cloudflare)
            check(appPosts == 1 && appPolls == 3 && receipt.canvas.receipt(for: .cloudflare)?.revision == 5,
                  "Only a new app revision acknowledges the app; ordinary canvas updates are ignored")
        }
        for missingReceipt in [false, true] {
            var blockedPosts = 0
            PairHTTP.handler = { request in
                if request.httpMethod == "POST" { blockedPosts += 1 }
                return (200, appStatus(appRevision: 4, canvasRevision: 2, supported: missingReceipt, receipt: !missingReceipt))
            }
            do { _ = try await client.pushCanvasConfirmed(pair, capability: appCap, display: false, contentChannel: .cloudflare); fatalError("Missing app negotiation accepted") }
            catch { check(blockedPosts == 0, "Missing channel or app receipt blocks before POST") }
        }
        var appSinglePosts = 0
        PairHTTP.handler = { _ in appSinglePosts += 1; return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
        do { try await client.pushCanvas(portrait, capability: appCap, display: false, contentChannel: .cloudflare); fatalError("Single layout app accepted") }
        catch { check(appSinglePosts == 0, "Apps require a complete pair without downgrading") }
        var posts = 0
        PairHTTP.handler = { request in if request.httpMethod == "POST" { posts += 1 }; return (200, status(dual: false)) }
        do { _ = try await client.pushCanvasConfirmed(pair, capability: cap); fatalError("Legacy accepted pair") }
        catch { check(posts == 0, "Missing device pair capability rejects before submission") }
        PairHTTP.handler = { request in posts += 1; return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
        var corrupt = pair; corrupt[40] ^= 1
        do { try await client.pushCanvas(corrupt, capability: cap); fatalError("Corrupt pair posted") }
        catch { check(posts == 0, "Malformed pair never reaches network") }
        PairHTTP.handler = { request in
            check(request.url?.path == "/api/manage/pico/canvas" && request.value(forHTTPHeaderField: "Content-Type") == "image/bmp", "Existing single canvas contract retained")
            return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
        }
        try await client.pushCanvas(portrait, capability: cap)
        print("PASS \(checks) atomic orientation pair encoding, CRC, native dimensions, capability, authenticated HTTP and receipt checks")
    }
}
