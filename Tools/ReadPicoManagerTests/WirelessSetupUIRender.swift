import AppKit
import Foundation
import SwiftUI
import LinxDisplayCore

private actor WirelessPanelDevice: ReadPicoManagerDeviceClient {
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data(#"{"config":{"enabled":false,"local":"","external":"","home_wifi":"","external_enabled":false,"external_control":false,"has_token":false},"saved_wifi":[],"network_online":true}"#.utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data(#"{"protocol":1,"canvas":{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4],"state":"displayed","revision":1}}"#.utf8))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
}

@main struct WirelessSetupUIRender {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        var shots = [String]()
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [440.0, 740.0] {
                for scene in ["idle", "wifi-connected", "select-network", "scanning", "password-error", "usb-busy"] {
                    let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in WirelessPanelDevice() })
                    let drafts = ReadPicoDraftGuard(model: manager)
                    if scene == "wifi-connected" {
                        manager.connect(address: "http://pico-preview.invalid/manage#key=" + String(repeating: "a", count: 32), key: "")
                        while manager.busy { try await Task.sleep(nanoseconds: 1_000_000) }
                    }
                    manager.seedWirelessUIFixture(scene)
                    let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = app.appearance
                    let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                        Text("连接 Pico").font(.title2.weight(.semibold))
                        ReadPicoUSBConnectionPanel(drafts: drafts, forBoard: true)
                        Divider()
                        Text("图片与组件可以继续编辑，发送时会优先使用局域网。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(20).frame(width: width, height: 460).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                    window.contentView = content; content.frame = .init(x: 0, y: 0, width: width, height: 460); window.orderFront(nil)
                    for _ in 0..<12 { try await Task.sleep(nanoseconds: 25_000_000) }
                    precondition(content.bounds.width == width && content.bounds.height == 460)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    let name = "wireless-\(scene)-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name)); shots.append(name)
                    window.close(); manager.busy = false; drafts.deactivate()
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["result":"PASS", "screens":shots, "physical_device_accessed":false, "user_configuration_modified":false, "network_accessed":false], options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("PASS rendered \(shots.count) current-source native wireless connection scenes")
    }
}
