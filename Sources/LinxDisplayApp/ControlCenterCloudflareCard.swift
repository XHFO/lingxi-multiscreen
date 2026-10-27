import AppKit
import Charts
import LinxDisplayCore
import SwiftUI

/// Dashboard data is laid out at the actual card size, without a device-frame bitmap.
struct ControlCenterCloudflareCard: View {
    @ObservedObject var model: AppModel
    let source: DeviceControlCenterDataSource
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @State private var showsDisplaySettings = false
    @State private var opensConnectionAfterDismiss = false

    private var saved: CloudflareAnalyticsSource? {
        guard case .cloudflare(let id) = source.destination else { return nil }
        return model.settings.cloudflareSources.first { $0.id == id }
    }
    var body: some View {
        Button { showsDisplaySettings = true } label: {
            if let saved {
                ControlCenterCloudflareContent(source: saved,
                    themeAccent: CloudflareDisplaySettingsPolicy.themeAccent(for: model.settings))
                    .equatable()
                    .frame(height: height)
                    .controlCenterGlassCard(hovering: hovering)
            } else {
                ContentUnavailableView("暂无统计数据", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity).frame(height: height)
                    .controlCenterGlassCard(hovering: hovering)
            }
        }
        .buttonStyle(ControlCenterCardButtonStyle())
        .onHover { hovering = $0 }
        .help(String(localized: "打开显示设置"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.title + ", " + source.status)
        .accessibilityHint(String(localized: "打开显示设置"))
        .accessibilityIdentifier("control-center-source-\(source.id)")
        .sheet(isPresented: $showsDisplaySettings, onDismiss: {
            guard opensConnectionAfterDismiss else { return }
            opensConnectionAfterDismiss = false
            action()
        }) {
            if case .cloudflare(let id) = source.destination {
                CloudflareDisplaySettingsView(model: model, sourceID: id,
                    onClose: { showsDisplaySettings = false },
                    onEditConnection: {
                        opensConnectionAfterDismiss = true
                        showsDisplaySettings = false
                    })
                    .controlCenterFloatingPresentationSurface()
            }
        }
    }
}

struct ControlCenterCloudflareContent: View, Equatable {
    let source: CloudflareAnalyticsSource
    var themeAccent: CGColor? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var config: CloudflareAnalyticsSettings { source.configuration }
    private var reading: CloudflareAnalyticsSnapshot? { source.snapshot.flatMap { $0.matches(config) ? $0 : nil } }
    private var language: CloudflareDisplayLanguage { config.displayLanguage }
    private var resolvedAccent: CGColor {
        config.resolvedAccentCG(themeAccent: config.accentTone == .system ? themeAccent : nil)
    }
    private var accent: Color { Color(cgColor: resolvedAccent) }
    private var domain: String {
        config.domainLetterCase.display([config.hostname, config.zoneName, source.name]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? source.name)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.themeAccent == rhs.themeAccent }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.45
            let roomy = geometry.size.height >= 480
            let compact = geometry.size.height < 340
            let inset: CGFloat = compact ? 14 : 20
            VStack(alignment: .leading, spacing: compact ? 6 : roomy ? 16 : 10) {
                HStack(spacing: 8) {
                    Label("Cloudflare", systemImage: "cloud.fill")
                        .font(compact ? .system(size: 12, weight: .semibold) : .subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(periodLabel).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, inset).padding(.top, compact ? 12 : 18)
                if let reading {
                    if wide {
                        HStack(alignment: .center, spacing: compact ? 14 : 22) {
                            Text(domain).font(compact ? .system(size: 18, weight: .bold) : .title2.weight(.bold))
                                .lineLimit(compact ? 1 : 2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            metrics(reading, roomy: false, compact: compact)
                                .frame(maxWidth: .infinity)
                        }.padding(.horizontal, inset)
                    } else {
                        Text(domain).font(compact ? .system(size: 18, weight: .bold) : roomy ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                            .lineLimit(compact ? 1 : 2).truncationMode(.middle).padding(.horizontal, inset)
                        metrics(reading, roomy: roomy, compact: compact).padding(.horizontal, inset)
                    }
                    if compact {
                        // Reserve real space for both visualizations. A flexible
                        // map must not squeeze the metrics or trend off a short card.
                        regionGraphic(reading, roomy: false, horizontalInset: inset)
                            .frame(height: max(44, geometry.size.height - (wide ? 154 : 182)))
                    } else {
                        regionGraphic(reading, roomy: roomy, horizontalInset: inset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                    // The trend uses the full card width in every size, including
                    // horizontal cards; it never sits inside a smaller image tile.
                    trend(reading, compact: compact, horizontalInset: inset)
                        .frame(height: compact ? 42 : roomy ? max(130, geometry.size.height * 0.24)
                               : max(58, geometry.size.height * (wide ? 0.23 : 0.19)))
                    HStack(spacing: 6) {
                        Text(language.text("最近统计", "LATEST READING"))
                        Spacer(minLength: 4)
                        Text(reading.sampledAt, style: .time)
                    }
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, inset).padding(.bottom, compact ? 12 : 16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: compact ? 28 : 40)).foregroundStyle(.secondary)
                        Text(language.text("暂无统计数据", "No analytics yet")).font(.headline)
                        Text(language.text("打开数据源设置以连接网站统计。", "Open source settings to connect website analytics."))
                            .font(.system(size: compact ? 12 : 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.padding(inset).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
    }

    private var periodLabel: String {
        switch config.period {
        case .day: return language.text("24 小时", "24 HOURS")
        case .week: return language.text("7 天", "7 DAYS")
        case .month: return language.text("30 天", "30 DAYS")
        }
    }
    private func metrics(_ snapshot: CloudflareAnalyticsSnapshot, roomy: Bool, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: compact ? 10 : 16) {
            metric(language.text("请求", "REQUESTS"), value: language.countText(snapshot.requests), roomy: roomy, compact: compact)
            metric(language.text("流量", "TRAFFIC"), value: language.bytesText(snapshot.bytes), roomy: roomy, compact: compact)
        }
    }
    private func metric(_ label: String, value: String, roomy: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(label).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: compact ? 22 : roomy ? 34 : 25, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.68)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func regionGraphic(_ snapshot: CloudflareAnalyticsSnapshot, roomy: Bool, horizontalInset: CGFloat) -> some View {
        if config.presentation == .worldMap {
            VStack(spacing: 2) {
                Canvas { context, size in
                    context.withCGContext { cg in
                        // The shared offline map expects y-up; SwiftUI Canvas is y-down.
                        cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
                        CloudflareWorldMap.draw(cg, in: CGRect(origin: .zero, size: size),
                            regions: snapshot.regions, byTraffic: config.rankByTraffic,
                            ink: scheme == .dark ? NSColor.white.cgColor : NSColor.black.cgColor,
                            accent: resolvedAccent, highContrast: contrast == .increased)
                    }
                }
                .accessibilityLabel(language.text("全球热区，按国家或地区汇总", "Global activity, aggregated by country or region"))
                if roomy, let top = snapshot.rankedRegions(byTraffic: config.rankByTraffic).first {
                    HStack(spacing: 8) {
                        Text(language.text("首位地区", "TOP REGION")).foregroundStyle(.secondary)
                        Text(language.regionName(top.code)).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text(config.rankByTraffic ? language.bytesText(top.bytes) : language.countText(top.requests))
                            .monospacedDigit()
                    }.font(.caption).padding(.horizontal, horizontalInset)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: roomy ? 14 : 7) {
                ForEach(Array(snapshot.rankedRegions(byTraffic: config.rankByTraffic).prefix(roomy ? 6 : 3))) { region in
                    HStack(spacing: 12) {
                        Text(language.regionName(region.code)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(config.rankByTraffic ? language.bytesText(region.bytes) : language.countText(region.requests))
                            .monospacedDigit().fontWeight(.semibold).lineLimit(1)
                    }.font(roomy ? .body : .caption)
                }
            }.padding(.horizontal, horizontalInset).frame(maxHeight: .infinity, alignment: .center)
        }
    }
    private func trend(_ snapshot: CloudflareAnalyticsSnapshot, compact: Bool, horizontalInset: CGFloat) -> some View {
        let points = snapshot.trend.enumerated().compactMap { offset, point -> (Int, Double)? in
            let value = config.rankByTraffic ? point.bytes : point.requests
            return value.isFinite && value >= 0 ? (offset, value) : nil
        }
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack {
                Text(language.text(config.rankByTraffic ? "流量趋势" : "请求趋势", config.rankByTraffic ? "TRAFFIC TREND" : "REQUEST TREND"))
                Spacer()
                Text(periodLabel)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, horizontalInset)
            if points.isEmpty {
                Text(language.text("暂无趋势数据", "No trend data"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(points, id: \.0) { point in
                    AreaMark(x: .value("Time", point.0), y: .value("Value", point.1))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.0), y: .value("Value", point.1))
                        .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    if points.count == 1 {
                        PointMark(x: .value("Time", point.0), y: .value("Value", point.1)).foregroundStyle(accent)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartXScale(domain: 0...max(1, snapshot.trend.count - 1), range: .plotDimension(padding: 0))
                .chartYScale(domain: 0...max(1, (points.map(\.1).max() ?? 0) * 1.08), range: .plotDimension(padding: 0))
                .accessibilityLabel(language.text("网站访问趋势", "Website traffic trend"))
            }
        }
    }
}
