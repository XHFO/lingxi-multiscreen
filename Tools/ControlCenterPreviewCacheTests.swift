import Foundation

@main struct ControlCenterPreviewCacheTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }

    static func main() {
        struct Input: Equatable { let target: String; let appearance: String }
        final class Frame {}
        let base = Date(timeIntervalSince1970: 1000)
        let first = Input(target: "board-one", appearance: "dark")
        var cache = ControlCenterPreviewCache<String, Input, Frame?>(maximumAge: 15)
        var renders = 0
        func make() -> Frame? { renders += 1; return Frame() }
        let frame = cache.value(for: "device-one", input: first, now: base, make: make)
        check(frame != nil && renders == 1, "a fallback renders once on first demand")
        for offset in [0.0, 3, 6, 9, 12, 14.999] {
            let repeated = cache.value(for: "device-one", input: first,
                                       now: base.addingTimeInterval(offset), make: make)
            check(repeated === frame && renders == 1, "unchanged fallback reuses the identical frame")
        }
        let newer = cache.value(for: "device-one", input: first, now: base.addingTimeInterval(15), make: make)
        check(newer !== frame && renders == 2, "source readings are refreshed after the bounded fallback interval")
        let changed = Input(target: "board-two", appearance: "dark")
        _ = cache.value(for: "device-one", input: changed, now: base.addingTimeInterval(16), make: make)
        check(renders == 3, "changing the selected board invalidates immediately")
        let light = Input(target: "board-two", appearance: "light")
        _ = cache.value(for: "device-one", input: light, now: base.addingTimeInterval(17), make: make)
        check(renders == 4, "changing appearance invalidates immediately")
        _ = cache.value(for: "device-two", input: light, now: base.addingTimeInterval(17), make: make)
        check(renders == 5, "different devices never share fallback images")
        cache.retain(["device-two"])
        _ = cache.value(for: "device-one", input: light, now: base.addingTimeInterval(18), make: make)
        check(renders == 6, "removed device entries are discarded")
        _ = cache.value(for: "device-two", input: light, now: base, make: make)
        check(renders == 7, "backward wall-clock adjustment does not keep an entry indefinitely")
        var missing = ControlCenterPreviewCache<String, Int, Frame?>()
        var misses = 0
        let missingFrame = missing.value(for: "absent", input: 1, now: base) { misses += 1; return nil }
        let repeatedMiss = missing.value(for: "absent", input: 1, now: base.addingTimeInterval(3)) { misses += 1; return Frame() }
        check(missingFrame == nil && repeatedMiss == nil && misses == 1,
              "an unavailable fallback is cached instead of retried every timer tick")
        let viewport = CGRect(x: 100, y: 100, width: 500, height: 500)
        check(!ControlCenterPreviewVisibility.intersects(nil, viewport: viewport), "unknown card geometry does not render eagerly")
        check(!ControlCenterPreviewVisibility.intersects(.zero, viewport: viewport), "zero-sized cards do not render")
        check(!ControlCenterPreviewVisibility.intersects(viewport, viewport: .zero), "unknown viewport does not render eagerly")
        check(ControlCenterPreviewVisibility.intersects(CGRect(x: 120, y: 120, width: 100, height: 100), viewport: viewport),
              "visible cards render")
        check(ControlCenterPreviewVisibility.intersects(CGRect(x: 120, y: 620, width: 100, height: 100), viewport: viewport),
              "nearby cards are prepared before entering the viewport")
        check(!ControlCenterPreviewVisibility.intersects(CGRect(x: 120, y: 900, width: 100, height: 100), viewport: viewport),
              "distant cards do not consume fallback renders")
        print("Control center preview cache: \(checks) checks passed")
    }
}
