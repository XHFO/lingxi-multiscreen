import AppKit
import LinxDisplayCore
import SwiftUI

struct ControlCenterWeatherCard: View {
    @ObservedObject var model: AppModel
    let source: DeviceControlCenterDataSource
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        let snapshot = model.settings.weatherSnapshot.flatMap { $0.matches(model.settings.weather) ? $0 : nil }
        Button(action: action) {
            ControlCenterWeatherContent(city: source.title, snapshot: snapshot)
                .equatable().frame(height: height)
                .controlCenterGlassCard(hovering: hovering)
        }
        .buttonStyle(ControlCenterCardButtonStyle())
        .onHover { hovering = $0 }
        .help(String(localized: "打开天气设置"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.title + ", " + source.status)
        .accessibilityHint(String(localized: "打开天气设置"))
        .accessibilityIdentifier("control-center-source-\(source.id)")
    }
}

struct ControlCenterWeatherContent: View, Equatable {
    let city: String
    let snapshot: WeatherSnapshot?
    @Environment(\.colorSchemeContrast) private var contrast
    private var condition: WeatherCondition { snapshot?.condition ?? .unknown }
    private var night: Bool { snapshot?.isDay == false }
    private var palette: WeatherCardPalette { condition.palette(dark: night) }
    private var foreground: Color { night ? .white : color(palette.foreground) }
    private var secondary: Color { foreground.opacity(contrast == .increased ? 1 : 0.85) }
    private var symbol: String {
        if night && condition == .sunny { return "moon.stars.fill" }
        if night && condition == .cloudy { return "cloud.moon.fill" }
        return condition.symbolName
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.city == rhs.city && lhs.snapshot == rhs.snapshot }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.45
            let roomy = geometry.size.height > 480
            let compact = geometry.size.height < 340
            ZStack {
                LinearGradient(colors: night ? [color(0x142640), color(0x304D6A)]
                               : [color(palette.background), color(palette.backgroundBottom)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: compact ? 10 : roomy ? 24 : 16) {
                    HStack(spacing: 8) {
                        Label(city, systemImage: "location.fill")
                            .font(compact ? .system(size: 13, weight: .semibold) : .headline)
                            .lineLimit(compact ? 1 : 2)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    if let snapshot, snapshot.temperature.isFinite {
                        if wide {
                            HStack(alignment: .center, spacing: compact ? 14 : 24) {
                                current(snapshot, roomy: false, compact: compact)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                weatherSymbol(side: min(compact ? 100 : 150, geometry.size.height * 0.4))
                                    .frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: compact ? 14 : 20) { details(snapshot, compact: compact) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            HStack(alignment: .center, spacing: 12) {
                                current(snapshot, roomy: roomy, compact: compact)
                                Spacer(minLength: 0)
                                weatherSymbol(side: min(compact ? 72 : roomy ? 160 : 92, geometry.size.width * 0.3))
                            }.frame(maxHeight: .infinity)
                            HStack(alignment: .top, spacing: compact ? 12 : 20) { details(snapshot, compact: compact) }
                        }
                        HStack(spacing: 6) {
                            Text(snapshot.isStale ? "上次天气" : "Open-Meteo")
                            Spacer(minLength: 0)
                            Text(snapshot.updatedAt, style: .time)
                        }.font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "cloud.sun.fill").font(.system(size: compact ? 28 : 40))
                            Text("暂无天气数据").font(.headline)
                            Text("打开天气设置，选择城市并更新。")
                                .font(.system(size: compact ? 12 : 13)).multilineTextAlignment(.center)
                        }.foregroundStyle(foreground).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(compact ? 14 : roomy ? 26 : 20)
            }
            .foregroundStyle(foreground)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
    private func current(_ snapshot: WeatherSnapshot, roomy: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : roomy ? 12 : 7) {
            Text(snapshot.temperature.formatted(.number.precision(.fractionLength(0))) + "°")
                .font(.system(size: compact ? 56 : roomy ? 112 : 68, weight: .light, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(LocalizedStringKey(snapshot.description))
                .font(compact ? .system(size: 15, weight: .medium) : roomy ? .title2.weight(.medium) : .title3.weight(.medium))
                .lineLimit(2)
            Text("\(temperature(snapshot.low)) / \(temperature(snapshot.high))")
                .font(compact ? .system(size: 12).monospacedDigit() : .subheadline.monospacedDigit()).foregroundStyle(secondary)
        }
    }
    @ViewBuilder private func details(_ snapshot: WeatherSnapshot, compact: Bool) -> some View {
        metric("体感", value: temperature(snapshot.apparent), symbol: "thermometer.medium", compact: compact)
        metric("降水概率", value: "\(min(100, max(0, snapshot.rainProbability)))%", symbol: "drop.fill", compact: compact)
    }
    private func metric(_ label: LocalizedStringKey, value: String, symbol: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Label(label, systemImage: symbol).font(.system(size: compact ? 11 : 12)).foregroundStyle(secondary)
            Text(value).font(compact ? .system(size: 18, weight: .semibold) : .title3.weight(.semibold)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func weatherSymbol(side: CGFloat) -> some View {
        Image(systemName: symbol).symbolRenderingMode(.palette)
            .foregroundStyle(night ? color(0xF9DD8D) : color(palette.symbol), night ? Color.white : color(palette.cloud))
            .font(.system(size: side * 0.8, weight: .regular)).frame(width: side, height: side)
            .accessibilityHidden(true)
    }
    private func temperature(_ value: Double) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) + "°" : "—"
    }
    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
