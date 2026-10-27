import CoreGraphics
import Foundation

/// Offline country-level schematic. Dot brightness and size encode the selected metric;
/// no individual request location is inferred from aggregated country statistics.
public enum CloudflareWorldMap {
    public struct Coverage: Equatable {
        public let mapped: Int
        public let unmapped: Int
    }
    public static func coverage(regions: [CloudflareAnalyticsSnapshot.Region], byTraffic: Bool) -> Coverage {
        let active = Set(regions.filter { value($0, byTraffic: byTraffic) > 0 }.map { $0.code.uppercased() })
        return Coverage(mapped: active.filter { CloudflareWorldDots.countries[$0] != nil }.count,
                        unmapped: active.filter { CloudflareWorldDots.countries[$0] == nil }.count)
    }
    private static func value(_ region: CloudflareAnalyticsSnapshot.Region, byTraffic: Bool) -> Double {
        let number = byTraffic ? region.bytes : region.requests
        return number.isFinite && number > 0 ? number : 0
    }
    /// Bounds use ordinary Core Graphics coordinates. The same static pixels are used by
    /// native previews and physical displays, including 16-gray e-paper quantization.
    public static func draw(_ context: CGContext, in bounds: CGRect,
                            regions: [CloudflareAnalyticsSnapshot.Region], byTraffic: Bool,
                            ink: CGColor, accent: CGColor, highContrast: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var values: [String: Double] = [:]
        for region in regions {
            let code = region.code.uppercased()
            values[code] = min((values[code] ?? 0) + value(region, byTraffic: byTraffic), Double.greatestFiniteMagnitude)
        }
        let peak = max(values.filter { CloudflareWorldDots.countries[$0.key] != nil }.map(\.value).max() ?? 0, 1)
        let step = min(bounds.width / CGFloat(CloudflareWorldDots.columns), bounds.height / CGFloat(CloudflareWorldDots.rows))
        let width = step * CGFloat(CloudflareWorldDots.columns), height = step * CGFloat(CloudflareWorldDots.rows)
        let origin = CGPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: bounds)
        for code in CloudflareWorldDots.countries.keys.sorted() {
            let value = values[code] ?? 0
            let strength = value > 0 ? sqrt(value / peak) : 0
            let radius = step * (value > 0 ? 0.31 + 0.15 * strength : (highContrast ? 0.25 : 0.20))
            let color = value > 0 ? accent : ink
            let opacity: CGFloat = highContrast
                ? (value > 0 ? 0.74 + 0.26 * strength : 0.50)
                : (value > 0 ? 0.45 + 0.55 * strength : 0.23)
            context.setFillColor(color.copy(alpha: opacity) ?? color)
            for encoded in CloudflareWorldDots.countries[code]! {
                let column = Int(encoded) % CloudflareWorldDots.columns, row = Int(encoded) / CloudflareWorldDots.columns
                let point = CGPoint(x: origin.x + (CGFloat(column) + 0.5) * step,
                                    y: origin.y + height - (CGFloat(row) + 0.5) * step)
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }
}
