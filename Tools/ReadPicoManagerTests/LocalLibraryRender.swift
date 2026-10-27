import AppKit
import SwiftUI
import Foundation
import LinxDisplayCore

private actor LibraryRenderClient: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":true,"local":"http://homeassistant.local:8123","external":"https://home.example.invalid","home_wifi":"家中无线网络","external_enabled":true,"external_control":false,"has_token":true},"saved_wifi":["家中无线网络"],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":430000,"state":"idle","revision":1},"config":{"auto_sleep_minutes":3,"double_tap_wake":true,"lock_style":0,"state":0,"revision":1},"image_lock":{"supported":true,"available":false,"state":"idle","revision":1,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":110000}}"#.utf8))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}

@main struct LocalLibraryRender {
    @MainActor private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    @MainActor private static func snapshot(_ content: NSView, name: String, output: URL) throws -> [String: Any] {
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("no bitmap") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = bitmap.representation(using: .png, properties: [:])!; try png.write(to: output.appendingPathComponent(name + ".png"))
        return ["name":name,"width":content.bounds.width,"height":content.bounds.height,"bytes":png.count]
    }
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-library-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let firmwareResources = Bundle.main.resourceURL!.appendingPathComponent("Firmware/ReadPico")
        let bundledApplications = try ReadPicoBundledApps.load(directory: firmwareResources)
        guard !bundledApplications.isEmpty else { fatalError("native resource fixture has no bundled applications") }
        let resourceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: firmwareResources.appendingPathComponent("manifest.json"))) as! [String: Any]
        let library = try ReadPicoLocalLibrary(rootURL: root.appendingPathComponent("library"))
        let sources = root.appendingPathComponent("sources"); try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for title in ["在时间的河流中阅读", "关于创造、生活与远方的随笔", "长篇文字与字体排版测试"] {
            let url = sources.appendingPathComponent(title + ".txt")
            try Data((title + "\n\n" + String(repeating: "阅读让我们在安静的片刻，看见生活的细微变化。把喜欢的文字放进资料库，预览之后再带到阅读器中。\n\n", count: 80)).utf8).write(to: url)
            _ = try await library.importFile(url, kind: .book)
        }
        let note = sources.appendingPathComponent("我的阅读笔记.md")
        try Data("# 我的阅读笔记\n\n今天读到一句很喜欢的话：阅读是与过去的自己再次相遇。\n\n## 下次继续\n- 第二章\n- 整理摘录\n\n这是一份独立笔记，不覆盖书中的划线与批注。".utf8).write(to: note)
        _ = try await library.importFile(note, kind: .note)
        _ = try await library.importFile(URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"), kind: .font)
        let local = ReadPicoLocalLibraryModel(library: library); await local.reload()
        local.selected = Set(local.items.map(\.id))
        let model = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
        defer { model.deactivate() }
        let drafts = ReadPicoDraftGuard(model: model)
        let card = root.appendingPathComponent("card"); try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let store = try ReadPicoTFStore(rootURL: card)
        _ = try await library.sync(try await library.items(), to: store)
        let mounted = ReadPicoManagerModel(discoverVolumes: { [.init(rootURL: card, name: "小纸 TF · 预览", capacity: 32_000_000_000, free: 28_000_000_000, readOnly: false, hasPicoFolders: true)] }, discoverUSBPorts: { [] })
        mounted.selectCard(card)
        while mounted.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let mountedDrafts = ReadPicoDraftGuard(model: mounted)
        let connected = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in LibraryRenderClient() })
        connected.connect(address: "http://reader.local/manage#key=" + String(repeating:"a", count:32), key: "")
        while connected.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let connectedDrafts = ReadPicoDraftGuard(model: connected)
        defer { mounted.deactivate(); connected.deactivate() }
        var shots: [[String: Any]] = []
        for appearance in ["light", "dark"] {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for size in [(850.0, 720.0), (1200.0, 920.0), (660.0, 540.0)] {
                for section in ["books", "fonts", "notes", "connection", "settings", "apps", "drawings", "device-books", "lockScreen", "firmware"] {
                    let name = "\(section)-\(appearance)-\(Int(size.0))x\(Int(size.1))"
                    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.0, height: size.1), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = app.appearance
                    let view: AnyView
                    switch section {
                    case "lockScreen": view = AnyView(ReadPicoLockScreenView(drafts: connectedDrafts))
                    case "firmware": view = AnyView(ScrollView { ReadPicoFirmwareView().padding(16) })
                    case "settings": view = AnyView(ReadPicoManagerView(initialSection: "connection", draftGuard: connectedDrafts, libraryModel: local, embedded: true, automaticUSBPreparation: false))
                    case "apps", "drawings", "device-books": view = AnyView(ReadPicoManagerView(initialSection: section == "device-books" ? "books" : section, draftGuard: mountedDrafts, libraryModel: local, initialDeviceContents: section == "device-books", embedded: true, automaticUSBPreparation: false))
                    default: view = AnyView(ReadPicoManagerView(initialSection: section, draftGuard: drafts, libraryModel: local, embedded: true, automaticUSBPreparation: false))
                    }
                    let content = NSHostingView(rootView: view
                        .environment(\.colorScheme, appearance == "dark" ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = content; content.frame = NSRect(x: 0, y: 0, width: size.0, height: size.1); window.orderFront(nil)
                    for _ in 0..<12 { try await Task.sleep(nanoseconds: 20_000_000) }
                    content.layoutSubtreeIfNeeded()
                    guard content.bounds.width <= size.0 && content.bounds.height <= size.1 else { fatalError("layout overflow") }
                    shots.append(try snapshot(content, name: name, output: output))
                    if ["apps", "settings", "lockScreen"].contains(section),
                       let scroll = scrollViews(in: content).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                       let document = scroll.documentView {
                        let distance = max(0, document.bounds.height - scroll.contentSize.height)
                        document.scroll(NSPoint(x: 0, y: document.isFlipped ? distance : 0)); scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(nanoseconds: 60_000_000)
                        shots.append(try snapshot(content, name: name + "-bottom", output: output))
                    }
                    window.close()
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["result":"PASS","shots":shots,"physical_device_accessed":false,"user_configuration_modified":false,
            "firmware_resource_path":firmwareResources.path,"firmware_resource_version":resourceManifest["version"] ?? "unknown","bundled_applications_loaded":bundledApplications.count], options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("PASS rendered \(shots.count) native library/settings screens")
    }
}
