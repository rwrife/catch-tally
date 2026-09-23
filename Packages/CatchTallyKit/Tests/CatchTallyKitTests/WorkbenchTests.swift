import Foundation
import Testing
@testable import CatchTallyKit

/// Shared fixture for the workbench suites: store + one session with a
/// few tally entries spanning dispositions and recorded lengths.
private func makeWorkbenchFixture() throws -> (
    store: CatchTallyStore, speciesId: Int64, sessionId: Int64, photos: InMemoryPhotoStore
) {
    let store = try CatchTallyStore()
    var species = Species(name: "Bass")
    try store.saveSpecies(&species)
    var session = Session(date: Date(timeIntervalSince1970: 1_700_000_000))
    try store.saveSession(&session)
    return (store, species.id!, session.id!, InMemoryPhotoStore())
}

@Suite("Entry editing (issue #4 workbench)")
struct EntryEditingTests {
    @Test("updateEntryDetail stores length+unit, disposition, and notes")
    func detailEdit() throws {
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        let updated = try store.updateEntryDetail(
            id: entryId, length: 42.5, lengthUnit: .centimeters,
            disposition: .released, notes:  "  threw it back  ")
        #expect(updated.length == 42.5)
        #expect(updated.lengthUnit == .centimeters)
        #expect(updated.disposition == .released)
        #expect(updated.notes == "threw it back")

        let fetched = try #require(try store.fetchEntry(id: entryId))
        #expect(fetched.hasLength)
    }

    @Test("length without unit (or unit without length) is rejected, row untouched")
    func incompleteLengthRejected() throws {
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        #expect(throws: TallyError.incompleteLength) {
            try store.updateEntryDetail(id: entryId, length: 12, lengthUnit: nil,
                                        disposition: .kept, notes: nil)
        }
        #expect(throws: TallyError.incompleteLength) {
            try store.updateEntryDetail(id: entryId, length: nil, lengthUnit: .inches,
                                        disposition: .kept, notes: nil)
        }
        // Rejection left the row exactly as it was.
        let untouched = try #require(try store.fetchEntry(id: entryId))
        #expect(untouched.length == nil && untouched.lengthUnit == nil)

        // Clearing both together is legal (length becomes unknown again).
        try store.updateEntryDetail(id: entryId, length: 12, lengthUnit: .inches,
                                    disposition: .kept, notes: nil)
        let cleared = try store.updateEntryDetail(id: entryId, length: nil, lengthUnit: nil,
                                                  disposition: .kept, notes: nil)
        #expect(!cleared.hasLength)
    }

    @Test("keep ↔ release transitions flip both ways")
    func dispositionToggle() throws {
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)  // kept

        #expect(try store.toggleDisposition(id: entryId) == .released)
        #expect(try store.toggleDisposition(id: entryId) == .kept)
        // Derived kept-count follows the flip.
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId).kept == 1)
        try store.toggleDisposition(id: entryId)
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId).kept == 0)
    }

    @Test("editing entries in a CLOSED session is allowed (dock-side editing)")
    func closedSessionEditing() throws {
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.closeSession(id: sessionId)

        let updated = try store.updateEntryDetail(
            id: entryId, length: 19, lengthUnit: .inches, disposition: .kept, notes: "keeper")
        #expect(updated.length == 19)
    }

    @Test("unknown entry id raises notFound")
    func missingEntry() throws {
        let (store, _, _, _) = try makeWorkbenchFixture()
        #expect(throws: TallyError.notFound("entry 999")) {
            try store.toggleDisposition(id: 999)
        }
    }
}

