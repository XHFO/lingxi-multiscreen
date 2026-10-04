import AppKit
import LinxDisplayCore

@MainActor
extension AppModel {
    public var haEntityCatalog: [HAEntity] { haSnapshot.entities }
    public func awtrixHAEntity(deviceID: UUID, entityID: String) -> HAEntity? {
        if let latest = awtrixHAEntities[deviceID] {
            return latest.first { $0.entityId == entityID }
        }
        return haSnapshot.entities.first { $0.entityId == entityID }
    }
    public func awtrixCards(for deviceID: UUID) -> [AWTRIXCardDescriptor] {
        let cards = AWTRIXCardPolicy.cards(apps: awtrixSnapshots[deviceID]?.apps ?? [],
                                           settings: awtrixSettings(for: deviceID))
        guard let desired = awtrixDesiredLoopOrders[deviceID]
            ?? awtrixSettings(for: deviceID).manualDisplaySession?.order else { return cards }
        return cards.map { card in
            AWTRIXCardDescriptor(name: card.name, title: card.title, symbol: card.symbol,
                                  isInstalled: card.isInstalled,
                                  isInLoop: desired.contains(card.name))
        }
    }

    public func awtrixVisibleCards(for deviceID: UUID) -> [AWTRIXCardDescriptor] {
        AWTRIXCardPolicy.visibleCards(apps: awtrixSnapshots[deviceID]?.apps ?? [],
                                      settings: awtrixSettings(for: deviceID))
    }

    public func setAWTRIXCardVisible(_ name: String, visible: Bool, deviceID: UUID) {
        var names = awtrixVisibleCards(for: deviceID).map(\.name)
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if visible { names.append(name) }
        setAWTRIXSidebarOrder(names, deviceID: deviceID)
    }

    public func setAWTRIXSidebarOrder(_ names: [String], deviceID: UUID) {
        mutateAWTRIXSettings(deviceID) { $0.sidebarAppNames = names }
    }

    public func showAWTRIXCard(_ name: String, deviceID: UUID) async {
        let config = awtrixSettings(for: deviceID)
        if name.caseInsensitiveCompare(AWTRIXCardPolicy.homeAssistantAppName) == .orderedSame {
            await showAWTRIXHomeAssistant(deviceID: deviceID)
        } else if name.caseInsensitiveCompare(config.appName) == .orderedSame {
            await showAWTRIXText(deviceID: deviceID)
        } else {
            await activateAWTRIXApp(name, deviceID: deviceID)
        }
    }

