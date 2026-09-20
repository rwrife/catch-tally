import Foundation
import Testing
@testable import CatchTallyKit

/// Shared fixture: fresh migrated store with one species/session pair.
private func makeFixture() throws -> (CatchTallyStore, speciesId: Int64, sessionId: Int64, spotId: Int64) {
    let store = try CatchTallyStore()
    var spot = Spot(name: "Dock", description: "north side")
    try store.saveSpot(&spot)
    var species = Species(name: "Bass", keepLimitNote: "5 per day (my own note)")
    try store.saveSpecies(&species)
    var session = Session(date: Date(timeIntervalSince1970: 1_700_000_000), spotId: spot.id)
    try store.saveSession(&session)
    return (store, species.id!, session.id!, spot.id!)
}

@Suite("Tally arithmetic")
struct TallyTests {
    @Test("increment then decrement tracks live derived totals")
    func incrementDecrement() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 0, kept: 0))

        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 2, kept: 2))

        try store.decrement(sessionId: sessionId, speciesId: speciesId)
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 1, kept: 1))
    }

    @Test("decrement clamps at zero and mutates nothing")
    func clamping() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 0, kept: 0))

        #expect(throws: TallyError.clampedAtZero) {
            try store.decrement(sessionId: sessionId, speciesId: speciesId)
        }
        // Clamped decrement is a no-op: not journaled, so nothing becomes undoable.
        #expect(try store.canUndo() == false)
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 0, kept: 0))

        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.decrement(sessionId: sessionId, speciesId: speciesId)
        #expect(throws: TallyError.clampedAtZero) {
            try store.decrement(sessionId: sessionId, speciesId: speciesId)
        }
    }

    @Test("batch add appends all entries as one mutation")
    func batchAdd() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        let ids = try store.addBatch(sessionId: sessionId, speciesId: speciesId, count: 5)
        #expect(ids.count == 5)
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 5, kept: 5))

        // A whole batch is one undo step.
        try store.undoLast()
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 0, kept: 0))
    }

    @Test("kept-count derives from keep/release disposition")
    func keptCount() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        try store.addCatch(sessionId: sessionId, speciesId: speciesId, disposition: .kept)
        try store.addCatch(sessionId: sessionId, speciesId: speciesId, disposition: .released)
        try store.addBatch(sessionId: sessionId, speciesId: speciesId, count: 2, disposition: .released)
        try store.addCatch(sessionId: sessionId, speciesId: speciesId, disposition: .kept)

        // 2 kept + 3 released ⇒ total 5, kept 2 — derived, never stored.
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 5, kept: 2))

        let totals = try store.sessionTotals(sessionId: sessionId)
        #expect(totals[speciesId] == SpeciesTally(total: 5, kept: 2))
    }

    @Test("per-species tallies are isolated per session and species")
    func isolation() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        var other = Species(name: "Trout")
        try store.saveSpecies(&other)
        var session2 = Session(date: Date(timeIntervalSince1970: 1_700_001_000))
        try store.saveSession(&session2)

        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.addCatch(sessionId: sessionId, speciesId: other.id!)
        try store.addCatch(sessionId: session2.id!, speciesId: speciesId)

        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 2, kept: 2))
        #expect(try store.tally(sessionId: sessionId, speciesId: other.id!) == SpeciesTally(total: 1, kept: 1))
        #expect(try store.tally(sessionId: session2.id!, speciesId: speciesId) == SpeciesTally(total: 1, kept: 1))
    }
}

@Suite("Undo journal")
struct UndoTests {
    @Test("undo removes the last single add")
    func undoSingleAdd() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        #expect(try store.canUndo() == true)

