import Foundation

/// 中文：显式实机入口，复用生产直接USB发送器；不接管或挂载TF卡。
/// English: Explicit hardware runner using the production direct sender without exporting TF storage.
@main struct USBDirectBoardLive {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let probe = args.count == 2 && args[0] == "--status"
        guard probe || ((args.count == 2 || args.count == 3) && (args.count == 2 || args[2] == "--display")) else {
            throw ReadPicoManagerError.invalid("Usage: usb-direct-board-live --status USB_PORT | USB_PORT NATIVE_BMP4 [--display]")
        }
        let port = probe ? args[1] : args[0]
        guard ReadPicoUSBTransferClient.discoverPorts().contains(port) else {
            throw ReadPicoManagerError.unavailable("Selected current USB port is absent; nothing sent.")
        }
        let identity = ReadPicoUSBTransferClient.serialIdentity(port: port)
        let client = ReadPicoUSBBoardClient()
        let status = try await client.verifyDirect(port: port)
        print("USB_DIRECT_CAPABILITY " + String(data: try JSONSerialization.data(withJSONObject: [
            "port": port, "current_identity": identity as Any? ?? NSNull(), "direct_protocol": status.directProtocol,
            "chunk_bytes": status.chunkBytes, "display_intent": status.displayIntent, "state": status.state
        ], options: [.sortedKeys]), encoding: .utf8)!)
        fflush(stdout)
        if probe { return }
        let bmp = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let receipt = try await client.pushDirect(bmp, port: port, expectedIdentity: identity, display: args.count == 3) { value in
            print("USB_DIRECT_PROGRESS " + String(data: try! JSONSerialization.data(withJSONObject: [
                "message": value.text, "fraction": value.fraction as Any? ?? NSNull()
            ], options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
        }
        print("USB_DIRECT_RECEIPT " + String(data: try JSONSerialization.data(withJSONObject: [
            "task": receipt.taskID, "state": receipt.state, "current_identity": receipt.deviceIdentity as Any? ?? NSNull()
        ], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
