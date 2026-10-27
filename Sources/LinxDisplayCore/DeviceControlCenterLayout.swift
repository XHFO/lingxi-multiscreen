import CoreGraphics
import Foundation

/// Card preferences use complete grid cells. Window resizing only changes the rendered
/// column width; it never overwrites the saved combination or ordering.
public struct DeviceControlCenterCardSize: Codable, Equatable, Sendable {
    public static let defaultWidth = 320.0
    public static let defaultHeight = 360.0
    public static let defaultSpacing = 18.0
    public static let widthRange = defaultWidth...(defaultWidth * 2 + defaultSpacing)
    public static let heightRange = defaultHeight...(defaultHeight * 3 + defaultSpacing * 2)

    public private(set) var columnSpan: Int
    public private(set) var rowSpan: Int
    public var preferredWidth: Double { Double(columnSpan) * Self.defaultWidth + Double(columnSpan - 1) * Self.defaultSpacing }
    public var preferredHeight: Double { Double(rowSpan) * Self.defaultHeight + Double(rowSpan - 1) * Self.defaultSpacing }

    public init(columnSpan: Int, rowSpan: Int) {
        self.columnSpan = min(max(columnSpan, 1), 2)
        // Only the authored wide 2×3 layout extends past two rows. A malformed
        // or unsupported 1×3 preference safely retains the existing 1×2 form.
        self.rowSpan = min(max(rowSpan, 1), self.columnSpan == 2 ? 3 : 2)
    }

    /// Also migrates the earlier freely-sized cards to their nearest grid combination.
    public init(preferredWidth: Double = defaultWidth, preferredHeight: Double = defaultHeight) {
        self.init(columnSpan: Self.nearestSpan(preferredWidth, cell: Self.defaultWidth),
                  rowSpan: Self.nearestSpan(preferredHeight, cell: Self.defaultHeight, maximum: 3))
    }

    private static func nearestSpan(_ value: Double, cell: Double, maximum: Int = 2) -> Int {
        guard value.isFinite else { return 1 }
        return Int(min(max(((value + Self.defaultSpacing) / (cell + Self.defaultSpacing)).rounded(), 1), Double(maximum)))
    }

    private enum CodingKeys: String, CodingKey { case columnSpan, rowSpan, preferredWidth, preferredHeight }
    public init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        let legacyWidth = (try? values?.decode(Double.self, forKey: .preferredWidth)) ?? Self.defaultWidth
        let legacyHeight = (try? values?.decode(Double.self, forKey: .preferredHeight)) ?? Self.defaultHeight
        self.init(columnSpan: (try? values?.decode(Int.self, forKey: .columnSpan))
                    ?? Self.nearestSpan(legacyWidth, cell: Self.defaultWidth),
                  rowSpan: (try? values?.decode(Int.self, forKey: .rowSpan))
                    ?? Self.nearestSpan(legacyHeight, cell: Self.defaultHeight, maximum: 3))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(columnSpan, forKey: .columnSpan)
        try values.encode(rowSpan, forKey: .rowSpan)
    }
}

/// User-defined groups contain either devices or data sources. Their stable identity is
/// independent of their editable title and their position in the control center.
public struct DeviceControlCenterGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public private(set) var title: String

    public init(id: String = UUID().uuidString, title: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case id, title }
    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(id: "", title: ""); return
        }
        self.init(id: (try? values.decode(String.self, forKey: .id)) ?? "",
                  title: (try? values.decode(String.self, forKey: .title)) ?? "")
    }
}

/// A single desktop layout, keyed by the complete card identity. Device and source prefixes
/// remain part of the key, so equally named devices and different source kinds never share sizes.
public struct DeviceControlCenterLayout: Codable, Equatable, Sendable {
    public private(set) var cardSizes: [String: DeviceControlCenterCardSize]
    public private(set) var cardOrder: [String]
    public private(set) var groups: [DeviceControlCenterGroup]
    public private(set) var cardGroups: [String: String]
    public private(set) var hiddenCardIDs: Set<String>
    public private(set) var homeAssistantSelections: [String: ControlCenterHASelection]