    /// 与其他设备一致，滑杆/开关本地自动保存，停止编辑后合并一次设备请求。
    public func updateAWTRIXDisplaySettings(deviceID: UUID,
                                            update: (inout AWTRIXSettings) -> Void) {
        mutateAWTRIXSettings(deviceID, update)
        awtrixSettingsSaveTasks[deviceID]?.cancel()
        awtrixSettingsSaveTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.applyAWTRIXDisplaySettings(deviceID: deviceID)
            if !Task.isCancelled { self.awtrixSettingsSaveTasks[deviceID] = nil }
        }
    }

    public func applyAWTRIXDisplaySettings(deviceID: UUID) async {
        guard await waitForAWTRIXDevice(deviceID) else { return }
        var config = awtrixSettings(for: deviceID)
        if config.manualDisplaySession != nil { config.autoTransition = false }
        awtrixBusyIDs.insert(deviceID)
        defer { awtrixBusyIDs.remove(deviceID) }
        do {
            try await Self.awtrixClient.applyDisplaySettings(config)
            guard !Task.isCancelled, awtrixDeviceStillMatches(config, deviceID: deviceID) else { return }
            awtrixStatuses[deviceID] = "显示设置已自动保存"
        } catch {
            if !Task.isCancelled { awtrixStatuses[deviceID] = Self.awtrixFriendly(error) }
        }
    }

    public func setAWTRIXAutoRotation(_ enabled: Bool, deviceID: UUID) async {
        if awtrixSettings(for: deviceID).manualDisplaySession != nil {
            guard await finishAWTRIXManualDisplay(deviceID: deviceID) else { return }
        }
        updateAWTRIXDisplaySettings(deviceID: deviceID) { $0.autoTransition = enabled }
        await awtrixSettingsSaveTasks[deviceID]?.value
    }

    public func setAWTRIXPower(_ enabled: Bool, deviceID: UUID) async {
        guard await waitForAWTRIXDevice(deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        awtrixBusyIDs.insert(deviceID)
        do {
            try await Self.awtrixClient.setDisplayPower(enabled, configuration: config)
        } catch {
            awtrixStatuses[deviceID] = Self.awtrixFriendly(error)
            awtrixBusyIDs.remove(deviceID)
            return
        }
        awtrixBusyIDs.remove(deviceID)
        await refreshAWTRIX(deviceID: deviceID)
    }

    public func moveAWTRIXApp(next: Bool, deviceID: UUID) async {
        awtrixRequestedCardNames[deviceID] = nil
        awtrixContentSaveTasks.removeValue(forKey: deviceID)?.cancel()
        awtrixHASyncTasks[deviceID]?.cancel()
        let generation = awtrixDisplayRequestPolicy.issue(for: deviceID)
        awtrixDisplayRequestTasks.removeValue(forKey: deviceID)?.cancel()
        guard await waitForAWTRIXDevice(deviceID),
              awtrixDisplayRequestPolicy.isCurrent(generation, for: deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        awtrixBusyIDs.insert(deviceID)
        do {
            try await restoreAWTRIXManualDisplay(deviceID: deviceID)
            if next { try await Self.awtrixClient.nextApp(config) }
            else { try await Self.awtrixClient.previousApp(config) }
        } catch {
            awtrixStatuses[deviceID] = Self.awtrixFriendly(error)
            awtrixBusyIDs.remove(deviceID)
            return
        }
        awtrixBusyIDs.remove(deviceID)
        await refreshAWTRIX(deviceID: deviceID)
        await refreshAWTRIXLivePreview(deviceID: deviceID)
    }

    /// 轮换目标独立于侧栏可见性；连续修改保留最新整份顺序。
    public func setAWTRIXCard(_ name: String, inLoop: Bool, deviceID: UUID) async {
        if awtrixSettings(for: deviceID).manualDisplaySession != nil {
            guard await finishAWTRIXManualDisplay(deviceID: deviceID) else { return }
        }
        if awtrixSnapshots[deviceID] == nil { await refreshAWTRIX(deviceID: deviceID) }
        var order = awtrixDesiredLoopOrders[deviceID]
            ?? awtrixSnapshots[deviceID]?.apps.filter(Self.awtrixAppIsInLoop).map(\.name) ?? []
        order.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if inLoop { order.append(name) }
        awtrixDesiredLoopOrders[deviceID] = order
        objectWillChange.send()
        awtrixLoopSaveTasks[deviceID]?.cancel()
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let config = self.awtrixSettings(for: deviceID)
            for target in self.awtrixDesiredLoopOrders[deviceID] ?? [] {
                guard !Task.isCancelled else { return }
                if self.awtrixSnapshots[deviceID]?.apps.contains(where: { $0.name == target }) == true { continue }
                if target == AWTRIXCardPolicy.homeAssistantAppName {
                    await self.pushAWTRIXHomeAssistant(deviceID: deviceID, showNow: false)
                } else if target == config.appName {
                    await self.pushAWTRIXTextUpdate(deviceID: deviceID, showIfRequested: false)
                }
            }
            guard !Task.isCancelled, await self.waitForAWTRIXDevice(deviceID) else { return }
            await self.refreshAWTRIX(deviceID: deviceID)
            guard !Task.isCancelled, await self.waitForAWTRIXDevice(deviceID) else { return }
            let desired = self.awtrixDesiredLoopOrders[deviceID] ?? []
            let installed = Set(self.awtrixSnapshots[deviceID]?.apps.map(\.name) ?? [])
            if desired.contains(where: { !installed.contains($0) }) {
                self.awtrixStatuses[deviceID] = "尚有卡片未准备好，请先配置内容后重试轮换"
                self.awtrixDesiredLoopOrders[deviceID] = nil
                self.awtrixLoopSaveTasks[deviceID] = nil
                return
            }
            await self.applyAWTRIXAppOrder(desired, deviceID: deviceID)
            if !Task.isCancelled {
                self.awtrixDesiredLoopOrders[deviceID] = nil
                self.awtrixLoopSaveTasks[deviceID] = nil
            }
        }
        awtrixLoopSaveTasks[deviceID] = task
        await task.value
    }

    public func awtrixCardIsInLoop(_ name: String, deviceID: UUID) -> Bool {
        if let order = awtrixDesiredLoopOrders[deviceID] {
            return order.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return awtrixCards(for: deviceID).first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.isInLoop ?? false
    }

    public func updateAWTRIXText(deviceID: UUID, update: (inout AWTRIXSettings) -> Void) {
        mutateAWTRIXSettings(deviceID, update)
        awtrixContentSaveTasks[deviceID]?.cancel()
        awtrixContentSaveTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.pushAWTRIXTextUpdate(deviceID: deviceID, showIfRequested: true)
            if !Task.isCancelled { self.awtrixContentSaveTasks[deviceID] = nil }
        }
    }

    public func scheduleAWTRIXAppConfigurationSave(_ name: String, deviceID: UUID) {
        let key = deviceID.uuidString + "|" + name
        awtrixConfigSaveTasks[key]?.cancel()
        awtrixConfigSaveTasks[key] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            guard let self else { return }
            while self.awtrixAppIsBusy(deviceID: deviceID, name: name) {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard !Task.isCancelled, self.awtrixDeviceExists(deviceID) else { return }
            await self.saveAWTRIXAppConfiguration(name, deviceID: deviceID)
            if !Task.isCancelled { self.awtrixConfigSaveTasks[key] = nil }
        }
    }

    public func updateAWTRIXHomeAssistant(deviceID: UUID,
                                           update: (inout AWTRIXHomeAssistantSettings) -> Void) {
        mutateAWTRIXSettings(deviceID) { update(&$0.homeAssistant) }
        awtrixHALastContent[deviceID] = nil
        awtrixContentSaveTasks[deviceID]?.cancel()
        awtrixContentSaveTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // 设置页的即时反馈遵循自动推送开关，手动按钮始终可以推送。
            if self.awtrixSettings(for: deviceID).homeAssistant.autoPush {
                await self.pushAWTRIXHomeAssistant(deviceID: deviceID, showNow:
                    self.awtrixRequestedCardNames[deviceID] == AWTRIXCardPolicy.homeAssistantAppName)
            }
            if !Task.isCancelled { self.awtrixContentSaveTasks[deviceID] = nil }
        }
    }

    /// 不阻塞共享 1 秒 tick，离开设置页后仍为已启用的 HA 卡片同步数据。
    func scheduleAWTRIXHomeAssistantSync(now: Date) {
        guard !awtrixPreparingForQuit else { return }
        for device in enabledDevices(for: .awtrix) {
            let config = awtrixSettings(for: device.id)
            guard config.homeAssistant.autoPush, !config.homeAssistant.entityIDs.isEmpty,
                  config.manualDisplaySession == nil || awtrixManualDisplayActiveIDs.contains(device.id),
                  !settings.haServerURL.isEmpty,
                  awtrixHASyncTasks[device.id] == nil,
                  awtrixDisplayRequestTasks[device.id] == nil,
                  awtrixContentSaveTasks[device.id] == nil else { continue }
            let wanted = awtrixVisibleCards(for: device.id).contains { $0.name == AWTRIXCardPolicy.homeAssistantAppName }
                || awtrixCardIsInLoop(AWTRIXCardPolicy.homeAssistantAppName, deviceID: device.id)
                || awtrixSnapshots[device.id]?.device.currentApp == AWTRIXCardPolicy.homeAssistantAppName
            guard wanted else { continue }
            if let last = awtrixHALastAttempt[device.id],
               now.timeIntervalSince(last) < Double(config.homeAssistant.refreshSeconds) { continue }
            awtrixHALastAttempt[device.id] = now
            awtrixHASyncTasks[device.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pushAWTRIXHomeAssistant(deviceID: device.id, showNow: false)
                self.awtrixHASyncTasks[device.id] = nil
            }
        }
    }

    /// 调用者持有设备锁。更新已有卡片不触碰设备轮播；新卡片默认不加入轮播。
    /// disabled 是固件的停用列表，不可按 !inLoop 重建，否则会关掉后台脚本。
    func publishAWTRIXGeneratedContent(_ content: AWTRIXSettings,
                                       deviceID: UUID) async throws -> String {
        if awtrixSnapshots[deviceID] == nil {
            awtrixSnapshots[deviceID] = try await Self.awtrixClient.refresh(content)
        }
        try Task.checkCancellation()
        guard awtrixDeviceStillMatches(content, deviceID: deviceID) else { throw CancellationError() }
        let snapshot = awtrixSnapshots[deviceID]!
        let before = try await Self.awtrixClient.fetchApps(content)
        let wasInstalled = before.contains { $0.name == content.appName }
        let arrangement = AWTRIXAppArrangement(apps: before)
        let order = arrangement.order
        let disabled = arrangement.disabled
        let excludeNewCard = !wasInstalled
            && awtrixDesiredLoopOrders[deviceID]?.contains(content.appName) != true
        do {
        let icon = try await Self.awtrixClient.showText(content, showNow: false)
        try Task.checkCancellation()
        if excludeNewCard {
            try await Self.awtrixClient.setAppOrder(order,
                disabled: disabled + [content.appName], configuration: content)
        }
        let apps = try await Self.awtrixClient.fetchApps(content)
        guard awtrixDeviceStillMatches(content, deviceID: deviceID) else { throw CancellationError() }
        awtrixSnapshots[deviceID] = AWTRIXSnapshot(device: snapshot.device,
            settings: snapshot.settings, system: snapshot.system, apps: apps,
            capabilities: snapshot.capabilities, paletteDefinitions: snapshot.paletteDefinitions)
        return icon
        } catch {
            // 即使切卡取消了上传，设备可能已接收 PUT；补偿恢复之前的轮换成员。
            // 独立任务不继承取消标记，调用方继续持锁直到恢复完成。
            if excludeNewCard, awtrixDeviceStillMatches(content, deviceID: deviceID) {
                let repair = Task {
                    try? await Self.awtrixClient.setAppOrder(order,
                        disabled: disabled + [content.appName], configuration: content)
                }
                await repair.value
            }
            throw error
        }
    }

    func pushAWTRIXTextUpdate(deviceID: UUID, showIfRequested: Bool) async {
        guard await waitForAWTRIXDevice(deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        awtrixBusyIDs.insert(deviceID)
        defer { awtrixBusyIDs.remove(deviceID) }
        do {
            let icon = try await publishAWTRIXGeneratedContent(config, deviceID: deviceID)
            try Task.checkCancellation()
            mutateAWTRIXSettings(deviceID) { $0.lastUploadedIcon = icon }
            if let old = config.lastUploadedIcon, !old.isEmpty, old != icon,
               old != config.homeAssistant.lastUploadedIcon {
                try? await Self.awtrixClient.deleteIcon(old, configuration: config)
            }
            if showIfRequested, awtrixRequestedCardNames[deviceID] == config.appName {
                try await activateAWTRIXCardForDisplay(config.appName, deviceID: deviceID, restartReturn: false)
                await refreshAWTRIXLivePreview(deviceID: deviceID)
            }
            awtrixStatuses[deviceID] = "文字已自动保存并更新"
        } catch {
            if !Task.isCancelled { awtrixStatuses[deviceID] = Self.awtrixFriendly(error) }
        }
    }

    func pushAWTRIXHomeAssistant(deviceID: UUID, showNow: Bool, userInitiated: Bool = false) async {
        guard awtrixDeviceExists(deviceID) else { return }
        let config = awtrixSettings(for: deviceID)
        let source = config.homeAssistant
        let server = settings.haServerURL
        let token = settings.haToken
        guard !source.entityIDs.isEmpty else {
            if await waitForAWTRIXDevice(deviceID) {
                awtrixBusyIDs.insert(deviceID)
                defer { awtrixBusyIDs.remove(deviceID) }
                do {
                    if config.manualDisplaySession?.appName == AWTRIXCardPolicy.homeAssistantAppName {
                        try await restoreAWTRIXManualDisplay(deviceID: deviceID)
                    }
                    if awtrixSnapshots[deviceID]?.apps.contains(where: {
                        $0.name == AWTRIXCardPolicy.homeAssistantAppName
                    }) == true {
                        var empty = config
                        empty.appName = AWTRIXCardPolicy.homeAssistantAppName
                        try await Self.awtrixClient.clearText(empty)
                        await refreshAWTRIXCurrentState(deviceID: deviceID)
                    }
                    awtrixHAEntities[deviceID] = []
                    awtrixHALastContent[deviceID] = nil
                } catch {
                    if !Task.isCancelled { awtrixStatuses[deviceID] = "清除实体卡片失败：\(Self.awtrixFriendly(error))" }
                    return
                }
            }
            awtrixStatuses[deviceID] = "请先选择 Home Assistant 实体"
            return
        }
        guard !server.isEmpty else {
            awtrixStatuses[deviceID] = "请先在设备管理连接 Home Assistant"
            return
        }
        var ownsBusy = false
        defer { if ownsBusy { awtrixBusyIDs.remove(deviceID) } }
        awtrixHALastAttempt[deviceID] = Date()
        do {
            var entities: [HAEntity]
            do {
                entities = try await HomeAssistantClient.fetchStates(
                    serverURL: server, token: token, entityIDs: source.entityIDs)
            } catch HAError.serverError(status: 404) {
                entities = []
            }
            guard !Task.isCancelled, awtrixDeviceStillMatches(config, deviceID: deviceID),
                  sameAWTRIXHASource(awtrixSettings(for: deviceID).homeAssistant, source),
                  settings.haServerURL == server, settings.haToken == token else { return }
            guard await waitForAWTRIXDevice(deviceID) else { return }
            guard sameAWTRIXHASource(awtrixSettings(for: deviceID).homeAssistant, source),
                  awtrixDeviceStillMatches(config, deviceID: deviceID),
                  settings.haServerURL == server, settings.haToken == token else { return }
            awtrixBusyIDs.insert(deviceID)
            ownsBusy = true
            if awtrixSnapshots[deviceID] == nil {
                awtrixSnapshots[deviceID] = try await Self.awtrixClient.refresh(config)
                try Task.checkCancellation()
            }
            for index in entities.indices {
                if let alias = settings.haEntityAliases[entities[index].entityId], !alias.isEmpty {
                    entities[index].friendlyName = alias
                }
            }
            awtrixHAEntities[deviceID] = entities
            objectWillChange.send()
            let text = AWTRIXHomeAssistantContent.text(entities: entities, settings: source)
            let contentKey = [server, config.baseURL, source.foregroundHex, text,
                              String(config.durationSeconds), String(config.scrollSpeedMilliseconds)].joined(separator: "|")
            let isInstalled = awtrixSnapshots[deviceID]?.apps.contains { $0.name == AWTRIXCardPolicy.homeAssistantAppName } == true
            if !isInstalled || awtrixHALastContent[deviceID] != contentKey {
                var content = config
                content.appName = AWTRIXCardPolicy.homeAssistantAppName
                content.text = text
                content.foregroundHex = source.foregroundHex
                content.backgroundHex = "#000000"
                content.palette = "Solid"
                content.effect = ""
                content.lastUploadedIcon = source.lastUploadedIcon
                let icon = try await publishAWTRIXGeneratedContent(content, deviceID: deviceID)
                guard !Task.isCancelled, awtrixDeviceStillMatches(config, deviceID: deviceID) else { return }
                let oldIcon = source.lastUploadedIcon
                mutateAWTRIXSettings(deviceID) { $0.homeAssistant.lastUploadedIcon = icon }
                awtrixHALastContent[deviceID] = contentKey
                if let oldIcon, !oldIcon.isEmpty, oldIcon != icon,
                   oldIcon != config.lastUploadedIcon,
                   awtrixSnapshots[deviceID]?.apps.contains(where: { $0.name != content.appName && $0.icon == oldIcon }) != true {
                    try? await Self.awtrixClient.deleteIcon(oldIcon, configuration: config)
                }
            }
            if showNow, awtrixRequestedCardNames[deviceID] == AWTRIXCardPolicy.homeAssistantAppName {
                try Task.checkCancellation()
                try await activateAWTRIXCardForDisplay(AWTRIXCardPolicy.homeAssistantAppName,
                    deviceID: deviceID, restartReturn: userInitiated)
                await refreshAWTRIXLivePreview(deviceID: deviceID)
            }
            let displayed = showNow && awtrixRequestedCardNames[deviceID] == AWTRIXCardPolicy.homeAssistantAppName
            if displayed || awtrixStatuses[deviceID]?.hasPrefix("Home Assistant 显示失败") != true {
                awtrixStatuses[deviceID] = displayed
                    ? "Home Assistant 已显示 · \(entities.count) 个实体"
                    : "Home Assistant 内容已同步 · \(entities.count) 个实体"
            }
            if showNow {
                // refresh 与本函数共用 busy；先释放再同步设备运行状态。
                awtrixBusyIDs.remove(deviceID)
                ownsBusy = false
                await refreshAWTRIXCurrentState(deviceID: deviceID)
            }
        } catch {
            if !Task.isCancelled, awtrixDeviceExists(deviceID) {
                let phase = showNow ? "显示失败" : "同步失败"
                awtrixStatuses[deviceID] = "Home Assistant \(phase)：\(Self.awtrixFriendly(error))"
            }
        }
    }

    private func sameAWTRIXHASource(_ lhs: AWTRIXHomeAssistantSettings,
                                     _ rhs: AWTRIXHomeAssistantSettings) -> Bool {
        var a = lhs, b = rhs
        a.lastUploadedIcon = nil
        b.lastUploadedIcon = nil
        return a == b
    }

    func waitForAWTRIXDevice(_ deviceID: UUID) async -> Bool {
        while awtrixBusyIDs.contains(deviceID) {
            guard !Task.isCancelled, awtrixDeviceExists(deviceID) else { return false }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
        return !Task.isCancelled && awtrixDeviceExists(deviceID)
    }

    func cancelAWTRIXBackgroundWork(deviceID: UUID? = nil) {
        let ids = deviceID.map { [$0] } ?? Array(Set(
            Array(awtrixSettingsSaveTasks.keys) + Array(awtrixContentSaveTasks.keys)
                + Array(awtrixHASyncTasks.keys) + Array(awtrixLoopSaveTasks.keys)
                + Array(awtrixHALastContent.keys) + Array(awtrixRequestedCardNames.keys)))
        for id in ids {
            awtrixSettingsSaveTasks.removeValue(forKey: id)?.cancel()
            awtrixContentSaveTasks.removeValue(forKey: id)?.cancel()
            awtrixHASyncTasks.removeValue(forKey: id)?.cancel()
            awtrixLoopSaveTasks.removeValue(forKey: id)?.cancel()
            awtrixDesiredLoopOrders[id] = nil
            awtrixHALastContent[id] = nil
            awtrixHALastAttempt[id] = nil
            awtrixHAEntities[id] = nil
            awtrixRequestedCardNames[id] = nil
            awtrixManualDisplayReturnTasks.removeValue(forKey: id)?.cancel()
            awtrixManualDisplayActiveIDs.remove(id)
            awtrixManualDisplayEpochs[id] = nil
        }
        for key in Array(awtrixConfigSaveTasks.keys) where deviceID == nil || key.hasPrefix(deviceID!.uuidString + "|") {
            awtrixConfigSaveTasks.removeValue(forKey: key)?.cancel()
        }
    }
}
