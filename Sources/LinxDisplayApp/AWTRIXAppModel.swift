import AppKit
import LinxDisplayCore

private enum AWTRIXQueuedDisplayRequest {
    case app(String)
    case text
    case homeAssistant
}

@MainActor
extension AppModel {
    static let awtrixClient = AWTRIXClient()

    public func refreshAWTRIX() async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await refreshAWTRIX(deviceID: deviceID)
    }

    /// 显式按设备刷新，侧栏展开非活动设备时不会把结果写入另一台 AWTRIX。
    public func refreshAWTRIX(deviceID: UUID) async {
        guard !awtrixBusyIDs.contains(deviceID) else { return }
        let sourceConfig = awtrixSettings(for: deviceID)
        let previousStatus = awtrixStatuses[deviceID]
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在连接 AWTRIX…"
        defer { awtrixBusyIDs.remove(deviceID) }
        do {
            if sourceConfig.manualDisplaySession != nil,
               !awtrixManualDisplayActiveIDs.contains(deviceID) {
                try await restoreAWTRIXManualDisplay(deviceID: deviceID)
            }
            let snapshot = try await Self.awtrixClient.refresh(sourceConfig)
            if Task.isCancelled {
                awtrixStatuses[deviceID] = previousStatus
                return
            }
            guard awtrixDeviceStillMatches(sourceConfig, deviceID: deviceID) else {
                if awtrixDeviceExists(deviceID) { awtrixStatuses[deviceID] = previousStatus }
                return
            }
            awtrixSnapshots[deviceID] = snapshot
            var config = awtrixSettings(for: deviceID)
            // 保存期间读取只更新运行状态；待发送的本地选择不能被旧设备值覆盖。
            if awtrixSettingsSaveTasks[deviceID] == nil {
            if let value = snapshot.settings.brightness {
                config.brightness = min(value, AWTRIXClient.safeBrightnessLimit)
            }
            if let value = snapshot.settings.autoBrightness { config.autoBrightness = value }
            if let value = config.manualDisplaySession?.autoTransition ?? snapshot.settings.autoTransition {
                config.autoTransition = value
            }
            if let value = snapshot.settings.appDurationMs {
                config.appDurationSeconds = max(1, value / 1_000)
            }
            if let value = snapshot.settings.transitionEffect { config.transitionEffect = value }
            if let value = snapshot.settings.transitionDurationMs {
                config.transitionDurationMilliseconds = value
            }
            if let value = snapshot.system.minBrightness { config.autoBrightnessMinimum = value }
            if let value = snapshot.system.maxBrightness {
                config.autoBrightnessMaximum = min(value, AWTRIXClient.safeBrightnessLimit)
            }
            }
            config.paletteEntries = snapshot.paletteDefinitions[config.palette] ?? []
            config.sanitize()
            mutateAWTRIXSettings(deviceID) { $0 = config }
            let version = snapshot.device.version.map { " · 固件 \($0)" } ?? ""
            let app = snapshot.device.currentApp.map { " · 当前 \($0)" } ?? ""
            let message = "AWTRIX 已连接\(version)\(app)"
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        } catch {
            if Self.isCancellation(error) {
                awtrixStatuses[deviceID] = previousStatus
                return
            }
            // 短暂断线时保留最后一次成功的应用清单，避免整个动态侧栏闪烁消失。
            let message = Self.awtrixFriendly(error)
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        }
    }

    public func applyAWTRIXDisplaySettings() async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await applyAWTRIXDisplaySettings(deviceID: deviceID)
    }

    public func setAWTRIXPower(_ power: Bool) async {
        await performAWTRIXAction(power ? "正在开启屏幕…" : "正在关闭屏幕…") {
            try await Self.awtrixClient.setDisplayPower(power, configuration: self.settings.awtrix)
        }
        if awtrixStatus.hasPrefix("AWTRIX 操作成功") {
            awtrixStatus = power ? "AWTRIX 屏幕已开启" : "AWTRIX 屏幕已关闭"
            if let snapshot = awtrixSnapshot {
                var device = snapshot.device
                device.matrixPower = power
                awtrixSnapshot = AWTRIXSnapshot(device: device,
                                                settings: snapshot.settings,
                                                system: snapshot.system,
                                                apps: snapshot.apps,
                                                capabilities: snapshot.capabilities,
                                                paletteDefinitions: snapshot.paletteDefinitions)
            }
        }
    }

    public func showAWTRIXText() async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await showAWTRIXText(deviceID: deviceID)
    }

    public func showAWTRIXText(deviceID: UUID) async {
        await enqueueAWTRIXDisplayRequest(.text, deviceID: deviceID)
    }

    private func performQueuedAWTRIXTextDisplay(deviceID: UUID,
                                                generation: UInt64) async {
        guard !Task.isCancelled,
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
              awtrixDeviceExists(deviceID) else { return }
        var config = awtrixSettings(for: deviceID)
        config.sanitize()
        // 把规范化结果写回发起操作的受管设备，而不是依赖期间可能变化的活动设备。
        mutateAWTRIXSettings(deviceID) { $0 = config }
        let previousStatus = awtrixStatuses[deviceID]
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在准备并发送文字…"
        do {
            let previous = config.lastUploadedIcon
            let icon = try await publishAWTRIXGeneratedContent(config, deviceID: deviceID)
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
                  awtrixDeviceExists(deviceID) else {
                awtrixBusyIDs.remove(deviceID)
                return
            }
            // 只更新返回图标字段，保留请求期间用户对该设备做出的其他设置修改。
            mutateAWTRIXSettings(deviceID) { $0.lastUploadedIcon = icon }
            try await activateAWTRIXCardForDisplay(config.appName, deviceID: deviceID)
            if let previous, previous != icon, previous != config.homeAssistant.lastUploadedIcon {
                try? await Self.awtrixClient.deleteIcon(previous, configuration: config)
            }
            awtrixBusyIDs.remove(deviceID)
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) else { return }
            await refreshAWTRIXLivePreview(deviceID: deviceID)
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) else { return }
            await refreshAWTRIXCurrentState(deviceID: deviceID)
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
                  awtrixDeviceExists(deviceID) else { return }
            let message = "文字已显示在 AWTRIX"
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        } catch {
            awtrixBusyIDs.remove(deviceID)
            if Self.isCancellation(error) || Task.isCancelled
                || !awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) {
                if awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) {
                    awtrixStatuses[deviceID] = previousStatus
                }
                return
            }
            let message = Self.awtrixFriendly(error)
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        }
    }

    public func clearAWTRIXText() async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await clearAWTRIXText(deviceID: deviceID)
    }

    public func clearAWTRIXText(deviceID: UUID) async {
        guard awtrixDeviceExists(deviceID), !awtrixBusyIDs.contains(deviceID) else { return }
        var config = awtrixSettings(for: deviceID)
        if config.lastUploadedIcon == config.homeAssistant.lastUploadedIcon {
            config.lastUploadedIcon = nil
        }
        let previousStatus = awtrixStatuses[deviceID]
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在移除文字应用…"
        do {
            try await Self.awtrixClient.clearText(config)
            guard awtrixDeviceExists(deviceID) else {
                awtrixBusyIDs.remove(deviceID)
                return
            }
            mutateAWTRIXSettings(deviceID) { $0.lastUploadedIcon = nil }
            awtrixBusyIDs.remove(deviceID)
            await refreshAWTRIXLivePreview(deviceID: deviceID)
            await refreshAWTRIX(deviceID: deviceID)
            let message = "AWTRIX 文字应用已移除"
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        } catch {
            awtrixBusyIDs.remove(deviceID)
            if Self.isCancellation(error) {
                awtrixStatuses[deviceID] = previousStatus
                return
            }
            let message = Self.awtrixFriendly(error)
            awtrixStatuses[deviceID] = message
            if activeDeviceID(for: .awtrix) == deviceID { status = message }
        }
    }

    public func moveAWTRIXApp(next: Bool) async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await moveAWTRIXApp(next: next, deviceID: deviceID)
    }

    /// 设备管理页的连接测试不改变当前选中的 AWTRIX。
    public func testAWTRIXConnection(deviceID: UUID) async {
        guard !awtrixBusyIDs.contains(deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在连接 AWTRIX…"
        defer { awtrixBusyIDs.remove(deviceID) }
        do {
            let snapshot = try await Self.awtrixClient.refresh(config)
            awtrixSnapshots[deviceID] = snapshot
            let version = snapshot.device.version.map { " · 固件 \($0)" } ?? ""
            awtrixStatuses[deviceID] = "连接成功\(version)"
        } catch {
            awtrixStatuses[deviceID] = Self.awtrixFriendly(error)
        }
    }

    public func activateAWTRIXApp(_ name: String) async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await activateAWTRIXApp(name, deviceID: deviceID)
    }

    public func activateAWTRIXApp(_ name: String, deviceID: UUID) async {
        await enqueueAWTRIXDisplayRequest(.app(name), deviceID: deviceID)
    }

    public func showAWTRIXHomeAssistant(deviceID: UUID) async {
        await enqueueAWTRIXDisplayRequest(.homeAssistant, deviceID: deviceID)
    }

    /// 所有会改变实机当前画面的侧边栏操作共用一条每设备队列；包括首次创建
    /// “灵犀文字”，因此刷新期间点击文字入口也不会被原来的 busy guard 丢弃。
    private func enqueueAWTRIXDisplayRequest(_ request: AWTRIXQueuedDisplayRequest,
                                             deviceID: UUID) async {
        guard awtrixDeviceExists(deviceID) else { return }
        awtrixContentSaveTasks.removeValue(forKey: deviceID)?.cancel()
        switch request {
        case .app(let name): awtrixRequestedCardNames[deviceID] = name
        case .text: awtrixRequestedCardNames[deviceID] = awtrixSettings(for: deviceID).appName
        case .homeAssistant: awtrixRequestedCardNames[deviceID] = AWTRIXCardPolicy.homeAssistantAppName
        }
        awtrixHASyncTasks[deviceID]?.cancel()
        let generation = awtrixDisplayRequestPolicy.issue(for: deviceID)
        awtrixDisplayRequestTasks[deviceID]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runQueuedAWTRIXDisplayRequest(
                request, deviceID: deviceID, generation: generation)
        }
        awtrixDisplayRequestTasks[deviceID] = task
        await task.value
        if awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) {
            awtrixDisplayRequestTasks[deviceID] = nil
        }
    }

    /// 同一设备严格执行最后一次侧边栏选择。完整刷新、设置保存等操作继续复用
    /// `awtrixBusyIDs` 串行化；这里只等待它们结束，不再用 guard 静默丢弃点击。
    private func runQueuedAWTRIXDisplayRequest(_ request: AWTRIXQueuedDisplayRequest,
                                               deviceID: UUID,
                                               generation: UInt64) async {
        while awtrixBusyIDs.contains(deviceID) {
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
                  awtrixDeviceExists(deviceID) else { return }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
              awtrixDeviceExists(deviceID) else { return }
        switch request {
        case .app(let name):
            await performQueuedAWTRIXAppActivation(
                name, deviceID: deviceID, generation: generation)
        case .text:
            await performQueuedAWTRIXTextDisplay(
                deviceID: deviceID, generation: generation)
        case .homeAssistant:
            await pushAWTRIXHomeAssistant(deviceID: deviceID, showNow: true, userInitiated: true)
        }
    }

    private func performQueuedAWTRIXAppActivation(_ name: String, deviceID: UUID,
                                                  generation: UInt64) async {
        guard !Task.isCancelled,
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
              awtrixDeviceExists(deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        let previousStatus = awtrixStatuses[deviceID]
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在切换到 \(name)…"
        do {
            try await activateAWTRIXCardForDisplay(name, deviceID: deviceID)
            guard !Task.isCancelled,
                  awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID),
                  awtrixDeviceStillMatches(config, deviceID: deviceID) else {
                awtrixBusyIDs.remove(deviceID)
                return
            }
            awtrixStatuses[deviceID] = "已切换到 \(name)"
            if let snapshot = awtrixSnapshots[deviceID] {
                var state = snapshot.device
                state.currentApp = name
                awtrixSnapshots[deviceID] = AWTRIXSnapshot(
                    device: state,
                    settings: snapshot.settings,
                    system: snapshot.system,
                    apps: snapshot.apps,
                    capabilities: snapshot.capabilities,
                    paletteDefinitions: snapshot.paletteDefinitions)
            }
        } catch {
            if Self.isCancellation(error) || Task.isCancelled
                || !awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) {
                if awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) {
                    awtrixStatuses[deviceID] = previousStatus
                }
            } else {
                awtrixStatuses[deviceID] = Self.awtrixFriendly(error)
            }
            awtrixBusyIDs.remove(deviceID)
            return
        }
        // 激活后重新读取清单/currentApp，并获取设备真实屏幕帧。
        awtrixBusyIDs.remove(deviceID)
        guard !Task.isCancelled,
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) else { return }
        await refreshAWTRIXLivePreview(deviceID: deviceID)
        guard !Task.isCancelled,
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) else { return }
        await refreshAWTRIXCurrentState(deviceID: deviceID)
    }

    public func awtrixAppInfo(deviceID: UUID, name: String) -> AWTRIXAppInfo? {
        awtrixSnapshots[deviceID]?.apps.first { $0.name == name }
    }

    public func awtrixAppConfiguration(deviceID: UUID,
                                       name: String) -> AWTRIXAppConfiguration? {
        awtrixAppConfigurations[deviceID]?[name]
    }

    public func awtrixAppDraftValue(deviceID: UUID, name: String,
                                    field: AWTRIXConfigField) -> AWTRIXJSONValue? {
        awtrixAppConfigDrafts[deviceID]?[name]?[field.key] ?? field.effectiveValue
    }

    public func setAWTRIXAppDraftValue(_ value: AWTRIXJSONValue,
                                       deviceID: UUID, name: String, fieldKey: String) {
        var deviceDrafts = awtrixAppConfigDrafts[deviceID] ?? [:]
        var draft = deviceDrafts[name] ?? [:]
        draft[fieldKey] = value
        deviceDrafts[name] = draft
        awtrixAppConfigDrafts[deviceID] = deviceDrafts
    }

    public func awtrixAppStatus(deviceID: UUID, name: String) -> String {
        awtrixAppStatuses[deviceID]?[name] ?? ""
    }

    public func awtrixAppIsBusy(deviceID: UUID, name: String) -> Bool {
        awtrixAppBusyKeys.contains(Self.awtrixAppKey(deviceID: deviceID, name: name))
    }

    public func awtrixAppHasChanges(deviceID: UUID, name: String) -> Bool {
        !awtrixAppChangedValues(deviceID: deviceID, name: name).isEmpty
    }

    /// 动态读取脚本应用自己声明的设置 schema，不在客户端写死字段。
    public func loadAWTRIXAppConfiguration(_ name: String, deviceID: UUID,
                                           force: Bool = false) async {
        if !force, awtrixAppConfigurations[deviceID]?[name] != nil { return }
        let busyKey = Self.awtrixAppKey(deviceID: deviceID, name: name)
        guard !awtrixAppBusyKeys.contains(busyKey) else { return }
        let previousStatus = awtrixAppStatus(deviceID: deviceID, name: name)
        let deviceSettings = awtrixSettings(for: deviceID)
        awtrixAppBusyKeys.insert(busyKey)
        setAWTRIXAppStatus("正在读取应用设置…", deviceID: deviceID, name: name)
        defer { awtrixAppBusyKeys.remove(busyKey) }
        do {
            let configuration = try await Self.awtrixClient.fetchAppConfiguration(
                name, configuration: deviceSettings)
            if Task.isCancelled {
                setAWTRIXAppStatus(previousStatus, deviceID: deviceID, name: name)
                return
            }
            guard awtrixDeviceStillMatches(deviceSettings, deviceID: deviceID) else {
                if awtrixDeviceExists(deviceID) {
                    setAWTRIXAppStatus(previousStatus, deviceID: deviceID, name: name)
                }
                return
            }
            cacheAWTRIXAppConfiguration(configuration, deviceID: deviceID, name: name)
            setAWTRIXAppStatus(configuration.fields.isEmpty
                               ? "该应用没有可调整的设置"
                               : "已读取 \(configuration.fields.count) 项设置",
                               deviceID: deviceID, name: name)
        } catch {
            if Self.isCancellation(error) {
                setAWTRIXAppStatus(previousStatus, deviceID: deviceID, name: name)
                return
            }
            setAWTRIXAppStatus(Self.awtrixFriendly(error), deviceID: deviceID, name: name)
        }
    }

    public func discardAWTRIXAppConfigurationChanges(_ name: String, deviceID: UUID) {
        guard let configuration = awtrixAppConfigurations[deviceID]?[name] else { return }
        setAWTRIXAppDraft(Self.awtrixDraft(from: configuration),
                          deviceID: deviceID, name: name)
        setAWTRIXAppStatus("已放弃未保存的修改", deviceID: deviceID, name: name)
    }

    public func restoreAWTRIXAppConfigurationDefaults(_ name: String, deviceID: UUID) {
        guard let configuration = awtrixAppConfigurations[deviceID]?[name] else { return }
        var draft = Self.awtrixDraft(from: configuration)
        for field in configuration.fields {
            if let value = field.defaultValue { draft[field.key] = value }
        }
        setAWTRIXAppDraft(draft, deviceID: deviceID, name: name)
        setAWTRIXAppStatus("已恢复默认值，正在自动保存…",
                           deviceID: deviceID, name: name)
    }

    /// PATCH 只发送用户实际改动的字段；保存后立即重新 GET，
    /// 以设备脚本最终规范化的值为准。
    public func saveAWTRIXAppConfiguration(_ name: String, deviceID: UUID) async {
        let changed = awtrixAppChangedValues(deviceID: deviceID, name: name)
        let submittedDraft = awtrixAppConfigDrafts[deviceID]?[name] ?? [:]
        guard !changed.isEmpty else {
            setAWTRIXAppStatus("没有需要保存的修改", deviceID: deviceID, name: name)
            return
        }
        let busyKey = Self.awtrixAppKey(deviceID: deviceID, name: name)
        guard !awtrixAppBusyKeys.contains(busyKey) else { return }
        let previousStatus = awtrixAppStatus(deviceID: deviceID, name: name)
        awtrixAppBusyKeys.insert(busyKey)
        setAWTRIXAppStatus("正在保存应用设置…", deviceID: deviceID, name: name)
        defer { awtrixAppBusyKeys.remove(busyKey) }
        let deviceSettings = awtrixSettings(for: deviceID)
        do {
            try await Self.awtrixClient.updateAppConfiguration(
                name, values: changed, configuration: deviceSettings)
        } catch {
            if Self.isCancellation(error) {
                setAWTRIXAppStatus(previousStatus, deviceID: deviceID, name: name)
                return
            }
            setAWTRIXAppStatus(Self.awtrixFriendly(error), deviceID: deviceID, name: name)
            return
        }
        do {
            let configuration = try await Self.awtrixClient.fetchAppConfiguration(
                name, configuration: deviceSettings)
            if Task.isCancelled {
                setAWTRIXAppStatus("设置已发送，可重新读取确认",
                                   deviceID: deviceID, name: name)
                return
            }
            guard awtrixDeviceStillMatches(deviceSettings, deviceID: deviceID) else {
                if awtrixDeviceExists(deviceID) {
                    setAWTRIXAppStatus("连接信息已变化，请重新读取",
                                       deviceID: deviceID, name: name)
                }
                return
            }
            let newerDraft = awtrixAppConfigDrafts[deviceID]?[name] ?? [:]
            cacheAWTRIXAppConfiguration(configuration, deviceID: deviceID, name: name)
            // 回读设备规范化值时保留网络请求期间继续输入的新值。
            for (key, value) in newerDraft where value != submittedDraft[key] {
                setAWTRIXAppDraftValue(value, deviceID: deviceID, name: name, fieldKey: key)
            }
            setAWTRIXAppStatus("应用设置已保存", deviceID: deviceID, name: name)
        } catch {
            if Self.isCancellation(error) {
                setAWTRIXAppStatus("设置已发送，可重新读取确认",
                                   deviceID: deviceID, name: name)
                return
            }
            setAWTRIXAppStatus("设置已发送，但重新读取失败：\(Self.awtrixFriendly(error))",
                               deviceID: deviceID, name: name)
        }
    }

    /// 读取设备当前真实屏幕帧。与本地文字预览完全分开，且相同像素帧不触发 UI 更新。
    @discardableResult
    public func refreshAWTRIXLivePreview(deviceID: UUID) async -> Bool {
        guard !awtrixLivePreviewBusyIDs.contains(deviceID) else { return false }
        let previousStatus = awtrixLivePreviewStatuses[deviceID]
        awtrixLivePreviewBusyIDs.insert(deviceID)
        if awtrixLivePreviewImages[deviceID] == nil {
            setAWTRIXLivePreviewStatus("正在读取设备实时画面…", deviceID: deviceID)
        }
        defer { awtrixLivePreviewBusyIDs.remove(deviceID) }
        do {
            let deviceSettings = awtrixSettings(for: deviceID)
            let frame = try await Self.awtrixClient.fetchDisplayFrame(
                deviceSettings)
            if Task.isCancelled {
                awtrixLivePreviewStatuses[deviceID] = previousStatus
                return false
            }
            guard awtrixDeviceStillMatches(deviceSettings, deviceID: deviceID) else {
                if awtrixDeviceExists(deviceID) {
                    awtrixLivePreviewStatuses[deviceID] = previousStatus
                }
                return false
            }
            if awtrixLivePreviewFrames[deviceID] != frame,
               let image = frame.makeImage() {
                awtrixLivePreviewFrames[deviceID] = frame
                awtrixLivePreviewImages[deviceID] = NSImage(
                    cgImage: image, size: NSSize(width: frame.width, height: frame.height))
            }
            setAWTRIXLivePreviewStatus("设备实时画面 · \(frame.width)×\(frame.height)",
                                       deviceID: deviceID)
            return true
        } catch {
            if Self.isCancellation(error) {
                awtrixLivePreviewStatuses[deviceID] = previousStatus
                return false
            }
            setAWTRIXLivePreviewStatus(Self.awtrixFriendly(error), deviceID: deviceID)
            return false
        }
    }

    /// 由应用详情页的结构化 Task 持有；离开页面或切换应用时会自动取消。
    public func pollAWTRIXLivePreview(deviceID: UUID) async {
        while !Task.isCancelled {
            // 控制/上传请求优先。实时预览不能与切卡、上传图片争抢 MCU 的连接缓冲。
            let succeeded = awtrixBusyIDs.contains(deviceID)
                ? false : await refreshAWTRIXLivePreview(deviceID: deviceID)
            do {
                try await Task.sleep(nanoseconds: succeeded ? 400_000_000 : 1_000_000_000)
            } catch {
                break
            }
        }
    }

    /// 以设备当前返回的顺序为基准修改轮换成员。
    public func setAWTRIXApp(_ name: String, inLoop: Bool) async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await setAWTRIXApp(name, inLoop: inLoop, deviceID: deviceID)
    }

    public func setAWTRIXApp(_ name: String, inLoop: Bool, deviceID: UUID) async {
        guard let snapshot = awtrixSnapshots[deviceID] else { return }
        var order = Self.uniqueAWTRIXAppNames(snapshot.apps.filter(Self.awtrixAppIsInLoop).map(\.name))
        if inLoop {
            if !order.contains(name) { order.append(name) }
        } else {
            order.removeAll { $0 == name }
        }
        await applyAWTRIXAppOrder(order, deviceID: deviceID)
    }

    public func applyAWTRIXAppOrder(_ order: [String]) async {
        guard let deviceID = activeDeviceID(for: .awtrix) else { return }
        await applyAWTRIXAppOrder(order, deviceID: deviceID)
    }

    @discardableResult
    public func applyAWTRIXAppOrder(_ order: [String], deviceID: UUID) async -> Bool {
        guard let snapshot = awtrixSnapshots[deviceID],
              !awtrixBusyIDs.contains(deviceID) else { return false }
        let arrangement = AWTRIXAppArrangement(apps: snapshot.apps)
            .settingVisibleOrder(order, apps: snapshot.apps)
        awtrixBusyIDs.insert(deviceID)
        awtrixStatuses[deviceID] = "正在保存应用轮换…"
        do {
            try await Self.awtrixClient.setAppOrder(
                arrangement.order, disabled: arrangement.disabled, configuration: awtrixSettings(for: deviceID))
            awtrixStatuses[deviceID] = "AWTRIX 应用轮换已保存"
        } catch {
            awtrixStatuses[deviceID] = Self.awtrixFriendly(error)
            awtrixBusyIDs.remove(deviceID)
            return false
        }
        awtrixBusyIDs.remove(deviceID)
        await refreshAWTRIX(deviceID: deviceID)
        return true
    }

    public static func awtrixAppIsInLoop(_ app: AWTRIXAppInfo) -> Bool {
        app.inLoop ?? app.enabled ?? false
    }

    private func performAWTRIXAction(_ progress: String,
                                     action: @escaping () async throws -> Void) async {
        guard !awtrixBusy else { return }
        awtrixBusy = true
        awtrixStatus = progress
        defer { awtrixBusy = false }
        do {
            try await action()
            awtrixStatus = "AWTRIX 操作成功"
            status = awtrixStatus
        } catch {
            awtrixStatus = Self.awtrixFriendly(error)
            status = awtrixStatus
        }
    }

    static func awtrixFriendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func awtrixAppKey(deviceID: UUID, name: String) -> String {
        deviceID.uuidString + "|" + name
    }

    private static func awtrixDraft(from configuration: AWTRIXAppConfiguration)
        -> [String: AWTRIXJSONValue] {
        configuration.fields.reduce(into: [:]) { result, field in
            if let value = field.effectiveValue { result[field.key] = value }
        }
    }

    private static func uniqueAWTRIXAppNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func cacheAWTRIXAppConfiguration(_ configuration: AWTRIXAppConfiguration,
                                             deviceID: UUID, name: String) {
        var configurations = awtrixAppConfigurations[deviceID] ?? [:]
        configurations[name] = configuration
        awtrixAppConfigurations[deviceID] = configurations
        setAWTRIXAppDraft(Self.awtrixDraft(from: configuration), deviceID: deviceID, name: name)
    }

    private func setAWTRIXAppDraft(_ draft: [String: AWTRIXJSONValue],
                                   deviceID: UUID, name: String) {
        var deviceDrafts = awtrixAppConfigDrafts[deviceID] ?? [:]
        deviceDrafts[name] = draft
        awtrixAppConfigDrafts[deviceID] = deviceDrafts
    }

    private func setAWTRIXAppStatus(_ message: String, deviceID: UUID, name: String) {
        var statuses = awtrixAppStatuses[deviceID] ?? [:]
        guard statuses[name] != message else { return }
        statuses[name] = message
        awtrixAppStatuses[deviceID] = statuses
    }

    private func setAWTRIXLivePreviewStatus(_ message: String, deviceID: UUID) {
        guard awtrixLivePreviewStatuses[deviceID] != message else { return }
        awtrixLivePreviewStatuses[deviceID] = message
    }

    private func awtrixAppChangedValues(deviceID: UUID, name: String)
        -> [String: AWTRIXJSONValue] {
        guard let configuration = awtrixAppConfigurations[deviceID]?[name] else { return [:] }
        let draft = awtrixAppConfigDrafts[deviceID]?[name] ?? [:]
        return configuration.fields.reduce(into: [:]) { result, field in
            guard let value = draft[field.key] else { return }
            if value != field.effectiveValue { result[field.key] = value }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func awtrixDeviceStillMatches(_ configuration: AWTRIXSettings,
                                          deviceID: UUID) -> Bool {
        let current = awtrixSettings(for: deviceID)
        return awtrixDeviceExists(deviceID)
            && current.baseURL == configuration.baseURL
            && current.username == configuration.username
            && current.password == configuration.password
    }

    func awtrixDeviceExists(_ deviceID: UUID) -> Bool {
        settings.devices.contains { $0.id == deviceID && $0.type == .awtrix && $0.isEnabled }
    }
}