    public init(cardSizes: [String: DeviceControlCenterCardSize] = [:], cardOrder: [String] = [],
                groups: [DeviceControlCenterGroup] = [], cardGroups: [String: String] = [:],
                hiddenCardIDs: Set<String> = [],
                homeAssistantSelections: [String: ControlCenterHASelection] = [:]) {
        self.cardSizes = cardSizes.filter { !$0.key.isEmpty }
        self.cardOrder = Self.uniqueIDs(cardOrder)
        var seen = Set<String>()
        self.groups = groups.filter { !$0.id.isEmpty && !$0.title.isEmpty && seen.insert($0.id).inserted }
        let groupIDs = Set(self.groups.map(\.id))
        // Keep settings for temporarily unavailable cards, but never create an invisible
        // section from a stale or malformed group reference.
        self.cardGroups = cardGroups.filter { !$0.key.isEmpty && groupIDs.contains($0.value) }
        self.hiddenCardIDs = hiddenCardIDs.filter { !$0.isEmpty }
        self.homeAssistantSelections = homeAssistantSelections.filter { !$0.key.isEmpty }
    }

    public func size(for id: String) -> DeviceControlCenterCardSize {
        cardSizes[id] ?? DeviceControlCenterCardSize()
    }

    /// Retained cards keep their user order; new cards append in the supplied default order.
    /// Deleted cards and duplicate identifiers never produce invisible gaps or duplicate views.
    public func orderedIDs(for available: [String]) -> [String] {
        let unique = Self.uniqueIDs(available)
        let availableSet = Set(unique)
        return Self.uniqueIDs(cardOrder.filter { availableSet.contains($0) } + unique)
    }

