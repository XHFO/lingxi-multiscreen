import CoreBluetooth
import Foundation

public struct M5DiscoveredController: Identifiable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum M5ControllerBluetoothState: Sendable {
    case unknown
    case ready
    case poweredOff
    case unauthorized
    case unsupported
}

/// StickS3 控制器的全局 BLE 中心会话。用户扫描与后台自动重连分别记账，
/// 因此断线重连不会让设备管理页一直显示“正在扫描”。
public final class M5ControllerBLEClient: NSObject, @unchecked Sendable {
    public var onEvent: ((M5ControllerEvent) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public var onDiscovered: (([M5DiscoveredController]) -> Void)?
    public var onScanStateChange: ((Bool) -> Void)?
    public var onStateChange: ((M5ControllerBluetoothState) -> Void)?
    /// `error == nil` 代表设备已经完成分片重组并成功解析，而不只是 macOS
    /// 把若干字节交给了蓝牙栈。
    public var onInfoTransmissionResult: ((Data, Error?) -> Void)?

    private let serviceUUID = CBUUID(string: M5ControllerBLE.serviceUUIDString)
    private let eventCharacteristicUUID = CBUUID(
        string: M5ControllerBLE.eventCharacteristicUUIDString)
    private let infoCharacteristicUUID = CBUUID(
        string: M5ControllerBLE.infoCharacteristicUUIDString)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var infoCharacteristic: CBCharacteristic?
    private var desiredPeripheralID: UUID?
    private var discoveredMap: [UUID: M5DiscoveredController] = [:]
    private var pendingInfo: Data?
    private struct InfoTransmission {
        let payload: Data
        let transferID: UInt16
        let chunks: [Data]
        var chunkIndex = 0
        var chunkRetryCount = 0
        var wholeRetryCount = 0
        var transportComplete = false
        var applicationACKReceived = false
    }
    private var activeTransmission: InfoTransmission?
    private var nextTransferID: UInt16 = 1
    private var lastDeliveredInfo: Data?
    private var infoACKTimeoutWorkItem: DispatchWorkItem?
    private var infoRetryWorkItem: DispatchWorkItem?
    private var eventNotificationsReady = false
    /// 删除设备/解除配对时，先把空设备列表可靠写回控制器，再断开 BLE。
    private var disconnectAfterPayload: Data?
    private var disconnectFallbackWorkItem: DispatchWorkItem?
    private var connectedFlag = false
    private var userScanRequested = false
    /// macOS 自动连接的 HID 外设不一定再次触发普通扫描回调。用户扫描期间持续把
    /// 系统已连接的同服务外设并入结果，覆盖固件刚重启时的短暂发现窗口。
    private var systemDiscoveryRefreshWorkItem: DispatchWorkItem?
    private var bluetoothStateValue: M5ControllerBluetoothState = .unknown

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public var isConnected: Bool { connectedFlag }
    public var isScanning: Bool { userScanRequested }
    public var bluetoothState: M5ControllerBluetoothState { bluetoothStateValue }
    public var discoveredControllers: [M5DiscoveredController] {
        discoveredMap.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func startScan() {
        guard !userScanRequested else {
            scheduleSystemDiscoveryRefresh()
            updateHardwareScan()
            return
        }
        userScanRequested = true
        onScanStateChange?(true)
        includeSystemConnectedPeripherals()
        scheduleSystemDiscoveryRefresh()
        updateHardwareScan()
    }

    public func stopScan() {
        guard userScanRequested else {
            cancelSystemDiscoveryRefresh()
            updateHardwareScan()
            return
        }
        userScanRequested = false
        cancelSystemDiscoveryRefresh()
        onScanStateChange?(false)
        updateHardwareScan()
    }

    public func clearDiscovered() {
        discoveredMap.removeAll()
        onDiscovered?([])
    }

    public func connect(peripheralID: UUID) {
        cancelDeferredDisconnect()
        if desiredPeripheralID == peripheralID {
            if !connectedFlag { tryDirectRetrieve(peripheralID) }
            updateHardwareScan()
            return
        }
        desiredPeripheralID = peripheralID
        pendingInfo = nil
        resetInfoTransport(keepPending: false)
        teardownPeripheral(notify: true)
        tryDirectRetrieve(peripheralID)
        updateHardwareScan()
    }

    public func disconnect() {
        cancelDeferredDisconnect()
        desiredPeripheralID = nil
        pendingInfo = nil
        resetInfoTransport(keepPending: false)
        teardownPeripheral(notify: true)
        updateHardwareScan()
    }

    /// 清空 StickS3 上最后一次收到的卡片，并在写入确认后断开。
    /// 超时兜底确保异常外设不会让连接永久悬挂。
    public func clearInfoAndDisconnect(info: Data) {
        desiredPeripheralID = nil
        cancelDeferredDisconnect()
        guard connectedFlag, let peripheral, let infoCharacteristic else {
            teardownPeripheral(notify: true)
            updateHardwareScan()
            return
        }

        _ = peripheral
        _ = infoCharacteristic
        disconnectAfterPayload = info
        pendingInfo = info
        pumpInfoQueue()
        let fallback = DispatchWorkItem { [weak self] in
            self?.finishDeferredDisconnect()
        }
        disconnectFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: fallback)
    }

    public func send(info: Data) {
        guard !info.isEmpty, info.count <= M5ControllerInfoTransport.maximumPayloadSize else {
            onInfoTransmissionResult?(info, M5ControllerInfoTransmissionError.invalidPayload)
            return
        }
        if info == pendingInfo || info == activeTransmission?.payload
            || info == lastDeliveredInfo { return }
        pendingInfo = info
        pumpInfoQueue()
    }

    private func pumpInfoQueue() {
        guard activeTransmission == nil, connectedFlag, eventNotificationsReady,
              let peripheral, infoCharacteristic != nil,
              let payload = pendingInfo else { return }
        pendingInfo = nil
        let maximumLength = peripheral.maximumWriteValueLength(for: .withResponse)
        let transferID = nextTransferID
        nextTransferID = nextTransferID == UInt16.max ? 1 : nextTransferID &+ 1
        let chunks = M5ControllerInfoTransport.chunks(
            payload: payload, maximumWriteLength: maximumLength, transferID: transferID)
        guard !chunks.isEmpty else {
            onInfoTransmissionResult?(payload, M5ControllerInfoTransmissionError.invalidPayload)
            return
        }
        activeTransmission = InfoTransmission(payload: payload,
                                              transferID: transferID,
                                              chunks: chunks)
        writeCurrentInfoChunk()
    }

    private func writeCurrentInfoChunk() {
        guard let peripheral, let infoCharacteristic,
              let transmission = activeTransmission,
              transmission.chunks.indices.contains(transmission.chunkIndex) else { return }
        peripheral.writeValue(transmission.chunks[transmission.chunkIndex],
                              for: infoCharacteristic, type: .withResponse)
    }

    private func scheduleInfoACKTimeout() {
        infoACKTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.retryOrFailActiveTransmission(
                M5ControllerInfoTransmissionError.applicationACKTimedOut)
        }
        infoACKTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func retryOrFailActiveTransmission(_ error: Error) {
        guard var transmission = activeTransmission else { return }
        infoACKTimeoutWorkItem?.cancel()
        infoACKTimeoutWorkItem = nil
        if pendingInfo == nil, connectedFlag, transmission.wholeRetryCount < 2 {
            transmission.wholeRetryCount += 1
            transmission.chunkIndex = 0
            transmission.chunkRetryCount = 0
            transmission.transportComplete = false
            transmission.applicationACKReceived = false
            activeTransmission = transmission
            let work = DispatchWorkItem { [weak self] in self?.writeCurrentInfoChunk() }
            infoRetryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return
        }
        let payload = transmission.payload
        activeTransmission = nil
        onInfoTransmissionResult?(payload, error)
        pumpInfoQueue()
    }

    private func completeActiveTransmission() {
        guard let transmission = activeTransmission else { return }
        infoACKTimeoutWorkItem?.cancel()
        infoACKTimeoutWorkItem = nil
        activeTransmission = nil
        lastDeliveredInfo = transmission.payload
        onInfoTransmissionResult?(transmission.payload, nil)
        if disconnectAfterPayload == transmission.payload {
            finishDeferredDisconnect()
        } else {
            pumpInfoQueue()
        }
    }

    private func handleInfoApplicationACK(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "info",
              let id = object["id"] as? Int,
              var transmission = activeTransmission,
              Int(transmission.transferID) == id else { return false }
        if object["ok"] as? Bool != true {
            retryOrFailActiveTransmission(M5ControllerInfoTransmissionError.deviceRejectedPayload)
            return true
        }
        let byteCount = object["bytes"] as? Int ?? -1
        guard byteCount == transmission.payload.count else {
            retryOrFailActiveTransmission(M5ControllerInfoTransmissionError.deviceRejectedPayload)
            return true
        }
        transmission.applicationACKReceived = true
        activeTransmission = transmission
        if transmission.transportComplete { completeActiveTransmission() }
        return true
    }

    private func resetInfoTransport(keepPending: Bool) {
        infoACKTimeoutWorkItem?.cancel()
        infoACKTimeoutWorkItem = nil
        infoRetryWorkItem?.cancel()
        infoRetryWorkItem = nil
        if keepPending {
            pendingInfo = pendingInfo ?? activeTransmission?.payload
        }
        activeTransmission = nil
        lastDeliveredInfo = nil
        eventNotificationsReady = false
    }

    private func updateHardwareScan() {
        guard central.state == .poweredOn else { return }
        let reconnectNeeded = desiredPeripheralID != nil && !connectedFlag
        if userScanRequested || reconnectNeeded {
            if !central.isScanning {
                central.scanForPeripherals(withServices: [serviceUUID])
            }
        } else if central.isScanning {
            central.stopScan()
        }
    }

    /// CoreBluetooth 不会保证一个已经被系统连接的外设仍通过普通扫描回调出现。
    /// 把同服务的系统已连接外设也并入用户扫描结果，删除档案后可以立即重新添加。
    private func includeSystemConnectedPeripherals() {
        guard central.state == .poweredOn, userScanRequested else { return }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
            discoveredMap[peripheral.identifier] = M5DiscoveredController(
                id: peripheral.identifier,
                name: peripheral.name ?? "M5 StickS3 控制器")
        }
        onDiscovered?(discoveredControllers)
    }

