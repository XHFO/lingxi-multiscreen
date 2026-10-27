import AppKit
import Combine
import LinxDisplayCore
import SwiftUI

/// An overview of saved devices, with truthful preview provenance and stable device-ID navigation.
struct DeviceControlCenterView: View {
    @ObservedObject var model: AppModel
    let onOpen: (UUID, CGRect?) -> Void
    let onOpenDataSource: (DeviceControlCenterDataSource.Destination) -> Void
    let onAdd: () -> Void
    @State private var previews: [UUID: DeviceControlCenterPreview] = [:]
    @State private var previewImageData: [UUID: Data] = [:]
    @State private var editingLayout = false
    @State private var resized: [String: DeviceControlCenterCardSize] = [:]
    @State private var resizeGrid: DeviceControlCenterLayoutEngine.Grid?
    @State private var resizeOriginal: DeviceControlCenterCardSize?
    @State private var gridWidth = 1000.0
    @State private var viewportWidth = 1000.0
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var draggedID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dropID: String?
    @State private var gridFrames: [String: CGRect] = [:]
    @State private var groupFrames: [String: CGRect] = [:]
    @State private var dropGroupKey: String?
    @State private var groupEditor: ControlCenterGroupEditorRequest?
    @State private var showsCardPicker = false
    @State private var addsDeviceAfterPickerDismiss = false
    @State private var sourcePreviewDemandID = UUID()
    private let ungroupedKey = "__ungrouped"
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private var devices: [ManagedDevice] { DeviceControlCenterPolicy.devices(model.settings.devices) }
    private var screenDevices: [ManagedDevice] {
        devices.filter { DeviceControlCenterPolicy.hasDisplay($0.type) || $0.type == .m5Controller }
    }
    private var dataSources: [DeviceControlCenterDataSource] { model.controlCenterDataSources() }
    private var layout: DeviceControlCenterLayout { model.settings.controlCenterLayout }
    private var compactDashboard: Bool { viewportWidth < 1200 }
    private var screenIDs: [String] { screenDevices.map { "device:" + $0.id.uuidString } }
    private var sourceIDs: [String] { dataSources.map { "source:" + $0.id } }
    private var allIDs: [String] { screenIDs + sourceIDs }
    private var visibleIDs: [String] { layout.visibleIDs(for: allIDs) }
    private var catalog: [ControlCenterCardCatalogItem] {
        screenDevices.map { .init(id: "device:" + $0.id.uuidString, title: $0.name,
                                 subtitle: $0.type.title, symbolName: $0.type.capabilityProfile?.icon ?? "display") }
        + dataSources.map { .init(id: "source:" + $0.id, title: $0.title, subtitle: $0.subtitle, symbolName: $0.symbolName) }
    }
    private var cards: [String: ControlCenterItem] {
        Dictionary(uniqueKeysWithValues:
            screenDevices.map { ("device:" + $0.id.uuidString, ControlCenterItem.device($0)) } +
            dataSources.map { ("source:" + $0.id, ControlCenterItem.source($0)) })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compactDashboard ? 16 : 24) {
                header
                if editingLayout {
                    Label("拖动卡片调整顺序或移入分组；右下角调整网格大小，卡片菜单也可选择分组。", systemImage: "hand.draw")
                        .font(.body).foregroundStyle(.secondary)
                }
                if allIDs.isEmpty && layout.groups.isEmpty {
                    ContentUnavailableView {
                        Label("你的设备，从这里开始", systemImage: "square.grid.2x2")
                    } description: { Text("添加屏幕、阅读器或控制设备，在这里集中查看。") }
                    actions: { Button("添加第一台设备", action: onAdd).buttonStyle(.borderedProminent) }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else if visibleIDs.isEmpty && !editingLayout {
                    ContentUnavailableView {
                        Label("还没有中控卡片", systemImage: "rectangle.stack.badge.plus")
                    } description: { Text("从已配置的设备与数据源中选择卡片。") }
                    actions: { Button("添加卡片") { showsCardPicker = true }.buttonStyle(.borderedProminent) }
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    cardGroup(nil)
                    ForEach(layout.groups) { group in
                        cardGroup(group)
                    }
                }
            }
            .padding(compactDashboard ? 16 : 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { viewportWidth = $0 }
        .task { registerSourcePreviewDemand(); refreshPreviews() }
        .onReceive(refresh) { _ in refreshPreviews() }
        .onChange(of: devices.map { "\($0.id):\($0.isEnabled)" }.joined()) { _ in registerSourcePreviewDemand(); refreshPreviews() }
        .onChange(of: dataSources.map(\.id).joined()) { _ in registerSourcePreviewDemand(); refreshPreviews() }
        .onChange(of: layout.hiddenCardIDs) { _ in registerSourcePreviewDemand(); refreshPreviews(); clearGesture() }
        .onPreferenceChange(ControlCenterCardFrameKey.self) { cardFrames = $0 }
        .onPreferenceChange(ControlCenterGroupFrameKey.self) { groupFrames = $0 }
        .onPreferenceChange(ControlCenterGridFrameKey.self) { gridFrames = $0 }
        .sheet(isPresented: $showsCardPicker, onDismiss: {
            guard addsDeviceAfterPickerDismiss else { return }
            addsDeviceAfterPickerDismiss = false
            onAdd()
        }) {
            ControlCenterCardPicker(items: catalog,
                layout: Binding(get: { model.settings.controlCenterLayout }, set: { model.settings.controlCenterLayout = $0 }),
                onAddDevice: {
                    addsDeviceAfterPickerDismiss = true
                    showsCardPicker = false
                }, onClose: { showsCardPicker = false })
                .controlCenterFloatingPresentationSurface()
        }
        .sheet(item: $groupEditor) { request in
            ControlCenterGroupNameEditor(title: request.title, renaming: request.groupID != nil) { name in
                if let id = request.groupID {
                    model.settings.controlCenterLayout.renameGroup(id, title: name)
                } else {
                    var updated = layout
                    if let id = updated.createGroup(title: name), let cardID = request.cardID {
                        updated.setGroup(for: cardID, to: id)
                    }
                    model.settings.controlCenterLayout = updated
                }
                groupEditor = nil
            } onCancel: { groupEditor = nil }
                .controlCenterFloatingPresentationSurface()
        }
        .onDisappear { model.endControlCenterSourcePreviewDemand(owner: sourcePreviewDemandID); clearGesture() }
        .onExitCommand { clearGesture() }
        .accessibilityIdentifier("device-control-center")
    }
    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("中控面板").font(compactDashboard ? .title2.weight(.bold) : .largeTitle.weight(.bold))
            Text("设备与数据一览，点按卡片展开详情。")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                headerTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                headerControls
            }
            VStack(alignment: .leading, spacing: 18) {
                headerTitle
                headerControls
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var headerControls: some View {
        ViewThatFits(in: .horizontal) {
            layoutControls(showsGroupButton: true)
            layoutControls(showsGroupButton: false)
        }
    }
    private func layoutControls(showsGroupButton: Bool) -> some View {
        HStack(spacing: 10) {
            Button { editingLayout.toggle(); clearGesture() } label: {
                Label(LocalizedStringKey(editingLayout ? "完成" : "编辑布局"), systemImage: editingLayout ? "checkmark" : "slider.horizontal.3")
            }.buttonStyle(.bordered).controlSize(compactDashboard ? .regular : .large)
                .accessibilityIdentifier("control-center-edit-layout")
            if editingLayout && showsGroupButton {
                Button { groupEditor = .init(groupID: nil, title: "", cardID: nil) } label: {
                    Label("新建分组", systemImage: "folder.badge.plus")
                }.buttonStyle(.bordered).controlSize(compactDashboard ? .regular : .large)
                    .accessibilityIdentifier("control-center-add-group")
            }
            Menu {
                Button("新建分组") { groupEditor = .init(groupID: nil, title: "", cardID: nil) }
                Divider()
                Button("恢复默认布局") { model.settings.controlCenterLayout.reset(); clearGesture() }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().help(String(localized: "布局选项"))
            Button { showsCardPicker = true } label: { Label("添加卡片", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(compactDashboard ? .regular : .large)
                .accessibilityIdentifier("control-center-add-card")
        }.fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private func cardGroup(_ group: DeviceControlCenterGroup?) -> some View {
        let ids = layout.visibleIDs(for: allIDs, inGroup: group?.id)
        let key = group?.id ?? ungroupedKey
        if !ids.isEmpty || group != nil || (editingLayout && !layout.groups.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                if group != nil || !layout.groups.isEmpty {
                    HStack(spacing: 10) {
                        Text(group?.title ?? String(localized: "未分组")).font(.title2.weight(.semibold))
                        Text(ids.count, format: .number).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        if let group, editingLayout {
                            Menu {
                                Button("重新命名分组") { groupEditor = .init(groupID: group.id, title: group.title, cardID: nil) }
                                Button("向前移动") {
                                    if let index = layout.groups.firstIndex(where: { $0.id == group.id }) {
                                        model.settings.controlCenterLayout.moveGroup(group.id, to: index - 1)
                                    }
                                }.disabled(layout.groups.first?.id == group.id)
                                Button("向后移动") {
                                    if let index = layout.groups.firstIndex(where: { $0.id == group.id }) {
                                        model.settings.controlCenterLayout.moveGroup(group.id, to: index + 1)
                                    }
                                }.disabled(layout.groups.last?.id == group.id)
                                Divider()
                                Button("解散分组，保留卡片") { model.settings.controlCenterLayout.removeGroup(group.id) }
                            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                                .menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel(Text("分组选项"))
                                .accessibilityIdentifier("control-center-group-menu-\(group.id)")
                        }
                    }
                }
                if ids.isEmpty {
                    Text(LocalizedStringKey(editingLayout ? "将卡片拖到这里，或从卡片菜单选择此分组。" : "暂无卡片，可在编辑布局中添加。"))
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: editingLayout ? 108 : 60)
                } else {
                    ControlCenterFlowLayout {
                        ForEach(ids, id: \.self) { id in
                            if let item = cards[id] {
                                editableCard(id: id, title: item.title, section: ids) { height in
                                    switch item {
                                    case .device(let device):
                                        DeviceControlCenterCard(device: device, preview: previews[device.id], height: height,
                                            action: { onOpen(device.id, cardFrames[id]) })
                                    case .source(let source):
                                        if source.kind == .nowPlaying {
                                            ControlCenterNowPlayingCard(model: model, size: resized[id] ?? layout.size(for: id),
                                                                       height: height, action: { onOpenDataSource(source.destination) })
                                        } else if source.kind == .printer {
                                            ControlCenterPrinterCard(source: source, snapshot: model.controlCenterPrinterSnapshot(for: source),
                                                                     height: height, action: { onOpenDataSource(source.destination) })
                                        } else if source.kind == .homeAssistant {
                                            ControlCenterHomeAssistantCard(model: model, source: source, height: height,
                                                action: { onOpenDataSource(source.destination) })
                                        } else if source.kind == .cloudflare {
                                            ControlCenterCloudflareCard(model: model, source: source, height: height,
                                                action: { onOpenDataSource(source.destination) })
                                        } else if source.kind == .weather {
                                            ControlCenterWeatherCard(model: model, source: source, height: height,
                                                action: { onOpenDataSource(source.destination) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { gridWidth = $0 }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ControlCenterGridFrameKey.self,
                                                   value: [key: geometry.frame(in: .global)])
                        }
                    }
                }
            }
            .padding(editingLayout && !layout.groups.isEmpty ? 12 : 0)
            .zIndex(draggedID.map { layout.groupID(for: $0) == group?.id } == true ? 1 : 0)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ControlCenterGroupFrameKey.self, value: [key: geometry.frame(in: .global)])
                }
            }
            .overlay {
                if editingLayout && !layout.groups.isEmpty {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(dropGroupKey == key ? Color.accentColor : Color.secondary.opacity(0.16),
                                      style: StrokeStyle(lineWidth: dropGroupKey == key ? 2 : 1, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            }
        }
    }
    private func editableCard<Content: View>(id: String, title: String, section: [String],
                                             @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        let order = layout.orderedIDs(for: section)
        let index = order.firstIndex(of: id) ?? 0
        return EditableControlCenterCard(id: id, title: title, size: resized[id] ?? layout.size(for: id),
            editing: editingLayout, dragOffset: draggedID == id ? dragOffset : .zero,
            dropTarget: dropID == id, canMoveEarlier: index > 0, canMoveLater: index < order.count - 1,
            onReorder: { value, ended in reorder(id, value: value, ended: ended) },
            onResize: { translation, ended in resize(id, translation: translation, ended: ended) },
            onSetSize: { width, height in model.settings.controlCenterLayout.setSize(for: id, width: width, height: height) },
            onResetSize: { model.settings.controlCenterLayout.resetSize(for: id) },
            onMove: { delta in model.settings.controlCenterLayout.move(id, to: index + delta, availableIDs: section, allAvailableIDs: allIDs) },
            groups: layout.groups, currentGroupID: layout.groupID(for: id),
            onSetGroup: { model.settings.controlCenterLayout.setGroup(for: id, to: $0) },
            onNewGroup: { groupEditor = .init(groupID: nil, title: "", cardID: id) },
            onRemove: { model.settings.controlCenterLayout.setCardVisible(false, for: id); clearGesture() },
            sizeOptions: sizeOptions(for: id),
            content: content)
            .zIndex(draggedID == id ? 1 : 0)
    }
    private func sizeOptions(for id: String) -> ControlCenterCardSizeOptions {
        guard let item = cards[id], case .source(let source) = item,
              source.kind == .nowPlaying || source.kind == .printer else { return .grid }
        return .smallMediumLarge
    }
    private func resize(_ id: String, translation: CGSize, ended: Bool) {
        if resizeGrid == nil {
            resizeGrid = DeviceControlCenterLayoutEngine.grid(availableWidth: gridWidth)
            resizeOriginal = layout.size(for: id)
        }
        let grid = resizeGrid ?? DeviceControlCenterLayoutEngine.grid(availableWidth: gridWidth)
        let original = resizeOriginal ?? layout.size(for: id)
        let candidate = grid.snappedSize(original: original, translation: translation)
        let size = sizeOptions(for: id).constrainedResize(candidate, original: original)
        if ended {
            model.settings.controlCenterLayout.setSize(for: id, width: size.preferredWidth, height: size.preferredHeight)
            resized[id] = nil; resizeGrid = nil; resizeOriginal = nil
        } else { resized[id] = size }
    }
    private func reorder(_ id: String, value: DragGesture.Value, ended: Bool) {
        draggedID = id; dragOffset = value.translation
        let groupKey = groupFrames.first(where: { $0.value.contains(value.location) })?.key
        dropGroupKey = groupKey
        let targetGroupID = groupKey == ungroupedKey ? nil : groupKey
        var section = layout.visibleIDs(for: allIDs, inGroup: targetGroupID)
        if !section.contains(id) { section.append(id) }
        let others = section.filter { $0 != id }
        let insertion: Int?
        if let groupKey, let frame = gridFrames[groupKey] {
            let localPoint = CGPoint(x: value.location.x - frame.minX, y: value.location.y - frame.minY)
            insertion = DeviceControlCenterLayoutEngine.insertionIndex(for: id, at: localPoint,
                items: section.map { .init(id: $0, size: resized[$0] ?? layout.size(for: $0)) },
                availableWidth: frame.width)
        } else {
            insertion = groupKey != nil && others.isEmpty ? 0 : nil
        }
        // Keep an adjacent card highlighted, while resolving the actual drop
        // against grid cells so empty cells can be filled too.
        dropID = insertion.flatMap { index in
            others.isEmpty ? nil : others[min(index, others.count - 1)]
        }
        if ended {
            if groupKey != nil, let insertion {
                var updated = layout
                updated.setGroup(for: id, to: targetGroupID)
                updated.move(id, to: insertion, availableIDs: section, allAvailableIDs: allIDs)
                model.settings.controlCenterLayout = updated
            }
            clearGesture()
        }
    }
    private func clearGesture() {
        draggedID = nil; dragOffset = .zero; dropID = nil; dropGroupKey = nil; resized = [:]; resizeGrid = nil; resizeOriginal = nil
    }
    private func refreshPreviews() {
        let visible = screenDevices.filter { layout.isCardVisible("device:" + $0.id.uuidString) }
        let ids = Set(visible.map(\.id))
        var next = previews.filter { ids.contains($0.key) }
        var imageData = previewImageData.filter { ids.contains($0.key) }
        var changed = next.count != previews.count
        for device in visible {
            let fresh = model.controlCenterPreview(for: device)
            let previous = previews[device.id]
            // Retain a transiently unavailable frame, while making its age explicit.
            let current: DeviceControlCenterPreview
            if device.isEnabled, fresh.image == nil, let previous, previous.image != nil {
                current = .init(image: previous.image, source: previous.source,
                                status: String(localized: "显示上次画面，等待更新"))
            } else { current = fresh }
            let sameImageReference = current.image === previous?.image
            let bytes = sameImageReference ? imageData[device.id] : current.image?.tiffRepresentation
            if let previous, previous.status == current.status, previous.caption == current.caption,
               sameImageReference || (bytes != nil && bytes == imageData[device.id]) { continue }
            let image = bytes != nil && bytes == imageData[device.id] ? previous?.image : current.image
            next[device.id] = .init(image: image, source: current.source, status: current.status)
            imageData[device.id] = bytes
            changed = true
        }
        if changed { previews = next; previewImageData = imageData }
    }
    private func registerSourcePreviewDemand() {
        let ids = Set(dataSources.compactMap { source -> UUID? in
            guard layout.isCardVisible("source:" + source.id) else { return nil }
            guard case .managedDevice(let id) = source.destination else { return nil }
            return id
        })
        model.beginControlCenterSourcePreviewDemand(owner: sourcePreviewDemandID, deviceIDs: ids)
    }
}

private enum ControlCenterItem {
    case device(ManagedDevice)
    case source(DeviceControlCenterDataSource)
    var title: String {
        switch self { case .device(let device): device.name; case .source(let source): source.title }
    }
}

private struct ControlCenterGridFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ControlCenterGroupFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ControlCenterGroupEditorRequest: Identifiable {
    let id = UUID()
    let groupID: String?
    let title: String
    let cardID: String?
}

private struct ControlCenterGroupNameEditor: View {
    @State var title: String
    let renaming: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizedStringKey(renaming ? "重新命名分组" : "新建分组")).font(.title2.weight(.semibold))
            TextField("分组名称", text: $title).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { save() }.accessibilityIdentifier("control-center-group-name")
            Text("设备和数据源可以放在同一个分组，卡片内容保持不变。")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 390).onAppear { focused = true }
    }
    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onSave(name) }
    }
}

private struct DeviceControlCenterDataSourceCard: View {
    let source: DeviceControlCenterDataSource
    let preview: NSImage?
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high).scaledToFit()
                            .padding(18)
                            .accessibilityLabel(String(localized: "数据预览"))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: source.symbolName).font(.system(size: 36, weight: .regular))
                            Text(source.previewError == nil ? String(localized: "暂无数据画面") : String(localized: "连接失败"))
                                .font(.body).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(20)
                    }
                }.frame(minHeight: 100, maxHeight: .infinity).clipped().layoutPriority(-1)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: source.symbolName).font(.body).foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(source.title).font(.headline).lineLimit(2)
                        Text(source.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(source.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
            .controlCenterGlassCard(hovering: hovering)
        }
        .buttonStyle(ControlCenterCardButtonStyle())
        .onHover { hovering = $0 }
        .help(String(localized: "打开数据源设置"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "打开数据源设置"))
        .accessibilityIdentifier("control-center-source-\(source.id)")
    }
}

