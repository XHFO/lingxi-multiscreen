import AppKit
import Foundation
import WebKit

/// Uses production Session construction without a window or prior sheet. Inline
/// fixtures simulate a page that waits for layout before reading its printer list.
@MainActor private final class ViewportTestsDriver: NSObject, WKScriptMessageHandler {
    var sessions: [String: FormlabsDashboardSession] = [:]
    var viewports: [String: [String: Any]] = [:]
    var observed: Set<String> = []
    var completing = false

    func start() {
        for label in ["production", "zero-control"] {
            let session = FormlabsDashboardSession(deviceID: UUID(), serial: "FORM-FIXTURE", websiteDataStore: .nonPersistent())
            sessions[label] = session
            precondition(session.webView.window == nil && session.webView.superview == nil)
            precondition(session.webView.frame.size == CGSize(width: 1024, height: 768))
            if label == "zero-control" { session.webView.setFrameSize(.zero) }
            let scripts = session.webView.configuration.userContentController
            scripts.removeAllUserScripts()
            scripts.addUserScript(WKUserScript(source: #"""
            window.fetch = async () => new Response(JSON.stringify([{serial:'FORM-FIXTURE',printer_status:{status:'PRINTING',current_print_run:{guid:'viewport-test',name:'Fixture',layer_count:100,currently_printing_layer:20}}}]),{status:200,headers:{'Content-Type':'application/json'}});
            """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            scripts.addUserScript(WKUserScript(source: FormlabsDashboardPayload.observationScript(serial: "FORM-FIXTURE"), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            scripts.add(self, name: "viewportProbe")
            session.onChange = { [weak self, weak session] in
                guard let self, let session, session.currentPayload != nil else { return }
                self.observed.insert(label); self.finishIfReady()
            }
            let html = """
            <html><body><script>
            const size={label:'\(label)',width:innerWidth,height:innerHeight,clientWidth:document.documentElement.clientWidth,clientHeight:document.documentElement.clientHeight};
            window.webkit.messageHandlers.viewportProbe.postMessage(size);
            if(size.width>0&&size.height>0)fetch('https://api.formlabs.com/printernet/v1/my/printers/?detailed=True');
            </script></body></html>
            """
            session.webView.loadHTMLString(html, baseURL: FormlabsDashboardSession.dashboardURL)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let value = message.body as! [String: Any]
        let label = value["label"] as! String
        viewports[label] = value
        finishIfReady()
    }

    func finishIfReady() {
        guard !completing, viewports.count == 2, observed.contains("production") else { return }
        completing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            let production = viewports["production"]!, zero = viewports["zero-control"]!
            precondition((production["width"] as! NSNumber).intValue == 1024)
            precondition((production["height"] as! NSNumber).intValue == 768)
            precondition((production["clientWidth"] as! NSNumber).intValue == 1024)
            precondition((zero["width"] as! NSNumber).intValue == 0 && (zero["height"] as! NSNumber).intValue == 0)
            precondition(!observed.contains("zero-control"))
            precondition(sessions.values.allSatisfy { $0.webView.window == nil && $0.webView.superview == nil })
            print("Dashboard startup viewport: production hidden Session is 1024x768 before any sheet; layout-gated fixture response observed. Zero-size control remains 0x0 and emits no printer request. No window/account/network used.")
            sessions.values.forEach { $0.stop() }
            exit(0)
        }
    }
}

@main struct ViewportTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let test = ViewportTestsDriver(); test.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            print("Dashboard viewport fixture timed out"); exit(1)
        }
        withExtendedLifetime(test) { RunLoop.main.run() }
    }
}
