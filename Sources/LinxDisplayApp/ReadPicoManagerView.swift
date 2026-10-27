import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import DiskArbitration
import IOKit
import LinxDisplayCore

protocol ReadPicoManagerDeviceClient: ReadPicoContentStore {
    func home() async throws -> ReadPicoHomeSnapshot
    func homeLink() async throws -> ReadPicoHomeLinkDocument
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String, cfAccessClientId: String, cfAccessClientSecret: String) async throws
    func capabilities() async throws -> ReadPicoCapabilities
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                             contentChannel: ReadPicoContentChannel,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities
    func lockImage() async throws -> Data
    func saveLockImageConfirmed(_ bmp: Data, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities
}
extension ReadPicoManagerDeviceClient {
    /// Default: synthesize from `home()` so USB/test doubles need not implement the aggregate route.
    func homeLink() async throws -> ReadPicoHomeLinkDocument {
        let snap = try await home()
        var body: [String: Any] = [
            "ok": true,
            "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap.config)),
            "network_online": snap.networkOnline
        ]
        if let portal = snap.portal {
            body["portal"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(portal))
        }
        return try JSONDecoder().decode(ReadPicoHomeLinkDocument.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        guard !display || capability.displayIntent == true else { throw ReadPicoManagerError.unavailable("请更新设备固件，以支持发送后立即展示。") }
        return try await pushCanvasConfirmed(bmp, capability: capability, onAccepted: onAccepted)
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                             contentChannel: ReadPicoContentChannel,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        guard contentChannel == .canvas else { throw ReadPicoManagerError.unavailable("当前连接尚不支持 Cloudflare 独立应用。") }
        return try await pushCanvasConfirmed(bmp, capability: capability, display: display, onAccepted: onAccepted)
    }
    func scan() async throws -> [ReadPicoCardFile] { throw ReadPicoManagerError.unavailable("当前固件尚未开放 Wi-Fi 内容管理，请更新固件或使用 USB。") }
    func proposedPath(for source: URL, kind: ReadPicoFileKind) async throws -> String { throw ReadPicoManagerError.unavailable("当前连接不支持 Wi-Fi 文件上传。") }
    func isIdentical(_ source: URL, kind: ReadPicoFileKind) async throws -> Bool { throw ReadPicoManagerError.unavailable("当前连接不支持 Wi-Fi 文件校验。") }
    func importFile(_ source: URL, kind: ReadPicoFileKind, replace: Bool, progress: (@Sendable (Int64, Int64, String) -> Void)?) async throws -> String { throw ReadPicoManagerError.unavailable("当前连接不支持 Wi-Fi 文件上传。") }
    func remove(_ item: ReadPicoCardFile) async throws { throw ReadPicoManagerError.unavailable("当前连接不支持 Wi-Fi 文件移除。") }
    func export(_ item: ReadPicoCardFile, to destination: URL, format: String) async throws { throw ReadPicoManagerError.unavailable("当前连接不支持 Wi-Fi 文件导出。") }
    func lockImage() async throws -> Data { throw ReadPicoManagerError.unavailable("当前连接尚不支持锁屏图片读取。") }
    func saveLockImageConfirmed(_ bmp: Data, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        throw ReadPicoManagerError.unavailable("当前连接尚不支持锁屏图片上传。")
    }
}
extension ReadPicoHTTPClient: ReadPicoManagerDeviceClient {}

@MainActor final class ReadPicoManagerModel: ObservableObject {
    struct BoardDelivery: Equatable {
        let id: UUID
        let displayed: Bool
        let revision: UInt32?
        let orientation: String?
        let contentChannel: ReadPicoContentChannel
        init(id: UUID, displayed: Bool, revision: UInt32? = nil, orientation: String? = nil, contentChannel: ReadPicoContentChannel = .canvas) {
            self.id = id; self.displayed = displayed; self.revision = revision; self.orientation = orientation; self.contentChannel = contentChannel
        }
    }
    private enum BoardReceiptTarget {
        case wireless(session: UUID, revision: UInt32, contentChannel: ReadPicoContentChannel)
        case usb(identity: String, taskID: String, contentChannel: ReadPicoContentChannel)
    }
    private struct BoardReceiptSample: Sendable {
        let displayed: Bool
        let power: ReadPicoPowerStatus?
        let canvas: ReadPicoCanvasCapability?
        let revision: UInt32?
        let orientation: String?
    }
    @Published var store: ReadPicoTFStore?
    @Published var files: [ReadPicoCardFile] = []
    @Published var busy = false
    @Published var message = "连接 TF 磁盘管理内容，或通过设备地址配置网络功能。"
    @Published var isError = false
    @Published private(set) var mountedVolumes: [ReadPicoMountedVolume] = []
    @Published private(set) var usbPorts: [String] = []
    @Published private(set) var waitingForUSBVolume = false
    @Published private(set) var cardMessage = "用数据线连接阅读器，再开启 USB 传输；已开启时可直接选择下方磁盘。"
    @Published private(set) var cardError = false
    @Published var home = ReadPicoHomeConfiguration()
    @Published var homeToken = ""
    /// Write-only Cloudflare Access Service Token (external HTTPS HA only; not Analytics).
    @Published var homeCfAccessClientId = ""
    @Published var homeCfAccessClientSecret = ""
    /// From pico/status `home_link_mode`; missing field is stored as `.thin`.
    @Published private(set) var homeLinkMode: ReadPicoHomeLinkMode?
    @Published private(set) var homeModuleMissing = false
    /// From `home_portal` / home `portal`. When active, Mac must not submit HA form.
    @Published private(set) var homePortal: ReadPicoHomePortal?
    @Published var wifi: [String] = []
    @Published var connection: ReadPicoConnection?
    @Published private(set) var contentCapability: ReadPicoContentCapability?
    @Published var transportPreference: ReadPicoTransportPreference = .automatic
    @Published var boardTransportPreference: ReadPicoTransportPreference = .automatic
    @Published private(set) var boardSubmissionUncertain = false
    @Published private(set) var boardDelivery: BoardDelivery?
    @Published private(set) var provisioningPhase: ReadPicoWirelessSetupPhase = .idle
    @Published private(set) var wirelessNetworks: [ReadPicoUSBWirelessNetwork] = []
    @Published private(set) var wirelessStatus = "用 USB 连接一次，即可自动连接 Pico 或为设备配置 Wi-Fi。"
    @Published private(set) var wirelessError = false
    @Published var capability: ReadPicoCanvasCapability?
    @Published var usbBoardProgress: ReadPicoUSBBoardProgress?
    @Published private(set) var usbBoardNeedsSelection = false
    @Published private(set) var powerStatus: ReadPicoPowerStatus?
    @Published private(set) var powerStatusReceivedAt: Date?
    @Published var imageLock: ReadPicoImageLockCapability?
    @Published var lockImagePreview: Data?
    @Published var pendingLockImage: Data?
    @Published var deviceConfiguration = ReadPicoDeviceConfiguration()
    @Published var deviceSettingsSupported = false
    @Published private(set) var confirmedHome: ReadPicoHomeConfiguration?
    @Published private(set) var confirmedDeviceConfig: ReadPicoDeviceConfiguration?
    @Published private(set) var cancelling = false
    /// A device-owner lifetime, separate from HTTP/USB handoffs within that owner.
    private(set) var ownerGeneration = UUID()
    private enum Operation {
        case connect, wireless, reload, install, remove, export, home, power, settings, canvas, lockImage, readLockImage, usbStart, eject
        var message: String {
            switch self {
            case .connect: return "正在连接并读取设备设置…"
            case .wireless: return "正在通过 USB 自动连接 Pico…"
            case .reload: return "正在读取 TF 卡…"
            case .install: return "正在校验并导入文件…"
            case .remove: return "正在移除所选文件…"
            case .export: return "正在导出原稿…"
            case .home: return "正在保存 Home Assistant 设置…"
            case .power: return "正在保存并确认电源设置…"
            case .settings: return "正在依次保存并确认设备设置…"
            case .canvas: return "正在发送画布…"
            case .lockImage: return "正在保存自定义锁屏图片…"
            case .readLockImage: return "正在读取阅读器锁屏图片…"
            case .usbStart: return "正在核对设备并开启 USB 文件传输…"
            case .eject: return "正在安全弹出 TF 磁盘…"
            }
        }
        var cancellable: Bool { self != .remove && self != .export && self != .eject }
        var cancelMessage: String {
            switch self {
            case .home, .power, .settings, .canvas, .lockImage: return "已停止等待。设备已接收的请求可能继续完成；重新读取设置或在阅读器上核对结果。"
            case .install: return "已停止后续导入，已完成的文件保留；请核对列表。"
            case .usbStart: return "已停止等待。设备若已接收开启请求，TF 磁盘仍可能出现，请勿重复开启。"
            default: return "操作已取消。"
            }
        }
    }
    private var client: (any ReadPicoManagerDeviceClient)?
    private let makeClient: @Sendable (ReadPicoConnection) -> any ReadPicoManagerDeviceClient
    private let usbClient: ReadPicoUSBTransferClient
    private let wirelessClient: ReadPicoUSBWirelessClient
    private var wirelessProvisioningPort: String?
    private var wirelessProvisioningIdentity: String?
    private var wirelessUSBIdentity: String?
    private var wirelessNeedsRenewal = false
    private var wirelessRenewalRetryAfter: Date?
    private var boardRouting = ReadPicoBoardRouting()
    private let discoverVolumes: @Sendable () -> [ReadPicoMountedVolume]
    private let discoverUSBPorts: @Sendable () -> [String]
    private let identifyUSBPort: @Sendable (String) -> String?
    private let ejectVolume: @MainActor (URL) async throws -> Void
    private let volumeUSBIdentity: @Sendable (URL) -> String?
    private let boardClient: ReadPicoUSBBoardClient
    private let readUSBPower: @Sendable (String) async throws -> ReadPicoPowerStatus?
    private let boardNow: @Sendable () -> Date
    private let wirelessResumeWait: TimeInterval
    private var deviceSessionID = UUID()
    private var powerRefreshID: UUID?
    private var powerRefreshTask: Task<ReadPicoPowerStatus?, Error>?
    private var boardReceiptTarget: BoardReceiptTarget?
    private var boardReceiptTask: Task<BoardReceiptSample?, Error>?
    private var boardReceiptReadID: UUID?
    private var usbWaitStarted: Date?
    private var trustedUSBIdentity: String?
    private var selectedBoardUSBPort: String?
    private var automaticAttempts: [String: String] = [:]
    private var automaticUSBPreparationSuppressed = false
    private var preferredVolumeIdentity: String?
    private var preferredVolumeCapacity: Int64?
    private var operation: Operation?
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var operationCompletion: ((Bool) -> Void)?
    private var rejectedCompletions: [(Bool) -> Void] = []
    init(usbClient: ReadPicoUSBTransferClient = .init(),
         wirelessClient: ReadPicoUSBWirelessClient = .init(),
         discoverVolumes: @escaping @Sendable () -> [ReadPicoMountedVolume] = { ReadPicoMountedVolume.discover() },
         discoverUSBPorts: @escaping @Sendable () -> [String] = { ReadPicoUSBTransferClient.discoverPorts() },
         identifyUSBPort: @escaping @Sendable (String) -> String? = { ReadPicoUSBTransferClient.serialIdentity(port: $0) },
         ejectVolume: @escaping @MainActor (URL) async throws -> Void = { url in
             try await ReadPicoSafeEject().eject(url)
         },
         volumeUSBIdentity: @escaping @Sendable (URL) -> String? = { ReadPicoManagerModel.usbIdentity(forVolume: $0) },
         boardClient: ReadPicoUSBBoardClient = .init(),
         readUSBPower: @escaping @Sendable (String) async throws -> ReadPicoPowerStatus? = { try await ReadPicoUSBTransferClient().readPowerStatus(port: $0) },
         boardNow: @escaping @Sendable () -> Date = { Date() },
         wirelessResumeWait: TimeInterval = 8,
         makeClient: @escaping @Sendable (ReadPicoConnection) -> any ReadPicoManagerDeviceClient = { ReadPicoHTTPClient(connection: $0) }) {
        self.makeClient = makeClient; self.usbClient = usbClient; self.wirelessClient = wirelessClient; self.discoverVolumes = discoverVolumes
        self.discoverUSBPorts = discoverUSBPorts; self.identifyUSBPort = identifyUSBPort; self.ejectVolume = ejectVolume
        self.volumeUSBIdentity = volumeUSBIdentity; self.boardClient = boardClient; self.readUSBPower = readUSBPower; self.boardNow = boardNow
        self.wirelessResumeWait = min(20, max(0.01, wirelessResumeWait))
    }
    /// Read registry ancestry only. A mounted disk is never trusted from its label, folders or arrival time.
    /// 只读取磁盘所属 USB 设备的序列号，不凭盘名、文件夹或出现时间猜测 TF 卡。
    nonisolated private static func usbIdentity(forVolume url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        var entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        for _ in 0..<24 {
            for key in ["USB Serial Number", "kUSBSerialNumberString"] {
                if let serial = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   !serial.isEmpty { return serial }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry); entry = parent
        }
        return nil
    }
    var hasUSBBoardConnectionCandidate: Bool {
        let ports = usbPorts
        if let selectedBoardUSBPort, ports.contains(selectedBoardUSBPort) { return true }
        if connection == nil || boardTransportPreference == .usb { return ports.count == 1 }
        return ports.contains { ReadPicoBoardRouting.identityMatches(identifyUSBPort($0), wirelessUSBIdentity) }
    }
    var usesWirelessContent: Bool {
        transportPreference != .usb && connection != nil && client != nil && contentCapability?.isUsable == true
    }
    var canManageContent: Bool { contentStore != nil }
    var contentConnectionDescription: String {
        if usesWirelessContent { return "Wi-Fi · " + (connection?.baseURL.host ?? "Pico") }
        if transportPreference != .wifi, let store { return "USB · " + store.rootURL.lastPathComponent }
        return transportPreference == .wifi ? "等待 Wi-Fi 配对" : transportPreference == .usb ? "等待 USB 连接" : "等待连接 Pico"
    }
    private var contentStore: (any ReadPicoContentStore)? {
        if usesWirelessContent { return client }
        return transportPreference == .wifi ? nil : store
    }
    private var contentCompletionHint: String {
        usesWirelessContent ? "设备内容已更新，无需 USB 弹出。" : "安全弹出 TF 磁盘后，设备会重新读取内容。"
    }
    var prefersUSBBoard: Bool {
        switch boardTransportPreference {
        case .usb: return true
        case .wifi: return false
        case .automatic:
            return connection == nil || capability?.supportsNativeGray16 != true || boardRouting.lanState == .offline
        }
    }
    var boardLANState: ReadPicoBoardRouting.LANState { boardRouting.lanState }
    var boardLANVerifiedAt: Date? { boardRouting.probeAt }
    var boardConnectionDescription: String {
        if boardSubmissionUncertain { return "上次画布结果待核对" }
        if boardTransportPreference == .usb { return hasUSBBoardConnectionCandidate ? "USB 直接推送 · TF 保留在设备" : "连接 USB 后即可直接发送" }
        guard connection != nil else { return "连接 USB 一次，即可自动设置局域网" }
        switch boardRouting.lanState {
        case .ready:
            if let date = boardRouting.probeAt, (0...ReadPicoBoardRouting.readyFreshness).contains(boardNow().timeIntervalSince(date)) { return "局域网已验证 · USB 可作离线备用" }
            return "已保留配对 · 下次发送前验证局域网"
        case .offline: return "局域网离线 · 等待同设备 USB 备用连接"
        case .authenticationRequired: return "配对已过期 · 请重新连接"
        case .unavailable: return "局域网未通过验证 · 请重新连接"
        case .unknown: return "已保留配对 · 等待验证局域网"
        }
    }
    /// A non-secret content destination key; absent/ambiguous identity never permits cached-display reuse.
    var boardConnectionIdentity: String? {
        if !prefersUSBBoard, let connection {
            return "wifi:\(connection.baseURL.absoluteString)|session:\(deviceSessionID.uuidString)"
        }
        guard boardTransportPreference != .wifi else { return nil }
        let ports = discoverUSBPorts()
        let selected = selectedBoardUSBPort.flatMap { ports.contains($0) ? $0 : nil }
        let matching = ports.filter { ReadPicoBoardRouting.identityMatches(identifyUSBPort($0), trustedUSBIdentity) }
        let port = selected ?? (matching.count == 1 ? matching[0] : nil)
        guard let port, let identity = identifyUSBPort(port),
              ReadPicoBoardRouting.identityMatches(identity, trustedUSBIdentity) else { return nil }
        return "usb:\(identity)"
    }
    func acceptPowerStatus(_ status: ReadPicoPowerStatus?, receivedAt: Date = Date()) {
        guard let status, powerStatusReceivedAt == nil || receivedAt >= powerStatusReceivedAt! else { return }
        powerStatus = status; powerStatusReceivedAt = receivedAt
    }
    /// Current-session status only. No reconnect and no CDC access while the host owns TF storage.
    func refreshDevicePowerStatus() async {
        guard !busy, powerRefreshID == nil, boardReceiptTask == nil, store == nil, !waitingForUSBVolume else { return }
        let session = deviceSessionID, started = Date(), refreshID = UUID()
        let read: @Sendable () async throws -> ReadPicoPowerStatus?
        if let client, connection != nil { read = { try await client.capabilities().power } }
        else {
            guard store == nil, !waitingForUSBVolume, let identity = trustedUSBIdentity else { return }
            let matching = discoverUSBPorts().filter { ReadPicoBoardRouting.identityMatches(identifyUSBPort($0), identity) }
            guard matching.count == 1 else { return }
            let reader = readUSBPower, port = matching[0]
            read = { try await reader(port) }
        }
        let sample = Task { try await read() }
        powerRefreshID = refreshID; powerRefreshTask = sample
        defer {
            if powerRefreshID == refreshID { powerRefreshID = nil; powerRefreshTask = nil }
        }
        do {
            let status = try await withTaskCancellationHandler { try await sample.value } onCancel: { sample.cancel() }
            guard !Task.isCancelled, !sample.isCancelled, deviceSessionID == session, powerRefreshID == refreshID,
                  powerStatusReceivedAt == nil || powerStatusReceivedAt! <= started else { return }
            acceptPowerStatus(status)
        } catch {
            // A sampling failure expires naturally; it must not replace the user's transfer or editor message.
        }
    }
    /// Check the exact delivered frame without POST, USB export, or changing the active device page.
    /// 只读核对同一版本或任务；保存回执不能替代屏幕显示回执，也不能授权跨设备确认。
    func refreshBoardDelivery(_ receiptID: UUID) async throws -> BoardDelivery? {
        guard let receipt = boardDelivery, receipt.id == receiptID else { return nil }
        guard !receipt.displayed else { return receipt }
        guard !busy, powerRefreshID == nil, boardReceiptTask == nil, store == nil, !waitingForUSBVolume,
              let target = boardReceiptTarget else { return receipt }
        let session = deviceSessionID, owner = ownerGeneration
        let sample: Task<BoardReceiptSample?, Error>
        switch target {
        case .wireless(let expectedSession, let revision, let contentChannel):
            guard session == expectedSession, let client, connection != nil else { return nil }
            sample = Task {
                let current = try await client.capabilities()
                guard current.protocol == 1, current.canvas.supports(contentChannel),
                      let receipt = current.canvas.receipt(for: contentChannel), receipt.revision == revision else {
                    throw ReadPicoManagerError.unavailable("设备已有其他画板版本，原画面尚未确认显示。")
                }
                if receipt.state == "error" { throw ReadPicoManagerError.unavailable("设备未完成画板显示；Mac 原稿已保留。") }
                return .init(displayed: receipt.state == "displayed", power: current.power, canvas: current.canvas, revision: receipt.revision, orientation: receipt.orientation)
            }
        case .usb(let identity, let taskID, let contentChannel):
            let client = boardClient
            sample = Task {
                guard let current = try await client.receiptStatus(taskID: taskID, expectedIdentity: identity, contentChannel: contentChannel) else { return nil }
                if current.state == "error" { throw ReadPicoManagerError.unavailable("设备未完成画板显示；Mac 原稿已保留。") }
                return .init(displayed: current.state == "displayed", power: current.power, canvas: nil, revision: current.revision, orientation: current.orientation)
            }
        }
        let readID = UUID()
        boardReceiptTask = sample; boardReceiptReadID = readID
        defer { if boardReceiptReadID == readID { boardReceiptTask = nil; boardReceiptReadID = nil } }
        let value = try await withTaskCancellationHandler { try await sample.value } onCancel: { sample.cancel() }
        guard !Task.isCancelled, !sample.isCancelled, deviceSessionID == session, ownerGeneration == owner,
              boardDelivery?.id == receiptID, !busy, store == nil, !waitingForUSBVolume else { return nil }
        guard let value else { return receipt }
        acceptPowerStatus(value.power)
        if let canvas = value.canvas { capability = canvas }
        if value.displayed { boardDelivery = .init(id: receiptID, displayed: true, revision: value.revision ?? receipt.revision, orientation: value.orientation ?? receipt.orientation, contentChannel: receipt.contentChannel); boardReceiptTarget = nil }
        return boardDelivery
    }
    var canCancel: Bool { busy && operation?.cancellable == true && !cancelling }
    var cancelTitle: String { operation == .install ? "停止后续导入" : "取消等待" }
    var hasUnsavedHomeChanges: Bool {
        home != (confirmedHome ?? .init()) || !homeToken.isEmpty || !homeCfAccessClientId.isEmpty || !homeCfAccessClientSecret.isEmpty
    }
    /// Thin host / missing PGA module: HA form is read-only guidance only.
    /// 仅用于本机 UI 审计截图：模拟已连接的薄/完整 Home Link，不发起网络。
    func applyAuditHomeLinkSnapshot(thin: Bool) {
        homeLinkMode = thin ? .thin : .full
        homeModuleMissing = thin
        homePortal = nil
        deviceSettingsSupported = true
        if thin {
            report("已连接 Pico · 审计快照（薄宿主 / 需安装 apps/tools/home-link.pga）")
        } else {
            report("已连接 Pico · 审计快照（完整 Home Link）")
        }
    }

