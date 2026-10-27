import CoreGraphics
import Foundation

/// 中文：真实Mac编码器/HTTP客户端到原生C固件，不接受实体设备地址。
/// English: Actual Mac bitmap encoder/HTTP client against native C firmware, refusing physical-device addresses.
@main struct GrayNativeIntegration {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["READ_PICO_MANAGE_URL"], let url = URLComponents(string: address),
              ["127.0.0.1", "localhost", "::1"].contains(url.host),
              let width = env["READ_PICO_GRAY_WIDTH"].flatMap(Int.init),
              let height = env["READ_PICO_GRAY_HEIGHT"].flatMap(Int.init),
              let expected = env["READ_PICO_EXPECTED_BMP"] else { fatalError("Loopback-only fixture configuration required") }
        let client = ReadPicoHTTPClient(connection: try ReadPicoConnection(address: address))
        let initial = try await client.capabilities()
        guard initial.canvas.supportsNativeGray16 else { fatalError("Actual C capability did not advertise native gray16") }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = UInt8(((x * 16 / width + y * 7 / height) & 15) * 17) } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var bmp = try ReadPicoBitmap.makeGray16(image: image, width: width, height: height)
        let stride = (width * 4 + 31) / 32 * 4
        if env["READ_PICO_GRAY_VARIANT"] == "top-reverse" {
            for level in 0..<16 { for channel in 0..<3 { bmp[54 + level * 4 + channel] = UInt8((15 - level) * 17) } }
            for row in 0..<height { for col in 0..<(width / 2) { bmp[118 + row * stride + col] ^= 255 } }
            let rows = bmp.subdata(in: 118..<bmp.count)
            for row in 0..<height { bmp.replaceSubrange((118 + row * stride)..<(118 + (row + 1) * stride), with: rows[((height - 1 - row) * stride)..<((height - row) * stride)]) }
            let signed = UInt32(bitPattern: -Int32(height))
            for byte in 0..<4 { bmp[22 + byte] = UInt8(truncatingIfNeeded: signed >> (byte * 8)) }
        }
        try ReadPicoBitmap.validateCanvas(bmp, capability: initial.canvas)
        try bmp.write(to: URL(fileURLWithPath: expected))
        let displayed = try await client.pushCanvasConfirmed(bmp, capability: initial.canvas)
        guard displayed.canvas.state == "displayed", displayed.canvas.revision != initial.canvas.revision else { fatalError("Actual display boundary was not confirmed") }
        print("PASS Swift→C HTTP \(width)×\(height) BMP4 \(bmp.count) bytes; displayed revision \(displayed.canvas.revision ?? 0)")
    }
}
