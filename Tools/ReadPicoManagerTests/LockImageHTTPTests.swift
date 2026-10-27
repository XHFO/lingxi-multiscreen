import Foundation
import CoreGraphics

private final class LockHTTP: URLProtocol, @unchecked Sendable {
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
private actor LockEvents {
    var count = 0
    func accepted() { count += 1 }
}
private func status(protocolVersion: Int = 1, supported: Bool = true, available: Bool = true,
                    state: String = "saved", revision: Int = 4, imageLock: Bool = true,
                    lockStyle: Int? = 0, configState: Int = 0, configRevision: Int = 2, nativeGray16: Bool = false) -> Data {
    var configuration: [String: Any] = ["auto_sleep_minutes": 5, "double_tap_wake": true, "state": configState, "revision": configRevision]
    if let lockStyle { configuration["lock_style"] = lockStyle }
    var body: [String: Any] = ["protocol": protocolVersion,
        "canvas": ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 110000], "config": configuration]
    if imageLock {
        var image: [String: Any] = ["supported": supported, "available": available, "state": state, "revision": revision, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": nativeGray16 ? 420000 : 110000]
        if nativeGray16 { image["bit_depths"] = [1, 4]; image["gray_levels"] = 16 }
        body["image_lock"] = image
    }
    return try! JSONSerialization.data(withJSONObject: body)
}
@main struct LockImageHTTPTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        let key = String(repeating: "a", count: 32), preview = String(repeating: "b", count: 32)
        let connection = try ReadPicoConnection(address: "http://fixture.invalid/manage?session=" + preview + "#key=" + key)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LockHTTP.self]
        let client = ReadPicoHTTPClient(connection: connection, session: URLSession(configuration: configuration))
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let bitmap = try ReadPicoBitmap.make(image: context.makeImage()!, width: 684, height: 1216)
        let legacy = try JSONDecoder().decode(ReadPicoCapabilities.self, from: status(imageLock: false, lockStyle: nil))
        check(legacy.imageLock == nil && legacy.config?.lockStyle == nil, "legacy capabilities/config remain decodable")
        check(try JSONDecoder().decode(ReadPicoDeviceConfiguration.self, from: Data(#"{"auto_sleep_minutes":5,"double_tap_wake":true,"state":0,"revision":2}"#.utf8)).lockStyle == nil, "legacy config defaults no lock style")
        LockHTTP.handler = { request in
            check(request.value(forHTTPHeaderField: "X-Pico-Setup-Key") == key, "image uses pairing header")
            check(request.value(forHTTPHeaderField: "X-Pico-Preview-Session") == preview, "image keeps preview session isolation")
            check(request.url?.query == nil && request.url?.fragment == nil, "credentials excluded from request URL")
            if request.url?.path == "/api/manage/pico/status" { return (200, status()) }
            check(request.url?.path == "/api/manage/pico/lock-image" && request.httpMethod == "GET", "authenticated image route")
            return (200, bitmap)
        }
        check(try await client.lockImage() == bitmap, "device BMP read returns exact bytes")
        LockHTTP.handler = { request in request.url?.path.hasSuffix("status") == true ? (200, status()) : (401, Data()) }
        do { _ = try await client.lockImage(); fatalError("unauthenticated image read") }
        catch ReadPicoManagerError.expired { checks += 1 }
        LockHTTP.handler = { request in request.url?.path.hasSuffix("status") == true ? (200, status()) : (200, bitmap.prefix(62)) }
        do { _ = try await client.lockImage(); fatalError("truncated BMP accepted") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        var polls = 0, posts = 0
        let accepted = LockEvents()
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1; check(request.url?.path == "/api/manage/pico/lock-image", "lock upload is separate from canvas")
                check(request.value(forHTTPHeaderField: "Content-Type") == "image/bmp", "binary image MIME")
                return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
            }
            polls += 1
            // Saved with the old revision, then a new pending revision, are both unconfirmed.
            return (200, status(state: polls == 3 ? "pending" : "saved", revision: polls < 3 ? 4 : 5))
        }
        let saved = try await client.saveLockImageConfirmed(bitmap) { await accepted.accepted() }
        check(posts == 1 && polls == 4 && saved.imageLock?.revision == 5, "202 and pending require new saved revision")
        check(await accepted.count == 1, "accepted callback is distinct from save confirmation")
        polls = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1; return (200, status(state: polls == 1 ? "saved" : "error", revision: polls == 1 ? 4 : 5))
        }
        do { _ = try await client.saveLockImageConfirmed(bitmap); fatalError("error state saved") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("保存失败"), "error states remain unconfirmed") }
        polls = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1
            if polls > 1 { throw URLError(.networkConnectionLost) }
            return (200, status())
        }
        do { _ = try await client.saveLockImageConfirmed(bitmap); fatalError("disconnect reported saved") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("尚未确认保存"), "post-acceptance disconnect keeps draft unconfirmed") }
        for mode in ["missing", "protocol", "unsupported"] {
            polls = 0; posts = 0
            LockHTTP.handler = { request in
                if request.httpMethod == "POST" { posts += 1; return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
                polls += 1
                return (200, polls == 1 ? status() : status(protocolVersion: mode == "protocol" ? 2 : 1, supported: mode != "unsupported", revision: 5, imageLock: mode != "missing"))
            }
            do { _ = try await client.saveLockImageConfirmed(bitmap); fatalError("changed \(mode) capability saved") }
            catch ReadPicoManagerError.unavailable { checks += 1 }
            check(posts == 1, "capability loss never resubmits")
        }
        polls = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" { return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1; return (200, status(state: polls == 1 ? "saved" : "pending", revision: polls == 1 ? 4 : 5))
        }
        do { _ = try await client.saveLockImageConfirmed(bitmap); fatalError("permanent pending saved") }
        catch ReadPicoManagerError.unavailable(let message) { check(message.contains("尚未确认保存") && polls == 49, "pending expires without falsely clearing draft") }
        polls = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "PUT" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
                }
                let values = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                check(values["lock_style"] as? Int == 4, "lock style uses device config")
                return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
            }
            polls += 1
            return (200, status(lockStyle: polls < 3 ? 0 : 4, configState: polls < 3 ? 0 : 2, configRevision: polls < 3 ? 2 : 3))
        }
        let style = try await client.saveDeviceConfiguration(.init(lockStyle: 4))
        check(style.config?.lockStyle == 4 && style.config?.revision == 3 && polls == 3, "style waits for matching committed revision")
        polls = 0
        LockHTTP.handler = { request in check(request.httpMethod == "GET", "legacy style cannot submit"); polls += 1; return (200, status(imageLock: false, lockStyle: nil)) }
        do { _ = try await client.saveDeviceConfiguration(.init(lockStyle: 4)); fatalError("legacy style written") }
        catch ReadPicoManagerError.unavailable { checks += 1 }
        let binaryCapability = try JSONDecoder().decode(ReadPicoCapabilities.self, from: status()).imageLock!
        let nativeCapability = try JSONDecoder().decode(ReadPicoCapabilities.self, from: status(nativeGray16: true)).imageLock!
        check(binaryCapability.bitDepths == nil && binaryCapability.grayLevels == nil && !binaryCapability.supportsNativeGray16, "missing legacy fields retain binary capability")
        check(nativeCapability.supportsNativeGray16 && nativeCapability.bitDepths == [1, 4], "native lock requires explicit depth levels MIME and byte budget")
        let grayBitmap = try ReadPicoBitmap.makeGray16(image: context.makeImage()!, width: 684, height: 1216)
        try ReadPicoBitmap.validateLock(bitmap, capability: nativeCapability)
        check(true, "native capability retains original binary format support")
        posts = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" { posts += 1 }
            return (200, status())
        }
        do { _ = try await client.saveLockImageConfirmed(grayBitmap); fatalError("legacy native upload accepted") }
        catch ReadPicoManagerError.unavailable { check(posts == 0, "native image is rejected before POST on legacy firmware") }
        LockHTTP.handler = { request in request.url?.path.hasSuffix("status") == true ? (200, status(nativeGray16: true)) : (200, grayBitmap) }
        check(try await client.lockImage() == grayBitmap, "native image read preserves exact 4bit bytes")
        LockHTTP.handler = { request in request.url?.path.hasSuffix("status") == true ? (200, status(nativeGray16: true)) : (200, Data(repeating: 0, count: 420001)) }
        do { _ = try await client.lockImage(); fatalError("oversized native response accepted") }
        catch ReadPicoManagerError.invalid { checks += 1 }
        polls = 0; posts = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1
                check(request.url?.path.hasSuffix("pico/lock-image") == true, "native lock remains on dedicated authenticated image endpoint")
                return (202, Data(#"{"ok":true,"accepted":true}"#.utf8))
            }
            polls += 1; return (200, status(revision: polls == 1 ? 4 : 5, nativeGray16: true))
        }
        let nativeSaved = try await client.saveLockImageConfirmed(grayBitmap)
        check(posts == 1 && nativeSaved.imageLock?.supportsNativeGray16 == true && nativeSaved.imageLock?.revision == 5, "native upload waits for a compatible saved revision")
        for corruption in ["palette", "truncated", "extra"] {
            var invalid = grayBitmap
            if corruption == "palette" { invalid[55] = 1 }
            if corruption == "truncated" { invalid.removeLast() }
            if corruption == "extra" { invalid.append(0) }
            posts = 0
            LockHTTP.handler = { request in
                if request.httpMethod == "POST" { posts += 1 }
                return (200, status(nativeGray16: true))
            }
            do { _ = try await client.saveLockImageConfirmed(invalid); fatalError("native \(corruption) accepted") }
            catch ReadPicoManagerError.invalid { check(posts == 0, "invalid native \(corruption) rejected before POST") }
        }
        polls = 0; posts = 0
        LockHTTP.handler = { request in
            if request.httpMethod == "POST" { posts += 1; return (202, Data(#"{"ok":true,"accepted":true}"#.utf8)) }
            polls += 1; return (200, status(revision: polls == 1 ? 4 : 5, nativeGray16: polls == 1))
        }
        do { _ = try await client.saveLockImageConfirmed(grayBitmap); fatalError("native capability disappeared but save confirmed") }
        catch ReadPicoManagerError.unavailable { check(posts == 1, "native save remains unconfirmed when result loses gray capability") }
        print("PASS: \(checks) lock image HTTP, compatibility, complete BMP, pairing, acceptance, pending/error/timeout and lock-style confirmation checks; no real device.")
    }
}
