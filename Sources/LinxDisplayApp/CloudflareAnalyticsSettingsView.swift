import SwiftUI
import AppKit
import Charts
import LinxDisplayCore

extension AppModel {
    func refreshCloudflareIfDue(now: Date) {
        guard settings.cloudflare.isValid, !cloudflareBusy else { return }
        if cloudflareRequestKey?.hasSameQuery(as: settings.cloudflare) != true || cloudflareRequestSourceID != settings.cloudflareSourceID {
            cloudflareRequestKey = settings.cloudflare; cloudflareRequestSourceID = settings.cloudflareSourceID; cloudflareLastAttempt = nil
        }
        guard settings.cloudflare.isRefreshDue(lastAttempt: cloudflareLastAttempt, now: now) else { return }
        Task { @MainActor [weak self] in await self?.refreshCloudflare() }
    }

    func refreshCloudflare() async {
        guard !cloudflareBusy else { return }
        let configuration = settings.cloudflare
        let sourceID = settings.cloudflareSourceID
        guard configuration.isValid else { cloudflareStatus = CloudflareAnalyticsError.invalidConfiguration.localizedDescription; return }
        let token = CloudflareAnalyticsSecretStore.read(id: configuration.credentialID)
        guard !token.isEmpty else { cloudflareStatus = CloudflareAnalyticsError.missingToken.localizedDescription; cloudflareLastAttempt = Date(); return }
        let generation = cloudflareCredentialGeneration
        cloudflareBusy = true; cloudflareLastAttempt = Date(); cloudflareRequestKey = configuration; cloudflareRequestSourceID = sourceID
        defer { cloudflareBusy = false }
        do {
            let result = try await CloudflareAnalyticsClient.fetch(configuration, token: token)
            guard sourceID == settings.cloudflareSourceID, configuration.hasSameQuery(as: settings.cloudflare), generation == cloudflareCredentialGeneration else { return }
            settings.cloudflareSnapshot = result
            cloudflareStatus = "已更新 · Cloudflare Analytics"
            invalidateCloudflarePreview()
        } catch {
            guard sourceID == settings.cloudflareSourceID, configuration.hasSameQuery(as: settings.cloudflare), generation == cloudflareCredentialGeneration else { return }
            cloudflareStatus = error is CloudflareAnalyticsError ? error.localizedDescription : "网站统计更新失败，已保留上次数据。"
        }
    }
}

