import AppKit
import SwiftUI

/// 从整个实体黑框计算等宽留边，而不是把原生画面塞进比例不同的绿色占位区域。
public struct LingxiKeyboardPreviewGeometry {
    public let bezelRect: CGRect
    public let borderWidth: CGFloat
    public let cornerRadius: CGFloat

    public var contentSize: CGSize {
        bezelRect.insetBy(dx: borderWidth, dy: borderWidth).size
    }

    public init(frameSize: CGSize) {
        // akko2.png：456×1357，黑框外轮廓约为 (78,439)–(378,1278)。
        let scale = max(0, min(frameSize.width / 456, frameSize.height / 1357))
        bezelRect = CGRect(x: 78 * scale, y: 439 * scale,
                           width: 300 * scale, height: 839 * scale)
        cornerRadius = 40 * scale
        // (W−2b)/(H−2b)=142/428，同时满足原生比例和四边等宽。
        let ratio: CGFloat = 142.0 / 428.0
        borderWidth = (bezelRect.width - ratio * bezelRect.height) / (2 * (1 - ratio))
    }
}

/// 仅供电脑端预览使用，绝不参与设备画面的编码或推送。
public struct DevicePreviewSurface: View {
    public let image: NSImage
    public let bezelSize: CGSize
    public let borderWidth: CGFloat
    public let cornerRadius: CGFloat

    public init(image: NSImage, bezelSize: CGSize, borderWidth: CGFloat, cornerRadius: CGFloat) {
        self.image = image
        self.bezelSize = bezelSize
        self.borderWidth = max(0, min(borderWidth, min(bezelSize.width, bezelSize.height) / 2))
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let contentSize = CGSize(width: bezelSize.width - borderWidth * 2,
                                 height: bezelSize.height - borderWidth * 2)
        let innerRadius = max(0, cornerRadius - borderWidth)
        ZStack {
            // 重绘完整黑框，覆盖素材占位开窗；四边都内缩同一个厚度。
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular).fill(.black)
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .frame(width: contentSize.width, height: contentSize.height)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .circular))
        }
        .frame(width: bezelSize.width, height: bezelSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .circular))
        .accessibilityLabel("设备实时画面预览")
    }
}
