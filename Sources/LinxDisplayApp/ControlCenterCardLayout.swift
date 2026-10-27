import LinxDisplayCore
import SwiftUI

private struct ControlCenterCardIDKey: LayoutValueKey { static let defaultValue = "" }
private struct ControlCenterCardSizeKey: LayoutValueKey {
    static let defaultValue = DeviceControlCenterCardSize()
}

/// The same fixed-cell grid geometry exercised by the Core layout tests.
struct ControlCenterFlowLayout: Layout {
    private func frames(_ subviews: Subviews, width: CGFloat?) -> [DeviceControlCenterLayoutFrame] {
        DeviceControlCenterLayoutEngine.frames(items: subviews.map {
            .init(id: $0[ControlCenterCardIDKey.self], size: $0[ControlCenterCardSizeKey.self])
        }, availableWidth: width ?? 1000)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = frames(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? result.map(\.maxX).max() ?? 0,
                      height: result.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = frames(subviews, width: bounds.width)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        for view in subviews {
            guard let frame = byID[view[ControlCenterCardIDKey.self]] else { continue }
            view.place(at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y), anchor: .topLeading,
                       proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

struct ControlCenterCardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Media and printer cards support authored small, wide and large layouts.
/// All cards support the extra-large 2 × 3 size; other cards also offer 1 × 2.
enum ControlCenterCardSizeOptions: Equatable {
    case grid, smallMediumLarge

    fileprivate var presets: [ControlCenterGridPreset] {
        switch self {
        case .grid: ControlCenterGridPreset.allCases
        case .smallMediumLarge: [.standard, .wide, .large, .extraLarge]
        }
    }

    /// Constrain an explicit resize without migrating an existing saved 1 × 2
    /// preference. A vertical expansion from the small layout uses the large
    /// layout rather than introducing an unsupported fourth presentation.
    func constrainedResize(_ candidate: DeviceControlCenterCardSize,
                           original: DeviceControlCenterCardSize) -> DeviceControlCenterCardSize {
        guard self == .smallMediumLarge, candidate.columnSpan == 1, candidate.rowSpan == 2 else { return candidate }
        if candidate == original { return original }
        return .init(columnSpan: 2, rowSpan: 2)
    }
}

struct EditableControlCenterCard<Content: View>: View {
    let id: String
    let title: String
    let size: DeviceControlCenterCardSize
    let editing: Bool
    let dragOffset: CGSize
    let dropTarget: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onReorder: (DragGesture.Value, Bool) -> Void
    let onResize: (CGSize, Bool) -> Void
    let onSetSize: (Double, Double) -> Void
    let onResetSize: () -> Void
    let onMove: (Int) -> Void
    let groups: [DeviceControlCenterGroup]
    let currentGroupID: String?
    let onSetGroup: (String?) -> Void
    let onNewGroup: () -> Void
    let onRemove: () -> Void
    var sizeOptions: ControlCenterCardSizeOptions = .grid
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var showDimensions = false

    var body: some View {
        GeometryReader { geometry in
            content(geometry.size.height)
                .disabled(editing)
                .allowsHitTesting(!editing)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                // Clip the complete material to the card outline. A rectangular
                // clip leaves shadow wedges outside its rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    if editing {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(dropTarget ? Color.accentColor : Color.accentColor.opacity(0.4),
                                          style: StrokeStyle(lineWidth: dropTarget ? 3 : 1, dash: dropTarget ? [] : [5, 4]))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if editing {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.body.weight(.semibold)).frame(width: 32, height: 32)
                            .background(.background, in: Circle()).contentShape(Circle())
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                                .onChanged { onReorder($0, false) }.onEnded { onReorder($0, true) })
                            .help(String(localized: "拖动以调整顺序"))
                            .accessibilityLabel(Text(title + ", " + String(localized: "调整顺序")))
                            .accessibilityAction(named: Text("向前移动")) { onMove(-1) }
                            .accessibilityAction(named: Text("向后移动")) { onMove(1) }
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if editing {
                        Menu { sizeAndOrderMenu } label: {
                            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 32, height: 32)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .background(.background, in: Circle()).padding(10)
                        .help(String(localized: "卡片布局选项"))
                        .accessibilityLabel(Text("卡片布局选项"))
                        .accessibilityIdentifier("control-center-layout-menu-\(id)")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if editing {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold)).frame(width: 32, height: 32)
                            .background(.background, in: Circle()).contentShape(Circle())
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { onResize($0.translation, false) }
                                .onEnded { onResize($0.translation, true) })
                            .onTapGesture { showDimensions = true }
                            .help(String(localized: "拖动以吸附网格，或点按选择尺寸"))
                            .accessibilityLabel(Text(title + ", " + String(localized: "调整卡片大小")))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { showDimensions = true }
                            .accessibilityIdentifier("control-center-resize-\(id)")
                            .padding(10)
                    }
                }
                .overlay(alignment: .top) {
                    if editing {
                        Text("\(size.columnSpan) × \(size.rowSpan)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.background, in: Capsule())
                            .padding(12).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .offset(dragOffset)
                .background {
                    Color.clear.preference(key: ControlCenterCardFrameKey.self,
                                           value: [id: geometry.frame(in: .global)])
                }
        }
        .layoutValue(key: ControlCenterCardIDKey.self, value: id)
        .layoutValue(key: ControlCenterCardSizeKey.self, value: size)
        .contextMenu { sizeAndOrderMenu }
        .popover(isPresented: $showDimensions) {
            ControlCenterGridSizePicker(title: title, size: size, options: sizeOptions) { selected in
                onSetSize(selected.preferredWidth, selected.preferredHeight)
                showDimensions = false
            }
        }
    }

    @ViewBuilder private var sizeAndOrderMenu: some View {
        Section("网格尺寸") {
            ForEach(sizeOptions.presets) { preset in
                Button { onSetSize(preset.size.preferredWidth, preset.size.preferredHeight) } label: {
                    if size == preset.size { Label(preset.label(for: sizeOptions), systemImage: "checkmark") }
                    else { Text(preset.label(for: sizeOptions)) }
                }
            }
            Button("恢复默认大小", action: onResetSize)
        }
        Menu("移至分组") {
            Button { onSetGroup(nil) } label: {
                if currentGroupID == nil { Label("未分组", systemImage: "checkmark") }
                else { Text("未分组") }
            }
            ForEach(groups) { group in
                Button { onSetGroup(group.id) } label: {
                    if currentGroupID == group.id { Label(group.title, systemImage: "checkmark") }
                    else { Text(group.title) }
                }
            }
            Divider()
            Button("新建分组", action: onNewGroup)
        }
        Section("顺序") {
            Button("向前移动") { onMove(-1) }.disabled(!canMoveEarlier)
            Button("向后移动") { onMove(1) }.disabled(!canMoveLater)
        }
        Divider()
        Button("移除卡片", action: onRemove)
    }
}

fileprivate enum ControlCenterGridPreset: String, CaseIterable, Identifiable {
    case standard, wide, tall, large, extraLarge
    var id: String { rawValue }
    var size: DeviceControlCenterCardSize {
        switch self {
        case .standard: .init(columnSpan: 1, rowSpan: 1)
        case .wide: .init(columnSpan: 2, rowSpan: 1)
        case .tall: .init(columnSpan: 1, rowSpan: 2)
        case .large: .init(columnSpan: 2, rowSpan: 2)
        case .extraLarge: .init(columnSpan: 2, rowSpan: 3)
        }
    }
    var title: String {
        switch self {
        case .standard: String(localized: "标准")
        case .wide: String(localized: "宽幅")
        case .tall: String(localized: "纵向")
        case .large: String(localized: "大幅")
        case .extraLarge: String(localized: "加大")
        }
    }
    func label(for options: ControlCenterCardSizeOptions) -> String {
        let name: String
        if options == .smallMediumLarge {
            name = switch self {
            case .standard: String(localized: "小尺寸")
            case .wide: String(localized: "中尺寸")
            case .large: String(localized: "大尺寸")
            case .extraLarge: String(localized: "超大尺寸")
            case .tall: title
            }
        } else { name = title }
        return "\(name) · \(size.columnSpan) × \(size.rowSpan)"
    }
}

private struct ControlCenterGridSizePicker: View {
    let title: String
    let size: DeviceControlCenterCardSize
    let options: ControlCenterCardSizeOptions
    let select: (DeviceControlCenterCardSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text("网格尺寸").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ForEach(options.presets) { preset in
                    let selected = size == preset.size
                    Button { select(preset.size) } label: {
                        VStack(spacing: 10) {
                            VStack(spacing: 3) {
                                ForEach(0..<3) { row in
                                    HStack(spacing: 3) {
                                        ForEach(0..<2) { column in
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(row < preset.size.rowSpan && column < preset.size.columnSpan
                                                      ? Color.accentColor : Color.secondary.opacity(0.12))
                                                .frame(width: 24, height: 20)
                                        }
                                    }
                                }
                            }.accessibilityHidden(true)
                            HStack(spacing: 5) {
                                Text(preset.label(for: options)).font(.body.weight(.medium))
                                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 126)
                        .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(ControlCenterCardButtonStyle())
                    .accessibilityLabel(preset.label(for: options))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("control-center-grid-size-\(preset.rawValue)")
                }
            }
            Text("拖动时自动吸附到网格，窄窗口会自动适配。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 360)
    }
}

/// Navigation is disabled during editing without washing out the screen preview.
struct ControlCenterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}
