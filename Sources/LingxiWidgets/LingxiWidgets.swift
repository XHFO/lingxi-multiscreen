import AppIntents
import AppKit
import SwiftUI
import WidgetKit

struct WidgetSnapshot: Codable {
    var title: String
    var primary: String
    var subtitle: String
    var detail: String
    var progress: Double
    var accent: String
    static func unavailable(_ title: String) -> WidgetSnapshot {
        WidgetSnapshot(title: title, primary: "—", subtitle: "打开多屏灵犀", detail: "本机数据服务未运行", progress: 0, accent: "gray")
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WidgetProvider: TimelineProvider {
    let kind: String
    let title: String
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: .unavailable(title))
    }
    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        load { completion(WidgetEntry(date: Date(), snapshot: $0)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        load { snapshot in
            let entry = WidgetEntry(date: Date(), snapshot: snapshot)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
        }
    }
    private func load(completion: @escaping (WidgetSnapshot) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8788/widget/\(kind)") else {
            completion(.unavailable(title)); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let snapshot = data.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
            DispatchQueue.main.async { completion(snapshot ?? .unavailable(title)) }
        }.resume()
    }
}

struct SnapshotView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) private var family
    private var isLarge: Bool { family == .systemLarge }
    var color: Color {
        switch entry.snapshot.accent {
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "blue": return .blue
        default: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 14 : 6) {
            HStack {
                Text(entry.snapshot.title).font(isLarge ? .title2.weight(.semibold) : .headline)
                Spacer()
                Circle().fill(color).frame(width: isLarge ? 11 : 8, height: isLarge ? 11 : 8)
            }
            Spacer(minLength: 0)
            Text(entry.snapshot.primary)
                .font(.system(size: isLarge ? 64 : 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(entry.snapshot.subtitle)
                .font(isLarge ? .title3 : .caption).foregroundStyle(.secondary)
            ProgressView(value: min(max(entry.snapshot.progress, 0), 1))
                .tint(color)
                .scaleEffect(y: isLarge ? 1.8 : 1, anchor: .center)
            Text(entry.snapshot.detail)
                .font(isLarge ? .body : .caption2).foregroundStyle(.tertiary).lineLimit(isLarge ? 5 : 2)
            Spacer(minLength: 0)
            if isLarge {
                HStack {
                    Text("多屏灵犀").font(.caption2).foregroundStyle(.quaternary)
                    Spacer()
                    Text(entry.date, style: .time).font(.caption2).foregroundStyle(.quaternary)
                }
            }
        }
        .padding(isLarge ? 22 : 14)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}


struct ImageEntry: TimelineEntry { let date: Date; let data: Data?; let darkData: Data?; let name: String }

struct ImageProvider: TimelineProvider {
    let path: String
    let title: String
    func placeholder(in context: Context) -> ImageEntry { ImageEntry(date: Date(), data: nil, darkData: nil, name: title) }
    func getSnapshot(in context: Context, completion: @escaping (ImageEntry) -> Void) {
        load(family: context.family, completion)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ImageEntry>) -> Void) {
        load(family: context.family) { entry in
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
        }
    }
    private func size(for family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: return "150&h=150"
        case .systemLarge: return "320&h=320"
        default: return "300&h=150"
        }
    }
    private func load(family: WidgetFamily = .systemMedium, _ completion: @escaping (ImageEntry) -> Void) {
        loadImage(family: family, dark: false) { light in
            loadImage(family: family, dark: true) { dark in
                DispatchQueue.main.async {
                    completion(ImageEntry(date: Date(), data: light, darkData: dark, name: title))
                }
            }
        }
    }
    private func loadImage(family: WidgetFamily, dark: Bool, _ completion: @escaping (Data?) -> Void) {
        let separator = path.contains("?") ? "&" : "?"
        guard let url = URL(string: "http://127.0.0.1:8788" + path + separator + "w=" + size(for: family) + "&scheme=" + (dark ? "dark" : "light")) else {
            completion(nil); return
        }
        var request = URLRequest(url: url); request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in completion(data) }.resume()
    }
}

struct WidgetImageView: View {
    let entry: ImageEntry
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if let data = (colorScheme == .dark ? entry.darkData : entry.data) ?? entry.data ?? entry.darkData,
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable()
            } else {
                Text("打开多屏灵犀").font(.headline).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white
        }
    }
}

