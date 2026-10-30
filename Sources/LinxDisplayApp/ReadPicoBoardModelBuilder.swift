import AppKit
import LinxDisplayCore

/// Reads the same cached source snapshots as every other Lingxi device. Never fetches credentials.
@MainActor enum ReadPicoBoardModelBuilder {
    typealias Module = ReadPicoBoardModel.Module
    typealias Metric = ReadPicoBoardModel.Metric
    typealias Row = ReadPicoBoardModel.Row

    static func build(board: ReadPicoLingxiBoardConfiguration, image: NSImage?, model: AppModel,
                      now: Date, boardID: String, excerpt: ReadPicoReadingCard?) throws -> ReadPicoBoardModel {
        try board.validate()
        var modules: [Module] = [], pictures: [(Int, NSImage)] = []
        func picture(_ bytes: Data?, at index: Int) {
            if let bytes, let image = NSImage(data: bytes) { pictures.append((index, image)) }
        }
        func metric(_ label: String, _ value: Double, _ unit: String = "") -> Metric {
            .init(label, value.isFinite ? String(format: value.rounded() == value ? "%.0f" : "%.1f", value) : "—", unit)
        }
        func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
        for raw in board.modules {
            guard let kind = CanvasModule(rawValue: raw) else { throw ReadPicoManagerError.invalid("画板含有未知模块。") }
            let index = modules.count
            var item = Module(kind: .text, id: "module-\(raw)")
            item.span = board.fullWidthModules.contains(raw) ? 2 : 1
            switch kind {
            case .clock, .date:
                item.kind = kind == .clock ? .clock : .date
                item.title = kind == .clock ? "时间" : "日期"
                item.timestamp = floor(now.timeIntervalSince1970 / 60) * 60
            case .cpu:
                item.kind = .cpu; item.title = "处理器"
                item.metrics = [metric("使用率", model.system.cpuPercent, "%")]
                item.progress = percent(model.system.cpuPercent)
            case .memory:
                item.kind = .memory; item.title = "内存"
                item.metrics = [metric("使用率", model.system.memoryPercent, "%")]
                item.rows = [.init("已使用", bytes(model.system.usedMemoryBytes)), .init("总内存", bytes(model.system.totalMemoryBytes))]
                item.progress = percent(model.system.memoryPercent)
            case .disk:
                item.kind = .disk; item.title = "磁盘"
                item.metrics = [metric("使用率", model.system.diskPercent, "%")]
                item.rows = [.init("已使用", bytes(model.system.usedDiskBytes)), .init("总空间", bytes(model.system.totalDiskBytes))]
                item.progress = percent(model.system.diskPercent)
            case .network:
                item.kind = .network; item.title = "网络"
                item.metrics = [metric("下载", model.system.downloadBytesPerSecond / 1024, "KB/s"), metric("上传", model.system.uploadBytesPerSecond / 1024, "KB/s")]
            case .nowPlaying:
                let value = model.nowPlaying
                item.mediaLayout = board.nowPlayingHorizontal ? .horizontal : .vertical
                item.kind = .nowPlaying; item.title = value.title; item.subtitle = value.artist; item.body = value.album
                item.duration = max(value.duration, 0); item.timestamp = max(value.sampledAt.timeIntervalSince1970, 0)
                item.progress = percent(value.progress * 100); item.running = value.isPlaying
                item.footer = value.isPlaying ? "正在播放" : "已暂停"
                if model.settings.canvasNowPlayingCover { picture(value.artwork, at: index) }
            case .pomodoro:
                let value = model.pomodoroSnapshot
                item.kind = .pomodoro; item.title = "番茄钟"; item.body = value.taskName
                item.duration = max(value.duration, 0); item.progress = percent(value.progress * 100)
                item.running = value.isRunning
                item.timestamp = max(now.timeIntervalSince1970, 0)
                item.metrics = [metric("剩余", ceil(value.remaining / 60), "分钟")]
                item.rows = [.init("已完成", "\(value.completedFocusSessions)"), .init("状态", value.isPaused ? "暂停" : value.isRunning ? "进行中" : "就绪")]
            case .uptime:
                item.kind = .uptime; item.title = "运行时间"; item.duration = max(model.system.uptime, 0)
                item.timestamp = max(model.system.sampledAt.timeIntervalSince1970, 0)
                item.body = "\(Int(max(model.system.uptime, 0)) / 3600) 小时 \(Int(max(model.system.uptime, 0)) / 60 % 60) 分钟"
            case .text:
                item.title = "文字"; item.body = board.text
            case .image:
                guard let image else { throw ReadPicoManagerError.invalid("图片模块缺少原图，请先选择图片。") }
                item.kind = .image; pictures.append((index, image))
            case .qwenQuota:
                let value = model.qwenQuota
                item.kind = .qwenQuota; item.title = "千问办公"; item.subtitle = value.plan ?? ""
                if value.available {
                    item.metrics = [metric("剩余额度", value.remainingCredits, value.unit)]
                    item.rows = Array(value.segments.prefix(24)).map { .init($0.id, "\($0.remaining) \($0.unit)") }
                    item.progress = percent(value.progress * 100)
                } else { item.body = "尚未读取到额度" }
            case .codex:
                let value = model.usage
                item.kind = .codex; item.title = value.sourceName ?? "Codex"; item.subtitle = value.planType ?? ""
                if value.isAvailable {
                    item.metrics = [.init(value.windowTitle, "\(value.remainingPercent)", "%")]
                    item.progress = percent(Double(value.remainingPercent))
                    item.rows = [.init("可用重置", "\(value.availableResetCount)")]
                    if let reset = value.resetDate { item.rows.append(.init("下次重置", stamp(reset))) }
                } else { item.body = "尚未读取到额度" }
            case .grokBot:
                let value = model.grokBotUsage
                item.kind = .grokBot; item.title = "Grok 状态"; item.subtitle = value.planLabel ?? ""
                item.footer = "状态显示 · 本版暂不支持动画"
                if value.isAvailable, let remaining = value.remainingPercent {
                    item.metrics = [.init("本周剩余", "\(remaining)", "%")]; item.progress = percent(Double(remaining))
                } else { item.body = value.message.isEmpty ? "尚未读取" : value.message }
                if let reset = value.resetDate { item.rows.append(.init("下次重置", stamp(reset))) }
                if let count = value.availableBankedResetCount { item.rows.append(.init("可用重置", "\(count)")) }
            case .oracleText:
                item.kind = .oracleText; item.title = "先知"; item.body = ScreenRenderer.rotatingOracleText(now)
            case .readingExcerpt:
                item.kind = .readingExcerpt; item.title = excerpt?.sourceTitle ?? "阅读摘录"
                item.body = excerpt.map { value in
                    [value.body, value.note.map { "批注：" + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                } ?? "请先同步阅读笔记，并授权此设备显示。"
            case .sspai:
                item.kind = .sspai; item.title = "少数派"
                item.rows = model.sspaiArticles.prefix(6).map { .init($0.author, $0.title) }
                if item.rows.isEmpty { item.body = "尚未获取文章" }
            case .homeAssistant:
                item.kind = .homeAssistant; item.title = "Home Assistant"
                let value = model.haSnapshot.selecting(entityIDs: board.entityIDs)
                item.rows = value.selectedEntities.map { .init(value.aliases[$0.entityId] ?? $0.displayName, $0.displayValue) }
                for id in value.missingEntityIDs { item.rows.append(.init(value.aliases[id] ?? id, "不可用")) }
                item.footer = value.errorText ?? ""
                if item.rows.isEmpty { item.body = "请在画板中选择要显示的实体" }
                if let entity = value.selectedEntities.first(where: { value.images[$0.entityId] != nil }) { picture(value.images[entity.entityId], at: index) }
            case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
                item.kind = .bambuLab; item.title = "Bambu Lab"
                if let panel = Panel.bambuPanel(forSlotIndex: raw - CanvasModule.bambuLab.rawValue), let device = model.bambuDevice(for: panel) {
                    item.id = device.id.uuidString; item.title = device.name
                    let value = device.settings
                    let bindings: [(String, String?)] = [("状态", value.bambuStatusEntityID), ("任务", value.bambuTaskEntityID), ("进度", value.bambuProgressEntityID), ("喷嘴", value.bambuNozzleTempEntityID), ("热床", value.bambuBedTempEntityID), ("剩余时间", value.bambuRemainingEntityID), ("错误", value.bambuErrorEntityID)]
                    for (label, id) in bindings {
                        if let id, let entity = model.haSnapshot.entities.first(where: { $0.entityId == id }) {
                            item.rows.append(.init(label, entity.displayValue))
                            if label == "进度", let value = Double(entity.state) { item.progress = percent(value) }
                        }
                    }
                    let art = value.bambuTaskImageEntityID ?? value.bambuImageEntityID
                    if let art { picture(model.haSnapshot.images[art], at: index) }
                }
                if item.rows.isEmpty { item.body = "等待打印机数据" }
            case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
                item.kind = .formlabs; item.title = "Formlabs"
                let slot = raw - CanvasModule.formlabs.rawValue, values = model.formlabsCanvasItems()
                if values.indices.contains(slot) {
                    let value = values[slot], snapshot = value.snapshot
                    item.title = value.deviceName; item.body = snapshot.print?.name ?? ""
                    item.subtitle = snapshot.print?.status ?? snapshot.device?.status ?? "等待数据"
                    if let progress = snapshot.print?.progress { item.progress = percent(progress * 100) }
                    item.footer = snapshot.cloudError ?? ""
                    if value.connection.showLayers, let current = snapshot.print?.currentLayer, let total = snapshot.print?.layerCount { item.rows.append(.init("层数", "\(current) / \(total)")) }
                    if value.connection.showMaterial, let material = snapshot.print?.materialName { item.rows.append(.init("材料", material)) }
                    if let remaining = snapshot.print?.estimatedTimeRemainingMS ?? snapshot.device?.estimatedPrintTimeRemainingMS { item.rows.append(.init("剩余时间", "\(remaining / 60000) 分钟")) }
                    if value.connection.showThumbnail { picture(snapshot.thumbnail, at: index) }
                    if let device = model.formlabsDevice(for: kind) { item.id = device.id.uuidString }
                } else { item.body = "请先添加打印机" }
            case .weather:
                item.kind = .weather; item.title = "天气"
                if let value = model.settings.weatherSnapshot, value.matches(model.settings.weather) {
                    item.title = value.city; item.subtitle = value.description; item.body = value.advice
                    item.metrics = [metric("温度", value.temperature, "°C"), metric("体感", value.apparent, "°C")]
                    item.rows = [.init("最低 / 最高", "\(value.low) / \(value.high) °C"), .init("降水概率", "\(value.rainProbability)%")]
                    item.footer = "更新于 " + stamp(value.updatedAt)
                } else { item.body = "尚未获取天气" }
            case .cloudflare:
                let config = model.settings.cloudflare, language = config.displayLanguage
                item.kind = .cloudflare; item.title = "Cloudflare"
                item.presentation = config.presentation == .worldMap ? .worldMap : .ranking
                item.rankMetric = config.rankByTraffic ? .traffic : .requests
                item.subtitle = config.domainLetterCase.display(config.hostname.isEmpty ? config.zoneName : config.hostname)
                if let value = model.settings.cloudflareSnapshot, value.matches(config) {
                    item.regions = value.rankedRegions(byTraffic: config.rankByTraffic).prefix(250).map {
                        .init(code: $0.code.uppercased(), value: config.rankByTraffic ? $0.bytes : $0.requests)
                    }
                    item.metrics = [.init(language.text("请求", "Requests"), language.countText(value.requests)), .init(language.text("流量", "Traffic"), language.bytesText(value.bytes))]
                    item.rows = value.rankedRegions(byTraffic: config.rankByTraffic).prefix(24).map { .init(language.regionName($0.code), config.rankByTraffic ? language.bytesText($0.bytes) : language.countText($0.requests)) }
                    item.series = Array(value.trend.suffix(60)).map { config.rankByTraffic ? $0.bytes : $0.requests }.map { $0.isFinite ? max($0, 0) : 0 }
                    item.footer = stamp(value.start) + " — " + stamp(value.end)
                } else { item.body = language.text("等待网站统计", "Waiting for analytics") }
            case .excerptText:
                throw ReadPicoManagerError.invalid("此摘录模块未开放给 Pico，请使用阅读摘录。")
            }
            item.title = clipped(item.title, 192); item.subtitle = clipped(item.subtitle, 384)
            item.body = clipped(item.body, 8192); item.footer = clipped(item.footer, 384)
            item.metrics = Array(item.metrics.prefix(8)).map { .init(clipped($0.label, 96), clipped($0.value, 96), clipped($0.unit, 32)) }
            item.rows = Array(item.rows.prefix(24)).map { .init(clipped($0.label, 96), clipped($0.value, 256)) }
            modules.append(item)
        }
        guard pictures.count <= 8 else { throw ReadPicoManagerError.invalid("每张数据画板最多包含 8 张图片素材。") }
        let side = min(128, Int(sqrt(Double(65_536 / max(pictures.count, 1)))))
        var assets: [ReadPicoBoardModel.Asset] = []
        for (index, image) in pictures {
            let asset = try makeAsset(image, maximumSide: side)
            modules[index].asset = asset.id
            if let existing = assets.first(where: { $0.id == asset.id }),
               existing.width != asset.width || existing.height != asset.height {
                throw ReadPicoManagerError.invalid("图片素材尺寸发生冲突，请调整图片后重试。")
            }
            if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
        }
        let needsMap = modules.contains { $0.kind == .cloudflare && $0.presentation == .worldMap }
        let worldMap = needsMap ? try ReadPicoBoardMapResource.data().base64EncodedString() : nil
        let result = ReadPicoBoardModel(boardID: clipped(boardID, 64), generatedAt: now.timeIntervalSince1970,
                                        columns: board.columns, dark: board.darkBackground, textScale: board.rasterScale, worldMap: worldMap, modules: modules, assets: assets)
        try ReadPicoNativeBoardRenderer.validate(result.encoded()); return result
    }
    private static func percent(_ value: Double) -> Double? { value.isFinite ? min(max(value, 0), 100) : nil }
    private static func stamp(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date) }
    private static func clipped(_ text: String, _ limit: Int) -> String {
        let safe = text.replacingOccurrences(of: "\0", with: "")
        guard safe.utf8.count > limit else { return safe }
        var result = ""
        for character in safe { if result.utf8.count + String(character).utf8.count > limit - 3 { break }; result.append(character) }
        return result + "…"
    }
    private static func makeAsset(_ image: NSImage, maximumSide: Int) throws -> ReadPicoBoardModel.Asset {
        var bounds = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { throw ReadPicoManagerError.invalid("无法读取画板图片素材。") }
        let scale = min(1, Double(maximumSide) / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard rendered else { throw ReadPicoManagerError.invalid("图片灰阶转换失败。") }
        let stride = (width + 1) / 2
        var packed = Data(repeating: 255, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let shade = UInt8((Int(pixels[y * width + x]) + 8) / 17), offset = y * stride + x / 2
            if x % 2 == 0 { packed[offset] = (shade << 4) | 15 } else { packed[offset] = (packed[offset] & 240) | shade }
        } }
        return .init(width: width, height: height, pixels: packed)
    }
}
