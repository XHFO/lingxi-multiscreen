import Foundation

public struct WeatherSettings: Codable, Equatable, Sendable {
    public var city = ""
    public var latitude = 0.0
    public var longitude = 0.0
    public var refreshMinutes = 30
    public init() {}
    public var isValid: Bool { !city.isEmpty && latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) && (15...180).contains(refreshMinutes) }
}

/// WMO 天气分类同时用于软件卡片和 C6 本地卡片，避免两端文案、图标和主题不同步。
public enum WeatherCondition: String, CaseIterable, Sendable {
    case sunny, cloudy, overcast, fog, drizzle, rain, snow, thunderstorm, unknown

    public init(code: Int) {
        switch code {
        case 0: self = .sunny
        case 1, 2: self = .cloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57: self = .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .sunny: return "晴"
        case .cloudy: return "多云"
        case .overcast: return "阴"
        case .fog: return "雾"
        case .drizzle: return "毛毛雨"
        case .rain: return "雨"
        case .snow: return "雪"
        case .thunderstorm: return "雷雨"
        case .unknown: return "天气变化"
        }
    }

    public var symbolName: String {
        switch self {
        case .sunny: return "sun.max.fill"
        case .cloudy: return "cloud.sun.fill"
        case .overcast: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    public func palette(dark: Bool, monochrome: Bool = false) -> WeatherCardPalette {
        if monochrome {
            return WeatherCardPalette(background: dark ? 0x000000 : 0xFFFFFF,
                                      backgroundBottom: dark ? 0x000000 : 0xFFFFFF,
                                      foreground: dark ? 0xFFFFFF : 0x000000,
                                      secondary: dark ? 0xFFFFFF : 0x000000,
                                      symbol: dark ? 0xFFFFFF : 0x000000,
                                      cloud: dark ? 0xFFFFFF : 0x000000)
        }
        // 天空由天气决定，而不是由电脑深/浅模式决定；晴天和多云共用蓝天。
        // 9 类上下端点与 C6 的逐行 sRGB 插值一致，正文两端对比均不低于 4.5:1。
        let top: UInt32, bottom: UInt32, foreground: UInt32, symbol: UInt32, cloud: UInt32
        switch self {
        case .sunny, .cloudy:
            top = 0x4B99E4; bottom = 0xBCE6FA; foreground = 0x08253F
            symbol = self == .sunny ? 0xFFD45E : 0xF4FAFF; cloud = 0xF4FAFF
        case .overcast:
            top = 0x8EA3B6; bottom = 0xD1DAE3; foreground = 0x172C3F
            symbol = 0xEFF4F8; cloud = 0xEFF4F8
        case .fog:
            top = 0xA8B7BE; bottom = 0xDCE4E5; foreground = 0x18313C
            symbol = 0xF3F7F8; cloud = 0xF3F7F8
        case .drizzle:
            top = 0x739CAB; bottom = 0xBBCFD9; foreground = 0x102B3E
            symbol = 0xE5F0F5; cloud = 0xE5F0F5
        case .rain:
            top = 0x7D96AA; bottom = 0xC2D0DE; foreground = 0x0E283F
            symbol = 0xE1EBF2; cloud = 0xE1EBF2
        case .snow:
            top = 0x94B8CE; bottom = 0xDFEDF5; foreground = 0x102C43
            symbol = 0xFFFFFF; cloud = 0xFFFFFF
        case .thunderstorm:
            top = 0x333C62; bottom = 0x5A6785; foreground = 0xF8FAFC
            symbol = 0xFFE57C; cloud = 0x4A5572
        case .unknown:
            top = 0x789CB8; bottom = 0xC4D9E8; foreground = 0x102B41
            symbol = 0xEFF7FC; cloud = 0xEFF7FC
        }
        return WeatherCardPalette(background: top, backgroundBottom: bottom,
                                  foreground: foreground, secondary: foreground,
                                  symbol: symbol, cloud: cloud)
    }
}

/// 固定 sRGB 色值，固件可直接转换为 RGB565；墨水屏版本不依赖颜色辨识天气。
public struct WeatherCardPalette: Equatable, Sendable {
    public let background: UInt32
    public let backgroundBottom: UInt32
    public let foreground: UInt32
    public let secondary: UInt32
    public let symbol: UInt32
    public let cloud: UInt32

    /// 固件使用同一逐行插值；只改变像素底色，不增加动画或天气请求频率。
    public func background(at fraction: Double) -> UInt32 {
        let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
        func channel(_ shift: UInt32) -> UInt32 {
            let start = Double((background >> shift) & 255)
            let end = Double((backgroundBottom >> shift) & 255)
            return UInt32((start + (end - start) * progress).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var city: String
    public var temperature: Double
    public var apparent: Double
    public var low: Double
    public var high: Double
    public var rainProbability: Int
    public var code: Int
    public var updatedAt: Date
    public var latitude: Double?, longitude: Double?
    public var isDay: Bool?
    public init(city: String, temperature: Double, apparent: Double, low: Double, high: Double, rainProbability: Int, code: Int, updatedAt: Date = Date(), latitude: Double? = nil, longitude: Double? = nil, isDay: Bool? = nil) {
        self.city = city; self.temperature = temperature; self.apparent = apparent; self.low = low; self.high = high
        self.rainProbability = rainProbability; self.code = code; self.updatedAt = updatedAt
        self.latitude = latitude; self.longitude = longitude
        self.isDay = isDay
    }
    public func matches(_ settings: WeatherSettings) -> Bool { city == settings.city && latitude == settings.latitude && longitude == settings.longitude }
    public var condition: WeatherCondition { WeatherCondition(code: code) }
    public var description: String { condition.title }
    public static func description(_ code: Int) -> String { WeatherCondition(code: code).title }
    public var clothing: String { apparent < 10 ? "厚外套保暖" : apparent < 20 ? "薄外套叠穿" : "轻薄透气衣物" }
    public var carWash: String { rainProbability >= 40 || code >= 51 ? "暂缓洗车" : "适宜洗车" }
    public var advice: String { "\(clothing) · \(carWash)" }
    public var isStale: Bool { Date().timeIntervalSince(updatedAt) > 3 * 3600 }
}
public struct WeatherCity: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let country: String?
    public let admin1: String?
    public var title: String { [name, admin1, country].compactMap { $0 }.joined(separator: " · ") }
}
public enum WeatherClient {
    public static func url(for settings: WeatherSettings) -> URL? {
        guard settings.isValid else { return nil }
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [.init(name: "latitude", value: String(settings.latitude)), .init(name: "longitude", value: String(settings.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: "1"), .init(name: "timezone", value: "auto")]
        return u.url
    }
    public static func parse(_ data: Data, settings: WeatherSettings, now: Date = Date()) throws -> WeatherSnapshot {
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let apparent_temperature: Double; let weather_code: Int; let is_day: Int? }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double]; let precipitation_probability_max: [Int?] }
            let current: Current; let daily: Daily
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let high = r.daily.temperature_2m_max.first, let low = r.daily.temperature_2m_min.first,
              high.isFinite, low.isFinite, r.current.temperature_2m.isFinite else { throw URLError(.cannotParseResponse) }
        return .init(city: settings.city, temperature: r.current.temperature_2m, apparent: r.current.apparent_temperature,
                     low: low, high: high, rainProbability: r.daily.precipitation_probability_max.first.flatMap { $0 } ?? 0,
                     code: r.current.weather_code, updatedAt: now, latitude: settings.latitude, longitude: settings.longitude,
                     isDay: r.current.is_day.map { $0 != 0 })
    }
    public static func fetch(_ settings: WeatherSettings) async throws -> WeatherSnapshot {
        guard let url = url(for: settings) else { throw URLError(.badURL) }
        let data = try await read(url); return try parse(data, settings: settings)
    }
    public static func cities(query: String) async throws -> [WeatherCity] {
        var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        u.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"), .init(name: "language", value: "zh"), .init(name: "format", value: "json")]
        struct Response: Decodable { var results: [WeatherCity]? }
        return try JSONDecoder().decode(Response.self, from: await read(u.url!)).results ?? []
    }
    private static func read(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65536 else { throw URLError(.badServerResponse) }
        return data
    }
}