struct ImageWidget: Widget {
    let kind: String
    let path: String
    let title: String
    init() { self.init(kind: "LingxiCloudflare", path: "/widget/image/cloudflare", title: "Cloudflare") }
    init(kind: String, path: String, title: String) { self.kind = kind; self.path = path; self.title = title }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ImageProvider(path: path, title: title)) { entry in
            WidgetImageView(entry: entry)
        }
        .configurationDisplayName(title)
        .description("与多屏灵犀中控卡片一致")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct PrinterDTO: Decodable, Identifiable { let id: String; let name: String; let subtitle: String }
struct PrinterEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "打印机")
    static var defaultQuery = PrinterQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct PrinterQuery: EntityQuery {
    private func fetch() async -> [PrinterEntity] {
        if let url = URL(string: "http://127.0.0.1:8788/widget/printers"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let list = try? JSONDecoder().decode([PrinterDTO].self, from: data), !list.isEmpty {
            return list.map { PrinterEntity(id: $0.id, name: $0.name) }
        }
        // AppIntent 查询可能在宿主尚未启动桥接时运行；用打包时生成的列表兜底。
        guard let url = Bundle.main.url(forResource: "WidgetPrinters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PrinterDTO].self, from: data) else { return [] }
        return list.map { PrinterEntity(id: $0.id, name: $0.name) }
    }
    func entities(for identifiers: [String]) async throws -> [PrinterEntity] {
        let all = await fetch(); return all.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PrinterEntity] { await fetch() }
    func defaultResult() async -> PrinterEntity? { await fetch().first }
}
struct PrinterSelectionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择打印机"
    static var description = IntentDescription("选择要显示的中控打印机卡片")
    @Parameter(title: "打印机") var printer: PrinterEntity?
    static var parameterSummary: some ParameterSummary {
        Summary("显示 \(\.$printer)")
    }
    init() {}
}
struct PrinterEntry: TimelineEntry { let date: Date; let data: Data?; let darkData: Data?; let name: String }
struct PrinterProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrinterEntry { PrinterEntry(date: Date(), data: nil, darkData: nil, name: "打印机") }
    func snapshot(for configuration: PrinterSelectionIntent, in context: Context) async -> PrinterEntry {
        await load(configuration, family: context.family)
    }
    func timeline(for configuration: PrinterSelectionIntent, in context: Context) async -> Timeline<PrinterEntry> {
        let entry = await load(configuration, family: context.family)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }
    private func load(_ configuration: PrinterSelectionIntent, family: WidgetFamily) async -> PrinterEntry {
        var base = "/widget/image/printer"
        if let id = configuration.printer?.id, let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            base += "?id=\(encoded)&"
        } else {
            base += "?"
        }
        let dimensions: String
        switch family {
        case .systemSmall: dimensions = "w=150&h=150"
        case .systemLarge: dimensions = "w=320&h=320"
        default: dimensions = "w=300&h=150"
        }
        func image(dark: Bool) async -> Data? {
            guard let url = URL(string: "http://127.0.0.1:8788" + base + dimensions + "&scheme=" + (dark ? "dark" : "light")) else { return nil }
            return try? await URLSession.shared.data(from: url).0
        }
        return PrinterEntry(date: Date(), data: await image(dark: false),
                            darkData: await image(dark: true),
                            name: configuration.printer?.name ?? "打印机")
    }
}
struct PrinterWidgetView: View {
    let entry: PrinterEntry
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if let data = (colorScheme == .dark ? entry.darkData : entry.data) ?? entry.data ?? entry.darkData,
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable()
            } else {
                VStack(spacing: 6) {
                    Text(entry.name).font(.headline)
                    Text("打开多屏灵犀，或在编辑小组件中选择打印机").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(for: .widget) {
            colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white
        }
    }
}

struct PrinterWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LingxiPrinterCard", intent: PrinterSelectionIntent.self,
                               provider: PrinterProvider()) { entry in
            PrinterWidgetView(entry: entry)
        }
        .configurationDisplayName("打印机")
        .description("选择并显示 Bambu Lab / Formlabs 中控卡片")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct CloudflareRegionDTO: Codable { var code: String; var name: String; var requests: String; var bytes: String }
