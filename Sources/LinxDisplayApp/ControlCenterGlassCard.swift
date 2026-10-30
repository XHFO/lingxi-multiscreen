import SwiftUI

/// Shared presentation for the control center's interactive device and source cards.
/// Images keep their original colors; only the surrounding control surface uses glass.
struct ControlCenterGlassCard: ViewModifier {
    let hovering: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    private var border: Color {
        if contrast == .increased { return Color.primary.opacity(0.7) }
        return hovering ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12)
    }

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                shape.strokeBorder(border, lineWidth: contrast == .increased ? 2 : (hovering ? 1.5 : 0.5))
                    .allowsHitTesting(false)
            }
            // Liquid Glass supplies its own depth; a second view-wide shadow
            // creates corner remnants when the grid constrains the material.
            // Hover feedback never changes a card's geometry or its grid hit region.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .clipShape(shape)
                .contentShape(shape)
        } else {
            content
                // A translucent backing quiets the window's backdrop while
                // retaining the glass surface's transmitted color and depth.
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: shape)
                .clipShape(shape)
                .contentShape(shape)
                .glassEffect(.regular.interactive(!reduceMotion), in: shape)
        }
    }
}

extension View {
    func controlCenterGlassCard(hovering: Bool) -> some View {
        modifier(ControlCenterGlassCard(hovering: hovering))
    }
}
