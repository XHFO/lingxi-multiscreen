import AppKit
import Foundation
import ImageIO
import LinxDisplayCore

/// Local fixtures only: no account configuration, printer, or cloud request is used.
@main
struct FormlabsRenderingTests {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("formlabs-rendering-tests").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func png(_ image: CGImage) -> Data {
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        }
        func save(_ image: CGImage, _ name: String) throws {
            try png(image).write(to: output.appendingPathComponent(name + ".png"))
        }


        let now = ISO8601DateFormatter().date(from: "2026-11-23T02:00:00Z")!
        let sampled = ISO8601DateFormatter().date(from: "2026-09-15T15:32:03Z")!
        let settings = AppSettings()
        let connection = FormlabsConnectionSettings(printerSerial: "FIXTURE", showThumbnail: true)
        let cover = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        cover.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1))
        cover.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let live = FormlabsSnapshot(
            device: FormlabsDeviceInfo(id: "FIXTURE", status: "printing", isConnected: true),
            print: FormlabsPrintInfo(runID: "fixture-run", name: "Fixture model", status: "printing",
                currentLayer: 55, layerCount: 411, estimatedTimeRemainingMS: 6_420_000,
                materialName: "Grey V5"), thumbnail: png(cover.makeImage()!), sampledAt: sampled,
            hasCurrentPrint: true)
        var stale = live
        stale.dataIssue = "公开 API 暂未提供当前任务"
        var staleDifferentMetrics = stale
        staleDifferentMetrics.print?.status = "finished"
        staleDifferentMetrics.print?.currentLayer = 411
        staleDifferentMetrics.print?.estimatedTimeRemainingMS = 0
        var offline = live
        offline.device?.status = "offline"
        offline.device?.isConnected = false
        offline.hasCurrentPrint = false
        var idle = live
        idle.device?.status = "idle"
        idle.hasCurrentPrint = false
        let unavailable = FormlabsSnapshot(cloudError: "连接暂时失败", dataIssue: "公开 API 数据未更新")

        func standalone(_ snapshot: FormlabsSnapshot, at date: Date = now) throws -> CGImage {
            try ScreenRenderer.renderFormlabs(deviceName: "Formlabs Fixture", connection: connection,
                snapshot: snapshot, settings: settings, now: date).image
        }
        let liveImage = try standalone(live)
        let staleImage = try standalone(stale)
        check(png(liveImage) != png(staleImage), "Stale data must visibly differ from a live print")
        check(png(staleImage) == png(try standalone(staleDifferentMetrics)),
              "Stale status, layer count, progress, and remaining time must not leak into the card")
        check(png(staleImage) == png(try standalone(stale, at: now.addingTimeInterval(300))),
              "Re-rendering cached data must not advance the displayed update time")
        var differentSampleTime = stale
        differentSampleTime.sampledAt = sampled.addingTimeInterval(3600)
        check(png(staleImage) != png(try standalone(differentSampleTime)),
              "The cache footer must display the actual last successful sample time")
        check(png(try standalone(unavailable)) != png(try standalone(.empty)),
              "An API failure without a snapshot must not look like missing configuration")
        check(png(try standalone(unavailable)) == png(try standalone(unavailable, at: now.addingTimeInterval(300))),
              "An unavailable snapshot without a sample time must not invent one")
        check(ScreenRenderer.formlabsStatusText("data_unavailable") == "数据未更新",
              "Unavailable data has a clear status label")
        check(ScreenRenderer.formlabsStatusText("COMPLETE") == "已完成",
              "Official successful terminal states remain localized")
        try save(liveImage, "standalone-live")
        try save(staleImage, "standalone-stale")
        try save(try standalone(offline), "standalone-offline")
        try save(try standalone(unavailable), "standalone-unavailable")
        try save(try standalone(idle), "standalone-idle-cached-task")

        let system = SystemSnapshot(cpuPercent: 0, memoryPercent: 0,
            usedMemoryBytes: 0, totalMemoryBytes: 1, downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0, uptime: 0, sampledAt: now)
        let pomodoro = PomodoroSnapshot(phase: .idle, effectivePhase: .idle,
            taskName: "", remaining: 0, duration: 1, completedFocusSessions: 0)
        func canvas(_ snapshot: FormlabsSnapshot, width: Int, height: Int) -> CGImage {
            ScreenRenderer.renderDeviceCanvas(modules: [.formlabs], system: system,
                nowPlaying: NowPlayingInfo(title: ""), pomodoro: pomodoro, customText: "",
                settings: settings, formlabsItems: [.init(deviceName: "Formlabs Fixture",
                    connection: connection, snapshot: snapshot)], now: now, width: width,
                height: height, palette: settings.resolvedPalette, optimizeForEInk: true)
        }
        for (width, height) in [(142, 428), (200, 200), (296, 152)] {
            let staleCanvas = canvas(stale, width: width, height: height)
            check(png(staleCanvas) == png(canvas(staleDifferentMetrics, width: width, height: height)),
                  "Canvas \(width)x\(height) must hide stale print metrics")
            check(png(staleCanvas) != png(canvas(live, width: width, height: height)),
                  "Canvas \(width)x\(height) must distinguish cached data")
            try save(staleCanvas, "canvas-stale-\(width)x\(height)")
        }

        for style in C6PrinterCardStyle.allCases {
            func frame(_ snapshot: FormlabsSnapshot) -> Data {
                C6LocalRenderer.formlabsFrame(name: "Formlabs Fixture", configuration: connection,
                    snapshot: snapshot, palette: settings.resolvedPalette, cardStyle: style)
            }
            let cachedFrame = frame(stale)
            check(cachedFrame == frame(staleDifferentMetrics), "C6 \(style) must hide stale print metrics")
            check(cachedFrame != frame(live), "C6 \(style) must distinguish unavailable data")
            check(cachedFrame != frame(offline), "C6 \(style) must distinguish API unavailability from offline")
            check(cachedFrame.count == C6LocalRenderer.frameBytes, "C6 frame dimensions remain unchanged")
            try save(C6LocalRenderer.image(fromRGB565: cachedFrame)!, "c6-stale-\(style.rawValue)")
        }

        print("PASS: \(checks) Formlabs rendering checks; images: \(output.path)")
    }
}
