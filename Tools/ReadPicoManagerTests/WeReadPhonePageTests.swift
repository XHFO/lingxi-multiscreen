import AppKit
import Foundation
import WebKit

private enum Failure: Error { case check(String) }

@MainActor private final class PhonePageFixture: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let window: NSWindow
    var navigation: CheckedContinuation<Void, Error>?
    var checks = 0
    var screenshots: [[String: Any]] = []
    let output: URL
    let baseURL: String

    init(baseURL: String, output: URL) {
        self.baseURL = baseURL; self.output = output
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: #"""
        window.__fixture = {calls:[], mode:'success'};
        window.fetch = async (path, options) => {
          const body = JSON.parse(options.body);
          window.__fixture.calls.push({path,method:options.method,
            tokenMatches:options.headers.Authorization === 'Bearer '+ 'a'.repeat(64),
            keyMatches:body.api_key === 'wrk-fixture-abc123',
            contentType:options.headers['Content-Type'],credentials:options.credentials,
            cache:options.cache,redirect:options.redirect});
          if (window.__fixture.mode === 'network') throw Error('fixture network failure');
          if (window.__fixture.mode === 'storage') return {ok:false,status:503,json:async()=>({message:'Mac 未能保存授权，请重试。'})};
          if (window.__fixture.mode === 'unauthorized') return {ok:false,status:401,json:async()=>({message:'授权会话无效，请重新扫码。'})};
          return {ok:true,status:200,json:async()=>({message:'授权已保存。'})};
        };
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        view.navigationDelegate = self
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { print("fixture navigation ready"); fflush(stdout); self.navigation?.resume(); self.navigation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.navigation?.resume(throwing: error); self.navigation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.navigation?.resume(throwing: error); self.navigation = nil }
    func js(_ script: String) async throws -> Any? { try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) }
    func require(_ condition: Bool, _ name: String) throws { checks += 1; if !condition { throw Failure.check(name) } }
    func bool(_ script: String) async throws -> Bool { (try await js("return (\(script));")) as? Bool ?? false }
    func load(token: Bool = true) async throws {
        print("fixture loading production phone page"); fflush(stdout)
        // A unique fixture-only query forces a new document instead of a same-document hash navigation.
        let url = URL(string: baseURL + "/?fixture=" + UUID().uuidString + (token ? "#" + String(repeating: "a", count: 64) : ""))!
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation; view.load(URLRequest(url: url))
        }
        _ = try await js("document.body.getBoundingClientRect(); await new Promise(resolve=>setTimeout(resolve,50)); return true;")
    }
    func submit(key: String = "wrk-fixture-abc123", mode: String = "success") async throws {
        let json = try JSONSerialization.data(withJSONObject: ["key": key, "mode": mode], options: [.sortedKeys])
        let literal = String(decoding: json, as: UTF8.self)
        _ = try await js("const v=\(literal); window.__fixture.mode=v.mode; document.getElementById('key').value=v.key; document.getElementById('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})); await new Promise(r=>setTimeout(r,30)); return true;")
    }
    func snapshot(name: String) async throws {
        print("fixture snapshot \(name)"); fflush(stdout)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? Failure.check("snapshot")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure.check("PNG encode") }
        try data.write(to: output.appendingPathComponent(name))
        screenshots.append(["file": name, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
        try require(image.size.width == view.bounds.width && image.size.height == view.bounds.height, "snapshot dimensions")
    }
    func run() async throws {
        for width in [390, 768] {
            for dark in [false, true] {
                window.setContentSize(NSSize(width: width, height: width == 390 ? 844 : 1024))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.appearance = window.appearance
                try await load()
                try require(try await bool("document.documentElement.scrollWidth <= innerWidth"), "no horizontal overflow")
                try require(try await bool("[...document.querySelectorAll('input,button,a.button')].every(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.left>=0&&r.right<=innerWidth&&r.height>=44})"), "touch controls fit and meet 44 px")
                try require(try await bool("location.hash === '' && !location.href.includes('#')"), "token removed from history")
                try require(try await bool("document.querySelector('a.button').href === 'https://weread.qq.com/r/weread-skills' && document.querySelector('a.button').rel.includes('noreferrer')"), "official key guide link")
                let name = "phone-\(width)-\(dark ? "dark" : "light")"
                try await snapshot(name: name + "-top.png")
                _ = try await js("scrollTo(0,document.documentElement.scrollHeight);document.body.getBoundingClientRect();await new Promise(r=>setTimeout(r,50));return true;")
                try await snapshot(name: name + "-bottom.png")
            }
        }
        try await load()
        try require(try await bool("document.getElementById('key').type === 'password' && !document.getElementById('submit').disabled"), "key masked initially")
        _ = try await js("document.getElementById('reveal').click();return true;")
        try require(try await bool("document.getElementById('key').type === 'text' && document.getElementById('reveal').getAttribute('aria-pressed') === 'true'"), "reveal key is explicit")
        try await submit()
        try require(try await bool("window.__fixture.calls.length === 1 && window.__fixture.calls[0].keyMatches && window.__fixture.calls[0].tokenMatches"), "actual lowercase key and fragment token reach fake POST")
        try require(try await bool("window.__fixture.calls[0].path === '/api/weread/authorize' && window.__fixture.calls[0].method === 'POST' && window.__fixture.calls[0].contentType === 'application/json' && window.__fixture.calls[0].credentials === 'omit' && window.__fixture.calls[0].cache === 'no-store' && window.__fixture.calls[0].redirect === 'error'"), "bounded credential POST contract")
        try require(try await bool("document.getElementById('key').value === '' && document.getElementById('setup').hidden && getComputedStyle(document.getElementById('success')).display !== 'none' && document.activeElement.id === 'success'"), "success clears key and announces next step")
        try await load(token: false)
        try require(try await bool("document.getElementById('submit').disabled && document.getElementById('status').textContent.includes('缺少授权会话') && window.__fixture.calls.length === 0"), "missing token cannot submit")
        try await load()
        try await submit(key: "not-a-key")
        try require(try await bool("window.__fixture.calls.length === 0 && document.getElementById('status').textContent.includes('完整的 wrk-')"), "invalid key rejected before network")
        try await submit(mode: "storage")
        try require(try await bool("window.__fixture.calls.length === 1 && !document.getElementById('submit').disabled && document.getElementById('status').textContent.includes('未能保存')"), "storage failure permits retry")
        try await submit()
        try require(try await bool("window.__fixture.calls.length === 2 && document.getElementById('setup').hidden"), "storage retry succeeds")
        try await load()
        try await submit(mode: "unauthorized")
        try require(try await bool("document.getElementById('submit').disabled && document.getElementById('status').textContent.includes('会话无效')"), "invalid session revoked in page")
        try await load()
        try await submit(mode: "network")
        try require(try await bool("!document.getElementById('submit').disabled && document.getElementById('status').textContent.includes('无法连接')"), "network error actionable and retryable")
        _ = try await js("document.getElementById('key').value='wrk-fixture-abc123';dispatchEvent(new Event('pagehide'));return true;")
        try require(try await bool("document.getElementById('key').value === ''"), "leaving page clears key")
        let report: [String: Any] = ["result": "PASS", "checks": checks, "screens": screenshots,
            "page": "production HTML; WKWebView real JavaScript; fetch and credential saving injected",
            "real_credentials_used": false, "hardware_accessed": false, "real_account_accessed": false,
            "limitations": ["Desktop WebKit at mobile widths; no physical phone or live account acceptance.", "HTTP server contract covered independently by production Core loopback tests."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("PASS \(checks) production phone-page checks; \(screenshots.count) WKWebView snapshots")
        window.orderOut(nil)
    }
}

@main private enum Main {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let fixture = PhonePageFixture(baseURL: CommandLine.arguments[1], output: output)
                try await fixture.run(); exit(0)
            } catch { fputs("FAIL phone page fixture: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
