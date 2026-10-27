import AppKit
import LinxDisplayCore
import SwiftUI

/// A read-only, source-matched projection of the printer readings already in memory.
/// Missing readings stay missing; this projection never starts a request.
struct ControlCenterPrinterSnapshot {
    enum Brand { case bambu, formlabs }
    enum PictureKind { case camera, task }
    struct Picture: Identifiable {
        let kind: PictureKind
        let image: NSImage?
        let placeholder: String
        var id: String { kind == .camera ? "camera" : "task" }
        var title: String { kind == .camera ? "摄像头快照" : "任务封面" }
        var symbol: String { kind == .camera ? "camera" : "cube.transparent" }
    }
    struct Metric: Identifiable {
        let label: String
        let value: String
        let symbol: String
        var id: String { label }
    }
    let brand: Brand
    let usesBrandAccent: Bool
    let status: String
    let task: String?
    let progress: Double?
    let metrics: [Metric]
    let error: String?
    let pictures: [Picture]
    let pictureNotice: String?
    let sampledAt: Date?

    var brandTitle: String { brand == .bambu ? "Bambu Lab" : "Formlabs" }
    var accent: Color {
        guard usesBrandAccent else { return .accentColor }
        return brand == .bambu ? Color(red: 0.26, green: 0.62, blue: 0.35)
            : Color(red: 0.16, green: 0.47, blue: 0.86)
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "unknown", "unavailable", "none", "null"].contains(trimmed.lowercased()) ? nil : trimmed
    }

    private static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 315_360_000 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds)
    }

    static func bambu(_ config: BambuLabCardSettings, entities: [HAEntity],
                      staleErrorSeconds: TimeInterval, cameraImage: Data? = nil,
                      taskImage: Data? = nil, supportsPictures: Bool = true,
                      sampledAt: Date? = nil) -> Self {
        func entity(_ id: String) -> HAEntity? {
            guard !id.isEmpty, let value = entities.first(where: { $0.entityId == id }),
                  text(value.state) != nil else { return nil }
            return value
        }
        let rawStatus = entity(config.statusEntityID)?.state ?? "unknown"
        let status = config.showStatus ? BambuStatusText.map(rawStatus) : ""
        let progress: Double? = config.showProgress ? entity(config.progressEntityID).flatMap {
            guard let value = Double($0.state), value.isFinite else { return nil }
            return min(max(value / 100, 0), 1)
        } : nil
        var metrics: [Metric] = []
        if config.showRemaining, let time = entity(config.selectedTimeEntityID) {
            let value: String?
            if config.timeDisplayMode == .endTime {
                value = text(ScreenRenderer.bambuCompactCanvasTimeText(time, mode: .endTime))
            } else if let amount = Double(time.state), amount.isFinite {
                let unit = time.unitOfMeasurement?.lowercased() ?? ""
                let multiplier: Double = ["s", "sec", "secs", "second", "seconds", "秒"].contains(unit) ? 1
                    : ["h", "hr", "hrs", "hour", "hours", "小时"].contains(unit) ? 3600 : 60
                value = duration(amount * multiplier)
            } else { value = nil }
            if let value {
                metrics.append(.init(label: config.timeDisplayMode == .endTime ? "预计完成" : "剩余时间",
                                     value: value, symbol: "clock"))
            }
        }
        if config.showTemperature {
            for (id, label, symbol) in [(config.nozzleTempEntityID, "喷嘴", "thermometer.medium"),
                                         (config.bedTempEntityID, "热床", "rectangle.bottomhalf.filled")] {
                if let temperature = entity(id), let value = Double(temperature.state), value.isFinite {
                    let unit = temperature.unitOfMeasurement ?? "°C"
                    metrics.append(.init(label: label, value: value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit,
                                         symbol: symbol))
                }
            }
        }
        let error = config.showError ? entity(config.errorEntityID).flatMap { value -> String? in
            guard !["normal", "ok", "0", "off", "无"].contains(value.state.lowercased()),
                  HAErrorCodePolicy.isFresh(entity: value, staleSeconds: staleErrorSeconds) else { return nil }
            return BambuHMSCode.reason(for: value.state) ?? value.state
        } : nil
        let pictures: [Picture] = config.showImage && supportsPictures ? [
            .init(kind: .camera, image: cameraImage.flatMap(NSImage.init(data:)),
                  placeholder: config.imageEntityID.isEmpty ? "未设置摄像头" : "等待摄像头快照"),
            .init(kind: .task, image: taskImage.flatMap(NSImage.init(data:)),
                  placeholder: config.taskImageEntityID.isEmpty ? "未设置任务封面" : "等待当前任务封面")
        ] : []
        return .init(brand: .bambu, usesBrandAccent: config.themeAccent == .bambuLab, status: status,
                     task: config.showTask ? entity(config.taskEntityID).flatMap { text($0.state) } : nil,
                     progress: progress, metrics: metrics, error: error, pictures: pictures,
                     pictureNotice: config.showImage && !supportsPictures ? "MQTT 不提供摄像头与任务封面" : nil,
                     sampledAt: sampledAt)
    }

    static func formlabs(_ snapshot: FormlabsSnapshot, connection: FormlabsConnectionSettings) -> Self {
        let job = snapshot.print
        let rawStatus = snapshot.device?.isConnected == false ? "offline"
            : job.flatMap { text($0.status) } ?? snapshot.device?.status ?? "unknown"
        var metrics: [Metric] = []
        if let value = duration((job?.estimatedTimeRemainingMS ?? snapshot.device?.estimatedPrintTimeRemainingMS).map { $0 / 1000 }) {
            metrics.append(.init(label: "剩余时间", value: value, symbol: "clock"))
        }
        if connection.showLayers, let current = job?.currentLayer, let total = job?.layerCount,
           current >= 0, total > 0 {
            metrics.append(.init(label: "层数", value: "\(current) / \(total)", symbol: "square.3.layers.3d"))
        }
        if connection.showMaterial, let material = job?.materialName,
           !FormlabsPrintInfo.isUnavailableMaterialName(material) {
            metrics.append(.init(label: "材料", value: material, symbol: "drop"))
        }
        var progress: Double?
        if let current = job?.currentLayer, let total = job?.layerCount, current >= 0, total > 0 {
            progress = min(max(Double(current) / Double(total), 0), 1)
        } else if let elapsed = job?.elapsedDurationMS, let total = job?.estimatedDurationMS,
                  elapsed.isFinite, total.isFinite, elapsed >= 0, total > 0 {
            progress = min(max(elapsed / total, 0), 1)
        }
        // A cached cloud error is not a new alert; keep it visibly attached to this reading.
        let error = snapshot.cloudError.flatMap(text) ?? job.flatMap { job -> String? in
            let state = job.status.lowercased()
            return state.contains("error") || state.contains("fail") ? text(job.message) : nil
        }
        let thumbnail = job.flatMap { FormlabsTaskCachePolicy.taskIdentity($0).isEmpty ? nil : snapshot.thumbnail }
        return .init(brand: .formlabs, usesBrandAccent: connection.useBrandAccent,
                     status: ScreenRenderer.formlabsStatusText(rawStatus),
                     task: job.flatMap { text($0.name) }, progress: progress, metrics: metrics,
                     error: error,
                     pictures: connection.showThumbnail ? [.init(kind: .task,
                        image: thumbnail.flatMap(NSImage.init(data:)), placeholder: "等待当前任务封面")] : [],
                     pictureNotice: nil,
                     sampledAt: snapshot.sampledAt)
    }
}

