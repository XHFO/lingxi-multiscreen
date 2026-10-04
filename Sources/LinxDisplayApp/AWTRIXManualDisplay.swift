import Foundation
import LinxDisplayCore

@MainActor
extension AppModel {
    /// 调用方持有设备操作锁。只临时启用被排除的目标，保留后台脚本和原生轮播顺序。
    func activateAWTRIXCardForDisplay(_ name: String, deviceID: UUID,
                                      restartReturn: Bool = true) async throws {
        var config = awtrixSettings(for: deviceID)
        if let session = config.manualDisplaySession,
           session.appName != name || session.baseURL != config.baseURL || session.username != config.username {
            try await restoreAWTRIXManualDisplay(deviceID: deviceID)
            config = awtrixSettings(for: deviceID)
        }
        let apps = try await Self.awtrixClient.fetchApps(config)
        try Task.checkCancellation()
        guard awtrixDeviceStillMatches(config, deviceID: deviceID) else { throw CancellationError() }
        guard let target = apps.first(where: { $0.name == name }) else {
            throw AWTRIXError.requestFailed(404, "卡片不存在，请刷新卡片列表")
        }
        if target.enabled == false {
            let session = config.manualDisplaySession ?? AWTRIXManualDisplaySession(appName: name,
                order: apps.filter(Self.awtrixAppIsInLoop).map(\.name),
                disabled: apps.filter { $0.enabled == false }.map(\.name),
                autoTransition: config.autoTransition, baseURL: config.baseURL, username: config.username)
            // 先保存恢复点，再修改设备；崩溃或重启后能够归还原设置。
            mutateAWTRIXSettings(deviceID) { $0.manualDisplaySession = session }
            awtrixManualDisplayActiveIDs.insert(deviceID)
            do {
                if session.autoTransition {
                    try await Self.awtrixClient.setAutoTransition(false, configuration: config)
                }
                try Task.checkCancellation()
                try await Self.awtrixClient.setAppOrder(session.order + [name],
                    disabled: session.disabled.filter { $0 != name }, configuration: config)
                try Task.checkCancellation()
            } catch {
                let repair = Task { try? await self.restoreAWTRIXManualDisplay(deviceID: deviceID) }
                await repair.value
                throw error
            }
        }
        do {
            if restartReturn {
                // 真正接管显示时才废弃旧驻留计时；前置HA/上传失败仍保留旧归还路径。
                awtrixManualDisplayEpochs[deviceID] = UUID()
                awtrixManualDisplayReturnTasks.removeValue(forKey: deviceID)?.cancel()
            }
            try await Self.awtrixClient.activateApp(name, fast: true, configuration: config)
            try Task.checkCancellation()
            if let session = awtrixSettings(for: deviceID).manualDisplaySession {
                awtrixManualDisplayActiveIDs.insert(deviceID)
                if restartReturn || awtrixManualDisplayReturnTasks[deviceID] == nil {
                    scheduleAWTRIXManualDisplayReturn(session, deviceID: deviceID)
                }
            }
            await refreshAWTRIXCurrentState(deviceID: deviceID)
        } catch {
            if awtrixSettings(for: deviceID).manualDisplaySession != nil {
                let repair = Task { try? await self.restoreAWTRIXManualDisplay(deviceID: deviceID) }
                await repair.value
            }
            throw error
        }
    }

    /// 调用方持锁。恢复失败保留磁盘恢复点，下一次操作或重启可以重试。
    func restoreAWTRIXManualDisplay(deviceID: UUID) async throws {
        awtrixManualDisplayReturnTasks.removeValue(forKey: deviceID)?.cancel()
        let config = awtrixSettings(for: deviceID)
        guard let session = config.manualDisplaySession else { return }
        guard session.baseURL == config.baseURL, session.username == config.username else {
            // 同一受管UUID换成另一台物理设备后，不可向新设备写旧设备的轮播清单。
            mutateAWTRIXSettings(deviceID) { $0.manualDisplaySession = nil }
            awtrixManualDisplayActiveIDs.remove(deviceID)
            return
        }
        try await Self.awtrixClient.setAppOrder(session.order, disabled: session.disabled,
                                                configuration: config)
        try await Self.awtrixClient.setAutoTransition(session.autoTransition, configuration: config)
        guard awtrixDeviceStillMatches(config, deviceID: deviceID) else { throw CancellationError() }
        mutateAWTRIXSettings(deviceID) { $0.manualDisplaySession = nil }
        awtrixManualDisplayActiveIDs.remove(deviceID)
    }

