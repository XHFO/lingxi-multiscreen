import AppKit
import SwiftUI
import LinxDisplayCore

/// 中文：渲染真实SwiftUI视图，连接状态为固定夹具，不接触设备或用户配置。
/// English: Render the real SwiftUI views with fixture connection states and no device/user-configuration access.
@MainActor final class ReadPicoManagerModel: ObservableObject {
    @Published var busy = false
    @Published var store: String?
    @Published var connection: ReadPicoConnection?
    @Published var usbPorts = ["/dev/cu.usbmodem1401"]
}
@main struct WorkspacePreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000117")!
        let session = ReadPicoDesktopConsoleSession.session(for: id.uuidString)
        session.shortcuts = [
            .init(label: "计算器", application: "/System/Applications/Calculator.app", screen: 0),
            .init(label: "Safari", application: "/Applications/Safari.app", screen: 0),
            .init(label: "备忘录", application: "/System/Applications/Notes.app", screen: 0),
            .init(label: "终端", application: "/System/Applications/Utilities/Terminal.app", screen: 0),
            .init(label: "日历", application: "/System/Applications/Calendar.app", screen: 1),
            .init(label: "音乐", application: "/System/Applications/Music.app", screen: 1),
            .init(label: "照片", application: "/System/Applications/Photos.app", screen: 1),
            .init(label: "预览", application: "/System/Applications/Preview.app", screen: 1)
        ]
        session.selectedPort = "/dev/cu.usbmodem1401"; session.previewState()
        let manager = ReadPicoManagerModel()
        let state = try JSONDecoder().decode(ReadPicoWorkspace.Reply.self, from: Data("{\"workspace\":true,\"ok\":true,\"protocol\":1,\"paired\":true,\"connected\":true,\"reading\":false,\"role\":1,\"mode\":2,\"state\":5,\"peer_state\":5,\"done\":14224,\"total\":14224,\"revision\":117}".utf8))
        session.workspace.accept(state); session.workspace.mode = .console
        func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat, dark: Bool = false) throws {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("No bitmap") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        session.rotated = true
        try capture(ReadPicoDesktopConsoleView(manager: manager, deviceID: id), "console-landscape", width: 1180, height: 1120)
        session.rotated = false
        try capture(ReadPicoDesktopConsoleView(manager: manager, deviceID: id), "console-portrait", width: 1180, height: 1300)
        session.rotated = true
        try capture(ReadPicoDesktopConsoleView(manager: manager, deviceID: id), "console-compact", width: 760, height: 1600)
        try capture(ReadPicoDesktopConsoleView(manager: manager, deviceID: id), "console-dark", width: 1180, height: 1120, dark: true)
        session.workspace.mode = .board
        try capture(ReadPicoWorkspacePanel(session: session.workspace, manager: manager, port: session.selectedPort).padding(24), "board-pair-settings", width: 760, height: 300)
        let waiting = try JSONDecoder().decode(ReadPicoWorkspace.Reply.self, from: Data("{\"workspace\":true,\"ok\":true,\"protocol\":1,\"paired\":true,\"connected\":false,\"reading\":false,\"role\":1,\"mode\":0,\"state\":1}".utf8))
        session.workspace.mode = .independent; session.workspace.accept(waiting)
        try capture(ReadPicoWorkspacePanel(session: session.workspace, manager: manager, port: session.selectedPort).padding(24), "pair-waiting", width: 760, height: 300)
        print("PASS: actual SwiftUI snapshots, wide/compact, portrait/landscape, light/dark and paired-board controls; fixture data, no hardware")
    }
}