    /// Thin host / missing module: HA form read-only. `pga` writes into the PGA store and stays editable.
    var isHomeAssistantLocked: Bool {
        homeModuleMissing || homeLinkMode == .thin
    }
    /// Device LAN QR portal holds port 80 / store — Mac form is backup only; do not submit.
    var isHomePortalBlocking: Bool {
        homePortal?.active == true
    }
    var canSubmitHomeAssistant: Bool {
        !isHomeAssistantLocked && !isHomePortalBlocking
    }
    var hasUnsavedPowerChanges: Bool {
        guard deviceSettingsSupported else { return false }
        return !samePowerValues(deviceConfiguration, confirmedDeviceConfig ?? .init())
    }
    var hasUnsavedDeviceConfigurationChanges: Bool { hasUnsavedHomeChanges || hasUnsavedPowerChanges }
    var hasUnsavedDeviceChanges: Bool { hasUnsavedDeviceConfigurationChanges || pendingLockImage != nil }
    private func samePowerValues(_ lhs: ReadPicoDeviceConfiguration, _ rhs: ReadPicoDeviceConfiguration) -> Bool {
        lhs.autoSleepMinutes == rhs.autoSleepMinutes && lhs.doubleTapWake == rhs.doubleTapWake && lhs.lockStyle == rhs.lockStyle && lhs.coverLayout == rhs.coverLayout
    }
    func report(_ message: String, error: Bool = false) { self.message = message; isError = error }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }
    private func rejectCompletion(_ completion: ((Bool) -> Void)?) {
        guard let completion else { return }
        if busy { rejectedCompletions.append(completion) } else { completion(false) }
    }
    private func finishRejectedCompletions() {
        while !busy && !rejectedCompletions.isEmpty {
            let completion = rejectedCompletions.removeFirst()
            completion(false)
        }
    }
    @discardableResult private func perform(_ kind: Operation, completion: ((Bool) -> Void)? = nil,
                                           _ action: @escaping @MainActor (UUID) async throws -> String) -> Bool {
        guard !busy else { rejectCompletion(completion); return false }
        let pendingPowerRead = powerRefreshTask
        pendingPowerRead?.cancel()
        let pendingBoardRead = boardReceiptTask
        pendingBoardRead?.cancel()
        let id = UUID(); operationID = id; operation = kind; operationCompletion = completion
        busy = true; cancelling = false; report(kind.message)
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                // Let a cancelled read release its serial lease before a USB operation begins.
                _ = try? await pendingPowerRead?.value
                _ = try? await pendingBoardRead?.value
                try check(id)
                let result = try await action(id)
                try check(id)
                report(result); succeeded = true
            } catch {
                guard operationID == id else { return }
                if Task.isCancelled || error is CancellationError {
                    report(kind.cancelMessage)
                    if kind == .wireless { setWireless(.idle, kind.cancelMessage) }
                } else {
                    report(error.localizedDescription, error: true)
                    if kind == .wireless { setWireless(.failed, error.localizedDescription, error: true) }
                }
            }
            guard operationID == id else { return }
            let completion = operationCompletion; operationCompletion = nil
            busy = false; cancelling = false; operation = nil; operationID = nil; operationTask = nil
            completion?(succeeded)
            finishRejectedCompletions()
        }
        return true
    }
    func cancelOperation() {
        guard canCancel else { return }
        cancelling = true; report("正在停止等待，已完成的内容会保留…"); operationTask?.cancel()
    }
    private func clearConnection() {
        if usesWirelessContent { files = [] }
        deviceSessionID = UUID(); powerRefreshTask?.cancel(); powerRefreshTask = nil; powerRefreshID = nil; powerStatus = nil; powerStatusReceivedAt = nil
        boardReceiptTask?.cancel(); boardReceiptTask = nil; boardReceiptReadID = nil; boardReceiptTarget = nil; boardDelivery = nil
        connection = nil; client = nil; capability = nil; contentCapability = nil; imageLock = nil; lockImagePreview = nil; pendingLockImage = nil; deviceSettingsSupported = false
        deviceConfiguration = .init(); home = .init(); homeToken = ""; homeCfAccessClientId = ""; homeCfAccessClientSecret = ""; wifi = []
        confirmedHome = nil; confirmedDeviceConfig = nil
        homeLinkMode = nil; homeModuleMissing = false; homePortal = nil
        wirelessUSBIdentity = nil; wirelessNeedsRenewal = false; wirelessRenewalRetryAfter = nil; boardRouting.reset()
        wirelessProvisioningPort = nil; wirelessProvisioningIdentity = nil; wirelessNetworks = []
        setWireless(.idle, "用 USB 连接一次，即可自动连接 Pico 或为设备配置 Wi-Fi。")
    }
    private func permitsConnectionChange(discardChanges: Bool) -> Bool {
        guard !busy else { return false }
        guard discardChanges || !hasUnsavedDeviceConfigurationChanges else {
            report("有未保存的设备设置，请先保存或明确放弃修改。", error: true)
            return false
        }
        return true
    }
    @discardableResult func connectionInputChanged(discardChanges: Bool = false) -> Bool {
        guard permitsConnectionChange(discardChanges: discardChanges) else { return false }
        guard connection != nil || hasUnsavedDeviceChanges else { return true }
        clearConnection(); report("连接信息已修改，请重新连接后配置设备。")
        return true
    }
    @discardableResult func discardPendingDeviceChanges() -> Bool {
        guard !busy else { return false }
        home = confirmedHome ?? .init(); homeToken = ""; homeCfAccessClientId = ""; homeCfAccessClientSecret = ""
        deviceConfiguration = confirmedDeviceConfig ?? .init()
        pendingLockImage = nil
        report("已放弃未保存的设备设置。")
        return true
    }
    func deactivate() {
        ownerGeneration = UUID()
        let completion = operationCompletion; operationCompletion = nil
        operationID = nil; operationTask?.cancel(); operationTask = nil
        busy = false; cancelling = false; operation = nil; clearConnection()
        // 中文：不确定的回执属于已离开的设备会话，不阻止下一个设备所有者发送。
        // English: An uncertain receipt belongs to the departed owner, never the next device session.
        boardRouting = .init(); boardSubmissionUncertain = false
        store = nil; files = []; waitingForUSBVolume = false; usbWaitStarted = nil
        trustedUSBIdentity = nil; selectedBoardUSBPort = nil; automaticAttempts = [:]; preferredVolumeIdentity = nil; preferredVolumeCapacity = nil
        automaticUSBPreparationSuppressed = false; usbBoardNeedsSelection = false
        wirelessProvisioningPort = nil; wirelessProvisioningIdentity = nil; wirelessNetworks = []
        setWireless(.idle, "用 USB 连接一次，即可自动连接 Pico 或为设备配置 Wi-Fi。")
        completion?(false)
        finishRejectedCompletions()
    }
    func selectCard(_ url: URL) {
        perform(.reload) { id in
            let store = try ReadPicoTFStore(rootURL: url), items = try await store.scan()
            try self.check(id)
            self.store = store; self.files = items
            if let volume = self.mountedVolumes.first(where: { $0.rootURL == store.rootURL }) {
                self.preferredVolumeIdentity = volume.identity; self.preferredVolumeCapacity = volume.capacity
            }
            self.waitingForUSBVolume = false; self.usbWaitStarted = nil; self.cardError = false; self.usbBoardNeedsSelection = false
            self.cardMessage = "已连接 \(url.lastPathComponent)。管理完成后点击“安全弹出”；设备会检查卡片并恢复阅读。"
            return "已读取 \(url.lastPathComponent)：\(items.filter { $0.kind == .book }.count) 本图书、\(items.filter { $0.kind == .application }.count) 个应用。"
        }
    }
    /// Bounded app data sync shares the same cancellable TF operation owner as books/apps.
    /// 有界应用资料同步沿用图书与应用的可取消 TF 操作所有权。
    func syncWeRead(_ snapshot: ReadPicoWeReadSnapshot) {
        guard let store else {
            report("请先通过 USB 连接 TF 文件管理，再同步微信读书离线笔记。", error: true)
            return
        }
        guard files.contains(where: { $0.relativePath == "apps/tools/weread.pga" && $0.valid }) else {
            report("请先添加微信读书功能包，再同步离线笔记。", error: true)
            return
        }
        perform(.install) { id in
            try self.check(id); try await store.verifyAvailable(writing: true)
            guard self.store === store else { throw CancellationError() }
            let exporter = try ReadPicoWeReadTFExporter(rootURL: store.rootURL)
            let result = try await exporter.write(snapshot, progress: { done, total, phase in
                Task { @MainActor in
                    guard self.operationID == id else { return }
                    self.report(phase == "committing" ? "正在提交离线书架…" : "正在同步微信读书 \(done) / \(total) 字节…")
                }
            })
            try self.check(id); try await store.verifyAvailable()
            guard self.store === store else { throw CancellationError() }
            self.files = try await store.scan()
            return "已同步 \(result.bookCount) 本书、\(result.noteCount) 条划线与想法。安全弹出后，在设备应用集中打开微信读书。"
        }
    }
    /// Observe mounts only. Never open a serial port while MSC owns the device.
    func refreshCardAvailability(now: Date = Date()) async {
        let volumes = discoverVolumes(), ports = discoverUSBPorts()
        if mountedVolumes != volumes { mountedVolumes = volumes }
        if usbPorts != ports {
            let removed = Set(usbPorts).subtracting(ports)
            for port in removed { automaticAttempts.removeValue(forKey: port) }
            usbPorts = ports
        }
        guard !busy else { return }
        if let store {
            do { try await store.verifyAvailable() }
            catch {
                guard !busy, self.store === store else { return }
                self.store = nil; files = []; cardError = true
                // A host eject or detached volume ends this file-management intent.
                // CDC returning is the expected MSC handoff, not a new request to export TF.
                automaticUSBPreparationSuppressed = true
                cardMessage = error.localizedDescription
                report(cardMessage, error: true)
            }
        } else if transportPreference != .wifi, (connection == nil || transportPreference == .usb), !automaticUSBPreparationSuppressed, let preferredVolumeIdentity,
                  let match = volumes.first(where: { $0.identity == preferredVolumeIdentity && $0.capacity == preferredVolumeCapacity }) {
            // Restore only a volume the user already chose in this device session.
            selectCard(match.rootURL)
        } else if waitingForUSBVolume {
            if let volume = linkedUSBBoardVolume(volumes) {
                selectCard(volume.rootURL)
            } else if !volumes.isEmpty {
                cardMessage = "Mac 已挂载 \(volumes.count) 个外部磁盘，请核对名称和容量，选择阅读器的 TF 磁盘。"
                cardError = false
            } else if let start = usbWaitStarted, now.timeIntervalSince(start) >= 30 {
                cardMessage = ports.isEmpty
                    ? "设备已接受 USB 请求，但 Mac 尚未挂载 TF 磁盘。设备显示“电脑已连接”不代表磁盘已挂载；请保持连接，点“重新检测”，或在设备安全结束后重新开启。"
                    : "设备串口已重新出现，但 Mac 尚未挂载 TF 磁盘。设备可能已返回普通模式，可停止等待后重新开启；如果设备仍在传输页，请先安全结束。"
                cardError = true
            }
        }
    }
    func startUSB(port: String) {
        guard store == nil, permitsConnectionChange(discardChanges: false) else { return }
        let identity = identifyUSBPort(port)
        automaticAttempts[port] = identity ?? "unidentified"
        perform(.usbStart) { id in
            let result = try await self.usbClient.start(port: port) { @MainActor in
                guard self.operationID == id else { return }
                // USB handoff deliberately stops Wi-Fi and its temporary management session.
                self.clearConnection(); self.waitingForUSBVolume = true; self.usbWaitStarted = Date()
                if identity == nil || self.trustedUSBIdentity != identity {
                    self.preferredVolumeIdentity = nil; self.preferredVolumeCapacity = nil
                }
                self.trustedUSBIdentity = identity
                // Consume the automatic request once the reader accepts it. MSC removes
                // CDC and safe eject restores it, possibly at a different serial path.
                // Only an explicit connection or a new file-page intent may export again.
                self.automaticUSBPreparationSuppressed = true
                self.cardError = false; self.cardMessage = "设备已接受请求，正在等待 Mac 挂载 TF 磁盘；USB 将重新连接一次。"
            }
            try self.check(id)
            self.acceptPowerStatus(result.power)
            if result.backgroundSupported {
                self.cardMessage = "已在设备后台开启 USB，当前画面保留。正在等待 Mac 挂载 TF 磁盘；安全弹出后自动恢复本机读卡。"
            }
            return self.cardMessage
        }
    }
    var canEjectCard: Bool {
        guard let root = store?.rootURL else { return false }
        return mountedVolumes.contains { $0.rootURL.standardizedFileURL == root.standardizedFileURL }
    }
    func ejectCard() {
        guard let store, canEjectCard else { return }
        let root = store.rootURL
        perform(.eject) { id in
            try await store.verifyAvailable(); try self.check(id)
            do { try await self.ejectVolume(root) }
            catch { throw ReadPicoManagerError.unavailable("TF 磁盘未能安全弹出，仍保持连接。请关闭正在访问此磁盘的文件或窗口后重试。" + error.localizedDescription) }
            try self.check(id)
            self.store = nil; self.files = []; self.waitingForUSBVolume = false; self.usbWaitStarted = nil
            self.automaticUSBPreparationSuppressed = true
            self.mountedVolumes.removeAll { $0.rootURL == root }; self.cardError = false
            self.cardMessage = "Mac 已安全弹出。阅读器会自动接回 TF 卡并恢复阅读；若仍停在传输页，请点击设备上的“安全结束 USB 传输”。"
            return self.cardMessage
        }
    }
    func forgetCard() {
        guard !busy else { return }
        store = nil; files = []; cardError = false
        cardMessage = "已取消选择目录。重新选择 TF 磁盘后继续管理；此操作不会弹出磁盘。"
    }
    func stopWaitingForUSB() {
        guard !busy else { return }
        waitingForUSBVolume = false; usbWaitStarted = nil; cardError = false; automaticUSBPreparationSuppressed = true
        cardMessage = "已停止等待，未发送结束命令。设备若仍在 USB 传输，请先安全弹出磁盘并在设备结束传输，再重新开启。"
    }
    func resumeAutomaticUSBPreparation() {
        guard !busy else { return }
        automaticUSBPreparationSuppressed = false; automaticAttempts = [:]
    }
    func automaticUSBPreparationCandidate(selectedPort: String) -> String? {
        guard !busy, transportPreference != .wifi, (connection == nil || transportPreference == .usb), store == nil, !waitingForUSBVolume, !automaticUSBPreparationSuppressed else { return nil }
        let matching = usbPorts.filter { port in ReadPicoBoardRouting.identityMatches(trustedUSBIdentity, identifyUSBPort(port)) }
        let port = usbPorts.contains(selectedPort) ? selectedPort : matching.count == 1 ? matching[0] : usbPorts.count == 1 ? usbPorts[0] : nil
        guard let port else { return nil }
        let identity = identifyUSBPort(port) ?? "unidentified"
        guard automaticAttempts[port] != identity else { return nil }
        return port
    }
    func markAutomaticUSBPreparationAttempt(port: String) { automaticAttempts[port] = identifyUSBPort(port) ?? "unidentified" }
    func isTrustedUSBPort(_ port: String) -> Bool {
        guard let trustedUSBIdentity else { return false }
        return ReadPicoBoardRouting.identityMatches(identifyUSBPort(port), trustedUSBIdentity)
    }
    func reload() {
        guard let store = contentStore else { report("请先连接 Pico，可使用 Wi-Fi 配对或 USB 文件管理。", error: true); return }
        perform(.reload) { id in let items = try await store.scan(); try self.check(id); self.files = items; return "设备内容已刷新。" }
    }
    func install(_ urls: [URL], kind: ReadPicoFileKind, replace: Bool) {
        guard let store = contentStore else { report("请先连接 Pico，可使用 Wi-Fi 配对或 USB 文件管理。", error: true); return }
        perform(.install) { id in
            var installed = 0
            do { for url in urls { try self.check(id); try await store.importFile(url, kind: kind, replace: replace, progress: nil); installed += 1 } }
            catch {
                let items = try? await store.scan()
                if self.operationID == id { self.files = items ?? self.files }
                throw ReadPicoManagerError.unavailable("已导入 \(installed) 项。" + error.localizedDescription)
            }
            let items = try await store.scan(); try self.check(id); self.files = items
            return "已校验并导入 \(installed) 项。" + self.contentCompletionHint
        }
    }
    var librarySyncConnectionID: String { deviceSessionID.uuidString + "|" + (usesWirelessContent ? "wireless" : store?.rootURL.path ?? "disconnected") }
    func prepareLibrarySync(_ items: [ReadPicoLibraryItem], library: ReadPicoLocalLibrary,
                            completion: @escaping (ReadPicoLibrarySyncPlan?) -> Void) {
        guard let store = contentStore else { report("请先连接 Pico，再核对同步差异。", error: true); completion(nil); return }
        var plan: ReadPicoLibrarySyncPlan?
        perform(.reload, completion: { success in completion(success ? plan : nil) }) { id in
            plan = try await library.prepareSync(items, to: store)
            try self.check(id)
            return "已核对所选资料与 Pico 内容，尚未传输文件。"
        }
    }
    func synchronizeLibrary(_ items: [ReadPicoLibraryItem], library: ReadPicoLocalLibrary,
                            plan: ReadPicoLibrarySyncPlan? = nil, policy: ReadPicoLibrarySyncPolicy = .merge,
                            progress: @escaping @MainActor (ReadPicoLibraryProgress) -> Void,
                            completion: ((Bool) -> Void)? = nil) {
        guard let store = contentStore else { report("请先连接 Pico，可使用 Wi-Fi 配对或 USB 文件管理。", error: true); completion?(false); return }
        perform(.install, completion: completion) { [self] id in
            let counter = ReadPicoLibrarySyncCounter()
            do {
                let notify: @Sendable (ReadPicoLibraryProgress) -> Void = { [weak self] value in
                    counter.receive(value)
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        progress(value)
                    }
                }
                let results: [ReadPicoLibrarySyncResult]
                if let plan { results = try await library.sync(plan, to: store, policy: policy, progress: notify) }
                else { results = try await library.sync(items, to: store, replace: false, progress: notify) }
                try self.check(id)
                self.files = try await store.scan()
                let skipped = results.filter(\.alreadyPresent).count
                return "同步完成：成功 \(results.count - skipped) 项，跳过相同内容 \(skipped) 项，失败 0 项。" + self.contentCompletionHint
            } catch {
                if let refreshed = try? await store.scan(), self.operationID == id { self.files = refreshed }
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let counts = counter.counts
                throw ReadPicoManagerError.unavailable("同步未完成：成功 \(counts.completed) 项，跳过 \(counts.skipped) 项，失败 1 项；其余未传输。" + error.localizedDescription + " 已保存的资料与冲突原件保留，请重新核对差异后继续。")
            }
        }
    }
    func remove(_ file: ReadPicoCardFile) {
        guard let store = contentStore else { return }
        perform(.remove) { id in try self.check(id); try await store.remove(file); let items = try await store.scan(); try self.check(id); self.files = items; return "已移除“\(file.title)”，笔记、阅读进度和应用存档均保留。" }
    }
    func export(_ file: ReadPicoCardFile, to url: URL, format: String) {
        guard let store = contentStore else { return }
        perform(.export) { id in try self.check(id); try await store.export(file, to: url, format: format); return "已导出至 \(url.lastPathComponent)。" }
    }
    private func setWireless(_ phase: ReadPicoWirelessSetupPhase, _ text: String, error: Bool = false) {
        provisioningPhase = phase; wirelessStatus = text; wirelessError = error
    }
    private func wirelessPort(_ selected: String?) throws -> (String, String) {
        let ports = discoverUSBPorts(); usbPorts = ports
        let wanted = wirelessUSBIdentity ?? wirelessProvisioningIdentity
        let matching = ports.filter { port in
            guard let wanted, let actual = identifyUSBPort(port) else { return false }
            return ReadPicoUSBWirelessClient.normalizedIdentity(actual) == wanted
        }
        let port: String?
        if let selected, !selected.isEmpty { port = ports.contains(selected) ? selected : nil }
        else { port = matching.count == 1 ? matching[0] : wanted == nil && ports.count == 1 ? ports[0] : nil }
        guard let port, let raw = identifyUSBPort(port), let identity = ReadPicoUSBWirelessClient.normalizedIdentity(raw) else {
            throw ReadPicoManagerError.unavailable(ports.isEmpty
                ? "请用 USB 数据线连接 Pico 并点按电源唤醒，再点击自动连接。"
                : "请只连接要配置的 Pico，或在高级选项中选择对应 USB 设备。")
        }
        if let wanted, wanted != identity { throw ReadPicoUSBWirelessError.identityMismatch }
        return (port, identity)
    }
    private func verifyWirelessPort(_ port: String, identity: String) throws {
        guard discoverUSBPorts().contains(port), let actual = identifyUSBPort(port),
              ReadPicoUSBWirelessClient.normalizedIdentity(actual) == identity else { throw ReadPicoUSBWirelessError.identityMismatch }
    }
    private func recoveredWirelessPort(identity: String, id: UUID) async throws -> String {
        let end = Date().addingTimeInterval(8)
        repeat {
            try check(id)
            let ports = discoverUSBPorts().filter { port in
                guard let raw = identifyUSBPort(port) else { return false }
                return ReadPicoUSBWirelessClient.normalizedIdentity(raw) == identity
            }
            if ports.count == 1 { usbPorts = discoverUSBPorts(); return ports[0] }
            if ports.count > 1 { throw ReadPicoUSBWirelessError.identityMismatch }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < end
        throw ReadPicoUSBWirelessError.unavailable
    }
    /// Safely release the host filesystem before opening CDC. No label/path guessing and no forced unmount.
    private func releaseStorageForWireless(identity: String, id: UUID) async throws {
        try check(id)
        let volumes = discoverVolumes()
        let linked = volumes.filter { volume in
            guard let raw = volumeUSBIdentity(volume.rootURL) else { return false }
            return ReadPicoUSBWirelessClient.normalizedIdentity(raw) == identity
        }
        if let store, !linked.contains(where: { $0.rootURL.standardizedFileURL == store.rootURL.standardizedFileURL }) {
            throw ReadPicoManagerError.unavailable("当前选中的 TF 磁盘无法确认属于这台 Pico。请先安全弹出后再自动连接。")
        }
        guard linked.count <= 1 else { throw ReadPicoUSBWirelessError.busy }
        if let volume = linked.first {
            setWireless(.checking, "正在安全结束 USB 文件管理…")
            do { try await ejectVolume(volume.rootURL) }
            catch { throw ReadPicoManagerError.unavailable("TF 磁盘未能安全弹出，未开启无线配置。请关闭正在访问磁盘的文件后重试。") }
            try check(id)
            self.store = nil; if !usesWirelessContent { files = [] }
            waitingForUSBVolume = false; usbWaitStarted = nil; automaticUSBPreparationSuppressed = true
            mountedVolumes.removeAll { $0.rootURL.standardizedFileURL == volume.rootURL.standardizedFileURL }
            let end = Date().addingTimeInterval(8)
            repeat {
                try check(id)
                let remaining = discoverVolumes().contains { candidate in
                    guard let raw = volumeUSBIdentity(candidate.rootURL) else { return false }
                    return ReadPicoUSBWirelessClient.normalizedIdentity(raw) == identity
                }
                if !remaining { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            } while Date() < end
            throw ReadPicoUSBWirelessError.busy
        }
        guard !waitingForUSBVolume else { throw ReadPicoUSBWirelessError.busy }
    }
    private func pairWireless(_ management: ReadPicoUSBWirelessManagement, expectedIdentity: String, id: UUID) async throws -> String {
        try check(id)
        guard management.identity == expectedIdentity else { throw ReadPicoUSBWirelessError.identityMismatch }
        setWireless(.pairing, "Pico 已联网，正在验证局域网连接…")
        let result = try await pair(address: management.url.absoluteString, key: management.key, id: id, preserveDrafts: true)
        try check(id)
        wirelessUSBIdentity = expectedIdentity; trustedUSBIdentity = expectedIdentity
        wirelessNeedsRenewal = false; wirelessRenewalRetryAfter = nil
        return result
    }
    /// MSC deliberately revokes its temporary HTTP key. After our own safe handoff, wait for
    /// the saved STA connection to resume and obtain a new key from the same verified USB device.
    private func renewWirelessAfterStorage(identity: String, id: UUID) async throws -> Bool {
        setWireless(.checking, "正在恢复 Pico 的局域网连接…")
        let port = try await recoveredWirelessPort(identity: identity, id: id)
        let end = Date().addingTimeInterval(wirelessResumeWait)
        var observedOffline = false
        repeat {
            try verifyWirelessPort(port, identity: identity); try check(id)
            do {
                let status = try await wirelessClient.status(port: port, expectedIdentity: identity)
                try check(id)
                guard status.identity == identity else { throw ReadPicoUSBWirelessError.identityMismatch }
                observedOffline = status.ready && !status.busy && !status.connected
                if status.connected, status.ready, !status.busy {
                    let management = try await wirelessClient.open(port: port, expectedIdentity: identity)
                    _ = try await pairWireless(management, expectedIdentity: identity, id: id)
                    return true
                }
            } catch ReadPicoUSBWirelessError.busy { /* allow the completed MSC handoff to settle */ }
            catch ReadPicoUSBWirelessError.unavailable { /* bounded wait for the controller */ }
            catch ReadPicoUSBWirelessError.networkRequired { observedOffline = true }
            try await Task.sleep(nanoseconds: UInt64(max(0.001, min(0.5, end.timeIntervalSinceNow)) * 1_000_000_000))
        } while Date() < end
        if observedOffline {
            boardRouting.probeFailed(.offline, at: boardNow())
            wirelessRenewalRetryAfter = boardNow().addingTimeInterval(ReadPicoBoardRouting.offlineProbeInterval)
            setWireless(.failed, "Pico 当前未连接局域网，自动模式可使用同设备 USB 备用连接。", error: true)
            return false
        }
        throw ReadPicoManagerError.unavailable("Pico 尚未恢复局域网，请点击自动连接，选择网络后继续。")
    }
    @discardableResult func autoConnectWireless(port: String? = nil, discardChanges: Bool = false) -> Bool {
        guard !busy else { return false }
        // A healthy existing authenticated session is reused without changing settings drafts or taking USB.
        if let client, let connection, store == nil, !waitingForUSBVolume {
            return perform(.wireless) { id in
                self.setWireless(.checking, "正在确认局域网连接…")
                do {
                    let result = try await client.capabilities(); try self.check(id)
                    guard result.protocol == 1 else { throw ReadPicoUSBWirelessError.invalidResponse }
                    self.capability = result.canvas; self.acceptPowerStatus(result.power); self.boardRouting.probeSucceeded(at: self.boardNow())
                    self.setWireless(.connected, "已连接 Pico · " + (connection.baseURL.host ?? "局域网"))
                    return "已复用当前 Pico 管理连接，未保存的编辑继续保留。"
                } catch {
                    try self.check(id)
                    guard self.wirelessUSBIdentity != nil else { throw error }
                    return try await self.beginWireless(port: port, id: id)
                }
            }
        }
        guard discardChanges || !hasUnsavedDeviceConfigurationChanges || wirelessUSBIdentity != nil else {
            report("有未保存的设备设置，请先保存或明确放弃修改。", error: true); return false
        }
        return perform(.wireless) { id in try await self.beginWireless(port: port, id: id) }
    }
    private func beginWireless(port: String?, id: UUID) async throws -> String {
        setWireless(.checking, "正在识别 USB 连接的 Pico…")
        let (_, identity) = try wirelessPort(port)
        try await releaseStorageForWireless(identity: identity, id: id)
        let port = try await recoveredWirelessPort(identity: identity, id: id)
        try verifyWirelessPort(port, identity: identity); try check(id)
        let status = try await wirelessClient.status(port: port, expectedIdentity: identity); try check(id)
        guard status.identity == identity else { throw ReadPicoUSBWirelessError.identityMismatch }
        wirelessProvisioningPort = port; wirelessProvisioningIdentity = identity
        trustedUSBIdentity = identity
        if status.connected {
            try verifyWirelessPort(port, identity: identity)
            let management = try await wirelessClient.open(port: port, expectedIdentity: identity)
            return try await pairWireless(management, expectedIdentity: identity, id: id)
        }
        return try await scanWireless(port: port, identity: identity, id: id)
    }
    private func scanWireless(port: String, identity: String, id: UUID) async throws -> String {
        try verifyWirelessPort(port, identity: identity); try check(id)
        setWireless(.scanning, "正在让 Pico 扫描附近的 Wi-Fi…")
        let networks = try await wirelessClient.scan(port: port, expectedIdentity: identity); try check(id)
        wirelessNetworks = networks
        let text = networks.isEmpty ? "未发现 Wi-Fi，可重新扫描；Pico 支持 2.4 GHz 网络。" : "选择 Pico 附近的 Wi-Fi，输入密码即可连接。"
        setWireless(.selectNetwork, text)
        return text
    }
    @discardableResult func scanWirelessNetworks() -> Bool {
        guard !busy, wirelessProvisioningPort != nil, let identity = wirelessProvisioningIdentity else {
            if !busy { return autoConnectWireless() }; return false
        }
        return perform(.wireless) { id in
            try await self.releaseStorageForWireless(identity: identity, id: id)
            let port = try await self.recoveredWirelessPort(identity: identity, id: id)
            self.wirelessProvisioningPort = port
            return try await self.scanWireless(port: port, identity: identity, id: id)
        }
    }
    @discardableResult func joinWirelessNetwork(ssid: String, password: String) -> Bool {
        guard !busy, wirelessProvisioningPort != nil, let identity = wirelessProvisioningIdentity else { return false }
        if wirelessNetworks.contains(where: { $0.ssid == ssid && !$0.supported }) {
            setWireless(.selectNetwork, "此网络类型不受 Pico 支持，请选择其他 2.4 GHz Wi-Fi。", error: true); return false
        }
        return perform(.wireless) { id in
            try await self.releaseStorageForWireless(identity: identity, id: id)
            let port = try await self.recoveredWirelessPort(identity: identity, id: id)
            self.wirelessProvisioningPort = port
            try self.verifyWirelessPort(port, identity: identity); try self.check(id)
            self.setWireless(.connecting, "正在连接所选 Wi-Fi…")
            let management = try await self.wirelessClient.connect(port: port, expectedIdentity: identity, ssid: ssid, password: password)
            try self.check(id)
            return try await self.pairWireless(management, expectedIdentity: identity, id: id)
        }
    }
    @discardableResult func connect(address: String, key: String, discardChanges: Bool = false) -> Bool {
        guard permitsConnectionChange(discardChanges: discardChanges) else { return false }
        clearConnection()
        return perform(.connect) { id in
            try await self.pair(address: address, key: key, id: id, preserveDrafts: false)
        }
    }
    private func pair(address: String, key: String, id: UUID, preserveDrafts: Bool) async throws -> String {
        let connection = try ReadPicoConnection(address: address, setupKey: key), client = self.makeClient(connection)
        var capabilities: ReadPicoCapabilities?
        do { capabilities = try await client.capabilities() }
        catch {
            try self.check(id)
            // A missing extension is compatible with older HA/printer-only firmware.
            if case ReadPicoManagerError.http(404) = error {
                // legacy HA-only
            } else if Self.isManageConnectionFailure(error) {
                // Device QR portal occupies port 80 while open.
                throw ReadPicoManagerError.unavailable(Self.homePortalBusyHint)
            } else {
                throw error
            }
        }
        let reportedMode = capabilities?.homeLinkMode.flatMap { ReadPicoHomeLinkMode(rawValue: $0) }
        // Contract: when pico/status exists but omits home_link_mode ⇒ treat as thin.
        // pico/status 404 (legacy HA-only): infer after home() — do not lock a working home API.
        let statusPresent = capabilities != nil
        // Soft-degrade only thin/absent. `pga` home/printer routes write the PGA store (bambu still 503).
        let softThin = statusPresent && (reportedMode == nil || reportedMode == .thin)
        var snapshot: ReadPicoHomeSnapshot?
        var moduleMissing = false
        var portal = capabilities?.homePortal
        do {
            if reportedMode == .pga {
                // Prefer aggregate home-link; fall back to home. saved_wifi comes from home GET.
                do {
                    let doc = try await client.homeLink()
                    try self.check(id)
                    if let p = doc.portal { portal = p }
                    var wifi: [String] = []
                    do {
                        let homeSnap = try await client.home()
                        try self.check(id)
                        wifi = homeSnap.savedWifi
                        if let p = homeSnap.portal { portal = p }
                        snapshot = ReadPicoHomeSnapshot(config: doc.config, savedWifi: wifi, networkOnline: doc.networkOnline, portal: portal)
                    } catch {
                        try self.check(id)
                        // Port 80 may be contested mid-read; keep config/portal from aggregate.
                        snapshot = ReadPicoHomeSnapshot(config: doc.config, savedWifi: [], networkOnline: doc.networkOnline, portal: portal)
                    }
                } catch ReadPicoManagerError.http(404) {
                    snapshot = try await client.home()
                    try self.check(id)
                    if let p = snapshot?.portal { portal = p }
                }
            } else {
                snapshot = try await client.home()
                try self.check(id)
                if let p = snapshot?.portal { portal = p }
            }
        } catch ReadPicoManagerError.homeModuleMissing {
            try self.check(id)
            moduleMissing = true
        } catch {
            try self.check(id)
            if softThin || reportedMode == .thin {
                // Thin hosts: soft-degrade so power/canvas/TF still connect.
                moduleMissing = true
            } else if Self.isManageConnectionFailure(error) {
                // QR portal occupies port 80 while open — soft hint, keep drafts.
                throw ReadPicoManagerError.unavailable(Self.homePortalBusyHint)
            } else {
                throw error
            }
        }
        let resolvedMode: ReadPicoHomeLinkMode
        if let reportedMode {
            resolvedMode = reportedMode
        } else if statusPresent {
            resolvedMode = .thin
        } else {
            resolvedMode = moduleMissing ? .thin : .full
        }
        var remoteFiles: [ReadPicoCardFile]?, contentWarning = ""
        if capabilities?.protocol == 1, capabilities?.content?.isUsable == true, self.transportPreference != .usb {
            do { remoteFiles = try await client.scan() }
            catch {
                try self.check(id)
                if case ReadPicoManagerError.expired = error { throw error }
                contentWarning = " 内容列表暂未读取：" + error.localizedDescription
            }
        }
        try self.check(id)
        let preserveHome = preserveDrafts && self.hasUnsavedHomeChanges
        let preservePower = preserveDrafts && self.hasUnsavedPowerChanges
        let homeConfig = snapshot?.config ?? ReadPicoHomeConfiguration()
        let savedWifi = snapshot?.savedWifi ?? []
        self.deviceSessionID = UUID(); self.connection = connection; self.client = client; self.wifi = savedWifi
        self.homeLinkMode = resolvedMode
        self.homeModuleMissing = moduleMissing
        self.homePortal = portal ?? snapshot?.portal
        if !preserveHome {
            self.home = homeConfig; self.homeToken = ""; self.homeCfAccessClientId = ""; self.homeCfAccessClientSecret = ""
        }
        self.confirmedHome = homeConfig
        if let capabilities, capabilities.protocol == 1 {
            self.capability = capabilities.canvas; self.acceptPowerStatus(capabilities.power)
            self.contentCapability = capabilities.content
            if let remoteFiles { self.files = remoteFiles }
            self.imageLock = capabilities.imageLock
            if let config = capabilities.config {
                if !preservePower { self.deviceConfiguration = config }
                self.confirmedDeviceConfig = config; self.deviceSettingsSupported = true
            }
        }
        self.boardRouting.probeSucceeded(at: self.boardNow())
        self.setWireless(.connected, "已连接 Pico · " + (connection.baseURL.host ?? "局域网"))
        let homeNote: String
        if moduleMissing {
            homeNote = " Home Link 模块未就绪（需安装 apps/tools/home-link.pga）；电源与画板仍可用。"
        } else if resolvedMode == .pga {
            homeNote = " PGA 家庭存储已就绪；本机表单为备用写入，设备扫码填写优先。"
        } else if self.homePortal?.active == true {
            homeNote = " 设备端家庭设置二维码门户进行中，本机暂勿保存。"
        } else {
            homeNote = ""
        }
        return "已验证设备管理连接，可在应用、资料库和灵犀画板间复用。配对码仅保留在本次会话中。" + homeNote + contentWarning
    }
    @discardableResult func disconnect(discardChanges: Bool = false) -> Bool {
        guard permitsConnectionChange(discardChanges: discardChanges) else { return false }
        clearConnection(); report("已断开本次管理连接。")
        return true
    }
    private func confirmHomeSave(_ client: any ReadPicoManagerDeviceClient, config: ReadPicoHomeConfiguration,
                                 token: String, cfAccessClientId: String, cfAccessClientSecret: String, id: UUID) async throws {
        try self.check(id)
        do {
            try await client.saveHome(config, token: token, cfAccessClientId: cfAccessClientId, cfAccessClientSecret: cfAccessClientSecret)
        } catch ReadPicoManagerError.homeModuleMissing {
            try self.check(id)
            self.homeModuleMissing = true
            throw ReadPicoManagerError.unavailable("Home Link 模块未安装，设置未保存。需安装 apps/tools/home-link.pga。")
        } catch ReadPicoManagerError.homePortalActive {
            try self.check(id)
            self.homePortal = ReadPicoHomePortal(active: true, phase: "open", writer: "device")
            throw ReadPicoManagerError.homePortalActive
        } catch {
            try self.check(id)
            if Self.isManageConnectionFailure(error) {
                throw ReadPicoManagerError.unavailable(Self.homePortalBusyHint)
            }
            throw error
        }
        try self.check(id)
        let snapshot: ReadPicoHomeSnapshot
        do { snapshot = try await client.home() }
        catch ReadPicoManagerError.homeModuleMissing {
            try self.check(id)
            self.homeModuleMissing = true
            throw ReadPicoManagerError.unavailable("Home Link 模块未安装，设置未保存。需安装 apps/tools/home-link.pga。")
        } catch {
            try self.check(id)
            if Self.isManageConnectionFailure(error) {
                throw ReadPicoManagerError.unavailable("设置可能已提交，但管理口暂不可达（若设备正在显示家庭设置二维码，请关闭或等待后再核对）。" + error.localizedDescription)
            }
            throw ReadPicoManagerError.unavailable("设置请求已提交，但尚未确认回读。输入内容已保留，请重新连接后核对。" + error.localizedDescription)
        }
        try self.check(id)
        if let portal = snapshot.portal { self.homePortal = portal }
        var expected = config
        expected.hasToken = config.hasToken || !token.isEmpty
        expected.hasCfAccessClientId = config.hasCfAccessClientId || !cfAccessClientId.isEmpty
        expected.hasCfAccessClientSecret = config.hasCfAccessClientSecret || !cfAccessClientSecret.isEmpty
        guard snapshot.config == expected else {
            throw ReadPicoManagerError.unavailable("设置请求已提交，但设备回读与本次设置不一致。输入内容已保留，请重新读取或重试。")
        }
        confirmedHome = snapshot.config; wifi = snapshot.savedWifi
        // A newer draft must survive even if it was supplied programmatically while the UI was busy.
        if home == config { home = snapshot.config } else {
            home.hasToken = snapshot.config.hasToken
            home.hasCfAccessClientId = snapshot.config.hasCfAccessClientId
            home.hasCfAccessClientSecret = snapshot.config.hasCfAccessClientSecret
        }
        if homeToken == token { homeToken = "" }
        if homeCfAccessClientId == cfAccessClientId { homeCfAccessClientId = "" }
        if homeCfAccessClientSecret == cfAccessClientSecret { homeCfAccessClientSecret = "" }
    }

    static let homePortalBusyHint = "无法连接管理服务。若阅读器正在显示家庭设置二维码，请先关闭二维码或等待约 10 分钟门户结束后再连接。"
    static func isManageConnectionFailure(_ error: Error) -> Bool {
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default: break
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return true
        default: return false
        }
    }
    private func confirmPowerSave(_ client: any ReadPicoManagerDeviceClient,
                                  config: ReadPicoDeviceConfiguration, id: UUID) async throws {
        try self.check(id)
        let previous = confirmedDeviceConfig
        let result = try await client.saveDeviceConfiguration(config)
        try self.check(id)
        acceptPowerStatus(result.power)
        guard result.protocol == 1, let confirmed = result.config, confirmed.state == 2,
              samePowerValues(confirmed, config), previous == nil || confirmed.revision != previous?.revision else {
            throw ReadPicoManagerError.unavailable("设置请求已提交，但尚未确认电源设置已保存。输入内容已保留，请重新读取或重试。")
        }
        confirmedDeviceConfig = confirmed
        if samePowerValues(deviceConfiguration, config) { deviceConfiguration = confirmed }
    }
    func saveHome() {
        guard let client else { return }
        guard !isHomeAssistantLocked else {
            report("需安装 apps/tools/home-link.pga", error: true)
            return
        }
        guard !isHomePortalBlocking else {
            report("设备端正在扫码填写家庭设置。请先在阅读器关闭二维码，或等待约 10 分钟门户结束后，再在本机保存。", error: true)
            return
        }
        let config = home, token = homeToken, cfId = homeCfAccessClientId, cfSecret = homeCfAccessClientSecret
        perform(.home) { id in
            try await self.confirmHomeSave(client, config: config, token: token, cfAccessClientId: cfId, cfAccessClientSecret: cfSecret, id: id)
            return L10n.t(PicoKeys.HomeLink.savedToast) + "；服务器是否在线请在详细设置中查看。"
        }
    }
    func saveDeviceSettings() {
        guard let client else { return }; let config = deviceConfiguration
        perform(.power) { id in
            try await self.confirmPowerSave(client, config: config, id: id)
            return "设备已确认保存电源与锁屏设置；锁屏样式将在下次锁屏时显示。"
        }
    }
    func savePendingDeviceChanges(includeLockImage: Bool = true, completion: @escaping (Bool) -> Void) {
        guard !busy else { rejectCompletion(completion); return }
        guard hasUnsavedDeviceConfigurationChanges || (includeLockImage && pendingLockImage != nil) else { completion(true); return }
        guard let client else {
            report("尚未连接设备，未保存的输入已保留。", error: true); completion(false); return
        }
        let saveHome = hasUnsavedHomeChanges && canSubmitHomeAssistant, savePower = hasUnsavedPowerChanges
        let home = self.home, token = homeToken, cfId = homeCfAccessClientId, cfSecret = homeCfAccessClientSecret, power = deviceConfiguration
        let lockImage = includeLockImage ? pendingLockImage : nil
        perform(.settings, completion: completion) { id in
            if saveHome { try await self.confirmHomeSave(client, config: home, token: token, cfAccessClientId: cfId, cfAccessClientSecret: cfSecret, id: id) }
            if let lockImage { try await self.confirmLockImageSave(client, bmp: lockImage, id: id) }
            if savePower { try await self.confirmPowerSave(client, config: power, id: id) }
            try self.check(id)
            guard !self.hasUnsavedDeviceConfigurationChanges, !includeLockImage || self.pendingLockImage == nil else {
                throw ReadPicoManagerError.unavailable("本次设置已确认，但还有新的未保存修改，请先核对后再离开。")
            }
            return "所有设备设置已由阅读器确认保存。"
        }
    }
    private func availableBoardUSBIdentity() -> String? {
        let ports = discoverUSBPorts()
        if let selectedBoardUSBPort, ports.contains(selectedBoardUSBPort) { return identifyUSBPort(selectedBoardUSBPort) }
        if ports.count == 1 { return identifyUSBPort(ports[0]) }
        if let trustedUSBIdentity, ports.contains(where: { ReadPicoBoardRouting.identityMatches(identifyUSBPort($0), trustedUSBIdentity) }) { return trustedUSBIdentity }
        return nil
    }
    private func directBoardPort(expectedIdentity: String? = nil) throws -> String {
        let ports = discoverUSBPorts()
        if usbPorts != ports { usbPorts = ports }
        if let selectedBoardUSBPort, ports.contains(selectedBoardUSBPort),
           expectedIdentity == nil || ReadPicoBoardRouting.identityMatches(expectedIdentity, identifyUSBPort(selectedBoardUSBPort)) { return selectedBoardUSBPort }
        if let expectedIdentity {
            let matching = ports.filter { ReadPicoBoardRouting.identityMatches(expectedIdentity, identifyUSBPort($0)) }
            if matching.count == 1 { return matching[0] }
        } else if ports.count == 1 { return ports[0] }
        usbBoardNeedsSelection = !ports.isEmpty
        throw ReadPicoManagerError.unavailable(ports.isEmpty
            ? "尚未检测到设备的 USB 端口。若正在管理 TF 卡，请先安全结束文件传输。"
            : "检测到多个 USB 设备，请在连接选项中选择本次发送的设备。")
    }
    /// 中文：用户明确选择当前端口后重新核对能力；替换同类设备无需沿用历史MAC。
    /// English: An explicit port selection revalidates capabilities; replacement devices do not inherit a historical MAC binding.
    func selectUSBBoard(port: String) {
        guard !busy else { return }
        perform(.connect) { id in
            _ = try await self.boardClient.verifyDirect(port: port); try self.check(id)
            self.selectedBoardUSBPort = port; self.trustedUSBIdentity = self.identifyUSBPort(port)
            self.usbBoardNeedsSelection = false; self.boardRouting.reset()
            self.boardSubmissionUncertain = false; self.boardDelivery = nil; self.boardReceiptTarget = nil
            return "USB 直接推送已就绪，TF 卡仍由阅读器使用。"
        }
    }
    private func sendBoardUSB(_ bmp: Data, id: UUID, display: Bool, contentChannel: ReadPicoContentChannel) async throws -> String {
        // Explicit USB selection may target a replacement reader; automatic LAN fallback keeps the paired destination.
        // 中文：显式USB选择可换机，自动局域网回退仍限定为已配对的目标。
        let fallbackIdentity = boardTransportPreference == .automatic && connection != nil ? wirelessUSBIdentity : nil
        if let store {
            let mountedIdentity = self.volumeUSBIdentity(store.rootURL)
            if let fallbackIdentity, !ReadPicoBoardRouting.identityMatches(fallbackIdentity, mountedIdentity) {
                throw ReadPicoManagerError.unavailable("当前 TF 文件管理连接属于另一台设备，请先安全断开，再选择 USB 推送目标。")
            }
            report("正在结束文件管理，将 TF 卡交还阅读器…")
            try await self.ejectVolume(store.rootURL); try check(id)
            self.store = nil; self.files = []; self.waitingForUSBVolume = false; self.usbWaitStarted = nil
            let end = Date().addingTimeInterval(18)
            while Date() < end {
                try check(id)
                if self.discoverUSBPorts().contains(where: { mountedIdentity == nil || ReadPicoBoardRouting.identityMatches(mountedIdentity, self.identifyUSBPort($0)) }) { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let port = try directBoardPort(expectedIdentity: fallbackIdentity)
        let identity = identifyUSBPort(port)
        let directCapability = try await boardClient.verifyDirect(port: port); try check(id)
        if ReadPicoCanvasPair.isPair(bmp), !directCapability.supportsDualOrientation {
            throw ReadPicoManagerError.unavailable("请更新设备固件，以支持一次接收竖屏和横屏画面。")
        }
        guard directCapability.supports(contentChannel) else { throw ReadPicoManagerError.unavailable("请更新设备固件，以支持 Cloudflare 独立应用。") }
        trustedUSBIdentity = identity; selectedBoardUSBPort = port
        boardRouting.submissionStarted(); boardSubmissionUncertain = true
        do {
            let receipt = try await boardClient.pushDirect(bmp, port: port, expectedIdentity: identity, display: display, contentChannel: contentChannel) { value in
                await MainActor.run {
                    guard self.operationID == id else { return }
                    self.usbBoardProgress = value; self.report(value.text)
                }
            }
            try check(id)
            boardRouting.submissionReconciled(); boardSubmissionUncertain = false
            boardDelivery = .init(id: UUID(), displayed: receipt.state == "displayed", revision: receipt.revision, orientation: receipt.orientation, contentChannel: contentChannel)
            if receipt.state == "saved", let identity = receipt.deviceIdentity { boardReceiptTarget = .usb(identity: identity, taskID: receipt.taskID, contentChannel: contentChannel) }
            acceptPowerStatus(receipt.power); usbBoardProgress = nil; usbBoardNeedsSelection = false
            return receipt.state == "displayed" ? "已通过 USB 直接发送，设备已确认显示。" : "已通过 USB 直接保存，Pico 保留当前页面。"
        } catch { if operationID == id { usbBoardProgress = nil }; throw error }
    }
    /// Board routing is independent of the user's file-management transport selection.
    /// Only an authenticated read failure may authorize an automatic USB fallback, before any POST.
    func sendBoard(_ bmp: Data, display: Bool = false, contentChannel: ReadPicoContentChannel = .canvas, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { rejectCompletion(completion); return }
        if ReadPicoCanvasPair.isPair(bmp) {
            do { try ReadPicoCanvasPair.validate(bmp) }
            catch { report(error.localizedDescription, error: true); rejectCompletion(completion); return }
        }
        guard contentChannel == .canvas || ReadPicoCanvasPair.isPair(bmp) else {
            report("应用内容必须同时提供横竖两种布局。", error: true); rejectCompletion(completion); return
        }
        guard !boardSubmissionUncertain else {
            report("上次画布尚未确认显示，请先在 Pico 核对结果；核对后再继续发送。", error: true)
            rejectCompletion(completion); return
        }
        usbBoardProgress = nil; usbBoardNeedsSelection = false; boardDelivery = nil; boardReceiptTarget = nil
        perform(.canvas, completion: completion) { id in
            // One explicit first-time USB send may select the sole attached reader. Subsequent
            // LAN fallbacks still require the identity verified when that LAN session was paired.
            let available = self.availableBoardUSBIdentity()
            if (self.connection == nil || self.boardTransportPreference == .usb), let available {
                self.trustedUSBIdentity = available
            }
            if self.boardTransportPreference == .usb || (self.connection == nil && self.discoverUSBPorts().count == 1) {
                return try await self.sendBoardUSB(bmp, id: id, display: display, contentChannel: contentChannel)
            }
            if self.boardTransportPreference != .usb, self.connection != nil, self.store != nil || self.waitingForUSBVolume {
                guard let identity = self.wirelessUSBIdentity,
                      ReadPicoBoardRouting.identityMatches(identity, available) else { throw ReadPicoUSBWirelessError.identityMismatch }
                try await self.releaseStorageForWireless(identity: identity, id: id)
                self.wirelessNeedsRenewal = true
            }
            if self.boardTransportPreference != .usb, self.connection != nil, self.wirelessNeedsRenewal,
               self.wirelessRenewalRetryAfter == nil || self.boardNow() >= self.wirelessRenewalRetryAfter! {
                guard let identity = self.wirelessUSBIdentity else { throw ReadPicoUSBWirelessError.identityMismatch }
                _ = try await self.renewWirelessAfterStorage(identity: identity, id: id)
            }
            var route = self.boardRouting.route(preference: self.boardTransportPreference,
                hasLANSession: self.connection != nil && self.client != nil,
                verifiedLANUSBIdentity: self.wirelessUSBIdentity, availableUSBIdentity: available,
                trustedUSBIdentity: self.trustedUSBIdentity, now: self.boardNow())
            if route == .probeLAN || route == .wireless {
                guard self.store == nil, !self.waitingForUSBVolume, let client = self.client else { throw ReadPicoUSBWirelessError.busy }
                do {
                    let result = try await client.capabilities(); try self.check(id)
                    guard result.protocol == 1, result.canvas.supportsNativeGray16 else { throw ReadPicoManagerError.unavailable("当前设备尚不支持原生 16 灰阶画板，请更新固件后重试。") }
                    self.capability = result.canvas; self.acceptPowerStatus(result.power); self.boardRouting.probeSucceeded(at: self.boardNow())
                } catch {
                    try self.check(id)
                    let failure = ReadPicoBoardLANFailure.preflight(error)
                    self.boardRouting.probeFailed(failure, at: self.boardNow())
                    if failure != .offline { throw error }
                }
                route = self.boardRouting.route(preference: self.boardTransportPreference,
                    hasLANSession: self.connection != nil && self.client != nil,
                    verifiedLANUSBIdentity: self.wirelessUSBIdentity, availableUSBIdentity: available,
                    trustedUSBIdentity: self.trustedUSBIdentity, now: self.boardNow())
            }
            switch route {
            case .usb:
                return try await self.sendBoardUSB(bmp, id: id, display: display, contentChannel: contentChannel)
            case .wireless:
                guard self.store == nil, !self.waitingForUSBVolume, let client = self.client, let capability = self.capability else { throw ReadPicoUSBWirelessError.busy }
                if ReadPicoCanvasPair.isPair(bmp) {
                    guard capability.supportsDualOrientation, bmp.count <= (capability.pairMaxBytes ?? 0) else {
                        throw ReadPicoManagerError.unavailable("请更新设备固件，以支持一次接收竖屏和横屏画面。")
                    }
                    try ReadPicoCanvasPair.validate(bmp)
                } else { try ReadPicoBitmap.validateCanvas(bmp, capability: capability) }
                guard capability.supports(contentChannel), let previousReceipt = capability.receipt(for: contentChannel), previousReceipt.revision != nil else {
                    throw ReadPicoManagerError.unavailable("请更新设备固件，以支持本次应用的独立显示确认。")
                }
                self.boardRouting.submissionStarted(); self.boardSubmissionUncertain = true
                let result: ReadPicoCapabilities
                var accepted = false
                do {
                    result = try await client.pushCanvasConfirmed(bmp, capability: capability, display: display, contentChannel: contentChannel) { @MainActor in
                        accepted = true
                        guard self.operationID == id, !self.cancelling else { return }
                        self.report("画布已提交，正在等待阅读器确认保存或显示…")
                    }
                } catch {
                    if !accepted, ReadPicoBoardLANFailure.preflight(error) == .authenticationRequired {
                        self.boardRouting.submissionReconciled(); self.boardSubmissionUncertain = false
                        self.boardRouting.probeFailed(.authenticationRequired, at: self.boardNow())
                    }
                    throw error
                }
                try self.check(id)
                guard result.protocol == 1, result.canvas.supports(contentChannel), let receipt = result.canvas.receipt(for: contentChannel),
                      receipt.state == "displayed" || receipt.state == "saved", let revision = receipt.revision,
                      revision != previousReceipt.revision else { throw ReadPicoManagerError.unavailable("画布已提交，但尚未确认显示。请先在 Pico 核对；不会自动改用 USB 重复发送。") }
                self.capability = result.canvas; self.acceptPowerStatus(result.power)
                let displayed = receipt.state == "displayed"
                if displayed { self.boardRouting.displayConfirmed() }
                else { self.boardRouting.submissionReconciled() }
                self.boardDelivery = .init(id: UUID(), displayed: displayed, revision: revision, orientation: receipt.orientation, contentChannel: contentChannel)
                self.boardReceiptTarget = displayed ? nil : .wireless(session: self.deviceSessionID, revision: revision, contentChannel: contentChannel)
                self.boardSubmissionUncertain = false; self.boardRouting.probeSucceeded(at: self.boardNow())
                return displayed ? "阅读器已通过局域网确认显示画布，并保存在 TF 卡内。" : "画布已通过局域网保存到 TF 卡，尚未显示；Pico 保留当前页面。"
            case .authenticationRequired:
                throw ReadPicoManagerError.expired
            case .submissionUncertain:
                throw ReadPicoManagerError.unavailable("上次提交结果未确认，请先在 Pico 核对后继续。")
            case .blocked:
                throw ReadPicoManagerError.unavailable("局域网连接未通过验证，请重新连接 Pico；不会自动改用 USB。")
            case .probeLAN, .needsConnection:
                if self.connection == nil, !self.discoverUSBPorts().isEmpty { self.usbBoardNeedsSelection = true }
                throw ReadPicoManagerError.unavailable(self.connection == nil ? "请连接 Pico 的 USB 数据线，或点击自动连接设置局域网。" : "局域网当前不可达，且未找到同一台 Pico 的 USB 备用连接。")
            }
        }
    }
    /// Called only after the user explicitly checks the reader's visible result.
    func reconcileBoardSubmission() {
        guard !busy else { return }
        boardRouting.submissionReconciled(); boardRouting.reset(); boardSubmissionUncertain = false
        report("已按你的核对解除等待，可继续发送画布。")
    }
    /// One intentional send owns preparation, file ownership and the matching device display receipt.
    /// 一次发送包含完整 USB 准备和显示确认，常规流程无需用户选择串口、磁盘或手动弹出。
    func sendUSBBoard(_ bmp: Data, completion: ((Bool) -> Void)? = nil) {
        guard permitsConnectionChange(discardChanges: false) else { rejectCompletion(completion); return }
        sendBoard(bmp, completion: completion)
    }
    func pushUSBBoard(_ bmp: Data, completion: ((Bool) -> Void)? = nil) {
        sendUSBBoard(bmp, completion: completion)
    }
    /// Called by the board connection indicator. One attempt per attached identity prevents retry loops.
    func prepareUSBBoardConnection() {
        guard !busy, boardTransportPreference != .wifi, store == nil, !waitingForUSBVolume,
              (connection == nil || boardTransportPreference == .usb), !hasUnsavedDeviceConfigurationChanges else { return }
        let ports = discoverUSBPorts()
        if usbPorts != ports { usbPorts = ports }
        let selected = selectedBoardUSBPort.flatMap { ports.contains($0) ? $0 : nil }
        let candidate = selected ?? (ports.count == 1 ? ports[0] : nil)
        guard let port = candidate else { if ports.count > 1 { usbBoardNeedsSelection = true }; return }
        let key = identifyUSBPort(port) ?? port
        guard automaticAttempts[port] != key else { return }
        automaticAttempts[port] = key
        selectUSBBoard(port: port)
    }
    /// CDC and MSC firmware expose the same hardware MAC with different colon/case formatting.
    /// Only these two complete ASCII MAC forms are equivalent; every other serial stays exact.
    nonisolated static func usbBoardVolumeIdentityMatches(_ volumeIdentity: String?, deviceIdentity: String) -> Bool {
        guard let volumeIdentity else { return false }
        if volumeIdentity == deviceIdentity { return true }
        func mac(_ value: String) -> [UInt8]? {
            let bytes = Array(value.utf8)
            guard bytes.count == 12 || bytes.count == 17 else { return nil }
            var digits: [UInt8] = []
            for (index, byte) in bytes.enumerated() {
                if bytes.count == 17 && index % 3 == 2 {
                    guard byte == 58 else { return nil }
                } else {
                    switch byte {
                    case 48...57, 65...70: digits.append(byte)
                    case 97...102: digits.append(byte - 32)
                    default: return nil
                    }
                }
            }
            return digits.count == 12 ? digits : nil
        }
        guard let volumeMAC = mac(volumeIdentity), let deviceMAC = mac(deviceIdentity) else { return false }
        return volumeMAC == deviceMAC
    }
    private func linkedUSBBoardVolume(_ volumes: [ReadPicoMountedVolume]) -> ReadPicoMountedVolume? {
        guard let identity = trustedUSBIdentity else { return nil }
        let linked = volumes.filter {
            !$0.readOnly && $0.identity != nil && Self.usbBoardVolumeIdentityMatches(volumeUSBIdentity($0.rootURL), deviceIdentity: identity)
        }
        if let preferredVolumeIdentity, let match = linked.first(where: {
            $0.identity == preferredVolumeIdentity && $0.capacity == preferredVolumeCapacity
        }) { return match }
        return linked.count == 1 ? linked[0] : nil
    }
    func push(_ bmp: Data, completion: ((Bool) -> Void)? = nil) {
        sendBoard(bmp, completion: completion)
    }

    func uploadLockImage(_ bmp: Data) {
        guard let client, imageLock?.supported == true else { report("请先在设备设置中配对支持图片锁屏的阅读器。", error: true); return }
        perform(.lockImage) { id in
            try await self.confirmLockImageSave(client, bmp: bmp, id: id)
            return "锁屏图片已保存到阅读器 TF 卡。选择「自定义图片」并保存样式后，下次锁屏显示。"
        }
    }

    private func confirmLockImageSave(_ client: any ReadPicoManagerDeviceClient, bmp: Data, id: UUID) async throws {
            guard let imageLock else { throw ReadPicoManagerError.unavailable("请先读取阅读器的图片锁屏能力。") }
            try ReadPicoBitmap.validateLock(bmp, capability: imageLock)
            let previousRevision = self.imageLock?.revision
            let result = try await client.saveLockImageConfirmed(bmp) { @MainActor in
                guard self.operationID == id, !self.cancelling else { return }
                self.report("图片已提交，正在等待阅读器确认保存到 TF 卡…")
            }
            try self.check(id)
            guard result.protocol == 1, let image = result.imageLock, image.supported, image.available,
                  image.state == "saved", previousRevision == nil || image.revision != previousRevision else {
                throw ReadPicoManagerError.unavailable("尚未确认锁屏图片保存完成。")
            }
            try ReadPicoBitmap.validateLock(bmp, capability: image)
            self.imageLock = image; self.lockImagePreview = bmp; self.acceptPowerStatus(result.power)
            if self.pendingLockImage == bmp { self.pendingLockImage = nil }
    }

    func readLockImage() {
        guard let client else { return }
        perform(.readLockImage) { id in
            let data = try await client.lockImage(); try self.check(id)
            guard let imageLock = self.imageLock else { throw ReadPicoManagerError.unavailable("尚未读取图片锁屏能力。") }
            try ReadPicoBitmap.validateLock(data, capability: imageLock)
            self.lockImagePreview = data
            return "已读取阅读器保存的锁屏图片。"
        }
    }
}

/// Content management shared by the normal device detail and diagnostic workspace.
struct ReadPicoManagerView: View {
    @Environment(\.controlCenterUsesFloatingSurface) private var usesFloatingSurface
    private let onBusyChange: ((Bool) -> Void)?
    private let onEndpointVerified: ((String) -> Void)?
    private let embedded: Bool
    private let externalSection: String?
    private let fileManagementVisible: Bool
    private let settingsHeader: AnyView?
    private let onAutomaticUSBPreparationChange: ((Bool) -> Void)?
    private let ownsDraftGuard: Bool
    @StateObject private var drafts: ReadPicoDraftGuard
    @StateObject private var model: ReadPicoManagerModel
    @StateObject private var library: ReadPicoLocalLibraryModel
    @State private var showDeviceContents = false
    @State private var libraryNeedsConnection = false
    @State private var tab = ReadPicoManagerTab.books
    @State private var address: String
    @State private var setupKey = ""
    @State private var pendingDelete: ReadPicoCardFile?
    @State private var showWeb = false
    @State private var search = ""
    @State private var replaceExisting = false
    @State private var selectedUSBPort = ""
    @State private var automaticUSBPreparation: Bool
    @State private var pendingUSBPort: String?
    @State private var fileRequestGeneration = UUID()
    @State private var applicationBusy = false
    init(initialHost: String = "", initialSection: String = "books", externalSection: String? = nil,
         onBusyChange: ((Bool) -> Void)? = nil,
         model: ReadPicoManagerModel? = nil, draftGuard: ReadPicoDraftGuard? = nil,
         libraryModel: ReadPicoLocalLibraryModel? = nil,
         initialDeviceContents: Bool = false,
         embedded: Bool = false, onEndpointVerified: ((String) -> Void)? = nil,
         automaticUSBPreparation: Bool = true, onAutomaticUSBPreparationChange: ((Bool) -> Void)? = nil,
         settingsHeader: AnyView? = nil, fileManagementVisible: Bool = true) {
        self.onBusyChange = onBusyChange
        self.onEndpointVerified = onEndpointVerified
        self.embedded = embedded
        self.externalSection = externalSection
        self.fileManagementVisible = fileManagementVisible
        self.settingsHeader = settingsHeader
        self.onAutomaticUSBPreparationChange = onAutomaticUSBPreparationChange
        _automaticUSBPreparation = State(initialValue: automaticUSBPreparation)
        ownsDraftGuard = draftGuard == nil
        let owner = draftGuard ?? ReadPicoDraftGuard(model: model)
        _drafts = StateObject(wrappedValue: owner)
        _model = StateObject(wrappedValue: owner.model)
        _library = StateObject(wrappedValue: libraryModel ?? ReadPicoLocalLibraryModel())
        _showDeviceContents = State(initialValue: initialDeviceContents)
        _address = State(initialValue: embedded ? Self.savedEndpoint(initialHost) : initialHost)
        _tab = State(initialValue: ReadPicoManagerTab(rawValue: initialSection) ?? .books)
    }
    /// Saved endpoints never carry the temporary key, web session or credentials.
    private static func savedEndpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var parts = URLComponents(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return "" }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.url?.absoluteString ?? ""
    }
    private var activeTab: ReadPicoManagerTab { externalSection.flatMap(ReadPicoManagerTab.init(rawValue:)) ?? tab }
    private var localKind: ReadPicoLibraryKind? { activeTab == .books ? .book : activeTab == .fonts ? .font : activeTab == .notes ? .note : nil }
    private var currentKind: ReadPicoFileKind { localKind?.fileKind ?? (activeTab == .apps ? .application : .drawing) }
    private var compactContentConnection: Bool { activeTab != .connection }
    private var usesCard: Bool { [.apps, .drawings].contains(activeTab) || (localKind != nil && (showDeviceContents || libraryNeedsConnection)) }
    private var contentOperationBusy: Bool {
        model.busy || library.busy || applicationBusy
    }
    private var transientPresentationBusy: Bool {
        library.awaitingConnection || pendingUSBPort != nil || showWeb
    }
    private var visible: [ReadPicoCardFile] { model.files.filter { $0.kind == currentKind && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.relativePath.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded || model.busy { HStack {
                if !embedded { Label("小纸 Pico", systemImage: "book.closed.fill").font(.title2.weight(.semibold)) }

                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small).accessibilityLabel("正在处理设备操作")
                    if model.canCancel { Button(model.cancelTitle) { model.cancelOperation() } }
                }

            } }
            if localKind != nil {
                Picker("内容位置", selection: $showDeviceContents) {
                    Text("Mac 资料库").tag(false)
                    Text("设备内容").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 380)
            }
            if usesCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        cardConnectionPane
                        if activeTab == .apps {
                            ReadPicoBundledAppsView(model: model, onBusyChange: { applicationBusy = $0 })
                        }
                        if localKind != nil && !showDeviceContents {
                            mainContent.frame(minHeight: 430)
                        } else { mainContent }
                        statusFooter
                    }.padding(.trailing, 4)
                }
            } else {
                mainContent
                statusFooter
            }
        }
        .padding(embedded ? 16 : 20)
        .frame(minWidth: embedded ? 0 : 660, maxWidth: .infinity,
               minHeight: embedded ? 0 : 540, maxHeight: .infinity)
        .confirmationDialog("移除“\(pendingDelete?.title ?? "")”？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let file = pendingDelete { Button("移除文件", role: .destructive) { model.remove(file); pendingDelete = nil } }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("只移除所选文件，保留阅读笔记、进度及应用存档。") }
        .sheet(isPresented: $showWeb, onDismiss: {
            // Re-read only after an ordinary detailed-settings close. A global
            // departure must finish before starting any new connection work.
            if !drafts.isHandlingDeparture, let connection = model.connection {
                model.connect(address: connection.managementURL.absoluteString, key: "")
            }
        }) {
            if let connection = model.connection { ReadPicoManagementWebView(connection: connection, draftGuard: drafts) }
        }
        .onChange(of: contentOperationBusy, initial: true) { _, value in onBusyChange?(value) }
        .onChange(of: transientPresentationBusy, initial: true) { _, value in drafts.presentationBusy = value }
        .onChange(of: showDeviceContents) { _, _ in
            cancelPendingFileRequests()
            prepareUSBIfNeeded()
        }
        .onChange(of: model.connection) { _, connection in
            guard let connection else { return }
            address = connection.baseURL.absoluteString
            setupKey = ""
            onEndpointVerified?(connection.baseURL.absoluteString)
        }
        .onChange(of: automaticUSBPreparation) { _, value in
            onAutomaticUSBPreparationChange?(value)
            if value { model.resumeAutomaticUSBPreparation(); prepareUSBIfNeeded() }
            else { cancelPendingFileRequests() }
        }
        .onChange(of: fileManagementVisible) { _, visible in
            if visible { model.resumeAutomaticUSBPreparation(); prepareUSBIfNeeded() }
            else { cancelPendingFileRequests() }
        }
        .onChange(of: activeTab) { _, _ in
            cancelPendingFileRequests()
            if usesCard && fileManagementVisible { model.resumeAutomaticUSBPreparation(); prepareUSBIfNeeded() }
        }
        .onChange(of: selectedUSBPort) { _, _ in prepareUSBIfNeeded() }
        .task(id: fileManagementVisible) {
            while !Task.isCancelled {
                await model.refreshCardAvailability()
                prepareUSBIfNeeded()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .confirmationDialog("使用这台 USB 设备管理 TF 卡？", isPresented: Binding(get: { pendingUSBPort != nil }, set: { if !$0 { pendingUSBPort = nil } }), titleVisibility: .visible) {
            if let port = pendingUSBPort {
                Button("使用这台设备并开启传输") {
                    let requestID = fileRequestGeneration
                    guard canPrepareFileUSB(requestID) else { cancelPendingFileRequests(); return }
                    selectedUSBPort = port; pendingUSBPort = nil
                    drafts.request(.device, title: "开启 USB 前保存设备设置？") {
                        guard canPrepareFileUSB(requestID) else { return }
                        model.startUSB(port: port)
                    }
                }
            }
            Button("暂不连接", role: .cancel) { pendingUSBPort = nil }
        } message: {
            Text("\(pendingUSBPort.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")\n将先核对小纸 Pico 身份和 TF 状态，再开启文件传输。USB 会重新连接一次，Wi-Fi 管理会暂停；本次会话再次进入时会自动准备同一台设备。")
        }
        .onDisappear { cancelPendingFileRequests(); drafts.presentationBusy = false }
        .modifier(ReadPicoDraftProtection(drafts: drafts, enabled: ownsDraftGuard))
    }
    @ViewBuilder private var mainContent: some View {
        if activeTab == .connection { connectionPane }
        else if activeTab == .canvas { ContentUnavailableView("灵犀画板", systemImage: "rectangle.on.rectangle", description: Text("从小纸 Pico 侧栏打开灵犀画板，组合实时信息、图片或手绘并以 16 灰阶推送。")) }
        else if let kind = localKind, !showDeviceContents {
            ReadPicoLocalLibraryView(library: library, manager: model, kind: kind, isActive: fileManagementVisible && usesCard) {
                libraryNeedsConnection = true
                model.resumeAutomaticUSBPreparation(); prepareUSBIfNeeded()
            }
        } else { cardPane.disabled(model.busy) }
    }
    @ViewBuilder private var statusFooter: some View {
        if !compactContentConnection && (localKind == nil || showDeviceContents || model.isError) {
            Divider()
            Label(model.message, systemImage: model.isError ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(model.isError ? Color.red : Color.secondary)
                .font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private var cardConnectionPane: some View {
        ReadPicoUSBConnectionPanel(drafts: drafts, initialAddress: address, compact: compactContentConnection)
    }
    private func prepareUSBIfNeeded() {
        guard canPrepareFileUSB(fileRequestGeneration),
              pendingUSBPort == nil, !drafts.isHandlingDeparture, !drafts.externalBusy,
              let port = model.automaticUSBPreparationCandidate(selectedPort: selectedUSBPort) else { return }
        model.markAutomaticUSBPreparationAttempt(port: port)
        if model.isTrustedUSBPort(port) {
            let requestID = fileRequestGeneration
            drafts.request(.device, title: "自动准备 USB 前保存设备设置？") {
                guard canPrepareFileUSB(requestID) else { return }
                model.startUSB(port: port)
            }
        } else { pendingUSBPort = port }
    }
    private func canPrepareFileUSB(_ requestID: UUID) -> Bool {
        fileRequestGeneration == requestID && fileManagementVisible && usesCard && automaticUSBPreparation
            && model.transportPreference != .wifi && !model.usesWirelessContent
    }
    private func cancelPendingFileRequests() {
        fileRequestGeneration = UUID()
        if library.awaitingConnection { library.cancelPending() }
        libraryNeedsConnection = false
        pendingUSBPort = nil
    }
    private var cardPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(currentKind.title).font(.headline)
                Spacer()
                if currentKind == .application {
                    Toggle("替换同名内容", isOn: $replaceExisting).toggleStyle(.checkbox).help("开启后仅替换同名图书或相同 ID 的应用包；存档不删除。")
                    Button("导入…", systemImage: "square.and.arrow.down") { importFiles() }.disabled(!model.canManageContent || model.busy)
                }
                if !compactContentConnection {
                    Button("刷新", systemImage: "arrow.clockwise") { model.reload() }.disabled(!model.canManageContent || model.busy)
                }
            }
            TextField("搜索\(currentKind.title)", text: $search).textFieldStyle(.roundedBorder)
            if !model.canManageContent {
                ContentUnavailableView("连接 Pico 后查看内容", systemImage: "wifi", description: Text(compactContentConnection ? "连接设备并点击“同步”，即可查看 Pico 中的内容。" : "通过上方 Wi-Fi 配对，或连接 USB 管理 TF 卡文件。"))
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else if visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? "暂无\(currentKind.title)" : "没有匹配结果", systemImage: currentKind == .drawing ? "pencil.and.outline" : "tray", description: Text(cardContentDescription))
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                LazyVStack(spacing: 0) {
                  ForEach(visible) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.kind == .book ? "book.closed" : file.kind == .font ? "textformat" : file.kind == .note ? "note.text" : file.kind == .drawing ? "scribble.variable" : "square.grid.2x2").font(.title3).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.title).font(.body.weight(.medium))
                            Text(file.detail).font(.callout).foregroundStyle(file.valid ? Color.secondary : Color.red).lineLimit(2)
                            Text(file.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(file.sizeLabel).foregroundStyle(.secondary).font(.callout)
                        if file.kind == .drawing {
                            Menu("导出") { Button("可编辑原稿 (.dat)") { export(file, format: "dat") }; Button("矢量图 (.svg)") { export(file, format: "svg") }.disabled(!file.valid); Button("图片 (.png)") { export(file, format: "png") }.disabled(!file.valid) }
                                .fixedSize()
                        } else { Button("移除", role: .destructive) { pendingDelete = file }.disabled(model.busy).fixedSize() }
                    }.padding(10)
                    if file.id != visible.last?.id { Divider() }
                  }
                }.background(usesFloatingSurface ? Color.primary.opacity(0.035) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            Text(cardContentDescription)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var deviceServicesHint: String {
        if model.isHomeAssistantLocked {
            return "薄宿主下设备页的打印机／Bambu／HA 实体配置不可用。请先安装 apps/tools/home-link.pga 或使用完整 Home Link 固件后再打开详细设置。"
        }
        if model.homeLinkMode == .pga {
            return "PGA 模式下打印机精确路由写入设备存储；Bambu 登录仍不可用。优先在设备扫码填写，本机为备用。打开详细设置可查看设备页其余项。"
        }
        return "打开设备提供的管理页面，配置 Bambu Lab 账号与验证码、Formlabs Dashboard、Home Assistant 实体和房间。所有设置由阅读器保存。"
    }
    private var cardContentDescription: String {
        switch currentKind {
        case .book: return "在 Mac 本地资料库导入并勾选图书，再同步到 Pico。通过 Wi-Fi 完成后设备会更新书架；USB 完成后请安全断开。"
        case .font: return "字体保存在 TF 卡 fonts 文件夹。从 Mac 本地资料库预览并勾选同步后，可在阅读器选择字体。"
        case .note: return "本地笔记作为独立文本同步到书架，不覆盖设备的划线和批注。请在 Mac 本地资料库添加或预览。"
        case .application: return "PGA 包按应用 ID 校验和安装；移除只删除程序，保留 apps/data 中的存档和画稿。USB 完成后请安全断开。"
        case .drawing: return "原稿位于 apps/data/drawing-notes，支持继续编辑；PNG 和 SVG 是导出副本。Mac 不删除画板原稿。"
        }
    }
    private var connectionPane: some View {
        Form {
                if let settingsHeader { Section("设备") { settingsHeader } }
                Section("连接") {
                    ReadPicoUSBConnectionPanel(drafts: drafts, initialAddress: address)
                }
                if model.connection != nil {
                    if let connection = model.connection {
                        Label("已保留管理连接：\(connection.baseURL.absoluteString)", systemImage: "checkmark.circle").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if model.deviceSettingsSupported {
                        Section("电源与唤醒") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("自动休眠", selection: $model.deviceConfiguration.autoSleepMinutes) {
                                    ForEach(ReadPicoDeviceConfiguration.allowedSleepMinutes, id: \.self) { minutes in Text(minutes == 0 ? "不自动休眠" : "\(minutes) 分钟后").tag(minutes) }
                                }
                                Toggle("低功耗时双击屏幕唤醒", isOn: $model.deviceConfiguration.doubleTapWake)
                                Text("电源键仍为单击锁屏与唤醒；锁屏样式及其余功能可在详细设置或设备内选择。")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("保存电源设置") { model.saveDeviceSettings() }.disabled(!model.hasUnsavedPowerChanges)
                            }.disabled(model.busy)
                        }
                    }
                    Section(L10n.t(PicoKeys.HomeLink.settingsTitle)) {
                        VStack(alignment: .leading, spacing: 12) {
                            if model.isHomeAssistantLocked {
                                Text("需安装 apps/tools/home-link.pga")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("当前固件为 Home Link 薄宿主（或模块未安装）。可继续管理电源与画板；完整 HA／打印机需安装 TF 包或使用完整模块固件。骨架 PGA 不等于完整 HA。")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            } else if model.isHomePortalBlocking {
                                Text(L10n.t(PicoKeys.HomeLink.portalActive))
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(L10n.t(PicoKeys.HomeLink.portalWait))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            } else if model.homeLinkMode == .pga {
                                Text(L10n.t(PicoKeys.HomeLink.pgaBackup))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Toggle("开启 Home Assistant", isOn: $model.home.enabled)
                            LabeledContent(L10n.t(PicoKeys.HomeLink.fieldLocal)) { TextField("http://homeassistant.local:8123", text: $model.home.local).textFieldStyle(.roundedBorder) }
                            LabeledContent(L10n.t(PicoKeys.HomeLink.fieldWifi)) { Picker(L10n.t(PicoKeys.HomeLink.fieldWifi), selection: $model.home.homeWifi) { Text("未指定").tag(""); ForEach(model.wifi, id: \.self) { Text($0).tag($0) } }.labelsHidden() }
                            LabeledContent(L10n.t(PicoKeys.HomeLink.fieldToken)) { SecureField(model.home.hasToken ? "已保存；输入新令牌可替换" : "Home Assistant 长期访问令牌", text: $model.homeToken).textFieldStyle(.roundedBorder).accessibilityLabel("Home Assistant 访问令牌") }
                            DisclosureGroup("外部访问与 Cloudflare Access（高级）") {
                                Toggle("允许外部访问", isOn: $model.home.externalEnabled)
                                LabeledContent(L10n.t(PicoKeys.HomeLink.fieldExternal)) { TextField("https://…", text: $model.home.external).textFieldStyle(.roundedBorder) }
                                Toggle("允许外部控制", isOn: $model.home.externalControl)
                                Text("Cloudflare Access Service Token 仅用于外部 HTTPS Home Assistant（Zero Trust），写入阅读器后由设备侧发起请求；与网页 Cloudflare Analytics 无关。Mac 不代为创建令牌。")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Link(destination: URL(string: "https://one.dash.cloudflare.com/")!) {
                                        Label("打开 Zero Trust 控制台", systemImage: "arrow.up.right.square")
                                    }
                                    Link(destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/")!) {
                                        Label("如何创建 Service Token", systemImage: "questionmark.circle")
                                    }
                                }
                                .help("路径：Cloudflare One / Zero Trust → Access → Service Auth → Service Tokens。创建后复制 Client ID / Client Secret，粘贴到下方并保存到阅读器。")
                                Text("获取步骤：Zero Trust 控制台 → Access → Service Auth → Service Tokens → Create；将 Client ID / Client Secret 填入下方。令牌只保存在设备，不会回传到 Mac 明文。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                LabeledContent(L10n.t(PicoKeys.HomeLink.fieldCfId)) {
                                    SecureField(model.home.hasCfAccessClientId ? "已保存；输入可替换（≤95）" : "外部 HA 的 CF-Access-Client-Id（≤95）", text: $model.homeCfAccessClientId)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Cloudflare Access 客户端 ID（外部 HTTPS HA）")
                                }
                                LabeledContent(L10n.t(PicoKeys.HomeLink.fieldCfSecret)) {
                                    SecureField(model.home.hasCfAccessClientSecret ? "已保存；输入可替换（≤63）" : "外部 HA 的 CF-Access-Client-Secret（≤63）", text: $model.homeCfAccessClientSecret)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Cloudflare Access 客户端密钥（外部 HTTPS HA）")
                                }
                            }
                            Button(L10n.t(PicoKeys.HomeLink.save)) { model.saveHome() }
                                .disabled(model.busy || !model.canSubmitHomeAssistant || !model.hasUnsavedHomeChanges)
                        }.disabled(model.busy || model.isHomeAssistantLocked || model.isHomePortalBlocking)
                    }
                    Section("设备服务") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(deviceServicesHint)
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("打开设备详细设置", systemImage: "globe") {
                                drafts.request(.device, title: "打开详细设置前保存修改？") { showWeb = true }
                            }
                        }.disabled(model.busy)
                    }
                }
        }.formStyle(.grouped)
        .controlCenterHostedFormSurface()
    }
    private func selectCard() {
        let panel = NSOpenPanel(); panel.title = "选择阅读器 TF 磁盘"; panel.prompt = "选择磁盘"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { model.selectCard(url) }
    }
    private func importFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = currentKind == .application ? [UTType(filenameExtension: "pga") ?? .data] : [.epub, .plainText]
        if panel.runModal() == .OK { model.install(panel.urls, kind: currentKind, replace: replaceExisting) }
    }
    private func export(_ file: ReadPicoCardFile, format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: file.relativePath).deletingPathExtension().lastPathComponent + "." + format
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        if panel.runModal() == .OK, let url = panel.url { model.export(file, to: url, format: format) }
    }
    private func disconnect(title: String) {
        drafts.request(.device, title: title) {
            guard model.disconnect() else { return }
            setupKey = ""
            if let url = try? ReadPicoConnection(address: address).baseURL { address = url.absoluteString }
        }
    }

}
private enum ReadPicoManagerTab: String, CaseIterable, Identifiable {
    case books, fonts, notes, apps, drawings, connection, canvas
    var id: String { rawValue }
    var title: String { switch self { case .books: return "图书"; case .fonts: return "字体"; case .notes: return "笔记"; case .apps: return "应用"; case .drawings: return "画板原稿"; case .connection: return "设备设置"; case .canvas: return "灵犀画板" } }
}
