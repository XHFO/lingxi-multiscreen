import AppKit
import SwiftUI

/// Local presentation only: the official shell and current frame remain separate
/// so rotating the enclosure never rotates or stretches the supplied screen image.
struct ReadPicoDevicePreview: View {
    let image: NSImage?
    let landscape: Bool?

    init(image: NSImage?, landscape: Bool? = nil) {
        self.image = image
        self.landscape = landscape
    }

    private var isLandscape: Bool {
        landscape ?? image.map { $0.size.width > $0.size.height } ?? false
    }

    var body: some View {
        GeometryReader { geometry in
            let portrait = PreviewResources.readPicoHeroPixelSize
            let rotated = isLandscape
            let deviceSize = rotated ? CGSize(width: portrait.height, height: portrait.width) : portrait
            let scale = max(0, min(geometry.size.width / deviceSize.width, geometry.size.height / deviceSize.height))
            let screen = screenRect(landscape: rotated)
            ZStack(alignment: .topLeading) {
                if PreviewResources.readPicoHeroImage == nil {
                    RoundedRectangle(cornerRadius: 80 * scale)
                        .fill(Color(nsColor: .lightGray))
                }
                screenContent(width: screen.width * scale)
                    .frame(width: screen.width * scale, height: screen.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 20 * scale))
                    .offset(x: screen.minX * scale, y: screen.minY * scale)
                if let shell = PreviewResources.readPicoHeroImage {
                    Image(nsImage: shell).resizable().interpolation(.high)
                        .frame(width: portrait.width * scale, height: portrait.height * scale)
                        .rotationEffect(.degrees(rotated ? 90 : 0))
                        .frame(width: deviceSize.width * scale, height: deviceSize.height * scale)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: deviceSize.width * scale, height: deviceSize.height * scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .accessibilityIdentifier("read-pico-device-preview")
    }

    private func screenRect(landscape: Bool) -> CGRect {
        let size = PreviewResources.readPicoHeroPixelSize
        let rect = PreviewResources.readPicoHeroScreenRect
        let top = size.height - rect.maxY
        if landscape {
            // Clockwise shell rotation: (x, y) becomes (height - y, x).
            return CGRect(x: size.height - top - rect.height, y: rect.minX,
                          width: rect.height, height: rect.width)
        }
        return CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height)
    }

    @ViewBuilder private func screenContent(width: CGFloat) -> some View {
        ZStack {
            // Physical e-paper stays light in either software appearance.
            Color.white
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .accessibilityLabel("小纸 Pico 屏幕预览")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display").font(.system(size: 24))
                        .accessibilityHidden(true)
                    Text("暂无画面").font(.system(size: min(18, max(11, width * 0.07))))
                }
                .foregroundStyle(Color.black.opacity(0.65))
                .padding(8)
            }
        }
    }
}
