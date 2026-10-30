import AppKit
import Foundation

@main
struct ControlCenterPrinterImageCacheTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let first = UUID(), second = UUID()
        let a = Data([1, 2, 3]), b = Data([4, 5, 6])
        var decodes = 0
        let cache = ControlCenterPrinterImageCache(maximumEntries: 3, maximumDataBytes: 9) { _ in
            decodes += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let camera = cache.image(for: first, slot: .camera, data: a)
        let sameBytes = Data(Array(a))
        check(cache.image(for: first, slot: .camera, data: sameBytes) === camera,
              "Equal payloads must retain the exact image reference across grid updates")
        check(decodes == 1, "Unchanged payloads must decode only once")
        let task = cache.image(for: first, slot: .task, data: a)
        check(task !== camera, "Camera and task slots must stay independent")
        let otherDevice = cache.image(for: second, slot: .camera, data: a)
        check(otherDevice !== camera, "Different devices must have independent picture slots")
        check(cache.entryCount == 3 && cache.retainedDataBytes == 9, "Cache must account for all stored payload bytes")
        check(cache.image(for: first, slot: .camera, data: b) !== camera,
              "Changed data must immediately replace a device's old picture")
        check(cache.entryCount == 3 && cache.retainedDataBytes == 9, "Replacing a slot must not leak its previous payload")
        check(cache.image(for: first, slot: .camera, data: nil) == nil, "Absent data must never display the previous frame")
        check(cache.entryCount == 2 && cache.retainedDataBytes == 6, "Absent data must release its slot")

        var lruDecodes = 0
        let lru = ControlCenterPrinterImageCache(maximumEntries: 2, maximumDataBytes: 100) { _ in
            lruDecodes += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let recent = lru.image(for: first, slot: .camera, data: a)
        _ = lru.image(for: first, slot: .task, data: a)
        _ = lru.image(for: first, slot: .camera, data: a)
        _ = lru.image(for: second, slot: .task, data: a)
        check(lru.image(for: first, slot: .camera, data: a) === recent, "Recent slots must survive LRU eviction")
        check(lruDecodes == 3 && lru.entryCount == 2, "Entry limit must evict the least recently used slot")
        _ = lru.image(for: first, slot: .task, data: a)
        check(lruDecodes == 4, "An evicted slot must decode again rather than reuse another device's image")

        let bytes = ControlCenterPrinterImageCache(maximumEntries: 20, maximumDataBytes: 5)
        _ = bytes.image(for: first, slot: .camera, data: a)
        _ = bytes.image(for: first, slot: .task, data: b)
        check(bytes.entryCount == 1 && bytes.retainedDataBytes == 3, "Byte budget must apply before the entry limit")
        _ = bytes.image(for: second, slot: .camera, data: Data(repeating: 0, count: 6))
        check(bytes.entryCount == 1 && bytes.retainedDataBytes == 3, "Oversized payloads must not be retained")

        var failedDecodes = 0
        let failures = ControlCenterPrinterImageCache { data in
            failedDecodes += 1
            return NSImage(data: data)
        }
        check(failures.image(for: first, slot: .task, data: a) == nil, "Invalid image data must remain a placeholder")
        check(failures.image(for: first, slot: .task, data: a) == nil && failedDecodes == 1,
              "Failed decode results must also be reused")
        _ = failures.image(for: first, slot: .task, data: b)
        check(failedDecodes == 2, "A changed payload must retry a previous failed decode")
        _ = failures.image(for: first, slot: .task, data: nil)
        _ = failures.image(for: first, slot: .task, data: b)
        check(failedDecodes == 3, "Clearing a slot must release its failed result too")

        // Exercise the real AppKit decoder with a genuine PNG and preserve dimensions.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let actual = ControlCenterPrinterImageCache()
        let image = actual.image(for: first, slot: .task, data: png)
        check(image?.size == NSSize(width: 2, height: 3), "A real decoded image must keep its native dimensions")
        check(actual.image(for: first, slot: .task, data: png) === image, "Real AppKit images must retain identity")
        print("PASS: \(checks) printer image-cache checks")
    }
}