@Suite("Entry quick filters (issue #4)")
struct EntryFilterTests {
    @Test("filters partition released / kept / no-length-recorded")
    func filterSemantics() throws {
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        // 3 entries: kept with length, released with length, released no length.
        let a = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        let b = try store.addCatch(sessionId: sessionId, speciesId: speciesId,
                                   disposition: .released)
        let c = try store.addCatch(sessionId: sessionId, speciesId: speciesId,
                                   disposition: .released)
        try store.updateEntryDetail(id: a, length: 15, lengthUnit: .inches,
                                    disposition: .kept, notes: nil)
        try store.updateEntryDetail(id: b, length: 12, lengthUnit: .inches,
                                    disposition: .released, notes: nil)

        let all = try store.fetchEntries(sessionId: sessionId, filter: .all)
        #expect(all.map(\.id) == [a, b, c])
        #expect(try store.fetchEntries(sessionId: sessionId, filter: .kept).map(\.id) == [a])
        #expect(try store.fetchEntries(sessionId: sessionId, filter: .released).map(\.id) == [b, c])
        #expect(try store.fetchEntries(sessionId: sessionId, filter: .noLengthRecorded).map(\.id) == [c])
    }

    @Test("an entry with a length but no unit still counts as 'no length recorded'")
    func halfRecordedLengthIsUnknown() throws {
        let entry = CatchEntry(sessionId: 1, speciesId: 1, length: 10,
                               disposition: .kept, timestamp: Date())
        #expect(EntryFilter.noLengthRecorded.matches(entry))
        #expect(!entry.hasLength)
    }
}

@Suite("Photo copy lifecycle (issue #4, injected store)")
struct PhotoLifecycleTests {
    @Test("attach stores bytes + ref + alt text; detach deletes the file")
    func attachDetach() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let updated = try store.attachEntryPhoto(
            id: entryId, data: bytes, ref: "photo-1", altText: "  a fat bass  ", to: photos)
        #expect(updated.photoRef == "photo-1")
        #expect(updated.photoAltText == "a fat bass")
        #expect(try photos.readPhoto(ref: "photo-1") == bytes)
        #expect(try store.entryCount(usingPhotoRef: "photo-1") == 1)

        try store.detachEntryPhoto(id: entryId, from: photos)
        let after = try #require(try store.fetchEntry(id: entryId))
        #expect(after.photoRef == nil && after.photoAltText == nil)
        #expect(try photos.readPhoto(ref: "photo-1") == nil)  // file gone
        #expect(try store.entryCount(usingPhotoRef: "photo-1") == 0)
    }

    @Test("second attach is refused — replace requires explicit detach")
    func attachTwiceRefused() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.attachEntryPhoto(id: entryId, data: Data([1]), ref: "p1", altText: nil, to: photos)

        #expect(throws: PhotoStoreError.photoAlreadyAttached) {
            try store.attachEntryPhoto(id: entryId, data: Data([2]), ref: "p2", altText: nil, to: photos)
        }
        // The refused attach left nothing behind.
        #expect(try photos.readPhoto(ref: "p2") == nil)
        #expect(try photos.readPhoto(ref: "p1") == Data([1]))
    }

    @Test("detail edits never clobber the stored photo reference")
    func detailEditPreservesPhoto() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.attachEntryPhoto(id: entryId, data: Data([9]), ref: "keepme", altText: "alt", to: photos)

        let edited = try store.updateEntryDetail(
            id: entryId, length: 20, lengthUnit: .centimeters, disposition: .released, notes: "x")
        #expect(edited.photoRef == "keepme")
        #expect(edited.photoAltText == "alt")
    }

    @Test("alt text needs a photo; empty text clears the field")
    func altTextRules() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        #expect(throws: PhotoStoreError.photoMissing("(none)")) {
            try store.setEntryPhotoAltText(id: entryId, altText: "orphan alt")
        }

        try store.attachEntryPhoto(id: entryId, data: Data([1]), ref: "p", altText: "first", to: photos)
        try store.setEntryPhotoAltText(id: entryId, altText: "   ")
        #expect(try #require(try store.fetchEntry(id: entryId)).photoAltText == nil)
        try store.setEntryPhotoAltText(id: entryId, altText: "second")
        #expect(try #require(try store.fetchEntry(id: entryId)).photoAltText == "second")
    }

    @Test("hard delete removes row AND photo file")
    func deleteCleansPhoto() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.attachEntryPhoto(id: entryId, data: Data([7]), ref: "gone", altText: nil, to: photos)

        try store.deleteEntry(id: entryId, from: photos)
        #expect(try store.fetchEntry(id: entryId) == nil)
        #expect(try photos.readPhoto(ref: "gone") == nil)
    }

    @Test("a failed attach write leaves no reference behind (photo store throws first)")
    func attachWriteFailureLeavesNoRef() throws {
        struct Throwing: EntryPhotoStore {
            func writePhoto(data: Data, ref: String) throws { throw PhotoStoreError.photoMissing("simulated") }
            func readPhoto(ref: String) throws -> Data? { nil }
            func byteCount(ref: String) throws -> Int { 0 }
            func deletePhoto(ref: String) throws {}
        }
        let (store, speciesId, sessionId, _) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        #expect(throws: PhotoStoreError.self) {
            try store.attachEntryPhoto(id: entryId, data: Data([1]), ref: "x", altText: nil, to: Throwing())
        }
        #expect(try #require(try store.fetchEntry(id: entryId)).photoRef == nil)
    }

    @Test("decrement-undo restores photo fields verbatim (v3 column in tombstone path)")
    func undoRestoresPhotoFields() throws {
        let (store, speciesId, sessionId, photos) = try makeWorkbenchFixture()
        let entryId = try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.attachEntryPhoto(id: entryId, data: Data([5]), ref: "snap", altText: "trophy", to: photos)

        try store.decrement(sessionId: sessionId, speciesId: speciesId)
        #expect(try store.fetchEntry(id: entryId) == nil)
        try store.undoLast()

        let restored = try #require(try store.fetchEntry(id: entryId))
        #expect(restored.id == entryId)
        #expect(restored.photoRef == "snap")
        #expect(restored.photoAltText == "trophy")
    }
}

