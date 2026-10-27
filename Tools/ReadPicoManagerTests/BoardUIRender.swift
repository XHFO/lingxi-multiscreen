import AppKit
import SwiftUI
import Foundation
import LinxDisplayCore
import LinxDisplayApp

private actor BoardUIWiFiDevice: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":false},"saved_wifi":[],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4],"state":"displayed","revision":1},"content":{"supported":true,"max_bytes":268435456,"max_page_items":64}}"#.utf8))
    }
    func scan() async throws -> [ReadPicoCardFile] { [] }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}

@MainActor private func boardScrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(boardScrollViews)
}
@MainActor private func boardScreenshot(_ view: NSView, name: String, output: URL) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor private func renderBoard() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pico-board-ui-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let model = AppModel(store: SettingsStore(dataDirectory: temporary), startBackgroundServices: false)
    precondition(!model.backgroundServicesEnabled && model.settings.devices.isEmpty)
    let id = model.addDevice(type: .readPico)
    var shots = [String]()
    for dark in [false, true] {
      NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      for size in [(660.0, 540.0), (1040.0, 760.0)] {
       for mode in ["components", "image", "usb-progress", "wifi-connected", "wifi-options", "wifi-scanning", "wifi-network-choice", "wifi-password-error"] {
        let device = BoardUIWiFiDevice()
        let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in device })
        if mode == "wifi-connected" {
            manager.connect(address: "http://pico-preview.invalid/manage#key=" + String(repeating: "0", count: 32), key: "")
            for _ in 0..<1000 { if !manager.busy { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(manager.usesWirelessContent && !manager.prefersUSBBoard)
        }
        if ["wifi-network-choice", "wifi-password-error"].contains(mode) {
            manager.provisioningPhase = mode == "wifi-password-error" ? .failed : .selectNetwork
            manager.wirelessNetworks = [.init(ssid: "家中 Wi-Fi", rssi: -43, requiresPassword: true, supported: true)]
            manager.wirelessStatus = mode == "wifi-password-error" ? "Pico 未能连接网络，请核对密码后重试。" : "Pico 尚未连接 Wi-Fi，请选择网络。"
            manager.wirelessError = mode == "wifi-password-error"
        } else if mode == "wifi-scanning" {
            manager.provisioningPhase = .scanning
            manager.wirelessStatus = "正在扫描 Pico 周围的 Wi-Fi 网络…"
        }
        let drafts = ReadPicoDraftGuard(model: manager)
        drafts.canvas.initializeBoardIfNeeded(.init(), landscape: false)
        drafts.canvas.board.name = "阅读桌面"
        drafts.canvas.board.modules = [0, 1]
        drafts.canvas.board.text = "把正在阅读的内容、时钟和信息放到小纸上。"
        drafts.canvas.canvasMode = mode == "image" ? 0 : 2
        if mode == "image" {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 684, pixelsHigh: 1216,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
            do {
                let rect = NSRect(x: 0, y: 0, width: 684, height: 1216)
                NSColor.white.setFill(); rect.fill()
                for index in 0..<16 {
                    NSColor(calibratedWhite: CGFloat(index) / 15, alpha: 1).setFill()
                    NSRect(x: 60 + CGFloat(index % 4) * 144, y: 300 + CGFloat(index / 4) * 144, width: 120, height: 120).fill()
                }
                let text = "灵犀画板\n16 级灰阶" as NSString
                text.draw(at: NSPoint(x: 64, y: 980), withAttributes: [.font: NSFont.systemFont(ofSize: 48, weight: .medium), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 684, height: 1216))
            image.addRepresentation(bitmap)
            drafts.canvas.image = image
            precondition(drafts.canvas.image?.representations.first?.pixelsWide == 684)
            let rendered = try ReadPicoLingxiBoardRenderer.render(draft: drafts.canvas, model: model)
            precondition(rendered.width == 684 && rendered.height == 1216 && rendered.bitmap[28] == 4)
            if !dark && size.0 == 660 {
                let artifacts = output.appendingPathComponent("image-fixture")
                try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
                try rendered.bitmap.write(to: artifacts.appendingPathComponent("image-native-gray16.bmp"))
                try NSBitmapImageRep(data: rendered.preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                    .write(to: artifacts.appendingPathComponent("image-native-gray16.png"))
            }
        }
        manager.acceptPowerStatus(.init(known: true, charging: true, batteryPercent: 72, revision: 1, externalPower: true))
        if mode == "usb-progress" {
            manager.busy = true
            manager.usbBoardProgress = .init("正在传输灵犀画板 184 KB / 418 KB…", fraction: 0.44)
            manager.message = "正在传输灵犀画板 184 KB / 418 KB…"
        }
        var board = ReadPicoLingxiBoardView(model: model, deviceID: id, drafts: drafts)
        board = board.seedSelectionForRendering(1, delivery: !["components", "image"].contains(mode))
        let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: size.0, height: size.1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
        let content = NSHostingView(rootView: board.environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = content; content.frame = .init(x: 0, y: 0, width: size.0, height: size.1); window.orderFront(nil)
        for _ in 0..<15 { try await Task.sleep(nanoseconds: 25_000_000) }
        if mode == "wifi-options" {
            // Use the independent board route; file-management routing stays unchanged.
            manager.boardTransportPreference = .wifi
            try await Task.sleep(nanoseconds: 160_000_000)
        }
        let name = "board-\(mode)-\(dark ? "dark" : "light")-\(Int(size.0))x\(Int(size.1))"
        try boardScreenshot(content, name: name, output: output); shots.append(name)
        if let scroll = boardScrollViews(content).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
           let document = scroll.documentView {
            let distance = max(0, document.bounds.height - scroll.contentSize.height)
            if distance > 0 {
                if size.0 == 660 && !["components", "image"].contains(mode) {
                    document.scroll(.init(x: 0, y: document.isFlipped ? distance * 0.5 : distance * 0.5)); scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    try boardScreenshot(content, name: name + "-middle", output: output); shots.append(name + "-middle")
                }
                document.scroll(.init(x: 0, y: document.isFlipped ? distance : 0)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 80_000_000)
                try boardScreenshot(content, name: name + "-bottom", output: output); shots.append(name + "-bottom")
            }
        }
        manager.busy = false; window.close(); drafts.deactivate()
       }
      }
    }
    try JSONSerialization.data(withJSONObject: ["result":"PASS", "screens":shots,"image_fixture":"bitmap-backed 684x1216 source; production render accepted; real 4bit output saved", "physical_device_accessed":false,"user_configuration_modified":false,"background_services":false], options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    print("PASS rendered \(shots.count) native Board screens with components / image / USB progress / Wi-Fi connection and scrolled inspectors")
}
@MainActor @_cdecl("readpico_board_ui_render_main")
func boardUIRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in
        do { try await renderBoard(); exit(0) } catch { print("Board render failed: \(error)"); exit(1) }
    }
    app.run(); return 0
}
