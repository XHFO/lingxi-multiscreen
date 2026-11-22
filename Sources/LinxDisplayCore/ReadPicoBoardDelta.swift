import Foundation

/// A bounded replacement span over the last committed semantic JSON, never a screen image.
/// 基于已提交语义JSON的有界差分，保留未变化的图片资源；完整模型校验后才替换。
public enum ReadPicoBoardDelta {
    public static func isDelta(_ data: Data) -> Bool { data.count >= 24 && data.prefix(4) == Data("RPD1".utf8) }
    public static func make(base: Data, next: Data) -> Data? {
        guard ReadPicoBoardModel.isModel(base), ReadPicoBoardModel.isModel(next), base.count <= 65536, next.count <= 65536 else { return nil }
        let a = [UInt8](base), b = [UInt8](next)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix && a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        guard 24 + b.count - prefix - suffix < b.count else { return nil }
        var result = Data("RPD1".utf8)
        for value in [ReadPicoDesktopConsole.crc32(base), ReadPicoDesktopConsole.crc32(next), UInt32(b.count), UInt32(prefix), UInt32(a.count - prefix - suffix)] {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        result.append(contentsOf: b[prefix..<(b.count - suffix)]); return result
    }
    public static func apply(_ delta: Data, base: Data) throws -> Data {
        guard isDelta(delta), delta.count <= 65536, base.count <= 65536 else { throw ReadPicoManagerError.invalid("看板差分结构无效。") }
        let raw = [UInt8](delta)
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(raw[at + $1]) << ($1 * 8) } }
        let count = Int(u32(12)), prefix = Int(u32(16)), removed = Int(u32(20))
        guard ReadPicoDesktopConsole.crc32(base) == u32(4), count >= 62, count <= 65536,
              prefix <= base.count, removed <= base.count - prefix,
              base.count - removed + delta.count - 24 == count else { throw ReadPicoManagerError.conflict("看板基线已变化，请重新发送完整数据。") }
        var next = Data(base.prefix(prefix)); next.append(delta.dropFirst(24)); next.append(base.dropFirst(prefix + removed))
        guard ReadPicoDesktopConsole.crc32(next) == u32(8) else { throw ReadPicoManagerError.invalid("看板差分校验失败。") }
        _ = try ReadPicoBoardModel.decode(next); return next
    }
}

/// Per-process, per-transport cache. Firmware always verifies its own committed base CRC.
/// 进程内按传输目标隔离，固件仍验证自身已保存模型的CRC。
final class ReadPicoBoardDeltaCache: @unchecked Sendable {
    static let shared = ReadPicoBoardDeltaCache()
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func get(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return data[key] }
    func set(_ key: String, _ value: Data?) { lock.lock(); defer { lock.unlock() }; if data.count >= 32 { data.removeAll() }; data[key] = value }
}
