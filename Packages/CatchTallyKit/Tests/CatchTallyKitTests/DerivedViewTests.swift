import Foundation
import Testing
@testable import CatchTallyKit

/// Shared fixture for the derived-view suite (issue #5): two species (one
/// with a numeric keep-limit note, one without), two spots, two sessions at
/// different spots, and entries spanning lengths/units/dispositions.
private struct DerivedFixture {
    let store: CatchTallyStore
    let keptSpeciesId: Int64      // "Bass", note "5 per day (my own note)"
    let plainSpeciesId: Int64     // "Trout", no note
    let dockId: Int64
    let riverId: Int64
    let dockSessionId: Int64
    let riverSessionId: Int64
}

private func makeDerivedFixture() throws -> DerivedFixture {
    let store = try CatchTallyStore()
    var bass = Species(name: "Bass", keepLimitNote: "5 per day (my own note)")
    try store.saveSpecies(&bass)
    var trout = Species(name: "Trout")
    try store.saveSpecies(&trout)
    var dock = Spot(name: "Dock")
    try store.saveSpot(&dock)
    var river = Spot(name: "River Bend")
    try store.saveSpot(&river)
    var s1 = Session(date: Date(timeIntervalSince1970: 1_700_000_000), spotId: dock.id)
    try store.saveSession(&s1)
    var s2 = Session(date: Date(timeIntervalSince1970: 1_800_000_000), spotId: river.id)
    try store.saveSession(&s2)
    return DerivedFixture(store: store, keptSpeciesId: bass.id!, plainSpeciesId: trout.id!,
                          dockId: dock.id!, riverId: river.id!,
                          dockSessionId: s1.id!, riverSessionId: s2.id!)
}

/// Add an entry with an explicit length through store + detail edit.
private func addLength(_ f: DerivedFixture, session: Int64, species: Int64,
                       length: Double?, unit: LengthUnit?, kept: Bool = true,
                       at ts: Date) throws -> Int64 {
    let id = try store0(f).addCatch(sessionId: session, speciesId: species,
                                    disposition: kept ? .kept : .released,
                                    timestamp: ts)
    _ = try store0(f).updateEntryDetail(id: id, length: length, lengthUnit: unit,
                                        disposition: kept ? .kept : .released, notes: nil)
    return id
}
private func store0(_ f: DerivedFixture) -> CatchTallyStore { f.store }

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func later(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_000_000 + seconds)
}

@Suite("Personal-best board (issue #5)")
struct PersonalBestBoardTests {
    @Test("PB ranks by length per unit; unknown lengths never fabricate a best")
    func rankingAndUnknowns() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 40, unit: .centimeters, at: t0)
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 55.5, unit: .centimeters, at: later(10))
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 60, unit: .centimeters, at: later(20))
        // A no-length entry: counted, never ranked.
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: nil, unit: nil, at: later(30))

        let board = try f.store.personalBestBoard()
        let bass = try #require(board.first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.totalEntries == 4)
        #expect(bass.entriesWithoutLength == 1)
        let cm = try #require(bass.bests.first { $0.unit == .centimeters })
        #expect(cm.length == 60)

        // Species with zero entries: no bests at all — visibly nothing, not zero.
        let trout = try #require(board.first { $0.speciesId == f.plainSpeciesId })
        #expect(trout.bests.isEmpty)
        #expect(!trout.hasAnyEntry)
        #expect(trout.totalEntries == 0)
    }

    @Test("lengths in different units are never mixed into one ranking")
    func unitGroups() throws {
        let f = try makeDerivedFixture()
        // 20 inches ≈ 50.8 cm numerically smaller than 55 — inches best
        // must be the 20-inch fish, cm best the 55-cm fish. Never compared.
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 55, unit: .centimeters, at: t0)
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 20, unit: .inches, at: later(10))
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 30, unit: .inches, at: later(20))

        let bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.count == 2)
        #expect(bass.bests.first { $0.unit == .centimeters }?.length == 55)
        #expect(bass.bests.first { $0.unit == .inches }?.length == 30)
    }

    @Test("exact ties keep the EARLIEST entry as the record holder")
    func tieBreak() throws {
        let f = try makeDerivedFixture()
        let first = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                                  length: 48, unit: .centimeters, at: t0)
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 48, unit: .centimeters, at: later(500))

        let bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        let best = try #require(bass.bests.first { $0.unit == .centimeters })
        #expect(best.entryId == first)
    }

    @Test("PB context carries session date and spot name")
    func context() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 61, unit: .centimeters, at: later(20))
        let bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        let best = try #require(bass.bests.first)
        #expect(best.spotName == "River Bend")
        #expect(best.sessionDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(best.recordedAt == later(20))
    }

    @Test("deleting a species removes its board row and entries (cascade)")
    func speciesCascade() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 50, unit: .centimeters, at: t0)
        try f.store.deleteSpecies(id: f.keptSpeciesId)

        let board = try f.store.personalBestBoard()
        #expect(board.count == 1)
        #expect(board[0].speciesId == f.plainSpeciesId)
        #expect(board[0].totalEntries == 0)
    }

    @Test("decrement + undo keeps the board consistent with live entries")
    func undoConsistency() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 70, unit: .centimeters, at: t0)
        var bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.first?.length == 70)

        try f.store.decrement(sessionId: f.dockSessionId, speciesId: f.keptSpeciesId)
        bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.isEmpty)  // gone ⇒ no best, never a stale one
        #expect(bass.totalEntries == 0)

        try f.store.undoLast()
        bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.first?.length == 70)  // restored verbatim
    }
}

