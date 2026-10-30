import AppKit
import Foundation

/// Reuses decoded printer pictures while unrelated model readings update the grid.
/// Each device owns independent camera/task slots, and both storage limits apply
/// across the cache. Failed decodes are remembered until that slot's data changes.
@MainActor
final class ControlCenterPrinterImageCache {
    enum Slot: Hashable { case camera, task }
    private struct Key: Hashable {
        let deviceID: UUID
        let slot: Slot
    }
    private struct Entry {
        let data: Data
        let image: NSImage?
        var lastUse: UInt64
    }

    private let maximumEntries: Int
    private let maximumDataBytes: Int
    private let decode: (Data) -> NSImage?
    private var entries: [Key: Entry] = [:]
    private var sequence: UInt64 = 0
    private(set) var retainedDataBytes = 0
    var entryCount: Int { entries.count }

    init(maximumEntries: Int = 32, maximumDataBytes: Int = 32 * 1024 * 1024,
         decode: @escaping (Data) -> NSImage? = { NSImage(data: $0) }) {
        precondition(maximumEntries > 0 && maximumDataBytes > 0)
        self.maximumEntries = maximumEntries
        self.maximumDataBytes = maximumDataBytes
        self.decode = decode
    }

    func image(for deviceID: UUID, slot: Slot, data: Data?) -> NSImage? {
        let key = Key(deviceID: deviceID, slot: slot)
        guard let data else {
            remove(key)
            return nil
        }
        sequence &+= 1
        if var entry = entries[key], entry.data == data {
            entry.lastUse = sequence
            entries[key] = entry
            return entry.image
        }
        remove(key)
        let image = decode(data)
        // An unusually large frame is still shown, but cannot displace the
        // bounded cache with a single oversized encoded payload.
        guard data.count <= maximumDataBytes else { return image }
        while entries.count >= maximumEntries || retainedDataBytes > maximumDataBytes - data.count {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            remove(oldest)
        }
        entries[key] = Entry(data: data, image: image, lastUse: sequence)
        retainedDataBytes += data.count
        return image
    }

    private func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { retainedDataBytes -= old.data.count }
    }
}
