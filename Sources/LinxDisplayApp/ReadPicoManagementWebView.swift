import AppKit
import SwiftUI
import WebKit
import LinxDisplayCore

struct ReadPicoManagementWebView: View {
    let connection: ReadPicoConnection
    let draftGuard: ReadPicoDraftGuard
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ReadPicoManagementWebController

    init(connection: ReadPicoConnection, draftGuard: ReadPicoDraftGuard) {
        self.connection = connection
        self.draftGuard = draftGuard
        _controller = StateObject(wrappedValue: ReadPicoManagementWebController(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读器详细设置").font(.headline)
                Spacer()
                Button("完成") { controller.close { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.checkingDeparture)
            }.padding()
            ReadPicoWebSurface(controller: controller)
                .overlay {
                    if let error = controller.loadError {
                        ContentUnavailableView {
                            Label("无法打开设备设置", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重新载入") { controller.retryLoading() }
                                .buttonStyle(.borderedProminent)
                                .disabled(controller.checkingDeparture)
                        }.background(.background)
                    } else if controller.loading {
                        ProgressView("正在读取设备设置…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
        .frame(minWidth: 620, minHeight: 540)
        // Native sheet dismissal does not reliably run a page's beforeunload.
        .interactiveDismissDisabled()
        .onAppear { controller.register(with: draftGuard) { dismiss() } }
        .onDisappear { controller.invalidate() }
    }
}

@MainActor final class ReadPicoManagementWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum PageState: Equatable {
        case known(dirty: Bool, working: Bool)
        case unavailable
    }
    private enum DepartureKind { case close, navigation }
    private struct Departure {
        let kind: DepartureKind
        let allowed: () -> Void
        let cancelled: () -> Void
    }
    private final class Dialog {
        let alert: NSAlert
        let fallback: NSApplication.ModalResponse
        let completion: (NSApplication.ModalResponse) -> Void
        var finished = false
        init(_ alert: NSAlert, fallback: NSApplication.ModalResponse, completion: @escaping (NSApplication.ModalResponse) -> Void) {
            self.alert = alert; self.fallback = fallback; self.completion = completion
        }
        func finish(_ response: NSApplication.ModalResponse) {
            guard !finished else { return }; finished = true; completion(response)
        }
    }

    // Evaluate only two booleans. Never return input values, account details,
    // setup keys, tokens, passwords, or verification codes to the native app.
    static let departureQuery = """
    (() => {
      if ('readPicoManagementDepartureState' in window) {
        const query = window.readPicoManagementDepartureState;
        if (typeof query !== 'function') throw new Error('management-state-unavailable');
        const result = query.call(window);
        if (!result || typeof result !== 'object' || Array.isArray(result) ||
            typeof result.then === 'function' || Reflect.ownKeys(result).length !== 2 ||
            !Object.prototype.hasOwnProperty.call(result, 'dirty') ||
            !Object.prototype.hasOwnProperty.call(result, 'working') ||
            typeof result.dirty !== 'boolean' || typeof result.working !== 'boolean')
          throw new Error('management-state-unavailable');
        return {dirty: result.dirty, working: result.working};
      }
      if (typeof state !== 'object' || !state || !(state.dirty instanceof Set) ||
          !(state.pending instanceof Set) || typeof state.working !== 'boolean')
        throw new Error('management-state-unavailable');
      const auth = state.bambu;
      return {
        dirty: state.dirty.size > 0,
        working: state.working || state.pending.size > 0 ||
          !!(auth && (auth.pending || [1, 2, 3].includes(auth.phase)))
      };
    })()
    """

    // This marker assigns unload protection to the native gate; it does not
    // authorize a departure or clear the page's pending work.
    static let nativeDepartureGuardScript = """
    Object.defineProperty(window, '__readPicoNativeDepartureGuard', {
      value: true, writable: false, configurable: false
    });
    """

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: nativeDepartureGuardScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return configuration
    }

    let connection: ReadPicoConnection
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    @Published private(set) var checkingDeparture = false
    private(set) weak var webView: WKWebView?
    private(set) var activeAlert: NSAlert?
    private var activeDialog: Dialog?
    private var dialogs: [Dialog] = []
    private var departure: Departure?
    private var departureAlert: NSAlert?
    private var queryID: UUID?
    private var queryTimeout: DispatchWorkItem?
    private var hasLoaded = false
    private var invalidated = false
    private var approvedClose = false
    private var authorizedNavigation: URL?
    private weak var draftGuard: ReadPicoDraftGuard?
    private let ownerID = UUID()
    private static var exitOwners: [ObjectIdentifier: UUID] = [:]

    init(connection: ReadPicoConnection) { self.connection = connection }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func register(with draftGuard: ReadPicoDraftGuard, dismiss: @escaping () -> Void) {
        self.draftGuard = draftGuard
        Self.exitOwners[ObjectIdentifier(draftGuard)] = ownerID
        draftGuard.childDeparture = { [weak self, weak draftGuard] continuation in
            guard let self else { draftGuard?.cancelChildDeparture(); return }
            self.requestDeparture(kind: .close, cancelled: { [weak draftGuard] in draftGuard?.cancelChildDeparture() }) {
                dismiss()
                // Let the web sheet detach before a parent prompt or quit opens.
                DispatchQueue.main.async { continuation() }
            }
        }
    }

    func close(_ dismiss: @escaping () -> Void) {
        requestDeparture(kind: .close, cancelled: { [weak draftGuard] in draftGuard?.cancelChildDeparture() }, allowed: dismiss)
    }

    func retryLoading() {
        guard loadError != nil, !invalidated else { return }
        let reload = { [weak self] in
            guard let self, !self.invalidated else { return }
            self.loading = true; self.loadError = nil
            self.webView?.load(URLRequest(url: self.connection.managementURL))
        }
        if hasLoaded { requestDeparture(kind: .navigation, cancelled: {}, allowed: reload) }
        else { reload() }
    }

    func invalidate() {
        invalidated = true
        if let draftGuard, Self.exitOwners[ObjectIdentifier(draftGuard)] == ownerID {
            Self.exitOwners.removeValue(forKey: ObjectIdentifier(draftGuard))
            draftGuard.childDeparture = nil
        }
        departure?.cancelled(); departure = nil
        queryTimeout?.cancel(); queryTimeout = nil; queryID = nil
        checkingDeparture = false
        let current = activeDialog
        activeDialog = nil; activeAlert = nil; departureAlert = nil
        if let current, let parent = current.alert.window.sheetParent { parent.endSheet(current.alert.window, returnCode: current.fallback) }
        current?.finish(current?.fallback ?? .abort)
        let pending = dialogs; dialogs = []
        for dialog in pending { dialog.finish(dialog.fallback) }
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
    }

    func queryPageState(_ completion: @escaping (PageState) -> Void) {
        guard !invalidated, let webView else { completion(.unavailable); return }
        let id = UUID(); queryID = id
        queryTimeout?.cancel()
        let finish: (PageState) -> Void = { [weak self] result in
            guard let self, self.queryID == id else { return }
            self.queryID = nil; self.queryTimeout?.cancel(); self.queryTimeout = nil
            completion(result)
        }
        let timeout = DispatchWorkItem { finish(.unavailable) }
        queryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        webView.evaluateJavaScript(Self.departureQuery) { value, error in
            guard error == nil, let values = value as? [String: Any], Set(values.keys) == ["dirty", "working"],
                  let dirty = values["dirty"] as? Bool, let working = values["working"] as? Bool else {
                finish(.unavailable); return
            }
            finish(.known(dirty: dirty, working: working))
        }
    }

    private func requestDeparture(kind: DepartureKind, cancelled: @escaping () -> Void, allowed: @escaping () -> Void) {
        guard !invalidated else { cancelled(); return }
        if approvedClose { allowed(); return }
        departure = Departure(kind: kind, allowed: allowed, cancelled: cancelled)
        if let departureAlert { configureDepartureAlert(departureAlert) }
        startDepartureQuery()
    }

    private func startDepartureQuery() {
        guard departure != nil, !checkingDeparture, activeDialog == nil, dialogs.isEmpty, !invalidated else { return }
        checkingDeparture = true
        queryPageState { [weak self] state in
            guard let self, self.departure != nil, !self.invalidated else { return }
            if state == .known(dirty: false, working: false) { self.finishDeparture(allow: true); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.addButton(withTitle: "返回继续填写")
            alert.addButton(withTitle: "放弃并关闭")
            alert.buttons[0].keyEquivalent = "\u{1b}"
            alert.buttons[1].keyEquivalent = ""
            self.departureAlert = alert
            self.configureDepartureAlert(alert, state: state)
            self.present(alert, fallback: .alertFirstButtonReturn) { [weak self] response in
                self?.departureAlert = nil
                self?.finishDeparture(allow: response == .alertSecondButtonReturn)
            }
        }
    }

    private func configureDepartureAlert(_ alert: NSAlert, state: PageState? = nil) {
        let closing = departure?.kind == .close
        alert.messageText = closing ? "关闭前请确认设备设置" : "重新读取前请确认设备设置"
        alert.buttons[1].title = closing ? "放弃并关闭" : "放弃并重新读取"
        if let state {
            var message: String
            switch state {
            case .known(let dirty, let working):
                message = dirty ? "此页还有未保存的修改。" : ""
                if working { message += "设备请求或 Bambu Lab 账户验证仍在进行，设备可能在关闭后继续处理。" }
            case .unavailable:
                message = "暂时无法确认网页的保存状态。为避免丢失输入，建议先返回检查。"
            }
            alert.informativeText = message + "\n请使用页面各表单的保存按钮完成保存。放弃后，未保存的输入和验证码不会保留。"
        }
    }

    private func finishDeparture(allow: Bool) {
        guard let request = departure else { return }
        departure = nil; checkingDeparture = false
        if allow { approvedClose = request.kind == .close; request.allowed() }
        else { request.cancelled() }
    }

    private func present(_ alert: NSAlert, fallback: NSApplication.ModalResponse, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let dialog = Dialog(alert, fallback: fallback, completion: completion)
        guard !invalidated else { dialog.finish(fallback); return }
        dialogs.append(dialog); presentNextDialog()
    }

    private func presentNextDialog() {
        guard !invalidated, activeDialog == nil, !dialogs.isEmpty else { return }
        let dialog = dialogs.removeFirst(); activeDialog = dialog; activeAlert = dialog.alert
        guard let window = webView?.window else { complete(dialog, response: dialog.fallback); return }
        dialog.alert.beginSheetModal(for: window) { [weak self] response in self?.complete(dialog, response: response) }
    }

    private func complete(_ dialog: Dialog, response: NSApplication.ModalResponse) {
        guard activeDialog === dialog else { dialog.finish(dialog.fallback); return }
        activeDialog = nil; activeAlert = nil
        dialog.finish(response)
        presentNextDialog(); startDepartureQuery()
    }

    func allows(_ url: URL) -> Bool {
        let origin = connection.baseURL
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
        return url.scheme?.lowercased() == origin.scheme?.lowercased() && url.host?.lowercased() == origin.host?.lowercased() &&
            port(url) == port(origin) && ["/manage", "/"].contains(url.path)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, allows(url), let frame = navigationAction.targetFrame else { decisionHandler(.cancel); return }
        guard frame.isMainFrame else { decisionHandler(.allow); return }
        if !hasLoaded || authorizedNavigation == url {
            authorizedNavigation = nil; decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        let request = navigationAction.request
        requestDeparture(kind: .navigation, cancelled: {}) { [weak self, weak webView] in
            self?.authorizedNavigation = url
            webView?.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { hasLoaded = true; loading = false; loadError = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; loadError = "请在阅读器打开“手机与电脑管理”，并检查 Mac 与设备的网络连接。"
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let url = frame.request.url, allows(url) else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = "设备设置"; alert.informativeText = String(message.prefix(4000)); alert.alertStyle = .warning
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        present(alert, fallback: .alertSecondButtonReturn) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let url = frame.request.url, allows(url) else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = "设备设置"; alert.informativeText = String(message.prefix(4000)); alert.addButton(withTitle: "好")
        present(alert, fallback: .alertFirstButtonReturn) { _ in completionHandler() }
    }
}

private struct ReadPicoWebSurface: NSViewRepresentable {
    let controller: ReadPicoManagementWebController
    func makeNSView(context: Context) -> WKWebView {
        let configuration = ReadPicoManagementWebController.makeConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        controller.attach(view); view.load(URLRequest(url: controller.connection.managementURL))
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
