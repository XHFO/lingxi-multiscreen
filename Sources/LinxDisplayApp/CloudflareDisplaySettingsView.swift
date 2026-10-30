import AppKit
import LinxDisplayCore
import SwiftUI

/// Apply only presentation fields to the current source record. A delayed control
/// update must never replace a newer reading, connection, query or source name.
enum CloudflareDisplaySettingsPolicy {
    static func applying(_ display: CloudflareAnalyticsSettings,
                         to current: CloudflareAnalyticsSource) -> CloudflareAnalyticsSource {
        CloudflareSourceDraftPolicy.applyingDisplayPreferences(display, to: current)
    }

    static func themeAccent(for settings: AppSettings) -> CGColor {
        let palette = ScreenThemes.resolved(theme: settings.cardTheme,
            backgroundTone: settings.backgroundTone, customBackgroundHex: settings.customBackgroundHex,
            accentTone: settings.accentTone, customAccentHex: settings.customAccentHex,
            softwareIsDark: settings.softwareIsDark, renderingMode: settings.cardRenderingMode)
        return CGColor(red: palette.accent.0, green: palette.accent.1, blue: palette.accent.2, alpha: 1)
    }
}

/// Shared card settings. Time range has its own binding because it changes the
/// query; presentation edits must not overwrite a concurrently changed range.
struct CloudflareDisplayOptionsView: View {
    @Binding var configuration: CloudflareAnalyticsSettings
    var showsLanguageAndMetric = true
    var showsPeriod = true
    var onPeriodChange: ((CloudflareAnalyticsPeriod) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsPeriod {
                field("统计范围") {
                    ViewThatFits(in: .horizontal) {
                        periodPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                        periodPicker.pickerStyle(.menu)
                    }
                }
            }
            field("更新频率") {
                HStack {
                    Text("每 \(configuration.refreshMinutes) 分钟更新")
                    Spacer(minLength: 12)
                    Stepper("更新频率", value: $configuration.refreshMinutes, in: 5...60, step: 5)
                        .accessibilityValue("\(configuration.refreshMinutes) 分钟")
                        .accessibilityIdentifier("cloudflare-display-refresh-interval")
                }
            }
            field("展示样式") {
                Picker("展示样式", selection: $configuration.presentation) {
                    ForEach(CloudflareAnalyticsPresentation.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("cloudflare-display-presentation")
            }
            if showsLanguageAndMetric {
                field("统计指标") {
                    Picker("统计指标", selection: $configuration.rankByTraffic) {
                        Text("流量").tag(true)
                        Text("请求数").tag(false)
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("cloudflare-display-metric")
                }
                field("显示语言") {
                    Picker("显示语言", selection: $configuration.displayLanguage) {
                        ForEach(CloudflareDisplayLanguage.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("cloudflare-display-language")
                }
            }
            field("域名大小写") {
                Picker("域名大小写", selection: $configuration.domainLetterCase) {
                    ForEach(CloudflareDomainLetterCase.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("cloudflare-display-letter-case")
            }
            field("强调色") {
                Picker("强调色", selection: $configuration.accentTone) {
                    ForEach(AccentTone.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                    .accessibilityIdentifier("cloudflare-display-accent")
            }
            if configuration.accentTone == .custom {
                ColorPicker("自定义强调色", selection: customAccent, supportsOpacity: false)
                    .accessibilityIdentifier("cloudflare-display-custom-accent")
            }
        }
    }

    private var periodPicker: some View {
        Picker("统计范围", selection: Binding(get: { configuration.period }, set: { period in
            if let onPeriodChange { onPeriodChange(period) }
            else { configuration.period = period }
        })) {
            ForEach(CloudflareAnalyticsPeriod.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("cloudflare-display-period")
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customAccent: Binding<Color> {
        Binding(get: {
            if let hex = configuration.customAccentHex, let rgb = HexColor.parse(hex) {
                return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
            }
            return Color(red: 1, green: 97.0 / 255, blue: 1.0 / 255)
        }, set: { color in
            let converted = NSColor(color).usingColorSpace(.sRGB) ?? .orange
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            configuration.customAccentHex = HexColor.string(from: red, green, blue)
        })
    }
}

/// A source-scoped settings editor. Opening it never selects another source or
/// reads credentials. An explicit range change refreshes the active source.
struct CloudflareDisplaySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let sourceID: UUID
    var compact = false
    let onClose: () -> Void
    let onEditConnection: () -> Void

    init(model: AppModel, sourceID: UUID, compact: Bool = false, onClose: @escaping () -> Void,
         onEditConnection: @escaping () -> Void) {
        self.model = model; self.settings = model.settings; self.sourceID = sourceID
        self.compact = compact; self.onClose = onClose; self.onEditConnection = onEditConnection
    }

    private var source: CloudflareAnalyticsSource? { settings.cloudflareSources.first { $0.id == sourceID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloudflare 显示设置").font(.title2.weight(.semibold))
                    if let source { Text(source.name).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 12)
                if !compact {
                    Button("完成", action: onClose).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cloudflare-display-done")
                }
            }.padding(compact ? 0 : 22).padding(.bottom, compact ? 18 : 0)
            Divider()
            if let source {
                GeometryReader { geometry in
                    if geometry.size.width >= 720 {
                        HStack(spacing: 0) {
                            ScrollView { options(for: source).padding(22) }
                                .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                            Divider()
                            preview(for: source).padding(22)
                                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                options(for: source)
                                preview(for: source).frame(height: 420)
                            }.padding(.vertical, 22).padding(.horizontal, compact ? 0 : 22)
                        }
                    }
                }
            } else {
                ContentUnavailableView("数据源已移除", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: compact ? 0 : 760, idealWidth: compact ? nil : 980,
               maxWidth: compact ? .infinity : 1200, minHeight: compact ? 0 : 600,
               idealHeight: compact ? nil : 720, maxHeight: compact ? .infinity : 900)
        .accessibilityIdentifier("cloudflare-display-settings")
    }

    private func options(for source: CloudflareAnalyticsSource) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            CloudflareDisplayOptionsView(configuration: configuration(for: source),
                                         onPeriodChange: updatePeriod)
            Text("修改会自动保存，并用于使用此来源的卡片。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("网站与连接").font(.subheadline.weight(.medium))
                Text("更换网站或 API Token，请打开连接设置。调整显示样式无需重新登录。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("连接设置…", action: onEditConnection)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cloudflare-display-connection")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preview(for source: CloudflareAnalyticsSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("实时预览").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                if settings.cloudflareSourceID == sourceID, model.cloudflareBusy {
                    ProgressView().controlSize(.small)
                }
            }
            ControlCenterCloudflareContent(source: source,
                themeAccent: CloudflareDisplaySettingsPolicy.themeAccent(for: settings))
                .equatable()
                .controlCenterGlassCard(hovering: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("cloudflare-display-preview")
        }
    }

    private func updatePeriod(_ period: CloudflareAnalyticsPeriod) {
        guard let current = source, current.configuration.period != period else { return }
        let updated = CloudflareSourceDraftPolicy.applyingPeriod(period, to: current)
        guard settings.updateCloudflareSource(updated) else { return }
        model.invalidateCloudflarePreview()
        guard settings.cloudflareSourceID == sourceID else { return }
        model.cloudflareLastAttempt = nil
        model.cloudflareStatus = ""
        guard model.backgroundServicesEnabled else { return }
        // An in-flight request is guarded by hasSameQuery; the normal scheduler
        // picks up the new range after it finishes instead of accepting old data.
        Task { await model.refreshCloudflare() }
    }

    private func configuration(for fallback: CloudflareAnalyticsSource) -> Binding<CloudflareAnalyticsSettings> {
        Binding(get: { source?.configuration ?? fallback.configuration }, set: { display in
            guard let current = source else { return }
            let updated = CloudflareDisplaySettingsPolicy.applying(display, to: current)
            guard updated != current, settings.updateCloudflareSource(updated) else { return }
            model.invalidateCloudflarePreview()
        })
    }
}

/// Saved sources open their editable preferences immediately. Credential editing
/// is an explicit secondary action and never runs when adjusting card settings.
struct CloudflareSourceSettingsWorkspace: View {
    @ObservedObject var model: AppModel
    let sourceID: UUID
    var compact = true
    let onClose: () -> Void
    @State private var showsConnectionSettings = false

    var body: some View {
        CloudflareDisplaySettingsView(model: model, sourceID: sourceID, compact: compact,
            onClose: onClose, onEditConnection: { showsConnectionSettings = true })
            .sheet(isPresented: $showsConnectionSettings) {
                if let source = model.settings.cloudflareSources.first(where: { $0.id == sourceID }) {
                    CloudflareSourceEditor(model: model, source: source) { showsConnectionSettings = false }
                } else {
                    ContentUnavailableView("数据源已移除", systemImage: "network")
                }
            }
    }
}
