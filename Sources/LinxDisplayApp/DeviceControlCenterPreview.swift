import AppKit
import LinxDisplayCore
import SwiftUI

struct DeviceControlCenterPreview {
    enum Source { case deviceFrame, localRender, unavailable, noDisplay, disabled }
    let image: NSImage?
    let source: Source
    let status: String
    var caption: String {
        switch source {
        case .deviceFrame: return String(localized: "最近设备画面")
        case .localRender: return String(localized: "本机内容预览")
        case .unavailable: return String(localized: "暂无画面")
        case .noDisplay: return String(localized: "服务与控制设备")
        case .disabled: return String(localized: "设备已停用")
        }
    }
}

/// Reuses the same product photographs and screen coordinates as each device's detail preview.
/// It only composes a local presentation; the image used for a device push is left untouched.
struct DeviceControlCenterPreviewSurface: View {
    let deviceType: DeviceType
    let image: NSImage

    private static let keyboardFrame: NSImage? = {
        guard let url = Bundle.main.url(forResource: "akko2", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geometry in
            switch deviceType {
            case .readPico:
                ReadPicoDevicePreview(image: image).padding(14)
            case .keyboard:
                if let frame = Self.keyboardFrame {
                    keyboardPreview(frame: frame, in: geometry.size)
                } else { plainPreview }
            case .oracle:
                if let frame = PreviewResources.oracleHeroImage {
                    heroPreview(frame: frame, screenRect: PreviewResources.oracleHeroScreenRect,
                                cornerRadius: PreviewResources.oracleHeroScreenCornerRadius, in: geometry.size)
                } else { plainPreview }
            case .excerpt:
                if let frame = PreviewResources.heroImage {
                    heroPreview(frame: frame, screenRect: PreviewResources.heroScreenRect, in: geometry.size)
                } else { plainPreview }
            case .m5Controller:
                if let frame = PreviewResources.m5StickS3Image {
                    controllerPreview(frame: frame, in: geometry.size)
                } else { plainPreview }
            default:
                plainPreview
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "屏幕预览"))
    }

    private var plainPreview: some View {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(18)
    }

    private func fittedSize(for frame: NSImage, in available: CGSize) -> CGSize {
        let width = max(1, available.width - 28)
        let height = max(1, available.height - 28)
        let ratio = frame.size.width / max(1, frame.size.height)
        return width / height > ratio
            ? CGSize(width: height * ratio, height: height)
            : CGSize(width: width, height: width / max(0.001, ratio))
    }

    private func heroPreview(frame: NSImage, screenRect: CGRect, cornerRadius: CGFloat = 0,
                             in available: CGSize) -> some View {
        let fitted = fittedSize(for: frame, in: available)
        let scale = fitted.width / max(1, frame.size.width)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: frame).resizable().interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: available.width / 2, y: available.height / 2)
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: screenRect.width * scale, height: screenRect.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous))
                .position(x: origin.x + screenRect.midX * scale,
                          y: origin.y + (frame.size.height - screenRect.midY) * scale)
        }
        .frame(width: available.width, height: available.height)
    }

    private func keyboardPreview(frame: NSImage, in available: CGSize) -> some View {
        let fitted = fittedSize(for: frame, in: available)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        let screen = LingxiKeyboardPreviewGeometry(frameSize: fitted)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: frame).resizable().interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: available.width / 2, y: available.height / 2)
            DevicePreviewSurface(image: image, bezelSize: screen.bezelRect.size,
                                 borderWidth: screen.borderWidth, cornerRadius: screen.cornerRadius)
                .position(x: origin.x + screen.bezelRect.midX, y: origin.y + screen.bezelRect.midY)
        }
        .frame(width: available.width, height: available.height)
    }

    private func controllerPreview(frame: NSImage, in available: CGSize) -> some View {
        let fitted = fittedSize(for: frame, in: available)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: frame).resizable().interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: available.width / 2, y: available.height / 2)
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: fitted.width * 0.58, height: fitted.height * 0.50)
                .position(x: origin.x + fitted.width * 0.50, y: origin.y + fitted.height * 0.348)
        }
        .frame(width: available.width, height: available.height)
    }
}