        try store.undoLast()
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 1, kept: 1))
    }

    @Test("undo restores a decrement verbatim, including original id")
    func undoDecrement() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        let first = try store.addCatch(
            sessionId: sessionId, speciesId: speciesId,
            timestamp: Date(timeIntervalSince1970: 100))
        _ = try store.addCatch(
            sessionId: sessionId, speciesId: speciesId,
            timestamp: Date(timeIntervalSince1970: 200))

        try store.decrement(sessionId: sessionId, speciesId: speciesId)  // removes newest
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId) == SpeciesTally(total: 1, kept: 1))

        try store.undoLast()
        let entries = try store.fetchEntries(sessionId: sessionId)
        #expect(entries.count == 2)
        #expect(entries.map(\.id).contains(first))
        #expect(entries.map(\.timestamp) == [
            Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)])
    }

    @Test("each mutation is undoable exactly once")
    func undoConsumedOnce() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)
        try store.undoLast()
        #expect(try store.canUndo() == false)
        #expect(throws: TallyError.nothingToUndo) { try store.undoLast() }
    }

    @Test("undo with empty journal throws")
    func undoEmpty() throws {
        let (store, _, _, _) = try makeFixture()
        #expect(throws: TallyError.nothingToUndo) { try store.undoLast() }
    }

    @Test("undo survives store reopen (journal is durable)")
    func undoDurableAcrossReopen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchtally-undo-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatchTallyStore(url: dir)
        var species = Species(name: "Pike")
        try store.saveSpecies(&species)
        var session = Session(date: Date())
        try store.saveSession(&session)

        try store.addCatch(sessionId: session.id!, speciesId: species.id!)
        try store.addCatch(sessionId: session.id!, speciesId: species.id!)

        // Simulate app relaunch: reopen the same file.
        let reopened = try CatchTallyStore(url: dir)
        #expect(try reopened.canUndo() == true)
        try reopened.undoLast()
        #expect(try reopened.tally(sessionId: session.id!, speciesId: species.id!)
                == SpeciesTally(total: 1, kept: 1))
    }
}

@Suite("Persistence & migrations")
struct StoreTests {
    @Test("relaunching the store restores exact state")
    func relaunchRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchtally-rt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatchTallyStore(url: dir)
        var spot = Spot(name: "Rocky Point")
        try store.saveSpot(&spot)
        var species = Species(name: "Walleye", keepLimitNote: "keep 4 max (personal)")
        try store.saveSpecies(&species)
        var session = Session(
            date: Date(timeIntervalSince1970: 1_750_000_000), spotId: spot.id,
            notes: "evening bite", status: .active)
        try store.saveSession(&session)
        try store.addBatch(sessionId: session.id!, speciesId: species.id!, count: 3)

        let reopened = try CatchTallyStore(url: dir)
        let speciesAgain = try reopened.fetchSpecies()
        #expect(speciesAgain == [species])
        let sessionsAgain = try reopened.fetchSessions()
        #expect(sessionsAgain == [session])
        #expect(try reopened.tally(sessionId: session.id!, speciesId: species.id!)
                == SpeciesTally(total: 3, kept: 3))
    }

    @Test("fresh database migrates to the latest schema version")
    func freshMigration() throws {
        let store = try CatchTallyStore()
        #expect(try store.currentSchemaVersion() == "v2-species-name-index")
    }

    @Test("v1 database upgrades through the ordered migration path")
    func upgradePath() throws {
        // Rebuild a v1-only database by replaying just the first migration,
        // then verify the real migrator detects the pending v2 upgrade and
        // applies it without data loss.
        let store = try CatchTallyStore()

        // Drop to v1: remove the v2 artifact (index) and the v2 migration
        // bookkeeping row, exactly as a v1 database would look pre-upgrade.
        try store.write { w in
            try w.execute(sql: "DROP INDEX species_name")
            try w.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-species-name-index'")
        }
        #expect(try store.currentSchemaVersion() == "v1-initial")

        var species = Species(name: "Drum")
        try store.saveSpecies(&species)

        try store.migrate()  // upgrade path
        #expect(try store.currentSchemaVersion() == "v2-species-name-index")
        // Existing data survived the upgrade.
        #expect(try store.fetchSpecies().map(\.name) == ["Drum"])
    }

    @Test("CRUD: rename and delete species cascade correctly")
    func speciesCrud() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        try store.addCatch(sessionId: sessionId, speciesId: speciesId)

        try store.renameSpecies(id: speciesId, to: "Largemouth Bass")
        #expect(try store.fetchSpecies().first?.name == "Largemouth Bass")

        try store.deleteSpecies(id: speciesId)
        #expect(try store.fetchSpecies().isEmpty)
        // Cascading delete removed the entries too.
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId)
                == SpeciesTally(total: 0, kept: 0))

        #expect(throws: TallyError.notFound("species 999")) {
            try store.deleteSpecies(id: 999)
        }
    }

    @Test("session close updates status; spots keep freeform description only")
    func sessionAndSpot() throws {
        let (store, _, sessionId, spotId) = try makeFixture()
        try store.closeSession(id: sessionId)
        let sessions = try store.fetchSessions()
        #expect(sessions.first?.status == .closed)

        let spots = try store.fetchSpots()
        #expect(spots.first?.id == spotId)
        #expect(spots.first?.description == "north side")
        // Spot has no coordinate fields at all (compile-time guarantee) —
        // assert via CodingKeys shape instead:
        let keys = Set(["id", "name", "description"])
        let encoder = JSONEncoder()
        let data = try encoder.encode(spots.first!)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == keys)  // Spot has no coordinate fields at all
    }
}

