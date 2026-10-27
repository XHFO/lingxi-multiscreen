import AppKit
import SwiftUI
import LinxDisplayCore

@MainActor private final class Visibility: ObservableObject { @Published var visible = true }
private final class Ports: @unchecked Sendable {
    let lock = NSLock(); private var value: [String] = []; private var opens = 0
    func set(_ ports: [String]) { lock.lock(); value = ports; lock.unlock() }
    func list() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
    func opened() -> ReadPicoUSBStartResult { lock.lock(); opens += 1; lock.unlock(); return .init() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return opens }
}
private struct Host: View {
    @ObservedObject var visibility: Visibility
    let drafts: ReadPicoDraftGuard
    var body: some View {
        ReadPicoManagerView(draftGuard: drafts, automaticUSBPreparation: true,
                            fileManagementVisible: visibility.visible)
            .opacity(visibility.visible ? 1 : 0).allowsHitTesting(visibility.visible)
    }
}
@main struct USBVisibilityTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let ports = Ports(), visibility = Visibility()
        let model = ReadPicoManagerModel(usbClient: .init { _, _ in ports.opened() },
                                        discoverVolumes: { [] }, discoverUSBPorts: { ports.list() },
                                        identifyUSBPort: { _ in "offline-visibility" })
        let drafts = ReadPicoDraftGuard(model: model)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 850, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(visibility: visibility, drafts: drafts))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        visibility.visible = false
        try await Task.sleep(nanoseconds: 100_000_000)
        ports.set(["/dev/cu.usbmodem-visibility-fixture"])
        try await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(window.attachedSheet == nil && ports.count() == 0, "hidden file page must not present USB confirmation or start transport")
        visibility.visible = true
        try await Task.sleep(nanoseconds: 1_300_000_000)
        guard let prompt = window.attachedSheet?.contentView else { fatalError("visible file page should offer first device confirmation") }
        func cancel(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "暂不连接" { button.performClick(nil); return true }
            return view.subviews.contains(where: cancel)
        }
        precondition(cancel(prompt), "native product confirmation has explicit cancel")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(window.attachedSheet == nil && ports.count() == 0, "cancelled automatic confirmation stays dismissed without retrying")
        drafts.deactivate(); window.close()
        print("PASS: 4 native SwiftUI visibility, first-device confirmation and cancellation checks; no physical serial opened.")
    }
}
