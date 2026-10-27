import AppKit
import SwiftUI
import Foundation
import LinxDisplayCore

private actor FixtureClient: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":true,"local":"http://homeassistant.local:8123","external":"https://home.example.invalid","home_wifi":"家中无线网络","external_enabled":true,"external_control":false,"has_token":true},"saved_wifi":["家中无线网络"],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"content":{"supported":true,"max_bytes":268435456,"max_page_items":64},"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":110000,"state":"idle","revision":1},"config":{"auto_sleep_minutes":3,"double_tap_wake":true,"state":0,"revision":1}}"#.utf8))
    }
    func scan() async throws -> [ReadPicoCardFile] {
        [.init(relativePath: "books/无线同步图书.txt", title: "无线同步图书", kind: .book, bytes: 18000, detail: "TXT · 保存在 Pico TF 卡"),
         .init(relativePath: "apps/games/snake.pga", title: "贪吃蛇", kind: .application, bytes: 19000, detail: "独立游戏包")]
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities {
        try await Task.sleep(nanoseconds: 60_000_000_000); return try await capabilities()
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}
private final class VolumeFixture: @unchecked Sendable {
    var volumes: [ReadPicoMountedVolume] = []
    var ports: [String] = []
}

@main struct ReadPicoRender {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 || arguments.count == 7 else { fatalError("section appearance output.png [width height fixture]") }
        let width = arguments.count == 7 ? Double(arguments[4])! : 900
        let height = arguments.count == 7 ? Double(arguments[5])! : 720
        let fixture = arguments.count == 7 ? arguments[6] : "empty"
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: arguments[2] == "dark" ? .darkAqua : .aqua)
        let volumeFixture = VolumeFixture()
        let model = ReadPicoManagerModel(usbClient: .init { _, _ in .init() },
                                        discoverVolumes: { volumeFixture.volumes }, discoverUSBPorts: { volumeFixture.ports },
                                        identifyUSBPort: { _ in "offline-render" }, makeClient: { _ in FixtureClient() })
        let drafts = ReadPicoDraftGuard(model: model)
        let address = ["connected", "busy", "dirty", "canvas-dirty", "departure", "wireless"].contains(fixture) ? "http://reader.local/manage#key=" + String(repeating: "a", count: 32) : ""
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pico-render-library-" + UUID().uuidString)
        let local = ReadPicoLocalLibraryModel(library: try ReadPicoLocalLibrary(rootURL: libraryRoot))
        var temporary: URL?
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) }; model.deactivate() }
        if !address.isEmpty {
            model.connect(address: address, key: "")
            while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            if fixture == "busy" { model.saveDeviceSettings() }
            if fixture == "dirty" || fixture == "departure" { model.home.local = "http://changed-home.local:8123" }
            if fixture == "canvas-dirty" {
                drafts.canvas.canvasMode = 1
                drafts.canvas.strokes = [[CGPoint(x: 0.15, y: 0.25), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.45, y: 0.7)]]
            }
        } else if fixture == "long-files" || fixture == "tf-mounted" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-render-" + UUID().uuidString)
            temporary = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("第一章 正文".utf8).write(to: directory.appendingPathComponent(String(repeating: "书名较长的阅读测试", count: 7) + ".txt"))
            model.selectCard(directory)
            while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            volumeFixture.volumes = [.init(rootURL: directory, name: "小纸 TF", capacity: 32_000_000_000, free: 28_800_000_000,
                                          readOnly: false, hasPicoFolders: true, identity: "offline-render-card")]
            await model.refreshCardAvailability()
        } else if fixture == "usb-waiting" {
            volumeFixture.ports = ["/dev/cu.usbmodem-offline-render"]
            await model.refreshCardAvailability()
            model.startUSB(port: volumeFixture.ports[0])
            while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            await model.refreshCardAvailability(now: Date().addingTimeInterval(31))
        } else if fixture == "local-library" {
            // Exercise actual local imports/thumbnail creation, with no user library access.
            let inputs = libraryRoot.appendingPathComponent("fixture-inputs", isDirectory: true)
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            let kind: ReadPicoLibraryKind
            let urls: [URL]
            switch arguments[1] {
            case "fonts":
                kind = .font
                urls = [URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"),
                        URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Bold.ttf")]
            case "notes":
                kind = .note
                let first = inputs.appendingPathComponent("阅读与生活.md")
                let second = inputs.appendingPathComponent("随手记.txt")
                try Data("# 阅读与生活\n\n慢慢阅读，把想法留在纸上。\n\n- 勾选需要同步到 Pico 的笔记\n- 原稿保留在此 Mac\n".utf8).write(to: first)
                try Data("今日随手记\n下次继续读完这一章，整理其中的思考。".utf8).write(to: second)
                urls = [first, second]
            default:
                kind = .book
                let first = inputs.appendingPathComponent("慢读札记.txt")
                let second = inputs.appendingPathComponent("山水之间.txt")
                try Data("慢读札记\n\n第一章 在日常中阅读\n\n窗外的树影落在书页上。阅读不必匆忙，我们可以留一点时间，记下自己的想法。\n\n导入后先在 Mac 查看内容，勾选所需图书，再同步到随身的 Pico。".utf8).write(to: first)
                try Data("山水之间\n\n沿着山间小路向前，远处的风景渐渐清晰。\n\n没有勾选的图书仍保存在 Mac 本地资料库。".utf8).write(to: second)
                urls = [first, second]
            }
            local.importFiles(urls, kind: kind)
            while local.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            guard !local.isError, local.items.count == 2, local.thumbnails.count == 2,
                  let first = local.items.first else { fatalError("Local library fixture import failed: \(local.message)") }
            local.selected = [first.id]; local.focusedID = first.id
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = app.appearance
        let content = NSHostingView(rootView: ReadPicoManagerView(initialHost: address, initialSection: arguments[1], draftGuard: drafts, libraryModel: local, initialDeviceContents: ["long-files", "tf-mounted", "wireless"].contains(fixture), automaticUSBPreparation: false).modifier(ReadPicoDraftProtection(drafts: drafts)).environment(\.colorScheme, arguments[2] == "dark" ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = content; window.orderFront(nil)
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 25_000_000) }; content.layoutSubtreeIfNeeded()
        if fixture == "departure" {
            drafts.request(title: "关闭设备管理前保存修改？") {}
            for _ in 0..<20 { try await Task.sleep(nanoseconds: 25_000_000) }
            guard let sheet = window.attachedSheet, let prompt = sheet.contentView,
                  let rendered = prompt.bitmapImageRepForCachingDisplay(in: prompt.bounds) else { fatalError("Departure alert was not presented") }
            func labels(_ view: NSView) -> [String] {
                var result: [String] = []
                if let field = view as? NSTextField { result.append(field.stringValue) }
                if let button = view as? NSButton { result.append(button.title) }
                for child in view.subviews { result += labels(child) }
                return result
            }
            let visibleLabels = labels(prompt)
            try JSONSerialization.data(withJSONObject: visibleLabels, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arguments[3]).deletingPathExtension().appendingPathExtension("prompt-labels.json"))
            prompt.cacheDisplay(in: prompt.bounds, to: rendered)
            guard let png = rendered.representation(using: .png, properties: [:]) else { fatalError("No departure PNG") }
            try png.write(to: URL(fileURLWithPath: arguments[3]).deletingPathExtension().appendingPathExtension("prompt.png"))
            drafts.resolve(.cancel)
            for _ in 0..<10 { try await Task.sleep(nanoseconds: 25_000_000) }
            guard !drafts.isHandlingDeparture && model.hasUnsavedDeviceChanges else { fatalError("Alert cancellation lost draft") }
        }
        guard content.bounds.width <= width && content.bounds.height <= height else { fatalError("View exceeded requested window size") }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No snapshot") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: URL(fileURLWithPath: arguments[3])); drafts.deactivate(); window.close()
        print("Rendered \(arguments[1]) \(fixture) \(arguments[2]) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
