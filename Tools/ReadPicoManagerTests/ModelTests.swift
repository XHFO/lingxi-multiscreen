import Foundation
import LinxDisplayCore

private var checks = 0
@MainActor private func check(_ condition: Bool, _ description: String) {
    checks += 1
    if !condition { fatalError(description) }
}
private func snapshot(_ config: ReadPicoHomeConfiguration) throws -> ReadPicoHomeSnapshot {
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
    return try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: JSONSerialization.data(withJSONObject: ["config": encoded, "saved_wifi": ["Home"], "network_online": true]))
}
private func makeCapabilities(config: ReadPicoDeviceConfiguration? = ReadPicoDeviceConfiguration(),
                              canvasState: String = "displayed", canvasRevision: Int = 1) throws -> ReadPicoCapabilities {
    var body: [String: Any] = ["protocol": 1,
        "canvas": ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 110000, "state": canvasState, "revision": canvasRevision]]
    if let config { body["config"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) }
    return try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: body))
}
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private actor Device: ReadPicoManagerDeviceClient {
    var config = ReadPicoHomeConfiguration()
    var powerConfig = ReadPicoDeviceConfiguration()
    var failRead = false, failSave = false, failAfterSave = false, ignoreSave = false, holdPower = false
    var failPower = false, ignorePower = false, missingPower = false, unchangedPowerRevision = false
    var failCanvas = false, unconfirmedCanvas = false
    var readGate: Gate?, saveGate: Gate?, capabilityGate: Gate?, powerGate: Gate?, canvasGate: Gate?
    var capabilityError: Int?, loseToken = false
    var reads = 0, saves = 0, powers = 0, canvases = 0
    var events: [String] = []
    func setup(failRead: Bool = false, failSave: Bool = false, failAfterSave: Bool = false, ignoreSave: Bool = false, holdPower: Bool = false,
               readGate: Gate? = nil, saveGate: Gate? = nil, capabilityGate: Gate? = nil, capabilityError: Int? = nil, loseToken: Bool = false,
               failPower: Bool = false, ignorePower: Bool = false, missingPower: Bool = false, unchangedPowerRevision: Bool = false,
               powerGate: Gate? = nil, canvasGate: Gate? = nil, failCanvas: Bool = false, unconfirmedCanvas: Bool = false) {
        self.failRead = failRead; self.failSave = failSave; self.failAfterSave = failAfterSave
        self.ignoreSave = ignoreSave; self.holdPower = holdPower
        self.readGate = readGate; self.saveGate = saveGate; self.capabilityGate = capabilityGate
        self.capabilityError = capabilityError; self.loseToken = loseToken
        self.failPower = failPower; self.ignorePower = ignorePower; self.missingPower = missingPower
        self.unchangedPowerRevision = unchangedPowerRevision; self.powerGate = powerGate; self.canvasGate = canvasGate
        self.failCanvas = failCanvas; self.unconfirmedCanvas = unconfirmedCanvas
    }
    func counts() -> (Int, Int, Int, Int) { (reads, saves, powers, canvases) }
    func recordedEvents() -> [String] { events }
    func resetEvents() { events = [] }
    func home() async throws -> ReadPicoHomeSnapshot {
        reads += 1; events.append("home-read")
        if failRead { throw URLError(.cannotConnectToHost) }
        if let readGate { await readGate.wait() }
        return try snapshot(config)
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {
        saves += 1; events.append("home-write")
        if failSave { throw ReadPicoManagerError.invalid("本地验证失败") }
        if let saveGate { await saveGate.wait() }
        if !ignoreSave { let hadToken = self.config.hasToken; self.config = config; self.config.hasToken = hadToken || !token.isEmpty }
        if loseToken { self.config.hasToken = false }
        if failAfterSave { failRead = true }
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        if let capabilityGate { await capabilityGate.wait() }
        if let capabilityError { throw ReadPicoManagerError.http(capabilityError) }
        return try makeCapabilities(config: powerConfig)
    }
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities {
        powers += 1; events.append("power-write")
        if failPower { throw URLError(.cannotConnectToHost) }
        if let powerGate { await powerGate.wait() }
        while holdPower { try await Task.sleep(nanoseconds: 10_000_000) }
        var committed = ignorePower ? powerConfig : configuration
        committed.state = 2; committed.revision = powerConfig.revision + (unchangedPowerRevision ? 0 : 1)
        powerConfig = committed
        return try makeCapabilities(config: missingPower ? nil : committed)
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        canvases += 1; await onAccepted?()
        if failCanvas { throw URLError(.cannotConnectToHost) }
        if let canvasGate { await canvasGate.wait() }
        while holdPower { try await Task.sleep(nanoseconds: 10_000_000) }
        return try makeCapabilities(canvasState: unconfirmedCanvas ? "queued" : "displayed", canvasRevision: canvases + 1)
    }
}
@MainActor private func idle(_ model: ReadPicoManagerModel) async throws {
    for _ in 0..<300 { if !model.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    fatalError("model did not settle")
}
@MainActor private func connected(_ device: Device, address: String) async throws -> ReadPicoManagerModel {
    let model = ReadPicoManagerModel { _ in device }
    check(model.connect(address: address, key: ""), "clean model accepts a connection")
    try await idle(model)
    check(model.connection != nil && !model.hasUnsavedDeviceChanges, "connection establishes clean confirmed baselines")
    return model
}
@MainActor private func editBoth(_ model: ReadPicoManagerModel) {
    model.home.enabled = true; model.home.local = "http://home.local:8123"; model.home.homeWifi = "Home"
    model.homeToken = "new-token"; model.deviceConfiguration.autoSleepMinutes = 10
}
@MainActor private func draftAndCompletionChecks(addressA: String, addressB: String) async throws {
    let device = Device(), model = try await connected(device, address: addressA)
    let home = model.confirmedHome, power = model.confirmedDeviceConfig
    model.deviceConfiguration.state = 3; model.deviceConfiguration.revision = 91
    check(!model.hasUnsavedPowerChanges, "power telemetry is not an editable draft")
    editBoth(model)
    let homeDraft = model.home, powerDraft = model.deviceConfiguration
    check(model.hasUnsavedHomeChanges && model.hasUnsavedPowerChanges && model.hasUnsavedDeviceChanges, "both draft categories are tracked")
    for action in ["connect", "disconnect", "input"] {
        let accepted: Bool
        switch action {
        case "connect": accepted = model.connect(address: addressB, key: "")
        case "disconnect": accepted = model.disconnect()
        default: accepted = model.connectionInputChanged()
        }
        check(!accepted && !model.busy && model.connection?.baseURL.host == "a.local", "dirty \(action) cannot retire the target")
        check(model.home == homeDraft && model.homeToken == "new-token" && model.deviceConfiguration == powerDraft, "dirty \(action) preserves every draft field")
        check(model.confirmedHome == home && model.confirmedDeviceConfig == power, "dirty \(action) cannot advance baselines")
    }
    check(model.discardPendingDeviceChanges() && !model.hasUnsavedDeviceChanges && model.homeToken.isEmpty, "explicit discard restores confirmed settings")
    check(model.home == home && model.deviceConfiguration == power && model.connection != nil, "discard retains the connected target")
    model.homeToken = "discard-input"
    check(model.connectionInputChanged(discardChanges: true) && model.connection == nil && !model.hasUnsavedDeviceChanges, "explicit input change clears drafts and credentials")
    model.connect(address: addressA, key: ""); try await idle(model)
    model.deviceConfiguration.doubleTapWake.toggle()
    check(model.disconnect(discardChanges: true) && model.connection == nil && model.confirmedHome == nil && model.confirmedDeviceConfig == nil, "explicit disconnect retires both baselines")

    let successDevice = Device(), success = try await connected(successDevice, address: addressA)
    var cleanCallback = false
    success.savePendingDeviceChanges { value in cleanCallback = value; check(!success.busy, "clean no-op callback runs outside busy") }
    let cleanCounts = await successDevice.counts()
    check(cleanCallback && cleanCounts.1 == 0 && cleanCounts.2 == 0, "clean aggregate save performs no requests")
    editBoth(success); let gate = Gate(); await successDevice.setup(saveGate: gate); await successDevice.resetEvents()
    var results: [Bool] = []
    success.savePendingDeviceChanges { value in results.append(value); check(!success.busy, "aggregate callback runs only after busy clears") }
    try await Task.sleep(nanoseconds: 30_000_000)
    check(success.busy && success.hasUnsavedHomeChanges && success.hasUnsavedPowerChanges && results.isEmpty, "accepted HA request alone cannot clear either pending draft")
    var busySaveResult: Bool?, busyPushResult: Bool?
    success.savePendingDeviceChanges { value in busySaveResult = value; check(!success.busy, "busy save rejection waits for idle before completing") }
    success.push(Data()) { value in busyPushResult = value; check(!success.busy, "busy push rejection waits for idle before completing") }
    check(busySaveResult == nil && busyPushResult == nil, "refused requests cannot complete while another operation is busy")
    check(await successDevice.counts().2 == 0, "power is not submitted before HA confirmation")
    check(!success.discardPendingDeviceChanges() && !success.disconnect(discardChanges: true), "busy transaction rejects even explicit discard")
    await gate.open(); try await idle(success)
    check(results == [true] && !success.hasUnsavedDeviceChanges && success.homeToken.isEmpty, "both confirmed saves complete exactly once")
    let afterBusyCounts = await successDevice.counts()
    check(busySaveResult == false && busyPushResult == false && afterBusyCounts.3 == 0, "busy requests fail once without issuing another save or canvas")
    check(await successDevice.recordedEvents() == ["home-write", "home-read", "power-write"], "aggregate save follows HA write/readback then power")
    check(success.confirmedHome == success.home && success.confirmedDeviceConfig == success.deviceConfiguration, "each matching readback advances its baseline")

    let failedHomeDevice = Device(), failedHome = try await connected(failedHomeDevice, address: addressA)
    let previousHome = failedHome.confirmedHome, previousPower = failedHome.confirmedDeviceConfig
    editBoth(failedHome); await failedHomeDevice.setup(failSave: true)
    var homeResults: [Bool] = []
    failedHome.savePendingDeviceChanges { value in homeResults.append(value); check(!failedHome.busy, "failed callback releases busy first") }
    try await idle(failedHome)
    check(homeResults == [false] && failedHome.hasUnsavedHomeChanges && failedHome.hasUnsavedPowerChanges && failedHome.homeToken == "new-token", "HA failure keeps both drafts and token")
    let failedHomeCounts = await failedHomeDevice.counts()
    check(failedHome.confirmedHome == previousHome && failedHome.confirmedDeviceConfig == previousPower && failedHomeCounts.2 == 0, "HA failure neither advances baselines nor submits power")

    let partialDevice = Device(), partial = try await connected(partialDevice, address: addressA)
    editBoth(partial); let oldPower = partial.confirmedDeviceConfig; await partialDevice.setup(failPower: true)
    var partialResults: [Bool] = []
    partial.savePendingDeviceChanges { partialResults.append($0) }; try await idle(partial)
    check(partialResults == [false] && !partial.hasUnsavedHomeChanges && partial.hasUnsavedPowerChanges, "confirmed HA survives a later power failure without a false all-saved result")
    check(partial.homeToken.isEmpty && partial.confirmedHome == partial.home && partial.confirmedDeviceConfig == oldPower, "partial success advances only the confirmed baseline")
    let savesBeforeRetry = await partialDevice.counts().1; await partialDevice.setup()
    partial.savePendingDeviceChanges { partialResults.append($0) }; try await idle(partial)
    let retryCounts = await partialDevice.counts()
    check(partialResults == [false, true] && !partial.hasUnsavedDeviceChanges && retryCounts.1 == savesBeforeRetry, "retry saves only the remaining power draft")

    for mode in ["missing", "mismatch", "revision"] {
        let badDevice = Device(), bad = try await connected(badDevice, address: addressA)
        let confirmed = bad.confirmedDeviceConfig; bad.deviceConfiguration.autoSleepMinutes = 30
        await badDevice.setup(ignorePower: mode == "mismatch", missingPower: mode == "missing", unchangedPowerRevision: mode == "revision")
        bad.saveDeviceSettings(); try await idle(bad)
        check(bad.isError && bad.hasUnsavedPowerChanges && bad.deviceConfiguration.autoSleepMinutes == 30 && bad.confirmedDeviceConfig == confirmed, "\(mode) power response cannot confirm or discard a draft")
    }

    let cancelledDevice = Device(), cancelled = try await connected(cancelledDevice, address: addressA)
    editBoth(cancelled); let cancelGate = Gate(); await cancelledDevice.setup(saveGate: cancelGate)
    let cancelHome = cancelled.confirmedHome, cancelPower = cancelled.confirmedDeviceConfig
    var cancelledResults: [Bool] = []
    cancelled.savePendingDeviceChanges { value in cancelledResults.append(value); check(!cancelled.busy, "cancel callback runs after settling") }
    try await Task.sleep(nanoseconds: 30_000_000); cancelled.cancelOperation()
    check(cancelled.busy && cancelled.cancelling && cancelledResults.isEmpty, "cancellation does not optimistically complete an ignored request")
    await cancelGate.open(); try await idle(cancelled)
    check(cancelledResults == [false] && cancelled.hasUnsavedHomeChanges && cancelled.hasUnsavedPowerChanges && cancelled.homeToken == "new-token", "cancelled aggregate retains all unconfirmed drafts")
    let cancelledCounts = await cancelledDevice.counts()
    check(cancelled.confirmedHome == cancelHome && cancelled.confirmedDeviceConfig == cancelPower && cancelledCounts.2 == 0, "cancelled late HA completion cannot advance either baseline or submit power")

    let powerCancelDevice = Device(), powerCancelled = try await connected(powerCancelDevice, address: addressA)
    editBoth(powerCancelled); let powerCancelGate = Gate(), previousPowerConfirmation = powerCancelled.confirmedDeviceConfig
    await powerCancelDevice.setup(powerGate: powerCancelGate)
    var powerCancelResults: [Bool] = []
    powerCancelled.savePendingDeviceChanges { value in powerCancelResults.append(value); check(!powerCancelled.busy, "power cancellation callback runs after busy release") }
    for _ in 0..<100 {
        if await powerCancelDevice.counts().2 == 1 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(powerCancelled.busy && !powerCancelled.hasUnsavedHomeChanges && powerCancelled.hasUnsavedPowerChanges && powerCancelled.homeToken.isEmpty, "confirmed HA stays committed while power confirmation is pending")
    powerCancelled.cancelOperation(); await powerCancelGate.open(); try await idle(powerCancelled)
    check(powerCancelResults == [false] && !powerCancelled.hasUnsavedHomeChanges && powerCancelled.hasUnsavedPowerChanges && powerCancelled.confirmedDeviceConfig == previousPowerConfirmation, "cancellation during power keeps confirmed HA and the unconfirmed power draft")

    let lateDevice = Device(), lateGate = Gate(), freshDevice = Device()
    let lifecycle = ReadPicoManagerModel { connection in connection.baseURL.host == "a.local" ? lateDevice : freshDevice }
    lifecycle.connect(address: addressA, key: ""); try await idle(lifecycle)
    editBoth(lifecycle); await lateDevice.setup(saveGate: lateGate)
    var lateResults: [Bool] = []
    lifecycle.savePendingDeviceChanges { value in lateResults.append(value); check(!lifecycle.busy, "deactivation callback sees settled state") }
    try await Task.sleep(nanoseconds: 30_000_000); lifecycle.deactivate()
    check(lateResults == [false] && lifecycle.homeToken.isEmpty && !lifecycle.hasUnsavedDeviceChanges, "deactivation cancels completion and wipes secrets safely")
    lifecycle.connect(address: addressB, key: ""); try await idle(lifecycle)
    let newHome = lifecycle.home, newPower = lifecycle.deviceConfiguration
    await lateGate.open(); try await Task.sleep(nanoseconds: 30_000_000)
    check(lateResults == [false] && lifecycle.connection?.baseURL.host == "b.local" && lifecycle.home == newHome && lifecycle.deviceConfiguration == newPower && !lifecycle.hasUnsavedDeviceChanges, "old save readback cannot touch a new target or complete twice")

    let newerDevice = Device(), newer = try await connected(newerDevice, address: addressA), newerGate = Gate()
    editBoth(newer); await newerDevice.setup(saveGate: newerGate)
    var newerResult: Bool?
    newer.savePendingDeviceChanges { newerResult = $0 }
    try await Task.sleep(nanoseconds: 30_000_000)
    newer.home.external = "https://new-draft.example"; newer.homeToken = "newer-token"
    await newerGate.open(); try await idle(newer)
    check(newerResult == false && newer.hasUnsavedHomeChanges && newer.home.external == "https://new-draft.example" && newer.homeToken == "newer-token", "confirmed older submission cannot erase a newer draft or allow exit")

    let canvasDevice = Device(), canvas = try await connected(canvasDevice, address: addressA)
    var canvasResults: [Bool] = []
    canvas.push(Data()) { value in canvasResults.append(value); check(!canvas.busy, "canvas completion runs outside busy") }; try await idle(canvas)
    check(canvasResults == [true] && canvas.capability?.revision == 2, "only confirmed displayed canvas completes successfully")
    for mode in ["error", "queued"] {
        await canvasDevice.setup(failCanvas: mode == "error", unconfirmedCanvas: mode == "queued")
        canvas.push(Data()) { canvasResults.append($0) }; try await idle(canvas)
        check(canvasResults.last == false && canvas.isError && canvas.capability?.revision == 2, "\(mode) canvas preserves previous confirmed capability")
    }
    let canvasGate = Gate(); await canvasDevice.setup(canvasGate: canvasGate)
    canvas.push(Data()) { value in canvasResults.append(value); check(!canvas.busy, "cancelled canvas completion waits for busy release") }
    try await Task.sleep(nanoseconds: 30_000_000); canvas.cancelOperation(); await canvasGate.open(); try await idle(canvas)
    check(canvasResults == [true, false, false, false] && canvas.capability?.revision == 2, "cancelled late canvas cannot falsely confirm display")
    canvas.deactivate(); var disconnectedCanvas: Bool?
    canvas.push(Data()) { disconnectedCanvas = $0 }
    check(disconnectedCanvas == false && !canvas.busy, "unconnected canvas attempt completes with failure")
}
@main struct ReadPicoModelTests {
    @MainActor static func main() async throws {
        let addressA = "http://a.local/manage#key=" + String(repeating: "a", count: 32)
        let addressB = "http://b.local/manage#key=" + String(repeating: "b", count: 32)
        let a = Device(), b = Device()
        await b.setup(failRead: true)
        let model = ReadPicoManagerModel { connection in connection.baseURL.host == "b.local" ? b : a }
        model.connect(address: addressA, key: "")
        check(model.busy && model.connection == nil, "connect does not publish a partial session")
        try await idle(model)
        check(model.connection?.baseURL.host == "a.local" && model.deviceSettingsSupported, "all connected state commits together")
        model.homeToken = "unsaved-token"
        check(!model.connect(address: addressB, key: "") && !model.busy && model.connection?.baseURL.host == "a.local" && model.homeToken == "unsaved-token", "new target is rejected until draft discard is explicit")
        model.connect(address: addressB, key: "", discardChanges: true)
        check(model.busy && model.connection == nil && model.homeToken.isEmpty && !model.deviceSettingsSupported, "new target retires old client and credentials immediately")
        try await idle(model)
        check(model.isError && model.connection == nil && model.capability == nil, "failed reconnect cannot retain old target")
        model.saveHome()
        check(await a.counts().1 == 0 && !model.busy, "failed B cannot save A")
        model.connect(address: addressA, key: ""); try await idle(model)
        model.connectionInputChanged()
        check(model.connection == nil && model.home == .init(), "editing connection input disables all old-target settings")

        let atomicDevice = Device(), capGate = Gate()
        await atomicDevice.setup(capabilityGate: capGate)
        let atomic = ReadPicoManagerModel { _ in atomicDevice }
        atomic.connect(address: addressA, key: "")
        try await Task.sleep(nanoseconds: 30_000_000)
        check(atomic.busy && atomic.connection == nil && atomic.capability == nil, "HA response alone cannot expose partially read settings")
        await capGate.open(); try await idle(atomic)
        check(atomic.connection != nil && atomic.capability != nil, "capability completes one atomic publication")

        let compatibilityDevice = Device()
        await compatibilityDevice.setup(capabilityError: 404)
        let compatibility = ReadPicoManagerModel { _ in compatibilityDevice }
        compatibility.connect(address: addressA, key: ""); try await idle(compatibility)
        check(compatibility.connection != nil && !compatibility.deviceSettingsSupported && !compatibility.isError, "only a missing extension supports old-firmware fallback")
        await compatibilityDevice.setup(capabilityError: 500)
        compatibility.connect(address: addressA, key: ""); try await idle(compatibility)
        check(compatibility.connection == nil && compatibility.isError, "capability server failure cannot masquerade as successful old firmware")

        await a.setup(failSave: true)
        model.connect(address: addressA, key: ""); try await idle(model)
        model.homeToken = "retained-token"; model.saveHome()
        check(model.busy && model.homeToken == "retained-token", "token stays visible until actual confirmation")
        try await idle(model)
        check(model.isError && model.homeToken == "retained-token", "local validation/save error retains token")
        let saveGate = Gate()
        await a.setup(saveGate: saveGate)
        model.home.local = "http://home.local:8123"; model.home.homeWifi = "Home"; model.saveHome()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(model.busy && model.homeToken == "retained-token", "saving remains busy with draft intact")
        await saveGate.open(); try await idle(model)
        check(!model.isError && model.homeToken.isEmpty && model.home.hasToken, "only confirmed matching readback clears token")
        await a.setup(loseToken: true)
        model.saveHome(); try await idle(model)
        check(model.isError && model.home.hasToken && model.message.contains("不一致"), "lost existing credential cannot masquerade as a successful unchanged save")
        await a.setup(ignoreSave: true)
        model.home.enabled.toggle(); model.homeToken = "mismatch-token"; model.saveHome(); try await idle(model)
        check(model.isError && model.homeToken == "mismatch-token" && model.message.contains("回读"), "mismatched readback cannot report saved or discard draft")
        await a.setup(failAfterSave: true)
        model.saveHome(); try await idle(model)
        check(model.isError && model.homeToken == "mismatch-token" && model.message.contains("已提交") && model.message.contains("未确认"), "post-save read failure preserves accepted-but-unconfirmed stage")

        await a.setup(holdPower: true)
        model.saveDeviceSettings()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(model.busy && model.canCancel, "network operation exposes cancellable wait")
        model.cancelOperation(); try await idle(model)
        check(!model.isError && !model.busy && model.message.contains("已停止等待") && model.message.contains("可能继续完成"), "cancel never promises to undo an accepted request")

        let lateDevice = Device(), lateGate = Gate(), freshDevice = Device()
        await lateDevice.setup(readGate: lateGate)
        let lifecycle = ReadPicoManagerModel { connection in connection.baseURL.host == "a.local" ? lateDevice : freshDevice }
        lifecycle.connect(address: addressA, key: "")
        try await Task.sleep(nanoseconds: 30_000_000)
        lifecycle.deactivate()
        check(!lifecycle.busy && lifecycle.connection == nil, "leaving page cancels and clears session")
        lifecycle.connect(address: addressB, key: ""); try await idle(lifecycle)
        await lateGate.open(); try await Task.sleep(nanoseconds: 30_000_000)
        check(lifecycle.connection?.baseURL.host == "b.local" && !lifecycle.busy && !lifecycle.isError, "late cancelled completion cannot replace fresh target or message")

        try await draftAndCompletionChecks(addressA: addressA, addressB: addressB)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pico-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let card = temporary.appendingPathComponent("card"), book = temporary.appendingPathComponent("book.txt")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true); try Data("正文".utf8).write(to: book)
        let files = ReadPicoManagerModel()
        files.selectCard(card); try await idle(files)
        files.install([book], kind: .book, replace: false)
        check(files.busy, "content transaction raises the same busy gate")
        try await idle(files)
        check(files.files.count == 1 && !files.isError, "real import commits and refreshes")
        files.remove(files.files[0]); check(files.busy && !files.canCancel, "atomic removal cannot be interrupted mid transaction")
        try await idle(files)
        check(files.files.isEmpty && !files.isError, "real removal finishes before unlocking")
        files.install([book], kind: .book, replace: false); files.cancelOperation(); try await idle(files)
        check(files.files.isEmpty && files.message.contains("已停止后续导入"), "cancel before batch starts leaves card unchanged")
        files.install([book], kind: .book, replace: false); files.deactivate()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(!FileManager.default.fileExists(atPath: card.appendingPathComponent("books/book.txt").path), "leaving page prevents not-yet-started batch writes")
        print("PASS: \(checks) actual ReadPicoManagerModel target, draft, confirmation, cancellation and TF lifecycle checks; no device accessed.")
    }
}
