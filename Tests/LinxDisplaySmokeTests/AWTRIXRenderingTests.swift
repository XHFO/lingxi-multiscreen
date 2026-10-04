import AppKit
import Foundation
import ImageIO
import LinxDisplayCore

/// 纯本地内容编码回归，不发设备请求，也不读取用户连接配置。
func testAWTRIXTextRendering() async throws {
    check(AWTRIXTextContent.usesNativeFont("Hello AWTRIX 2026!"), "AWTRIX 英文和数字使用原生字体")
    check(!AWTRIXTextContent.usesNativeFont("室温 24°C"), "AWTRIX 中文与非 ASCII 内容继续使用点阵")
    var settings = AWTRIXSettings()
    settings.text = "Hello\nAWTRIX"
    settings.foregroundHex = "#12ABCD"
    settings.backgroundHex = "#010203"
    let unavailableFontDirectory = URL(fileURLWithPath: "/private/tmp/awtrix-no-font-\(UUID().uuidString)")
    let native = try await AWTRIXTextContent.prepare(settings, fontDirectory: unavailableFontDirectory)
    let nativeJSON = try JSONSerialization.jsonObject(with: native.payloadData) as! [String: Any]
    checkEqual(nativeJSON["text"] as? String, "Hello AWTRIX", "原生字体保留文本并折叠换行")
    checkEqual(nativeJSON["font"] as? String, "small", "英文 payload 使用 AWTRIX 原生 small 字体")
    checkEqual(nativeJSON["textCase"] as? String, "asTyped", "英文大小写不受设备全局大写开关改变")
    checkEqual(nativeJSON["textColor"] as? String, "#12ABCD", "原生文字颜色使用固件 textColor 字段")
    checkEqual(nativeJSON["backgroundColor"] as? String, "#010203", "原生文字保留背景色")
    checkEqual((nativeJSON["scroll"] as? [String: Any])?["speed"] as? Int, 53,
               "90ms/像素换算为固件 21px/s 基准速度百分比")
    check(native.iconData == nil && native.iconName.isEmpty && nativeJSON["icon"] == nil,
          "英文显示不依赖本地点阵字库，不生成或上传 GIF")
    settings.palette = "Ocean"
    settings.effect = "PlasmaCloud"
    let effects = try await AWTRIXTextContent.prepare(settings, fontDirectory: unavailableFontDirectory)
    let effectsJSON = try JSONSerialization.jsonObject(with: effects.payloadData) as! [String: Any]
    checkEqual(effectsJSON["textColor"] as? String, "palette", "原生渐变文字由设备调色板着色")
    checkEqual(effectsJSON["palette"] as? String, "Ocean", "原生文字保留所选调色板")
    checkEqual(effectsJSON["effect"] as? String, "PlasmaCloud", "原生文字保留所选灯光效果")

    let renderer = try AWTRIXBitmapRenderer()
    let plainGIF = try renderer.renderGIF(text: "中文", foregroundHex: "#12ABCD",
                                          backgroundHex: "#010203", paletteName: "Solid",
                                          scrollSpeedMilliseconds: 90)
    guard let staticSource = CGImageSourceCreateWithData(plainGIF as CFData, nil),
          let staticFrame = CGImageSourceCreateImageAtIndex(staticSource, 0, nil) else {
        throw AWTRIXError.gifEncodingFailed
    }
    checkEqual(CGImageSourceGetCount(staticSource), 1, "短中文仍是居中的单帧点阵")
    let bitmap = NSBitmapImageRep(cgImage: staticFrame)
    let draw = try renderer.renderDrawCommands(text: "中文", foregroundHex: "#12ABCD", paletteName: "Solid")
    var foregroundPoints = Set<Int>()
    for command in draw {
        for index in stride(from: 2, to: command.count, by: 2) {
            if let x = command[index] as? Int, let y = command[index + 1] as? Int {
                foregroundPoints.insert(y * 32 + x)
            }
        }
    }
    let pixelsMatch = (0..<256).allSatisfy { index in
        // 直接比较解码样本；NSColor 的 calibrated/device 转换会改写 RGB 数值，
        // 与固件直接读取 GIF 调色板字节的行为不同。
        var components = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&components, atX: index % 32, y: index / 32)
        let actual = (components[0] << 16) | (components[1] << 8) | components[2]
        return actual == (foregroundPoints.contains(index) ? 0x12ABCD : 0x010203)
    }
    check(pixelsMatch, "独立 ImageIO 解码后的每个 GIF 像素都与中文字形和颜色一致")
    let staticCodes = try awtrixGIFCodeStatistics(plainGIF)
    checkEqual(staticCodes.map(\.clearCount), [1], "短中文 GIF 每帧只重置一次 LZW 字典")
    check(plainGIF.count < 160, "中文静态 GIF 使用真实字典压缩，避免逐像素 literal 膨胀")

    let degreeDraw = try renderer.renderDrawCommands(text: "°", foregroundHex: "#FFFFFF", paletteName: "Solid")
    checkEqual(awtrixDrawPoints(degreeDraw), Set([45, 76, 78, 109]),
               "温度单位的度数符号使用真实四点圆环字形，不退化为问号")
    let temperature = try renderer.renderGIF(text: "24°C", foregroundHex: "#FFFFFF",
                                              backgroundHex: "#000000", paletteName: "Solid",
                                              scrollSpeedMilliseconds: 90)
    check(CGImageSourceCreateWithData(temperature as CFData, nil).map(CGImageSourceGetCount) == 1,
          "常见温度数字与 °C 可完整显示于单帧点阵")

    let tailGIF = try renderer.renderGIF(text: String(repeating: "中", count: 159) + "末",
                                        foregroundHex: "#FFFFFF", backgroundHex: "#000000",
                                        paletteName: "Solid", scrollSpeedMilliseconds: 90)
    guard let tailSource = CGImageSourceCreateWithData(tailGIF as CFData, nil) else {
        throw AWTRIXError.gifEncodingFailed
    }
    let tailCount = CGImageSourceGetCount(tailSource)
    let lastGlyph = awtrixDrawPoints(try renderer.renderDrawCommands(
        text: "末", foregroundHex: "#FFFFFF", paletteName: "Solid"))
    var completeTailVisible = false
    for frameIndex in max(0, tailCount - 8)..<tailCount {
        guard let frame = CGImageSourceCreateImageAtIndex(tailSource, frameIndex, nil) else { continue }
        let frameBitmap = NSBitmapImageRep(cgImage: frame)
        let pixels: [Int] = (0..<256).map { index in
            var components = [Int](repeating: 0, count: frameBitmap.samplesPerPixel)
            frameBitmap.getPixel(&components, atX: index % 32, y: index / 32)
            return (components[0] << 16) | (components[1] << 8) | components[2]
        }
        completeTailVisible = completeTailVisible || (0...24).contains { left in
            (0..<64).allSatisfy { index in
                let x = index % 8, y = index / 8
                return pixels[y * 32 + left + x] == (lastGlyph.contains(y * 32 + 12 + x) ? 0xFFFFFF : 0)
            }
        }
    }
    check(completeTailVisible, "达到 160 字上限时，末字在滚动结束前仍会完整显示")

    for palette in ["Solid", "Rainbow"] {
        let longGIF = try renderer.renderGIF(
            text: String(repeating: "中", count: AWTRIXBitmapRenderer.maximumTextCharacters),
            foregroundHex: "#FFFFFF", backgroundHex: "#000000", paletteName: palette,
            scrollSpeedMilliseconds: 90)
        guard let source = CGImageSourceCreateWithData(longGIF as CFData, nil) else {
            throw AWTRIXError.gifEncodingFailed
        }
        let frameCount = CGImageSourceGetCount(source)
        check(longGIF.count <= AWTRIXBitmapRenderer.maximumGIFBytes,
              "最长 \(palette) 中文 GIF 不超过 32KiB 固件内存预算")
        check(frameCount > 1 && frameCount <= AWTRIXBitmapRenderer.maximumGIFFrames,
              "最长 \(palette) 中文滚动不超过 128 帧")
        let codeStatistics = try awtrixGIFCodeStatistics(longGIF)
        checkEqual(codeStatistics.count, frameCount, "\(palette) 的码流统计覆盖每帧")
        check(codeStatistics.allSatisfy { $0.clearCount == 1 },
              "\(palette) 每帧只发一次 clear，不反复重置固件解码状态")
        check(codeStatistics.contains { $0.maximumCodeBits >= 6 },
              "\(palette) LZW 字典可跨越码宽边界并继续复用像素串")
        check(longGIF.count < frameCount * 128,
              "\(palette) 长中文使用字典压缩，单帧平均小于128字节")
        check((0..<frameCount).allSatisfy { index in
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return false }
            return frame.width == 32 && frame.height == 8
        }, "最长 \(palette) GIF 的每帧均可被独立解码器完整读取")
    }
    do {
        _ = try renderer.renderGIF(text: String(repeating: "中", count: 161),
                                    foregroundHex: "#FFFFFF", backgroundHex: "#000000",
                                    paletteName: "Solid", scrollSpeedMilliseconds: 90)
        check(false, "超长中文应明确报错，不创建无界动画")
    } catch AWTRIXError.bitmapTextTooLong(let limit) {
        checkEqual(limit, 160, "超长中文错误包含实际上限")
    }
    settings.text = String(repeating: "A", count: 8_192)
    do {
        _ = try await AWTRIXTextContent.prepare(settings)
        check(false, "超过固件 JSON 上限的原生文字应在发网前拒绝")
    } catch AWTRIXError.textPayloadTooLarge {
        check(true, "原生文字遵循固件 8192 字节 JSON 容量")
    }
    settings.text = String(repeating: "中", count: 160)
    settings.effect = ""
    let cancelled = Task { try await AWTRIXTextContent.prepare(settings) }
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        check(false, "已取消的点阵准备不能返回可上传结果")
    } catch is CancellationError {
        check(true, "取消点阵任务会传播到后台编码并停止后续上传")
    }
    print("  AWTRIX 原生英文、后台点阵与 GIF 容量验证通过")
}

