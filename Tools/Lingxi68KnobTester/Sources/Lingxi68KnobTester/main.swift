import AppKit
import IOKit.hid
import SwiftUI

private let lingxiVendorID = 0x38EE
private let lingxiProductID = 0x0005

private struct HIDLogEntry: Identifiable {
    let id = UUID()
    let time: String
    let title: String
    let detail: String
    let kind: Kind

    enum Kind {
        case action
        case raw
        case system
    }
}

@MainActor
private final class HIDMonitor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var connectedInterfaces = 0
    @Published private(set) var latestAction = "等待旋钮操作"
    @Published private(set) var entries: [HIDLogEntry] = []
    @Published private(set) var hasFeatureInterface = false
    @Published private(set) var isDeepScanRunning = false
    @Published private(set) var deepScanSecondsRemaining = 0
    @Published private(set) var featureReadCount = 0
    @Published private(set) var hasInputAccess = false
    @Published private(set) var inputAccessLabel = "输入监控：检查中"

    private var manager: IOHIDManager?
    private var reportRegistrations: [RawReportRegistration] = []
    private var featurePoller: FeatureReportPoller?
    private var deepScanTimer: Timer?
    private var featureReadSucceeded = false
    private var featureChangeCount = 0

    func start() {
        guard manager == nil else { return }

        refreshInputAccess(requestIfUnknown: true)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: lingxiVendorID,
            kIOHIDProductIDKey as String: lingxiProductID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.deviceAdded(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.deviceRemoved(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.received(value: value, result: result) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isRunning = result == kIOReturnSuccess
        refreshInputAccess(requestIfUnknown: false)

        if result == kIOReturnSuccess {
            append(title: "监听已启动", detail: "目标 VID 0x38EE / PID 0x0005", kind: .system)
        } else {
            append(
                title: "标准输入监听未完全开启",
                detail: String(format: "IOKit 错误：0x%08X。厂商 Feature 接口仍可能独立可用；媒体键监听需要输入监控权限。", result),
                kind: .system
            )
        }
    }

    func stop() {
        guard let manager else { return }
        stopDeepScan(showResult: false)
        featurePoller?.stop()
        featurePoller = nil
        hasFeatureInterface = false
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        isRunning = false
        connectedInterfaces = 0
        // IOHID 在设备关闭后不再触发回调，此时可以安全释放 Report 缓冲区。
        reportRegistrations.removeAll()
    }

    func clear() {
        entries.removeAll()
        latestAction = "等待旋钮操作"
    }

    func copyLog() {
        let text = entries.reversed().map { entry in
            "[\(entry.time)] \(entry.title) — \(entry.detail)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func startDeepScan() {
        guard let featurePoller, !isDeepScanRunning else { return }
        featureReadSucceeded = false
        featureChangeCount = 0
        featureReadCount = 0
        deepScanSecondsRemaining = 15
        isDeepScanRunning = true
        latestAction = "深度扫描中：请不要按 Fn，转动并按压旋钮"
        append(
            title: "开始裸旋钮深度扫描",
            detail: "15 秒内只操作旋钮，不要按 Fn；正在轮询 64 字节只读 Feature Report。",
            kind: .system
        )
        featurePoller.start()

        deepScanTimer?.invalidate()
        deepScanTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                self.deepScanSecondsRemaining -= 1
                if self.deepScanSecondsRemaining <= 0 {
                    self.stopDeepScan(showResult: true)
                }
            }
        }
    }

    func stopDeepScan(showResult: Bool = true) {
        guard isDeepScanRunning else { return }
        deepScanTimer?.invalidate()
        deepScanTimer = nil
        featurePoller?.stop()
        isDeepScanRunning = false
        deepScanSecondsRemaining = 0

        guard showResult else { return }
        if featureChangeCount > 0 {
            latestAction = "发现 \(featureChangeCount) 次隐藏状态变化"
            append(
                title: "深度扫描完成",
                detail: "实际读取 \(featureReadCount) 次，Feature Report 共变化 \(featureChangeCount) 次，存在继续解析裸旋钮的可能。",
                kind: .action
            )
        } else if featureReadSucceeded {
            latestAction = "未发现裸旋钮状态变化"
            append(
                title: "深度扫描完成",
                detail: "Feature Report 成功读取 \(featureReadCount) 次，但在扫描期间没有发生变化。",
                kind: .system
            )
        } else {
            latestAction = "厂商状态读取失败"
            append(
                title: "深度扫描完成",
                detail: "无法读取厂商 Feature Report，详见错误记录。",
                kind: .system
            )
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        connectedInterfaces += 1

        let usagePage = intProperty(kIOHIDPrimaryUsagePageKey, device: device)
        let usage = intProperty(kIOHIDPrimaryUsageKey, device: device)
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "未知设备"
        append(
            title: "发现 HID 接口",
            detail: "\(product) · Usage Page \(hex(usagePage)) / Usage \(hex(usage))",
            kind: .system
        )

        // InputValue 可以直接识别标准媒体键；InputReport 用于观察厂商自定义接口。
        let registration = RawReportRegistration(owner: self, device: device)
        reportRegistrations.append(registration)
        registration.begin()

        if usagePage == 0xFFFF, usage == 0x02 {
            featurePoller?.stop()
            featurePoller = FeatureReportPoller(owner: self, device: device)
            hasFeatureInterface = true
            append(
                title: "发现厂商 Feature 接口",
                detail: "64 字节只读轮询可用；该接口没有 Input Report。",
                kind: .system
            )
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        connectedInterfaces = max(0, connectedInterfaces - 1)
        if intProperty(kIOHIDPrimaryUsagePageKey, device: device) == 0xFFFF {
            stopDeepScan(showResult: false)
            featurePoller?.stop()
            featurePoller = nil
            hasFeatureInterface = false
        }
        append(title: "HID 接口已断开", detail: interfaceDescription(device), kind: .system)
    }

    private func received(value: IOHIDValue, result: IOReturn) {
        guard result == kIOReturnSuccess else {
            append(title: "读取事件失败", detail: String(format: "IOKit 错误：0x%08X", result), kind: .system)
            return
        }

        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let integerValue = IOHIDValueGetIntegerValue(value)

        let action = actionName(usagePage: usagePage, usage: usage, value: integerValue)
        if let action, integerValue != 0 {
            latestAction = action
            append(
                title: action,
                detail: "Usage Page \(hex(usagePage)) / Usage \(hex(usage)) / Value \(integerValue)",
                kind: .action
            )
        } else {
            append(
                title: "HID Value",
                detail: "Usage Page \(hex(usagePage)) / Usage \(hex(usage)) / Value \(integerValue)",
                kind: .raw
            )
        }
    }

    fileprivate func receivedRawReport(type: IOHIDReportType, reportID: UInt32, bytes: [UInt8]) {
        // 空的全零 Report 通常只是释放态；仍保留非零数据，避免日志被淹没。
        guard bytes.contains(where: { $0 != 0 }) else { return }
        let typeName: String
        switch type {
        case kIOHIDReportTypeInput: typeName = "Input"
        case kIOHIDReportTypeOutput: typeName = "Output"
        case kIOHIDReportTypeFeature: typeName = "Feature"
        default: typeName = "Type \(type.rawValue)"
        }
        let payload = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        append(
            title: "原始 HID Report",
            detail: "\(typeName) · ID \(reportID) · [\(payload)]",
            kind: .raw
        )
    }

    fileprivate func receivedFeatureBaseline(_ bytes: [UInt8]) {
        featureReadSucceeded = true
        append(
            title: "Feature 基准状态",
            detail: "[\(hexPayload(bytes))]",
            kind: .raw
        )
    }

    fileprivate func receivedFeatureProgress(_ count: Int) {
        featureReadSucceeded = true
        featureReadCount = count
    }

    fileprivate func receivedFeatureChange(previous: [UInt8], current: [UInt8]) {
        featureReadSucceeded = true
        featureChangeCount += 1
        let changedIndexes = zip(previous, current).enumerated().compactMap { index, pair in
            pair.0 == pair.1 ? nil : "\(index):\(String(format: "%02X", pair.0))→\(String(format: "%02X", pair.1))"
        }
        latestAction = "发现隐藏状态变化"
        append(
            title: "Feature Report 发生变化",
            detail: "变化字节 \(changedIndexes.joined(separator: ", ")) · [\(hexPayload(current))]",
            kind: .action
        )
    }

    fileprivate func receivedFeatureError(_ result: IOReturn) {
        append(
            title: "Feature Report 读取失败",
            detail: String(format: "IOKit 错误：0x%08X", result),
            kind: .system
        )
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshInputAccess(requestIfUnknown: Bool) {
        var access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeUnknown, requestIfUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        }

        switch access {
        case kIOHIDAccessTypeGranted:
            hasInputAccess = true
            inputAccessLabel = "标准输入监听：已授权"
        case kIOHIDAccessTypeDenied:
            hasInputAccess = false
            inputAccessLabel = "标准输入监听：未授权"
        default:
            hasInputAccess = false
            inputAccessLabel = "标准输入监听：待授权"
        }
    }

    private func append(title: String, detail: String, kind: HIDLogEntry.Kind) {
        entries.insert(
            HIDLogEntry(time: Self.timeFormatter.string(from: Date()), title: title, detail: detail, kind: kind),
            at: 0
        )
        if entries.count > 300 {
            entries.removeLast(entries.count - 300)
        }
    }

    private func actionName(usagePage: Int, usage: Int, value: CFIndex) -> String? {
        guard usagePage == 0x0C else { return nil }
        switch usage {
        case 0xE9: return "顺时针 / 音量增加"
        case 0xEA: return "逆时针 / 音量减少"
        case 0xE2: return "旋钮按压 / 静音"
        case 0xCD: return "播放 / 暂停"
        default: return value == 0 ? nil : "Consumer Control 事件"
        }
    }

    private func interfaceDescription(_ device: IOHIDDevice) -> String {
        let usagePage = intProperty(kIOHIDPrimaryUsagePageKey, device: device)
        let usage = intProperty(kIOHIDPrimaryUsageKey, device: device)
        return "Usage Page \(hex(usagePage)) / Usage \(hex(usage))"
    }

    private func intProperty(_ key: String, device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func hex(_ value: Int) -> String {
        String(format: "0x%02X", value)
    }

    private func hexPayload(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// 厂商接口没有 Input Report，只有 64 字节 Feature Report。扫描期间仅执行 GetReport，绝不写入设备。
private final class FeatureReportPoller {
    weak var owner: HIDMonitor?
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "com.xh.lingxi68.feature-scan", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var previous: [UInt8]?
    private var didReportError = false
    private var successfulReadCount = 0

    init(owner: HIDMonitor, device: IOHIDDevice) {
        self.owner = owner
        self.device = device
    }

    func start() {
        stop()
        previous = nil
        didReportError = false
        successfulReadCount = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(bytes.count)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                0,
                buffer.baseAddress!,
                &length
            )
        }

        guard result == kIOReturnSuccess else {
            if !didReportError {
                didReportError = true
                Task { @MainActor [weak owner] in owner?.receivedFeatureError(result) }
            }
            return
        }

        successfulReadCount += 1
        if successfulReadCount == 1 || successfulReadCount.isMultiple(of: 40) {
            let count = successfulReadCount
            Task { @MainActor [weak owner] in owner?.receivedFeatureProgress(count) }
        }

        bytes = Array(bytes.prefix(max(0, min(bytes.count, Int(length)))))
        if let previous {
            if previous != bytes {
                self.previous = bytes
                Task { @MainActor [weak owner] in
                    owner?.receivedFeatureChange(previous: previous, current: bytes)
                }
            }
        } else {
            previous = bytes
            Task { @MainActor [weak owner] in owner?.receivedFeatureBaseline(bytes) }
        }
    }
}

private final class RawReportRegistration {
    weak var owner: HIDMonitor?
    private let device: IOHIDDevice
    private let capacity = 1024
    private let buffer: UnsafeMutablePointer<UInt8>

    init(owner: HIDMonitor, device: IOHIDDevice) {
        self.owner = owner
        self.device = device
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    func begin() {
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            capacity,
            { context, result, _, type, reportID, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                let registration = Unmanaged<RawReportRegistration>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                Task { @MainActor in
                    registration.owner?.receivedRawReport(type: type, reportID: reportID, bytes: bytes)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}

private struct ContentView: View {
    @ObservedObject var monitor: HIDMonitor

    var body: some View {
        VStack(spacing: 16) {
            header
            latestActionCard
            instructions
            deepScanPanel
            eventList
            footer
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("灵犀 68 旋钮测试器")
                    .font(.title2.bold())
                Text("独立 HID 诊断程序 · VID 38EE / PID 0005")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                monitor.connectedInterfaces > 0 ? "已连接（\(monitor.connectedInterfaces) 个接口）" : "未发现设备",
                systemImage: monitor.connectedInterfaces > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(monitor.connectedInterfaces > 0 ? .green : .orange)
        }
    }

    private var latestActionCard: some View {
        VStack(spacing: 8) {
            Text("最近一次识别")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(monitor.latestAction)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
    }

    private var instructions: some View {
        HStack(spacing: 18) {
            instruction(number: "1", text: "顺时针转一格")
            instruction(number: "2", text: "逆时针转一格")
            instruction(number: "3", text: "按压旋钮一次")
            Spacer()
            Text("操作可能同时改变系统音量，这是标准媒体键的正常现象。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 230, alignment: .trailing)
        }
    }

    private func instruction(number: String, text: String) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            Text(text).font(.callout.weight(.medium))
        }
    }

    private var deepScanPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("不按 Fn 深度扫描")
                    .font(.callout.bold())
                Text("只读轮询厂商 Feature Report；开始后 15 秒内转动并按压旋钮，全程不要按 Fn。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isDeepScanRunning {
                Button("停止（\(monitor.deepScanSecondsRemaining) 秒）") {
                    monitor.stopDeepScan()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button("开始 15 秒扫描") {
                    monitor.startDeepScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!monitor.hasFeatureInterface)
            }
        }
        .padding(12)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.purple.opacity(0.25)))
    }

    private var eventList: some View {
        GroupBox("事件记录（最新在上）") {
            if monitor.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("暂无事件")
                        .font(.headline)
                    Text("转动或按下旋钮后，事件会显示在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(monitor.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: icon(for: entry.kind))
                            .foregroundStyle(color(for: entry.kind))
                            .frame(width: 18)
                        Text(entry.time)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                        Text(entry.title)
                            .font(.callout.weight(.semibold))
                            .frame(width: 165, alignment: .leading)
                        Text(entry.detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Label(
                monitor.inputAccessLabel,
                systemImage: monitor.hasInputAccess ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(monitor.hasInputAccess ? .green : .orange)
            if !monitor.hasInputAccess {
                Button("打开输入监控设置") { monitor.openInputMonitoringSettings() }
                    .font(.caption)
            }
            Divider().frame(height: 16)
            Label(
                monitor.hasFeatureInterface
                    ? (monitor.featureReadCount > 0 ? "厂商扫描：已读取 \(monitor.featureReadCount) 次" : "厂商深度扫描：可用")
                    : "厂商深度扫描：不可用",
                systemImage: monitor.hasFeatureInterface ? "scope" : "scope"
            )
            .font(.caption)
            .foregroundStyle(monitor.hasFeatureInterface ? .purple : .secondary)
            Spacer()
            Button("清空") { monitor.clear() }
            Button("复制日志") { monitor.copyLog() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    private func icon(for kind: HIDLogEntry.Kind) -> String {
        switch kind {
        case .action: return "dial.high.fill"
        case .raw: return "waveform.path.ecg"
        case .system: return "info.circle.fill"
        }
    }

    private func color(for kind: HIDLogEntry.Kind) -> Color {
        switch kind {
        case .action: return .blue
        case .raw: return .purple
        case .system: return .secondary
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
private struct Lingxi68KnobTesterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = HIDMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
                .onAppear { monitor.start() }
                .onDisappear { monitor.stop() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 860, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
