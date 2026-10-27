import AppKit
import SwiftUI
import LinxDisplayCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum UIAuditCapture {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--ui-audit-dir"), args.index(after: idx) < args.endIndex else { return }
        let dir = args[args.index(after: idx)]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        dumpHomeLinkHA(dir: dir, thin: true, name: "readpico-ha-cf-access-thin.png")
        dumpHomeLinkHA(dir: dir, thin: false, name: "readpico-ha-cf-access-full.png")
        dumpHomeLinkDisconnected(dir: dir)
        dumpCardBitmaps(dir: dir, stamp: stamp)
        NSApp.terminate(nil)
    }

    private static func dumpCardBitmaps(dir: String, stamp: String) {
        let settings = AppSettings()
        settings.cardRenderingMode = .liquidGlass
        let grokConfigured = GrokBotUsageSnapshot(
            state: .live,
            usagePercent: 58,
            remainingPercent: 42,
            planLabel: "Pro",
            resetDate: Date().addingTimeInterval(86400 * 3),
            availableBankedResetCount: 1,
            sampledAt: Date(),
            message: ""
        )
        writeJPEG({ try ScreenRenderer.renderGrokBot(grokConfigured, settings: settings) },
                  path: (dir as NSString).appendingPathComponent("grokbot-quota-lingxi68-\(stamp).jpg"))
        writeJPEG({ try ScreenRenderer.renderGrokBot(.notConfigured, settings: settings) },
                  path: (dir as NSString).appendingPathComponent("grokbot-quota-empty-lingxi68-\(stamp).jpg"))
        // Seed a realistic CF snapshot so hierarchy (domain / section / rows / chrome) is visible in audits.
        let cfSettings = seedCloudflareAuditSettings(settings)
        writeJPEG({
            try ScreenRenderer.renderCanvas(modules: [.cloudflare], system: .empty,
                nowPlaying: .placeholder, pomodoro: PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "", remaining: 0, duration: 0, completedFocusSessions: 0), customText: "", settings: cfSettings)
        }, path: (dir as NSString).appendingPathComponent("cloudflare-card-lingxi68-\(stamp).jpg"))
        // 小电视 240×240 Grok 模块
        let img = ScreenRenderer.renderDeviceCanvas(
            modules: [.grokBot], system: .empty, nowPlaying: .placeholder,
            pomodoro: PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "", remaining: 0, duration: 0, completedFocusSessions: 0), customText: "", settings: settings,
            grokBot: grokConfigured, width: 240, height: 240,
            palette: settings.resolvedPalette, optimizeForEInk: false)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("grokbot-quota-xiaodiushi-240-\(stamp).png"))
        writeCGImage(img, to: url)
        print("WROTE \(url.path)")
    }

    private static func seedCloudflareAuditSettings(_ base: AppSettings) -> AppSettings {
        let now = Date()
        base.cloudflare.zoneID = String(repeating: "a", count: 32)
        base.cloudflare.zoneName = "xhfo.net"
        base.cloudflare.hostname = "analytics-preview.very-long-subdomain.xhfo.net"
        base.cloudflare.period = .day
        base.cloudflare.presentation = .ranking
        base.cloudflare.rankByTraffic = true
        base.cloudflare.displayLanguage = .chinese
        let start = Int(now.timeIntervalSince1970) - 3600
        let end = Int(now.timeIntervalSince1970)
        let fixture = """
        {"zoneID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","hostname":"analytics-preview.very-long-subdomain.xhfo.net","period":"day","start":\(start),"end":\(end),"sampledAt":\(end),"requests":1284500,"bytes":98566144000,"regions":[{"code":"CN","requests":620000,"bytes":42000000000},{"code":"US","requests":310000,"bytes":28000000000},{"code":"JP","requests":140000,"bytes":12000000000},{"code":"DE","requests":90000,"bytes":8000000000},{"code":"SG","requests":70000,"bytes":5500000000}],"trend":[{"time":"t1","requests":100,"bytes":200},{"time":"t2","requests":180,"bytes":260},{"time":"t3","requests":140,"bytes":220}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let snap = try? decoder.decode(CloudflareAnalyticsSnapshot.self, from: Data(fixture.utf8)) {
            base.cloudflareSnapshot = snap
        }
        return base
    }

    private static func writeJPEG(_ body: () throws -> RenderResult, path: String) {
        do {
            let result = try body()
            try result.data.write(to: URL(fileURLWithPath: path))
            print("WROTE \(path) \(result.data.count)")
        } catch {
            fputs("render failed \(path): \(error)\n", stderr)
        }
    }

    private static func writeCGImage(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    private static func dumpHomeLinkDisconnected(dir: String) {
        let model = ReadPicoManagerModel()
        let root = ReadPicoManagerView(initialHost: "", initialSection: "connection", model: model, embedded: true)
            .frame(width: 720, height: 720)
        snapshot(rootView: root, size: NSSize(width: 720, height: 720),
                 path: (dir as NSString).appendingPathComponent("readpico-manager-disconnected.png"))
    }

    private static func dumpHomeLinkHA(dir: String, thin: Bool, name: String) {
        let key = String(repeating: "a", count: 32)
        let model = ReadPicoManagerModel()
        do {
            model.connection = try ReadPicoConnection(address: "http://127.0.0.1:17999", setupKey: key)
        } catch {
            fputs("connection setup failed: \(error)\n", stderr)
        }
        model.applyAuditHomeLinkSnapshot(thin: thin)
        model.home = ReadPicoHomeConfiguration(
            enabled: true,
            local: "http://homeassistant.local:8123",
            external: "https://ha.example.com",
            homeWifi: "",
            externalEnabled: true,
            externalControl: false,
            hasToken: true,
            hasCfAccessClientId: !thin,
            hasCfAccessClientSecret: !thin
        )
        let root = ReadPicoManagerView(initialHost: "http://127.0.0.1:17999",
                                       initialSection: "connection",
                                       model: model,
                                       embedded: true)
            .frame(width: 720, height: 1100)
        snapshot(rootView: root, size: NSSize(width: 720, height: 1100),
                 path: (dir as NSString).appendingPathComponent(name))
    }

    private static func snapshot<V: View>(rootView: V, size: NSSize, path: String) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("bitmapImageRep failed for \(path)\n", stderr); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let out = NSBitmapImageRep(data: tiff),
              let png = out.representation(using: .png, properties: [:]) else {
            fputs("png encode failed for \(path)\n", stderr); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("WROTE \(path) \(png.count)")
        } catch {
            fputs("write failed \(path): \(error)\n", stderr)
        }
        window.orderOut(nil)
    }
}
