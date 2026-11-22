import AppKit
import Foundation
import WebKit

/// A hidden, nonpersistent WebView runs inline fixtures only. Its fetch is replaced
/// before the production observer is injected, so no Formlabs request is made.
@MainActor
private final class HiddenPageTest: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var webView: WKWebView!
    var received = 0
    var allowedInitialHTML = false
    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let fixture = #"""
        window.fetch = async () => new Response(JSON.stringify([{serial:'FORM-FIXTURE',alias:'Fixture',user:{email:'discard'},printer_status:{status:'PRINTING',current_print_run:{guid:'hidden-test',name:'Print fixture',layer_count:100,currently_printing_layer:20}}}]), {status:200,headers:{'Content-Type':'application/json'}});
        """#
        configuration.userContentController.addUserScript(WKUserScript(source: fixture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: FormlabsDashboardPayload.observationScript(serial: "FORM-FIXTURE"), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: "formlabsPrinter")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        // No NSWindow or superview is created, matching the background session.
        webView.loadHTMLString("<html><body>Local fixture<script>fetch('https://api.formlabs.com/printernet/v1/my/printers/?detailed=True');setTimeout(()=>fetch('https://api.formlabs.com/printernet/v1/my/printers/?detailed=True'),100);</script></body></html>", baseURL: FormlabsDashboardSession.dashboardURL)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        precondition(webView.window == nil && webView.superview == nil)
        precondition(message.frameInfo.isMainFrame)
        precondition(message.frameInfo.securityOrigin.protocol == "https")
        precondition(message.frameInfo.securityOrigin.host == "dashboard.formlabs.com")
        let body = message.body as! [String: Any]
        precondition(body["kind"] as? String == "printer")
        let printer = body["printer"] as! [String: Any]
        precondition(printer["serial"] as? String == "FORM-FIXTURE" && printer["user"] == nil)
        let run = (printer["printer_status"] as! [String: Any])["current_print_run"] as! [String: Any]
        precondition(run["guid"] as? String == "hidden-test")
        received += 1
        if received == 2 {
            print("Hidden WebKit: official-origin inline fixtures delivered twice without a window, native origin check and GUID/account projection passed; no account or network used")
            exit(0)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // WebKit reports the supplied baseURL for the initial loadHTMLString. It
        // still loads the inline bytes, not that URL. Reject all later navigation.
        let initial = !allowedInitialHTML && (navigationAction.request.url?.scheme == "about"
            || navigationAction.request.url == FormlabsDashboardSession.dashboardURL)
        allowedInitialHTML = true
        decisionHandler(initial ? .allow : .cancel)
    }
}

@main struct HiddenWebViewTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let test = HiddenPageTest()
        test.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            print("Hidden WebKit fixture timed out before receiving two responses")
            exit(1)
        }
        withExtendedLifetime(test) { RunLoop.main.run() }
    }
}