    /// A nil group selects the mixed, ungrouped grid. Grouping is only a projection of the
    /// global card order, so moving between groups does not discard the user's arrangement.
    public func orderedIDs(for available: [String], inGroup groupID: String?) -> [String] {
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return [] }
        return orderedIDs(for: available).filter { self.groupID(for: $0) == groupID }
    }

    public func groupID(for cardID: String) -> String? { cardGroups[cardID] }

    public func isCardVisible(_ id: String) -> Bool { !id.isEmpty && !hiddenCardIDs.contains(id) }

    /// Visibility is a local presentation preference. Hiding a card retains its
    /// settings, group and order, so restoring it returns to its previous place.
    @discardableResult public mutating func setCardVisible(_ visible: Bool, for id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if visible { return hiddenCardIDs.remove(id) != nil }
        return hiddenCardIDs.insert(id).inserted
    }

    public func visibleIDs(for available: [String]) -> [String] {
        orderedIDs(for: available).filter(isCardVisible)
    }

    public func visibleIDs(for available: [String], inGroup groupID: String?) -> [String] {
        orderedIDs(for: available, inGroup: groupID).filter(isCardVisible)
    }

    public func homeAssistantEntityIDs(for sourceID: String, connectionFingerprint: String) -> [String] {
        guard let saved = homeAssistantSelections[sourceID], saved.connectionFingerprint == connectionFingerprint else { return [] }
        return saved.entityIDs
    }

    @discardableResult public mutating func setHomeAssistantEntities(for sourceID: String,
            connectionFingerprint: String, entityIDs: [String]) -> Bool {
        guard !sourceID.isEmpty, !connectionFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let selection = ControlCenterHASelection(connectionFingerprint: connectionFingerprint, entityIDs: entityIDs)
        guard homeAssistantSelections[sourceID] != selection else { return false }
        homeAssistantSelections[sourceID] = selection
        return true
    }

    /// Empty titles are rejected without changing the layout. Duplicate titles remain
    /// independently editable because group identity does not depend on the title.
    @discardableResult public mutating func createGroup(title: String) -> String? {
        let group = DeviceControlCenterGroup(title: title)
        guard !group.title.isEmpty else { return nil }
        groups.append(group)
        return group.id
    }

    @discardableResult public mutating func renameGroup(_ id: String, title: String) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let renamed = DeviceControlCenterGroup(id: id, title: title)
        guard !renamed.title.isEmpty, renamed != groups[index] else { return false }
        groups[index] = renamed
        return true
    }

    /// Removing a group returns all its cards, including currently unavailable cards, to
    /// the mixed grid. Their sizes and relative order are unchanged.
    @discardableResult public mutating func removeGroup(_ id: String) -> Bool {
        guard groups.contains(where: { $0.id == id }) else { return false }
        groups.removeAll { $0.id == id }
        cardGroups = cardGroups.filter { $0.value != id }
        return true
    }

    @discardableResult public mutating func moveGroup(_ id: String, to index: Int) -> Bool {
        guard let current = groups.firstIndex(where: { $0.id == id }) else { return false }
        var next = groups
        let group = next.remove(at: current)
        next.insert(group, at: min(max(index, 0), next.count))
        guard next != groups else { return false }
        groups = next
        return true
    }

    @discardableResult public mutating func setGroup(for cardID: String, to groupID: String?) -> Bool {
        guard !cardID.isEmpty else { return false }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return false }
        guard cardGroups[cardID] != groupID else { return false }
        cardGroups[cardID] = groupID
        return true
    }

    @discardableResult public mutating func setSize(for id: String, width: Double, height: Double) -> Bool {
        guard !id.isEmpty else { return false }
        let size = DeviceControlCenterCardSize(preferredWidth: width, preferredHeight: height)
        guard self.size(for: id) != size else { return false }
        cardSizes[id] = size
        return true
    }

    /// Index refers to the final order after removing the dragged item. It is clamped so a
    /// drop outside the collection safely places the card at the beginning or the end.
    @discardableResult public mutating func move(_ id: String, to index: Int, availableIDs: [String],
                                                allAvailableIDs: [String]? = nil) -> Bool {
        let previous = orderedIDs(for: availableIDs)
        guard previous.contains(id) else { return false }
        var next = previous.filter { $0 != id }
        next.insert(id, at: min(max(index, 0), next.count))
        guard next != previous else { return false }
        // Materialize the complete default order before changing a visible section.
        // A legacy/first layout has no saved order yet, but hidden cards still own slots.
        // Retain unavailable saved identities as well as the current complete catalog.
        let completeOrder = Self.uniqueIDs(cardOrder + orderedIDs(for: allAvailableIDs ?? availableIDs) + previous)
        // A section may supply only its own cards. Replace only that section's slots.
        let scope = Set(previous)
        var replacement = next.makeIterator()
        cardOrder = completeOrder.map { existing in
            scope.contains(existing) ? (replacement.next() ?? existing) : existing
        }
        return true
    }

    @discardableResult public mutating func move(_ id: String, before target: String, availableIDs: [String],
                                                allAvailableIDs: [String]? = nil) -> Bool {
        guard id != target else { return false }
        let others = orderedIDs(for: availableIDs).filter { $0 != id }
        guard let index = others.firstIndex(of: target) else { return false }
        return move(id, to: index, availableIDs: availableIDs, allAvailableIDs: allAvailableIDs)
    }

    @discardableResult public mutating func move(_ id: String, after target: String, availableIDs: [String],
                                                allAvailableIDs: [String]? = nil) -> Bool {
        guard id != target else { return false }
        let others = orderedIDs(for: availableIDs).filter { $0 != id }
        guard let index = others.firstIndex(of: target) else { return false }
        return move(id, to: index + 1, availableIDs: availableIDs, allAvailableIDs: allAvailableIDs)
    }

    public mutating func resetSize(for id: String) { cardSizes[id] = nil }
    public mutating func resetOrder() { cardOrder = [] }
    /// Restores arrangement and visibility while preserving each source's chosen
    /// content. A layout reset must not erase independent Home Assistant choices.
    public mutating func reset() { cardSizes = [:]; cardOrder = []; groups = []; cardGroups = [:]; hiddenCardIDs = [] }

    private static func uniqueIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey { case cardSizes, cardOrder, groups, cardGroups, hiddenCardIDs, homeAssistantSelections }
    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { self.init(); return }
        let sizes = (try? values.decode([String: DeviceControlCenterCardSize].self, forKey: .cardSizes)) ?? [:]
        let order = (try? values.decode([String].self, forKey: .cardOrder)) ?? []
        let groups = (try? values.decode([DeviceControlCenterGroup].self, forKey: .groups)) ?? []
        let cardGroups = (try? values.decode([String: String].self, forKey: .cardGroups)) ?? [:]
        let hidden = (try? values.decode(Set<String>.self, forKey: .hiddenCardIDs)) ?? []
        let selections = (try? values.decode([String: ControlCenterHASelection].self, forKey: .homeAssistantSelections)) ?? [:]
        self.init(cardSizes: sizes, cardOrder: order, groups: groups, cardGroups: cardGroups,
                  hiddenCardIDs: hidden, homeAssistantSelections: selections)
    }
}