@Suite("Spot history (issue #5)")
struct SpotHistoryTests {
    @Test("per-spot sessions, totals, and per-species bests at that spot")
    func history() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 40, unit: .centimeters, at: t0)
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 52, unit: .centimeters, kept: false, at: later(10))
        _ = try addLength(f, session: f.dockSessionId, species: f.plainSpeciesId,
                          length: 30, unit: .centimeters, at: later(20))
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 60, unit: .centimeters, at: later(30))

        let rows = try f.store.spotHistories()
        let dock = try #require(rows.first { $0.spotId == f.dockId })
        #expect(dock.totalCaught == 3)
        #expect(dock.kept == 2)  // one released
        #expect(dock.sessions.count == 1)
        #expect(dock.sessions[0].totalCaught == 3)
        // Per-species best at the dock — the river 60 must NOT leak in.
        let dockBass = try #require(dock.bestsPerSpecies.first { $0.speciesId == f.keptSpeciesId })
        #expect(dockBass.bests.first?.length == 52)

        let river = try #require(rows.first { $0.spotId == f.riverId })
        #expect(river.totalCaught == 1)
        let riverBass = try #require(river.bestsPerSpecies.first { $0.speciesId == f.keptSpeciesId })
        #expect(riverBass.bests.first?.length == 60)
    }

    @Test("spot with sessions but no entries: empty totals, no fabricated bests")
    func emptySpot() throws {
        let f = try makeDerivedFixture()
        let rows = try f.store.spotHistories()
        let dock = try #require(rows.first { $0.spotId == f.dockId })
        #expect(dock.sessions.count == 1)
        #expect(dock.totalCaught == 0)
        #expect(dock.bestsPerSpecies.isEmpty)
    }

    @Test("sessions at a spot sort newest-first")
    func sessionOrder() throws {
        let f = try makeDerivedFixture()
        var s3 = Session(date: Date(timeIntervalSince1970: 1_900_000_000), spotId: f.dockId)
        try f.store.saveSession(&s3)
        let dock = try #require(try f.store.spotHistories().first { $0.spotId == f.dockId })
        #expect(dock.sessions.count == 2)
        #expect(dock.sessions[0].date == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test("deleteSpot clears session references but keeps catch history")
    func spotDeletionCascade() throws {
        let f = try makeDerivedFixture()
        let entry = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                                  length: 44, unit: .centimeters, at: t0)
        try f.store.deleteSpot(id: f.dockId)

        // Spot history no longer lists the spot...
        #expect(try f.store.spotHistories().first { $0.spotId == f.dockId } == nil)
        // ...the session survives with no spot, entries intact...
        let session = try #require(try f.store.fetchSession(id: f.dockSessionId))
        #expect(session.spotId == nil)
        #expect(try f.store.fetchEntries(sessionId: f.dockSessionId).count == 1)
        // ...and the PB board still ranks the fish, with spot context gone.
        let bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.first?.length == 44)
        #expect(bass.bests.first?.entryId == entry)
        #expect(bass.bests.first?.spotName == nil)
    }

    @Test("deleting an unknown spot throws notFound")
    func spotDeleteNotFound() throws {
        let f = try makeDerivedFixture()
        #expect(throws: TallyError.notFound("spot 999")) {
            try f.store.deleteSpot(id: 999)
        }
    }
}

