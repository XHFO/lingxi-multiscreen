import Foundation
import CoreGraphics
import ImageIO

var assertions = 0
func expect(_ value: Bool, _ message: String) {
    assertions += 1
    guard value else { fatalError(message) }
}
var config = C6StandaloneConfiguration()
expect(config.isValid, "valid defaults")
expect(config.clockStyle == .flip, "existing clock remains the default")
var roundClock = config; roundClock.clockStyle = .rounded
expect(try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONEncoder().encode(roundClock)) == roundClock, "rounded clock style roundtrip")
var clockDocument = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roundClock)) as! [String: Any]
clockDocument.removeValue(forKey: "clock_style")
expect(try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONSerialization.data(withJSONObject: clockDocument)).clockStyle == .flip, "legacy documents retain flip clock")
for invalid in [-1, 2, 0.5, "1"] as [Any] {
    clockDocument["clock_style"] = invalid
    expect((try? JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONSerialization.data(withJSONObject: clockDocument))) == nil, "unknown or noninteger clock style rejected")
}
for mask in [0, 15] { var value = config; value.cardMask = mask; expect(value.isValid, "rotation mask boundaries accepted") }
for mask in [-1, 16] { var value = config; value.cardMask = mask; expect(!value.isValid, "invalid rotation bits rejected") }
expect(!config.theme.enabled && config.theme.background == 0x080B12, "old documents use existing deepSpace default")
var themed = config; themed.theme.enabled = true; themed.theme.dark = false; themed.theme.accent = 0xFFFFFF
let decodedTheme = try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONEncoder().encode(themed))
expect(themed.isValid && decodedTheme == themed, "resolved theme roundtrip")
themed.theme.accent = 0x1000000; expect(!themed.isValid, "RGB24 bounds")
for (saturation, contrast) in [(50, 75), (200, 150)] { var edge = config; edge.saturationPercent = saturation; edge.contrastPercent = contrast; expect(edge.isValid, "color calibration inclusive boundaries") }
for (saturation, contrast) in [(49, 100), (201, 100), (100, 74), (100, 151)] { var edge = config; edge.saturationPercent = saturation; edge.contrastPercent = contrast; expect(!edge.isValid, "color calibration out of range rejected") }
config.enabled = true; config.clock = false; config.diagnostics = false
expect(!config.isValid, "empty enabled mode rejected")
config.clock = true; config.rotation = 90
expect(config.isValid, "quarter-turn rotation supported")
config.rotation = 180; config.brightness = 101
expect(!config.isValid, "brightness rejected")
config.brightness = 80; config.interval = 4
expect(!config.isValid, "interval rejected")
config.interval = 15; config.timezone = 50401
expect(!config.isValid, "timezone rejected")
config.timezone = 28800
let data = try JSONEncoder().encode(config)
expect(try JSONDecoder().decode(C6StandaloneConfiguration.self, from: data) == config, "roundtrip")
let document = String(decoding: data, as: UTF8.self)
expect(!document.contains("\"token\":") && !document.contains("password"), "no secrets in settings")
for host in ["192.168.1.2", "10.0.0.5", "172.16.1.2", "192.168.4.1"] {
    expect((try? C6StandaloneClient(host: host)) != nil, "private address allowed")
}
for host in ["8.8.8.8", "https://192.168.1.2", "192.168.1.999", "192.168.1.2/path", "localhost", "172.32.0.1", "192.168.1.2@8.8.8.8"] {
    expect((try? C6StandaloneClient(host: host)) == nil, "unsafe address rejected")
}
for pin in ["0000", "0123", "1234", "9999"] {
    expect(C6StandaloneClient.validPIN(pin), "four ASCII digits accepted, including leading zero")
}
for pin in ["", "123", "12345", "12a4", " 1234", "1234\n", "１２３４", "١٢٣٤", "12.4"] {
    expect(!C6StandaloneClient.validPIN(pin), "only exactly four ASCII digits accepted")
}
let pairingReply = Data(#"{"token":"0123456789abcdef"}"#.utf8)
expect(try C6StandaloneClient.pairingToken(from: pairingReply, status: 200) == "0123456789abcdef", "pairing returns internal authorization, never the short PIN")
func expectPairingError(_ data: Data, status: Int, expected: C6StandaloneError) {
    do {
        _ = try C6StandaloneClient.pairingToken(from: data, status: status)
        expect(false, "pairing error must not succeed")
    } catch let error as C6StandaloneError {
        expect(error == expected, "pairing status translated to actionable error")
    } catch { expect(false, "pairing parser leaked decoding failure") }
}
for reply in [#"{"token":"1234"}"#, #"{"token":"0123456789abcdeg"}"#, #"{"token":42}"#, #"{}"#, "not JSON"] {
    expectPairingError(Data(reply.utf8), status: 200, expected: .invalidPairingResponse)
}
for (status, error) in [(400, C6StandaloneError.invalidPIN), (401, .incorrectPIN), (403, .pairingNotOpen),
                        (404, .unsupported), (410, .pairingExpired), (423, .pairingLocked), (429, .pairingLocked),
                        (500, .response(500))] {
    expectPairingError(Data(#"{"error":"pairing_error"}"#.utf8), status: status, expected: error)
}
var ha = C6HAConfiguration(); ha.enabled = true; ha.host = "192.168.1.10"
ha.entities = [.init(id: "sensor.room_temperature", name: "客厅温度")]
config.ha = ha
expect(config.isValid, "HA subscription config valid")
config.ha.entities.append(config.ha.entities[0]); expect(!config.isValid, "duplicate entities rejected")
config.ha.entities.removeLast()
config.ha.entities[0].id = "sensor.bad.extra"; expect(!config.isValid, "complete entity ID validated")
config.ha.entities[0].id = "sensor.room_temperature"
var printer = C6PrinterConfiguration(); printer.sourceHA = true; printer.serial = "sample_printer"
printer.statusEntity = "sensor.x2d_print_status"; printer.name = "工作室 X2D"; printer.showTask = false
printer.imageEntity = "image.x2d_task_cover"; printer.showImage = false
printer.showNozzle = true; printer.showBed = true; printer.showError = true; printer.brandAccent = false; printer.timeMode = 1
printer.nozzleEntity = "sensor.x2d_nozzle"; printer.bedEntity = "sensor.x2d_bed"; printer.errorEntity = "sensor.x2d_error"; printer.endTimeEntity = "sensor.x2d_end_time"
config.printers = [printer]; config.weather = true; config.weatherCity = "上海"
config.latitude = 31.23; config.longitude = 121.47
expect(config.isValid, "HA-backed printer and weather valid")
var badImage = config; badImage.printers[0].imageEntity = "camera.x2d_camera"
expect(badImage.isValid, "offline camera entities provide bounded static snapshots, not video")
badImage.printers[0].imageEntity = "camera.x2d_camera/stream"
expect(!badImage.isValid, "camera source must be an entity ID, not an arbitrary path")
let encoded = try JSONEncoder().encode(config)
expect(try JSONDecoder().decode(C6StandaloneConfiguration.self, from: encoded) == config, "schema2 selection roundtrip")
expect(C6TaskThumbnail.homeAssistantTaskKey("模型 A.gcode") == "51f8e7ab9c2c491e", "task hash UTF-8 parity with firmware")
expect(C6TaskThumbnail.homeAssistantTaskKey("unknown") == nil && C6TaskThumbnail.homeAssistantTaskKey("") == nil, "unknown task has no cover identity")
expect(C6TaskThumbnail.mqttTaskKey(fields: ["subtask_id": "1234", "task_id": "456", "subtask_name": "test"]) == "1bf798bd4bce1656", "MQTT uses most precise job identifier")
expect(C6TaskThumbnail.mqttTaskKey(fields: ["subtask_id": "0", "task_id": "456"]) == "720a0e7b1c1c2e99", "zero MQTT identifier falls back to task ID")
let thumbnailHeaders = try C6StandaloneClient.thumbnailHeaders(width: 80, height: 80, serial: "printer_A", taskKey: "51f8e7ab9c2c491e", revision: 3, byteCount: 12_800)
expect(thumbnailHeaders["Content-Type"] == "application/octet-stream" && thumbnailHeaders["X-Config-Revision"] == "3", "bounded binary cover protocol")
for (w, serial, key, bytes) in [(81, "printer_A", "51f8e7ab9c2c491e", 12960), (80, "printer_A\r\nX:secret", "51f8e7ab9c2c491e", 12800), (80, "printer_A", "51f8e7ab9c2c491G", 12800), (80, "printer_A", "51f8e7ab9c2c491e", 12799)] {
    expect((try? C6StandaloneClient.thumbnailHeaders(width: w, height: 80, serial: serial, taskKey: key, revision: 3, byteCount: bytes)) == nil, "invalid cover dimensions, headers and body rejected before transport")
}
let imageProvider = CGDataProvider(data: Data([255, 0, 0, 255, 0, 0]) as CFData)!
let testImage = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [], provider: imageProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let png = NSMutableData(); let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, testImage, nil); expect(CGImageDestinationFinalize(destination), "test cover PNG encoded")
let rgb565 = C6TaskThumbnail.encodeThumbnail(from: png as Data)!
expect(rgb565.count == 12800, "Mac cover uses fixed 80×80 RGB565 buffer")
expect(rgb565[0] == 0 && rgb565[1] == 0 && rgb565[(40 * 80 + 40) * 2] == 0xf8 && rgb565[(40 * 80 + 40) * 2 + 1] == 0, "aspect-fit letterbox and canonical RGB565 red retained")
expect(C6TaskThumbnail.encodeThumbnail(from: Data()) == nil && C6TaskThumbnail.encodeThumbnail(from: Data("not an image".utf8)) == nil, "invalid images never sent")
let asymmetricBytes = Data((0..<8*4).flatMap { i -> [UInt8] in i < 8*2 ? [255,0,0,255] : [0,0,255,255] })
let asymmetricProvider = CGDataProvider(data: asymmetricBytes as CFData)!
let asymmetricImage = CGImage(width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: asymmetricProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let asymmetricPNG = NSMutableData()
let asymmetricDestination = CGImageDestinationCreateWithData(asymmetricPNG, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(asymmetricDestination, asymmetricImage, nil)
expect(CGImageDestinationFinalize(asymmetricDestination), "asymmetric media fixture encoded")
let asymmetricFrame = C6TaskThumbnail.encodeMedia(from: asymmetricPNG as Data)!
expect(asymmetricFrame.width == 8 && asymmetricFrame.height == 4, "media preserves original aspect and tiny-image size")
expect(asymmetricFrame.bytes[0] == 0xf8 && asymmetricFrame.bytes[1] == 0 && asymmetricFrame.bytes[62] == 0 && asymmetricFrame.bytes[63] == 0x1f,
       "media uploads preserve top-red bottom-blue orientation without a software flip")
var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
legacyObject.removeValue(forKey: "flip_animation")
legacyObject.removeValue(forKey: "theme")
legacyObject.removeValue(forKey: "card_mask")
legacyObject.removeValue(forKey: "saturation_percent"); legacyObject.removeValue(forKey: "contrast_percent")
var legacyPrinters = legacyObject["printers"] as! [[String: Any]]; legacyPrinters[0].removeValue(forKey: "rotate"); legacyPrinters[0].removeValue(forKey: "image_entity"); legacyPrinters[0].removeValue(forKey: "show_image"); legacyObject["printers"] = legacyPrinters
for key in ["show_nozzle", "show_bed", "show_error", "brand_accent", "time_mode", "nozzle_entity", "bed_entity", "error_entity", "end_time_entity"] { legacyPrinters[0].removeValue(forKey: key) }; legacyObject["printers"] = legacyPrinters
let legacyConfig = try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyObject))
expect(legacyConfig.flipAnimation && legacyConfig.printers[0].showImage && legacyConfig.printers[0].imageEntity.isEmpty, "old configs retain default flip animation and safe absent image source")
expect(legacyConfig.saturationPercent == 100 && legacyConfig.contrastPercent == 100, "old configs default to neutral color calibration")
expect(legacyConfig.cardMask == 15 && legacyConfig.printers[0].rotate, "legacy selections participate in rotation by default")
expect(!legacyConfig.theme.enabled && !legacyConfig.printers[0].showNozzle && legacyConfig.printers[0].brandAccent && legacyConfig.printers[0].timeMode == 0, "missing theme and printer details retain safe schema2 defaults")
var remote = config; remote.revision = 23; remote.localFirst = true; remote.enabled = false
remote.ha.entities = []; remote.ha.tokenSet = true; remote.printers = []
remote.flipAnimation = false
let merged = C6ConfigurationSync.merging(config, into: remote)
expect(C6ConfigurationSync.merging(roundClock, into: remote).clockStyle == remote.clockStyle, "native clock appearance remains device-owned")
expect(merged.ha.entities == config.ha.entities && merged.printers == config.printers, "selected content copied")
expect(merged.revision == 23 && merged.localFirst && !merged.enabled, "device-owned priority preserved")
expect(!merged.flipAnimation, "device-owned flip animation preserved during content sync")
var uiRemote = remote
uiRemote.rotation = 270; uiRemote.language = .english; uiRemote.digitStyle = .aerospace
uiRemote.sleepMode = .schedule; uiRemote.idleSleepMinutes = 17
uiRemote.sleepStartMinute = 1320; uiRemote.sleepEndMinute = 360; uiRemote.keepPrintingAwake = false
uiRemote.printers = config.printers; uiRemote.printers[0].cardStyle = .remaining
let uiMerged = C6ConfigurationSync.merging(config, into: uiRemote)
expect(uiMerged.rotation == 270 && uiMerged.language == .english && uiMerged.digitStyle == .aerospace, "console display preferences survive automatic content sync")
expect(uiMerged.sleepMode == .schedule && uiMerged.idleSleepMinutes == 17 && uiMerged.sleepStartMinute == 1320 && uiMerged.sleepEndMinute == 360 && !uiMerged.keepPrintingAwake, "console sleep preferences survive content sync")
expect(uiMerged.printers[0].cardStyle == .remaining, "card style follows printer identity")
let uiData = try JSONEncoder().encode(uiMerged)
expect(try JSONDecoder().decode(C6StandaloneConfiguration.self, from: uiData) == uiMerged, "all new choices roundtrip")
let uiObject = try JSONSerialization.jsonObject(with: uiData) as! [String: Any]
expect(uiObject["sleep_idle_minutes"] as? Int == 17 && uiObject["sleep_start"] as? Int == 1320 && uiObject["sleep_end"] as? Int == 360 && uiObject["sleep_keep_printing"] as? Bool == false, "sleep keys match existing Formlabs wire contract")
var legacyUI = uiObject
for key in ["language", "digit_style", "sleep_mode", "sleep_idle_minutes", "sleep_start", "sleep_end", "sleep_keep_printing"] { legacyUI.removeValue(forKey: key) }
var legacyUIPrinters = legacyUI["printers"] as! [[String: Any]]
for index in legacyUIPrinters.indices { legacyUIPrinters[index].removeValue(forKey: "card_style") }
legacyUI["printers"] = legacyUIPrinters
let legacyUIDecoded = try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyUI))
expect(legacyUIDecoded.language == .chinese && legacyUIDecoded.digitStyle == .pixel && legacyUIDecoded.sleepMode == .off && legacyUIDecoded.idleSleepMinutes == 5 && legacyUIDecoded.sleepStartMinute == 1380 && legacyUIDecoded.sleepEndMinute == 420 && legacyUIDecoded.keepPrintingAwake && legacyUIDecoded.printers.allSatisfy { $0.cardStyle == .standard }, "missing new fields retain legacy defaults")
for (key, invalid) in [("language", 2), ("digit_style", -1), ("sleep_mode", 3)] {
    var bad = uiObject; bad[key] = invalid
    expect((try? JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONSerialization.data(withJSONObject: bad))) == nil, "invalid UI enums rejected")
}
for angle in [0, 90, 180, 270] { var good = config; good.rotation = angle; expect(good.isValid, "all four directions valid") }
for angle in [-90, 45, 360] { var bad = config; bad.rotation = angle; expect(!bad.isValid, "invalid direction rejected") }
for minutes in [0, 121] { var bad = config; bad.idleSleepMinutes = minutes; expect(!bad.isValid, "sleep idle bounds rejected") }
for minute in [-1, 1440] { var bad = config; bad.sleepStartMinute = minute; expect(!bad.isValid, "sleep schedule bounds rejected") }
var equalSleepTimes = config
equalSleepTimes.sleepMode = .schedule
equalSleepTimes.sleepStartMinute = 420; equalSleepTimes.sleepEndMinute = 420
expect(!equalSleepTimes.isValid, "equal scheduled sleep endpoints rejected before transport")
equalSleepTimes.sleepMode = .off
expect(equalSleepTimes.isValid, "equal unused sleep endpoints remain valid when scheduling is off")
let oldUICapabilities = try C6StandaloneCapabilities.fromInfo(Data(#"{"device":"lingxi-esp32-c6-screen"}"#.utf8))
expect(oldUICapabilities.supports(config), "old firmware supports default schema2 choices")
expect(!oldUICapabilities.supports(uiMerged), "old firmware cannot silently discard new UI choices")
let newUICapabilities = try C6StandaloneCapabilities.fromInfo(Data(#"{"device":"lingxi-esp32-c6-screen","ui_options":true,"rotations":[0,90,180,270],"languages":[0,1],"digit_styles":[0,1],"sleep_modes":[0,1,2],"printer_card_styles":[0,1,2],"printer_overview":true}"#.utf8))
expect(newUICapabilities.supports(uiMerged) && newUICapabilities.printerOverview, "new firmware explicitly negotiates all options")
var localControls = remote; localControls.rotation = 0; localControls.cardMask = 3
let preservedControls = C6ConfigurationSync.merging(config, into: localControls)
expect(preservedControls.rotation == 0 && preservedControls.cardMask == 3, "device-owned rotation and card participation survive desktop content sync")
var calibratedSelection = config; calibratedSelection.saturationPercent = 150; calibratedSelection.contrastPercent = 125
let calibratedMerge = C6ConfigurationSync.merging(calibratedSelection, into: remote)
expect(calibratedMerge.saturationPercent == 150 && calibratedMerge.contrastPercent == 125, "software color calibration follows selected content, not remote-owned preferences")
var themeSelection = config; themeSelection.theme.enabled = true; themeSelection.theme.accent = 0xFF4500
expect(C6ConfigurationSync.merging(themeSelection, into: remote).theme == themeSelection.theme, "resolved palette follows this device selection")
var secondDevice = remote; secondDevice.theme.accent = 0x445566
expect(C6ConfigurationSync.merging(themeSelection, into: secondDevice).theme == themeSelection.theme && secondDevice.theme.accent == 0x445566, "merge does not mutate another device theme")
expect(merged.ha.tokenSet, "same identity retains token indicator")
var comparison = merged; comparison.revision += 1; comparison.ha.tokenSet = false
expect(C6ConfigurationSync.equivalent(merged, comparison), "revisions and credential indicators do not trigger writes")
comparison.ha.entities = []; comparison.weather = false; comparison.printers = []
expect(!C6ConfigurationSync.equivalent(merged, comparison), "removed selections require sync")
expect(C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-A", lastSyncedInputKey: nil), "first connection retains explicit desktop selection sync")
expect(!C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-A", lastSyncedInputKey: "desktop-A"), "unchanged desktop input makes periodic configuration reads non-writing")
expect(C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-B", lastSyncedInputKey: "desktop-A"), "explicit desktop input changes still require a CAS write")
expect(C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-A", lastSyncedInputKey: "desktop-B"), "reverting a desktop input is a real edit, not an OR merge")
var webEdited = config
webEdited.clock = !config.clock; webEdited.clockStyle = .rounded
webEdited.weather = !config.weather; webEdited.weatherCity = "网页设定的城市"
webEdited.printers = [C6PrinterConfiguration()]
webEdited.printers[0].sourceFormlabs = true; webEdited.printers[0].serial = "web_formlabs"
let untouchedWeb = webEdited
let adoptedWeb = C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-A", lastSyncedInputKey: "desktop-A")
    ? C6ConfigurationSync.merging(config, into: webEdited) : webEdited
expect(adoptedWeb == untouchedWeb, "periodic adoption preserves web clock, weather, independent Formlabs and their revision")
let editedDesktop = C6ConfigurationSync.shouldApplySelection(inputKey: "desktop-B", lastSyncedInputKey: "desktop-A")
    ? C6ConfigurationSync.merging(config, into: webEdited) : webEdited
expect(editedDesktop.clock && editedDesktop.clockStyle == webEdited.clockStyle
       && editedDesktop.weather == (config.weather || webEdited.weather)
       && editedDesktop.printers.contains(where: { $0.serial == "web_formlabs" })
       && config.printers.allSatisfy { p in editedDesktop.printers.contains(where: { $0.identity == p.identity }) },
       "desktop additions preserve independently configured local cards and clock appearance")
expect(editedDesktop.revision == webEdited.revision, "desktop edit starts from the latest device revision for CAS")
expect(C6ConfigurationSync.canRetainMediaOrigin(previous: config, current: webEdited, originMatches: true), "web display-only edits preserve established media source")
expect(!C6ConfigurationSync.canRetainMediaOrigin(previous: nil, current: webEdited, originMatches: true), "unknown previous device server cannot authorize desktop cached pictures")
expect(!C6ConfigurationSync.canRetainMediaOrigin(previous: config, current: config, originMatches: false), "a revoked media origin stays revoked on the next periodic read")
for field in ["host", "port", "tls"] {
    var otherServer = webEdited
    if field == "host" { otherServer.ha.host = "192.168.1.99" }
    if field == "port" { otherServer.ha.port = config.ha.port == 8123 ? 8124 : 8123 }
    if field == "tls" { otherServer.ha.tls = !config.ha.tls }
    expect(!C6ConfigurationSync.canRetainMediaOrigin(previous: config, current: otherServer, originMatches: true),
           "web HA \(field) change revokes old server media despite identical entity IDs")
}
expect(C6ConfigurationSync.homeAssistantEndpoint("http://ha.local:8123")?.port == 8123, "explicit HA port preserved")
expect(C6ConfigurationSync.homeAssistantEndpoint("http://ha.local/")?.port == 80, "HTTP proxy defaults to port 80")
expect(C6ConfigurationSync.homeAssistantEndpoint("https://ha.local")?.port == 443, "HTTPS defaults to port 443")
expect(C6ConfigurationSync.homeAssistantEndpoint("https://ha.local")?.tls == true, "HTTPS enables certificate verification")
for invalid in ["ftp://ha.local", "http://ha.local/path", "http://user:password@ha.local", "http://ha.local?token=example"] {
    expect(C6ConfigurationSync.homeAssistantEndpoint(invalid) == nil, "unsupported HA endpoint rejected")
}
var weather = WeatherSettings(); weather.city = "测试城市"; weather.latitude = 31.23; weather.longitude = 121.47
expect(WeatherClient.url(for: weather)?.host == "api.open-meteo.com", "fixed HTTPS weather provider")
expect(WeatherClient.url(for: weather)?.scheme == "https", "weather certificate validation available")
let forecast = Data(#"{"current":{"temperature_2m":25.5,"apparent_temperature":28.0,"weather_code":3},"daily":{"temperature_2m_max":[28],"temperature_2m_min":[22],"precipitation_probability_max":[60]}}"#.utf8)
let snapshot = try WeatherClient.parse(forecast, settings: weather)
expect(snapshot.city == weather.city && snapshot.rainProbability == 60 && snapshot.carWash == "暂缓洗车", "weather data and advice parsed")
weather.refreshMinutes = 1; expect(!weather.isValid && WeatherClient.url(for: weather) == nil, "high-frequency refresh rejected")
var formConfig = C6StandaloneConfiguration(); var formPrinter = C6PrinterConfiguration()
formPrinter.sourceFormlabs = true; formPrinter.serial = "Form-123"; formPrinter.formClientID = "test-client"
formConfig.printers = [formPrinter]
expect(formConfig.isValid, "Formlabs cloud data source accepts native serial without LAN IP or HA")
formConfig.printers[0].sourceHA = true; expect(!formConfig.isValid, "Mutually exclusive cloud and HA sources")
formConfig.printers[0].sourceHA = false
formConfig.printers[0].formClientID = ""; expect(!formConfig.isValid, "Formlabs credentials identity required")
formConfig.printers[0] = formPrinter
let formRoundTrip = try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONEncoder().encode(formConfig))
expect(formRoundTrip == formConfig, "Formlabs wire flags and display settings roundtrip")
expect(C6TaskThumbnail.formlabsTaskKey(runID: "run1", name: "name") == C6TaskThumbnail.taskKey(source: "formlabs", value: "run1"), "Formlabs native task key matches Mac")
formConfig.printers[0].formCredentialsSet = true
expect(C6ConfigurationSync.equivalent(formConfig, formRoundTrip), "Formlabs credential indicator doesn't cause repeated writes")
var mixed = C6StandaloneConfiguration()
var bambu = C6PrinterConfiguration(); bambu.serial = "SHARED"; bambu.name = "同名打印机"; bambu.host = "192.168.1.20"; bambu.trustLAN = true
var form = formPrinter; form.serial = "SHARED"; form.name = bambu.name
mixed.printers = [bambu, form]
expect(mixed.isValid && bambu.identity != form.identity, "same name and serial across brands stay distinct")
var rotationRemote = mixed; rotationRemote.printers[0].rotate = false
rotationRemote.printers[0].cardStyle = .percentage
rotationRemote.printers[1].cardStyle = .remaining
var reordered = mixed; reordered.printers.reverse()
let rotationMerge = C6ConfigurationSync.merging(reordered, into: rotationRemote)
expect(!rotationMerge.printers[0].rotate && rotationMerge.printers[1].rotate, "existing local order and per-device rotation survive reordered desktop selections")
expect(rotationMerge.printers[0].cardStyle == .percentage && rotationMerge.printers[1].cardStyle == .remaining, "same serial across different brands never cross-matches card styles")
expect(rotationMerge.printers.allSatisfy(\.enabled), "hidden rotation retains enabled data subscriptions")
expect(C6ConfigurationSync.mediaSourceMatches(form, selected: form), "same selected Formlabs printer and cloud account can receive desktop cover")
var otherFormAccount = form; otherFormAccount.formClientID = form.formClientID + "_other"
expect(!C6ConfigurationSync.mediaSourceMatches(otherFormAccount, selected: form), "same Formlabs serial with another Client ID never receives the old account cover")
expect(!C6ConfigurationSync.mediaSourceMatches(form, selected: bambu), "identical serials across brands never share desktop media")
var hiddenForm = form; hiddenForm.enabled = false
expect(!C6ConfigurationSync.mediaSourceMatches(form, selected: hiddenForm), "disabled desktop selection cannot authorize printer media")
expect(![bambu].contains(where: { C6ConfigurationSync.mediaSourceMatches(form, selected: $0) }), "a web-only Formlabs printer is not implicitly selected for desktop thumbnail upload")
var mediaHA = bambu; mediaHA.sourceHA = true; mediaHA.statusEntity = "sensor.print_status"
mediaHA.taskEntity = "sensor.print_task"; mediaHA.imageEntity = "camera.printer"
expect(C6ConfigurationSync.mediaSourceMatches(mediaHA, selected: mediaHA), "same selected HA printer entity mapping retains desktop media")
var otherHA = mediaHA; otherHA.taskEntity = "sensor.other_task"
expect(!C6ConfigurationSync.mediaSourceMatches(otherHA, selected: mediaHA), "a changed HA task mapping cannot reuse old desktop task pictures")
otherHA = mediaHA; otherHA.imageEntity = "camera.other_printer"
expect(!C6ConfigurationSync.mediaSourceMatches(otherHA, selected: mediaHA), "a web-edited HA camera mapping stays on its local source")
expect(!C6ConfigurationSync.mediaSourceMatches(mediaHA, selected: bambu), "switching between MQTT and HA never crosses printer media sources")
var secrets = C6Credentials(); secrets.printerAccessCodes[bambu.credentialKey] = "bambu-secret"; secrets.formClientSecrets[form.credentialKey] = "form-secret"
let payload = try JSONSerialization.jsonObject(with: C6StandaloneClient.configurationPayload(mixed, credentials: secrets)) as! [String: Any]
let entries = payload["printers"] as! [[String: Any]]
expect(entries[0]["brand"] as? String == "bambu" && entries[1]["brand"] as? String == "formlabs", "wire configuration includes explicit brand")
expect(entries[0]["access_code"] as? String == "bambu-secret" && entries[0]["form_client_secret"] == nil, "Bambu receives only its own credentials")
expect(entries[1]["form_client_secret"] as? String == "form-secret" && entries[1]["access_code"] == nil, "Formlabs receives only its own credentials")
var changedAccount = form; changedAccount.formClientID = "other-client"
expect(changedAccount.credentialKey != form.credentialKey, "changing Formlabs account isolates secret input")
var changedOrigin = bambu; changedOrigin.host = "192.168.1.21"
expect(changedOrigin.credentialKey != bambu.credentialKey, "changing MQTT origin isolates secret input")
var previousSource = bambu; previousSource.sourceHA = true; previousSource.accessCodeSet = true
var previous = mixed; previous.printers = [previousSource, form]
expect(!C6ConfigurationSync.merging(mixed, into: previous).printers[0].accessCodeSet, "HA cannot supply MQTT access-code indicator")
var webOnly = config
webOnly.clock = true; webOnly.clockStyle = .rounded; webOnly.timezone = 3600
webOnly.weather = true; webOnly.weatherCity = "本地城市"
webOnly.ha.enabled = true; webOnly.ha.host = "192.168.1.10"
webOnly.ha.entities = [C6HAEntity(id: "sensor.web_only", name: "网页配置")]
webOnly.printers = [form]
var emptyDesktop = C6StandaloneConfiguration()
emptyDesktop.clock = false; emptyDesktop.diagnostics = false
let retainedLocal = C6ConfigurationSync.merging(emptyDesktop, into: webOnly)
expect(retainedLocal.clock && retainedLocal.clockStyle == .rounded && retainedLocal.timezone == 3600,
       "deselecting desktop clock cannot clear the local clock or overwrite its style/timezone")
expect(retainedLocal.weather && retainedLocal.weatherCity == webOnly.weatherCity,
       "deselecting desktop weather cannot clear a web-only weather configuration")
expect(retainedLocal.ha == webOnly.ha && retainedLocal.printers == webOnly.printers,
       "empty desktop selection keeps independent HA subscriptions and Formlabs cloud printers")
var sameOrigin = emptyDesktop
sameOrigin.ha = webOnly.ha
sameOrigin.ha.entities = [C6HAEntity(id: "sensor.desktop_only", name: "电脑配置")]
sameOrigin.printers = [bambu]
let union = C6ConfigurationSync.merging(sameOrigin, into: webOnly)
expect(union.ha.entities.map(\.id) == ["sensor.web_only", "sensor.desktop_only"],
       "same HA origin unions selected entities without deleting web-only IDs")
expect(union.printers.map(\.identity) == [form.identity, bambu.identity],
       "desktop printer additions preserve local configured order")
expect(!C6ConfigurationSync.hasHomeAssistantOriginConflict(selection: sameOrigin, remote: webOnly),
       "same-origin additions are safe")
for changedField in 0..<3 {
    var differentOrigin = sameOrigin
    if changedField == 0 { differentOrigin.ha.host = "192.168.1.11" }
    if changedField == 1 { differentOrigin.ha.port = 8124 }
    if changedField == 2 { differentOrigin.ha.tls = true }
    expect(C6ConfigurationSync.hasHomeAssistantOriginConflict(selection: differentOrigin, remote: webOnly),
           "another HA host, port or TLS origin stops before any credential write")
    expect(C6ConfigurationSync.merging(differentOrigin, into: webOnly) == webOnly,
           "read-only conflict planning cannot move existing entities to another HA origin")
}
var crowdedLocal = webOnly
crowdedLocal.ha.entities = (0..<6).map { C6HAEntity(id: "sensor.web_\($0)") }
expect(!C6ConfigurationSync.merging(sameOrigin, into: crowdedLocal).isValid,
       "merged HA capacity overflow is rejected, never truncated or destructive")
crowdedLocal = webOnly
crowdedLocal.printers = (0..<3).map { i in var p = form; p.serial = "web_\(i)"; return p }
expect(!C6ConfigurationSync.merging(sameOrigin, into: crowdedLocal).isValid,
       "merged printer capacity overflow is rejected, never deletes an independent printer")
var sameSerialNewAccount = mixed
sameSerialNewAccount.printers[1].formClientID = "changed-account"
sameSerialNewAccount.printers[1].cardStyle = .standard
var oldAccount = mixed
oldAccount.printers[1].cardStyle = .remaining; oldAccount.printers[1].formCredentialsSet = true
let changedAccountMerge = C6ConfigurationSync.merging(sameSerialNewAccount, into: oldAccount)
expect(changedAccountMerge.printers[1].cardStyle == .standard && !changedAccountMerge.printers[1].formCredentialsSet,
       "source account change never inherits another account's layout or credential indicator")
expect(C6ConfigurationSync.hasPrinterOriginConflict(selection: sameSerialNewAccount, remote: oldAccount),
       "an independently configured cloud account cannot be silently rebound during desktop sync")
expect(C6ConfigurationSync.applyingChanges(sameSerialNewAccount, since: nil, into: oldAccount) == oldAccount,
       "first-sync source conflict preserves the entire prior device configuration")
var checkpoint = union
checkpoint.theme.accent = 0x123456
var webDelta = checkpoint
webDelta.weatherCity = "网页新城市"; webDelta.latitude = 30.1
webDelta.clockStyle = .rounded; webDelta.timezone = 7200
webDelta.printers[0].name = "网页改名"
webDelta.printers[0].showImage = false; webDelta.printers[0].cardStyle = .remaining
webDelta.ha.entities[0].name = "网页实体名"
let restartPlan = C6ConfigurationSync.applyingChanges(checkpoint, since: checkpoint, into: webDelta)
expect(restartPlan == webDelta, "a persisted desktop checkpoint makes restart read-only for web-edited options")
var themeOnly = checkpoint; themeOnly.theme.accent = 0xAABBCC
let themeDelta = C6ConfigurationSync.changedSelection(themeOnly, since: checkpoint)
expect(!themeDelta.weather && !themeDelta.ha.enabled && themeDelta.ha.entities.isEmpty && themeDelta.printers.isEmpty,
       "an unrelated theme edit has no weather, HA or printer ownership delta")
let themeApplied = C6ConfigurationSync.applyingChanges(themeOnly, since: checkpoint, into: webDelta)
expect(themeApplied.theme == themeOnly.theme && themeApplied.weatherCity == webDelta.weatherCity
       && themeApplied.printers == webDelta.printers && themeApplied.ha == webDelta.ha,
       "theme changes preserve all independently edited data-source fields")
expect(themeApplied.clockStyle == webDelta.clockStyle && themeApplied.timezone == webDelta.timezone,
       "theme changes never reset native clock appearance or timezone")
var onePrinterField = checkpoint; onePrinterField.printers[0].showLayers.toggle()
let printerFieldDelta = C6ConfigurationSync.changedSelection(onePrinterField, since: checkpoint)
expect(printerFieldDelta.printers.count == 1 && !printerFieldDelta.ha.enabled && !printerFieldDelta.weather,
       "one printer field only owns one printer update")
let printerFieldApplied = C6ConfigurationSync.applyingChanges(onePrinterField, since: checkpoint, into: webDelta)
expect(printerFieldApplied.printers[0].showLayers == onePrinterField.printers[0].showLayers
       && printerFieldApplied.printers[0].name == webDelta.printers[0].name
       && printerFieldApplied.printers[0].showImage == webDelta.printers[0].showImage
       && printerFieldApplied.printers[0].cardStyle == webDelta.printers[0].cardStyle,
       "a layers edit cannot overwrite independent printer name, image selection or native layout")
var oneEntityField = checkpoint; oneEntityField.ha.entities[1].name = "电脑新实体名"
let entityFieldDelta = C6ConfigurationSync.changedSelection(oneEntityField, since: checkpoint)
expect(entityFieldDelta.ha.enabled && entityFieldDelta.ha.entities.count == 1
       && entityFieldDelta.ha.entities[0].id == oneEntityField.ha.entities[1].id,
       "one entity alias change is reduced to that exact HA entity")
let entityFieldApplied = C6ConfigurationSync.applyingChanges(oneEntityField, since: checkpoint, into: webDelta)
expect(entityFieldApplied.ha.entities[0].name == webDelta.ha.entities[0].name
       && entityFieldApplied.ha.entities[1].name == oneEntityField.ha.entities[1].name,
       "changing one desktop entity name cannot undo another web alias")
var deletedRemotely = webDelta; deletedRemotely.printers.removeFirst(); deletedRemotely.ha.entities.removeFirst()
let noResurrection = C6ConfigurationSync.applyingChanges(themeOnly, since: checkpoint, into: deletedRemotely)
expect(noResurrection.printers == deletedRemotely.printers && noResurrection.ha.entities == deletedRemotely.ha.entities,
       "unrelated edits do not resurrect sources manually removed from the device")
var desktopRemoval = checkpoint; desktopRemoval.printers = []; desktopRemoval.ha.enabled = false
desktopRemoval.ha.entities = []; desktopRemoval.weather = false
let preserveIndependent = C6ConfigurationSync.applyingChanges(desktopRemoval, since: checkpoint, into: webDelta)
expect(preserveIndependent.printers == webDelta.printers && preserveIndependent.ha == webDelta.ha
       && preserveIndependent.weather == webDelta.weather,
       "desktop card removal does not implicitly delete independently configured device capabilities")
var webOtherHA = webDelta; webOtherHA.ha.host = "192.168.1.99"
let unrelatedHATheme = C6ConfigurationSync.applyingChanges(themeOnly, since: checkpoint, into: webOtherHA)
expect(unrelatedHATheme.theme == themeOnly.theme && unrelatedHATheme.ha == webOtherHA.ha,
       "unchanged desktop HA source does not block safe unrelated visual changes")
expect(!C6ConfigurationSync.hasHomeAssistantOriginConflict(selection: themeDelta, remote: webOtherHA),
       "preflight uses the delta rather than stale unchanged desktop HA ownership")
expect(C6ConfigurationSync.hasHomeAssistantOriginConflict(selection: entityFieldDelta, remote: webOtherHA),
       "a real HA edit to a different server is still rejected before sending credentials")
var originChangedWeb = checkpoint; originChangedWeb.printers[0].formClientID = "another-cloud-client"
let safeUnrelatedSource = C6ConfigurationSync.applyingChanges(themeOnly, since: checkpoint, into: originChangedWeb)
expect(safeUnrelatedSource.theme == themeOnly.theme && safeUnrelatedSource.printers == originChangedWeb.printers,
       "an unchanged cloud origin cannot block safe unrelated theme changes")
expect(C6ConfigurationSync.hasPrinterOriginConflict(selection: printerFieldDelta, remote: originChangedWeb),
       "a real printer edit cannot cross an independently changed cloud account")
expect(C6ConfigurationSync.applyingChanges(onePrinterField, since: checkpoint, into: originChangedWeb) == originChangedWeb,
       "printer origin conflict never overwrites any on-device settings")
var oneWeatherChange = checkpoint; oneWeatherChange.weatherMinutes = 45
let weatherChangedDelta = C6ConfigurationSync.changedSelection(oneWeatherChange, since: checkpoint)
expect(weatherChangedDelta.weather && !weatherChangedDelta.ha.enabled && weatherChangedDelta.printers.isEmpty,
       "weather selection changes have no unrelated source ownership")
let weatherFieldApplied = C6ConfigurationSync.applyingChanges(oneWeatherChange, since: checkpoint, into: webDelta)
expect(weatherFieldApplied.weatherMinutes == 45 && weatherFieldApplied.weatherCity == webDelta.weatherCity
       && weatherFieldApplied.latitude == webDelta.latitude,
       "changing desktop weather polling preserves an independently changed device city and coordinates")
expect(C6ConfigurationSync.canAuthorizeMediaOrigin(selection: checkpoint, current: webDelta),
       "only an enabled exact validated HA endpoint can authorize desktop media")
expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: checkpoint, current: unrelatedHATheme),
       "an unrelated theme edit preserving a web-changed HA endpoint cannot grant media origin")
expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: nil, current: webDelta),
       "missing resolved desktop checkpoint cannot authorize media")
for changedEndpoint in 0..<3 {
    var otherEndpoint = webDelta
    if changedEndpoint == 0 { otherEndpoint.ha.host = "192.168.1.99" }
    if changedEndpoint == 1 { otherEndpoint.ha.port += 1 }
    if changedEndpoint == 2 { otherEndpoint.ha.tls.toggle() }
    expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: checkpoint, current: otherEndpoint),
           "a different host, port or TLS policy cannot inherit desktop media authority")
}
var inactiveSelection = checkpoint; inactiveSelection.ha.enabled = false
expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: inactiveSelection, current: webDelta),
       "a disabled desktop HA selection cannot authorize cached media")
var inactiveCurrent = webDelta; inactiveCurrent.ha.enabled = false
expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: checkpoint, current: inactiveCurrent),
       "a disabled on-device HA origin cannot accept desktop media")
inactiveSelection = checkpoint; inactiveSelection.ha.host = ""
inactiveCurrent = checkpoint; inactiveCurrent.ha.host = ""
expect(!C6ConfigurationSync.canAuthorizeMediaOrigin(selection: inactiveSelection, current: inactiveCurrent),
       "equal empty HA endpoints are not evidence of a validated source")
mixed.printers = [bambu, bambu]; expect(!mixed.isValid, "same brand serial duplicate rejected")
expect(C6StandaloneError.configurationSave("storage_full").localizedDescription.contains("原配置保留"), "storage failure explains preservation")
print("C6 selection/weather/Formlabs: \(assertions) assertions passed")
