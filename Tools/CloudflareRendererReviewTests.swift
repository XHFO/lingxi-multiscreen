import AppKit
import CoreGraphics
import Foundation

/// The runner extracts the actual production layout and CoreText helpers into this module.
/// No client, Keychain, AppModel, user settings, device or network request is used.
@main struct CloudflareRendererReviewTests {
    static var checks = 0
    static var failures: [String] = []
    static var cases: [[String: Any]] = []
    static var language: CloudflareDisplayLanguage = .chinese
    static func hasHan(_ value: String) -> Bool { value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !value() { failures.append(description); print("FAIL " + description) }
    }
    static func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool { abs(a - b) <= tolerance }
    static func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.minY >= outer.minY - tolerance &&
        inner.maxX <= outer.maxX + tolerance && inner.maxY <= outer.maxY + tolerance
    }
    static func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0.01 && intersection.height > 0.01
    }
    static func coordinates(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    static func parse(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func settings() -> CloudflareAnalyticsSettings {
        var value = CloudflareAnalyticsSettings()
        value.zoneID = String(repeating: "a", count: 32)
        value.zoneName = "Cloudflare 网站统计"
        value.hostname = "a-long-hostname.for-layout-review.example.com"
        return value
    }
    static func snapshot(_ settings: CloudflareAnalyticsSettings, start: Date, end: Date,
                         sampled: Date? = nil, trend: [CloudflareAnalyticsSnapshot.Point]? = nil, requests: Double = 123_456_789, bytes: Double = 987_654_321_000,
                         regions: [CloudflareAnalyticsSnapshot.Region]? = nil) -> CloudflareAnalyticsSnapshot {
        let rows: [CloudflareAnalyticsSnapshot.Point] = trend ?? [
            .init(time: "2026-10-23T01:00:00Z", requests: 100, bytes: 2_000),
            .init(time: "2026-10-23T02:00:00Z", requests: 200, bytes: 7_000),
            .init(time: "2026-10-23T10:00:00Z", requests: 350, bytes: 3_000),
            .init(time: "2026-10-23T18:00:00Z", requests: 120, bytes: 6_000),
        ]
        return .init(zoneID: settings.zoneID, hostname: settings.hostname, period: settings.period,
                     start: start, end: end, sampledAt: sampled ?? end,
                     requests: requests, bytes: bytes,
                     regions: regions ?? [
                        .init(code: "US", requests: 51_000, bytes: 1_000_000),
                        .init(code: "CN", requests: 71_000, bytes: 3_000_000),
                        .init(code: "DE", requests: 12_000, bytes: 900_000),
                        .init(code: "GB", requests: 5_000, bytes: 2_000_000),
                        .init(code: "JP", requests: 19_000, bytes: 700_000),
                     ], trend: rows)
    }
    static func testTimeAxis() {
        let start = parse("2026-10-23T00:00:00Z"), end = start.addingTimeInterval(24 * 3600)
        let config = settings(), chart = CGRect(x: 10, y: 20, width: 240, height: 100)
        let irregular = snapshot(config, start: start, end: end, trend: [
            .init(time: "2026-10-23T10:00:00Z", requests: 30, bytes: 6),
            .init(time: "2026-10-23T01:00:00Z", requests: 10, bytes: 9),
            .init(time: "2026-10-23T02:00:00Z", requests: 20, bytes: 3),
        ])
        let points = CloudflareRendererReview.cloudflareTrendPoints(irregular, chart: chart, byTraffic: false)
        check(points.count == 3, "three unordered buckets become three chronological points")
        check(near(points[0].x, 20) && near(points[1].x, 30) && near(points[2].x, 110), "1h/2h/10h use actual elapsed-hour positions")
        check(near(points[2].x - points[1].x, 8 * (points[1].x - points[0].x)), "eight missing hours are not collapsed to one spacing")
        check(near(points[0].y, 120 - 100 / 3) && near(points[2].y, 20), "request values use the request peak")
        let traffic = CloudflareRendererReview.cloudflareTrendPoints(irregular, chart: chart, byTraffic: true)
        check(traffic.map(\.x) == points.map(\.x) && near(traffic[0].y, 20) && near(traffic[1].y, 120 - 100 / 3), "traffic ranking changes values while preserving time positions")

        let daily = snapshot(config, start: start, end: start.addingTimeInterval(3 * 86400), trend: [
            .init(time: "2026-10-25", requests: 3, bytes: 3),
            .init(time: "2026-10-23T12:00:00.500Z", requests: 2, bytes: 2),
            .init(time: "2026-10-23", requests: 1, bytes: 1),
        ])
        let dailyPoints = CloudflareRendererReview.cloudflareTrendPoints(daily, chart: chart, byTraffic: false)
        check(dailyPoints.count == 3 && near(dailyPoints[0].x, 10) && near(dailyPoints[2].x, 170), "daily YYYY-MM-DD rows map to UTC midnight and actual day spacing")
        check(near(dailyPoints[1].x, 10 + 240 * CGFloat(43200.5 / (3 * 86400))), "fractional ISO8601 seconds retain precise time position")

        let invalid = snapshot(config, start: start, end: end, trend: [
            .init(time: "not-a-date", requests: 1, bytes: 1),
            .init(time: "", requests: 1, bytes: 1),
            .init(time: "2026-10-22T23:59:59Z", requests: 1, bytes: 1),
            .init(time: "2026-10-24T00:00:01Z", requests: 1, bytes: 1),
            .init(time: "2026-10-23T03:00:00Z", requests: -.infinity, bytes: .infinity),
            .init(time: "2026-10-23T04:00:00Z", requests: .nan, bytes: -1),
            .init(time: "2026-10-23T05:00:00Z", requests: -1, bytes: .nan),
            .init(time: "2026-10-23T00:00:00Z", requests: 0, bytes: 0),
            .init(time: "2026-10-24T00:00:00Z", requests: 10, bytes: 20),
        ])
        for byTraffic in [false, true] {
            let filtered = CloudflareRendererReview.cloudflareTrendPoints(invalid, chart: chart, byTraffic: byTraffic)
            check(filtered.count == 2, "invalid dates, window-external and invalid metric values are filtered (traffic=\(byTraffic))")
            check(near(filtered[0].x, chart.minX) && near(filtered[1].x, chart.maxX), "inclusive range boundaries remain bounded (traffic=\(byTraffic))")
            check(filtered.allSatisfy { $0.x.isFinite && $0.y.isFinite && chart.contains($0) || $0 == CGPoint(x: chart.minX, y: chart.maxY) || $0 == CGPoint(x: chart.maxX, y: chart.minY) }, "filtered output has finite chart coordinates (traffic=\(byTraffic))")
        }
        let empty = snapshot(config, start: end, end: start, trend: [])
        check(CloudflareRendererReview.cloudflareTrendPoints(empty, chart: chart, byTraffic: false).isEmpty, "reversed time range cannot produce chart points")
        check(CloudflareRendererReview.cloudflareTrendPoints(irregular, chart: .zero, byTraffic: false).isEmpty, "zero-size chart is rejected")
    }
    static func palette(dark: Bool = false) -> ScreenPalette {
        let bg: CGFloat = dark ? 0 : 1, ink: CGFloat = dark ? 1 : 0
        return ScreenPalette(background: (bg,bg,bg), card: (bg,bg,bg), inset: (bg,bg,bg),
            border: (0.5,0.5,0.5), accent: (ink,ink,ink), secondaryAccent: (ink,ink,ink),
            primaryText: (ink,ink,ink), secondaryText: (dark ? 0.75 : 0.25,dark ? 0.75 : 0.25,dark ? 0.75 : 0.25),
            tertiaryText: (dark ? 0.6 : 0.4,dark ? 0.6 : 0.4,dark ? 0.6 : 0.4))
    }
    /// Match the canvas encoder's RGB -> device gray -> nearest native gray conversion.
    /// Comparing actual pixels catches color-space and alpha differences that raw CGColor components miss.
    static func nativeGrayPixels(_ image: CGImage) -> [Int] {
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { min(15, (Int(pixels[$0]) + 8) / 17) * 17 }
    }
    static func pixel(_ pixels: [Int], width: Int, height: Int, at point: CGPoint) -> Int {
        let column = Int(point.x.rounded(.down)), row = height - 1 - Int(point.y.rounded(.down))
        precondition(column >= 0 && column < width && row >= 0 && row < height)
        return pixels[row * width + column]
    }
    static func positiveMapLevels(dark: Bool) -> [Int] {
        let step = 10, width = CloudflareWorldDots.columns * step, height = CloudflareWorldDots.rows * step
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsAntialiasing(false)
        context.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The map uses sqrt(metric/peak). These fixtures span its positive-value opacity range.
        let codes = ["CN", "US", "DE", "GB"], strengths = [0.000001, 1.0 / 3, 2.0 / 3, 1.0]
        let regions = zip(codes, strengths).map {
            CloudflareAnalyticsSnapshot.Region(code: $0.0, requests: $0.1 * $0.1, bytes: $0.1 * $0.1)
        }
        CloudflareWorldMap.draw(context, in: CGRect(x: 0, y: 0, width: width, height: height),
            regions: regions, byTraffic: false, ink: CGColor(gray: dark ? 1 : 0, alpha: 1),
            accent: CGColor(gray: dark ? 1 : 0, alpha: 1), highContrast: true)
        let pixels = nativeGrayPixels(context.makeImage()!)
        return codes.map { code in
            let encoded = Int(CloudflareWorldDots.countries[code]!.first!)
            let column = encoded % CloudflareWorldDots.columns, row = encoded / CloudflareWorldDots.columns
            return pixel(pixels, width: width, height: height,
                at: CGPoint(x: (CGFloat(column) + 0.5) * CGFloat(step),
                            y: CGFloat(height) - (CGFloat(row) + 0.5) * CGFloat(step)))
        }
    }
    static func render(width: Int, height: Int, byTraffic: Bool, presentation: CloudflareAnalyticsPresentation, output: URL,
                       domainCase: CloudflareDomainLetterCase = .original) throws {
        let canvasWidth = width + 24, canvasHeight = height + 28
        CloudflareRendererReview.height = canvasHeight
        CloudflareRendererReview.textTraces = []; CloudflareRendererReview.chartTraces = []
        let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight,
                                bitsPerComponent: 8, bytesPerRow: canvasWidth * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        let band = CGRect(x: 12, y: 14, width: width, height: height)
        let start = parse("2026-10-23T00:00:00Z"), end = start.addingTimeInterval(86400)
        var config = settings(); config.rankByTraffic = byTraffic; config.presentation = presentation
        config.domainLetterCase = domainCase
        config.displayLanguage = language
        let value = snapshot(config, start: start, end: end, sampled: end.addingTimeInterval(-4000))
        let settings = AppSettings(cloudflare: config, cloudflareSnapshot: value)
        CloudflareRendererReview.drawCloudflareAnalytics(context, band: band, colors: palette(), settings: settings, now: end)
        let name = "\(width)x\(height)-" + (byTraffic ? "traffic" : "requests") + "-" + presentation.rawValue + "-" + domainCase.rawValue + "-" + language.rawValue
        let traces = CloudflareRendererReview.textTraces, bandCG = CloudflareRendererReview.rect(band)
        check(!traces.isEmpty, "\(name) retains visible text")
        for (index, trace) in traces.enumerated() {
            check(contains(bandCG, trace.bounds), "\(name) text \(index) rectangle stays inside band")
            check(contains(bandCG, trace.glyphBounds, tolerance: 0.75), "\(name) text \(index) actual CoreText glyph bounds stay inside band")
            for prior in traces.prefix(index) {
                check(!overlap(prior.bounds, trace.bounds), "\(name) text rectangles do not overlap: \(index)")
                check(!overlap(prior.glyphBounds, trace.glyphBounds), "\(name) actual glyph bounds do not overlap: \(index)")
            }
        }
        for chart in CloudflareRendererReview.chartTraces {
            let chartCG = CloudflareRendererReview.rect(chart)
            check(contains(bandCG, chartCG), "\(name) chart stays inside band")
            check(traces.allSatisfy { !overlap($0.bounds, chartCG) }, "\(name) chart and text do not overlap")
        }
        let image = context.makeImage()!
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: canvasWidth * canvasHeight * 4)
        var dark = 0, outside = 0
        for row in 0..<canvasHeight {
            for column in 0..<canvasWidth {
                if pixels[(row * canvasWidth + column) * 4] < 240 {
                    dark += 1
                    if column < 12 || column >= width + 12 || row < 14 || row >= height + 14 { outside += 1 }
                }
            }
        }
        check(dark > 0, "\(name) PNG contains actual rasterized text or trend pixels")
        check(outside == 0, "\(name) produces no ink outside the allocated band")
        let displayed = traces.map(\.displayed).joined(separator: " ")
        check(language == .english ? !hasHan(displayed) : !["REQ", "TRAFFIC", "CACHED", "UPDATED", "TOP REGIONS"].contains(where: displayed.contains),
              "\(name) labels and regions consistently use the selected language")
        if height < 28 {
            let metric = CloudflareAnalyticsSnapshot.countText(value.requests, language: language)
            let label = language.text("请求", "REQ")
            check(traces.count == 1 && traces[0].text == label + " " + metric,
                  "\(name) very short band prioritizes the request metric over the long hostname")
            check(traces.first?.displayed.contains(label) == true && traces.first?.displayed.contains(metric) == true,
                  "\(name) actual CoreText input preserves the request label and all digits of \(metric)")
            check(traces.first?.displayed == label + " " + metric,
                  "\(name) measurement and truncation do not remove any request digits")
        } else if height < 76 {
            check(traces.count == (height >= 40 ? 3 : 2), "\(name) dense mode keeps bounded headline and metrics rows")
        }
        if height >= 180 {
            check(CloudflareRendererReview.chartTraces.count == 1, "\(name) reserves one trend chart")
        }
        if height >= 76 {
            check(traces.last?.text.hasPrefix("Cloudflare · ") == true, "\(name) footer remains visible")
            check(traces.contains { $0.text == config.domainLetterCase.display(config.hostname) },
                  "\(name) generic color renderer applies selected domain case only at display time")
        }
        if traces.contains(where: { $0.text.hasPrefix(language.text("全球热区", "GLOBAL /")) }) {
            check(traces.contains(where: { $0.text.hasPrefix("1. ") }), "\(name) map retains at least one textual region value")
        }
        cases.append([
            "name": name, "png": name + ".png", "width": width, "height": height,
            "band_cg": coordinates(bandCG), "dark_pixels": dark, "outside_band_pixels": outside,
            "text": traces.map { ["source": $0.text, "displayed": $0.displayed, "font_size": $0.size,
                                   "bounds_cg": coordinates($0.bounds), "glyph_bounds_cg": coordinates($0.glyphBounds)] },
            "charts_top_left": CloudflareRendererReview.chartTraces.map(coordinates),
        ])
    }
    static func renderNative(width: Int, height: Int, scale: CGFloat, parts: Int = 1,
                             halfWidth: Bool = false, dark: Bool = false,
                             byTraffic: Bool, presentation: CloudflareAnalyticsPresentation,
                             output: URL, state: String = "ready", longDomain: Bool = false, overrideHeight: CGFloat? = nil,
                             domainCase: CloudflareDomainLetterCase = .original) throws {
        CloudflareRendererReview.height = 428
        CloudflareRendererReview.textTraces = []; CloudflareRendererReview.chartTraces = []
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = palette(dark: dark)
        context.setFillColor(colors.backgroundCG); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: CGFloat(height) / scale - 428)
        let physicalWidth = (CGFloat(width) - 16 * scale) / (halfWidth ? 2 : 1)
        let physicalHeight = overrideHeight ?? ((CGFloat(height) - 16 * scale) / CGFloat(parts))
        let band = CGRect(x: 8, y: 8, width: physicalWidth / scale, height: physicalHeight / scale)
        let transform = context.ctm
        let start = parse("2026-10-23T00:00:00Z"), end = start.addingTimeInterval(86400)
        var config = settings(); config.rankByTraffic = byTraffic; config.presentation = presentation
        config.hostname = longDomain ? "Dashboard.Super-Long-Hostname-For-Domain-Layout-Review.Example.com" : "Example.com"
        config.domainLetterCase = domainCase
        config.displayLanguage = language
        let longRegions: [CloudflareAnalyticsSnapshot.Region]? = state == "long-regions" ? [
            .init(code: "BA", requests: 71000, bytes: 3000000),
            .init(code: "AE", requests: 51000, bytes: 2000000),
            .init(code: "GB", requests: 19000, bytes: 1000000),
            .init(code: "US", requests: 12000, bytes: 900000),
            .init(code: "XX", requests: 5000, bytes: 700000),
        ] : nil
        let value = snapshot(config, start: start, end: end, sampled: state == "stale" ? end.addingTimeInterval(-4000) : end,
            requests: state == "huge" ? 9_876_543_210_987 : 123_456_789,
            bytes: state == "huge" ? 8_765_432_109_876 : 987_654_321_000, regions: longRegions)
        CloudflareRendererReview.drawCloudflareAnalytics(context, band: band, colors: colors,
            settings: AppSettings(cloudflare: config, cloudflareSnapshot: state == "missing" ? nil : value),
            now: end, nativeEInkPixelScale: scale)
        let name = "app-\(width)x\(height)-scale\(Int(scale))-parts\(parts)-" +
            (halfWidth ? "half-" : "full-") + (dark ? "dark-" : "light-") +
            (byTraffic ? "traffic-" : "requests-") + presentation.rawValue + "-" + state + (longDomain ? "-long-domain" : "") + (overrideHeight.map { "-height\(Int($0))" } ?? "") + "-" + domainCase.rawValue + "-" + language.rawValue
        let traces = CloudflareRendererReview.textTraces
        let bandPixels = CloudflareRendererReview.rect(band).applying(transform)
        check(!traces.isEmpty, "\(name) native band retains useful text")
        for (index, trace) in traces.enumerated() {
            let physical = trace.bounds.applying(trace.transform)
            let glyphs = trace.glyphBounds.applying(trace.transform)
            check(trace.size * abs(trace.transform.a) >= 28 - 0.01, "\(name) retains at least 28 physical pixel type")
            check(contains(bandPixels, physical), "\(name) text \(index) rectangle inside band")
            check(contains(bandPixels, glyphs, tolerance: 1), "\(name) actual glyphs inside band")
            for prior in traces.prefix(index) {
                check(!overlap(prior.bounds.applying(prior.transform), physical), "\(name) text rectangles don't overlap")
                check(!overlap(prior.glyphBounds.applying(prior.transform), glyphs), "\(name) actual glyphs don't overlap")
            }
        }
        let source = traces.map(\.text).joined(separator: " ")
        let displayed = traces.map(\.displayed).joined(separator: " ")
        check(language == .english ? !hasHan(displayed) : !["REQ", "TRAFFIC", "CACHED", "UPDATED", "TOP REGIONS"].contains(where: displayed.contains),
              "\(name) every visible label and region uses the selected language")
        check(traces.filter { ["LOW", "HIGH", "低", "高"].contains($0.text) }.allSatisfy { $0.text == $0.displayed },
              "\(name) every visible map legend label is complete")
        if state != "missing" {
            let request = CloudflareAnalyticsSnapshot.countText(value.requests, language: language)
            let requestOptions = [request, value.requests.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(language.locale)), String(format: "%.2e", value.requests)]
            check(traces.contains { requestOptions.contains($0.text) && $0.displayed == $0.text }, "\(name) complete request metric survives, with explicit compact units when needed")
            if physicalHeight >= 100 {
                let traffic = CloudflareAnalyticsSnapshot.bytesText(value.bytes, language: language)
                let splitTraffic = traffic.split(separator: " ").map(String.init)
                let trafficSurvives = traces.contains { [traffic, String(format: "%.2e", value.bytes)].contains($0.text) && $0.displayed == $0.text }
                    || (splitTraffic.count == 2 && zip(traces, traces.dropFirst()).contains {
                        $0.text == splitTraffic[0] && $0.displayed == $0.text && $1.text == splitTraffic[1] && $1.displayed == $1.text
                    })
                check(trafficSurvives, "\(name) complete traffic metric and explicit units survive")
            }
            if parts == 1 && !halfWidth && physicalHeight >= 480 && physicalWidth >= 500 {
                let expectedDomain = config.domainLetterCase.display(config.hostname)
                let suffix = config.domainLetterCase.display("Example.com")
                check(longDomain ? source.contains(suffix) : source.contains(expectedDomain), "\(name) domain identity, selected case and suffix remain present")
                check(value.regions.contains { source.contains(language.regionName($0.code)) }, "\(name) full layout includes localized textual regional values")
                check(source.uppercased().contains("CLOUDFLARE"), "\(name) source identity remains visible")
                check(traces.filter { [language.text("请求", "REQ"), language.text("流量", "TRAFFIC"), "CLOUDFLARE"].contains($0.text) }.allSatisfy { $0.displayed == $0.text },
                      "\(name) utility and metric labels are complete, with no ellipsis")
                check(traces.contains { $0.text == expectedDomain || (longDomain && $0.text.contains(suffix)) },
                      "\(name) domain casing is used by the actual native title call")
                let first = value.rankedRegions(byTraffic: byTraffic).first!
                let regionalValue = byTraffic ? CloudflareAnalyticsSnapshot.bytesText(first.bytes, language: language)
                    : CloudflareAnalyticsSnapshot.countText(first.requests, language: language)
                check(traces.contains { $0.text == regionalValue && $0.displayed == regionalValue },
                      "\(name) top region retains its complete selected metric")
                if presentation == .worldMap {
                    check(source.contains(language.text("全球" + (byTraffic ? "流量" : "请求") + "分布", "GLOBAL / " + (byTraffic ? "TRAFFIC" : "REQ"))),
                          "\(name) full map presentation includes its selected metric heading")
                    check(displayed.contains(language.text("国家 / 地区聚合", "COUNTRY / REGION")) && traces.contains { $0.displayed == language.text("低", "LOW") }
                        && traces.contains { $0.displayed == language.text("高", "HIGH") }, "\(name) full map retains its complete aggregation caption and legend")
                }
                if state == "stale" {
                    check(displayed.contains(language.text("缓存", "CACHED")), "\(name) stale state is explicit")
                }
            }
        } else {
            check(!displayed.contains(CloudflareAnalyticsSnapshot.countText(value.requests, language: language)), "\(name) empty state never shows fixture metrics")
            check(displayed.uppercased().contains("CLOUDFLARE") || displayed.contains(language.text("网站统计", "site data")), "\(name) app identity is visible in empty state")
        }
        for chart in CloudflareRendererReview.chartTraces {
            let physical = CloudflareRendererReview.rect(chart).applying(transform)
            check(contains(bandPixels, physical), "\(name) trend plot stays inside band")
            check(traces.allSatisfy { !overlap($0.bounds.applying($0.transform), physical) }, "\(name) trend plot doesn't overlap text")
        }
        let image = context.makeImage()!
        var legendLevels: [Int] = []
        if let low = traces.first(where: { $0.text == language.text("低", "LOW") }) {
            let lowBounds = low.bounds.applying(low.transform)
            let gray = nativeGrayPixels(image)
            legendLevels = (0..<4).map { index in
                pixel(gray, width: width, height: height,
                    at: CGPoint(x: lowBounds.minX + 81 + CGFloat(index) * 22, y: lowBounds.midY - 1))
            }
            let expected = positiveMapLevels(dark: dark)
            check(legendLevels == expected, "\(name) legend uses the map's actual native positive-value gray levels: \(legendLevels) vs \(expected)")
            check(zip(legendLevels, legendLevels.dropFirst()).allSatisfy { dark ? $0 < $1 : $0 > $1 },
                  "\(name) legend remains distinguishable and ordered after native 16-gray conversion")
        }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var ink = 0, outside = 0
        let x0 = Int(bandPixels.minX.rounded(.down)), x1 = Int(bandPixels.maxX.rounded(.up))
        let y0 = height - Int(bandPixels.maxY.rounded(.up)), y1 = height - Int(bandPixels.minY.rounded(.down))
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let changed = dark ? pixels[offset] > 16 : pixels[offset] < 240
                if changed {
                    ink += 1
                    if column < x0 || column >= x1 || row < y0 || row >= y1 { outside += 1 }
                }
            }
        }
        check(ink > 0, "\(name) actual output includes visible ink")
        check(outside == 0, "\(name) no drawing escapes allocated band")
        cases.append(["name": name, "png": name + ".png", "width": width, "height": height,
                      "native_scale": scale, "parts": parts, "half_width": halfWidth, "state": state,
                      "dark": dark, "band_pixels": coordinates(bandPixels), "outside_band_pixels": outside,
                      "native_legend_gray_levels": legendLevels,
                      "text": traces.map { ["source": $0.text, "displayed": $0.displayed,
                        "font_pixels": $0.size * abs($0.transform.a),
                        "bounds_pixels": coordinates($0.bounds.applying($0.transform)),
                        "glyph_bounds_pixels": coordinates($0.glyphBounds.applying($0.transform))] },
                      "charts": CloudflareRendererReview.chartTraces.map { coordinates(CloudflareRendererReview.rect($0).applying(transform)) }])
    }
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        testTimeAxis()
        let landDots = CloudflareWorldDots.countries.values.flatMap { $0 }
        check(landDots.count == Set(landDots).count, "Country dots remain mutually exclusive")
        let coverage = CloudflareWorldMap.coverage(regions: [
            .init(code: "cn", requests: 10, bytes: 0), .init(code: "CN", requests: 5, bytes: 0), .init(code: "US", requests: 0, bytes: 50),
            .init(code: "XX", requests: 3, bytes: 20), .init(code: "ZZ", requests: 2, bytes: 10), .init(code: "DE", requests: .nan, bytes: .infinity)
        ], byTraffic: false)
        check(coverage.mapped == 1 && coverage.unmapped == 2, "Unknown/invalid map locations aren't invented")
        let legacy = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: Data("{}".utf8))
        check(legacy.presentation == .worldMap, "Existing settings adopt the world map without losing source identity")
        check(legacy.domainLetterCase == .original, "Existing domain spelling remains unchanged by default")
        check(legacy.displayLanguage == .chinese, "Existing boards retain Chinese as their initial display language")
        var configured = legacy; configured.presentation = .ranking
        let roundTrip = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: JSONEncoder().encode(configured))
        check(roundTrip.presentation == .ranking, "Presentation choice survives settings round trip")
        for selectedLanguage in CloudflareDisplayLanguage.allCases {
        language = selectedLanguage
        for domainCase in CloudflareDomainLetterCase.allCases {
            var config = settings(); config.hostname = "Stats.XhFo.NET"; config.domainLetterCase = domainCase; config.displayLanguage = language
            let value = snapshot(config, start: parse("2026-10-23T00:00:00Z"), end: parse("2026-10-24T00:00:00Z"))
            let domain = config.hostname
            check(config.domainLetterCase.display(domain) == (domainCase == .original ? domain : (domainCase == .lowercase ? domain.lowercased() : domain.uppercased())),
                  "\(domainCase) transforms only the displayed domain")
            let stored = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: JSONEncoder().encode(config))
            check(stored.domainLetterCase == domainCase && stored.displayLanguage == language && stored.hostname == domain && value.matches(stored),
                  "\(domainCase)/\(language) survive coding without changing the hostname filter or matching snapshot")
            try render(width: 224, height: 400, byTraffic: true, presentation: .worldMap, output: output, domainCase: domainCase)
            for (width, height) in [(684, 1216), (1216, 684)] {
                for longDomain in [false, true] {
                    try renderNative(width: width, height: height, scale: 3, byTraffic: true,
                        presentation: .worldMap, output: output, longDomain: longDomain, domainCase: domainCase)
                }
            }
        }
        for width in [90, 224, 684] {
            for height in [12, 24, 28, 40, 56, 75, 76, 96, 120, 159, 160, 180, 224, 400] {
                for byTraffic in [false, true] {
                    for style in CloudflareAnalyticsPresentation.allCases {
                        try render(width: width, height: height, byTraffic: byTraffic, presentation: style, output: output)
                    }
                }
            }
        }
        for scale in [CGFloat(2), 3, 4] {
            for (width, height) in [(684, 1216), (1216, 684)] {
                for dark in [false, true] {
                    for byTraffic in [false, true] {
                        for style in CloudflareAnalyticsPresentation.allCases {
                            try renderNative(width: width, height: height, scale: scale, dark: dark,
                                byTraffic: byTraffic, presentation: style, output: output)
                        }
                    }
                    try renderNative(width: width, height: height, scale: scale, dark: dark,
                        byTraffic: true, presentation: .worldMap, output: output, longDomain: true)
                    for parts in [2, 3, 4] {
                        for half in [false, true] {
                            try renderNative(width: width, height: height, scale: scale, parts: parts,
                                halfWidth: half, dark: dark, byTraffic: true, presentation: .worldMap, output: output)
                        }
                    }
                }
            }
        }
        for (width, height) in [(684, 1216), (1216, 684)] {
            for dark in [false, true] {
                for state in ["stale", "missing", "huge", "long-regions"] {
                    try renderNative(width: width, height: height, scale: 3, dark: dark,
                        byTraffic: true, presentation: .worldMap, output: output, state: state)
                }
            }
        }
        for (width, height) in [(684, 1216), (1216, 684)] {
            for dark in [false, true] {
                for boundary: CGFloat in [44, 100, 135, 136, 143, 144, 250, 300, 320, 400] {
                    try renderNative(width: width, height: height, scale: 3, dark: dark,
                        byTraffic: true, presentation: .worldMap, output: output, overrideHeight: boundary)
                }
            }
        }
        // Keep every original fixed-height density/metric/presentation regression case;
        // the richer app scenarios above must not replace those exact boundary combinations.
        for scale in [CGFloat(2), 3, 4] {
            for (width, height) in [(684, 1216), (1216, 684)] {
                for byTraffic in [false, true] {
                    for style in CloudflareAnalyticsPresentation.allCases {
                        if scale == 3 && byTraffic && style == .worldMap { continue }
                        for boundary: CGFloat in [44, 100, 136, 250, 300, 320, 400] {
                            try renderNative(width: width, height: height, scale: scale,
                                byTraffic: byTraffic, presentation: style, output: output, overrideHeight: boundary)
                        }
                    }
                }
            }
        }
        for scale in [CGFloat(2), 3, 4] {
            try renderNative(width: 684, height: 1216, scale: scale,
                byTraffic: false, presentation: .worldMap, output: output, state: "missing", overrideHeight: 44)
            if scale != 3 {
                try renderNative(width: 1216, height: 684, scale: scale,
                    byTraffic: false, presentation: .worldMap, output: output, state: "missing")
            }
        }
        }
        let report: [String: Any] = ["checks": checks, "failures": failures, "render_cases": cases,
            "scope": "Actual current production layout/CoreText/map/metric-formatting with trace-only glyph observations; synthetic state, no user settings or network. Both Chinese and English; actual localized region names, explicit numeric locales and standard byte units; all three domain-case projections. Native dark/light, 2/3/4 density, long domain/region names, stale/missing/huge, 1/2/3/4 bands and half-width allocations. Legacy small-screen regressions retained."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("layout-trace.json"))
        print("Cloudflare app production renderer: \(checks) checks; \(failures.count) failures; \(cases.count) PNGs")
        if !failures.isEmpty { exit(1) }
    }
}