@Suite("Session freeze + audited date edits (issue #4)")
struct SessionFreezeTests {
    @Test("closing freezes the date; re-closing never overwrites the freeze")
    func freezeOnClose() throws {
        let (store, _, sessionId, _) = try makeWorkbenchFixture()
        let freezeTime = Date(timeIntervalSince1970: 1_800_000_000)
        try store.closeSession(id: sessionId, closedAt: freezeTime)

        var s = try #require(try store.fetchSession(id: sessionId))
        #expect(s.status == .closed)
        #expect(s.frozenDate == freezeTime)

        // Re-close with a different time: freeze is preserved.
        try store.closeSession(id: sessionId, closedAt: Date(timeIntervalSince1970: 1_900_000_000))
        s = try #require(try store.fetchSession(id: sessionId))
        #expect(s.frozenDate == freezeTime)
    }

    @Test("active sessions re-date freely; frozen ones demand an audit note")
    func auditGate() throws {
        let (store, _, sessionId, _) = try makeWorkbenchFixture()
        let newDate = Date(timeIntervalSince1970: 1_650_000_000)

        // Active: plain re-date works, and the audit method refuses to be
        // bypassed around (nothing to audit yet).
        try store.setSessionDate(id: sessionId, to: newDate)
        #expect(try #require(try store.fetchSession(id: sessionId)).date == newDate)
        #expect(throws: TallyError.self) {
            try store.editSessionDate(id: sessionId, to: newDate, auditNote: "no freeze yet")
        }