    func finishAWTRIXManualDisplay(deviceID: UUID, expectedEpoch: UUID? = nil) async -> Bool {
        guard await waitForAWTRIXDevice(deviceID) else { return false }
        if let expectedEpoch {
            guard awtrixManualDisplayEpochs[deviceID] == expectedEpoch else { return false }
            // 已经拿到锁且代次仍有效，移除当前计时任务，避免归还操作取消自身。
            awtrixManualDisplayReturnTasks[deviceID] = nil
        }
        awtrixBusyIDs.insert(deviceID)
        defer { awtrixBusyIDs.remove(deviceID) }
        do {
            try await restoreAWTRIXManualDisplay(deviceID: deviceID)
            await refreshAWTRIXCurrentState(deviceID: deviceID)
            return true
        } catch {
            if !Task.isCancelled { awtrixStatuses[deviceID] = "恢复轮播失败：\(Self.awtrixFriendly(error))" }
            return false
        }
    }

    private func scheduleAWTRIXManualDisplayReturn(_ session: AWTRIXManualDisplaySession,
                                                   deviceID: UUID) {
        awtrixManualDisplayReturnTasks.removeValue(forKey: deviceID)?.cancel()
        guard session.autoTransition else { return }
        let epoch = UUID()
        let displayGeneration = awtrixDisplayRequestPolicy.currentGeneration(for: deviceID)
        awtrixManualDisplayEpochs[deviceID] = epoch
        let delay = UInt64(awtrixSettings(for: deviceID).appDurationSeconds) * 1_000_000_000
        awtrixManualDisplayReturnTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled,
                  self.awtrixSettings(for: deviceID).manualDisplaySession == session else { return }
            while !Task.isCancelled, self.awtrixDeviceExists(deviceID),
                  self.awtrixManualDisplayEpochs[deviceID] == epoch {
                if await self.finishAWTRIXManualDisplay(deviceID: deviceID, expectedEpoch: epoch) {
                    if self.awtrixManualDisplayEpochs[deviceID] == epoch,
                       self.awtrixDisplayRequestPolicy.currentGeneration(for: deviceID) == displayGeneration {
                        self.awtrixRequestedCardNames[deviceID] = nil
                        self.awtrixStatuses[deviceID] = "临时显示结束，已恢复原轮播"
                        await self.refreshAWTRIXLivePreview(deviceID: deviceID)
                    }
                    return
                }
                // 离线时保留恢复点并低频重试；代次变化后不再触碰新选择。
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }

    var hasAWTRIXManualDisplayToRestore: Bool {
        enabledDevices(for: .awtrix).contains { awtrixSettings(for: $0.id).manualDisplaySession != nil }
    }

    func restoreAWTRIXManualDisplaysBeforeQuit() async {
        awtrixPreparingForQuit = true
        cancelAWTRIXBackgroundWork()
        awtrixDisplayRequestTasks.values.forEach { $0.cancel() }
        awtrixDisplayRequestTasks.removeAll()
        for device in enabledDevices(for: .awtrix) where awtrixSettings(for: device.id).manualDisplaySession != nil {
            _ = await finishAWTRIXManualDisplay(deviceID: device.id)
        }
    }

    /// 切卡只读轻量状态和清单，不在每次操作后重新加载所有调色板。
    func refreshAWTRIXCurrentState(deviceID: UUID) async {
        let config = awtrixSettings(for: deviceID)
        do {
            let device = try await Self.awtrixClient.fetchDevice(config)
            let apps = try await Self.awtrixClient.fetchApps(config)
            guard !Task.isCancelled, awtrixDeviceStillMatches(config, deviceID: deviceID),
                  let snapshot = awtrixSnapshots[deviceID] else { return }
            awtrixSnapshots[deviceID] = AWTRIXSnapshot(device: device,
                settings: snapshot.settings, system: snapshot.system, apps: apps,
                capabilities: snapshot.capabilities, paletteDefinitions: snapshot.paletteDefinitions)
        } catch { /* 显示请求自身单独报错，状态读取失败不覆盖它。 */ }
    }
}
