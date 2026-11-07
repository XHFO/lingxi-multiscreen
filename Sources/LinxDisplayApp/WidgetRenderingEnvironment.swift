import SwiftUI

private struct WidgetRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Widget snapshots must avoid Liquid Glass: ImageRenderer renders glass as a
    /// light material even in dark mode. Use an opaque adaptive surface instead.
    var widgetRendering: Bool {
        get { self[WidgetRenderingKey.self] }
        set { self[WidgetRenderingKey.self] = newValue }
    }
}