    private func scheduleSystemDiscoveryRefresh() {
        cancelSystemDiscoveryRefresh()
        guard userScanRequested else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.userScanRequested else { return }
            self.includeSystemConnectedPeripherals()
            self.updateHardwareScan()
            self.scheduleSystemDiscoveryRefresh()
        }
        systemDiscoveryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelSystemDiscoveryRefresh() {
        systemDiscoveryRefreshWorkItem?.cancel()
        systemDiscoveryRefreshWorkItem = nil
    }

    private func tryDirectRetrieve(_ id: UUID) {
        guard central.state == .poweredOn,
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        attach(target)
    }

    private func attach(_ target: CBPeripheral) {
        if peripheral?.identifier == target.identifier,
           (target.state == .connected || target.state == .connecting) { return }
        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)
    }

    private func teardownPeripheral(notify: Bool) {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        eventCharacteristic = nil
        infoCharacteristic = nil
        resetInfoTransport(keepPending: desiredPeripheralID != nil)
        guard connectedFlag else { return }
        connectedFlag = false
        if notify { onConnectionChange?(false) }
    }


    private func cancelDeferredDisconnect() {
        disconnectFallbackWorkItem?.cancel()
        disconnectFallbackWorkItem = nil
        disconnectAfterPayload = nil
    }

    private func finishDeferredDisconnect() {
        guard disconnectAfterPayload != nil else { return }
        disconnectAfterPayload = nil
        disconnectFallbackWorkItem?.cancel()
        disconnectFallbackWorkItem = nil
        teardownPeripheral(notify: true)
        updateHardwareScan()
    }

    private func markReady() {
        guard !connectedFlag else { return }
        connectedFlag = true
        updateHardwareScan()
        onConnectionChange?(true)
        if let pendingInfo {
            self.pendingInfo = pendingInfo
            pumpInfoQueue()
        }
    }
}

