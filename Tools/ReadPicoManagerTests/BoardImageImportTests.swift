import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinxDisplayCore
import LinxDisplayApp

@MainActor private var checks = 0
@MainActor private func check(_ condition: Bool, _ text: String) {
    checks += 1; precondition(condition, text)
}
@MainActor private func png(width: Int, height: Int) throws -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "image-fixture", code: 1) }
    return data as Data
}
@MainActor private func imageImportTests(_ output: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = fm.temporaryDirectory.appendingPathComponent("pico-image-import-" + UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let model = AppModel(store: SettingsStore(dataDirectory: temporary.appendingPathComponent("settings")), startBackgroundServices: false)
    check(!model.backgroundServicesEnabled && model.settings.devices.isEmpty, "No live services or user settings")
    let id = model.addDevice(type: .readPico)
    let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
    let drafts = ReadPicoDraftGuard(model: manager)
    let board = ReadPicoLingxiBoardView(model: model, deviceID: id, drafts: drafts)
    var cases = [[String: Any]]()
    for (width, height) in [(684, 1216), (5000, 500), (500, 5000)] {
        let data = try png(width: width, height: height)
        let input = temporary.appendingPathComponent("\(width)x\(height).png")
        try data.write(to: input)
        // Exercise the actual production file checks, ImageIO decode and image assignment.
        check(board.importImageForTesting(from: input), "Production Board import accepts bounded source")
        let image = drafts.canvas.image!
        check(image.representations.count == 1 && image.representations[0] is NSBitmapImageRep,
              "Production import retains explicit pixel-backed representation")
        check(image.representations[0].pixelsWide == width && image.representations[0].pixelsHigh == height,
              "Import dimensions stay at source pixels without Retina multiplication")
        let rendered = try ReadPicoLingxiBoardRenderer.render(draft: drafts.canvas, model: model)
        check(rendered.width == 684 && rendered.height == 1216 && rendered.bitmap[28] == 4 && rendered.bitmap.count == 418422,
              "Imported image renders through production path to native4bit portrait frame")
        check(try drafts.canvas.boardImageData()?.isEmpty == false, "Imported image can be serialized for module rendering")
        let document = temporary.appendingPathComponent("\(width)x\(height).picocanvas")
        try drafts.canvas.save(to: document)
        let reopened = ReadPicoCanvasDraft(); try reopened.load(from: document)
        let reopenedImage = reopened.image!
        check(reopenedImage.representations.count == 1 && reopenedImage.representations[0] is NSBitmapImageRep,
              "Actual saved-draft load restores explicit bitmap representation")
        check(reopenedImage.representations[0].pixelsWide == width && reopenedImage.representations[0].pixelsHigh == height,
              "Saved draft reopen retains source pixel dimensions")
        check(try reopened.bitmapGray16() == rendered.bitmap, "Saving and reopening preserve exact native4bit output")
        check(try reopened.boardImageData()?.isEmpty == false, "Reopened original remains serializable")
        let roundTrip = temporary.appendingPathComponent("\(width)x\(height)-again.picocanvas")
        try reopened.save(to: roundTrip)
        check(fm.fileExists(atPath: roundTrip.path), "Reopened valid original can be saved again")
        cases.append(["source_width": width, "source_height": height, "png_bytes": data.count,
                      "wire_bytes": rendered.bitmap.count, "bit_depth": 4, "import_and_reopen": "PASS"])
    }
    let original = drafts.canvas.image!
    func rejected(_ data: Data, name: String, reason: String) throws {
        let url = temporary.appendingPathComponent(name); try data.write(to: url)
        check(!board.importImageForTesting(from: url) && manager.isError, reason)
        check(drafts.canvas.image === original, "Rejected import preserves the previous original")
    }
    try rejected(Data("not an image".utf8), name: "broken.png", reason: "Invalid encoded image rejected")
    try rejected(png(width: 8193, height: 1), name: "too-wide.png", reason: "Original8192 dimension limit remains enforced")
    try rejected(png(width: 4097, height: 4097), name: "too-many-pixels.png", reason: "Original16M pixel area limit remains enforced")
    try rejected(Data(repeating: 0, count: 16 * 1024 * 1024 + 1), name: "too-many-bytes.png", reason: "Original16MB encoded-file limit remains enforced")
    check(!board.importImageForTesting(from: temporary) && drafts.canvas.image === original, "Directory input rejected without altering original")
    check(!board.importImageForTesting(from: URL(string: "https://offline.invalid/image.png")!) && drafts.canvas.image === original,
          "Nonlocal input rejected without any network access")
    drafts.deactivate()
    let report: [String: Any] = ["result": "PASS", "checks": checks, "cases": cases,
        "actual_production_import": true, "actual_draft_save_load_render": true,
        "physical_device_accessed": false, "external_network_accessed": false, "user_settings_modified": false]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("report.json"))
    print("PASS actual Board image import and draft reopen: \(checks) checks; temporary files and isolated AppModel only")
}
@MainActor @_cdecl("readpico_board_image_import_tests_main")
func boardImageImportTestsMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    do {
        try imageImportTests(URL(fileURLWithPath: CommandLine.arguments[1])); return 0
    } catch { print("FAIL Board image import: \(error)"); return 1 }
}
