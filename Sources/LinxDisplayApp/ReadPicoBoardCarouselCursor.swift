import Foundation

/// A failed/in-flight request never advances the playlist or starts its dwell timer.
struct ReadPicoBoardCarouselCursor {
    private(set) var displayedID: UUID?
    private(set) var due: Date?

    func candidate(in playlist: ReadPicoBoardPlaylist, now: Date = Date()) -> ReadPicoBoardPlaylistItem? {
        if let due, due > now, let current = playlist.item(id: displayedID), current.enabled { return current }
        return playlist.item(after: displayedID)
    }
    mutating func confirm(_ item: ReadPicoBoardPlaylistItem, minimumInterval: Int, now: Date = Date()) {
        if item.id != displayedID || due == nil || due! <= now {
            displayedID = item.id
            due = now.addingTimeInterval(TimeInterval(max(item.durationSeconds, minimumInterval)))
        }
    }
    mutating func reset() { displayedID = nil; due = nil }
}
