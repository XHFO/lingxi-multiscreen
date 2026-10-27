import AppKit
import LinxDisplayCore
import SwiftUI

/// Apply only presentation fields to the current source record. A delayed control
/// update must never replace a newer reading, connection, query or source name.
enum CloudflareDisplaySettingsPolicy {
    static func applying(_ display: CloudflareAnalyticsSettings,
                         to current: CloudflareAnalyticsSource) -> CloudflareAnalyticsSource {
        var result = current
        result.configuration.presentation = display.presentation
        result.configuration.rankByTraffic = display.rankByTraffic
        result.configuration.domainLetterCase = display.domainLetterCase
        result.configuration.displayLanguage = display.displayLanguage
        result.configuration.accentTone = display.accentTone
        result.configuration.customAccentHex = display.customAccentHex
        return result
    }

    static func themeAccent(for settings: AppSettings) -> CGColor {
        let palette = ScreenThemes.resolved(theme: settings.cardTheme,
            backgroundTone: settings.backgroundTone, customBackgroundHex: settings.customBackgroundHex,
            accentTone: settings.accentTone, customAccentHex: settings.customAccentHex,
            softwareIsDark: settings.softwareIsDark, renderingMode: settings.cardRenderingMode)
        return CGColor(red: palette.accent.0, green: palette.accent.1, blue: palette.accent.2, alpha: 1)
    }
}

/// The same controls serve the website workspace and the dashboard's direct style
/// entry. No connection or query fields are exposed by this component.
struct CloudflareDisplayOptionsView: View {
    @Binding var configuration: CloudflareAnalyticsSettings
    var showsLanguageAndMetric = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

/// A direct, source-scoped presentation editor. Connection editing is a secondary
/// action; opening this view never selects a source or reads saved credentials.
struct CloudflareDisplaySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let sourceID: UUID
    let onClose: () -> Void
    let onEditConnection: () -> Void

    init(model: AppModel, sourceID: UUID, onClose: @escaping () -> Void,
         onEditConnection: @escaping () -> Void) {
        self.model = model; self.settings = model.settings; self.sourceID = sourceID
        self.onClose = onClose; self.onEditConnection = onEditConnection
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
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cloudflare-display-done")
            }.padding(22)
            Divider()
            if let source {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            CloudflareDisplayOptionsView(configuration: configuration(for: source))
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
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("实时预览").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        ControlCenterCloudflareContent(source: source,
                            themeAccent: CloudflareDisplaySettingsPolicy.themeAccent(for: settings))
                            .equatable()
                            .controlCenterGlassCard(hovering: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("cloudflare-display-preview")
                    }.padding(22).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("数据源已移除", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, idealWidth: 980, maxWidth: 1200, minHeight: 600, idealHeight: 720, maxHeight: 900)
        .accessibilityIdentifier("cloudflare-display-settings")
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
