import AppKit
import SwiftUI
import LinxDisplayCore

@MainActor
func testDevicePreviewCorners() throws {
    for scale in [0.5, 1.0, 2.0, 3.0] {
        let geometry = LingxiKeyboardPreviewGeometry(frameSize: CGSize(width: 456 * scale,
                                                                        height: 1357 * scale))
        let horizontal = (geometry.bezelRect.width - geometry.contentSize.width) / 2
        let vertical = (geometry.bezelRect.height - geometry.contentSize.height) / 2
        check(abs(horizontal - vertical) < 0.000001, "四边黑框等宽，不因等比适配增加左右黑边")
        check(abs(horizontal - geometry.borderWidth) < 0.000001, "布局使用统一黑边厚度")
        check(abs(geometry.contentSize.width / geometry.contentSize.height - 142.0 / 428.0) < 1e-10,
              "等宽黑框保留完整原生画面比例，不拉伸或裁切")
        check(geometry.borderWidth > 0 && geometry.borderWidth < geometry.cornerRadius,
              "黑边及内圆角为有效尺寸")
    }

    // 验证实际 SwiftUI 输出的四个角，而不只是验证半径公式。
    let whiteImage = NSImage(size: CGSize(width: 142, height: 428), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    let cornerRenderer = ImageRenderer(content: DevicePreviewSurface(image: whiteImage,
        bezelSize: CGSize(width: 158, height: 444),
        borderWidth: 8, cornerRadius: 28).background(Color.black))
    cornerRenderer.scale = 4
    if let corners = cornerRenderer.cgImage {
        let bitmap = NSBitmapImageRep(cgImage: corners)
        for y in [CGFloat(2), 5, 10, 15] {
            let edgeX = 8 + 20 * (1 - sqrt(1 - pow((20 - y) / 20, 2)))
            for right in [false, true] {
                for bottom in [false, true] {
                    for inside in [false, true] {
                        let x = edgeX + (inside ? 1.5 : -1.5)
                        let pixelX = Int((right ? 158 - x : x) * 4)
                        let pixelY = Int((bottom ? 444 - (8 + y) : 8 + y) * 4)
                        let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
                        check(color != nil && (inside ? color!.redComponent > 0.95
                                                     : color!.redComponent < 0.05),
                              "实际预览四角使用等距内缩的正圆弧")
                    }
                }
            }
        }
    } else { check(false, "原生四角轮廓可渲染") }

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let frameURL = root.appendingPathComponent("Resources/akko2.png")
    let weatherURL = root.appendingPathComponent("artifacts/weather-sky/keyboard-light-sunny.png")
    guard let frame = NSImage(contentsOf: frameURL) else {
        check(false, "键盘外观预览素材存在"); return
    }
    let picture = NSImage(contentsOf: weatherURL) ?? NSImage(size: CGSize(width: 142, height: 428))
    let originalTIFF = picture.tiffRepresentation
    for width in [CGFloat(180), 280] {
        let height = width * frame.size.height / frame.size.width
        let geometry = LingxiKeyboardPreviewGeometry(frameSize: CGSize(width: width, height: height))
        // 从实际原生渲染像素测量四边，防止仅验证半径却遗漏黑边不等距。
        for renderScale in [CGFloat(2), 4] {
            let bezelRenderer = ImageRenderer(content: DevicePreviewSurface(image: whiteImage,
                bezelSize: geometry.bezelRect.size, borderWidth: geometry.borderWidth,
                cornerRadius: geometry.cornerRadius))
            bezelRenderer.scale = renderScale
            if let bezelImage = bezelRenderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: bezelImage)
                let isWhite: (Int, Int) -> Bool = { x, y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95
                }
                let row = bitmap.pixelsHigh / 2, column = bitmap.pixelsWide / 2
                if let left = (0..<bitmap.pixelsWide).first(where: { isWhite($0, row) }),
                   let right = (0..<bitmap.pixelsWide).last(where: { isWhite($0, row) }),
                   let top = (0..<bitmap.pixelsHigh).first(where: { isWhite(column, $0) }),
                   let bottom = (0..<bitmap.pixelsHigh).last(where: { isWhite(column, $0) }) {
                    let borders = [left, bitmap.pixelsWide - 1 - right, top, bitmap.pixelsHigh - 1 - bottom]
                    check(borders.max()! - borders.min()! <= 1, "实际像素四边黑框等厚，允许1像素抗锯齿差")
                    for measured in borders {
                        // 95%全白阈值会跳过边缘过渡像素，另有最多半像素的采样偏移。
                        check(abs(CGFloat(measured) - geometry.borderWidth * renderScale) <= 1.5,
                              "黑框厚度符合设定及抗锯齿采样误差：\(measured)，预期\(geometry.borderWidth * renderScale)")
                    }
                } else { check(false, "等宽黑框内有完整可见画面") }
            } else { check(false, "等宽黑框可导出") }
        }
        for dark in [false, true] {
            let scene = ZStack {
                Image(nsImage: frame).resizable().interpolation(.high)
                    .frame(width: width, height: height)
                    .position(x: width / 2, y: height / 2)
                DevicePreviewSurface(image: picture, bezelSize: geometry.bezelRect.size,
                    borderWidth: geometry.borderWidth, cornerRadius: geometry.cornerRadius)
                    .position(x: geometry.bezelRect.midX, y: geometry.bezelRect.midY)
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                check(false, "SwiftUI原生圆角预览可导出"); continue
            }
            checkEqual(image.width, Int(width * 2), "圆角预览导出宽度正确")
            checkEqual(picture.tiffRepresentation, originalTIFF, "预览圆角不改写推送源图像")
            let bitmap = NSBitmapImageRep(cgImage: image)
            var exposedGreen = 0
            for y in Int(geometry.bezelRect.minY * 2)..<Int(geometry.bezelRect.maxY * 2) {
                for x in Int(geometry.bezelRect.minX * 2)..<Int(geometry.bezelRect.maxX * 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.greenComponent > color.redComponent + 0.25,
                       color.greenComponent > color.blueComponent + 0.25 { exposedGreen += 1 }
                }
            }
            checkEqual(exposedGreen, 0, "屏幕四角无素材绿色定位区域泄漏")
            if let directory = ProcessInfo.processInfo.environment["LINGXI_DEVICE_PREVIEW_DIR"] {
                let target = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let file = target.appendingPathComponent("keyboard-\(Int(width))-\(dark ? "dark" : "light").png")
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try data.write(to: file)
                }
                else { check(false, "预览图片可编码") }
            }
        }
    }
    print("  设备预览四边等距黑框、同心圆角、缩放及推送源隔离通过")
}