public struct DeviceControlCenterLayoutItem: Equatable, Sendable {
    public let id: String
    public let size: DeviceControlCenterCardSize
    public init(id: String, size: DeviceControlCenterCardSize = .init()) {
        self.id = id; self.size = size
    }
}

public struct DeviceControlCenterLayoutFrame: Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Equal columns and responsive rows provide a common grid for every size combination.
/// Items keep their saved sequence; each is placed in the first available rectangle,
/// scanning from the beginning. A later small item can therefore fill an earlier hole
/// that a wide item could not use, without rewriting the saved order or sizes.
public enum DeviceControlCenterLayoutEngine {
    // Rendering density is independent of the legacy point sizes used to decode
    // saved 1×1 / 2×1 / 1×2 / 2×2 preferences. Compact cards have authored layouts.
    public static let minimumColumnWidth = 244.0
    public struct Grid: Equatable, Sendable {
        public let columnCount: Int
        public let columnWidth: Double
        public let rowHeight: Double
        public let spacing: Double

        /// A drag advances only after crossing half of the current grid cell. Using the
        /// saved spans preserves a wide card's preference even in a temporary single column.
        public func snappedSize(original: DeviceControlCenterCardSize, translation: CGSize) -> DeviceControlCenterCardSize {
            func delta(_ translation: Double, step: Double) -> Int {
                guard translation.isFinite else { return 0 }
                return Int(min(max(translation / step, -2), 2).rounded())
            }
            let columnDelta = delta(translation.width, step: columnWidth + spacing)
            let columns = min(max(original.columnSpan + columnDelta, 1), 2)
            let rows = min(max(original.rowSpan + delta(translation.height, step: rowHeight + spacing), 1), 3)
            // Growing downward from a narrow card selects the authored 2×3
            // layout. An explicit horizontal shrink of a 2×3 card returns to
            // 1×2 rather than making its third row impossible to remove.
            return .init(columnSpan: rows == 3 && columns == 1 && columnDelta >= 0 ? 2 : columns,
                         rowSpan: rows)
        }
    }

    public static func grid(availableWidth: Double, spacing: Double = DeviceControlCenterCardSize.defaultSpacing) -> Grid {
        let width = availableWidth.isFinite && availableWidth > 0 ? min(availableWidth, 100_000) : DeviceControlCenterCardSize.defaultWidth
        let gap = spacing.isFinite ? min(max(spacing, 0), 80) : DeviceControlCenterCardSize.defaultSpacing
        let columns = max(1, Int(((width + gap) / (minimumColumnWidth + gap)).rounded(.down)))
        let columnWidth = (width - Double(columns - 1) * gap) / Double(columns)
        let rowHeight = min(320, max(264, columnWidth * 0.96))
        return .init(columnCount: columns, columnWidth: columnWidth, rowHeight: rowHeight, spacing: gap)
    }

    public static func frames(items: [DeviceControlCenterLayoutItem], availableWidth: Double,
                              spacing: Double = DeviceControlCenterCardSize.defaultSpacing) -> [DeviceControlCenterLayoutFrame] {
        var placement = Placement(grid: grid(availableWidth: availableWidth, spacing: spacing))
        var seen = Set<String>()
        var frames: [DeviceControlCenterLayoutFrame] = []
        for item in items where !item.id.isEmpty && seen.insert(item.id).inserted {
            frames.append(placement.place(item))
        }
        return frames
    }

