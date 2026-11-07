import AppKit
import SwiftUI

@MainActor
enum WidgetCardImageRenderer {
    static func png<V: View>(_ view: V, size: CGSize, dark: Bool = false) -> Data? {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.widgetRendering, true))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
