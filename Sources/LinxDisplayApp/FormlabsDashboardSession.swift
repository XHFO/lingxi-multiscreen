import Foundation
import Combine
import WebKit

/// The only bridge out of the official page is a bounded, printer-only projection.
/// Cookies, request headers, account objects and login storage never cross this bridge.
enum FormlabsDashboardPayload {
    private static func fields(_ names: String) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: names.split(separator: " ").map { (String($0), true) })
    }

    static let schema: [String: Any] = {
        let material = fields("serial display_name material consumable_type tank_type")
        var run = fields("id uuid guid print_run_id run_id name print_name status currently_printing_layer layer_count elapsed_duration_ms estimated_duration_ms estimated_time_remaining_ms material_name material print_settings_name layer_thickness_mm message thumbnail_url cartridge front_cartridge back_cartridge started_at finished_at last_modified")
        run["print_thumbnail"] = fields("thumbnail")
        run["thumbnail"] = fields("thumbnail")
        var status = fields("status state last_pinged_at last_modified hopper_material estimated_print_time_remaining_ms")
        status["current_print_run"] = run
        var printer = fields("id serial printer_serial serial_number machine_id name alias user_facing_name printer_name product_name model firmware_version is_connected ready_to_print_now estimated_print_time_remaining_ms last_pinged_at last_modified")
        printer["printer_status"] = status
        // A status can be a string in older responses, or the status object above.
        printer["status"] = status
        printer["current_print_run"] = run
        printer["cartridge_status"] = [["cartridge": material]]
        printer["tank_status"] = ["tank": material]
        return printer
    }()

    static func serial(of object: [String: Any]) -> String? {
        for key in ["serial", "printer_serial", "serial_number", "machine_id", "id"] {
            if let value = object[key] as? String { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func sanitized(_ object: [String: Any], serial: String) -> Data? {
        guard Self.serial(of: object) == serial else { return nil }
        let result = filter(object, schema: schema)
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              data.count <= 128 * 1024 else { return nil }
        return data
    }

    private static func filter(_ object: [String: Any], schema: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, rule) in schema {
            guard let value = object[key] else { continue }
            if value is NSNull { result[key] = NSNull() }
            else if let child = rule as? [String: Any], let dictionary = value as? [String: Any] {
                result[key] = filter(dictionary, schema: child)
            } else if let children = rule as? [[String: Any]], let child = children.first,
                      let values = value as? [[String: Any]] {
                result[key] = values.prefix(8).map { filter($0, schema: child) }
            } else if rule is Bool || key == "status" {
                if let string = value as? String { result[key] = String(string.prefix(2_048)) }
                else if let number = value as? NSNumber, number.doubleValue.isFinite { result[key] = number }
            }
        }
        return result
    }

    static func observationScript(serial: String) -> String {
        let parameters = try! JSONSerialization.data(withJSONObject: ["serial": serial, "schema": schema], options: [.sortedKeys])
        return "const lingxiFormParameters = " + String(decoding: parameters, as: UTF8.self) + ";\n" + observerSource
    }

    // This script observes responses to requests already made by Dashboard itself.
    // It does not issue requests, read authentication storage or interact with login UI.
    static let observerSource = #"""
    (() => {
      if (location.origin !== 'https://dashboard.formlabs.com' || window.top !== window) return;
      const parameters = lingxiFormParameters;
      const post = body => window.webkit.messageHandlers.formlabsPrinter.postMessage(body);
      const endpoint = raw => {
        try {
          const u = new URL(raw, location.href);
          return u.origin === 'https://api.formlabs.com' && u.pathname === '/printernet/v1/my/printers/'
            && (u.searchParams.get('detailed') || '').toLowerCase() === 'true';
        } catch (_) { return false; }
      };
      const clean = (value, schema) => {
        const result = {};
        for (const [key, rule] of Object.entries(schema)) {
          const item = value[key];
          if (item === null) result[key] = null;
          else if (Array.isArray(rule) && Array.isArray(item))
            result[key] = item.slice(0, 8).filter(x => x && typeof x === 'object').map(x => clean(x, rule[0]));
          else if (rule && typeof rule === 'object' && item && typeof item === 'object' && !Array.isArray(item))
            result[key] = clean(item, rule);
          else if (rule === true || key === 'status') {
            if (typeof item === 'string') result[key] = item.slice(0, 2048);
            else if (typeof item === 'boolean' || (typeof item === 'number' && Number.isFinite(item))) result[key] = item;
          }
        }
        return result;
      };
      const consume = (code, body) => {
        if (code === 401 || code === 403) { post({kind: 'loginRequired'}); return; }
        if (code < 200 || code >= 300) { post({kind: 'requestFailed'}); return; }
        let list = Array.isArray(body) ? body : null;
        if (!list && body && typeof body === 'object')
          for (const key of ['printers', 'results', 'data', 'items']) if (Array.isArray(body[key])) { list = body[key]; break; }
        if (!list) { post({kind: 'invalidResponse'}); return; }
        const printer = list.find(p => p && typeof p === 'object'
          && String(p.serial ?? p.printer_serial ?? p.serial_number ?? p.machine_id ?? p.id ?? '') === parameters.serial);
        if (!printer) { post({kind: 'printerNotFound'}); return; }
        post({kind: 'printer', printer: clean(printer, parameters.schema)});
      };
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = function(...args) {
        const raw = typeof args[0] === 'string' || args[0] instanceof URL ? String(args[0]) : args[0]?.url;
        return originalFetch.apply(this, args).then(response => {
          if (endpoint(raw)) {
            if (response.status === 401 || response.status === 403) consume(response.status, null);
            else response.clone().json().then(body => consume(response.status, body)).catch(() => post({kind: 'invalidResponse'}));
          }
          return response;
        }, error => {
          if (endpoint(raw)) post({kind: 'requestFailed'});
          throw error;
        });
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      const urls = new WeakMap(), observed = new WeakSet();
      XMLHttpRequest.prototype.open = function(method, url, ...args) {
        urls.set(this, String(url));
        if (!observed.has(this)) {
          observed.add(this);
          for (const event of ['error', 'timeout']) this.addEventListener(event, function() {
            if (endpoint(urls.get(this))) post({kind: 'requestFailed'});
          });
          this.addEventListener('load', function() {
            if (!endpoint(urls.get(this))) return;
            if (this.status === 401 || this.status === 403) { consume(this.status, null); return; }
            try {
              const body = this.responseType === 'json' ? this.response : JSON.parse(this.responseText);
              consume(this.status, body);
            } catch (_) { post({kind: 'invalidResponse'}); }
          });
        }
        return originalOpen.call(this, method, url, ...args);
      };
    })();
    """#
}

/// Owned by AppModel, not the login sheet. Closing the sheet keeps the authorized
/// official page alive; each managed source has its own on-device WebKit profile.
@MainActor
final class FormlabsDashboardSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let dashboardURL = URL(string: "https://dashboard.formlabs.com/")!
    // Dashboard can defer its detailed printer list until it has a usable layout.
    // A restored session must have a viewport before any login sheet is shown.
    static let backgroundViewport = CGSize(width: 1024, height: 768)
    private static let consentPrefix = "FormlabsDashboardAuthorized."
    let deviceID: UUID
    let serial: String
    let webView: WKWebView
    @Published private(set) var statusText = "请在官方 Dashboard 页面登录。"
    @Published private(set) var requiresLogin = false
    @Published private(set) var receivedAt: Date?
    private(set) var payload: Data?
    var onChange: (() -> Void)?
    var isLoginVisible = false
    private var timer: Timer?
    private var stopped = false
    private var lastPageLoad: Date?
    private var popups: [WKWebView] = []
    private var transientFailures = 0
    private var retryAfter: Date?

    static func isAuthorized(_ id: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: consentPrefix + id.uuidString)
    }

    static func authorize(_ id: UUID) {
        UserDefaults.standard.set(true, forKey: consentPrefix + id.uuidString)
    }

    static func forget(_ id: UUID, completion: @escaping @MainActor () -> Void = {}) {
        UserDefaults.standard.removeObject(forKey: consentPrefix + id.uuidString)
        let store = WKWebsiteDataStore(forIdentifier: id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            Task { @MainActor in completion() }
        }
    }

    init(deviceID: UUID, serial: String, websiteDataStore: WKWebsiteDataStore? = nil) {
        self.deviceID = deviceID
        self.serial = serial
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? WKWebsiteDataStore(forIdentifier: deviceID)
        configuration.userContentController.addUserScript(WKUserScript(
            source: FormlabsDashboardPayload.observationScript(serial: serial),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.backgroundViewport), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The content controller retains only a weak proxy, avoiding a WebView/session cycle.
        configuration.userContentController.add(WeakPrinterMessageHandler(self), name: "formlabsPrinter")
        webView.allowsBackForwardNavigationGestures = true
    }

    func start() {
        guard !stopped, Self.isAuthorized(deviceID), lastPageLoad == nil else { return }
        loadDashboard()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPageIfNeeded() }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate(); timer = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "formlabsPrinter")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for popup in popups { popup.stopLoading(); popup.removeFromSuperview() }
        popups = []
        onChange = nil
    }

    var currentPayload: Data? {
        guard !requiresLogin, let receivedAt, Date().timeIntervalSince(receivedAt) < 90 else { return nil }
        return payload
    }

    func refreshPageIfNeeded(force: Bool = false) {
        guard !stopped, Self.isAuthorized(deviceID) else { return }
        if !isLoginVisible, !requiresLogin, !webView.isLoading,
           let retryAfter, Date() >= retryAfter, transientFailures <= 3 {
            self.retryAfter = nil
            loadDashboard()
            return
        }
        if let receivedAt, Date().timeIntervalSince(receivedAt) >= 90 {
            let staleMessage = "Dashboard 暂未返回新状态，请打开登录页检查连接。"
            if statusText != staleMessage { statusText = staleMessage; onChange?() }
        }
        // Never reload a login form or interrupt an open interactive page.
        guard !isLoginVisible, !requiresLogin, receivedAt != nil, !webView.isLoading,
              force || Date().timeIntervalSince(lastPageLoad ?? .distantPast) >= 30,
              force || Date().timeIntervalSince(receivedAt ?? .distantPast) >= 30 else { return }
        loadDashboard()
    }

    func openDashboard() {
        guard !stopped else { return }
        transientFailures = 0
        retryAfter = nil
        loadDashboard()
    }

    private func loadDashboard() {
        if webView.window == nil, webView.bounds.width <= 0 || webView.bounds.height <= 0 {
            webView.setFrameSize(Self.backgroundViewport)
        }
        lastPageLoad = Date()
        webView.load(URLRequest(url: Self.dashboardURL))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard !stopped, message.frameInfo.isMainFrame,
              origin.protocol == "https", origin.host == "dashboard.formlabs.com",
              origin.port == 0 || origin.port == 443,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        accept(kind: kind, printer: body["printer"] as? [String: Any])
    }

    // Kept separate from WebKit so response lifecycle is testable without a live account.
    func accept(kind: String, printer: [String: Any]?) {
        guard !stopped else { return }
        switch kind {
        case "printer":
            guard let printer, let data = FormlabsDashboardPayload.sanitized(printer, serial: serial) else { return }
            payload = data; receivedAt = Date(); requiresLogin = false
            transientFailures = 0; retryAfter = nil
            statusText = "已连接 Dashboard，正在读取此打印机的网页状态。"
        case "loginRequired":
            payload = nil; requiresLogin = true; retryAfter = nil
            statusText = "Dashboard 登录已失效，请重新登录。"
        case "printerNotFound":
            payload = nil; requiresLogin = false; retryAfter = nil
            statusText = "当前 Dashboard 账号中未找到此序列号，请核对账号和序列号。"
        case "requestFailed", "invalidResponse":
            payload = nil
            scheduleRetry()
            statusText = "Dashboard 网页未能读取打印机，请打开登录页检查连接。"
        default: return
        }
        onChange?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, payload == nil, !requiresLogin else { return }
        statusText = "等待 Dashboard 的打印机列表；如页面提示登录，请先完成登录。"
        onChange?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !stopped, (error as NSError).code != NSURLErrorCancelled else { return }
        payload = nil
        scheduleRetry()
        statusText = transientFailures <= 3
            ? "Dashboard 页面加载失败，网络恢复后将自动重试；也可打开登录页重试。"
            : "Dashboard 页面多次加载失败，请检查网络后重新打开登录页。"
        onChange?()
    }

    private func scheduleRetry() {
        guard !requiresLogin else { return }
        transientFailures += 1
        retryAfter = transientFailures <= 3
            ? Date().addingTimeInterval(Double(30 * (1 << (transientFailures - 1)))) : nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped, webView === self.webView, let url = webView.url, url.host != nil else { return }
        let path = url.path.lowercased()
        if url.host != "dashboard.formlabs.com" || path.contains("login")
            || path.contains("signin") || path.contains("sign-in") || path.contains("auth") {
            payload = nil; requiresLogin = true; retryAfter = nil
            statusText = "请在官方网页完成登录，登录后会恢复状态同步。"
            onChange?()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !stopped, isLoginVisible else { return nil }
        if let url = navigationAction.request.url,
           url.scheme != "https" && url.absoluteString != "about:blank" { return nil }
        // Preserve normal SSO window/opener behavior in the same isolated WebKit profile.
        let popup = WKWebView(frame: self.webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.translatesAutoresizingMaskIntoConstraints = false
        self.webView.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: self.webView.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: self.webView.trailingAnchor),
            popup.topAnchor.constraint(equalTo: self.webView.topAnchor),
            popup.bottomAnchor.constraint(equalTo: self.webView.bottomAnchor)
        ])
        popups.append(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
        popups.removeAll { $0 === webView }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.scheme == "https" || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

@MainActor
private final class WeakPrinterMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: FormlabsDashboardSession?
    init(_ owner: FormlabsDashboardSession) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
