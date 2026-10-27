import Foundation
import CryptoKit
import LinxDisplayCore

@main struct ReadingNotesTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let system = fixture.appendingPathComponent("books/.pico-system")
        let fm = FileManager.default
        let db = fixture.appendingPathComponent("mac-db")
        let deviceA = UUID(), deviceB = UUID()
        let store = ReadPicoReadingNotesStore(rootURL: db)
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1; print("PASS " + message) }
        func sourceDigest() throws -> String {
            let files = try fm.contentsOfDirectory(at: system, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            var data = Data()
            for file in files { data.append(Data(file.lastPathComponent.utf8)); data.append(try Data(contentsOf: file)) }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let originalDigest = try sourceDigest()
        let imported = try await store.importCard(rootURL: fixture, deviceID: deviceA)
        check(imported.imported == 4 && imported.total == 4 && !imported.usedBackup, "actual C-layout v3 index/object files import into Mac")
        var notes = try await store.notes()
        check(notes.allSatisfy { $0.bookPath == "/sdcard/books/真实图书.epub" && $0.fileBytes == 123456 && $0.chapter == 2 && $0.start == 12 && $0.end == 42 }, "source book identity and exact UTF8 chapter anchors survive import")
        check(Set(notes.filter { $0.kind == .note }.map(\.anchorID)).count == 1 && notes.filter { $0.kind == .note }.count == 2, "distinct notes at the same stable anchor are preserved")
        let repeated = try await store.importFile(system.appendingPathComponent("reader-r3-index.dat"), deviceID: deviceB)
        check(repeated.imported == 0 && repeated.duplicates == 4 && repeated.total == 4, "repeat import deduplicates independent of object IDs or reader identity")
        notes = try await store.notes()
        check(notes.allSatisfy { Set($0.sourceDeviceIDs) == [deviceA, deviceB] }, "deduplicated records retain provenance from both actual readers")
        let all = Set(notes.map(\.id))
        check(try await store.nextCard(target: deviceA.uuidString) == nil, "no record is exposed to a device before explicit authorization")
        try await store.setAuthorization(noteIDs: all, target: deviceA.uuidString, includeNotes: false)
        var cycle: [String] = []
        for _ in 0..<3 {
            let card = try await store.nextCard(target: deviceA.uuidString, instance: "module-a")!
            cycle.append(card.id)
            check(card.note == nil && card.body == card.quote && !card.sourceTitle.isEmpty, "default card projection excludes private notes and includes quote/source")
        }
        check(Set(cycle).count == 3, "each randomized cycle has no repetitions and excludes empty bookmarks")
        let reopened = ReadPicoReadingNotesStore(rootURL: db)
        let next = try await reopened.nextCard(target: deviceA.uuidString, instance: "module-a")!
        check(next.id != cycle.last, "restart preserves shuffle state and avoids a boundary repeat")
        check(try await reopened.nextCard(target: deviceB.uuidString) == nil, "authorization is independent for another device")
        let privateIDs = Set(notes.filter { !$0.note.isEmpty }.map(\.id))
        try await store.setAuthorization(noteIDs: privateIDs, target: deviceB.uuidString, includeNotes: true)
        let sharedPrivate = try await store.nextCard(target: deviceB.uuidString)!
        check(sharedPrivate.note?.isEmpty == false, "private annotation appears only after explicit per-device opt-in")
        try await store.removeAuthorization(noteIDs: all, target: deviceA.uuidString)
        let revokedCard = try await store.nextCard(target: deviceA.uuidString)
        let retainedNotes = try await store.notes()
        check(revokedCard == nil && retainedNotes.count == 4, "revoking display permission retains the Mac originals")
        let ordinary = fixture.appendingPathComponent("普通笔记.txt"); try Data("我不是固件批注记录".utf8).write(to: ordinary)
        do { _ = try await store.importFile(ordinary); preconditionFailure("ordinary txt accepted") } catch { check(true, "ordinary TXT is never misrepresented as anchored reading notes") }
        let object = system.appendingPathComponent("reader-r3-o-2.dat")
        let originalObject = try Data(contentsOf: object)
        var broken = originalObject; broken[60] ^= 1; try broken.write(to: object)
        do { _ = try await store.importCard(rootURL: fixture); preconditionFailure("bad CRC accepted") } catch { check((try await store.notes()).count == 4, "corrupt object aborts the whole import without partially replacing Mac data") }
        let objectBackup = system.appendingPathComponent("reader-r3-o-2.bak")
        try originalObject.write(to: objectBackup)
        let recoveredObject = try await store.importCard(rootURL: fixture)
        check(recoveredObject.usedBackup && recoveredObject.imported == 0, "valid object backup recovers without duplicating records")
        try originalObject.write(to: object); try fm.removeItem(at: objectBackup)
        let index = system.appendingPathComponent("reader-r3-index.dat"), indexBackup = system.appendingPathComponent("reader-r3-index.bak")
        let originalIndex = try Data(contentsOf: index)
        try originalIndex.write(to: indexBackup)
        var brokenIndex = originalIndex; brokenIndex[20] ^= 1; try brokenIndex.write(to: index)
        check(try await store.importCard(rootURL: fixture).usedBackup, "valid committed index backup recovers a damaged primary index")
        try originalIndex.write(to: index); try fm.removeItem(at: indexBackup)
        let outside = fixture.appendingPathComponent("outside.dat"); try originalObject.write(to: outside)
        try fm.removeItem(at: object); try fm.createSymbolicLink(at: object, withDestinationURL: outside)
        do { _ = try await store.importCard(rootURL: fixture); preconditionFailure("symlink object accepted") } catch { check(true, "source object symlinks are rejected") }
        try fm.removeItem(at: object); try originalObject.write(to: object)
        check(try sourceDigest() == originalDigest, "successful sync/authorization/shuffle never modifies source files")
        let c1 = ReadPicoReadingNotesStore(rootURL: db), c2 = ReadPicoReadingNotesStore(rootURL: db)
        async let r1 = c1.importCard(rootURL: fixture, deviceID: deviceA)
        async let r2 = c2.importCard(rootURL: fixture, deviceID: deviceB)
        _ = try await (r1, r2)
        check((try await store.notes()).count == 4, "separate store actors serialize JSON transactions through a real file lock")
        try await store.removeFromMac(noteIDs: privateIDs)
        let remainingNotes = try await store.notes()
        let remainingGrants = try await store.authorization(target: deviceB.uuidString)
        check(remainingNotes.count == 2 && remainingGrants.isEmpty, "removing Mac copies clears dependent grants without touching TF")
        check(try sourceDigest() == originalDigest, "Mac removal leaves all original TF records intact")
        let wrongTarget = "pico-sample"
        do { try await store.setAuthorization(noteIDs: [], target: wrongTarget, includeNotes: false); preconditionFailure("virtual target accepted") } catch { check(true, "permissions require a real UUID target") }

        // Synthetic dual-root USB export: actual user TF/internal note content is never accessed.
        let exportCard = fixture.appendingPathComponent("export-card")
        let exportRoot = exportCard.appendingPathComponent("readpico/reading-notes")
        let internalRoot = exportRoot.appendingPathComponent("internal-a")
        let tfRoot = exportRoot.appendingPathComponent("tf-a")
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try fm.copyItem(at: system, to: internalRoot); try fm.copyItem(at: system, to: tfRoot)
        func number(_ data: Data, _ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
        }
        func putNumber(_ value: UInt32, _ data: inout Data, _ at: Int) {
            for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        func crc32(_ payload: Data) -> UInt32 {
            var crc = UInt32.max
            for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) } }
            return ~crc
        }
        for objectID in 1...4 {
            let url = internalRoot.appendingPathComponent("reader-r3-o-\(objectID).dat")
            var data = try Data(contentsOf: url)
            let at = 12 + 544
            data.replaceSubrange(at..<(at + 288), with: Data(repeating: 0, count: 288))
            let path = Data("/flash/books/内置图书.epub".utf8)
            data.replaceSubrange(at..<(at + path.count), with: path)
            putNumber(crc32(Data(data.dropFirst(12))), &data, 8)
            try data.write(to: url)
        }
        let manifestURL = exportRoot.appendingPathComponent("manifest.json")
        func source(_ directory: String) throws -> [String: Any] {
            let index = try Data(contentsOf: exportRoot.appendingPathComponent(directory).appendingPathComponent("reader-r3-index.dat"))
            return ["directory": directory, "index_crc32": number(index, 8), "sequence": number(index, 12 + 8)]
        }
        func writeManifest(_ sources: [[String: Any]], complete: Bool = true) throws {
            try JSONSerialization.data(withJSONObject: ["version": 1, "complete": complete, "sources": sources], options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        }
        let sourceEntries = try [source("internal-a"), source("tf-a")]
        try writeManifest(sourceEntries)
        let exported = ReadPicoReadingNotesStore(rootURL: fixture.appendingPathComponent("export-db"))
        let merged = try await exported.importCard(rootURL: exportCard, deviceID: deviceA)
        let mergedNotes = try await exported.notes()
        check(merged.imported == 8 && mergedNotes.filter { $0.bookPath.hasPrefix("/flash/") }.count == 4,
              "one USB export atomically imports both internal and TF committed notes")
        check(try ReadPicoReadingNotesParser.read(from: manifestURL).notes.count == 8,
              "manual manifest selection resolves the same complete dual-root export")
        check(try ReadPicoReadingNotesParser.read(from: internalRoot.appendingPathComponent("reader-r3-index.dat")).notes.count == 8,
              "selecting one exported index still validates the complete dual-root transaction")
        let exportedAgain = try await exported.importCard(rootURL: exportCard, deviceID: deviceA)
        check(exportedAgain.imported == 0 && exportedAgain.duplicates == 8,
              "reconnecting the same dual-root snapshot never duplicates Mac records")
        let syntheticLegacy = exportCard.appendingPathComponent("books/.pico-system")
        try fm.createDirectory(at: syntheticLegacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: system, to: syntheticLegacy)
        let exportedObject = tfRoot.appendingPathComponent("reader-r3-o-2.dat")
        let exportedOriginal = try Data(contentsOf: exportedObject)
        let exportedBackup = tfRoot.appendingPathComponent("reader-r3-o-2.bak")
        try exportedOriginal.write(to: exportedBackup)
        var exportedBroken = exportedOriginal; exportedBroken[60] ^= 1; try exportedBroken.write(to: exportedObject)
        do { _ = try await exported.importCard(rootURL: exportCard); preconditionFailure("partial export accepted") }
        catch { check((try await exported.notes()).count == 8, "one damaged source aborts both imports without falling back to stale native TF records or older object backups") }
        try exportedOriginal.write(to: exportedObject); try fm.removeItem(at: exportedBackup)
        var wrongCRC = sourceEntries; wrongCRC[1]["index_crc32"] = UInt32(0)
        try writeManifest(wrongCRC)
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("stale export accepted") }
        catch { check(true, "manifest/index CRC mismatch rejects stale or partly replaced export snapshots") }
        try writeManifest(sourceEntries, complete: false)
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("incomplete export accepted") }
        catch { check(true, "an unfinished export never falls back to native TF records") }
        try fm.removeItem(at: manifestURL)
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("missing manifest accepted") }
        catch { check(true, "missing commit manifest is reported as unfinished rather than an empty successful import") }
        var invalidDirectories = sourceEntries; invalidDirectories[0]["directory"] = "../books/.pico-system"
        try writeManifest(invalidDirectories)
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("manifest path escaped") }
        catch { check(true, "export manifest accepts only the fixed internal/TF bank directory allowlist") }
        try fm.copyItem(at: tfRoot, to: exportRoot.appendingPathComponent("tf-b"))
        try writeManifest([sourceEntries[0], source("tf-b")])
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("mixed bank transaction accepted") }
        catch { check(true, "mixed export generations cannot be imported as one complete transaction") }
        try writeManifest(sourceEntries)
        let safeExport = exportRoot.appendingPathComponent("original-internal-a")
        try fm.moveItem(at: internalRoot, to: safeExport)
        try fm.createSymbolicLink(at: internalRoot, withDestinationURL: safeExport)
        do { _ = try ReadPicoReadingNotesParser.read(from: exportCard); preconditionFailure("symlink snapshot accepted") }
        catch { check(true, "export directory symlinks are rejected before opening index/object files") }
        try fm.removeItem(at: internalRoot); try fm.moveItem(at: safeExport, to: internalRoot)
        try writeManifest([])
        check(try ReadPicoReadingNotesParser.read(from: exportCard).notes.isEmpty,
              "a committed empty export reports no device notes without reading stale TF records")
        for policy in ReadPicoReadingNotesSyncPolicy.allCases {
            let policyRoot = fixture.appendingPathComponent("review-" + policy.rawValue)
            let local = ReadPicoReadingNotesStore(rootURL: policyRoot)
            _ = try await local.importCard(rootURL: fixture)
            let databaseURL = policyRoot.appendingPathComponent("notes.json")
            var database = try JSONSerialization.jsonObject(with: Data(contentsOf: databaseURL)) as! [String: Any]
            var rows = database["notes"] as! [[String: Any]]
            let position = rows.firstIndex { $0["kind"] as? Int == 0 }!, originalID = rows[position]["id"] as! String
            let macID = "local-edit-" + originalID
            rows[position]["id"] = macID; rows[position]["note"] = "Mac 中已修改的批注版本"
            database["notes"] = rows
            try JSONSerialization.data(withJSONObject: database).write(to: databaseURL)
            let before = try Data(contentsOf: databaseURL)
            let review = try await local.prepareImport(fixture)
            check(review.needsReview && review.conflictingAnchors.count == 1 && review.picoOnlyCount == 1, "\(policy): actual parsed source detects changed anchor records")
            check(try Data(contentsOf: databaseURL) == before, "notes review is read-only until policy selected")
            _ = try await local.applyImport(review, policy: policy)
            let reconciled = try await local.notes()
            check(reconciled.count == (policy == .merge ? 5 : 4), "\(policy): selected merge policy changes actual database")
            check(reconciled.contains { $0.id == macID } == (policy != .preferPico), "\(policy): Mac conflict visibility follows policy")
            check(reconciled.contains { $0.id == originalID } == (policy != .preferMac), "\(policy): Pico conflict visibility follows policy")
            if policy == .preferPico {
                check(try await local.restoreBeforeReconciliation() == 1, "Pico preference preserves recoverable previous Mac conflict")
                check((try await local.notes()).count == 5, "recovery merges old conflict without dropping new records")
            }
            let stale = try await local.prepareImport(fixture)
            try await local.removeFromMac(noteIDs: [macID])
            if policy != .preferPico && reconciled.contains(where: { $0.id == macID }) || policy == .preferPico {
                do { _ = try await local.applyImport(stale, policy: policy); preconditionFailure("stale review applied") }
                catch { check(true, "local database mutation invalidates a pending notes review") }
            }
        }
        check(try sourceDigest() == originalDigest, "all preference and recovery paths leave Pico source records unchanged")
        print("PASS \(checks) true Pico reading-note import/database/privacy/rotation checks; no physical device accessed")
    }
}
