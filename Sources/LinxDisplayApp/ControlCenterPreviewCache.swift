import Foundation
import CoreGraphics

/// Only synthesized fallback previews use a time limit. Frames already produced
/// by a device's normal pipeline bypass this cache and keep their own cadence.
struct ControlCenterPreviewCache<ID: Hashable, Input: Equatable, Value> {
    private struct Entry {
        let input: Input
        let createdAt: Date
        let value: Value
    }
    private var entries: [ID: Entry] = [:]
    let maximumAge: TimeInterval

    init(maximumAge: TimeInterval = 15) { self.maximumAge = maximumAge }

    mutating func value(for id: ID, input: Input, now: Date = Date(), make: () -> Value) -> Value {
        if let entry = entries[id], entry.input == input {
            let age = now.timeIntervalSince(entry.createdAt)
            if age >= 0 && age < maximumAge { return entry.value }
        }
        let value = make()
        entries[id] = Entry(input: input, createdAt: now, value: value)
        return value
    }

    mutating func retain(_ ids: Set<ID>) { entries = entries.filter { ids.contains($0.key) } }
}

enum ControlCenterPreviewVisibility {
    /// A small margin prepares a card just before it enters the scroll viewport.
    /// Missing geometry is not a reason to eagerly render the entire dashboard.
    static func intersects(_ card: CGRect?, viewport: CGRect, margin: CGFloat = 80) -> Bool {
        guard let card, !card.isEmpty, !viewport.isEmpty else { return false }
        return card.intersects(viewport.insetBy(dx: -margin, dy: -margin))
    }
}
