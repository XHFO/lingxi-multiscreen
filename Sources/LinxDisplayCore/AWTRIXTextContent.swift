import CryptoKit
import Foundation

/// 编码后的不可变显示内容，可以安全地从后台渲染任务传回网络调用方。
public struct AWTRIXPreparedTextContent: Sendable {
    public let payloadData: Data
    public let iconData: Data?
    /// 原生字体或 draw 显示没有上传图标，保持现有 showText 的空字符串约定。
    public let iconName: String
}

public enum AWTRIXTextContent {
    public static let maximumPayloadBytes = 8_192

    public static func usesNativeFont(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            (32...126).contains($0.value) || $0 == "\n" || $0 == "\r" || $0 == "\t"
        }
    }

    /// 明确脱离调用者 actor，避免 UI 主线程承担点阵/GIF 编码。
    /// 取消父任务同时取消编码任务；编码循环也逐帧检查取消。
    public static func prepare(_ value: AWTRIXSettings,
                               fontDirectory: URL? = nil) async throws -> AWTRIXPreparedTextContent {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try makeContent(value, fontDirectory: fontDirectory)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private static func makeContent(_ value: AWTRIXSettings,
                                    fontDirectory: URL?) throws -> AWTRIXPreparedTextContent {
        try Task.checkCancellation()
        var settings = value
        settings.sanitize()
        guard !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AWTRIXError.emptyText
        }
        var payload: [String: Any] = ["durationMs": settings.durationSeconds * 1_000]
        var gif: Data?
        var iconName = ""
        if usesNativeFont(settings.text) {
            // 直接让固件用其原生小字体排版和滚动，不读中文字体、不上传 GIF。
            payload["text"] = settings.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            payload["font"] = "small"
            payload["textCase"] = "asTyped"
            payload["textCenter"] = true
            payload["textColor"] = settings.foregroundHex
            payload["backgroundColor"] = settings.backgroundHex
            // 固件 scroll.speed = 21 px/s 的百分比；软件现有设置为每像素毫秒。
            payload["scroll"] = [
                "mode": "wrap", "direction": "left", "entry": "inline",
                "whenFits": "static", "gap": 8, "holdMs": 700,
                "speed": Int((100_000.0 / (21.0 * Double(settings.scrollSpeedMilliseconds))).rounded())
            ] as [String: Any]
            applyEffects(settings, to: &payload)
            if settings.palette.caseInsensitiveCompare("Solid") != .orderedSame {
                payload["textColor"] = "palette"
            }
        } else {
            guard settings.text.count <= AWTRIXBitmapRenderer.maximumTextCharacters else {
                throw AWTRIXError.bitmapTextTooLong(AWTRIXBitmapRenderer.maximumTextCharacters)
            }
            let renderer = try AWTRIXBitmapRenderer(fontDirectory: fontDirectory)
            payload["text"] = ""
            if !settings.effect.isEmpty && renderer.fitsOnPanel(settings.text) {
                payload["draw"] = try renderer.renderDrawCommands(
                    text: settings.text, foregroundHex: settings.foregroundHex,
                    paletteName: settings.palette, paletteEntries: settings.paletteEntries)
                applyEffects(settings, to: &payload)
            } else {
                let data = try renderer.renderGIF(
                    text: settings.text, foregroundHex: settings.foregroundHex,
                    backgroundHex: settings.backgroundHex, paletteName: settings.palette,
                    paletteEntries: settings.paletteEntries,
                    scrollSpeedMilliseconds: settings.scrollSpeedMilliseconds)
                let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
                iconName = "lingxi_zh_\(digest)"
                gif = data
                payload["icon"] = iconName
            }
        }
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= maximumPayloadBytes else { throw AWTRIXError.textPayloadTooLarge }
        return AWTRIXPreparedTextContent(payloadData: data, iconData: gif, iconName: iconName)
    }

    private static func applyEffects(_ settings: AWTRIXSettings, to payload: inout [String: Any]) {
        if !settings.effect.isEmpty {
            payload["effect"] = settings.effect
            payload["effectSpeed"] = settings.effectSpeed
        }
        if settings.palette.caseInsensitiveCompare("Solid") != .orderedSame {
            payload["palette"] = settings.palette
            payload["paletteBlend"] = settings.paletteBlend
            payload["paletteSpan"] = settings.paletteSpan
            payload["paletteSpeed"] = settings.paletteSpeed
        }
    }
}