extension AppModel {
    @MainActor func controlCenterPrinterSnapshot(for source: DeviceControlCenterDataSource) -> ControlCenterPrinterSnapshot? {
        guard source.kind == .printer, case .managedDevice(let id) = source.destination,
              let device = settings.devices.first(where: { $0.id == id }), device.isEnabled else { return nil }
        switch device.type {
        case .formlabs:
            guard let connection = device.settings.formlabsConnection,
                  let snapshot = formlabsSnapshots[id], snapshot.hasData, let cached = snapshot.device else { return nil }
            let serial = connection.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serial.isEmpty, cached.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(serial) == .orderedSame else { return nil }
            return .formlabs(snapshot, connection: connection)
        case .bambuLab:
            let entities = device.settings.bambuDataSource == .localMQTT
                ? existingBambuMQTTEntities(for: id)
                : activeHADeviceID.flatMap { existingHASourceEntities(for: $0) }
            let config = BambuLabCardSettings.from(device)
            guard let entities, !config.statusEntityID.isEmpty,
                  entities.contains(where: { $0.entityId == config.statusEntityID }) else { return nil }
            let pictures = existingControlCenterBambuPictures(for: id)
            return .bambu(config, entities: entities,
                          staleErrorSeconds: TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60),
                          cameraImage: pictures.camera, taskImage: pictures.task,
                          supportsPictures: device.settings.bambuDataSource != .localMQTT,
                          sampledAt: device.settings.bambuDataSource == .localMQTT ? nil : haSnapshot.sampledAt)
        default: return nil
        }
    }
}

/// C6-inspired hierarchy, authored for the control center's three native grid sizes.
struct ControlCenterPrinterCard: View {
    let source: DeviceControlCenterDataSource
    let snapshot: ControlCenterPrinterSnapshot?
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    private var accent: Color { snapshot?.accent ?? .accentColor }

