import AppKit
import Foundation
import LinxDisplayCore
import LinxDisplayApp
import SwiftUI

private actor LockScreenRenderClient: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot { try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":false},"saved_wifi":[],"network_online":true}"#.utf8)) }
    func capabilities() async throws -> ReadPicoCapabilities { try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":430000,"gray_levels":16,"bit_depths":[1,4],"state":"idle","revision":1},"config":{"auto_sleep_minutes":3,"double_tap_wake":true,"lock_style":0,"state":0,"revision":1},"image_lock":{"supported":true,"available":true,"state":"saved","revision":1,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4]}}"#.utf8)) }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}
private func sampleImage() -> CGImage {
    let width = 800, height = 1000
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<height { c.setFillColor(CGColor(red: 0.8 - Double(y) / 1800, green: 0.86 - Double(y) / 2400, blue: 0.92 - Double(y) / 4000, alpha: 1)); c.fill(CGRect(x: 0, y: y, width: width, height: 1)) }
    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillEllipse(in: CGRect(x: 500, y: 650, width: 170, height: 170))
    for (start, color) in [(220, 0.65), (60, 0.35), (-120, 0.12)] {
        c.setFillColor(CGColor(gray: color, alpha: 1)); c.beginPath(); c.move(to: CGPoint(x: 0, y: 0)); c.addLine(to: CGPoint(x: 0, y: start + 300)); c.addLine(to: CGPoint(x: 180, y: start + 450)); c.addLine(to: CGPoint(x: 360, y: start + 280)); c.addLine(to: CGPoint(x: 570, y: start + 520)); c.addLine(to: CGPoint(x: 800, y: start + 310)); c.addLine(to: CGPoint(x: 800, y: 0)); c.closePath(); c.fillPath()
    }
    return c.makeImage()!
}
@MainActor private func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
@MainActor private func capture(_ view: NSView, name: String, output: URL) throws {
    view.layoutSubtreeIfNeeded(); let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor private func renderLockScreens() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let image = sampleImage(); var shots = [String]()
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for size in [(660.0, 540.0), (1100.0, 820.0)] {
            for landscape in [false, true] {
                for mode in ["native-gray16", "diffusion", "bayer", "ascii"] {
                    let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in LockScreenRenderClient() })
                    manager.connect(address: "http://reader.local/manage#key=" + String(repeating: "a", count: 32), key: "")
                    while manager.busy { try await Task.sleep(nanoseconds: 10_000_000) }
                    let drafts = ReadPicoDraftGuard(model: manager)
                    let editor = drafts.lockScreen
                    editor.configureOutputCapability(manager.imageLock?.supportsNativeGray16)
                    editor.configureRenderer { try ReadPicoLockScreenRenderer.render($0, options: $1) }
                    try editor.setImage(image, name: "山间月色.png")
                    var options = editor.options; options.landscape = landscape; options.layout = .fill
                    options.output = ["diffusion", "bayer"].contains(mode) ? .monochrome : .gray16
                    if mode == "ascii" { options.mode = .ascii; options.asciiCellSize = 12 }
                    if mode == "bayer" { options.dither = .ordered }
                    editor.updateOptions(options)
                    while editor.rendering { try await Task.sleep(nanoseconds: 10_000_000) }
                    precondition(editor.bitmap != nil && editor.bitmap == manager.pendingLockImage && editor.error == nil)
                    precondition(editor.bitmap![28] == (options.output == .gray16 ? 4 : 1))
                    let name = "\(mode)-\(landscape ? "landscape" : "portrait")-\(dark ? "dark" : "light")-\(Int(size.0))x\(Int(size.1))"
                    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.0, height: size.1), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
                    let content = NSHostingView(rootView: ReadPicoLockScreenView(drafts: drafts).environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = content; content.frame = NSRect(x: 0, y: 0, width: size.0, height: size.1); window.orderFront(nil)
                    for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000) }
                    try capture(content, name: name, output: output); shots.append(name)
                    if let scroll = scrollViews(content).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }), let document = scroll.documentView {
                        let distance = max(0, document.bounds.height - scroll.contentSize.height)
                        document.scroll(NSPoint(x: 0, y: document.isFlipped ? distance : 0)); scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(nanoseconds: 60_000_000)
                        try capture(content, name: name + "-bottom", output: output); shots.append(name + "-bottom")
                    }
                    try editor.bitmap!.write(to: output.appendingPathComponent(name + ".bmp"))
                    window.close(); manager.deactivate()
                }
            }
        }
    }
    try JSONSerialization.data(withJSONObject: ["result":"PASS", "screens":shots, "count":shots.count, "native_gray16_and_legacy_binary":true, "actual_wire_preview":true, "physical_device_accessed":false, "user_configuration_modified":false], options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    print("PASS \(shots.count) native lock-screen editor screens")
}
@MainActor @_cdecl("readpico_lock_screen_editor_render_main")
func lockScreenEditorRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in do { try await renderLockScreens(); exit(0) } catch { print(error); exit(1) } }
    app.run(); return 0
}
