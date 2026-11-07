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
        case .systemSmall: return "170&h=170"
        case .systemLarge: return "360&h=360"
        default: return "360&h=180"
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
        guard let url = URL(string: "http://127.0.0.1:8788/widget/printers") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
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
        case .systemSmall: dimensions = "w=170&h=170"
        case .systemLarge: dimensions = "w=360&h=360"
        default: dimensions = "w=360&h=180"
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
        AppIntentConfiguration(kind: "LingxiPrinter", intent: PrinterSelectionIntent.self,
                               provider: PrinterProvider()) { entry in
            PrinterWidgetView(entry: entry)
        }
        .configurationDisplayName("打印机")
        .description("选择并显示 Bambu Lab / Formlabs 中控卡片")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
        LingxiWidget(kind: "LingxiDeepSeek", path: "deepseek", title: "DeepSeek 用量")
        LingxiWidget(kind: "LingxiAIStatus", path: "ai-status", title: "AI 状态")
        LingxiWidget(kind: "LingxiQwen", path: "qwen", title: "千问办公额度")
        LingxiWidget(kind: "LingxiGrok", path: "grok", title: "Grok Bot")
        LingxiWidget(kind: "LingxiSspai", path: "sspai", title: "少数派")
        LingxiWidget(kind: "LingxiPomodoro", path: "pomodoro", title: "番茄钟")
        LingxiWidget(kind: "LingxiExcerpt", path: "excerpt", title: "摘录语录")
        LingxiWidget(kind: "LingxiEmoji", path: "emoji", title: "Emoji 壁纸")
        LingxiWidget(kind: "LingxiWeather", path: "weather", title: "天气")
        LingxiWidget(kind: "LingxiNowPlaying", path: "now-playing", title: "正在播放")
        ImageWidget(kind: "LingxiCloudflare", path: "/widget/image/cloudflare", title: "Cloudflare")
        ImageWidget(kind: "LingxiHomeAssistant", path: "/widget/image/home-assistant", title: "Home Assistant")
        PrinterWidget()
    }
}
