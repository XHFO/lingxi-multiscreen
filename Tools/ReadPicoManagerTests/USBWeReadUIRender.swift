import AppKit
import Foundation
import LinxDisplayApp
import LinxDisplayCore
import SwiftUI

// Passive rendering of actual production SwiftUI components. Every discovery
// closure is synthetic; account/network/serial/eject actions are never invoked.
private final class DiscoveryFixture: @unchecked Sendable {
    let volumes: [ReadPicoMountedVolume]
    private let lock = NSLock()
    private var serialScans = 0, metadataReads = 0
    init(count: Int) {
        volumes = (0..<count).map { index in
            .init(rootURL: URL(fileURLWithPath: "/offline-ui-fixture/tf-\(index)"), name: index == 0 ? "NO NAME" : "阅读器 TF 卡",
                  capacity: 62_599_954_944, free: 48_000_000_000, readOnly: false,
                  hasPicoFolders: false, identity: "OFFLINE-UUID-\(index)")
        }
    }
    func ports() -> [ESPSerialPort] { lock.withLock { serialScans += 1 }; return [] }
    func descriptor(_ root: URL) -> ReadPicoFirmwareUSBRecovery.USBDescriptor? {
        lock.withLock { metadataReads += 1 }
        guard let index = volumes.firstIndex(where: { $0.rootURL == root }) else { return nil }
        return .init(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: index == 0 ? "14C19FD14CE4" : "AABBCCDDEEFF")
    }
    func recovery() -> ReadPicoFirmwareUSBRecovery {
        .init(environment: .init(volumes: { self.volumes }, descriptor: { self.descriptor($0) }, ports: { [] },
                                 serialIdentity: { _ in nil }, eject: { _ in fatalError("UI render must not eject storage") },
                                 wait: { fatalError("UI render must not recover a serial connection") }))
    }
    func counts() -> [String: Int] { lock.withLock { ["injected_serial_scans": serialScans, "injected_metadata_reads": metadataReads] } }
}
@MainActor private func isolatedManager() -> ReadPicoManagerModel {
    .init(usbClient: .init { _, _ in fatalError("UI render must not request USB handoff") },
          discoverVolumes: { [] }, discoverUSBPorts: { [] }, identifyUSBPort: { _ in nil },
          ejectVolume: { _ in fatalError("UI render must not eject storage") },
          volumeUSBIdentity: { _ in nil }, readUSBPower: { _ in nil },
          makeClient: { _ in fatalError("UI render must not create an HTTP client") })
}
@MainActor private func scrolls(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
}
@MainActor private func screenshot(_ view: NSView, name: String, output: URL) throws {
    view.layoutSubtreeIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No native view bitmap") }
    view.cacheDisplay(in: view.bounds, to: image)
    guard let png = image.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor private func runUIRender() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let first = ReadPicoWeReadBook(id: "fixture-walden", title: "瓦尔登湖：在日常阅读中留下清晰而有序的个人思考", author: "亨利·戴维·梭罗")
    let second = ReadPicoWeReadBook(id: "fixture-time", title: "A Brief History of Time — An Illustrated Reading Journal", author: "Stephen Hawking")
    let third = ReadPicoWeReadBook(id: "fixture-reading", title: "阅读与设计：让信息回到恰当的位置", author: "离线测试作者")
    let books = [first, second, third]
    let snapshot = ReadPicoWeReadSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000), books: [
        .init(book: first, notes: [
            .init(id: "h:one", kind: .highlight, chapter: "第一章 · 阅读与生活", quote: "留下一点安静的时间，让阅读成为日常的一部分。"),
            .init(id: "t:two", kind: .thought, chapter: "第二章 · 个人思考", quote: "重要的内容值得反复阅读。", text: "这段文字提醒我：工具应该减少操作，让人专注于内容本身。")]),
        .init(book: second, notes: [.init(id: "h:three", kind: .highlight, chapter: "Chapter 1 · Our Picture of the Universe", quote: "An offline sample excerpt for checking text layout and readable spacing.")])
    ])
    var captures: [String] = [], geometry: [[String: Any]] = [], discovery: [[String: Int]] = []
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for width in [400.0, 920.0] {
            for scene in ["firmware-empty", "firmware-msc", "firmware-multiple", "weread-empty", "weread-preview"] {
                let manager = isolatedManager()
                let fixture = DiscoveryFixture(count: scene == "firmware-msc" ? 1 : scene == "firmware-multiple" ? 2 : 0)
                let content: AnyView
                if scene.hasPrefix("firmware") {
                    content = AnyView(ReadPicoFirmwareView(discoverSerialPorts: { fixture.ports() }, usbRecovery: fixture.recovery()))
                } else {
                    if scene == "weread-preview" {
                        manager.files = [.init(relativePath: "apps/tools/weread.pga", title: "微信读书 · 书架与笔记", kind: .application, bytes: 32_768)]
                    }
                    content = AnyView(ReadPicoWeReadView(model: manager, initialExpanded: true,
                        initialBooks: scene == "weread-preview" ? books : [],
                        initialSelection: scene == "weread-preview" ? [first.id, second.id] : [],
                        initialPreview: scene == "weread-preview" ? snapshot : nil,
                        initialMessage: scene == "weread-preview" ? "已准备 2 本书、3 条笔记。核对后同步到 Pico。" : nil))
                }
                let height = 760.0
                let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: width, height: height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
                let host = NSHostingView(rootView: ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: height); window.orderFront(nil)
                try await Task.sleep(nanoseconds: 240_000_000)
                precondition(host.bounds.width == width && host.bounds.height == height)
                let name = "\(scene)-\(Int(width))-\(dark ? "dark" : "light")"
                try screenshot(host, name: name, output: output); captures.append(name)
                let nativeScrolls = scrolls(host)
                for scroll in nativeScrolls {
                    guard let document = scroll.documentView else { continue }
                    geometry.append(["screen": name, "viewport_width": scroll.contentSize.width,
                                     "document_width": document.bounds.width, "viewport_height": scroll.contentSize.height,
                                     "document_height": document.bounds.height])
                    precondition(document.bounds.width <= scroll.contentSize.width + 1, "Unexpected horizontal overflow: \(name)")
                }
                // Scroll only the outer workspace viewport. Inner book/notes
                // previews retain their initial position for a meaningful bottom shot.
                if let outer = nativeScrolls.first, let document = outer.documentView {
                    let distance = max(0, document.bounds.height - outer.contentSize.height)
                    document.scroll(.init(x: 0, y: document.isFlipped ? distance : 0)); outer.reflectScrolledClipView(outer.contentView)
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
                try screenshot(host, name: name + "-bottom", output: output); captures.append(name + "-bottom")
                if scene.hasPrefix("firmware") { precondition(fixture.counts()["injected_serial_scans", default: 0] > 0) }
                discovery.append(fixture.counts())
                window.close(); manager.deactivate()
            }
        }
    }
    let report: [String: Any] = ["result": "PASS", "screens": captures, "scroll_geometry": geometry,
        "fixture_discovery": discovery, "physical_device_accessed": false, "user_configuration_modified": false,
        "external_network": false, "keychain_accessed": false,
        "scope": "Actual Debug SwiftUI FirmwareView and WeReadView; injected synthetic discovery and preloaded pure data. Passive rendering only; account, USB, eject and sync actions are never invoked."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    print("PASS: \(captures.count) actual native UI screenshots; light/dark, 400/920 points, no horizontal scroll overflow; no hardware, network, Keychain or user configuration.")
}
@MainActor @_cdecl("readpico_usb_weread_render_main")
func usbWeReadRenderMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    Task { @MainActor in do { try await runUIRender(); exit(0) } catch { print(error); exit(1) } }
    app.run(); return 0
}