        try store.closeSession(id: sessionId)
        #expect(throws: TallyError.missingAuditNote) {
            try store.setSessionDate(id: sessionId, to: newDate)
        }
        #expect(throws: TallyError.missingAuditNote) {
            try store.editSessionDate(id: sessionId, to: newDate, auditNote: "   ")
        }
    }

    @Test("audited edit changes the date and appends the user's note verbatim")
    func auditTrail() throws {
        let (store, _, sessionId, _) = try makeWorkbenchFixture()
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        try store.closeSession(id: sessionId)

        try store.editSessionDate(
            id: sessionId, to: Date(timeIntervalSince1970: 1_600_000_000),
            auditNote: "logged it a day late")
        // A second edit appends — the trail is never overwritten.
        try store.editSessionDate(
            id: sessionId, to: Date(timeIntervalSince1970: 1_500_000_000),
            auditNote: "fixed after reviewing photo")

        let s = try #require(try store.fetchSession(id: sessionId))
        #expect(s.date == Date(timeIntervalSince1970: 1_500_000_000))
        // The freeze timestamp is untouched by date edits.
        #expect(s.frozenDate != nil && s.frozenDate! >= original)
        let lines = try #require(s.dateAuditNote).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try #require(s.dateAuditNote).contains("'logged it a day late'"))
        #expect(try #require(s.dateAuditNote).contains("'fixed after reviewing photo'"))
        #expect(try #require(s.dateAuditNote).contains("(was "))
    }

    @Test("freeze + audit trail survive a store reopen")
    func freezeDurable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchtally-freeze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatchTallyStore(url: url)
        var species = Species(name: "Pike")
        try store.saveSpecies(&species)
        var session = Session(date: Date(timeIntervalSince1970: 1_700_000_000))
        try store.saveSession(&session)
        try store.closeSession(id: session.id!, closedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.editSessionDate(
            id: session.id!, to: Date(timeIntervalSince1970: 1_600_000_000), auditNote: "late log")

        let reopened = try CatchTallyStore(url: url)
        let s = try #require(try reopened.fetchSession(id: session.id!))
        #expect(s.status == .closed)
        #expect(s.frozenDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(s.date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(try #require(s.dateAuditNote).contains("late log"))
    }
}

@Suite("Workspace layout seam (issue #4)")
struct TallyWorkspaceRoutingTests {
    @Test("compact always routes stacked")
    func compactRouting() {
        #expect(TallyWorkspaceRouting.route(band: .compact) == .stacked)
        #expect(TallyWorkspaceRouting.route(band: .compact, spannedSupportEnabled: true) == .stacked)
    }

    @Test("spanned routes stacked today; the documented hook flips it to split")
    func spannedHook() {
        // Shipped state: the seam's gate is off, so even spanned stays stacked.
        #expect(TallyWorkspaceRouting.spannedSupportEnabled == false)
        #expect(TallyWorkspaceRouting.route(band: .spanned) == .stacked)
        // Documented hook point for the future iPhone Duo workbench:
        // flipping the gate is the ONLY routing change needed.
        #expect(TallyWorkspaceRouting.route(band: .spanned, spannedSupportEnabled: true) == .split)
    }

    @Test("the seam is the only routing decision point in app sources")
    func seamIsSoleRouter() throws {
        // Source-scan proof, runnable on Linux with zero tooling:
        // 1) `horizontalSizeClass` may be read in exactly ONE app file —
        //    TallyWorkspaceLayout.swift — the seam's environment input.
        // 2) That file must route by calling `TallyWorkspaceRouting.route`.
        // 3) No app source may reference fold/unreleased-SDK API names.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CatchTallyKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CatchTallyKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let appDir = repoRoot.appendingPathComponent("CatchTally")
        let swiftFiles = try FileManager.default.contentsOfDirectory(atPath: appDir.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!swiftFiles.isEmpty, "expected app sources at \(appDir.path)")

        let forbidden = [
            "FoldStatus", "foldStatus", "FoldState", "foldState",
            "HingeAngle", "hingeAngle", "isUnfolded", "unfoldState",
            "SystemFold", "spanningMode",
        ]
        var sizeClassFiles: [String] = []
        for name in swiftFiles {
            let text = try String(
                contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token),
                        "forbidden fold/SDK API name '\(token)' in \(name)")
            }
            if text.contains("horizontalSizeClass") {
                sizeClassFiles.append(name)
            }
        }
        #expect(sizeClassFiles == ["TallyWorkspaceLayout.swift"],
                "size-class reading must be confined to the seam file, got \(sizeClassFiles)")

        let seamText = try String(
            contentsOf: appDir.appendingPathComponent("TallyWorkspaceLayout.swift"),
            encoding: .utf8)
        #expect(seamText.contains("TallyWorkspaceRouting.route"),
                "the seam file must delegate to the domain routing function")
    }
}