struct CloudflareWidgetData: Codable {
    var domain: String; var requests: String; var bytes: String; var period: String
    var regions: [CloudflareRegionDTO]
}
enum CloudflareWidgetStyle: String, AppEnum {
    case map, ranking
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "显示样式")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .map: DisplayRepresentation(title: "热区地图"),
        .ranking: DisplayRepresentation(title: "地区排行榜")
    ]
}
struct CloudflareWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Cloudflare 样式"
    static var description = IntentDescription("选择热区地图或地区排行榜")
    @Parameter(title: "样式") var style: CloudflareWidgetStyle?
    init() {}
}
struct CloudflareDataEntry: TimelineEntry {
    let date: Date
    let data: CloudflareWidgetData?
    let style: CloudflareWidgetStyle
    let map: Data?
}
struct CloudflareDataProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CloudflareDataEntry {
        CloudflareDataEntry(date: Date(), data: nil, style: .map, map: nil)
    }
    func snapshot(for configuration: CloudflareWidgetIntent, in context: Context) async -> CloudflareDataEntry {
        await load(configuration, family: context.family)
    }
    func timeline(for configuration: CloudflareWidgetIntent, in context: Context) async -> Timeline<CloudflareDataEntry> {
        let entry = await load(configuration, family: context.family)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }
    private func load(_ configuration: CloudflareWidgetIntent, family: WidgetFamily) async -> CloudflareDataEntry {
        let style = configuration.style ?? .map
        guard let url = URL(string: "http://127.0.0.1:8788/widget/cloudflare-data"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let value = try? JSONDecoder().decode(CloudflareWidgetData.self, from: data) else {
            return CloudflareDataEntry(date: Date(), data: nil, style: style, map: nil)
        }
        var map: Data?
        if style == .map {
            let size: String
            switch family {
            case .systemSmall: size = "w=150&h=90"
            case .systemLarge: size = "w=320&h=200"
            default: size = "w=300&h=120"
            }
            if let mapURL = URL(string: "http://127.0.0.1:8788/widget/cloudflare-map?" + size) {
                map = try? await URLSession.shared.data(from: mapURL).0
            }
        }
        return CloudflareDataEntry(date: Date(), data: value, style: style, map: map)
    }
}
struct CloudflareWidgetView: View {
    let entry: CloudflareDataEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 6) {
            HStack {
                Label("Cloudflare", systemImage: "cloud.fill").font(family == .systemLarge ? .headline : .caption.weight(.semibold))
                Spacer()
                Text(entry.data?.period ?? "24 小时").font(.caption2).foregroundStyle(.secondary)
            }
            Text(entry.data?.domain ?? "暂无统计")
                .font(family == .systemLarge ? .largeTitle.bold() : .title2.bold())
                .lineLimit(1).minimumScaleFactor(0.6)
            if entry.style == .map, let map = entry.map, let image = NSImage(data: map) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: family == .systemLarge ? 170 : 100)
            } else if entry.style == .ranking {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((entry.data?.regions ?? []).prefix(family == .systemLarge ? 6 : 3).enumerated()), id: \.offset) { index, region in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 12)
                            Text(region.name).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(region.requests).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                metric("请求", entry.data?.requests ?? "—")
                metric("流量", entry.data?.bytes ?? "—")
            }
        }
        .padding(family == .systemLarge ? 18 : 10)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: family == .systemLarge ? 28 : 18, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct CloudflareWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LingxiCloudflare", intent: CloudflareWidgetIntent.self,
                               provider: CloudflareDataProvider()) { entry in
            CloudflareWidgetView(entry: entry)
        }
        .configurationDisplayName("Cloudflare")
        .description("热区地图或地区排行榜，域名、请求与流量")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct PrinterMetricDTO: Codable { var label: String; var value: String }
