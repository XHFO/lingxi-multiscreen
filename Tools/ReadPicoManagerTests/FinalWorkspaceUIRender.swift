import AppKit
import Foundation
import LinxDisplayApp
import LinxDisplayCore
import SwiftUI

// 真实 Debug UI 的离线承载；所有模型、资料库与设备发现均隔离，不调用用户 App 或连接真实硬件。
// Host actual Debug UI offline; isolate settings, libraries and discovery without launching the user App or hardware.
private actor FinalUIDevice: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":false},"saved_wifi":[],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4],"state":"displayed","revision":1},"config":{"auto_sleep_minutes":3,"double_tap_wake":true,"lock_style":2,"cover_layout":3,"state":2,"revision":1},"image_lock":{"supported":true,"available":false,"state":"idle","revision":1,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4]}}"#.utf8))
    }
    func scan() async throws -> [ReadPicoCardFile] { [] }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}

@MainActor private func scrolls(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
}
@MainActor private func capture(_ view: NSView, _ name: String, _ output: URL) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor private func renderFinalWorkspace() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pico-final-ui-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let model = AppModel(store: SettingsStore(dataDirectory: temporary), startBackgroundServices: false)
    precondition(!model.backgroundServicesEnabled && model.settings.devices.isEmpty)
    let id = model.addDevice(type: .readPico)
    var shots = [String]()
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for mode in ["empty", "configured"] {
            model.settings.cloudflare = .init()
            if mode == "configured" {
                model.settings.cloudflare.zoneID = String(repeating: "a", count: 32)
                model.settings.cloudflare.zoneName = "小纸 Pico 与多屏灵犀的网站统计演示站点"
                model.settings.cloudflare.hostname = "reader-preview.example.invalid"
                model.settings.cloudflare.period = .week
                model.cloudflareStatus = "离线 UI 检查，仅显示合成配置，未请求 Cloudflare。"
            } else { model.cloudflareStatus = "" }
            for style in ["sheet", "narrow-form", "wide-form"] {
                let width = style == "sheet" ? 480.0 : style == "narrow-form" ? 360.0 : 660.0
                let height = style == "sheet" ? 520.0 : 620.0
                let content: AnyView = style == "sheet"
                    ? AnyView(ReadPicoSharedModuleSettingsView(model: model, module: .cloudflare))
                    : AnyView(Form { Section("网站统计") { CloudflareAnalyticsSettingsView(model: model) } }.formStyle(.grouped))
                let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
                let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: height); window.orderFront(nil)
                try await Task.sleep(nanoseconds: 220_000_000)
                precondition(host.bounds.width == width && host.bounds.height == height)
                let name = "cloudflare-\(mode)-\(style)-\(dark ? "dark" : "light")"
                try capture(host, name, output); shots.append(name)
                for scroll in scrolls(host) {
                    guard let document = scroll.documentView else { continue }
                    let distance = max(0, document.bounds.height-scroll.contentSize.height)
                    if distance > 0 { document.scroll(.init(x: 0, y: document.isFlipped ? distance : 0)); scroll.reflectScrolledClipView(scroll.contentView) }
                }
                try await Task.sleep(nanoseconds: 80_000_000)
                try capture(host, name+"-bottom", output); shots.append(name+"-bottom")
                window.close()
            }
        }
        for size in [(900.0, 640.0), (1280.0, 820.0)] {
            let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in FinalUIDevice() })
            let drafts = ReadPicoDraftGuard(model: manager)
            drafts.canvas.initializeBoardIfNeeded(.init(), landscape: false)
            drafts.canvas.board.name = "阅读与网站统计"
            drafts.canvas.board.modules = [CanvasModule.clock.rawValue, CanvasModule.cloudflare.rawValue]
            drafts.canvas.canvasMode = 2
            manager.acceptPowerStatus(.init(known: true, charging: true, batteryPercent: 72, revision: 1, externalPower: true))
            let sidebar = Sidebar(selection: .constant(.readPicoInformation), awtrixAppRoute: .constant(nil), model: model)
            let board = ReadPicoLingxiBoardView(model: model, deviceID: id, drafts: drafts)
            let content = HStack(spacing: 0) { sidebar.frame(width: 200); Divider(); board.frame(maxWidth: .infinity, maxHeight: .infinity) }
            let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: size.0, height: size.1), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
            let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host; host.frame = .init(x: 0, y: 0, width: size.0, height: size.1); window.orderFront(nil)
            try await Task.sleep(nanoseconds: 350_000_000)
            // Exercise the actual isolated Sidebar disclosure without modifying private State.
            let localPoint = NSPoint(x: 90, y: size.1 - 56)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: localPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 180_000_000)
            let name = "sidebar-board-\(Int(size.0))x\(Int(size.1))-\(dark ? "dark" : "light")"
            try capture(host, name, output); shots.append(name)
            window.close(); drafts.deactivate()
        }
    }
    let report: [String: Any] = ["result": "PASS", "screens": shots, "physical_device_accessed": false,
        "user_configuration_modified": false, "background_services": false, "external_network": false,
        "credential_scope": "new random fixture credential IDs; no secret write or real-account action",
        "scope": "Actual Debug Sidebar, BoardView, Cloudflare settings and shared-module sheet; isolated temporary AppModel"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    print("PASS \(shots.count) final workspace native screenshots")
}

@MainActor @_cdecl("readpico_final_workspace_render_main")
func finalWorkspaceRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in do { try await renderFinalWorkspace(); exit(0) } catch { print(error); exit(1) } }
    app.run(); return 0
}
