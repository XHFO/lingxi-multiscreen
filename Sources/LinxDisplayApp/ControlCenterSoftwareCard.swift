import SwiftUI
import LinxDisplayCore

/// 中控面板中的软件卡片。按 1×1 / 2×1 / 1×2 / 2×2 / 2×3 的实际尺寸切换排版，
/// 具体显示字段由每张卡片的「自定义显示内容」决定。
struct ControlCenterSoftwareCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let source: DeviceControlCenterDataSource
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    init(model: AppModel, source: DeviceControlCenterDataSource,
         height: CGFloat, action: @escaping () -> Void) {
        self.model = model
        self._settings = ObservedObject(wrappedValue: model.settings)
        self.source = source
        self.height = height
        self.action = action
    }

    private var mode: DisplayMode? {
        guard case let .software(mode) = source.destination else { return nil }
        return mode
    }

    var body: some View {
        GeometryReader { geometry in
            let summary = mode.map { ControlCenterSoftwareSummary.make(model: model, settings: settings, mode: $0) }
                ?? ControlCenterSoftwareSummary(title: source.title, icon: source.symbolName,
                                                headline: nil, headlineLabel: nil, metrics: [],
                                                body: source.subtitle, footer: source.status,
                                                progress: nil, fields: [])
            let size = geometry.size
            let wide = size.width > size.height * 1.32
            let large = size.width >= 560 && size.height >= 540
            let tall = size.height > size.width * 1.30
            Button(action: action) {
                layout(summary: summary, size: size, wide: wide, large: large, tall: tall)
                    .padding(padding(for: size, wide: wide, large: large))
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .controlCenterGlassCard(hovering: hovering)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(ControlCenterCardButtonStyle())
            .onHover { hovering = $0 }
            .help("打开\(summary.title)设置；右键可自定义显示内容")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(summary.title)，\(summary.status)")
            .accessibilityHint("打开软件卡片设置")
            .accessibilityIdentifier("control-center-source-\(source.id)")
        }
    }

    // MARK: - 排版

    @ViewBuilder
    private func layout(summary: ControlCenterSoftwareSummary, size: CGSize,
                        wide: Bool, large: Bool, tall: Bool) -> some View {
        if wide {
            wideLayout(summary, size: size)
        } else if large {
            largeLayout(summary, size: size)
        } else if tall {
            tallLayout(summary, size: size)
        } else {
            compactLayout(summary, size: size)
        }
    }

    /// 1×1：标题、主数值、少量指标与状态，信息按优先级取舍。
    private func compactLayout(_ summary: ControlCenterSoftwareSummary, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(summary)
            Spacer(minLength: 0)
            hero(summary, size: size, maxSize: min(size.width * 0.15, 42), bodySize: 20)
            if let progress = summary.progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(Color.accentColor)
            }
            if summary.headline != nil || !summary.metrics.isEmpty {
                metricGrid(Array(summary.metrics.prefix(2)), columns: 2, compact: true)
            }
            bodyText(summary, lineLimit: 2, compact: true)
            Spacer(minLength: 0)
            footer(summary)
        }
    }

    /// 1×2：纵向空间更大，主数值 + 指标网格 + 正文。
    private func tallLayout(_ summary: ControlCenterSoftwareSummary, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(summary)
            hero(summary, size: size, maxSize: min(size.width * 0.17, 52), bodySize: 24)
            if let progress = summary.progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(Color.accentColor)
            }
            metricGrid(Array(summary.metrics.prefix(5)), columns: 2, compact: false)
            bodyText(summary, lineLimit: 6, compact: false)
            Spacer(minLength: 0)
            footer(summary)
        }
    }

    /// 2×1：横向排版，左侧主数值，右侧指标/正文。
    private func wideLayout(_ summary: ControlCenterSoftwareSummary, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(summary)
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    hero(summary, size: size, maxSize: min(size.height * 0.16, 50), bodySize: 18)
                    if let progress = summary.progress {
                        ProgressView(value: min(max(progress, 0), 1)).tint(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    metricGrid(Array(summary.metrics.prefix(4)), columns: summary.metrics.count > 2 ? 2 : 1, compact: true)
                    bodyText(summary, lineLimit: 3, compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            footer(summary)
        }
    }

    /// 2×2 / 2×3：左侧大数值，右侧完整指标网格；空间足够时展示更多字段。
    private func largeLayout(_ summary: ControlCenterSoftwareSummary, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(summary)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    hero(summary, size: size, maxSize: min(size.width * 0.12, 66), bodySize: 26)
                    if let progress = summary.progress {
                        ProgressView(value: min(max(progress, 0), 1)).tint(Color.accentColor)
                    }
                    bodyText(summary, lineLimit: 8, compact: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                metricGrid(Array(summary.metrics.prefix(8)), columns: 2, compact: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            footer(summary)
        }
    }

    // MARK: - 组件

    private func header(_ summary: ControlCenterSoftwareSummary) -> some View {
        HStack(spacing: 8) {
            Label(summary.title, systemImage: summary.icon)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func hero(_ summary: ControlCenterSoftwareSummary, size: CGSize,
                      maxSize: CGFloat, bodySize: CGFloat) -> some View {
        Group {
            if let headline = summary.headline, !headline.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: max(22, min(maxSize, 68)),
                                      weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                    if let label = summary.headlineLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: max(11, min(maxSize * 0.24, 15))))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if let body = summary.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: bodySize, weight: .semibold))
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
            } else if summary.metrics.isEmpty {
                Text("未选择显示内容")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metricGrid(_ metrics: [ControlCenterSoftwareMetric], columns: Int,
                            compact: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 80), spacing: 12),
                                 count: max(1, min(columns, 2))),
                  alignment: .leading, spacing: compact ? 7 : 10) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label)
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(metric.value)
                        .font(.system(size: compact ? 13 : 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func bodyText(_ summary: ControlCenterSoftwareSummary, lineLimit: Int,
                          compact: Bool) -> some View {
        if let body = summary.body, !body.isEmpty, summary.headline != nil {
            Text(body)
                .font(.system(size: compact ? 12 : 15))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ summary: ControlCenterSoftwareSummary) -> some View {
        Text(summary.footer ?? summary.headlineLabel ?? "打开设置")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func padding(for size: CGSize, wide: Bool, large: Bool) -> EdgeInsets {
        if wide { return EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18) }
        if large { return EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22) }
        if size.height > size.width { return EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16) }
        return EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14)
    }
}
