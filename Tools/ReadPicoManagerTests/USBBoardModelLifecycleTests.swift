import Foundation
import CoreGraphics
import LinxDisplayCore

private var checks = 0
@MainActor private func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
@MainActor private func idle(_ model: ReadPicoManagerModel) async throws {
    for _ in 0..<1000 {
        if !model.busy { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    fatalError("Model did not finish the injected operation")
}

private actor DelayedUSBBoard {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func run() async throws {
        entered = true
        // Simulate an already-submitted transport that reports cancellation only after releasing its resources.
        // 模拟已提交的传输先释放资源，再晚到地报告取消。
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil; entered = false }
}

@main struct USBBoardModelLifecycleTests {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("pico-usb-lifecycle-" + UUID().uuidString).resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let card = root.appendingPathComponent("card")
        try files.createDirectory(at: card, withIntermediateDirectories: false)
        try Data("isolated book".utf8).write(to: card.appendingPathComponent("book.txt"))
        let mounted = ReadPicoMountedVolume(rootURL: card, name: "Fixture card", capacity: 1_000_000,
                                           free: 900_000, readOnly: false, hasPicoFolders: true, identity: "fixture-volume")
        let port = "/dev/cu.usbmodem-isolated-fixture"
        let delayed = DelayedUSBBoard()
        let client = ReadPicoUSBBoardClient(environment: .init(ports: { [port] }, identity: { _ in "fixture-reader" },
            volumes: { [] }, status: { _ in .init(taskID: "", state: "idle", directProtocol: 1, chunkBytes: 1024, displayIntent: true) },
            direct: { _, _, _, _ in try await delayed.run(); return .init(taskID: String(repeating: "a", count: 32), state: "saved") }))
        let cg = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let bmp = try ReadPicoBitmap.makeGray16(image: cg.makeImage()!, width: 684, height: 1216)
        let model = ReadPicoManagerModel(usbClient: .init { _, _ in .init(deviceIdentity: "fixture-reader") },
                                        discoverVolumes: { [mounted] }, discoverUSBPorts: { [port] },
                                        identifyUSBPort: { _ in "fixture-reader" }, ejectVolume: { _ in }, boardClient: client)
        for replacement in ["card", "wait"] {
            await model.refreshCardAvailability()
            model.selectCard(card); try await idle(model)
            check(model.store != nil && model.files.count == 1, "Fixture card was selected")
            var completionCount = 0
            model.pushUSBBoard(bmp) { success in
                check(!success, "Leaving the previous device does not confirm its display")
                completionCount += 1
            }
            await delayed.waitUntilEntered()
            // The runner disables access control to await the exact old task, rather than relying on sleeps.
            // 测试仅开放访问控制以等待原任务结束，不用延时猜测旧清理是否已执行。
            let oldOperation = model.operationTask!
            check(model.busy, "Old USB operation is in flight")
            model.deactivate()
            check(completionCount == 1 && !model.busy, "Departure resolves the old completion exactly once")
            check(!model.boardSubmissionUncertain, "A departed owner's uncertain submission never blocks a replacement owner")
            if replacement == "card" {
                await model.refreshCardAvailability()
                model.selectCard(card); try await idle(model)
                check(model.store != nil && model.files.count == 1, "Replacement device card loaded before old transport returns")
            } else {
                // The previous transport still owns its serial lease. Model the new owner's wait
                // without illegally opening that same physical port before cancellation completes.
                model.waitingForUSBVolume = true
                check(model.waitingForUSBVolume, "Replacement USB handoff is waiting for its volume")
            }
            let currentMessage = model.message
            await delayed.release()
            await oldOperation.value
            if replacement == "card" {
                check(model.store?.rootURL.path == card.path && model.files.count == 1,
                      "Late cancelled USB cleanup must not clear the replacement card or files")
            } else {
                check(model.waitingForUSBVolume,
                      "Late cancelled USB cleanup must not end a replacement USB volume wait")
            }
            check(model.message == currentMessage && completionCount == 1 && !model.busy,
                  "Late old task leaves replacement message, completion count and busy state intact")
            model.deactivate()
        }
        print("PASS USB board manager lifecycle: \(checks) checks; exact old-task completion awaited; injected transport, temporary TF roots, no hardware/network/user settings")
    }
}
