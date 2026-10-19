import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinxDisplayCore

func testC6SharedRenderer() throws {
    let weatherTime = Date(timeIntervalSince1970: 1_791_453_000)
    let zone = TimeZone(secondsFromGMT: 28_800)!
    let snapshot = WeatherSnapshot(city: "上海", temperature: 26, apparent: 27,
        low: 21, high: 28, rainProbability: 10, code: 0, updatedAt: weatherTime)
    let weather = C6LocalRenderer.weatherFrame(snapshot, city: "上海", now: weatherTime, timeZone: zone)
    let entities: [HAEntity] = [
        .init(entityId: "sensor.room", friendlyName: "客厅空气温度传感器", state: "24.6", unitOfMeasurement: "°C"),
        .init(entityId: "sensor.humidity", friendlyName: "Bedroom humidity", state: "53", unitOfMeasurement: "%"),
        .init(entityId: "light.desk", friendlyName: "书房氛围照明", state: "on", unitOfMeasurement: nil),
        .init(entityId: "sensor.long", friendlyName: "长状态设备示例", state: "服务器状态不可用", unitOfMeasurement: nil)
    ]
    // Availability differs from state normalization: the last sample represents
    // cached, unavailable server data and therefore uses the secondary ink.
    var unavailable = entities
    unavailable[3].state = "unavailable"
    let entityFrame = C6LocalRenderer.entitiesFrame(entities)
    checkEqual(entityFrame.count, 115_200, "C6 HA frame fixed canonical bytes")
    check(entityFrame != C6LocalRenderer.entitiesFrame(Array(entities.prefix(1))), "HA 1/4 use adapted but shared layout")
    check(entityFrame != C6LocalRenderer.entitiesFrame(Array(entities.prefix(2))), "HA 2/4 grid is distinct")
    check(C6LocalRenderer.entitiesFrame(unavailable) != entityFrame, "Unavailable entity status is distinguished")

    let printerEntities: [HAEntity] = [
        .init(entityId: "sensor.status", friendlyName: "", state: "PRINTING", unitOfMeasurement: nil),
        .init(entityId: "sensor.task", friendlyName: "", state: "长文件名测试 双层收纳结构打印项目", unitOfMeasurement: nil),
        .init(entityId: "sensor.progress", friendlyName: "", state: "67", unitOfMeasurement: nil),
        .init(entityId: "sensor.remaining", friendlyName: "", state: "92", unitOfMeasurement: nil)
    ]
    let settings = BambuLabCardSettings(name: "工作室 X2D", statusEntityID: "sensor.status",
        progressEntityID: "sensor.progress", taskEntityID: "sensor.task", remainingEntityID: "sensor.remaining")
    var thumbnail = Data(count: 80 * 80 * 2)
    thumbnail.withUnsafeMutableBytes { buffer in
        let b = buffer.bindMemory(to: UInt8.self)
        for i in 0..<(80 * 80) {
            let color = ((UInt16((i % 80) * 3) & 248) << 8)
                | ((UInt16((i / 80) * 3) & 252) << 3) | 16
            b[i * 2] = UInt8(color >> 8); b[i * 2 + 1] = UInt8(color & 255)
        }
    }
    let printer = C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities, thumbnailRGB565: thumbnail)
    check(printer != C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities), "Shared printer static cover changes actual frame")
    var noImage = settings; noImage.showImage = false
    checkEqual(C6LocalRenderer.printerFrame(settings: noImage, entities: printerEntities, thumbnailRGB565: thumbnail),
        C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities), "Disabled task cover releases image region")
    var invalid = printerEntities; invalid[2].state = "NaN"
    checkEqual(C6LocalRenderer.printerFrame(settings: settings, entities: invalid).count, 115_200, "Invalid numeric states cannot trap")
    let heroPercentage = C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities, cardStyle: .percentage)
    let heroRemaining = C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities, cardStyle: .remaining)
    check(heroPercentage != printer && heroRemaining != heroPercentage, "All three local printer layouts are distinct")
    checkEqual(heroPercentage, C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities,
        thumbnailRGB565: thumbnail, cardStyle: .percentage), "Hero percentage never reserves task cover")
    checkEqual(heroRemaining, C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities,
        thumbnailRGB565: thumbnail, cardStyle: .remaining), "Hero remaining never reserves task cover")
    check(heroRemaining != C6LocalRenderer.printerFrame(settings: settings, entities: Array(printerEntities.prefix(3)),
        cardStyle: .remaining), "Missing remaining duration shows unavailable rather than zero")
    check(heroPercentage != C6LocalRenderer.printerFrame(settings: settings, entities: invalid,
        cardStyle: .percentage), "Missing progress shows unavailable rather than fictitious zero")
    check(weather != C6LocalRenderer.weatherFrame(snapshot, city: "上海", now: weatherTime, timeZone: zone,
        language: .english), "Weather fixed labels follow device language")
    check(weather != C6LocalRenderer.weatherFrame(snapshot, city: "上海", now: weatherTime, timeZone: zone,
        digitStyle: .aerospace), "Weather hero temperature uses selected aerospace numerals")
    let overviewRows = [C6PrinterSummary(name: "用户自定义 Form 4", status: "PRINTING", progress: 67, connected: true, formlabs: true),
                        C6PrinterSummary(name: "用户自定义 X2D", status: "IDLE", progress: nil, connected: true)]
    let overview = C6LocalRenderer.printerOverviewFrame(overviewRows)
    checkEqual(overview.count, 115_200, "Mixed-brand overview remains one complete canonical frame")
    check(overview != C6LocalRenderer.printerOverviewFrame(Array(overviewRows.reversed())), "Overview order and names come from real supplied rows")
    var disconnected = overviewRows; disconnected[0].connected = false
    check(overview != C6LocalRenderer.printerOverviewFrame(disconnected), "Overview disconnect state is visible")

    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12, minute: 34, second: 56))!
    let clock = C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone)
    let rounded = C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone, style: .rounded)
    checkEqual(rounded.count, 115_200, "Rounded clock native frame is complete")
    check(rounded != clock, "Optional rounded clock differs from legacy flip")
    checkEqual(clock, C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone, style: .flip), "Explicit flip preserves legacy pixels")
    check(clock != C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone, language: .english), "Clock fixed labels follow local language")
    check(clock != C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone, digitStyle: .aerospace), "Flip-clock hero numerals support aerospace choice")
    checkEqual(rounded, C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone, style: .rounded,
        digitStyle: .aerospace), "Rounded clock geometry is independent of other hero-digit style")
    check(rounded != C6LocalRenderer.clockFrame(now: date.addingTimeInterval(1), timeZone: calendar.timeZone, style: .rounded), "Native seconds advance in rounded clock")
    let calibratedRound = C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone,
        style: .rounded, saturationPercent: 150, contrastPercent: 125)
    checkEqual(calibratedRound, try AIMacScreenSupport.encodeRGB565(AIMacColorCalibration.apply(
        to: C6LocalRenderer.image(fromRGB565: rounded)!, saturationPercent: 150, contrastPercent: 125)),
        "Rounded clock preview matches device color calibration")
    checkEqual(clock, C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone,
        style: .flip, saturationPercent: 150, contrastPercent: 125), "Existing native flip colors remain unchanged")
    let old = date.addingTimeInterval(-56), next = old.addingTimeInterval(60)
    checkEqual(C6LocalRenderer.clockFrame(now: next, timeZone: calendar.timeZone, previous: old, progress: 0),
               C6LocalRenderer.clockFrame(now: old, timeZone: calendar.timeZone), "Flip p0 exactly prior frame")
    checkEqual(C6LocalRenderer.clockFrame(now: next, timeZone: calendar.timeZone, previous: old, progress: 1),
               C6LocalRenderer.clockFrame(now: next, timeZone: calendar.timeZone), "Flip p1 exactly new frame")
    check(C6LocalRenderer.clockFrame(now: next, timeZone: calendar.timeZone, previous: old, progress: 0.5)
          != C6LocalRenderer.clockFrame(now: next, timeZone: calendar.timeZone), "Flip midpoint has real fold geometry")
    check(C6LocalRenderer.image(fromRGB565: Data()) == nil, "Reject truncated canonical frame")
    checkEqual(try AIMacScreenSupport.encodeRGB565(C6LocalRenderer.image(fromRGB565: weather)!), weather,
               "CGImage preview roundtrip preserves every RGB565 pixel")
    for (saturation, contrast) in [(50, 75), (100, 100), (150, 125), (200, 150)] {
        let shared = C6LocalRenderer.weatherFrame(snapshot, city: "上海", now: weatherTime, timeZone: zone,
            saturationPercent: saturation, contrastPercent: contrast)
        let image = AIMacColorCalibration.apply(to: C6LocalRenderer.image(fromRGB565: weather)!,
            saturationPercent: saturation, contrastPercent: contrast)
        checkEqual(shared, try AIMacScreenSupport.encodeRGB565(image), "Portable calibration matches Mac 14-bit algorithm \(saturation)/\(contrast)")
    }

    let lock = NSLock(); var mismatches = 0
    DispatchQueue.concurrentPerform(iterations: 24) { index in
        let actual = index % 2 == 0
            ? C6LocalRenderer.weatherFrame(snapshot, city: "上海", now: weatherTime, timeZone: zone)
            : C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities, thumbnailRGB565: thumbnail)
        if actual != (index % 2 == 0 ? weather : printer) { lock.lock(); mismatches += 1; lock.unlock() }
    }
    checkEqual(mismatches, 0, "Concurrent C6 previews never share mutable font/frame state")
    if let path = ProcessInfo.processInfo.environment["LINGXI_C6_SHARED_FIXTURE_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        for (name, actual) in [("sunny", weather), ("entities4-shared", entityFrame), ("printer-all-fields", printer), ("flip-clock", clock), ("round-clock", rounded)] {
            checkEqual(actual, try Data(contentsOf: folder.appendingPathComponent("\(name).rgb565")),
                       "Swift and actual firmware adapter pixels agree: \(name)")
        }
    }
    if let path = ProcessInfo.processInfo.environment["LINGXI_C6_PREVIEW_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func save(_ image: CGImage, _ name: String) throws {
            let url = folder.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw C6StandaloneError.invalidConfiguration }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw C6StandaloneError.invalidConfiguration }
        }
        let sourceImage = C6LocalRenderer.image(fromRGB565: printer)!
        try save(C6LocalRenderer.image(fromRGB565: rounded)!, "round-clock")
        try save(C6LocalRenderer.image(fromRGB565: clock)!, "flip-clock")
        try save(C6LocalRenderer.image(fromRGB565: heroPercentage)!, "unified-printer-percentage")
        try save(C6LocalRenderer.image(fromRGB565: heroRemaining)!, "unified-printer-remaining")
        try save(C6LocalRenderer.image(fromRGB565: overview)!, "unified-mixed-printer-overview")
        try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.clockFrame(now: date, timeZone: calendar.timeZone,
            language: .english, digitStyle: .aerospace))!, "unified-clock-english-aerospace")
        try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.weatherFrame(snapshot, city: "Shanghai", now: weatherTime,
            timeZone: zone, language: .english, digitStyle: .aerospace))!, "unified-weather-english-aerospace")
        try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.printerFrame(settings: settings, entities: printerEntities,
            language: .english, digitStyle: .aerospace, cardStyle: .percentage))!, "unified-printer-english-aerospace")
        let pictureData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(pictureData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, sourceImage, nil); check(CGImageDestinationFinalize(destination), "C6 fixture PNG encoded")
        let media: [HAEntity] = [
            .init(entityId: "camera.preview", friendlyName: "工作室摄像头", state: "idle", unitOfMeasurement: nil),
            .init(entityId: "image.preview", friendlyName: "打印任务封面", state: "available", unitOfMeasurement: nil)
        ] + Array(entities.prefix(2))
        let images = ["camera.preview": pictureData as Data, "image.preview": pictureData as Data]
        let idle = PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "", remaining: 0, duration: 0, completedFocusSessions: 0)
        let form = FormlabsSnapshot(device: .init(id: "Form-123", status: "printing", isConnected: true),
            print: .init(name: "打印任务 双层收纳盒", status: "printing", currentLayer: 120, layerCount: 320,
                         estimatedTimeRemainingMS: 5_520_000, materialName: "Clear V5"), thumbnail: pictureData as Data)
        for (name, theme) in [("light", CardTheme.minimalLight), ("dark", CardTheme.deepSpace)] {
            let palette = ScreenThemes.get(theme)
            var app = AppSettings(); app.cardRenderingMode = .classic
            var fields = settings; fields.imageEntityID = "camera.preview"; fields.taskImageEntityID = "image.preview"
            try save(ScreenRenderer.renderAIMacBambuCard(fields, entities: printerEntities,
                cameraImage: pictureData as Data, taskCoverImage: pictureData as Data,
                settings: app, sampledAt: date, palette: palette), "online-bambu-" + name)
            try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.printerFrame(settings: fields,
                entities: printerEntities, palette: palette, dataUpdatedAt: date,
                cameraImage: pictureData as Data, taskCoverImage: pictureData as Data))!, "local-bambu-" + name)
            let ha = HASnapshot(entities: media, selectedEntities: media, sampledAt: date, images: images)
            try save(ScreenRenderer.renderDeviceCanvas(modules: [.homeAssistant], system: .empty,
                nowPlaying: .sample, pomodoro: idle, customText: "", settings: app, ha: ha,
                now: date, width: 240, height: 240, palette: palette, optimizeForEInk: false), "online-ha-" + name)
            try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.entitiesFrame(media, palette: palette, images: images))!, "local-ha-" + name)
            try save(ScreenRenderer.renderDeviceCanvas(modules: [.formlabs], system: .empty,
                nowPlaying: .sample, pomodoro: idle, customText: "", settings: app,
                formlabsItems: [.init(deviceName: "工作室 Form 4", connection: .init(), snapshot: form)],
                now: date, width: 240, height: 240, palette: palette, optimizeForEInk: false), "online-formlabs-" + name)
            try save(C6LocalRenderer.image(fromRGB565: C6LocalRenderer.formlabsFrame(name: "工作室 Form 4",
                configuration: .init(), snapshot: form, palette: palette))!, "local-formlabs-" + name)
        }
    }
    print("  C6 shared fonts/layouts, exact calibration, native folds and concurrent isolation passed")
}

