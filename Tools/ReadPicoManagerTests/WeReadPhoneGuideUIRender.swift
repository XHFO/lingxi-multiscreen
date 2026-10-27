import AppKit
import Foundation
import LinxDisplayApp
import LinxDisplayCore
import SwiftUI
import Vision

private final class SetupFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) async throws -> Void)?
    private var starts = 0, stops = 0
    var expiry = Date().addingTimeInterval(600)
    func start(_ handler: @escaping @Sendable (String) async throws -> Void) async throws -> ReadPicoWeReadPhoneSetupServer.Session {
        lock.withLock { starts += 1; self.handler = handler }
        return .init(urls: [URL(string: "http://192.168.10.24:52345/#offline-fixture-never-authorized")!], expiresAt: expiry)
    }
    func stop() { lock.withLock { stops += 1 } }
    func callback() -> (@Sendable (String) async throws -> Void)? { lock.withLock { handler } }
    func counts() -> (Int, Int) { lock.withLock { (starts, stops) } }
}
@MainActor private final class Saves {
    var saved = 0, authorized = 0, failNext = false
    func save(_ key: String) throws {
        precondition(key == "wrk-offline-fixture-no-real-key")
        if failNext { failNext = false; throw ReadPicoWeReadError.storage("fixture save failure") }
        saved += 1
    }
}
@MainActor private func runModelTests() async throws -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    let fixture = SetupFixture(), saves = Saves()
    let model = ReadPicoWeReadPhoneGuideModel(start: { try await fixture.start($0) }, stop: { fixture.stop() },
        save: { try saves.save($0) }, onAuthorized: { saves.authorized += 1 })
    expect(fixture.counts().0 == 0, "Passive init started networking")
    model.start(); try await Task.sleep(nanoseconds: 30_000_000)
    guard let first = fixture.callback() else { fatalError("Missing fixture callback") }
    if case .ready = model.phase { checks += 1 } else { fatalError("Not ready") }
    model.cancel()
    do { try await first("wrk-offline-fixture-no-real-key"); fatalError("Cancelled callback accepted") } catch { checks += 1 }
    expect(saves.saved == 0 && saves.authorized == 0, "Cancelled callback saved an account")
    model.start(); try await Task.sleep(nanoseconds: 30_000_000)
    guard let second = fixture.callback() else { fatalError("Missing restart callback") }
    do { try await first("wrk-offline-fixture-no-real-key"); fatalError("Old generation accepted") } catch { checks += 1 }
    expect(saves.saved == 0, "Old generation overwrote account")
    saves.failNext = true
    do { try await second("wrk-offline-fixture-no-real-key"); fatalError("Save failure swallowed") } catch { checks += 1 }
    expect(saves.saved == 0 && saves.authorized == 0, "Failure declared an authorized account")
    expect(!model.feedback.isEmpty, "Save failure has no native recovery feedback")
    try await second("wrk-offline-fixture-no-real-key")
    expect(saves.saved == 1 && saves.authorized == 1, "Authorization not committed once")
    expect(model.phase == .saved && model.feedback.isEmpty, "Saved state missing")
    do { try await second("wrk-offline-fixture-no-real-key"); fatalError("Replay accepted") } catch { checks += 1 }
    expect(saves.saved == 1 && saves.authorized == 1, "Replay wrote an account")
    model.cancel()
    fixture.expiry = Date().addingTimeInterval(-1)
    model.start(); try await Task.sleep(nanoseconds: 30_000_000)
    guard let expired = fixture.callback() else { fatalError("Missing expiry callback") }
    do { try await expired("wrk-offline-fixture-no-real-key"); fatalError("Expired callback accepted") } catch { checks += 1 }
    expect(saves.saved == 1 && model.phase == .expired, "Expired setup remained active")
    model.cancel()
    let blocked = SetupFixture(), blockedSaves = Saves()
    let blockedModel = ReadPicoWeReadPhoneGuideModel(start: { try await blocked.start($0) }, stop: { blocked.stop() },
        save: { try blockedSaves.save($0) }, onAuthorized: { blockedSaves.authorized += 1 })
    blockedModel.start(); try await Task.sleep(nanoseconds: 30_000_000)
    guard let pending = blocked.callback() else { fatalError("Missing pending callback") }
    let attempt = Task { try await pending("wrk-offline-fixture-no-real-key") }
    blockedModel.cancel()
    do { try await attempt.value; fatalError("Queued callback accepted after dismissal") } catch { checks += 1 }
    expect(blockedSaves.saved == 0 && blockedSaves.authorized == 0, "Queued callback overwrote account")
    let failedModel = ReadPicoWeReadPhoneGuideModel(start: { _ in throw ReadPicoWeReadPhoneSetupError.noLocalNetwork }, stop: {},
        save: { _ in fatalError("Failure must not touch Keychain") })
    failedModel.start(); try await Task.sleep(nanoseconds: 30_000_000)
    if case .failed(let message) = failedModel.phase { expect(message.contains("局域网"), "Network recovery text absent") }
    else { fatalError("No network state missing") }
    failedModel.cancel()
    return checks
}
@MainActor private func scrolls(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
}
@MainActor private func screenshot(_ view: NSView, name: String, output: URL) throws {
    view.layoutSubtreeIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: image)
    guard let png = image.representation(using: .png, properties: [:]) else { fatalError("PNG encode") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor private func run() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let checks = try await runModelTests()
    let session = ReadPicoWeReadPhoneSetupServer.Session(urls: [
        URL(string: "http://192.168.10.24:52345/#offline-fixture-for-native-ui-only")!,
        URL(string: "http://10.0.1.24:52345/#offline-fixture-for-native-ui-only")!
    ], expiresAt: Date().addingTimeInterval(600))
    var captures = [String](), geometry = [[String: Any]](), renderedQRChecks = 0, renderedAddressChecks = 0
    let phases: [(String, ReadPicoWeReadPhoneGuideModel.Phase)] = [
        ("starting", .starting), ("qr", .ready(session)), ("saved", .saved), ("expired", .expired),
        ("no-network", .failed(ReadPicoWeReadPhoneSetupError.noLocalNetwork.localizedDescription))]
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for width in [400.0, 720.0] {
            for (scene, phase) in phases {
                let fixture = SetupFixture()
                let model = ReadPicoWeReadPhoneGuideModel(initialPhase: phase,
                    start: { try await fixture.start($0) }, stop: { fixture.stop() },
                    save: { _ in fatalError("Passive UI must not save credentials") })
                let content = ReadPicoWeReadPhoneGuideView(model: model, startsAutomatically: false)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: width, height: 700),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
                let host = NSHostingView(rootView: content)
                window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: 700); window.orderFront(nil)
                try await Task.sleep(nanoseconds: 120_000_000)
                precondition(fixture.counts().0 == 0, "Rendering started a server")
                let name = "\(scene)-\(Int(width))-\(dark ? "dark" : "light")"
                try screenshot(host, name: name, output: output); captures.append(name)
                if scene == "qr" {
                    let renderedRequest = VNDetectBarcodesRequest(); renderedRequest.symbologies = [.qr]
                    try VNImageRequestHandler(url: output.appendingPathComponent(name + ".png"), options: [:]).perform([renderedRequest])
                    precondition(renderedRequest.results?.first?.payloadStringValue == session.urls[0].absoluteString,
                                 "Rendered QR cannot be decoded: \(name)")
                    renderedQRChecks += 1
                    if width == 720 {
                        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate
                        text.recognitionLanguages = ["en-US"]; text.usesLanguageCorrection = false
                        try VNImageRequestHandler(url: output.appendingPathComponent(name + ".png"), options: [:]).perform([text])
                        let visibleText = text.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                        precondition(visibleText.contains("192.168.10.24:52345"), "Rendered address was localized or truncated: \(visibleText)")
                        renderedAddressChecks += 1
                    }
                }
                for scroll in scrolls(host) {
                    guard let doc = scroll.documentView else { continue }
                    geometry.append(["scene": name, "viewport_width": scroll.contentSize.width, "document_width": doc.bounds.width,
                                     "viewport_height": scroll.contentSize.height, "document_height": doc.bounds.height])
                    precondition(doc.bounds.width <= scroll.contentSize.width + 1, "Horizontal overflow: \(name)")
                    doc.scroll(.init(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - scroll.contentSize.height) : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try screenshot(host, name: name + "-bottom", output: output); captures.append(name + "-bottom")
                window.close(); model.cancel()
            }
        }
    }
    let url = session.urls[0]
    guard let image = ReadPicoWeReadPhoneGuideView.qrImage(for: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Missing QR") }
    let qr = VNDetectBarcodesRequest(); qr.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([qr])
    precondition(qr.results?.first?.payloadStringValue == url.absoluteString, "QR does not encode complete setup URL")
    let report: [String: Any] = ["result": "PASS", "screens": captures, "scroll_geometry": geometry,
        "model_checks": checks, "qr_roundtrip": true, "rendered_qr_checks": renderedQRChecks, "rendered_address_checks": renderedAddressChecks, "real_network": false, "keychain_accessed": false,
        "physical_device_accessed": false, "user_configuration_modified": false,
        "scope": "Actual Debug SwiftUI production guide; injected offline phases and storage. Cancellation, stale callback, expiry, retry, replay and QR roundtrip fixtures; no real credentials."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    print("PASS: \(checks) native guide model checks, QR roundtrip and \(captures.count) native UI screenshots; no real network/Keychain/device access.")
}
@MainActor @_cdecl("readpico_weread_phone_render_main")
func wereadPhoneRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
    app.run(); return 0
}