extension M5ControllerBLEClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = M5ControllerBluetoothState(central.state)
        if state != bluetoothStateValue {
            bluetoothStateValue = state
            onStateChange?(state)
        }
        guard central.state == .poweredOn else {
            teardownPeripheral(notify: true)
            return
        }
        includeSystemConnectedPeripherals()
        if let desiredPeripheralID, !connectedFlag { tryDirectRetrieve(desiredPeripheralID) }
        updateHardwareScan()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "M5 StickS3 控制器"
        if userScanRequested {
            discoveredMap[peripheral.identifier] = M5DiscoveredController(
                id: peripheral.identifier, name: name)
            onDiscovered?(discoveredControllers)
        }
        if desiredPeripheralID == peripheral.identifier { attach(peripheral) }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        if desiredPeripheralID == peripheral.identifier { self.peripheral = nil }
        updateHardwareScan()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        let wasConnected = connectedFlag
        self.peripheral = nil
        eventCharacteristic = nil
        infoCharacteristic = nil
        resetInfoTransport(keepPending: desiredPeripheralID != nil)
        connectedFlag = false
        if wasConnected { onConnectionChange?(false) }
        updateHardwareScan()
    }
}

extension M5ControllerBLEClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [eventCharacteristicUUID, infoCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard error == nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == eventCharacteristicUUID {
                eventCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == infoCharacteristicUUID {
                infoCharacteristic = characteristic
            }
        }
        if eventCharacteristic?.isNotifying == true, infoCharacteristic != nil {
            eventNotificationsReady = true
            markReady()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == eventCharacteristicUUID else { return }
        eventNotificationsReady = error == nil && characteristic.isNotifying
        if eventNotificationsReady, infoCharacteristic != nil { markReady() }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil,
              characteristic.uuid == eventCharacteristicUUID,
              let text = String(data: characteristic.value ?? Data(), encoding: .utf8) else {
            return
        }
        if handleInfoApplicationACK(text) { return }
        guard let event = M5ControllerEvent.parse(text) else { return }
        onEvent?(event)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == infoCharacteristicUUID,
              var transmission = activeTransmission else { return }
        if let error {
            if transmission.chunkRetryCount < 2 {
                transmission.chunkRetryCount += 1
                activeTransmission = transmission
                let work = DispatchWorkItem { [weak self] in self?.writeCurrentInfoChunk() }
                infoRetryWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                retryOrFailActiveTransmission(error)
            }
            return
        }
        transmission.chunkRetryCount = 0
        if transmission.chunkIndex + 1 < transmission.chunks.count {
            transmission.chunkIndex += 1
            activeTransmission = transmission
            writeCurrentInfoChunk()
        } else {
            transmission.transportComplete = true
            activeTransmission = transmission
            if transmission.applicationACKReceived {
                completeActiveTransmission()
            } else {
                scheduleInfoACKTimeout()
            }
        }
    }
}

public enum M5ControllerInfoTransmissionError: Error, LocalizedError {
    case invalidPayload
    case applicationACKTimedOut
    case deviceRejectedPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "控制卡片数据无效或超过 8 KB。"
        case .applicationACKTimedOut: return "控制器没有确认卡片数据。"
        case .deviceRejectedPayload: return "控制器未能解析卡片数据。"
        }
    }
}

private extension M5ControllerBluetoothState {
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .ready
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting, .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
