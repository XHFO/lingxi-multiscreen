import CoreGraphics

/// AI Mac 彩色屏幕的最终帧校准。只处理像素，不改变布局、尺寸或透明度。
public enum AIMacColorCalibration {
    /// 原生桌面时钟由固件渲染，电脑端预览也保持原样；其他卡片（含 Emoji）统一校准。
    public static func apply(to image: CGImage,
                             settings: AIMacScreenDeviceSettings) -> CGImage {
        guard settings.mode != .clock,
              !(settings.mode == .card && settings.cardMode == .aiMacClock) else { return image }
        return apply(to: image,
                     saturationPercent: settings.saturationPercent,
                     contrastPercent: settings.contrastPercent)
    }

    /// 饱和度范围为 50...200%，对比度范围为 75...150%。
    /// 中性参数直接返回原图，避免一次无必要的解码、色彩空间转换或重绘。
    public static func apply(to image: CGImage,
                             saturationPercent: Int,
                             contrastPercent: Int) -> CGImage {
        let saturation = min(200, max(50, saturationPercent))
        let contrast = min(150, max(75, contrastPercent))
        guard saturation != 100 || contrast != 100 else { return image }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / 4,
              width * 4 <= Int.max / height else { return image }

        // 统一 RGB/RGBA、通道顺序和预乘方式。固定 RGBA 字节顺序，不依赖主机端序。
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo),
              let data = context.data else { return image }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 合并饱和度和围绕 50% 灰的对比度调整：
        // out = contrast * (saturation * channel + (1 - saturation) * luma)
        //       + (1 - contrast) * 0.5 * alpha
        // 直接在预乘 RGB 上运算，并把输出限制在 0...alpha，透明边缘不会产生色晕。
        // 14 位定点系数使整帧只需一次整数扫描，无浮点像素循环和中间图像。
        let shift = 14
        let scale = 1 << shift
        let half = scale / 2
        let saturationFactor = Double(saturation) / 100
        let contrastFactor = Double(contrast) / 100
        let channelFactor = Int((saturationFactor * contrastFactor * Double(scale)).rounded())
        let lumaFactor = (1 - saturationFactor) * contrastFactor
        let lumaRed = Int((lumaFactor * 0.2126 * Double(scale)).rounded())
        let lumaGreen = Int((lumaFactor * 0.7152 * Double(scale)).rounded())
        // 保证灰阶的系数总和准确，避免饱和度单独变化时灰阶发生偏移。
        let lumaBlue = Int((contrastFactor * Double(scale)).rounded())
            - channelFactor - lumaRed - lumaGreen
        let alphaBias = Int(((1 - contrastFactor) * 0.5 * Double(scale)).rounded())
        let opaqueBias = alphaBias * 255 + half
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow

        for y in 0..<height {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                let alpha = Int(pixel[3])
                if alpha == 0 {
                    pixel[0] = 0
                    pixel[1] = 0
                    pixel[2] = 0
                    continue
                }
                let red = Int(pixel[0])
                let green = Int(pixel[1])
                let blue = Int(pixel[2])
                let common = lumaRed * red + lumaGreen * green + lumaBlue * blue
                    + (alpha == 255 ? opaqueBias : alphaBias * alpha + half)
                pixel[0] = UInt8(min(alpha, max(0, (channelFactor * red + common) >> shift)))
                pixel[1] = UInt8(min(alpha, max(0, (channelFactor * green + common) >> shift)))
                pixel[2] = UInt8(min(alpha, max(0, (channelFactor * blue + common) >> shift)))
                // alpha 字节原样保留；RGB 输入在解码时已得到不透明的 alpha。
            }
        }
        return context.makeImage() ?? image
    }
}