    var body: some View {
        Button(action: action) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 430
                let large = wide && geometry.size.height >= 520
                let compact = geometry.size.height < 330 || (large && geometry.size.height < 660)
                let inset: CGFloat = large ? (compact ? 18 : 26) : (compact ? 16 : 22)
                VStack(alignment: .leading, spacing: large ? (compact ? 12 : 20) : (compact ? 8 : 12)) {
                    header
                    if let snapshot {
                        if large { largeContent(snapshot, width: geometry.size.width - inset * 2, compact: compact) }
                        else if wide { mediumContent(snapshot, height: geometry.size.height - (compact ? 82 : 128), compact: compact) }
                        else { smallContent(snapshot, height: geometry.size.height, compact: compact) }
                    } else {
                        emptyContent
                    }
                    readingFooter
                }
                .padding(inset)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .frame(height: height)
            .controlCenterGlassCard(hovering: hovering)
        }
        .buttonStyle(ControlCenterCardButtonStyle())
        .onHover { hovering = $0 }
        .help(String(localized: "打开打印机设置"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.title)
        .accessibilityValue(accessibilityReading)
        .accessibilityHint(String(localized: "打开打印机设置"))
        .accessibilityIdentifier("control-center-printer-" + source.id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "printer.fill").foregroundStyle(accent)
            Text(source.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
    }

    private func smallContent(_ reading: ControlCenterPrinterSnapshot, height: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            if !reading.pictures.isEmpty {
                pictureGallery(reading, height: compact
                    ? min(76, max(54, height - (reading.error == nil ? 204 : 214)))
                    : height >= 520 ? min(230, height * 0.32) : 88)
            }
            if let task = reading.task {
                Text(task).font(.system(size: compact ? 13 : 14, weight: .semibold)).lineLimit(height >= 520 ? 2 : 1)
            }
            HStack(alignment: .firstTextBaseline) {
                status(reading, compact: compact)
                Spacer(minLength: 4)
                percentage(reading, size: compact ? 26 : 32)
            }
            progress(reading, compact: compact)
            metrics(reading, limit: 2, columns: 2, compact: compact)
            error(reading, lines: 1)
            pictureNotice(reading)
        }.frame(maxHeight: .infinity, alignment: .center)
    }