@Suite("Unknown-length semantics")
struct UnknownLengthTests {
    @Test("entries without length are excluded from PB candidates entirely")
    func unknownExcluded() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        _ = try store.addCatch(sessionId: sessionId, speciesId: speciesId)  // no length

        // An entry WITH length inserted directly to mirror workbench edits.
        try store.write { w in
            var withLength = CatchEntry(
                sessionId: sessionId, speciesId: speciesId,
                length: 52.5, lengthUnit: .centimeters,
                disposition: .kept, timestamp: Date(timeIntervalSince1970: 500))
            try withLength.insert(w)
        }

        let candidates = try store.personalBestCandidates(speciesId: speciesId)
        #expect(candidates.count == 1)
        #expect(candidates.first?.length == 52.5)
        #expect(candidates.first?.unit == .centimeters)
        // The unknown-length entry still counts toward totals — exclusion is
        // PB-eligibility only, never arithmetic.
        #expect(try store.tally(sessionId: sessionId, speciesId: speciesId)
                == SpeciesTally(total: 2, kept: 2))
    }

    @Test("PB candidates rank by recorded value, no silent zero defaults")
    func rankingNoDefaults() throws {
        let (store, speciesId, sessionId, _) = try makeFixture()
        try store.write { w in
            for (len, unit, t) in [
                (40.0, LengthUnit.centimeters, 100.0),
                (16.0, LengthUnit.inches, 200.0),
                (55.0, LengthUnit.centimeters, 300.0),
            ] {
                var e = CatchEntry(
                    sessionId: sessionId, speciesId: speciesId,
                    length: len, lengthUnit: unit,
                    disposition: .kept, timestamp: Date(timeIntervalSince1970: t))
                try e.insert(w)
            }
        }
        let candidates = try store.personalBestCandidates(speciesId: speciesId)
        #expect(candidates.count == 3)  // unit-grouping happens at display time (#5)
        let cm = candidates.filter { $0.unit == .centimeters }
        #expect(cm.map(\.length) == [40.0, 55.0])
    }

    @Test("CatchEntry.hasLength distinguishes unknown from recorded")
    func hasLengthFlag() {
        let base = CatchEntry(sessionId: 1, speciesId: 1, timestamp: Date())
        #expect(!base.hasLength)
        let zeroLength = CatchEntry(
            sessionId: 1, speciesId: 1, length: 0, lengthUnit: .centimeters, timestamp: Date())
        #expect(zeroLength.hasLength)  // a recorded 0 is *recorded*, not unknown
        let unitless = CatchEntry(sessionId: 1, speciesId: 1, length: 30, timestamp: Date())
        #expect(!unitless.hasLength)   // half-recorded stays unknown
    }
}