extension AppModel {
    /// Mirrors the existing controller detail preview without selecting or connecting a device.
    /// A live payload belongs only to the active controller; other saved controllers use their own settings.
    @MainActor func m5ScreenPreviewState(for deviceID: UUID)
        -> (info: M5ControllerInfo, connected: Bool, secured: Bool) {
        let config = m5ControllerSettings(for: deviceID)
        let targetCount = m5ResolvedTargets(config).count
        let shortcuts = config.resolvedMacShortcuts.filter(\.isEnabled)
        let vibeCount = shortcuts.filter { $0.group == .vibeCoding }.count
        let fallback = M5ControllerInfo(active: 0, devices: [
            .init(name: "Vibe Coding", detail: "\(vibeCount) 个可用动作", available: vibeCount > 0),
            .init(name: "多屏设备", detail: "\(targetCount) 台已配置", available: true),
            .init(name: "Home Assistant", detail: "\(config.homeAssistantEntityIDs?.count ?? 0) 个控制实体", available: true),
            .init(name: "Mac 快捷键", detail: "媒体 + \(max(0, shortcuts.count - vibeCount)) 个动作", available: true)
        ], title: "灵犀控制器", footer: "A/B选择 长A进入")
        let connected = activeDeviceID(for: .m5Controller) == deviceID && m5ControllerConnected
        return (connected ? (m5ControllerPreviewInfo ?? fallback) : fallback,
                connected, connected && m5ControllerHIDSecured)
    }

    /// A read-only presentation path: no new connections, sessions, sampling, selection or pushes.
    /// Reuses the menu's detached renderers; a computer rendition is never called a device screenshot.
    @MainActor func controlCenterPreview(for device: ManagedDevice) -> DeviceControlCenterPreview {
        guard device.isEnabled else { return .init(image: nil, source: .disabled, status: String(localized: "设置已保留，可随时重新启用")) }
        guard DeviceControlCenterPolicy.hasDisplay(device.type) else {
            return .init(image: nil, source: .noDisplay, status: String(localized: "打开设备设置查看连接与功能"))
        }
        let image: NSImage?
        let source: DeviceControlCenterPreview.Source
        switch device.type {
        case .keyboard:
            let mode = activeDeviceID(for: .keyboard) == device.id ? settings.displayMode : (device.settings.displayMode ?? .canvas)
            image = try? menuBarPreview(for: .card(device.id, mode)); source = .localRender
        case .oracle:
            let boards = visibleOracleCanvasBoards(for: device.id)
            let current = boards.first { isCurrentOracleCanvasBoard(deviceID: device.id, boardID: $0.id) } ?? boards.first
            image = current.flatMap { try? menuBarPreview(for: .board(device.id, $0.id)) }; source = .localRender
        case .excerpt:
            let boards = visibleExcerptCanvasBoards(for: device.id)
            let current = boards.first { isCurrentExcerptCanvasBoard(deviceID: device.id, boardID: $0.id) } ?? boards.first
            image = current.flatMap { try? menuBarPreview(for: .board(device.id, $0.id)) }; source = .localRender
        case .aiMacScreen:
            image = aiMacScreenPreviews[device.id]; source = .localRender
        case .c6Screen:
            image = aiMacScreenPreviews[device.id]
            source = c6OfflineSimulationIDs.contains(device.id) ? .deviceFrame : .localRender
        case .awtrix:
            image = awtrixLivePreviewImages[device.id]; source = .deviceFrame
        case .m5Controller:
            let state = m5ScreenPreviewState(for: device.id)
            let renderer = ImageRenderer(content: M5ControllerScreenPreview(
                info: state.info, connected: state.connected, secured: state.secured
            ).frame(width: 135, height: 240))
            renderer.scale = 2
            image = renderer.nsImage; source = .localRender
        case .readPico:
            image = existingReadPicoBoardFrame(for: device.id)?.preview; source = .localRender
        default: image = nil; source = .unavailable
        }
        return .init(image: image, source: image == nil ? .unavailable : source,
                     status: image == nil ? String(localized: "打开设备后可查看可用预览") : String(localized: "点击进入设备详情"))
    }
}