    private func mediumContent(_ reading: ControlCenterPrinterSnapshot, height: CGFloat, compact: Bool) -> some View {
        HStack(spacing: compact ? 14 : 24) {
            if !reading.pictures.isEmpty {
                pictureGallery(reading, height: max(120, height - 8), vertical: reading.pictures.count > 1)
                    .frame(width: compact ? min(150, height * 0.76) : min(215, max(155, height * 0.86)))
            }
            VStack(alignment: .leading, spacing: compact ? 7 : 11) {
                // At 360 pt the footer already names the brand. Sharing this row
                // leaves room for a two-line task, three metrics and an error.
                HStack(alignment: .firstTextBaseline) {
                    percentage(reading, size: compact ? 32 : 44)
                    Spacer(minLength: 8)
                    status(reading, compact: compact)
                }
                if let task = reading.task {
                    Text(task).font(.system(size: compact ? 15 : 20, weight: .semibold)).lineLimit(2)
                }
                progress(reading, compact: compact)
                metrics(reading, limit: compact ? 2 : 3, columns: compact ? 2 : 3, compact: compact)
                error(reading, lines: 1)
                pictureNotice(reading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity, alignment: .center)
    }

    private func largeContent(_ reading: ControlCenterPrinterSnapshot, width: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reading.brandTitle).font(.system(size: compact ? 15 : 17, weight: .semibold)).foregroundStyle(accent)
                    status(reading, compact: compact)
                }
                Spacer()
                percentage(reading, size: compact ? 44 : 62)
            }
            if !reading.pictures.isEmpty {
                pictureGallery(reading, height: compact ? min(170, max(92, height - 430)) : min(230, max(110, height - 580)))
                    .frame(width: width)
            }
            if let task = reading.task {
                Text(task).font(.system(size: compact ? 19 : 24, weight: .semibold)).lineLimit(2)
            }
            progress(reading, compact: compact)
            metrics(reading, limit: 3, columns: 3, compact: compact)
            error(reading, lines: 2)
            pictureNotice(reading)
        }.frame(maxHeight: .infinity, alignment: .center)
    }

    private func status(_ reading: ControlCenterPrinterSnapshot, compact: Bool = false) -> some View {
        Group {
            if !reading.status.isEmpty {
                Text(NSLocalizedString(reading.status, comment: "Printer status"))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, compact ? 7 : 9).padding(.vertical, compact ? 3 : 5)
                    .background(accent.opacity(0.12), in: Capsule())
            }
        }
    }

    private func percentage(_ reading: ControlCenterPrinterSnapshot, size: CGFloat) -> some View {
        Group {
            if let progress = reading.progress {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text((progress * 100).formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: size, weight: .semibold, design: .rounded))
                    Text("%").font(.system(size: max(11, size * 0.4), weight: .semibold)).foregroundStyle(.secondary)
                }.monospacedDigit().foregroundStyle(accent)
            }
        }
    }

    private func progress(_ reading: ControlCenterPrinterSnapshot, compact: Bool = false) -> some View {
        Group {
            if let progress = reading.progress {
                GeometryReader { geometry in
                    Capsule().fill(accent.opacity(0.14))
                        .overlay(alignment: .leading) {
                            Capsule().fill(accent).frame(width: geometry.size.width * progress)
                        }
                }.frame(height: compact ? 5 : 7).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func pictureGallery(_ reading: ControlCenterPrinterSnapshot, height: CGFloat,
                                              vertical: Bool = false) -> some View {
        // Roles remain independent. A missing task cover never borrows a camera
        // frame; camera snapshots are not described as a live video stream.
        let compactPictures = vertical ? height < 160 : height < 85
        let layout = vertical ? AnyLayout(VStackLayout(spacing: compactPictures ? 6 : 10)) : AnyLayout(HStackLayout(spacing: compactPictures ? 6 : 10))
        layout {
            ForEach(reading.pictures) { picture in
                ControlCenterPrinterPicture(picture: picture, accent: accent, compact: compactPictures)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(height: height)
    }

    @ViewBuilder private func pictureNotice(_ reading: ControlCenterPrinterSnapshot) -> some View {
        if let notice = reading.pictureNotice {
            Label(NSLocalizedString(notice, comment: "Printer picture availability"), systemImage: "photo")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func metrics(_ reading: ControlCenterPrinterSnapshot, limit: Int, columns: Int, compact: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: compact ? 6 : 12) {
            ForEach(Array(reading.metrics.prefix(limit))) { metric in
                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    Label(NSLocalizedString(metric.label, comment: "Printer metric"), systemImage: metric.symbol)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(metric.value).font(.system(size: 12, weight: .semibold)).lineLimit(compact ? 1 : 2).monospacedDigit()
                }
            }
        }
    }

    private func error(_ reading: ControlCenterPrinterSnapshot, lines: Int) -> some View {
        Group {
            if let error = reading.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(lines)
            }
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "printer").font(.system(size: 42, weight: .light)).foregroundStyle(.tertiary)
            Text(source.previewError == nil ? String(localized: "等待打印机读数") : String(localized: "连接失败"))
                .font(.title3.weight(.semibold))
            Text(source.previewError ?? String(localized: "连接数据源后显示状态、任务与进度"))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var readingFooter: some View {
        HStack {
            Text(source.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let snapshot {
                if let date = snapshot.sampledAt {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text("最近读取").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text(source.status).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var accessibilityReading: String {
        guard let snapshot else { return source.previewError ?? String(localized: "等待打印机读数") }
        var parts = [NSLocalizedString(snapshot.status, comment: "Printer status")]
        if let task = snapshot.task { parts.append(task) }
        if let progress = snapshot.progress { parts.append(progress.formatted(.percent.precision(.fractionLength(0)))) }
        parts += snapshot.metrics.map { NSLocalizedString($0.label, comment: "Printer metric") + ": " + $0.value }
        if let error = snapshot.error { parts.append(error) }
        parts += snapshot.pictures.map {
            NSLocalizedString($0.title, comment: "Printer picture role") + ": "
                + ($0.image == nil ? NSLocalizedString($0.placeholder, comment: "Printer picture availability")
                   : String(localized: "已读取"))
        }
        if let notice = snapshot.pictureNotice { parts.append(NSLocalizedString(notice, comment: "Printer picture availability")) }
        return parts.joined(separator: ", ")
    }
}

private struct ControlCenterPrinterPicture: View {
    let picture: ControlCenterPrinterSnapshot.Picture
    let accent: Color
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.055))
                    if let image = picture.image {
                        // Preserve the entire camera frame and model thumbnail,
                        // including models whose supports reach the image edge.
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: picture.symbol).font(.system(size: compact ? 17 : 20)).foregroundStyle(.secondary)
                            if !compact {
                                Text(NSLocalizedString(picture.placeholder, comment: "Printer picture availability"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }.padding(6)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Label(NSLocalizedString(picture.title, comment: "Printer picture role"), systemImage: picture.symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityHidden(true)
    }
}