@Suite("Kept-count vs user limit notes (issue #5)")
struct KeptCountTests {
    @Test("kept counts aggregate across sessions; released excluded")
    func counts() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: nil, unit: nil, at: t0)
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: nil, unit: nil, at: later(10))
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: nil, unit: nil, kept: false, at: later(20))

        let rows = try f.store.keptCountDashboard()
        let bass = try #require(rows.first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.totalCaught == 3)
        #expect(bass.kept == 2)
        #expect(bass.parsedLimit == 5)
        #expect(!bass.reachedOrExceeded)
        #expect(bass.userNote == "5 per day (my own note)")  // verbatim
    }

    @Test("reach state triggers exactly at the parsed limit and above")
    func reach() throws {
        let f = try makeDerivedFixture()
        for i in 0..<5 {
            _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                              length: nil, unit: nil, at: later(TimeInterval(i)))
        }
        var bass = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.kept == 5)
        #expect(bass.reachedOrExceeded == true)   // meets ⇒ reminder state
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: nil, unit: nil, at: later(99))
        bass = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.reachedOrExceeded == true)   // exceeds ⇒ reminder state
    }

    @Test("no note ⇒ plain count, no parsed limit, never a reach state")
    func noNote() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.plainSpeciesId,
                          length: nil, unit: nil, at: t0)
        let trout = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.plainSpeciesId })
        #expect(trout.userNote == nil)
        #expect(trout.parsedLimit == nil)
        #expect(trout.reachedOrExceeded == false)
    }

    @Test("note without any number ⇒ no parsed limit, note still shown")
    func unparseableNote() throws {
        let f = try makeDerivedFixture()
        try f.store.setKeepLimitNote(speciesId: f.plainSpeciesId, note: "keep a few")
        _ = try addLength(f, session: f.dockSessionId, species: f.plainSpeciesId,
                          length: nil, unit: nil, at: t0)
        let trout = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.plainSpeciesId })
        #expect(trout.userNote == "keep a few")  // verbatim, even without digits
        #expect(trout.parsedLimit == nil)
        #expect(trout.reachedOrExceeded == false)
    }

    @Test("parsedLimit takes the first digit run only")
    func digitRun() {
        #expect(KeepLimitNote.parsedLimit(from: "5 per day (my own note)") == 5)
        #expect(KeepLimitNote.parsedLimit(from: "up to 12") == 12)
        #expect(KeepLimitNote.parsedLimit(from: "no numbers here") == nil)
        #expect(KeepLimitNote.parsedLimit(from: "7-8") == 7)
        #expect(KeepLimitNote.parsedLimit(from: nil) == nil)
        #expect(KeepLimitNote.parsedLimit(from: "") == nil)
    }

    @Test("setKeepLimitNote trims, stores verbatim, and clears on empty")
    func noteEditing() throws {
        let f = try makeDerivedFixture()
        try f.store.setKeepLimitNote(speciesId: f.plainSpeciesId,
                                     note: "  only the big ones (2 max)  ")
        var trout = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.plainSpeciesId })
        #expect(trout.userNote == "only the big ones (2 max)")
        #expect(trout.parsedLimit == 2)

        try f.store.setKeepLimitNote(speciesId: f.plainSpeciesId, note: "   ")
        trout = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.plainSpeciesId })
        #expect(trout.userNote == nil)
        #expect(trout.parsedLimit == nil)
        #expect(trout.reachedOrExceeded == false)
    }

    @Test("kept count follows disposition flips live")
    func flipLive() throws {
        let f = try makeDerivedFixture()
        let e = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                              length: nil, unit: nil, kept: false, at: t0)
        var bass = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.kept == 0)
        try f.store.toggleDisposition(id: e)
        bass = try #require(try f.store.keptCountDashboard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.kept == 1)
    }
}

@Suite("Derived views are recomputed, never stored (issue #5 determinism)")
struct DerivedDeterminismTests {
    @Test("two reads with no mutation in between return identical snapshots")
    func determinism() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.dockSessionId, species: f.keptSpeciesId,
                          length: 50, unit: .centimeters, at: t0)
        let boardA = try f.store.personalBestBoard()
        let boardB = try f.store.personalBestBoard()
        #expect(boardA == boardB)
        let spotsA = try f.store.spotHistories()
        let spotsB = try f.store.spotHistories()
        #expect(spotsA == spotsB)
        let keptA = try f.store.keptCountDashboard()
        let keptB = try f.store.keptCountDashboard()
        #expect(keptA == keptB)
    }

    @Test("frozen-date audit edits flow through to PB context")
    func auditedDateEdits() throws {
        let f = try makeDerivedFixture()
        _ = try addLength(f, session: f.riverSessionId, species: f.keptSpeciesId,
                          length: 66, unit: .centimeters, at: later(30))
        try f.store.closeSession(id: f.riverSessionId)
        try f.store.editSessionDate(id: f.riverSessionId,
                                    to: Date(timeIntervalSince1970: 1_750_000_000),
                                    auditNote: "logged a day late")
        let bass = try #require(try f.store.personalBestBoard()
            .first { $0.speciesId == f.keptSpeciesId })
        #expect(bass.bests.first?.sessionDate == Date(timeIntervalSince1970: 1_750_000_000))
    }
}
