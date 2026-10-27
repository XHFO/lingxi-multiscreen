import AppKit
import LinxDisplayCore
import SwiftUI

/// The overview owns its own entity choices. Building this card, opening its editor
/// and changing its layout never executes a Home Assistant service.
struct ControlCenterHomeAssistantCard: View {
    @ObservedObject var model: AppModel
    let source: DeviceControlCenterDataSource
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @State private var showingEditor = false
    @State private var operations: [String: UUID] = [:]
    @State private var messages: [String: String] = [:]
    @State private var overrides: [String: ConfirmedReading] = [:]

    private struct ConfirmedReading {
        let fingerprint: String
        let baseline: HAEntity
        let confirmed: HAEntity
    }
    private var context: ControlCenterHAContext? { model.controlCenterHAContext(for: source) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 340 || geometry.size.height < 310
            let inset: CGFloat = compact ? 14 : 22
            let columns = geometry.size.width - inset * 2 >= 440 ? 2 : 1
            let gap: CGFloat = compact ? 8 : 10
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                HStack(spacing: compact ? 8 : 10) {
                    Button(action: action) {
                        HStack(spacing: compact ? 8 : 10) {
                            Image(systemName: "house.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                    .help(source.title)
                                Text("Home Assistant").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text("打开 Home Assistant 设置"))
                    Button { showingEditor = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
                    }.buttonStyle(.plain)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(String(localized: "选择实体"))
                        .disabled(context == nil)
                        .accessibilityLabel(Text("选择实体"))
                        .accessibilityIdentifier("control-center-ha-edit-\(source.id)")
                }
                if let context, !context.selectedEntityIDs.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns), spacing: gap) {
                            ForEach(context.selectedEntityIDs, id: \.self) { id in
                                entityTile(id, context: context, compact: compact)
                            }
                        }.padding(.trailing, 2)
                    }.scrollIndicators(.automatic)
                } else {
                    emptyContent(compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    // Empty/error content already presents the same connection
                    // failure. Keep the footer action without repeating it.
                    if context?.error == nil || context?.selectedEntityIDs.isEmpty == false {
                        Text(footerText).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(context?.error == nil && compact ? 1 : 2)
                            .help(footerText)
                    }
                    Spacer(minLength: 0)
                    Button("连接设置", action: action).buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize().frame(minHeight: 28)
                }
            }
            .padding(inset)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(height: height)
        .controlCenterGlassCard(hovering: hovering)
        .onHover { hovering = $0 }
        .onChange(of: context?.fingerprint) {
            operations.removeAll(); messages.removeAll(); overrides.removeAll()
        }
        .popover(isPresented: $showingEditor, arrowEdge: .top) {
            ControlCenterHAEntityEditor(model: model, source: source) { showingEditor = false }
                .controlCenterFloatingPresentationSurface()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-center-source-\(source.id)")
    }

    private var footerText: String {
        if let error = context?.error { return error }
        guard let context else { return source.status }
        return context.entities.isEmpty ? String(localized: "等待实体读取")
            : String(localized: "独立于屏幕卡片的显示内容")
    }

    private func emptyContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Image(systemName: "lightbulb.2")
                .font(.system(size: compact ? 24 : 34, weight: .regular)).foregroundStyle(.secondary)
            Text(context?.error == nil ? String(localized: "选择实体") : String(localized: "连接失败"))
                .font(compact ? .system(size: 14, weight: .semibold) : .title3.weight(.semibold))
            Text(context?.error ?? String(localized: "将常用开关和状态添加到这里。"))
                .font(compact ? .system(size: 12) : .subheadline).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 3)
                .help(context?.error ?? String(localized: "将常用开关和状态添加到这里。"))
            Button("选择实体") { showingEditor = true }
                .buttonStyle(.borderedProminent).disabled(context == nil)
                .controlSize(compact ? .small : .regular)
                .frame(minHeight: 28)
        }
    }

    private func displayedEntity(_ id: String, context: ControlCenterHAContext) -> HAEntity? {
        guard let baseline = context.entities.first(where: { $0.entityId == id }) else { return nil }
        if let reading = overrides[id], reading.fingerprint == context.fingerprint, reading.baseline == baseline {
            return reading.confirmed
        }
        return baseline
    }

    private func entityTile(_ id: String, context: ControlCenterHAContext, compact: Bool) -> some View {
        let entity = displayedEntity(id, context: context)
        let available = entity.map(ControlCenterHAControlPolicy.isAvailable) ?? false
        let controllable = entity.map(ControlCenterHAControlPolicy.isControllable) ?? false
        let inFlight = operations[id] != nil
        let isOn = entity?.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on"
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .center, spacing: compact ? 8 : 10) {
                Image(systemName: entity.map(SFIconMapper.symbol(for:)) ?? "questionmark.circle")
                    .font(compact ? .system(size: 17) : .title3)
                    .foregroundStyle(available && isOn ? Color.orange : Color.secondary)
                    .frame(width: compact ? 20 : 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity?.displayName ?? id)
                        .font(compact ? .system(size: 12, weight: .semibold) : .subheadline.weight(.semibold))
                        .lineLimit(2).help(entity?.displayName ?? id)
                    Text(available ? (entity?.displayValue ?? "") : String(localized: "实体离线或不可用"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if controllable {
                    Button {
                        guard let entity else { return }
                        execute(entity, context: context)
                    } label: {
                        ZStack {
                            Image(systemName: "power").opacity(inFlight ? 0 : 1)
                            if inFlight { ProgressView().controlSize(.small) }
                        }.frame(width: compact ? 28 : 32, height: 28)
                    }
                    .buttonStyle(.plain).tint(isOn ? .orange : .secondary)
                    .foregroundStyle(isOn ? Color.orange : Color.secondary)
                    .background(Color.primary.opacity(isOn ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(!available || inFlight)
                    .help(isOn ? String(localized: "关闭") : String(localized: "开启"))
                    .accessibilityLabel(Text((isOn ? String(localized: "关闭") : String(localized: "开启")) + " " + (entity?.displayName ?? id)))
                    .accessibilityValue(inFlight ? Text("正在执行…") : Text(entity?.displayState ?? ""))
                    .accessibilityIdentifier("control-center-ha-control-\(id)")
                } else {
                    Text("只读").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
            }
            if let message = messages[id] {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).help(message)
            }
        }
        .padding(compact ? 9 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 62 : 72, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func execute(_ entity: HAEntity, context: ControlCenterHAContext) {
        guard operations[entity.entityId] == nil else { return }
        let requestID = UUID()
        operations[entity.entityId] = requestID
        messages[entity.entityId] = nil
        let baseline = context.entities.first(where: { $0.entityId == entity.entityId }) ?? entity
        let turnOn = entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "on"
        Task { @MainActor in
            let result = await model.performControlCenterHAAction(source: source, entityID: entity.entityId,
                                                                  expectedFingerprint: context.fingerprint, turnOn: turnOn)
            guard operations[entity.entityId] == requestID,
                  self.context?.fingerprint == context.fingerprint else { return }
            operations[entity.entityId] = nil
            switch result {
            case .success(let reading):
                if let updated = reading.entity {
                    overrides[entity.entityId] = ConfirmedReading(fingerprint: context.fingerprint,
                                                                  baseline: baseline, confirmed: updated)
                }
                messages[entity.entityId] = reading.message
            case .failure(let error): messages[entity.entityId] = error.localizedDescription
            }
        }
    }
}

private struct ControlCenterHAEntityEditor: View {
    @ObservedObject var model: AppModel
    let source: DeviceControlCenterDataSource
    let onClose: () -> Void
    @State private var fingerprint = ""
    @State private var selected: [String] = []
    @State private var keyword = ""
    @State private var filter = 0
    @State private var error: String?
    private var context: ControlCenterHAContext? { model.controlCenterHAContext(for: source) }
    private var candidates: [HAEntity] {
        let all = context?.entities ?? []
        let base = filter == 0 ? all.filter(ControlCenterHAControlPolicy.isControllable)
            : filter == 2 ? selected.map { id in
                all.first { $0.entityId == id } ?? HAEntity(entityId: id, friendlyName: id, state: "unavailable", unitOfMeasurement: nil)
            } : all
        return HAEntityPicker.filter(base, keyword: keyword)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择实体").font(.title3.weight(.semibold))
                Spacer()
                Text(selected.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("仅影响中控面板，不更改设备屏幕内容。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("搜索名称、entity_id 或分类", text: $keyword).textFieldStyle(.roundedBorder)
            Picker("实体筛选", selection: $filter) {
                Text("可控制").tag(0)
                Text("全部实体").tag(1)
                Text("已选择").tag(2)
            }.pickerStyle(.segmented)
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label("暂无匹配实体", systemImage: "magnifyingglass")
                } description: {
                    Text(context?.entities.isEmpty == true ? "请先在连接设置中读取实体。" : "尝试其他搜索词或切换筛选。")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates, id: \.entityId) { entity in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { selected.contains(entity.entityId) }, set: { enabled in
                            if enabled { selected.append(entity.entityId) }
                            else { selected.removeAll { $0 == entity.entityId } }
                        })) {
                            HStack(spacing: 10) {
                                Image(systemName: SFIconMapper.symbol(for: entity)).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entity.displayName).font(.body).lineLimit(1)
                                    Text(entity.entityId).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(entity.displayValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox)
                        if filter == 2, let index = selected.firstIndex(of: entity.entityId) {
                            VStack(spacing: 2) {
                                Button { selected.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(index == 0).help(String(localized: "向前移动"))
                                Button { selected.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(index == selected.count - 1).help(String(localized: "向后移动"))
                            }.buttonStyle(.borderless).font(.caption2)
                        }
                    }.padding(.vertical, 5)
                }.listStyle(.inset).controlCenterHostedFormSurface()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !fingerprint.isEmpty, context?.fingerprint != fingerprint {
                Text("连接已变更，请重新选择实体。").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("清除选择") { selected = [] }.disabled(selected.isEmpty)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("完成") {
                    guard model.setControlCenterHASelection(source: source, expectedFingerprint: fingerprint, entityIDs: selected) else {
                        error = String(localized: "连接已变更，请重新选择实体。")
                        return
                    }
                    onClose()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(fingerprint.isEmpty || context?.fingerprint != fingerprint)
            }
        }
        .padding(20).frame(width: 540, height: 550)
        .onAppear {
            fingerprint = context?.fingerprint ?? ""
            selected = context?.selectedEntityIDs ?? []
        }
    }
}

struct ControlCenterHAContext {
    let sourceID: UUID
    let fingerprint: String
    let entities: [HAEntity]
    let selectedEntityIDs: [String]
    let error: String?
}

struct ControlCenterHAActionReading {
    let entity: HAEntity?
    let message: String?
}

/// Injectable only for focused, network-free regression checks. The production
/// transport continues to use the existing authenticated Home Assistant API.
struct ControlCenterHAActionTransport {
    let send: (HASharedConnection, HAServiceCommand) async throws -> Void
    let read: (HASharedConnection, String) async throws -> HAEntity
    let confirmationDelay: UInt64

    static let live = Self(send: { connection, command in
        try await HomeAssistantClient.callService(serverURL: connection.serverURL, token: connection.token, command: command)
    }, read: { connection, id in
        try await HomeAssistantClient.fetchState(serverURL: connection.serverURL, token: connection.token, entityID: id)
    }, confirmationDelay: 250_000_000)
}

enum ControlCenterHAActionError: LocalizedError {
    case sourceChanged, unavailable, unsupported, service(HAError)
    var errorDescription: String? {
        switch self {
        case .sourceChanged: return String(localized: "连接已变更，请重新选择实体。")
        case .unavailable: return String(localized: "实体离线或不可用")
        case .unsupported: return String(localized: "此实体仅支持查看状态")
        case .service(let error): return error.errorDescription
        }
    }
}

extension AppModel {
    @MainActor private func overviewHAConnection(sourceID: UUID) -> HASharedConnection? {
        guard let device = settings.devices.first(where: { $0.id == sourceID && $0.type == .homeAssistant && $0.isEnabled }) else { return nil }
        return HASharedConnectionResolver.resolve(serverURL: settings.haServerURL, token: settings.haToken,
                                                  legacyServerURL: device.settings.haServerURL,
                                                  legacyToken: device.settings.haToken)
    }

    @MainActor func controlCenterHAContext(for source: DeviceControlCenterDataSource) -> ControlCenterHAContext? {
        guard source.kind == .homeAssistant, case .managedDevice(let id) = source.destination,
              let connection = overviewHAConnection(sourceID: id) else { return nil }
        return ControlCenterHAContext(sourceID: id, fingerprint: connection.fingerprint,
            entities: existingHASourceEntities(for: id) ?? [],
            selectedEntityIDs: settings.controlCenterLayout.homeAssistantEntityIDs(for: source.id,
                connectionFingerprint: connection.fingerprint), error: controlCenterHAPreviewError(for: id))
    }

    @MainActor func setControlCenterHASelection(source: DeviceControlCenterDataSource,
                                               expectedFingerprint: String, entityIDs: [String]) -> Bool {
        guard let context = controlCenterHAContext(for: source), context.fingerprint == expectedFingerprint else { return false }
        let known = Set(context.entities.map(\.entityId))
        // Existing unavailable selections can be removed or retained, but arbitrary
        // entity IDs cannot be injected by a stale editor or another source.
        let allowed = known.union(context.selectedEntityIDs)
        guard entityIDs.allSatisfy({ allowed.contains($0) }) else { return false }
        var layout = settings.controlCenterLayout
        _ = layout.setHomeAssistantEntities(for: source.id, connectionFingerprint: expectedFingerprint, entityIDs: entityIDs)
        settings.controlCenterLayout = layout
        return true
    }

    /// Only the explicit power button calls this method. The source UUID, current
    /// saved selection, successful-reading origin and credentials are checked again
    /// before sending; responses are discarded if that connection changes midflight.
    @MainActor func performControlCenterHAAction(source: DeviceControlCenterDataSource, entityID: String,
                                                expectedFingerprint: String, turnOn: Bool,
                                                transport: ControlCenterHAActionTransport = .live) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        guard let context = controlCenterHAContext(for: source), context.fingerprint == expectedFingerprint,
              let connection = overviewHAConnection(sourceID: context.sourceID) else { return .failure(.sourceChanged) }
        guard let entity = context.entities.first(where: { $0.entityId == entityID }),
              ControlCenterHAControlPolicy.isAvailable(entity) else { return .failure(.unavailable) }
        guard let command = ControlCenterHAControlPolicy.command(for: entity,
            selectedEntityIDs: context.selectedEntityIDs, expectedFingerprint: expectedFingerprint,
            currentFingerprint: connection.fingerprint, turnOn: turnOn) else { return .failure(.unsupported) }
        do {
            try await transport.send(connection, command)
        } catch {
            guard overviewHAConnection(sourceID: context.sourceID)?.fingerprint == expectedFingerprint else { return .failure(.sourceChanged) }
            return .failure(.service((error as? HAError) ?? .cannotConnect))
        }
        guard overviewHAConnection(sourceID: context.sourceID)?.fingerprint == expectedFingerprint else { return .failure(.sourceChanged) }
        try? await Task.sleep(nanoseconds: transport.confirmationDelay)
        guard overviewHAConnection(sourceID: context.sourceID)?.fingerprint == expectedFingerprint else { return .failure(.sourceChanged) }
        do {
            let updated = try await transport.read(connection, entityID)
            guard controlCenterHAContext(for: source)?.fingerprint == expectedFingerprint else { return .failure(.sourceChanged) }
            guard updated.entityId == entityID else {
                return .success(ControlCenterHAActionReading(entity: nil,
                    message: String(localized: "操作已发送，状态暂未更新")))
            }
            return .success(ControlCenterHAActionReading(entity: updated, message: nil))
        } catch {
            guard overviewHAConnection(sourceID: context.sourceID)?.fingerprint == expectedFingerprint else { return .failure(.sourceChanged) }
            return .success(ControlCenterHAActionReading(entity: nil, message: String(localized: "操作已发送，状态暂未更新")))
        }
    }
}
