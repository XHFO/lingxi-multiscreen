import Foundation

/// 固件将退出轮播实现为停用应用。手动查看时暂时启用，离开/恢复轮播后归还原设置。
/// 写入配置以便应用意外退出后也能恢复，不能把临时启用固化为用户的轮播选择。
public struct AWTRIXManualDisplaySession: Codable, Equatable, Sendable {
    public var appName: String
    public var order: [String]
    public var disabled: [String]
    public var autoTransition: Bool
    public var baseURL: String
    public var username: String

    public init(appName: String, order: [String], disabled: [String], autoTransition: Bool,
                baseURL: String, username: String) {
        self.appName = appName
        self.order = order
        self.disabled = disabled
        self.autoTransition = autoTransition
        self.baseURL = baseURL
        self.username = username
    }
}

/// 设备启用状态与显示轮播成员不是同义词（后台脚本 enabled=true/inLoop=false）。
public struct AWTRIXAppArrangement: Equatable, Sendable {
    public var order: [String]
    public var disabled: [String]

    public init(apps: [AWTRIXAppInfo]) {
        order = apps.filter { $0.inLoop ?? ($0.enabled == true && $0.headless != true) }.map(\.name)
        var seen = Set<String>()
        disabled = apps.filter { $0.enabled == false && seen.insert($0.name).inserted }.map(\.name)
    }

    public func settingVisibleOrder(_ names: [String], apps: [AWTRIXAppInfo]) -> Self {
        let visible = Set(apps.filter { $0.isManageable && $0.headless != true }.map(\.name))
        var result = self
        result.order = names.filter { visible.contains($0) }
        var seen = Set<String>()
        result.disabled = apps.filter { app in
            let off = visible.contains(app.name) ? !result.order.contains(app.name) : app.enabled == false
            return off && seen.insert(app.name).inserted
        }.map(\.name)
        return result
    }
}

/// 像素屏展示的 Home Assistant 实体设置，连接与令牌沿用软件已有的 HA 配置。
public struct AWTRIXHomeAssistantSettings: Codable, Equatable, Sendable {
    public static let maxEntityCount = 8
    public var entityIDs: [String] = []
    public var refreshSeconds = 30
    public var showName = true
    public var foregroundHex = "#FFFFFF"
    public var autoPush = true
    public var lastUploadedIcon: String?

    public init(entityIDs: [String] = [], refreshSeconds: Int = 30,
                showName: Bool = true, foregroundHex: String = "#FFFFFF",
                autoPush: Bool = true, lastUploadedIcon: String? = nil) {
        self.entityIDs = entityIDs
        self.refreshSeconds = refreshSeconds
        self.showName = showName
        self.foregroundHex = foregroundHex
        self.autoPush = autoPush
        self.lastUploadedIcon = lastUploadedIcon
        sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case entityIDs, refreshSeconds, showName, foregroundHex, autoPush, lastUploadedIcon
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entityIDs: try values.decodeIfPresent([String].self, forKey: .entityIDs) ?? [],
                  refreshSeconds: try values.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 30,
                  showName: try values.decodeIfPresent(Bool.self, forKey: .showName) ?? true,
                  foregroundHex: try values.decodeIfPresent(String.self, forKey: .foregroundHex) ?? "#FFFFFF",
                  autoPush: try values.decodeIfPresent(Bool.self, forKey: .autoPush) ?? true,
                  lastUploadedIcon: try values.decodeIfPresent(String.self, forKey: .lastUploadedIcon))
    }

    public mutating func sanitize() {
        var seen = Set<String>()
        entityIDs = entityIDs.compactMap { raw in
            let entityID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !entityID.isEmpty && seen.insert(entityID).inserted ? entityID : nil
        }
        entityIDs = Array(entityIDs.prefix(Self.maxEntityCount))
        refreshSeconds = min(max(refreshSeconds, 5), 3_600)
        foregroundHex = AWTRIXBitmapRenderer.normalizedHex(foregroundHex) ?? "#FFFFFF"
    }
}

public enum AWTRIXHomeAssistantContent {
    public static let maxTextLength = 160

    /// 一行滚动展示，沿用其他屏幕相同的状态本地化；缺失实体不复用过期数值。
    public static func text(entities: [HAEntity],
                            settings: AWTRIXHomeAssistantSettings) -> String {
        var settings = settings
        settings.sanitize()
        guard !settings.entityIDs.isEmpty else { return "" }
        let byID = Dictionary(entities.map { ($0.entityId, $0) },
                              uniquingKeysWith: { _, latest in latest })
        let separator = "  |  "
        // 总长度有界，均分空间以保证所有已选实体都出现，不在末尾截掉整项状态。
        let itemBudget = (maxTextLength - (settings.entityIDs.count - 1) * separator.count)
            / settings.entityIDs.count
        func item(name: String, value: String) -> String {
            guard settings.showName else { return shortened(value, limit: itemBudget) }
            let valueBudget = min(value.count, max(6, itemBudget / 2))
            let displayName = shortened(name, limit: min(24, itemBudget - valueBudget - 1))
            return "\(displayName)：\(shortened(value, limit: itemBudget - displayName.count - 1))"
        }
        return settings.entityIDs.map { entityID in
            guard let entity = byID[entityID] else {
                return item(name: entityID, value: "不可用")
            }
            let state = shortened(singleLine(entity.displayState), limit: 32)
            let unit = shortened(singleLine(entity.unitOfMeasurement ?? ""), limit: 16)
            let rawState = entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unavailable = ["unavailable", "unknown", "none", ""].contains(rawState)
            let value = state.isEmpty ? "不可用" : state
            let display = unavailable || unit.isEmpty ? value : "\(value) \(unit)"
            let name = singleLine(entity.displayName)
            return item(name: name.isEmpty ? entityID : name, value: display)
        }.joined(separator: separator)
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return "…" }
        return String(value.prefix(limit - 1)) + "…"
    }
}

