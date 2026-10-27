import Foundation
import Darwin

private struct Response {
    let status: Int
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
}
private actor Counter {
    var count = 0
    func next() -> Int { count += 1; return count }
    func value() -> Int { count }
}
private enum TestError: Error { case failure }
private var checks = 0
private func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: " + name) }
    checks += 1
}
private func config(lifetime: TimeInterval = 30, requestTimeout: TimeInterval = 2) -> ReadPicoWeReadPhoneSetupServer.Configuration {
    var c = ReadPicoWeReadPhoneSetupServer.Configuration()
    c.addresses = { ["127.0.0.1"] }; c.bindAddress = "127.0.0.1"; c.permitsLoopback = true
    c.lifetime = lifetime; c.requestTimeout = requestTimeout
    return c
}
private func rawRequest(_ url: URL, bytes: Data) -> Response {
    guard let port = url.port else { return Response(status: 0, data: Data()) }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return Response(status: 0, data: Data()) }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { return Response(status: 0, data: Data()) }
    let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == bytes.count else { return Response(status: 0, data: Data()) }
    var output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while output.count < 131072 {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        output.append(contentsOf: buffer.prefix(n))
    }
    let line = String(decoding: output, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    return Response(status: Int(line.split(separator: " ").dropFirst().first ?? "0") ?? 0, data: output)
}
private func request(_ url: URL, method: String = "POST", host: String? = nil, origin: String? = "auto", token: String? = "auto", contentType: String = "application/json", body: String = "{\"api_key\":\"wrk-fixture-not-real\"}", extra: String = "", tail: String = "", path: String = "/api/weread/authorize") async -> Response {
    let authority = "127.0.0.1:\(url.port!)"
    var headers = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? authority)\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: \(contentType)\r\n"
    if let origin { headers += "Origin: \(origin == "auto" ? "http://" + authority : origin)\r\n" }
    if let token { headers += "Authorization: Bearer \(token == "auto" ? url.fragment! : token)\r\n" }
    let bytes = Data((headers + extra + "\r\n" + body + tail).utf8)
    return await Task.detached { rawRequest(url, bytes: bytes) }.value
}
private func sendThenReset(_ url: URL) {
    let authority = "127.0.0.1:\(url.port!)", body = "{\"api_key\":\"wrk-fixture-not-real\"}"
    let bytes = Data("POST /api/weread/authorize HTTP/1.1\r\nHost: \(authority)\r\nOrigin: http://\(authority)\r\nAuthorization: Bearer \(url.fragment!)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(url.port!).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard connected == 0 else { return }
    _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    usleep(50000)
    var abrupt = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &abrupt, socklen_t(MemoryLayout<linger>.size))
}
@main struct WeReadPhoneSetupTests {
    static func main() async throws {
        for address in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.2"] { check(ReadPicoWeReadPhoneSetupServer.isPrivateIPv4(address), "private address accepted") }
        for address in ["127.0.0.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "10.00.0.1", "10.0.0.256", "10.0.1", "10.0.0.1.", "fe80::1"] { check(!ReadPicoWeReadPhoneSetupServer.isPrivateIPv4(address), "nonprivate/malformed address refused") }
        check(ReadPicoWeReadPhoneSetupServer.constantEqual("abc", "abc"), "token equality")
        check(!ReadPicoWeReadPhoneSetupServer.constantEqual("abc", "abd"), "token mismatch")
        check(!ReadPicoWeReadPhoneSetupServer.constantEqual("abc", "abcd"), "token length mismatch")
        var emptyConfig = config(); emptyConfig.addresses = { [] }
        let unavailable = ReadPicoWeReadPhoneSetupServer(configuration: emptyConfig)
        do { _ = try await unavailable.start { _ in }; fatalError("missing-network accepted") }
        catch ReadPicoWeReadPhoneSetupError.noLocalNetwork { checks += 1 }
        let counter = Counter(), server = ReadPicoWeReadPhoneSetupServer(configuration: config())
        let session = try await server.start { key in
            check(key == "wrk-fixture-not-real", "handler gets exact validated fixture")
            _ = await counter.next()
        }
        let url = session.urls[0]
        check(url.fragment?.count == 64, "256-bit fragment token")
        check(url.query == nil, "token is not request query")
        check(session.expiresAt > Date(), "session expires in future")
        let page = await request(url, method: "GET", token: nil, body: "", path: "/")
        check(page.status == 200, "actual loopback page served")
        check(page.text.contains("微信读书官方授权页"), "page contains official authorization link")
        check(page.text.contains("https://weread.qq.com/r/weread-skills"), "official destination")
        check(page.text.contains("Cache-Control: no-store"), "no cache")
        check(page.text.contains("frame-ancestors 'none'"), "no framing")
        check(!page.text.contains(url.fragment!), "served page contains no session token")
        check(page.text.contains("可信的同一局域网"), "LAN transport limit explained")
        check(page.text.contains("history.replaceState"), "fragment removed from browser URL")
        check((await request(url, host: "evil.example")).status == 403, "unlisted Host refused")
        check((await request(url, origin: "https://evil.example")).status == 403, "foreign Origin refused")
        check((await request(url, origin: nil)).status == 403, "missing Origin refused")
        check((await request(url, token: "incorrect")).status == 401, "wrong bearer refused")
        check((await request(url, token: nil)).status == 401, "missing bearer refused")
        check((await request(url, extra: "Sec-Fetch-Site: cross-site\r\n")).status == 403, "cross site request refused")
        check((await request(url, method: "GET", body: "")).status == 405, "GET cannot save")
        check((await request(url, contentType: "text/plain")).status == 400, "wrong content type refused")
        check((await request(url, body: "bad-json")).status == 400, "malformed JSON refused")
        check((await request(url, body: "{\"api_key\":\"invalid\"}")).status == 400, "bad key rejected")
        check((await request(url, body: "{\"api_key\":\"wrk-fixture-not-real\",\"unknown\":1}")).status == 400, "extra JSON fields refused")
        check((await request(url, body: String(repeating: "x", count: 1025))).status == 413, "large body refused")
        check((await request(url, extra: "Content-Length: 1\r\n")).status == 400, "duplicate length refused")
        check((await request(url, extra: "Transfer-Encoding: chunked\r\n")).status == 400, "chunked smuggling refused")
        check((await request(url, extra: " Host: evil\r\n")).status == 400, "folded header refused")
        check((await request(url, tail: "TAIL")).status == 400, "trailing bytes refused")
        check(await counter.value() == 0, "invalid requests never call save")
        let saved = await request(url)
        check(saved.status == 200, "valid request saved and ACK sent")
        check(!saved.text.contains("wrk-fixture-not-real"), "success never echoes key")
        check(await counter.value() == 1, "exactly one save")
        let replay = await request(url)
        check(replay.status == 0 || replay.status == 410, "successful session revoked")
        check(await counter.value() == 1, "replay cannot save")
        let delayedCounter = Counter()
        let raceSession = try await server.start { _ in _ = await delayedCounter.next(); try await Task.sleep(nanoseconds: 250_000_000) }
        let pending = Task { await request(raceSession.urls[0]) }
        try await Task.sleep(nanoseconds: 70_000_000)
        check((await request(raceSession.urls[0])).status == 409, "overlapping POST rejected during save")
        check((await pending.value).status == 200, "first in-flight save ACK")
        check(await delayedCounter.value() == 1, "single commit across await")
        let failedCounter = Counter()
        let retrySession = try await server.start { _ in if await failedCounter.next() == 1 { throw TestError.failure } }
        let failed = await request(retrySession.urls[0])
        check(failed.status == 503 && !failed.text.contains("TestError"), "save failure safe error")
        check((await request(retrySession.urls[0])).status == 200, "failed save permits retry")
        let stale = try await server.start { _ in fatalError("stale handler invoked") }
        let freshCounter = Counter()
        let fresh = try await server.start { _ in _ = await freshCounter.next() }
        check(stale.urls[0].fragment != fresh.urls[0].fragment, "restart rotates token")
        check((await request(fresh.urls[0], token: stale.urls[0].fragment)).status == 401, "old token cannot authorize restarted server")
        check((await request(fresh.urls[0])).status == 200, "new token saves")
        check(await freshCounter.value() == 1, "restarted handler only once")
        let cancelledCounter = Counter()
        let cancelled = try await server.start { _ in try await Task.sleep(nanoseconds: 500_000_000); try Task.checkCancellation(); _ = await cancelledCounter.next() }
        let cancelling = Task { await request(cancelled.urls[0]) }
        try await Task.sleep(nanoseconds: 50_000_000); server.stop()
        _ = await cancelling.value
        try await Task.sleep(nanoseconds: 50_000_000)
        check(await cancelledCounter.value() == 0, "stop cancels pending save task")
        check((await request(cancelled.urls[0])).status == 0, "stop closes listener")
        let disconnectedCounter = Counter()
        let disconnected = try await server.start { _ in try await Task.sleep(nanoseconds: 180_000_000); _ = await disconnectedCounter.next() }
        await Task.detached { sendThenReset(disconnected.urls[0]) }.value
        try await Task.sleep(nanoseconds: 240_000_000)
        check(await disconnectedCounter.value() == 1, "submitted save may finish after phone disconnects")
        check((await request(disconnected.urls[0])).status == 0, "successful disconnected save revokes listener")
        let expiryCounter = Counter()
        let expiringSaveServer = ReadPicoWeReadPhoneSetupServer(configuration: config(lifetime: 0.12))
        let expiringSave = try await expiringSaveServer.start { _ in try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); _ = await expiryCounter.next() }
        _ = await request(expiringSave.urls[0])
        try await Task.sleep(nanoseconds: 50_000_000)
        check(await expiryCounter.value() == 0, "expiry cancels in-flight save")
        let obsoleteCounter = Counter()
        let obsolete = try await server.start { _ in try? await Task.sleep(nanoseconds: 180_000_000); _ = await obsoleteCounter.next() }
        let obsoleteRequest = Task { await request(obsolete.urls[0]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let replacement = try await server.start { _ in }
        _ = await obsoleteRequest.value
        try await Task.sleep(nanoseconds: 200_000_000)
        check((await request(replacement.urls[0], method: "GET", body: "", path: "/")).status == 200, "old generation completion cannot close new listener")
        server.stop()
        let expiredServer = ReadPicoWeReadPhoneSetupServer(configuration: config(lifetime: 0.12))
        let expired = try await expiredServer.start { _ in fatalError("expired authorization saved") }
        try await Task.sleep(nanoseconds: 180_000_000)
        check((await request(expired.urls[0])).status == 0, "expiry closes listener")
        let timeoutServer = ReadPicoWeReadPhoneSetupServer(configuration: config(requestTimeout: 0.1))
        let timeoutSession = try await timeoutServer.start { _ in }
        let timeoutResponse = await Task.detached { rawRequest(timeoutSession.urls[0], bytes: Data("GET / HTTP/1.1\r\n".utf8)) }.value
        check(timeoutResponse.status == 0, "incomplete request timed out")
        check((await request(timeoutSession.urls[0], method: "GET", body: "", path: "/")).status == 200, "timeout leaves session usable")
        timeoutServer.stop()
        let cancellationStart = Task { try await server.start { _ in } }
        cancellationStart.cancel()
        do { _ = try await cancellationStart.value; fatalError("cancelled startup succeeded") } catch { checks += 1 }
        server.stop()
        let htmlPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/weread-phone-page.html"
        try ReadPicoWeReadPhoneSetupPage.html.write(toFile: htmlPath, atomically: true, encoding: .utf8)
        print("PASS \(checks) checks; loopback fixture only; no account, Keychain, USB or device accessed")
    }
}
