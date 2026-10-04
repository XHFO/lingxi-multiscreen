import Foundation

/// 仅缓存变化很少的效果目录，不缓存实时状态或实体值。
actor AWTRIXMetadataCache {
    struct Entry: Sendable {
        let capabilities: AWTRIXCapabilities
        let palettes: [String: [String]]
        var sampledAt = Date()
    }
    private var entries: [String: Entry] = [:]

    func get(_ key: String) -> Entry? {
        guard let value = entries[key], Date().timeIntervalSince(value.sampledAt) < 60 else { return nil }
        return value
    }

    func set(_ entry: Entry, key: String) {
        entries[key] = entry
        if entries.count > 32 {
            entries = entries.filter { Date().timeIntervalSince($0.value.sampledAt) < 60 }
        }
    }
}
