import AppKit
import Foundation
import SwiftUI
import WebKit

/// This window is never shown or activated. The nonpersistent page uses only a
/// fixture fetch implementation, so mounting/dismantling cannot access an account.
@MainActor private final class LoginFocusTest {
    let session = FormlabsDashboardSession(deviceID: UUID(), serial: "FORM-FIXTURE", websiteDataStore: .nonPersistent())
    var window: NSWindow!
    var hosting: NSHostingView<FormlabsDashboardLoginView>?
    var received = 0
    var focusVerified = false
    var detached = false

    func start() {
        let controller = session.webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: #"""
        window.fetch = async () => new Response(JSON.stringify([{serial:'FORM-FIXTURE',printer_status:{status:'PRINTING',current_print_run:{guid:'focus-fixture',name:'Fixture',layer_count:100,currently_printing_layer:20}}}]), {status:200,headers:{'Content-Type':'application/json'}});
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: FormlabsDashboardPayload.observationScript(serial: "FORM-FIXTURE"), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        session.onChange = { [weak self] in self?.changed() }
        session.isLoginVisible = true
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: FormlabsDashboardLoginView(session: session, onClose: {}))
        window.contentView = hosting
        hosting?.layoutSubtreeIfNeeded()
        session.webView.loadHTMLString("<html><body><input id='fixture' placeholder='Local fixture'><script>fetch('https://api.formlabs.com/printernet/v1/my/printers/?detailed=True');</script></body></html>", baseURL: FormlabsDashboardSession.dashboardURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            precondition(!self.window.isVisible, "test must never show a window")
            precondition(self.session.webView.window === self.window)
            let responder = self.window.firstResponder as? NSView
            precondition(responder === self.session.webView || responder?.isDescendant(of: self.session.webView) == true,
                         "attached WebKit must own the initial native responder")
            self.focusVerified = true
            self.detachWhenReady()
        }
    }

    func changed() {
        guard session.currentPayload != nil else { return }
        received += 1
        if detached {
            precondition(session.webView.window == nil)
            precondition(session.webView.navigationDelegate === session)
            print("Dashboard login focus: direct WebKit mount owns first responder once; never-shown window detach preserves session, delegate and subsequent fixture response")
            session.stop()
            exit(0)
        }
        detachWhenReady()
    }

    func detachWhenReady() {
        guard focusVerified, received > 0, !detached else { return }
        detached = true
        window.contentView = nil
        hosting = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Calls the fixture function already installed in this inline page;
            // it has no access to the original network fetch implementation.
            self?.session.webView.evaluateJavaScript("void fetch('https://api.formlabs.com/printernet/v1/my/printers/?detailed=True')") { _, error in
                precondition(error == nil)
            }
        }
    }
}

@main struct LoginFocusTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let test = LoginFocusTest(); test.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            print("Dashboard login focus fixture timed out"); exit(1)
        }
        withExtendedLifetime(test) { RunLoop.main.run() }
    }
}
