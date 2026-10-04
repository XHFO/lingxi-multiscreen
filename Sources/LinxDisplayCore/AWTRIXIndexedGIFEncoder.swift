import Foundation

/// 固定 32×8、全局最多 16 色的 GIF 编码器。
/// 每帧只有 256 个索引像素，免除 ImageIO 的逐帧色彩量化与 CGImage 全量驻留。
struct AWTRIXIndexedGIFEncoder {
    private var output = Data()
    private let minimumCodeSize: Int

    init(colors: [UInt32]) {
        precondition((2...16).contains(colors.count))
        var paletteBits = 1
        while (1 << paletteBits) < colors.count { paletteBits += 1 }
        minimumCodeSize = max(2, paletteBits)
        output.append(contentsOf: "GIF89a".utf8)
        output.append(contentsOf: [32, 0, 8, 0, 0xF0 | UInt8(paletteBits - 1), 0, 0])
        for index in 0..<(1 << paletteBits) {
            let color = index < colors.count ? colors[index] : 0
            output.append(contentsOf: [UInt8((color >> 16) & 255),
                                       UInt8((color >> 8) & 255), UInt8(color & 255)])
        }
        output.append(contentsOf: [0x21, 0xFF, 11])
        output.append(contentsOf: "NETSCAPE2.0".utf8)
        output.append(contentsOf: [3, 1, 0, 0, 0])
    }

    mutating func appendFrame(_ pixels: [UInt8], durationMilliseconds: Int) throws {
        precondition(pixels.count == 32 * 8)
        try Task.checkCancellation()
        let delay = min(65_535, max(1, (durationMilliseconds + 5) / 10))
        // 完整覆盖每帧，不使用透明像素或 restore-to-previous，降低固件解码内存。
        output.append(contentsOf: [0x21, 0xF9, 4, 4, UInt8(delay & 255), UInt8(delay >> 8), 0, 0])
        output.append(contentsOf: [0x2C, 0, 0, 0, 0, 32, 0, 8, 0, 0])
        output.append(UInt8(minimumCodeSize))

        // 每帧只发一次 clear；复用字典里的重复像素串，减少传输量和固件读码次数。
        // 256 像素至多新增 255 项，16 色的最大字典不足 274 项，无需中途重置。
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        let maximumEntries = end + 1 + pixels.count
        var dictionary = [UInt16](repeating: 0, count: maximumEntries * clear)
        var nextEntry = end + 1
        var encoded = Data()
        var accumulator: UInt32 = 0
        var bitCount = 0
        // 按解码器的建表时机调整码宽：解码器比编码器晚一个词条，末码也需计入。
        var codeBits = minimumCodeSize + 1
        var decoderNextEntry = end + 1
        var decoderHasPrevious = false
        func emit(_ code: Int) {
            accumulator |= UInt32(code) << UInt32(bitCount)
            bitCount += codeBits
            while bitCount >= 8 {
                encoded.append(UInt8(accumulator & 255))
                accumulator >>= 8
                bitCount -= 8
            }
            if code == clear {
                codeBits = minimumCodeSize + 1
                decoderNextEntry = end + 1
                decoderHasPrevious = false
            } else if code != end {
                if decoderHasPrevious {
                    decoderNextEntry += 1
                    if decoderNextEntry == 1 << codeBits { codeBits += 1 }
                }
                decoderHasPrevious = true
            }
        }
        emit(clear)
        var prefix = Int(pixels[0])
        for pixel in pixels.dropFirst() {
            let key = prefix * clear + Int(pixel)
            let known = dictionary[key]
            if known != 0 {
                prefix = Int(known)
            } else {
                emit(prefix)
                dictionary[key] = UInt16(nextEntry)
                nextEntry += 1
                prefix = Int(pixel)
            }
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { encoded.append(UInt8(accumulator & 255)) }
        for start in stride(from: 0, to: encoded.count, by: 255) {
            let count = min(255, encoded.count - start)
            output.append(UInt8(count))
            output.append(encoded[start..<(start + count)])
        }
        output.append(0)
        guard output.count + 1 <= AWTRIXBitmapRenderer.maximumGIFBytes else {
            throw AWTRIXError.textPayloadTooLarge
        }
    }

    func finish() -> Data {
        var data = output
        data.append(0x3B)
        return data
    }
}
