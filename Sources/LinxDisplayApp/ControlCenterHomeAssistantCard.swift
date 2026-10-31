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
    @State private var sliderValues: [String: Double] = [:]
    @State private var climateTargets: [String: Double] = [:]

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
                    let sensorIDs = Set(context.selectedEntityIDs.filter { id in
                        displayedEntity(id, context: context)?.isClimateSensor == true
                    })
                    ScrollView {
                        VStack(alignment: .leading, spacing: gap) {
                            if !sensorIDs.isEmpty {
                                climateSensorsTile(context.selectedEntityIDs.filter { sensorIDs.contains($0) },
                                                   context: context, compact: compact)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns), spacing: gap) {
                                ForEach(context.selectedEntityIDs.filter { !sensorIDs.contains($0) }, id: \.self) { id in
                                    entityTile(id, context: context, compact: compact)
                                }
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
            sliderValues.removeAll(); climateTargets.removeAll()
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

    private func climateSensorsTile(_ ids: [String], context: ControlCenterHAContext,
                                    compact: Bool) -> some View {
        let sensors = ids.compactMap { displayedEntity($0, context: context) }
        return HStack(spacing: 0) {
            ForEach(Array(sensors.enumerated()), id: \.element.entityId) { index, entity in
                VStack(spacing: compact ? 3 : 5) {
                    Image(systemName: SFIconMapper.symbol(for: entity))
                        .font(compact ? .system(size: 16) : .title3)
                        .foregroundStyle(Color.orange)
                    Text(entity.displayName)
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(entity.displayValue)
                        .font(.system(size: compact ? 17 : 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                if index < sensors.count - 1 {
                    Divider().frame(height: compact ? 40 : 52)
                }
            }
        }
        .padding(compact ? 10 : 14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(sensors.map { "\($0.displayName) \($0.displayValue)" }.joined(separator: "，")))
    }

    private func entityTile(_ id: String, context: ControlCenterHAContext, compact: Bool) -> some View {
        let entity = displayedEntity(id, context: context)
        let available = entity.map(ControlCenterHAControlPolicy.isAvailable) ?? false
        let controllable = entity.map(ControlCenterHAControlPolicy.isControllable) ?? false
        let inFlight = operations[id] != nil
        let isOn = entity.map(ControlCenterHAControlPolicy.isPowerOn) ?? false
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
                    powerButton(id: id, entity: entity, context: context, compact: compact,
                                isOn: isOn, available: available, inFlight: inFlight)
                } else {
                    Text("只读").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
            }
            if let entity, available, controllable {
                if entity.isDimmableLight {
                    Spacer(minLength: 0)
                    brightnessControl(entity, context: context, compact: compact)
                    Spacer(minLength: 0)
                } else if entity.isSpeedFan {
                    Spacer(minLength: 0)
                    fanControl(entity, context: context, compact: compact)
                    Spacer(minLength: 0)
                } else if entity.isClimate {
                    climateControl(entity, context: context, compact: compact)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Text(entity.displayState)
                        .font(.system(size: compact ? 25 : 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(isOn ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
            if let message = messages[id] {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).help(message)
            }
        }
        .padding(compact ? 9 : 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: compact ? 156 : 170, alignment: .topLeading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func powerButton(id: String, entity: HAEntity?, context: ControlCenterHAContext,
                             compact: Bool, isOn: Bool, available: Bool, inFlight: Bool) -> some View {
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
        .background(Color.primary.opacity(isOn ? 0.08 : 0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(!available || inFlight)
        .help(isOn ? String(localized: "关闭") : String(localized: "开启"))
        .accessibilityLabel(Text((isOn ? String(localized: "关闭") : String(localized: "开启"))
            + " " + (entity?.displayName ?? id)))
        .accessibilityValue(inFlight ? Text("正在执行…") : Text(entity?.displayState ?? ""))
        .accessibilityIdentifier("control-center-ha-control-\(id)")
    }

    private func brightnessControl(_ entity: HAEntity, context: ControlCenterHAContext,
                                   compact: Bool) -> some View {
        let value = sliderValues[entity.entityId]
            ?? Double(entity.brightnessPercent ?? (entity.state.lowercased() == "on" ? 100 : 0))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("亮度").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.rounded()))%").font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { sliderValues[entity.entityId] ?? value },
                                  set: { sliderValues[entity.entityId] = $0 }),
                   in: 0...100, step: 1) { editing in
                guard !editing else { return }
                let percent = Int((sliderValues[entity.entityId] ?? value).rounded())
                sendBrightness(entity, context: context, percent: percent)
            }
            .tint(.orange)
            .controlSize(.small)
        }
    }

    private func fanControl(_ entity: HAEntity, context: ControlCenterHAContext,
                            compact: Bool) -> some View {
        let value = sliderValues[entity.entityId] ?? Double(entity.percentage ?? 0)
        let step = max(entity.percentageStep ?? 1, 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("风速").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.rounded()))%").font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { sliderValues[entity.entityId] ?? value },
                                  set: { sliderValues[entity.entityId] = $0 }),
                   in: 0...100, step: step) { editing in
                guard !editing else { return }
                let percent = Int((sliderValues[entity.entityId] ?? value).rounded())
                sendFan(entity, context: context, percent: percent)
            }
            .tint(.teal)
            .controlSize(.small)
        }
    }

    private func climateControl(_ entity: HAEntity, context: ControlCenterHAContext,
                                compact: Bool) -> some View {
        let step = max(entity.targetTemperatureStep ?? 0.5, 0.5)
        let rawLower = entity.minTemperature ?? 16
        let rawUpper = entity.maxTemperature ?? 30
        let lower = min(rawLower, rawUpper - step)
        let upper = max(rawUpper, lower + step)
        let target = min(max(climateTargets[entity.entityId] ?? entity.targetTemperature ?? 22, lower), upper)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    adjustClimate(entity, context: context, target: target - step, lower: lower, upper: upper)
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .accessibilityLabel(Text("降低目标温度"))
                VStack(spacing: 1) {
                    Text(String(format: "%.1f°", target))
                        .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("目标温度").font(.system(size: 9)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Button {
                    adjustClimate(entity, context: context, target: target + step, lower: lower, upper: upper)
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .accessibilityLabel(Text("提高目标温度"))
            }
            Slider(value: Binding(get: {
                min(max(climateTargets[entity.entityId] ?? target, lower), upper)
            }, set: { climateTargets[entity.entityId] = min(max($0, lower), upper) }),
                   in: lower...upper, step: step) { editing in
                guard !editing else { return }
                let value = climateTargets[entity.entityId] ?? target
                sendClimate(entity, context: context, temperature: value)
            }
            .tint(.orange)
            .controlSize(.small)
            if let modes = entity.hvacModes, !modes.isEmpty {
                Menu {
                    ForEach(modes, id: \.self) { mode in
                        Button {
                            sendClimateMode(entity, context: context, mode: mode)
                        } label: {
                            Label(hvacModeTitle(mode), systemImage: hvacModeSymbol(mode))
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: hvacModeSymbol(entity.state))
                        Text(hvacModeTitle(entity.state))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text("空调模式"))
                .accessibilityValue(Text(hvacModeTitle(entity.state)))
            }
            HStack(spacing: 6) {
                if let current = entity.currentTemperature {
                    Text("室温 " + String(format: "%.1f°", current))
                }
                if let humidity = entity.currentHumidity {
                    Text("湿度 " + String(format: "%.0f%%", humidity))
                }
                Spacer(minLength: 0)
                if let action = entity.hvacAction, !action.isEmpty {
                    Text(action)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func sendClimateMode(_ entity: HAEntity, context: ControlCenterHAContext, mode: String) {
        runOperation(entity, context: context) {
            await model.performControlCenterHAClimateModeAction(source: source, entityID: entity.entityId,
                expectedFingerprint: context.fingerprint, mode: mode)
        }
    }

    private func hvacModeTitle(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off": return String(localized: "关闭")
        case "heat": return String(localized: "制热")
        case "cool": return String(localized: "制冷")
        case "heat_cool": return String(localized: "自动冷暖")
        case "auto": return String(localized: "自动")
        case "dry": return String(localized: "除湿")
        case "fan_only": return String(localized: "送风")
        default: return raw
        }
    }

    private func hvacModeSymbol(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off": return "power"
        case "heat": return "flame.fill"
        case "cool": return "snowflake"
        case "heat_cool", "auto": return "arrow.triangle.2.circlepath"
        case "dry": return "drop.fill"
        case "fan_only": return "fan.fill"
        default: return "thermometer.medium"
        }
    }

    private func adjustClimate(_ entity: HAEntity, context: ControlCenterHAContext,
                               target: Double, lower: Double, upper: Double) {
        let value = min(max(target, lower), upper)
        climateTargets[entity.entityId] = value
        sendClimate(entity, context: context, temperature: value)
    }

    private func sendBrightness(_ entity: HAEntity, context: ControlCenterHAContext, percent: Int) {
        runOperation(entity, context: context) {
            await model.performControlCenterHABrightnessAction(source: source, entityID: entity.entityId,
                expectedFingerprint: context.fingerprint, percent: percent)
        }
    }

    private func sendFan(_ entity: HAEntity, context: ControlCenterHAContext, percent: Int) {
        runOperation(entity, context: context) {
            await model.performControlCenterHAFanAction(source: source, entityID: entity.entityId,
                expectedFingerprint: context.fingerprint, percent: percent)
        }
    }

    private func sendClimate(_ entity: HAEntity, context: ControlCenterHAContext, temperature: Double) {
        runOperation(entity, context: context) {
            await model.performControlCenterHAClimateAction(source: source, entityID: entity.entityId,
                expectedFingerprint: context.fingerprint, temperature: temperature)
        }
    }

    private func execute(_ entity: HAEntity, context: ControlCenterHAContext) {
        let turnOn = !ControlCenterHAControlPolicy.isPowerOn(entity)
        runOperation(entity, context: context) {
            await model.performControlCenterHAAction(source: source, entityID: entity.entityId,
                expectedFingerprint: context.fingerprint, turnOn: turnOn)
        }
    }

    private func runOperation(_ entity: HAEntity, context: ControlCenterHAContext,
                              action: @escaping () async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError>) {
        guard operations[entity.entityId] == nil else { return }
        let requestID = UUID()
        operations[entity.entityId] = requestID
        messages[entity.entityId] = nil
        let baseline = context.entities.first(where: { $0.entityId == entity.entityId }) ?? entity
        Task { @MainActor in
            let result = await action()
            guard operations[entity.entityId] == requestID,
                  self.context?.fingerprint == context.fingerprint else { return }
            operations[entity.entityId] = nil
            sliderValues[entity.entityId] = nil
            climateTargets[entity.entityId] = nil
            switch result {
            case .success(let reading):
                if let updated = reading.entity {
                    overrides[entity.entityId] = ConfirmedReading(fingerprint: context.fingerprint,
                                                                  baseline: baseline, confirmed: updated)
                }
                messages[entity.entityId] = reading.message
            case .failure(let error):
                messages[entity.entityId] = error.localizedDescription
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
        let base: [HAEntity]
        switch filter {
        case 0:
            base = all.filter(ControlCenterHAControlPolicy.isControllable)
        case 2:
            base = selected.map { id in
                all.first { $0.entityId == id } ?? HAEntity(entityId: id, friendlyName: id,
                                                            state: "unavailable", unitOfMeasurement: nil)
            }
        case 3:
            base = all.filter(ControlCenterHAControlPolicy.isClimateSensor)
        default:
            base = all
        }
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
                Text("温湿度").tag(3)
                Text("全部实体").tag(1)
                Text("已选择").tag(2)
            }.pickerStyle(.segmented)
            if filter == 3 {
                Text("温度与湿度传感器会合并到同一张温湿度卡中显示；可多选。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        await performControlCenterHAServiceAction(source: source, entityID: entityID,
            expectedFingerprint: expectedFingerprint, transport: transport) { entity, selectedIDs, expected, current in
            ControlCenterHAControlPolicy.command(for: entity, selectedEntityIDs: selectedIDs,
                expectedFingerprint: expected, currentFingerprint: current, turnOn: turnOn)
        }
    }

    @MainActor func performControlCenterHABrightnessAction(source: DeviceControlCenterDataSource,
                                                          entityID: String, expectedFingerprint: String,
                                                          percent: Int,
                                                          transport: ControlCenterHAActionTransport = .live) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        await performControlCenterHAServiceAction(source: source, entityID: entityID,
            expectedFingerprint: expectedFingerprint, transport: transport) { entity, selectedIDs, expected, current in
            ControlCenterHAControlPolicy.brightnessCommand(for: entity, selectedEntityIDs: selectedIDs,
                expectedFingerprint: expected, currentFingerprint: current, percent: percent)
        }
    }

    @MainActor func performControlCenterHAFanAction(source: DeviceControlCenterDataSource,
                                                    entityID: String, expectedFingerprint: String,
                                                    percent: Int,
                                                    transport: ControlCenterHAActionTransport = .live) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        await performControlCenterHAServiceAction(source: source, entityID: entityID,
            expectedFingerprint: expectedFingerprint, transport: transport) { entity, selectedIDs, expected, current in
            ControlCenterHAControlPolicy.fanCommand(for: entity, selectedEntityIDs: selectedIDs,
                expectedFingerprint: expected, currentFingerprint: current, percent: percent)
        }
    }

    @MainActor func performControlCenterHAClimateModeAction(source: DeviceControlCenterDataSource,
                                                           entityID: String, expectedFingerprint: String,
                                                           mode: String,
                                                           transport: ControlCenterHAActionTransport = .live) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        await performControlCenterHAServiceAction(source: source, entityID: entityID,
            expectedFingerprint: expectedFingerprint, transport: transport) { entity, selectedIDs, expected, current in
            ControlCenterHAControlPolicy.climateModeCommand(for: entity, selectedEntityIDs: selectedIDs,
                expectedFingerprint: expected, currentFingerprint: current, mode: mode)
        }
    }

    @MainActor func performControlCenterHAClimateAction(source: DeviceControlCenterDataSource,
                                                       entityID: String, expectedFingerprint: String,
                                                       temperature: Double,
                                                       transport: ControlCenterHAActionTransport = .live) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        await performControlCenterHAServiceAction(source: source, entityID: entityID,
            expectedFingerprint: expectedFingerprint, transport: transport) { entity, selectedIDs, expected, current in
            ControlCenterHAControlPolicy.climateTemperatureCommand(for: entity, selectedEntityIDs: selectedIDs,
                expectedFingerprint: expected, currentFingerprint: current, temperature: temperature)
        }
    }

    @MainActor private func performControlCenterHAServiceAction(
        source: DeviceControlCenterDataSource, entityID: String, expectedFingerprint: String,
        transport: ControlCenterHAActionTransport,
        commandBuilder: (HAEntity, [String], String, String?) -> HAServiceCommand?
    ) async -> Result<ControlCenterHAActionReading, ControlCenterHAActionError> {
        guard let context = controlCenterHAContext(for: source), context.fingerprint == expectedFingerprint,
              let connection = overviewHAConnection(sourceID: context.sourceID) else { return .failure(.sourceChanged) }
        guard let entity = context.entities.first(where: { $0.entityId == entityID }),
              ControlCenterHAControlPolicy.isAvailable(entity) else { return .failure(.unavailable) }
        guard let command = commandBuilder(entity, context.selectedEntityIDs,
                                           expectedFingerprint, connection.fingerprint) else {
            return .failure(.unsupported)
        }
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