struct PrinterWidgetData: Codable {
    var name: String; var brand: String; var status: String; var task: String
    var progress: Double; var metrics: [PrinterMetricDTO]; var error: String
}
struct PrinterDataEntry: TimelineEntry {
    let date: Date
    let data: PrinterWidgetData?
    let camera: Data?
    let task: Data?
}
struct PrinterDataProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrinterDataEntry { PrinterDataEntry(date: Date(), data: nil, camera: nil, task: nil) }
    func snapshot(for configuration: PrinterSelectionIntent, in context: Context) async -> PrinterDataEntry { await load(configuration) }
    func timeline(for configuration: PrinterSelectionIntent, in context: Context) async -> Timeline<PrinterDataEntry> {
        let entry = await load(configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }
    private func load(_ configuration: PrinterSelectionIntent) async -> PrinterDataEntry {
        var path = "/widget/printer-data"
        if let id = configuration.printer?.id, let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?id=\(encoded)"
        }
        guard let url = URL(string: "http://127.0.0.1:8788" + path),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let value = try? JSONDecoder().decode(PrinterWidgetData.self, from: data) else {
            return PrinterDataEntry(date: Date(), data: nil, camera: nil, task: nil)
        }
        let id = configuration.printer?.id
        func picture(_ kind: String) async -> Data? {
            var path = "/widget/printer-image?kind=\(kind)"
            if let id, let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                path += "&id=\(encoded)"
            }
            guard let url = URL(string: "http://127.0.0.1:8788" + path) else { return nil }
            return try? await URLSession.shared.data(from: url).0
        }
        return PrinterDataEntry(date: Date(), data: value,
                                camera: await picture("camera"), task: await picture("task"))
    }
}
struct PrinterDataView: View {
    let entry: PrinterDataEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 7) {
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(entry.data?.name ?? "打印机").font(family == .systemLarge ? .title2.bold() : .headline)
                    .lineLimit(1)
                Spacer()
                if let status = entry.data?.status, !status.isEmpty {
                    Text(status).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                }
            }
            if let data = entry.data {
                if family != .systemSmall, entry.camera != nil || entry.task != nil {
                    HStack(spacing: 8) {
                        if let camera = entry.camera, let image = NSImage(data: camera) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: family == .systemLarge ? 130 : 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if let task = entry.task, let image = NSImage(data: task) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: family == .systemLarge ? 130 : 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !data.task.isEmpty {
                    Text(data.task).font(family == .systemLarge ? .headline : .subheadline).lineLimit(2)
                }
                ProgressView(value: min(max(data.progress, 0), 1))
                if !data.metrics.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(Array(data.metrics.prefix(family == .systemLarge ? 6 : 4).enumerated()), id: \.offset) { _, metric in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metric.label).font(.caption2).foregroundStyle(.secondary)
                                Text(metric.value).font(.system(size: family == .systemLarge ? 18 : 14, weight: .semibold, design: .rounded))
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                        }
                    }
                }
                if !data.error.isEmpty {
                    Text(data.error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            } else {
                Text("打开多屏灵犀，或在编辑小组件中选择打印机")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(family == .systemLarge ? 20 : 12)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
    private var statusColor: Color {
        let status = entry.data?.status ?? ""
        if status.contains("打印") || status.contains("运行") { return .green }
        if status.contains("暂停") || status.contains("待机") || status.contains("休眠") { return .orange }
        if status.contains("错误") || status.contains("失败") { return .red }
        return .secondary
    }
}
struct PrinterDataWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LingxiPrinter", intent: PrinterSelectionIntent.self,
                               provider: PrinterDataProvider()) { entry in
            PrinterDataView(entry: entry)
        }
        .configurationDisplayName("打印机")
        .description("选择打印机并显示状态、任务与温度")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct HAEntityDTO: Codable { var name: String; var state: String; var domain: String }