func testC6FlipClockAndOrientation() throws {
    var config = AIMacScreenDeviceSettings()
    config.mode = .clock
    let now = Date(timeIntervalSince1970: 1_735_689_600)
    let flip = try AIMacScreenSupport.render(settings: config, system: .empty,
                                            now: now, c6FlipClock: true)
    let original = try AIMacScreenSupport.render(settings: config, system: .empty, now: now)
    let bytes = try AIMacScreenSupport.encodeRGB565(flip)
    checkEqual(flip.width, 240, "C6 翻页钟原生宽度")
    checkEqual(flip.height, 240, "C6 翻页钟原生高度")
    check(bytes != (try AIMacScreenSupport.encodeRGB565(original)), "C6 翻页钟独立于原 ESP8266 样式")
    config.rotate180 = true
    let rotatedSetting = try AIMacScreenSupport.render(settings: config, system: .empty,
                                                       now: now, c6FlipClock: true)
    checkEqual(try AIMacScreenSupport.encodeRGB565(rotatedSetting), bytes,
               "C6 软件预览保持正向，由固件处理旋转")
    check(!AIMacScreenSupport.needsSoftwareRotation(deviceType: .c6Screen, rotate180: true,
                                                   isNativeClock: false), "C6 软件推图不重复翻转")
    check(!AIMacScreenSupport.needsSoftwareRotation(deviceType: .keyboard, rotate180: true,
                                                   isNativeClock: false), "C6 屏幕方向不影响灵犀68推送")
    check(AIMacScreenSupport.needsSoftwareRotation(deviceType: .aiMacScreen, rotate180: true,
                                                  isNativeClock: false), "旧 ESP8266 图片旋转行为保留")
    check(!AIMacScreenSupport.needsSoftwareRotation(deviceType: .aiMacScreen, rotate180: true,
                                                   isNativeClock: true), "设备端时钟不重复旋转")
    let info = Data("""
    {"device":"lingxi-esp32-c6-screen","screen":{"width":240,"height":240},
     "rotation_api":{"path":"/api/rotation","device_rendered":true},"rotation":180}
    """.utf8)
    let capabilities = try AIMacScreenSupport.parseCapabilities(data: info, host: "192.168.1.88")
    checkEqual(capabilities.rotationURL?.path, "/api/rotation", "C6 固件屏幕方向接口可识别")
    checkEqual(capabilities.displayRotation, 180, "读取当前物理屏幕方向")
    let request = capabilities.rotationURL.flatMap {
        AIMacScreenSupport.displayRotationRequest(url: $0, rotate180: true)
    }
    checkEqual(request?.httpMethod, "POST", "旋转通过设备控制请求生效")
    checkEqual(request?.url?.query, "rotation=180", "旋转控制不修改传输图片内容")
    for angle in [0, 90, 180, 270] {
        let rotatedInfo = Data("""
        {"device":"lingxi-esp32-c6-screen","screen":{"width":240,"height":240},
         "rotation_api":{"path":"/api/rotation","device_rendered":true},"rotation":\(angle),
         "ui_options":true,"rotations":[0,90,180,270],"languages":[0,1],"digit_styles":[0,1],
         "printer_card_styles":[0,1,2],"printer_overview":true}
        """.utf8)
        let updated = try AIMacScreenSupport.parseCapabilities(data: rotatedInfo, host: "192.168.1.88")
        checkEqual(updated.displayRotation, angle, "设备能力读取完整四档屏幕方向")
        check(updated.c6StandaloneCapabilities.uiOptions && updated.c6StandaloneCapabilities.printerOverview,
            "新 UI 与总览能力来自显式协议声明")
        let rotationRequest = updated.rotationURL.flatMap { AIMacScreenSupport.displayRotationRequest(url: $0, rotation: angle) }
        checkEqual(rotationRequest?.url?.query, "rotation=\(angle)", "四档旋转不修改软件图像")
    }
    check(AIMacScreenSupport.displayRotationRequest(url: capabilities.rotationURL!, rotation: 45) == nil,
        "软件拒绝任意角度")
    let next = try AIMacScreenSupport.render(settings: config, system: .empty,
                                            now: now.addingTimeInterval(60), c6FlipClock: true)
    check(bytes != (try AIMacScreenSupport.encodeRGB565(next)), "本地分钟改变后翻页数字更新")
    if let path = ProcessInfo.processInfo.environment["LINGXI_C6_PREVIEW_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("c6-flip-clock.png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, flip, nil)
            check(CGImageDestinationFinalize(destination), "C6 翻页钟预览图片可生成")
        }
    }
    print("  C6 翻页钟预览与固件层方向隔离通过")
}
