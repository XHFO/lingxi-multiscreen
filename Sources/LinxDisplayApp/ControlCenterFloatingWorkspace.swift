import AppKit
import Combine
import LinxDisplayCore
import SwiftUI

/// Presentation context is separate from the active device/page model: expanding a
/// dashboard card does not create another settings store or another device session.
struct ControlCenterFloatingDeviceRoute {
    let presentationID = UUID()
    let device: ManagedDevice
    let sourceFrame: CGRect?
    let previewImage: NSImage?
}

/// A card expands in place into a native workspace, preserving the overview below it.
/// The original preview remains visible during the expansion; the existing device
/// settings and page navigation are then revealed inside the expanded surface.
struct ControlCenterFloatingWorkspace<Content: View>: View {
    let route: ControlCenterFloatingDeviceRoute
    let deviceName: String
    let isClosing: Bool
    let onClose: () -> Void
    let onCloseCompleted: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var expanded = false
    @State private var revealContent = false
    @State private var dismissRequested = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width > 1100 ? 30 : 16
            let target = CGRect(x: inset, y: inset,
                                width: max(1, geometry.size.width - inset * 2),
                                height: max(1, geometry.size.height - inset * 2))
            let source = initialFrame(in: geometry, fallback: target)
            let frame = expanded || reduceMotion ? target : source
            ZStack(alignment: .topLeading) {
                Color.black.opacity(expanded ? 0.22 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                workspace(finalSize: target.size)
                    .frame(width: frame.width, height: frame.height)
                    .background {
                        if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                        else { Rectangle().fill(.regularMaterial) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 24 : 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: expanded ? 24 : 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(expanded ? 0.24 : 0.08), radius: expanded ? 30 : 8, y: expanded ? 12 : 2)
                    .offset(x: frame.minX, y: frame.minY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onExitCommand(perform: onClose)
        .accessibilityIdentifier("control-center-floating-workspace")
        .task {
            if route.previewImage == nil {
                // Service-only cards have no image to cover the editor; keep
                // their content present instead of expanding an empty surface.
                updateWithoutAnimation { revealContent = true }
            }
            if reduceMotion {
                updateWithoutAnimation {
                    expanded = true
                    revealContent = true
                }
                closeFocused = true
            } else {
                // Commit the source geometry for one display frame before expanding.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, !dismissRequested else { return }
                // Only the shell moves. Crossfading native Forms over the source
                // image while the material is also resizing produces a bright
                // intermediate composite. The editor is already laid out behind
                // the image; exchange them once the expansion actually finishes.
                withAnimation(.easeInOut(duration: 0.26), completionCriteria: .logicallyComplete) {
                    expanded = true
                } completion: {
                    guard !dismissRequested, !isClosing else { return }
                    updateWithoutAnimation { revealContent = true }
                    closeFocused = true
                }
            }
        }
        .onChange(of: isClosing) { closing in
            guard closing, !dismissRequested else { return }
            dismissRequested = true
            updateWithoutAnimation { revealContent = route.previewImage == nil }
            if reduceMotion { onCloseCompleted() }
            else {
                withAnimation(.easeInOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                    expanded = false
                } completion: { onCloseCompleted() }
            }
        }
        .onDisappear { dismissRequested = true }
    }

    private func workspace(finalSize: CGSize) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image = route.previewImage {
                    DeviceControlCenterPreviewSurface(deviceType: route.device.type, image: image)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(revealContent ? 0 : 1)
                        .animation(nil, value: revealContent)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.body.weight(.semibold))
                                .frame(width: 32, height: 32).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .help(String(localized: "关闭设备详情"))
                        .accessibilityLabel("关闭设备详情")
                        .accessibilityIdentifier("control-center-close-device")
                        .focused($closeFocused)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceName).font(.headline).lineLimit(1)
                            Text(route.device.type.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Label("设备详情", systemImage: "slider.horizontal.3")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                    Divider()
                    content()
                        // Forms and lists normally paint their own opaque scroll
                        // surface. Here they share the enclosing window material.
                        .scrollContentBackground(.hidden)
                        .environment(\.controlCenterUsesFloatingSurface, true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: finalSize.width, height: finalSize.height)
                .opacity(revealContent ? 1 : 0)
                .animation(nil, value: revealContent)
                .allowsHitTesting(revealContent && !isClosing)
                .accessibilityHidden(!revealContent || isClosing)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
    }

    private func updateWithoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    private func initialFrame(in geometry: GeometryProxy, fallback: CGRect) -> CGRect {
        guard !reduceMotion, let global = route.sourceFrame,
              global.width.isFinite, global.height.isFinite,
              global.width > 0, global.height > 0 else { return fallback.insetBy(dx: 30, dy: 30) }
        let origin = geometry.frame(in: .global).origin
        return CGRect(x: global.minX - origin.x, y: global.minY - origin.y,
                      width: global.width, height: global.height)
    }
}

private struct ControlCenterHasExternalPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ControlCenterUsesFloatingSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Device forms keep their settings and actions when the floating workspace
    /// provides a persistent, shared preview outside the scrolling editor.
    var controlCenterHasExternalPreview: Bool {
        get { self[ControlCenterHasExternalPreviewKey.self] }
        set { self[ControlCenterHasExternalPreviewKey.self] = newValue }
    }

    /// Presentation styling is independent of preview ownership: a regular
    /// device page can own an external preview without becoming a floating view.
    var controlCenterUsesFloatingSurface: Bool {
        get { self[ControlCenterUsesFloatingSurfaceKey.self] }
        set { self[ControlCenterUsesFloatingSurfaceKey.self] = newValue }
    }
}

/// A nested grouped Form or List owns a native scroll surface of its own. Hiding only
/// the workspace's outer ScrollView does not make that inner surface transparent.
/// Apply this at each Form boundary, preserving ordinary inline form styling and
/// the real white pixels inside paper, artwork, and device-screen previews.
private struct ControlCenterHostedFormSurface: ViewModifier {
    @Environment(\.controlCenterUsesFloatingSurface) private var usesFloatingSurface

