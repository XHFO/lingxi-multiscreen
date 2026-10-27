import Foundation
import CoreGraphics

/// Explicit integration against the C firmware's native HTTP adapter, never a physical device.
@main struct ReadPicoNativeIntegration {
    static func main() async throws {
        guard let address = ProcessInfo.processInfo.environment["READ_PICO_MANAGE_URL"],
              let parsed = URLComponents(string: address), ["127.0.0.1", "localhost", "::1"].contains(parsed.host) else {
            fatalError("Provide a loopback-only READ_PICO_MANAGE_URL; no physical device is accepted by this test.")
        }
        let connection = try ReadPicoConnection(address: address), client = ReadPicoHTTPClient(connection: connection)
        let home = try await client.home(), capabilities = try await client.capabilities()
        guard capabilities.protocol == 1, let configuration = capabilities.config, capabilities.canvas.supported else { fatalError("Missing real native capabilities") }
        let saved = try await client.saveDeviceConfiguration(configuration)
        guard let updated = saved.config, updated.state == 2, updated.revision != configuration.revision else { fatalError("Not committed") }
        var modified = configuration
        modified.autoSleepMinutes = configuration.autoSleepMinutes == 1 ? 3 : 1
        modified.doubleTapWake.toggle()
        let changed = try await client.saveDeviceConfiguration(modified)
        guard changed.config?.autoSleepMinutes == modified.autoSleepMinutes, changed.config?.doubleTapWake == modified.doubleTapWake else { fatalError("Changed config not committed") }
        let restored = try await client.saveDeviceConfiguration(configuration)
        guard restored.config?.autoSleepMinutes == configuration.autoSleepMinutes, restored.config?.doubleTapWake == configuration.doubleTapWake else { fatalError("Restored config not committed") }
        let context = CGContext(data: nil, width: 684, height: 1216, bitsPerComponent: 8, bytesPerRow: 684 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 684, height: 1216))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 100, y: 180, width: 484, height: 856))
        let bmp = try ReadPicoBitmap.make(image: context.makeImage()!, width: 684, height: 1216)
        if let path = ProcessInfo.processInfo.environment["READ_PICO_EXPECTED_BMP"] { try bmp.write(to: URL(fileURLWithPath: path)) }
        guard let initialImage = capabilities.imageLock, initialImage.supported else { fatalError("Missing actual native image-lock support") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 684, height: 1216))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 72, y: 140, width: 220, height: 920))
        context.fill(CGRect(x: 350, y: 390, width: 250, height: 400))
        let lockBMP = try ReadPicoBitmap.make(image: context.makeImage()!, width: 684, height: 1216)
        guard lockBMP != bmp else { fatalError("Lock/canvas fixtures must be visually distinct") }
        if let path = ProcessInfo.processInfo.environment["READ_PICO_EXPECTED_LOCK_BMP"] { try lockBMP.write(to: URL(fileURLWithPath: path)) }
        let lockSaved = try await client.saveLockImageConfirmed(lockBMP)
        guard let savedImage = lockSaved.imageLock, savedImage.available, savedImage.state == "saved",
              savedImage.revision != initialImage.revision,
              lockSaved.canvas.revision == capabilities.canvas.revision,
              lockSaved.config?.lockStyle == configuration.lockStyle else { fatalError("Lock save not independently committed") }
        guard try await client.lockImage() == lockBMP else { fatalError("Actual authenticated lock BMP read differs") }
        var lockConfiguration = configuration; lockConfiguration.lockStyle = 4
        let styleSaved = try await client.saveDeviceConfiguration(lockConfiguration)
        guard styleSaved.config?.lockStyle == 4, styleSaved.config?.state == 2 else { fatalError("Custom lock style not committed") }
        let displayed = try await client.pushCanvasConfirmed(bmp, capability: capabilities.canvas)
        guard displayed.canvas.state == "displayed", displayed.canvas.revision != capabilities.canvas.revision else { fatalError("Canvas not displayed") }
        guard displayed.imageLock?.revision == savedImage.revision, try await client.lockImage() == lockBMP else { fatalError("Canvas push replaced separate lock image") }
        print("PASS: actual native firmware HTTP pairing, masked HA read, same-value/changed/restored config commits, separate lock-image save/read/style commit, and \(bmp.count)-byte BMP displayed revision \(displayed.canvas.revision ?? 0); network_online=\(home.networkOnline). Actual physical display remains untested.")
    }
}