struct HAWidgetData: Codable { var count: Int; var entities: [HAEntityDTO]; var error: String }
struct HAEntry: TimelineEntry { let date: Date; let data: HAWidgetData? }
struct HAProvider: TimelineProvider {
    func placeholder(in context: Context) -> HAEntry { HAEntry(date: Date(), data: nil) }
    func getSnapshot(in context: Context, completion: @escaping (HAEntry) -> Void) { load(completion) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HAEntry>) -> Void) {
        load { entry in completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))) }
    }
    private func load(_ completion: @escaping (HAEntry) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8788/widget/home-assistant-data") else {
            completion(HAEntry(date: Date(), data: nil)); return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let value = data.flatMap { try? JSONDecoder().decode(HAWidgetData.self, from: $0) }
            DispatchQueue.main.async { completion(HAEntry(date: Date(), data: value)) }
        }.resume()
    }
}
struct HAWidgetView: View {
    let entry: HAEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 5) {
            HStack {
                Label("Home Assistant", systemImage: "house.fill").font(family == .systemLarge ? .headline : .caption.weight(.semibold))
                Spacer()
                Text("\(entry.data?.count ?? 0) 个实体").font(.caption2).foregroundStyle(.secondary)
            }
            if let data = entry.data, !data.error.isEmpty {
                Text(data.error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            if let entities = entry.data?.entities, !entities.isEmpty {
                ForEach(Array(entities.prefix(family == .systemLarge ? 7 : 3).enumerated()), id: \.offset) { _, entity in
                    HStack(spacing: 6) {
                        Circle().fill(stateColor(entity.state)).frame(width: 6, height: 6)
                        Text(entity.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entity.state).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text("暂无实体").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(family == .systemLarge ? 18 : 10)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
    private func stateColor(_ state: String) -> Color {
        let value = state.lowercased()
        if ["on", "open", "home", "playing", "heat", "cool"].contains(value) { return .green }
        if ["unavailable", "unknown", "offline"].contains(value) { return .red }
        return .secondary
    }
}
struct HomeAssistantWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LingxiHomeAssistant", provider: HAProvider()) { entry in
            HAWidgetView(entry: entry)
        }
        .configurationDisplayName("Home Assistant")
        .description("实体状态列表")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct DeepSeekData: Codable {
    var state: String; var balance: String; var currency: String; var message: String
    var apiAvailable: Bool; var todayCost: String?; var todayTokens: String?
    var monthCost: String?; var monthTokens: String?; var todayRequests: Int?; var monthRequests: Int?
    var topModel: String?
}
struct DeepSeekEntry: TimelineEntry { let date: Date; let data: DeepSeekData? }
struct DeepSeekProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeepSeekEntry { DeepSeekEntry(date: Date(), data: nil) }
    func getSnapshot(in context: Context, completion: @escaping (DeepSeekEntry) -> Void) { load(completion) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeepSeekEntry>) -> Void) {
        load { entry in completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))) }
    }
    private func load(_ completion: @escaping (DeepSeekEntry) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8788/widget/deepseek-data") else {
            completion(DeepSeekEntry(date: Date(), data: nil)); return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let value = data.flatMap { try? JSONDecoder().decode(DeepSeekData.self, from: $0) }
            DispatchQueue.main.async { completion(DeepSeekEntry(date: Date(), data: value)) }
        }.resume()
    }
}
struct DeepSeekWidgetView: View {
    let entry: DeepSeekEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 5) {
            HStack {
                Text("DeepSeek").font(family == .systemLarge ? .headline : .caption.weight(.semibold))
                Spacer()
                Circle().fill((entry.data?.apiAvailable ?? false) ? .green : .orange).frame(width: 6, height: 6)
            }
            Text(entry.data?.balance ?? "—")
                .font(.system(size: family == .systemLarge ? 38 : 26, weight: .bold, design: .rounded))
                .foregroundStyle(.purple).lineLimit(1).minimumScaleFactor(0.6)
            Text(entry.data?.currency ?? "CNY").font(.caption2).foregroundStyle(.secondary)
            if let data = entry.data {
                if family != .systemSmall {
                    HStack(spacing: 12) {
                        info("今日", data.todayCost ?? "—", data.todayTokens.map { $0 + " tok" } ?? "")
                        info("本月", data.monthCost ?? "—", data.monthTokens.map { $0 + " tok" } ?? "")
                    }
                }
                if family == .systemLarge {
                    HStack(spacing: 12) {
                        info("今日请求", data.todayRequests.map(String.init) ?? "—", "")
                        info("本月请求", data.monthRequests.map(String.init) ?? "—", "")
                    }
                    if let top = data.topModel { Text("主要模型：\(top)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !data.message.isEmpty { Text(data.message).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(family == .systemLarge ? 18 : 10)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
    private func info(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
            if !sub.isEmpty { Text(sub).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DeepSeekWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LingxiDeepSeek", provider: DeepSeekProvider()) { entry in
            DeepSeekWidgetView(entry: entry)
        }
        .configurationDisplayName("DeepSeek 用量")
        .description("余额、今日/本月费用、Token、请求数与主要模型")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
struct LingxiWidget: Widget {
    let kind: String
    let path: String
    let title: String

    init() { self.init(kind: "LingxiCodex", path: "codex", title: "Codex 用量") }
    init(kind: String, path: String, title: String) {
        self.kind = kind; self.path = path; self.title = title
    }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetProvider(kind: path, title: title)) { entry in
            SnapshotView(entry: entry)
        }
        .configurationDisplayName(title)
        .description("多屏灵犀卡片快照")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct LingxiWidgetBundle: WidgetBundle {
    var body: some Widget {
        LingxiWidget(kind: "LingxiCodex", path: "codex", title: "Codex 用量")
        LingxiWidget(kind: "LingxiSystem", path: "system", title: "系统监控")
        DeepSeekWidget()
        LingxiWidget(kind: "LingxiAIStatus", path: "ai-status", title: "AI 状态")
        LingxiWidget(kind: "LingxiQwen", path: "qwen", title: "千问办公额度")
        LingxiWidget(kind: "LingxiGrok", path: "grok", title: "Grok Bot")
        LingxiWidget(kind: "LingxiSspai", path: "sspai", title: "少数派")
        LingxiWidget(kind: "LingxiPomodoro", path: "pomodoro", title: "番茄钟")
        LingxiWidget(kind: "LingxiExcerpt", path: "excerpt", title: "摘录语录")
        CloudflareWidget()
        HomeAssistantWidget()
        PrinterWidget()
    }
}
