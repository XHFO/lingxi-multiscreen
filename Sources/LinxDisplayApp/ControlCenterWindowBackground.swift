import AppKit
import SwiftUI

/// Samples the desktop and other applications behind the window, rather than
/// blurring the dashboard's own cards. The window change belongs to this surface
/// only and is restored when navigating away or detaching the hosting view.
struct ControlCenterWindowBackground: NSViewRepresentable {
    var isEnabled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> ControlCenterBackdropView {
        ControlCenterBackdropView()
    }

    func updateNSView(_ view: ControlCenterBackdropView, context: Context) {
        view.setTranslucent(isEnabled && !reduceTransparency)
    }

    static func dismantleNSView(_ view: ControlCenterBackdropView, coordinator: ()) {
        view.setTranslucent(false)
    }
}

final class ControlCenterBackdropView: NSGlassEffectView {
    private weak var configuredWindow: NSWindow?
    private var originalBackground: NSColor?
    private var originalOpaque = true
    private var translucent = false

    init() {
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 0
        // Keep the system glass fully opaque as a compositing layer: lowering its
        // alpha would mix sharp, untreated background detail back into the window.
        alphaValue = 1
        contentView = NSView(frame: .zero)
        updateTint()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTranslucent(_ enabled: Bool) {
        translucent = enabled
        isHidden = !enabled
        updateWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    // Background decoration must not intercept dashboard clicks or dragging.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateTint() {
        // A semantic tint calms desktop colors in both appearances while the
        // native regular glass retains its actual backdrop blur.
        tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.40)
    }

    private func updateWindow() {
        if configuredWindow !== window || !translucent { restoreWindow() }
        guard translucent, let window, configuredWindow == nil else { return }
        originalBackground = window.backgroundColor
        originalOpaque = window.isOpaque
        configuredWindow = window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.invalidateShadow()
    }

    private func restoreWindow() {
        guard let window = configuredWindow else { return }
        window.isOpaque = originalOpaque
        window.backgroundColor = originalBackground
        window.invalidateShadow()
        configuredWindow = nil
        originalBackground = nil
    }
}
