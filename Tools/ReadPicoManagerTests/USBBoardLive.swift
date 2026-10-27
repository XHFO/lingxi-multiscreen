import AppKit
import Foundation

/// Explicit physical-device acceptance runner. It uses the same production client as the board page.
/// 显式实机验收入口；严格核对串口身份与TF后调用画板页相同的生产客户端。
@main struct USBBoardLive {
    static func main() async throws {
        guard CommandLine.arguments.count == 6, let capacity = Int64(CommandLine.arguments[2]), capacity > 0 else {
            throw ReadPicoManagerError.invalid("Usage (start in USB debug mode): usb-board-live TF_UUID TF_CAPACITY USB_PORT USB_IDENTITY NATIVE_BMP4")
        }
        let cardID = CommandLine.arguments[1], port = CommandLine.arguments[3], identity = CommandLine.arguments[4]
        guard !cardID.isEmpty, !identity.isEmpty, ReadPicoUSBTransferClient.discoverPorts().contains(port),
              ReadPicoUSBTransferClient.serialIdentity(port: port) == identity else {
            throw ReadPicoManagerError.unavailable("Explicit USB debug-port identity does not match; nothing sent.")
        }
        let bmp = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5]))
        let capability = try JSONDecoder().decode(ReadPicoCanvasCapability.self, from: Data("{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"max_bytes\":420000,\"bit_depths\":[4],\"gray_levels\":16}".utf8))
        try ReadPicoBitmap.validateCanvas(bmp, capability: capability)
        print("USB_BOARD_PREFLIGHT verified debug identity; starting explicit USB handoff")
        fflush(stdout)
        _ = try await ReadPicoUSBTransferClient().start(port: port)
        let deadline = Date().addingTimeInterval(45)
        var selected: ReadPicoMountedVolume?
        var lastObserved: [ReadPicoMountedVolume]?
        while Date() < deadline {
            try Task.checkCancellation()
            let observed = ReadPicoMountedVolume.discover()
            if lastObserved != observed {
                let details = observed.map { ["uuid": $0.identity as Any? ?? NSNull(), "capacity": $0.capacity,
                    "readOnly": $0.readOnly, "root": $0.rootURL.path] as [String: Any] }
                print("USB_BOARD_VOLUMES " + String(data: try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]), encoding: .utf8)!)
                fflush(stdout); lastObserved = observed
            }
            let matching = observed.filter { $0.identity == cardID && $0.capacity == capacity && !$0.readOnly }
            if matching.count == 1 { selected = matching[0]; break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let selected else {
            throw ReadPicoManagerError.unavailable("The explicitly identified TF UUID and capacity did not mount; no board file written.")
        }
        print("USB_BOARD_PREFLIGHT matched TF UUID and capacity at " + selected.rootURL.path)
        fflush(stdout)
        let receipt = try await ReadPicoUSBBoardClient().push(bmp, store: ReadPicoTFStore(rootURL: selected.rootURL), expectedIdentity: identity,
            eject: { url in try await ReadPicoSafeEject().eject(url, expectedVolume: selected) },
            progress: { value in
                print("USB_BOARD_PROGRESS " + String(data: try! JSONSerialization.data(withJSONObject: ["message": value.text, "fraction": value.fraction as Any? ?? NSNull()], options: [.sortedKeys]), encoding: .utf8)!)
                fflush(stdout)
            })
        print("USB_BOARD_DISPLAYED " + receipt.taskID)
    }
}