    @ViewBuilder func body(content: Content) -> some View {
        if usesFloatingSurface { content.scrollContentBackground(.hidden) }
        else { content }
    }
}

extension View {
    func controlCenterHostedFormSurface() -> some View {
        modifier(ControlCenterHostedFormSurface())
    }

    /// The panel is UI chrome, rather than the pixels of an image or screen.
    /// Ordinary inline pages keep the native control background.
    func controlCenterHostedPanelSurface<S: Shape>(in shape: S) -> some View {
        modifier(ControlCenterHostedPanelSurface(shape: shape))
    }

    func controlCenterHostedPanelSurface() -> some View {
        controlCenterHostedPanelSurface(in: Rectangle())
    }

    /// Opt in at a native sheet/popover root, not at each child control.
    func controlCenterFloatingPresentationSurface() -> some View {
        modifier(ControlCenterFloatingPresentationSurface())
    }
}

private struct ControlCenterHostedPanelSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.controlCenterUsesFloatingSurface) private var usesFloatingSurface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            shape.fill(usesFloatingSurface && !reduceTransparency
                ? Color.primary.opacity(contrast == .increased ? 0.07 : 0.035)
                : Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct ControlCenterFloatingPresentationSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.environment(\.controlCenterUsesFloatingSurface, true)
                .presentationBackground(Color(nsColor: .windowBackgroundColor))
        } else {
            content.environment(\.controlCenterUsesFloatingSurface, true)
                .presentationBackground(.regularMaterial)
        }
    }
}

/// AppKit's explicit main-window appearance is mirrored into SwiftUI's
/// presentation preference so native sheets and popovers follow the same choice.
/// This observes software appearance only; device rendering themes are unrelated.
struct LingxiSoftwareAppearanceSurface: ViewModifier {
    @ObservedObject var settings: AppSettings

    func body(content: Content) -> some View {
        content.preferredColorScheme(preferredScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch settings.appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A persistent read-only preview across every page of a floating device workspace.
/// It refreshes existing render/cache state without changing the active device,
/// starting a transport session, or pushing anything to the physical display.
struct ControlCenterFloatingLivePreview: View {
    @ObservedObject var model: AppModel
    @Environment(\.controlCenterUsesFloatingSurface) private var usesFloatingSurface
    let deviceID: UUID
    var picoDrafts: ReadPicoDraftGuard? = nil
    var previewLockScreen = false
    @State private var preview: DeviceControlCenterPreview?
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private var device: ManagedDevice? { model.settings.devices.first { $0.id == deviceID } }
    private var picoChanges: AnyPublisher<Void, Never> {
        picoDrafts?.objectWillChange.eraseToAnyPublisher() ?? Empty<Void, Never>().eraseToAnyPublisher()
    }

    var body: some View {
        // Reparenting between a floating and inline workspace creates a new
        // presentation view, not a new device reading. Seed its first display
        // synchronously so an empty placeholder does not flash before .task.
        let reading = preview ?? makePreview()
        VStack(spacing: 0) {
            ZStack {
                Color.clear
                if device?.type == .readPico {
                    ReadPicoDevicePreview(image: reading?.image).padding(14)
                } else if let device, let image = reading?.image {
                    DeviceControlCenterPreviewSurface(deviceType: device.type, image: image)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: device?.type.capabilityProfile?.icon ?? "display")
                            .font(.system(size: 34, weight: .regular))
                        Text(reading?.caption ?? String(localized: "暂无画面"))
                            .font(.callout).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(20)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                Image(systemName: reading?.source == .deviceFrame ? "display" : "desktopcomputer")
                Text(reading?.caption ?? String(localized: "屏幕预览"))
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        // The device image retains its real colors, including e-paper white;
        // the surrounding preview chrome belongs to the shared floating surface.
        .background(usesFloatingSurface ? Color.primary.opacity(0.025) : Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("control-center-persistent-preview")
        .task(id: deviceID) { refreshPreview() }
        .onReceive(refresh) { _ in refreshPreview() }
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(240), scheduler: RunLoop.main)) { _ in
            refreshPreview()
        }
        .onReceive(picoChanges.debounce(for: .milliseconds(260), scheduler: RunLoop.main)) { _ in
            refreshPreview()
        }
        .onChange(of: previewLockScreen) { _ in refreshPreview() }
    }

    private func refreshPreview() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { preview = makePreview() }
    }

    private func makePreview() -> DeviceControlCenterPreview? {
        guard let device else { return nil }
        if device.type == .readPico, let picoDrafts, previewLockScreen {
            let bitmap = picoDrafts.lockScreen.hasImage ? picoDrafts.lockScreen.bitmap
                : picoDrafts.model.pendingLockImage ?? picoDrafts.model.lockImagePreview
            let image = bitmap.flatMap { NSImage(data: $0) }
            return .init(image: image, source: image == nil ? .unavailable : .localRender,
                         status: String(localized: "图片锁屏"))
        }
        let cached = model.controlCenterPreview(for: device)
        if cached.image == nil, device.type == .readPico, device.isEnabled,
           let picoDrafts, picoDrafts.canvas.hasRenderableBoardContent,
           let frame = try? ReadPicoLingxiBoardRenderer.render(draft: picoDrafts.canvas, model: model, deviceID: deviceID) {
            return .init(image: frame.preview, source: .localRender, status: String(localized: "灵犀画板"))
        }
        return cached
    }
}