private struct DeviceControlCenterCard: View {
    let device: ManagedDevice
    let preview: DeviceControlCenterPreview?
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    private var icon: String { device.type.capabilityProfile?.icon ?? "externaldrive" }
    private var compact: Bool { height < 330 }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if device.type == .readPico {
                        ReadPicoDevicePreview(image: preview?.image).padding(14)
                    } else if let image = preview?.image {
                        DeviceControlCenterPreviewSurface(deviceType: device.type, image: image)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: icon).font(.system(size: 36, weight: .regular))
                            Text(preview?.caption ?? String(localized: "暂无画面"))
                                .font(.body).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(20)
                    }
                }.frame(minHeight: 100, maxHeight: .infinity).clipped().layoutPriority(-1)
                VStack(alignment: .leading, spacing: compact ? 5 : 9) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(device.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if !compact {
                        Text(device.type.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Label(preview?.caption ?? String(localized: "暂无画面"),
                          systemImage: device.isEnabled ? (preview?.image == nil ? "rectangle.dashed" : "rectangle") : "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    if !compact || preview?.image == nil {
                        Text(preview?.status ?? String(localized: "打开设备后可查看可用预览"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
                    }
                }.padding(compact ? 12 : 16).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
            .controlCenterGlassCard(hovering: hovering)
        }
        .buttonStyle(ControlCenterCardButtonStyle())
        .onHover { hovering = $0 }
        .help(String(localized: "打开设备设置"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name)，\(device.type.title)，\(preview?.caption ?? "")")
        .accessibilityHint(String(localized: "打开设备设置"))
        .accessibilityIdentifier("control-center-device-\(device.id.uuidString)")
    }
}
