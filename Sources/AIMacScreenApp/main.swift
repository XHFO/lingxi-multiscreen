import AppKit
import SwiftUI

@MainActor
final class AIMacScreenAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AIMacScreenModel?
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AIMacScreenModel()
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "灵犀小屏实验版"
        window.contentView = NSHostingView(rootView: AIMacScreenView(model: model))
        window.center()
        window.setFrameAutosaveName("LingxiAIMacScreenExperimental.MainWindow")
        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AIMacScreenAppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
