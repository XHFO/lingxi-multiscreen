import Foundation
import LinxDisplayCore

// 中文：协议数据与过期事件验证，输出真实TF应用可接收的配置；不启动软件或访问设备。
// English: Validate protocol data and stale-event rejection, emitting a real TF configuration without opening apps or hardware.
@main struct DesktopConsoleTests {
    static func check(_ value: Bool) { precondition(value) }
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection") } catch {}
    }
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let items = (0..<24).map { index in
            ReadPicoDesktopConsole.Item(id: "app-\(index)", label: "应用 \(index + 1)",
                icon: Data((0..<512).map { UInt8(($0 + index) % 256) }))
        }
        let config = try ReadPicoDesktopConsole.configuration(items: items, revision: 7)
        check(config.count == 14224 && Array(config.prefix(4)) == [0x50, 0x43, 0x43, 0x31])
        check(Array(config[8..<16]) == [1, 0, 24, 0, 0, 0, 0, 0])
        check(config.subdata(in: 96..<608) == items[0].icon)
        try config.write(to: output.appendingPathComponent("console-config.bin"))
        let rotated = try ReadPicoDesktopConsole.configuration(items: items, revision: 8, rotated: true)
        check(Array(rotated[12..<16]) == [1, 0, 0, 0])
        try rotated.write(to: output.appendingPathComponent("console-rotated.bin"))
        let peerItems = (0..<24).map { ReadPicoDesktopConsole.Item(id: "peer-\($0)", label: "扩展 \($0 + 1)", icon: items[$0].icon) }
        try ReadPicoDesktopConsole.configuration(items: peerItems, revision: 9, rotated: true).write(to: output.appendingPathComponent("console-peer.bin"))
        let pair = try JSONDecoder().decode(ReadPicoWorkspace.Reply.self, from: Data("{\"workspace\":true,\"ok\":true,\"protocol\":1,\"paired\":true,\"connected\":true,\"reading\":false,\"mode\":2,\"state\":5,\"done\":14224,\"total\":14224}".utf8))
        check(pair.canDeliver && pair.fraction == 1 && pair.state == ReadPicoWorkspace.State.displayed.rawValue)
        let offline = try JSONDecoder().decode(ReadPicoWorkspace.Reply.self, from: Data("{\"workspace\":true,\"ok\":true,\"paired\":true,\"connected\":false}".utf8))
        check(!offline.canDeliver && offline.fraction == nil)

        check(try ReadPicoDesktopConsole.configuration(items: [], revision: 8).count == 14224)
        rejected { _ = try ReadPicoDesktopConsole.configuration(items: items + [items[0]], revision: 1) }
        rejected { _ = try ReadPicoDesktopConsole.configuration(items: [items[0], items[0]], revision: 1) }
        for item in [ReadPicoDesktopConsole.Item(id: "bad/path", label: "A", icon: items[0].icon),
                     .init(id: "a", label: String(repeating: "字", count: 16), icon: items[0].icon),
                     .init(id: "a", label: "A\nB", icon: items[0].icon),
                     .init(id: "a", label: "A", icon: Data())] {
            rejected { _ = try ReadPicoDesktopConsole.configuration(items: [item], revision: 1) }
        }
        check(ReadPicoDesktopConsole.crc32(Data("123456789".utf8)) == 0xcbf43926)
        var gate = ReadPicoDesktopConsole.EventGate(); gate.reset(session: "one")
        func reply(_ session: String, _ event: Int, _ action: String = "app-0", _ online: Bool = true) throws -> ReadPicoDesktopConsole.Reply {
            try JSONDecoder().decode(ReadPicoDesktopConsole.Reply.self, from: JSONSerialization.data(withJSONObject:
                ["console": true, "ok": true, "session": session, "event": event, "action": action, "online": online]))
        }
        let allowed: Set<String> = ["app-0"]
        check(gate.accept(try reply("old", 4), allowed: allowed) == nil)
        check(gate.accept(try reply("one", 1, "app-0", false), allowed: allowed) == nil)
        check(gate.accept(try reply("one", 1, "unknown"), allowed: allowed) == nil)
        check(gate.accept(try reply("one", 1), allowed: allowed) == "app-0")
        check(gate.accept(try reply("one", 1), allowed: allowed) == nil)
        check(gate.accept(try reply("one", 2), allowed: allowed) == "app-0")
        gate.reset(session: "two")
        check(gate.accept(try reply("one", 3), allowed: allowed) == nil)
        check(gate.accept(try reply("two", 1), allowed: allowed) == "app-0")
        let asset = ReadPicoBoardModel.Asset(width: 32, height: 32, pixels: items[0].icon)
        var model = ReadPicoBoardModel(boardID: "delta-fixture", generatedAt: 1700000000,
            modules: [.init(kind: .weather, id: "weather", metrics: [.init("温度", "23", "°C")]),
                      .init(kind: .image, id: "artwork", asset: asset.id)], assets: [asset])
        let base = try model.encoded(); model.modules[0].metrics[0].value = "25"
        let next = try model.encoded(); let delta = ReadPicoBoardDelta.make(base: base, next: next)!
        check(delta.count == 25 && delta.count < base.count / 10)
        check(try ReadPicoBoardDelta.apply(delta, base: base) == next)
        rejected { _ = try ReadPicoBoardDelta.apply(delta, base: next) }
        var corrupt = delta; corrupt[24] ^= 1
        rejected { _ = try ReadPicoBoardDelta.apply(corrupt, base: base) }
        rejected { _ = try ReadPicoBoardDelta.apply(Data(delta.prefix(23)), base: base) }
        try base.write(to: output.appendingPathComponent("board-base.json"))
        try next.write(to: output.appendingPathComponent("board-next.json"))
        try delta.write(to: output.appendingPathComponent("board-delta.bin"))
        print("PASS: 24-item configuration, UTF8 limits, CRC32, stale/duplicate/offline events and \(base.count)→\(delta.count)-byte semantic delta with unchanged artwork; no hardware or app launches")
    }
}
