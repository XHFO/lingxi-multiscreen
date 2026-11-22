import Foundation

private final class MockProtocol: URLProtocol {
    static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private struct FormlabsClientTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_795_400_000)
    static let old = now.addingTimeInterval(-900)
    static let settings = FormlabsConnectionSettings(printerSerial: "Form-123", clientID: "client",
        clientSecret: "secret", showThumbnail: false)
    static let previous = FormlabsSnapshot(
        device: FormlabsDeviceInfo(id: "Form-123", status: "printing", isConnected: true),
        print: FormlabsPrintInfo(runID: "old-guid", name: "Repeated name", status: "printing",
            currentLayer: 25, layerCount: 100, estimatedTimeRemainingMS: 500_000),
        thumbnail: Data([1, 2, 3]), sampledAt: old)

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func run(_ guid: String = "new-guid") -> [String: Any] {
        ["guid": guid, "name": "Repeated name", "status": "PRINTING", "currently_printing_layer": 30,
         "layer_count": 100, "estimated_time_remaining_ms": 400_000, "material_name": "Clear V5"]
    }
    static func printer(_ status: String = "PRINTING", run: [String: Any]? = run(),
                        heartbeat: Date = now, connected: Bool? = nil) -> [String: Any] {
        var printer: [String: Any] = ["serial": "Form-123", "alias": "Studio printer",
            "printer_status": ["status": status, "last_pinged_at": ISO8601DateFormatter().string(from: heartbeat),
                "current_print_run": run as Any? ?? NSNull()]]
        if let connected { printer["is_connected"] = connected }
        return printer
    }
    static func client() -> FormlabsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return FormlabsClient(session: URLSession(configuration: config), now: { now })
    }
    static func respond(_ body: Any, status: Int = 200) {
        MockProtocol.handler = { request in
            request.url!.path.contains("/o/token")
                ? (200, json(["access_token": "fixture-token", "expires_in": 3600])) : (status, json(body))
        }
    }
    static func main() async throws {
        let legacy = try JSONDecoder().decode(FormlabsConnectionSettings.self,
            from: Data(#"{"printerSerial":"Form-123","clientID":"client","clientSecret":"secret"}"#.utf8))
        check(legacy.dataSource == .developerAPI && legacy.clientSecret == "secret", "Legacy source and credentials must be retained")
        var dashboardSettings = settings; dashboardSettings.dataSource = .dashboard
        let decoded = try JSONDecoder().decode(FormlabsConnectionSettings.self, from: JSONEncoder().encode(dashboardSettings))
        check(decoded == dashboardSettings, "Dashboard mode must roundtrip without erasing developer credentials")

        respond(printer())
        let healthy = await client().refresh(settings: settings, previous: previous)
        check(healthy.isRealtimeAvailable && healthy.displayStatus == "PRINTING", "Fresh printing must be available")
        check(healthy.device?.productName == "Studio printer", "Official alias must be parsed")
        check(healthy.device?.lastPingedAt == now, "Device sample time must be parsed")
        check(healthy.print?.runID == "new-guid" && healthy.print?.progress == 0.3, "Official guid and layer progress must be parsed")
        check(healthy.thumbnail == nil && healthy.completionObservedAt == nil, "A same-name new GUID must clear the old cover and completion")
        check(healthy.sampledAt == now, "Only trustworthy response advances sample time")
        respond(["serial": "Form-123", "status": "PRINTING", "last_pinged_at": ISO8601DateFormatter().string(from: now),
                 "current_print_run": run()])
        let flat = await client().refresh(settings: settings)
        check(flat.isRealtimeAvailable && flat.device?.lastPingedAt == now, "Top-level status and heartbeat must use the same schema")

        for body in [[String: Any](), ["serial": "other", "status": "PRINTING"], ["serial": "Form-123"]] {
            respond(body)
            let invalid = await client().refresh(settings: settings, previous: previous)
            check(invalid.cloudError != nil && invalid.sampledAt == old, "Malformed or mismatched response must retain sample time")
            check(invalid.print == previous.print, "Invalid response must not complete or replace the task")
        }
        respond(printer("UNKNOWN", run: nil, heartbeat: old))
        let stale = await client().refresh(settings: settings, previous: previous)
        check(stale.dataIssue != nil && !stale.isRealtimeAvailable && stale.displayStatus == "data_unavailable", "Stale UNKNOWN must be visibly unavailable")
        check(stale.print == previous.print && stale.sampledAt == old, "Stale data must retain progress and actual sample time")
        check(stale.completionObservedAt == nil && stale.hasCurrentPrint == false, "Missing current task cannot imply completion")

        respond(printer("offline", run: nil, connected: false))
        let offline = await client().refresh(settings: settings, previous: previous)
        check(offline.displayStatus == "offline" && !offline.isRealtimeAvailable, "Offline status must take priority")
        check(offline.print?.currentLayer == 25 && offline.print?.status == "printing" && offline.sampledAt == old, "Offline must preserve cached progress")
        respond(printer("offline", connected: false))
        let offlineWithRun = await client().refresh(settings: settings, previous: previous)
        check(offlineWithRun.print == previous.print && offlineWithRun.thumbnail == previous.thumbnail,
              "Offline response containing a run must not overwrite the trustworthy task or cover")
        respond(printer("failed"))
        let failedWithRun = await client().refresh(settings: settings, previous: previous)
        check(failedWithRun.displayStatus == "failed" && failedWithRun.print?.status == "failed"
              && failedWithRun.print?.estimatedTimeRemainingMS == 0,
              "Explicit device failure must override a nested run that still reports printing")
        respond(printer("failed", run: nil))
        let failed = await client().refresh(settings: settings, previous: previous)
        check(failed.displayStatus == "failed" && failed.print?.status == "failed", "New failure must not be masked by cached status")
        check(failed.print?.progress == 0.25 && failed.print?.estimatedTimeRemainingMS == 0, "Failure must not synthesize 100 percent")
        respond(printer("idle", run: nil))
        let idle = await client().refresh(settings: settings, previous: previous)
        check(idle.displayStatus == "idle" && idle.print?.progress == 0.25, "Idle with no task is not proof of success")
        respond(printer("FINISHED", run: nil))
        let finished = await client().refresh(settings: settings, previous: previous)
        check(finished.displayStatus == "finished" && finished.print?.progress == 1, "Explicit success must finish the cached task")

        var tokens = 0, requests = 0
        MockProtocol.handler = { request in
            if request.url!.path.contains("/o/token") { tokens += 1; return (200, json(["access_token": "token-\(tokens)", "expires_in": 3600])) }
            requests += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" { return (401, json(["detail":"expired"])) }
            return (200, json(printer()))
        }
        let recovered = await client().refresh(settings: settings, previous: previous)
        check(tokens == 2 && requests == 2 && recovered.isRealtimeAvailable, "401 must refresh the matching token and retry once")
        tokens = 0; requests = 0
        MockProtocol.handler = { request in
            if request.url!.path.contains("/o/token") { tokens += 1; return (200, json(["access_token": "token-\(tokens)", "expires_in": 3600])) }
            requests += 1; return (401, json(["detail":"secret token-1 client"]))
        }
        let rejected = await client().refresh(settings: settings, previous: previous)
        check(tokens == 2 && requests == 2 && rejected.cloudError != nil, "Persistent 401 must terminate after a single retry")
        check(rejected.sampledAt == old && rejected.print == previous.print, "Failed refresh must not rewrite cached sample time")
        check(!(rejected.cloudError ?? "").contains("secret"), "Server error bodies must not expose credentials")

        tokens = 0; requests = 0
        MockProtocol.handler = { request in
            if request.url!.path.contains("/o/token") { tokens += 1; return (200, json(["access_token":"fixture", "expires_in":3600])) }
            requests += 1; return (403, json(["detail":"forbidden"]))
        }
        _ = await client().refresh(settings: settings, previous: previous)
        check(tokens == 1 && requests == 1, "403 is not a token-refresh loop")

        // Dashboard observations are parsed locally and do not borrow a developer credential.
        var networkCalls = 0
        MockProtocol.handler = { _ in networkCalls += 1; return (500, Data()) }
        let dashboard = await client().refreshDashboard(settings: dashboardSettings, previous: previous,
            payload: json([printer()]))
        check(dashboard.isRealtimeAvailable && dashboard.device?.connectionType == "dashboard", "Observed Dashboard payload must render current task")
        check(networkCalls == 0, "Dashboard observation with no cover must not issue any network request")
        let noMatch = await client().refreshDashboard(settings: dashboardSettings, previous: dashboard, payload: json([]))
        check(noMatch.cloudError != nil && !noMatch.isRealtimeAvailable, "Missing selected printer is not a successful empty observation")
        var malformedTime = printer()
        malformedTime["printer_status"] = ["status":"PRINTING", "last_pinged_at":"not-a-date", "current_print_run":run()]
        let invalidTime = await client().refreshDashboard(settings: dashboardSettings, previous: previous, payload: json(malformedTime))
        check(invalidTime.dataIssue != nil && invalidTime.sampledAt == old, "Invalid heartbeat cannot refresh cached data")
        var malformedNumbers = run(); malformedNumbers["currently_printing_layer"] = "1e400"; malformedNumbers["layer_count"] = "1e30"
        let invalidNumbers = await client().refreshDashboard(settings: dashboardSettings, payload: json(printer(run:malformedNumbers)))
        check(invalidNumbers.print?.currentLayer == nil && invalidNumbers.print?.layerCount == nil, "Unbounded numeric fields must not crash Int conversion")
        print("Formlabs client: \(checks) checks passed (API, Dashboard payload, failure/idle/finish, freshness, GUID/alias, bounded 401 recovery)")
    }
}