    /// Resolve a drop against actual grid positions, including empty cells. `point`
    /// is local to the grid content, excluding any group title or outer padding.
    /// `items` is the destination section's ordered items, including the dragged
    /// item (append it for a cross-group drop). The returned insertion index is
    /// relative to that list after removing the dragged item, matching Layout.move.
    ///
    /// Only preceding items determine a candidate's first-fit position. Visiting
    /// these prefixes once finds the closest reachable cell without repeatedly
    /// repacking the entire section. Equal positions retain the nearest saved index
    /// to avoid incidental reordering when the pointer has not moved the card.
    public static func insertionIndex(for id: String, at point: CGPoint,
                                      items: [DeviceControlCenterLayoutItem], availableWidth: Double,
                                      spacing: Double = DeviceControlCenterCardSize.defaultSpacing) -> Int? {
        guard !id.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        var seen = Set<String>()
        let ordered = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard let originalIndex = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let dragged = ordered[originalIndex]
        let others = ordered.filter { $0.id != id }
        let grid = grid(availableWidth: availableWidth, spacing: spacing)
        let columnStep = grid.columnWidth + grid.spacing
        let rowStep = grid.rowHeight + grid.spacing
        // Associate the gutter with its nearest cell and bound extreme finite
        // points before scoring. At most three rows per item can be occupied.
        let targetColumn = min(max(((point.x + grid.spacing / 2) / columnStep).rounded(.down), 0),
                               Double(grid.columnCount - 1))
        let targetRow = min(max(((point.y + grid.spacing / 2) / rowStep).rounded(.down), 0),
                            Double(others.count) * 3 + 3)
        var placement = Placement(grid: grid)
        var bestIndex = originalIndex
        var bestDistance = Double.infinity
        var bestMove = Int.max
        for index in 0...others.count {
            let candidate = placement.nextFrame(for: dragged)
            let dx = candidate.x / columnStep - targetColumn
            let dy = candidate.y / rowStep - targetRow
            let distance = dx * dx + dy * dy
            let move = abs(index - originalIndex)
            if distance < bestDistance - 0.000_001
                || (abs(distance - bestDistance) <= 0.000_001 && move < bestMove) {
                bestIndex = index
                bestDistance = distance
                bestMove = move
            }
            if index < others.count { _ = placement.place(others[index]) }
        }
        return bestIndex
    }

    private struct Placement {
        let grid: Grid
        var occupied = Set<Int>()

        mutating func place(_ item: DeviceControlCenterLayoutItem) -> DeviceControlCenterLayoutFrame {
            let frame = nextFrame(for: item)
            occupied.formUnion(cells(for: item,
                row: Int((frame.y / (grid.rowHeight + grid.spacing)).rounded()),
                column: Int((frame.x / (grid.columnWidth + grid.spacing)).rounded())))
            return frame
        }

        func nextFrame(for item: DeviceControlCenterLayoutItem) -> DeviceControlCenterLayoutFrame {
            let columns = min(item.size.columnSpan, grid.columnCount)
            // A two-column square should not become an enormous portrait when
            // the window only fits one column. Its saved preference is retained.
            let rows = columns < item.size.columnSpan ? 1 : item.size.rowSpan
            var cursor = 0
            while true {
                let row = cursor / grid.columnCount
                let column = cursor % grid.columnCount
                if column + columns <= grid.columnCount {
                    if cells(for: item, row: row, column: column).allSatisfy({ !occupied.contains($0) }) {
                        return .init(id: item.id,
                                     x: Double(column) * (grid.columnWidth + grid.spacing),
                                     y: Double(row) * (grid.rowHeight + grid.spacing),
                                     width: Double(columns) * grid.columnWidth + Double(columns - 1) * grid.spacing,
                                     height: Double(rows) * grid.rowHeight + Double(rows - 1) * grid.spacing)
                    }
                }
                cursor += 1
            }
        }

        private func cells(for item: DeviceControlCenterLayoutItem, row: Int, column: Int) -> [Int] {
            let columns = min(item.size.columnSpan, grid.columnCount)
            let rows = columns < item.size.columnSpan ? 1 : item.size.rowSpan
            return (0..<rows).flatMap { dy in
                (0..<columns).map { dx in (row + dy) * grid.columnCount + column + dx }
            }
        }
    }
}
