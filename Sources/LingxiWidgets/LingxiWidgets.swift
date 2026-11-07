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
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
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
        LingxiWidget(kind: "LingxiCloudflare", path: "cloudflare", title: "Cloudflare")
        LingxiWidget(kind: "LingxiHomeAssistant", path: "home-assistant", title: "Home Assistant")
        LingxiWidget(kind: "LingxiPrinter", path: "printer", title: "打印机")
    }
}
