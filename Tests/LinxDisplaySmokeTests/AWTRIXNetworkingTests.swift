import Foundation
import LinxDisplayCore

private final class AWTRIXMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var failures = Set<String>()
    static var paths: [String] = []

    static func reset(failures: Set<String> = []) {
        lock.lock()
        defer { lock.unlock() }
        self.failures = failures
        paths = []
    }

    static func recordedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.paths.append(path)
        let fails = Self.failures.contains(path)
        Self.lock.unlock()
        let body: String
        if fails { body = #"{"error":{"message":"test unavailable"}}"# }
        else {
            switch path {
            case "/api/v1/device": body = #"{"currentApp":"Time"}"#
            case "/api/v1/apps": body = #"[{"name":"Time","enabled":true,"inLoop":true}]"#
            case "/api/v1/capabilities":
                body = #"{"effects":[],"palettes":[],"paletteEffects":[],"overlays":[],"transitions":[]}"#
            case "/api/v1/files": body = #"{"files":[]}"#
            default: body = "{}"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: fails ? 503 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func testAWTRIXNetworking() async throws {
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [AWTRIXMockProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    defer { session.invalidateAndCancel() }
    let client = AWTRIXClient(session: session)
    var config = AWTRIXSettings()
    config.baseURL = "http://awtrix.test"
    AWTRIXMockProtocol.reset(failures: ["/api/v1/settings", "/api/v1/system",
                                      "/api/v1/capabilities", "/api/v1/files"])
    let degraded = try await client.refresh(config)
    checkEqual(degraded.device.currentApp, "Time", "AWTRIX 辅助接口失败仍保留当前应用")
    checkEqual(degraded.apps.map(\.name), ["Time"], "AWTRIX 辅助接口失败不能清空应用清单")
    checkEqual(Array(AWTRIXMockProtocol.recordedPaths().prefix(2)),
        ["/api/v1/device", "/api/v1/apps"], "AWTRIX 优先顺序读取设备与应用清单")
    AWTRIXMockProtocol.reset()
    _ = try await client.refresh(config)
    check(AWTRIXMockProtocol.recordedPaths().contains("/api/v1/capabilities"),
          "AWTRIX 不缓存失败的元数据请求")
    AWTRIXMockProtocol.reset()
    _ = try await client.refresh(config)
    checkEqual(AWTRIXMockProtocol.recordedPaths(),
        ["/api/v1/device", "/api/v1/apps", "/api/v1/settings", "/api/v1/system"],
        "AWTRIX 缓存静态效果目录，但实时状态仍重新查询")
    config.baseURL = "http://second-awtrix.test"
    AWTRIXMockProtocol.reset()
    _ = try await client.refresh(config)
    check(AWTRIXMockProtocol.recordedPaths().contains("/api/v1/capabilities"),
          "AWTRIX 元数据缓存按设备地址隔离")
    AWTRIXMockProtocol.reset(failures: ["/api/v1/apps"])
    do {
        _ = try await client.refresh(config)
        check(false, "AWTRIX 核心接口失败必须报错")
    } catch {
        check(error.localizedDescription.contains("GET /api/v1/apps"),
              "AWTRIX 错误必须标明请求方法及路径")
    }
    print("  AWTRIX 网络降级与元数据缓存通过")
}