private func awtrixDrawPoints(_ commands: [[Any]]) -> Set<Int> {
    var points = Set<Int>()
    for command in commands {
        for index in stride(from: 2, to: command.count, by: 2) {
            if let x = command[index] as? Int, let y = command[index + 1] as? Int {
                points.insert(y * 32 + x)
            }
        }
    }
    return points
}

private struct AWTRIXGIFCodeStatistics {
    var clearCount = 0
    var maximumCodeBits = 0
}

/// 直接读取 GIF 码流而非依赖编码器的内部计数，校验每帧的重置次数及变宽边界。
private func awtrixGIFCodeStatistics(_ data: Data) throws -> [AWTRIXGIFCodeStatistics] {
    let bytes = [UInt8](data)
    guard bytes.count >= 13 else { throw AWTRIXError.gifEncodingFailed }
    var position = 13
    if bytes[10] & 0x80 != 0 { position += 3 * (2 << Int(bytes[10] & 7)) }
    func readByte() throws -> Int {
        guard position < bytes.count else { throw AWTRIXError.gifEncodingFailed }
        defer { position += 1 }
        return Int(bytes[position])
    }
    func readBlocks() throws -> [UInt8] {
        var result: [UInt8] = []
        while true {
            let size = try readByte()
            if size == 0 { return result }
            guard position + size <= bytes.count else { throw AWTRIXError.gifEncodingFailed }
            result.append(contentsOf: bytes[position..<(position + size)])
            position += size
        }
    }
    var frames: [AWTRIXGIFCodeStatistics] = []
    while true {
        switch try readByte() {
        case 0x3B: return frames
        case 0x21:
            _ = try readByte()
            _ = try readBlocks()
        case 0x2C:
            position += 8
            let packed = try readByte()
            if packed & 0x80 != 0 { position += 3 * (2 << (packed & 7)) }
            let minimumBits = try readByte()
            guard (2...8).contains(minimumBits) else { throw AWTRIXError.gifEncodingFailed }
            let stream = try readBlocks()
            let clear = 1 << minimumBits, end = clear + 1
            var bits = minimumBits + 1, nextEntry = end + 1, bitOffset = 0
            var previous = false, ended = false
            var statistics = AWTRIXGIFCodeStatistics()
            while bitOffset + bits <= stream.count * 8 {
                statistics.maximumCodeBits = max(statistics.maximumCodeBits, bits)
                var code = 0
                for bit in 0..<bits {
                    let offset = bitOffset + bit
                    code |= Int((stream[offset / 8] >> UInt8(offset % 8)) & 1) << bit
                }
                bitOffset += bits
                if code == clear {
                    statistics.clearCount += 1
                    bits = minimumBits + 1
                    nextEntry = end + 1
                    previous = false
                } else if code == end {
                    ended = true
                    break
                } else {
                    guard code < nextEntry || (previous && code == nextEntry) else {
                        throw AWTRIXError.gifEncodingFailed
                    }
                    if previous {
                        nextEntry += 1
                        if nextEntry == 1 << bits { bits += 1 }
                    }
                    previous = true
                }
            }
            guard ended else { throw AWTRIXError.gifEncodingFailed }
            frames.append(statistics)
        default: throw AWTRIXError.gifEncodingFailed
        }
    }
}
