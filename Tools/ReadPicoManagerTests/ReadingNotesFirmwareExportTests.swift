import Foundation
import LinxDisplayCore

/// Uses only pico_reading_snapshot_host_test.c's synthetic build-directory fixture.
/// Deliberately prints counts only, never annotation bodies or source book names.
@main struct ReadingNotesFirmwareExportTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("synthetic firmware fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try ReadPicoReadingNotesParser.read(from: root)
        let internalCount = snapshot.notes.filter { (30...33).contains($0.start) }.count
        let tfCount = snapshot.notes.filter { (60...66).contains($0.start) }.count
        precondition(snapshot.notes.count == 5 && internalCount == 2 && tfCount == 3)
        precondition(!snapshot.usedBackup)
        print("PASS production firmware C serializer → production Mac Swift parser: 5 synthetic notes, internal 2 + TF 3, committed same-bank manifest CRC/sequence verified; no private note text emitted")
    }
}