/// 主窗口、卡片管理与菜单栏共同使用同一份卡片定义。
public struct AWTRIXCardDescriptor: Equatable, Identifiable, Sendable {
    public let name: String
    public let title: String
    public let symbol: String
    public let isInstalled: Bool
    public let isInLoop: Bool
    public var id: String { name }

    public init(name: String, title: String, symbol: String,
                isInstalled: Bool, isInLoop: Bool) {
        self.name = name
        self.title = title
        self.symbol = symbol
        self.isInstalled = isInstalled
        self.isInLoop = isInLoop
    }
}

public enum AWTRIXCardPolicy {
    public static let homeAssistantAppName = "lingxi_home"

    public static func cards(apps: [AWTRIXAppInfo],
                             settings: AWTRIXSettings) -> [AWTRIXCardDescriptor] {
        let apps = AWTRIXAppInfo.sidebarApps(from: apps)
        let textName = AWTRIXClient.validatedAppName(settings.appName) ?? "lingxi_text"
        func generated(_ name: String, title: String, symbol: String) -> AWTRIXCardDescriptor {
            let app = apps.first { $0.name == name }
            return AWTRIXCardDescriptor(name: name, title: title, symbol: symbol,
                                        isInstalled: app != nil,
                                        isInLoop: app.map { $0.inLoop ?? $0.enabled ?? false } ?? false)
        }
        var result = [generated(textName, title: "灵犀文字", symbol: "textformat"),
                      generated(homeAssistantAppName, title: "Home Assistant", symbol: "house.fill")]
        var seen = Set(result.map(\.name))
        for app in apps where seen.insert(app.name).inserted {
            result.append(AWTRIXCardDescriptor(name: app.name, title: app.title,
                                              symbol: symbol(for: app), isInstalled: true,
                                              isInLoop: app.inLoop ?? app.enabled ?? false))
        }
        // 设备暂时离线或应用已移除时仍保留用户添加的卡片，便于查看和移除。
        for name in settings.sidebarAppNames ?? [] where !name.isEmpty && seen.insert(name).inserted {
            result.append(AWTRIXCardDescriptor(name: name, title: name, symbol: "app",
                                              isInstalled: false, isInLoop: false))
        }
        return result
    }

    public static func visibleCards(apps: [AWTRIXAppInfo],
                                    settings: AWTRIXSettings) -> [AWTRIXCardDescriptor] {
        let available = cards(apps: apps, settings: settings)
        guard let names = settings.sidebarAppNames else {
            // 旧设备保留文字入口和原有应用；HA 仅在此前已推送时自动出现。
            return available.filter { $0.name != homeAssistantAppName || $0.isInstalled }
        }
        let byName = Dictionary(available.map { ($0.name, $0) },
                                uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted else { return nil }
            return byName[name]
        }
    }

    /// 功能图标不依赖排序或设备，主窗口和菜单栏保持一致。
    public static func symbol(for app: AWTRIXAppInfo) -> String {
        let searchable = [app.name, app.title, app.meta?.desc ?? ""]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        func contains(_ terms: String...) -> Bool { terms.contains { searchable.contains($0) } }
        if contains("bilibili", "follower", "followers", "fans", "粉丝") { return "person.2.fill" }
        if contains("aquarium", "fish", "水族", "鱼") { return "fish.fill" }
        if contains("flappy", "game", "gaming", "游戏") { return "gamecontroller.fill" }
        if contains("weather", "forecast", "temperature", "天气", "气温") { return "cloud.sun.fill" }
        if contains("calendar", "date", "日期", "日历") { return "calendar" }
        if contains("clock", "time", "timer", "时钟", "时间") { return "clock.fill" }
        if contains("nightmode", "night mode", "night", "moon", "夜间", "月亮") { return "moon.stars.fill" }
        if contains("xhome", "home", "house", "家庭", "家居") { return "house.fill" }
        if contains("radio", "收音机") { return "radio.fill" }
        if contains("music", "audio", "song", "playing", "音乐", "歌曲") { return "music.note" }
        if contains("alert", "notification", "notify", "alarm", "通知", "警报", "提醒") { return "bell.badge.fill" }
        if contains("printer", "print status", "3d print", "打印机", "打印状态") { return "printer.fill" }
        if contains("system", "cpu", "memory", "ram", "monitor", "系统", "性能") { return "cpu" }
        if contains("custom text", "text", "message", "文字", "文本") { return "textformat" }
        if contains("matrix", "pixel", "dot matrix", "led", "点阵", "像素") { return "circle.grid.3x3.fill" }
        return "app"
    }
}