/// A website workspace uses the existing shared source; credentials stay in device management.
/// 网站工作台沿用共用数据源；连接凭据仍在设备管理中维护。
struct CloudflareAnalyticsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDisplaySettings = false

    init(model: AppModel) { self.model = model; self.settings = model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            languagePicker
            if settings.cloudflareSources.isEmpty {
                emptySource
            } else {
                websiteHeader
                if settings.cloudflareSources.count > 1 {
                    Picker(copy("网站", "Website"), selection: sourceBinding) {
                        ForEach(settings.cloudflareSources) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                }
                scopePicker
                if let snapshot {
                    summary(snapshot)
                    trend(snapshot)
                    Divider()
                    regionRanking(snapshot)
                } else {
                    emptyReading
                }
                if !model.cloudflareStatus.isEmpty && model.cloudflareStatus != "已更新 · Cloudflare Analytics" {
                    Label(statusMessage, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                displaySettings
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(accent)
    }

    private var snapshot: CloudflareAnalyticsSnapshot? {
        settings.cloudflareSnapshot.flatMap { $0.matches(settings.cloudflare) ? $0 : nil }
    }

    private var websiteName: String {
        let value = settings.cloudflare.hostname.isEmpty ? settings.cloudflare.zoneName : settings.cloudflare.hostname
        guard !value.isEmpty else { return copy("网站流量", "Website analytics") }
        return settings.cloudflare.domainLetterCase.display(value)
    }

    private var accent: Color {
        if let rgb = AppearanceResolver.accentRGB(tone: settings.cloudflare.accentTone,
                                                  customHex: settings.cloudflare.customAccentHex) {
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        return CloudflareWorkspaceTheme.accent(in: colorScheme)
    }

    private var language: CloudflareDisplayLanguage { settings.cloudflare.displayLanguage }
    private var contentLocale: Locale { language.locale }
    private func copy(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(contentLocale))
    }

    private var languagePicker: some View {
        HStack(spacing: 12) {
            Text(copy("显示语言", "Display language")).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker(copy("显示语言", "Display language"), selection: $settings.cloudflare.displayLanguage) {
                ForEach(CloudflareDisplayLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 156)
            .accessibilityLabel(copy("Cloudflare 显示语言", "Cloudflare display language"))
        }
    }

    private func periodTitle(_ period: CloudflareAnalyticsPeriod) -> String {
        switch period {
        case .day: return copy("最近 24 小时", "Last 24 hours")
        case .week: return copy("最近 7 天", "Last 7 days")
        case .month: return copy("最近 30 天", "Last 30 days")
        }
    }

    private var statusMessage: String {
        guard language == .english else { return model.cloudflareStatus }
        switch model.cloudflareStatus {
        case CloudflareAnalyticsError.invalidConfiguration.localizedDescription:
            return "Enter a 32-character Zone ID and a hostname without a URL scheme."
        case CloudflareAnalyticsError.missingToken.localizedDescription:
            return "Save a Cloudflare API token with read-only Analytics access."
        case CloudflareAnalyticsError.authentication.localizedDescription:
            return "Cloudflare denied access. Check the token, expiration date, and allowed website."
        case CloudflareAnalyticsError.rateLimited.localizedDescription:
            return "Cloudflare is limiting requests. Previous data is retained; try again later."
        case CloudflareAnalyticsError.deniedDataset.localizedDescription:
            return "No data was returned. Check Analytics permissions or choose a shorter period."
        case CloudflareAnalyticsError.malformed.localizedDescription:
            return "Cloudflare returned incomplete statistics. Previous data is retained."
        case CloudflareAnalyticsError.transport.localizedDescription:
            return "Unable to connect to Cloudflare. Previous data is retained."
        default:
            return "Website statistics could not be updated. Previous data is retained; try again."
        }
    }

    private var sourceBinding: Binding<UUID?> {
        Binding(get: { settings.cloudflareSourceID }, set: { id in
            guard let id, settings.selectCloudflareSource(id) else { return }
            model.cloudflareCredentialGeneration += 1
            model.cloudflareLastAttempt = nil
            model.cloudflareStatus = ""
            model.invalidateCloudflarePreview()
            Task { await model.refreshCloudflare() }
        })
    }

    private var websiteHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("CLOUDFLARE", systemImage: "cloud.fill")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(accent)
                Text(websiteName)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(3).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(websiteName)
                    .fixedSize(horizontal: false, vertical: true)
                if let snapshot {
                    Text(copy("更新于 \(dateText(snapshot.sampledAt))", "Updated \(dateText(snapshot.sampledAt))"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(copy("选择时间范围，查看网站的请求与流量。", "Choose a period to explore requests and data transfer."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await model.refreshCloudflare() } } label: {
                HStack(spacing: 6) {
                    if model.cloudflareBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(model.cloudflareBusy ? copy("更新中", "Refreshing") : copy("更新", "Refresh"))
                }
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
            .disabled(model.cloudflareBusy || !settings.cloudflare.isValid)
            .accessibilityLabel(copy("更新网站统计", "Refresh website statistics"))
            .help(copy("从 Cloudflare 更新当前网站统计", "Refresh this website's statistics from Cloudflare"))
        }
    }

    private var scopePicker: some View {
        ViewThatFits(in: .horizontal) {
            periodPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
            periodPicker.pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodPicker: some View {
        Picker(copy("统计范围", "Time range"), selection: $settings.cloudflare.period) {
            ForEach(CloudflareAnalyticsPeriod.allCases) { Text(periodTitle($0)).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel(copy("统计范围", "Time range"))
    }

    private func summary(_ sample: CloudflareAnalyticsSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), alignment: .leading)], alignment: .leading, spacing: 12) {
            metric(copy("请求数", "Requests"), value: CloudflareAnalyticsSnapshot.countText(sample.requests, language: language), symbol: "arrow.up.arrow.down")
            metric(copy("响应流量", "Data transfer"), value: CloudflareAnalyticsSnapshot.bytesText(sample.bytes, language: language), symbol: "network")
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.largeTitle.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(16)
        .background(CloudflareWorkspaceTheme.orange.opacity(colorScheme == .dark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.22 : 0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func trend(_ sample: CloudflareAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(settings.cloudflare.rankByTraffic ? copy("流量趋势", "Data transfer trend") : copy("请求趋势", "Request trend")).font(.headline)
                    Spacer(minLength: 16)
                    metricPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.cloudflare.rankByTraffic ? copy("流量趋势", "Data transfer trend") : copy("请求趋势", "Request trend")).font(.headline)
                    metricPicker
                }
            }
            CloudflareTrafficTrendView(snapshot: sample, byTraffic: settings.cloudflare.rankByTraffic, language: language)
                .frame(height: 176)
            Text(copy("请求数不等于访客人数。", "Requests do not represent unique visitors."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metricPicker: some View {
        Picker(copy("统计指标", "Metric"), selection: $settings.cloudflare.rankByTraffic) {
            Text(copy("流量", "Transfer")).tag(true)
            Text(copy("请求数", "Requests")).tag(false)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(copy("趋势与地区排名的统计指标", "Metric for trends and region ranking"))
    }

    private func regionRanking(_ sample: CloudflareAnalyticsSnapshot) -> some View {
        let regions = sample.rankedRegions(byTraffic: settings.cloudflare.rankByTraffic)
        let peak = regions.first.map { settings.cloudflare.rankByTraffic ? $0.bytes : $0.requests } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(copy("地区排行", "Top regions")).font(.headline)
                Spacer()
                Text(copy("\(sample.regions.count) 个国家或地区", "\(sample.regions.count) countries or regions"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if regions.isEmpty {
                Text(copy("此时间范围暂无地区数据。", "No regional data for this period."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(regions.prefix(5).enumerated()), id: \.element.id) { index, region in
                    let value = settings.cloudflare.rankByTraffic ? region.bytes : region.requests
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                            Text(language.regionName(region.code)).font(.callout).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(settings.cloudflare.rankByTraffic ? CloudflareAnalyticsSnapshot.bytesText(value, language: language)
                                 : CloudflareAnalyticsSnapshot.countText(value, language: language))
                                .font(.callout.monospacedDigit())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        GeometryReader { proxy in
                            let ratio = peak.isFinite && peak > 0 && value.isFinite ? min(max(value / peak, 0), 1) : 0
                            Capsule().fill(.quaternary).overlay(alignment: .leading) {
                                Capsule().fill(accent).frame(width: proxy.size.width * ratio)
                            }
                        }.frame(height: 4)
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(copy("按来源 IP 聚合；套餐与采样可能限制统计范围。", "Grouped by source IP. Plan limits and sampling may affect coverage."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displaySettings: some View {
        DisclosureGroup(isExpanded: $showsDisplaySettings) {
            VStack(alignment: .leading, spacing: 16) {
                settingsField(copy("共用数据源", "Shared data source")) {
                    Picker(copy("共用数据源", "Shared data source"), selection: sourceBinding) {
                        ForEach(settings.cloudflareSources) { source in
                            Text(source.name).lineLimit(1).tag(Optional(source.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(copy("共用数据源", "Shared data source"))
                }
                Text(copy("所有设备共用此网站与显示设置。添加或编辑来源，请前往「设备管理 → 共享数据源」。", "All devices share this website and its display settings. Add or edit a source in Device Management → Shared Data Sources."))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                TextField(copy("子域名筛选（可选）", "Hostname filter (optional)"), text: $settings.cloudflare.hostname)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Text(copy("留空统计整个网站；例如 www.example.com，不含 https://。", "Leave blank for the entire website. Use a hostname such as www.example.com, without https://."))
                    .font(.caption).foregroundStyle(.secondary)
                CloudflareDisplayOptionsView(configuration: $settings.cloudflare, showsLanguageAndMetric: false,
                                             showsPeriod: false)
                Text(copy("仅调整域名的显示方式，网站筛选与统计数据保持原样。", "Changes only the displayed domain. The hostname filter and statistics stay the same."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(copy("全球热区按国家或地区显示点阵分布。设备上的地图与排行沿用上方选择的指标。", "Global traffic shows activity by country or region. The device's map and ranking use the metric selected above."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(copy("用于键盘卡片波形、地图热区与排行强调；「跟随主题」时沿用软件主题强调色，否则默认 Cloudflare 橙。", "Used for the keyboard-card sparkline, map heat, and ranking emphasis. System follows the app theme accent; otherwise defaults to Cloudflare orange."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        } label: {
            Label(copy("数据源与显示", "Data source and display"), systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private func settingsField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            content().labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptySource: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CLOUDFLARE", systemImage: "cloud.fill")
                .font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(accent)
            Text(copy("连接你的第一个网站", "Connect your first website"))
                .font(.title2.weight(.semibold))
            Text(copy("在「设备管理 → 共享数据源」添加 Cloudflare，按引导选择网站。添加一次，即可在所有设备的统计卡片中使用。", "Add Cloudflare in Device Management → Shared Data Sources and choose a website. Connect it once to use its statistics on every device."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private var emptyReading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.cloudflareBusy ? copy("正在更新网站统计", "Updating website statistics") : copy("等待网站数据", "Waiting for website data"), systemImage: "chart.xyaxis.line")
                .font(.headline)
            Text(model.cloudflareBusy ? copy("更新完成后，请求数、流量与地区排行会在这里显示。", "Requests, data transfer, and top regions will appear here when the update finishes.") : copy("点击右上方「更新」，读取所选时间范围的统计。", "Click Refresh above to load statistics for the selected period."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A restrained brand accent preserves readable text in both system appearances.
/// 少量品牌橙色承担强调，两种系统外观均保留可读的小文字。
private enum CloudflareWorkspaceTheme {
    static let orange = Color(red: 243 / 255, green: 128 / 255, blue: 32 / 255)
    static func accent(in appearance: ColorScheme) -> Color {
        appearance == .dark ? Color(red: 1, green: 167 / 255, blue: 102 / 255)
            : Color(red: 185 / 255, green: 75 / 255, blue: 0)
    }
}

/// Native Charts retain axis units, zero baseline and individual accessible data points.
/// 原生图表保留坐标单位、零基线与逐项可读的数据点。
private struct CloudflareTrafficTrendView: View {
    let snapshot: CloudflareAnalyticsSnapshot
    let byTraffic: Bool
    let language: CloudflareDisplayLanguage
    @Environment(\.colorScheme) private var colorScheme

    init(snapshot: CloudflareAnalyticsSnapshot, byTraffic: Bool, language: CloudflareDisplayLanguage = .chinese) {
        self.snapshot = snapshot; self.byTraffic = byTraffic; self.language = language
    }

    private var contentLocale: Locale { language.locale }
    private func copy(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().hour().minute().locale(contentLocale))
    }
    private func axisTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private struct Reading: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    private var readings: [Reading] {
        guard snapshot.start < snapshot.end else { return [] }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return snapshot.trend.enumerated().compactMap { index, point in
            let stamp = point.time.count == 10 ? point.time + "T00:00:00Z" : point.time
            let value = byTraffic ? point.bytes : point.requests
            guard let date = formatter.date(from: stamp) ?? fractional.date(from: stamp),
                  date >= snapshot.start, date <= snapshot.end,
                  value.isFinite, value >= 0 else { return nil }
            return Reading(id: index, date: date, value: value)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    var body: some View {
        let points = readings
        let accent = CloudflareWorkspaceTheme.accent(in: colorScheme)
        if points.isEmpty {
            ContentUnavailableView(copy("暂无趋势数据", "No trend data"), systemImage: "chart.xyaxis.line")
                .font(.callout)
        } else {
            Chart(points) { point in
                if points.count == 1 {
                    PointMark(x: .value(copy("时间", "Time"), point.date), y: .value(byTraffic ? copy("流量", "Data transfer") : copy("请求数", "Requests"), point.value))
                        .foregroundStyle(accent)
                        .symbolSize(36)
                        .accessibilityLabel(dateText(point.date))
                        .accessibilityValue(byTraffic ? CloudflareAnalyticsSnapshot.bytesText(point.value, language: language)
                                            : CloudflareAnalyticsSnapshot.countText(point.value, language: language))
                } else {
                    AreaMark(x: .value(copy("时间", "Time"), point.date), yStart: .value(copy("基线", "Baseline"), 0), yEnd: .value(byTraffic ? copy("流量", "Data transfer") : copy("请求数", "Requests"), point.value))
                        .foregroundStyle(accent.opacity(0.10))
                        .accessibilityHidden(true)
                    LineMark(x: .value(copy("时间", "Time"), point.date), y: .value(byTraffic ? copy("流量", "Data transfer") : copy("请求数", "Requests"), point.value))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .accessibilityLabel(dateText(point.date))
                        .accessibilityValue(byTraffic ? CloudflareAnalyticsSnapshot.bytesText(point.value, language: language)
                                            : CloudflareAnalyticsSnapshot.countText(point.value, language: language))
                }
            }
            .chartXScale(domain: snapshot.start...snapshot.end)
            .chartYScale(domain: 0...max(points.map(\.value).max() ?? 0, 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { axis in
                    AxisGridLine()
                    AxisValueLabel {
                        if let value = axis.as(Double.self) {
                            Text(value == 0 ? "0" : (byTraffic ? CloudflareAnalyticsSnapshot.bytesText(value, language: language)
                                 : value.formatted(.number.notation(.compactName).locale(contentLocale))))
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [snapshot.start, snapshot.start.addingTimeInterval(snapshot.end.timeIntervalSince(snapshot.start) / 2), snapshot.end]) { axis in
                    AxisTick()
                    // 端点标签向图内对齐，避免窄栏中末端时间被裁切。/ Keep endpoint labels inside the plot at narrow widths.
                    AxisValueLabel(anchor: axis.index == 0 ? .topLeading : (axis.index == 2 ? .topTrailing : .top)) {
                        if let date = axis.as(Date.self) {
                            VStack(spacing: 2) {
                                Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).locale(contentLocale))
                                Text(axisTimeText(date))
                            }
                            .font(.caption)
                            .monospacedDigit()
                            .fixedSize()
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
            .accessibilityLabel(byTraffic ? copy("网站流量趋势", "Website data transfer trend") : copy("网站请求趋势", "Website request trend"))
        }
    }
}
