import Foundation
import CoreGraphics
import AppKit
import LinxDisplayCore

func testReadPicoBoardModel() async throws {
    let bytes = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
    let asset = ReadPicoBoardModel.Asset(width: 4, height: 4, pixels: bytes)
    let clock = ReadPicoBoardModel.Module(kind: .clock, id: "clock", timestamp: 1_700_000_000)
    var original = ReadPicoBoardModel(boardID: "fixture", generatedAt: 1_700_000_000,
        modules: [clock, .init(kind: .cloudflare, id: "cf", title: "Cloudflare", subtitle: "EXAMPLE.COM",
            metrics: [.init("请求", "12345"), .init("流量", "64", "MB")], rows: [.init("中国", "42 MB")], series: [0, 12, 3, 20]),
            .init(kind: .image, id: "image", asset: asset.id)], assets: [asset])
    original.textScale = 4
    original.modules[1].span = 2
    original.modules[1].presentation = .worldMap
    original.modules[1].rankMetric = .traffic
    original.modules[1].regions = [.init(code: "CN", value: 42_000_000), .init(code: "US", value: 22_000_000)]
    let mapData = try ReadPicoBoardMapResource.data()
    original.worldMap = mapData.base64EncodedString()
    let data = try original.encoded()
    check(data.count < 16_384, "数据画板不携带横竖整屏BMP")
    checkEqual(try ReadPicoBoardModel.decode(data), original, "结构化模型完整往返")
    check(ReadPicoBoardModel.isModel(data), "JSON模型被正确识别")
    check(!ReadPicoBoardModel.isModel(Data([0x42, 0x4d])), "BMP不被当成模型")
    var later = original; later.generatedAt += 30; later.modules[0].timestamp! += 60; later.modules[0].body = "12:01"
    checkEqual(try original.semanticData(), try later.semanticData(), "生成时刻与本机时钟不触发重复推送")
    later.modules[1].metrics[0].value = "12346"
    check(try original.semanticData() != later.semanticData(), "真实数据变化会触发推送")
    func rejected(_ value: ReadPicoBoardModel, _ message: String) {
        do { _ = try value.encoded(); check(false, message) } catch { check(true, message) }
    }
    var invalid = original; invalid.modules.append(clock); rejected(invalid, "拒绝重复模块ID")
    invalid = original; invalid.worldMap = nil; rejected(invalid, "全球热区不能遗漏地图资源")
    invalid = original; invalid.worldMap = Data(repeating: 0, count: 8193).base64EncodedString(); rejected(invalid, "地图资源不能超过8KiB")
    invalid = original; invalid.worldMap! += "\n"; rejected(invalid, "地图资源必须使用规范base64")
    invalid = original; invalid.modules[1].presentation = .ranking; rejected(invalid, "地区排行不携带无用地图")
    invalid = original; invalid.textScale = 5; rejected(invalid, "拒绝未知字号偏好")
    invalid = original; invalid.modules[0].span = 3; rejected(invalid, "拒绝未知跨列偏好")
    invalid = original; invalid.modules[1].regions = [.init(code: "CN", value: -.infinity)]; rejected(invalid, "拒绝非法地区数值")
    invalid = original; invalid.modules[1].regions = [.init(code: "中国", value: 1)]; rejected(invalid, "地区码必须使用ASCII")
    invalid = original; invalid.modules[1].regions = Array(repeating: .init(code: "US", value: 1), count: 251); rejected(invalid, "拒绝过量地区")
    invalid = original; invalid.modules[1].regions = [.init(code: "CN", value: 1), .init(code: "CN", value: 2)]; rejected(invalid, "拒绝重复地区码")
    invalid = original; invalid.modules[1].regions = [.init(code: "CN", value: 1e31)]; rejected(invalid, "拒绝超过地区数值上限")
    invalid = original; invalid.modules[0].presentation = .ranking; rejected(invalid, "Cloudflare样式不能注入其他模块")
    invalid = original; invalid.modules[0].mediaLayout = .vertical; rejected(invalid, "封面布局只适用于正在播放")
    invalid = original; invalid.schema = 2; rejected(invalid, "拒绝未知schema")
    invalid = original; invalid.columns = 3; rejected(invalid, "拒绝未知列数")
    invalid = original; invalid.modules[0].body = String(repeating: "字", count: 2731); rejected(invalid, "长度按UTF8字节限制")
    invalid = original; invalid.modules[0].title = "bad\0value"; rejected(invalid, "拒绝NUL字符")
    invalid = original; invalid.modules[0].series = [.nan]; rejected(invalid, "拒绝非有限图表数据")
    invalid = original; invalid.modules[0].progress = 101; rejected(invalid, "拒绝越界进度")
    invalid = original; invalid.modules[0].rows = Array(repeating: .init("a", "b"), count: 25); rejected(invalid, "拒绝过长行列表")
    invalid = original; invalid.assets[0].data = Data(repeating: 0, count: 8).base64EncodedString(); rejected(invalid, "拒绝资产hash不符")
    invalid = original; invalid.assets[0].data += "\n"; rejected(invalid, "拒绝非规范base64")
    invalid = original; invalid.assets[0].width = 193; rejected(invalid, "拒绝过大素材")
    invalid = original; invalid.assets[0].format = "file:///etc/passwd"; rejected(invalid, "不读取图片路径或URL")
    invalid = original; invalid.assets = []; rejected(invalid, "拒绝悬空图片引用")
    invalid = original; invalid.modules[2].asset = nil; rejected(invalid, "图片模块必须提供素材")
    invalid = original; invalid.worldMap = nil; invalid.modules = (0..<12).map { .init(kind: .text, id: "\($0)", body: String(repeating: "x", count: 8192)) }
    rejected(invalid, "拒绝超过64KiB的完整信封")
    for kind in ReadPicoBoardModel.Kind.allCases where kind != .image {
        original.modules = [.init(kind: kind, id: kind.rawValue, title: "测试", body: "数据")]; original.assets = []; original.worldMap = kind == .cloudflare ? mapData.base64EncodedString() : nil
        checkEqual(try ReadPicoBoardModel.decode(original.encoded()).modules.first?.kind, kind, "语义模块支持 \(kind.rawValue)")
    }
    let previewTime = Date(timeIntervalSince1970: 1_700_000_000)
    for landscape in [false, true] {
        let preview = try ReadPicoNativeBoardRenderer.render(data, landscape: landscape, now: previewTime,
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        checkEqual(preview.width, landscape ? 1216 : 684, "共用原生预览使用实体屏幕宽度")
        checkEqual(preview.height, landscape ? 684 : 1216, "共用原生预览使用实体屏幕高度")
        guard let pixels = preview.dataProvider?.data as Data? else { throw ReadPicoManagerError.invalid("测试预览没有像素") }
        check(pixels.allSatisfy { $0 % 17 == 0 }, "原生预览仅含16个硬件灰阶")
        check(pixels.contains(where: { $0 < 128 }) && pixels.contains(255), "原生预览包含可见文字与背景")
        if let index = CommandLine.arguments.firstIndex(of: "--pico-model-previews"), CommandLine.arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: preview).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(landscape ? "landscape.png" : "portrait.png"))
        }
    }
    let utcPreview = try ReadPicoNativeBoardRenderer.render(data, landscape: false, now: previewTime, timeZone: TimeZone(secondsFromGMT: 0)!)
    let localPreview = try ReadPicoNativeBoardRenderer.render(data, landscape: false, now: previewTime, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    check((utcPreview.dataProvider?.data as Data?) != (localPreview.dataProvider?.data as Data?), "本机时区进入固件原生时钟排版")
    var unknownField = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    unknownField["untrusted_commands"] = ["draw"]
    do {
        _ = try ReadPicoNativeBoardRenderer.render(JSONSerialization.data(withJSONObject: unknownField), landscape: false)
        check(false, "原生预览应使用固件严格schema")
    } catch { check(true, "原生预览拒绝固件不支持的字段") }
    let full = try ReadPicoBoardModel.decode(data)
    func pixels(_ value: ReadPicoBoardModel) throws -> Data? {
        try ReadPicoNativeBoardRenderer.render(value.encoded(), landscape: true, now: previewTime).dataProvider?.data as Data?
    }
    var compact = full; compact.textScale = 2
    check(try pixels(full) != pixels(compact), "字号偏好改变原生排版")
    var spanning = full; spanning.columns = 2; spanning.modules[1].span = 1
    var fullWidth = spanning; fullWidth.modules[1].span = 2
    check(try pixels(spanning) != pixels(fullWidth), "整行偏好改变设备网格排布")
    var mapOnly = full; mapOnly.modules = [full.modules[1]]; mapOnly.assets = []
    var ranks = mapOnly; ranks.modules[0].presentation = .ranking; ranks.worldMap = nil
    check(try pixels(mapOnly) != pixels(ranks), "全球热区与地区排行使用独立的原生布局")
    var horizontal = ReadPicoBoardModel(boardID: "media", generatedAt: 1_700_000_000,
        modules: [.init(kind: .nowPlaying, id: "playing", title: "歌名", subtitle: "歌手", body: "专辑", asset: asset.id)], assets: [asset])
    horizontal.modules[0].mediaLayout = .horizontal
    var vertical = horizontal; vertical.modules[0].mediaLayout = .vertical
    check(try pixels(horizontal) != pixels(vertical), "专辑封面横排竖排都可生效")
    var damagedMap = mapOnly; damagedMap.worldMap = Data([1, 2, 3]).base64EncodedString()
    do { _ = try pixels(damagedMap); check(false, "C解析器应拒绝错误地图格式") }
    catch { check(true, "原生C解析器严格校验世界地图格式") }
    let capabilityLine = "RPICO {\"usb_board\":true,\"protocol\":1,\"gray_levels\":16,\"max_bytes\":420000,\"task\":\"\",\"state\":\"idle\",\"direct_protocol\":1,\"chunk_bytes\":1024,\"model_protocol\":1,\"model_max_bytes\":65536}\n"
    let capability = try ReadPicoUSBBoardStatus(line: capabilityLine)
    check(capability.supportsModel, "USB正确协商结构化数据能力")
    let old = try ReadPicoUSBBoardStatus(line: capabilityLine.replacingOccurrences(of: "\"model_protocol\":1,", with: ""))
    check(!old.supportsModel, "旧固件没有虚构模型能力")
    let port = "/dev/cu.usbmodemPicoModelTest"
    let client = ReadPicoUSBBoardClient(environment: .init(ports: { [port] }, identity: { _ in "fixture-reader" },
        volumes: { fatalError("数据画板不得探测或挂载TF磁盘") }, status: { _ in capability },
        directChannel: { _, payload, display, channel, _ in
            guard payload == data, !display, channel == .canvas else { throw ReadPicoManagerError.invalid("测试数据不一致") }
            return .init(taskID: String(repeating: "a", count: 32), state: "saved", contentChannel: channel)
        }))
    let receipt = try await client.pushDirect(data, port: port, expectedIdentity: "fixture-reader", display: false) { _ in }
    checkEqual(receipt.state, "saved", "USB数据画板保留后台保存语义")
    let unsupported = ReadPicoUSBBoardClient(environment: .init(ports: { [port] }, identity: { _ in "fixture-reader" },
        status: { _ in old }, directChannel: { _, _, _, _, _ in fatalError("旧固件不得收到模型或截图回退") }))
    do { _ = try await unsupported.pushDirect(data, port: port) { _ in }; check(false, "旧固件应拒绝模型") }
    catch { check(error.localizedDescription.contains("更新"), "旧固件明确提示升级") }
    if let index = CommandLine.arguments.firstIndex(of: "--pico-model-pty"), CommandLine.arguments.indices.contains(index + 1) {
        let port = CommandLine.arguments[index + 1]
        guard port.hasPrefix("/dev/ttys"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev" else {
            throw ReadPicoManagerError.invalid("集成测试只接受测试进程创建的PTY")
        }
        let display = CommandLine.arguments.contains("--pico-model-show")
        let receipt = try await ReadPicoUSBBoardClient.Environment().direct(port, data, display) { _ in }
        check(receipt.state == (display ? "displayed" : "saved"), "生产DirectWire收到真实C接收器保存或显示回执")
        print("Production DirectWire receipt: \(receipt.state), task \(receipt.taskID)")
    }
    if let index = CommandLine.arguments.firstIndex(of: "--pico-model-fixture"), CommandLine.arguments.indices.contains(index + 1) {
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
    }
}
