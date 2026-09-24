import Foundation
import GRDB

// MARK: - Derived-view value types (issue #5)
//
// Everything here is a VIEW over `catch_entry` — recomputed on read, never
// stored as independent truth (PLAN.md determinism rule). Unknown stays
// unknown: an entry with no length never becomes a zero and never makes a
// personal best; a species with no keep-limit note gets a plain count only.

/// One personal-best record with the context needed to display it: which
/// session it happened in and (if known) which spot.
public struct PersonalBestDetail: Equatable, Sendable {
    public var entryId: Int64
    public var length: Double
    public var unit: LengthUnit
    /// When the catch happened (entry timestamp).
    public var recordedAt: Date
    /// The session's (possibly audited-edited) date.
    public var sessionDate: Date
    /// Spot name at display time; nil ⇒ session had no spot or the spot
    /// was deleted (the catch itself is never destroyed by spot deletion).
    public var spotName: String?

    public init(entryId: Int64, length: Double, unit: LengthUnit,
                recordedAt: Date, sessionDate: Date, spotName: String?) {
        self.entryId = entryId
        self.length = length
        self.unit = unit
        self.recordedAt = recordedAt
        self.sessionDate = sessionDate
        self.spotName = spotName
    }
}

/// Personal-best board row for one species.
///
/// `bests` holds at most one entry per recorded unit (lengths in different
/// units are never compared against each other). An empty `bests` means
/// "no length recorded" — the UI must show that state and must never
/// fabricate a PB.
public struct PersonalBestRow: Equatable, Sendable {
    public var speciesId: Int64
    public var speciesName: String
    /// One best per unit group, sorted by unit. Empty ⇒ nothing PB-eligible.
    public var bests: [PersonalBestDetail]
    /// Entries for this species missing a usable length (unknown, not zero).
    public var entriesWithoutLength: Int
    public var totalEntries: Int

    public init(speciesId: Int64, speciesName: String, bests: [PersonalBestDetail],
                entriesWithoutLength: Int, totalEntries: Int) {
        self.speciesId = speciesId
        self.speciesName = speciesName
        self.bests = bests
        self.entriesWithoutLength = entriesWithoutLength
        self.totalEntries = totalEntries
    }

    public var hasAnyEntry: Bool { totalEntries > 0 }
}

/// Per-species bests scoped to one spot (spot-history row).
public struct SpeciesBests: Equatable, Sendable {
    public var speciesId: Int64
    public var speciesName: String
    /// One best per unit group at this spot; empty ⇒ no length recorded here.
    public var bests: [PersonalBestDetail]

    public init(speciesId: Int64, speciesName: String, bests: [PersonalBestDetail]) {
        self.speciesId = speciesId
        self.speciesName = speciesName
        self.bests = bests
    }
}

/// Full history for one spot: its sessions, catch totals, and the best
/// caught of each species at that spot.
public struct SpotHistoryRow: Equatable, Sendable {
    public struct SessionSummary: Equatable, Sendable {
        public var sessionId: Int64
        public var date: Date
        public var status: SessionStatus
        public var totalCaught: Int
        public var kept: Int

        public init(sessionId: Int64, date: Date, status: SessionStatus,
                    totalCaught: Int, kept: Int) {
            self.sessionId = sessionId
            self.date = date
            self.status = status
            self.totalCaught = totalCaught
            self.kept = kept
        }
    }

    public var spotId: Int64
    public var spotName: String
    /// Sessions at this spot, newest first.
    public var sessions: [SessionSummary]
    public var totalCaught: Int
    public var kept: Int
    /// Per-species bests recorded in sessions AT this spot, by species name.
    public var bestsPerSpecies: [SpeciesBests]

    public init(spotId: Int64, spotName: String, sessions: [SessionSummary],
                totalCaught: Int, kept: Int, bestsPerSpecies: [SpeciesBests]) {
        self.spotId = spotId
        self.spotName = spotName
        self.sessions = sessions
        self.totalCaught = totalCaught
        self.kept = kept
        self.bestsPerSpecies = bestsPerSpecies
    }
}

/// Kept-count dashboard row: the user's own kept total against their own
/// typed keep-limit note. The note is quoted verbatim at display time and
/// is NEVER interpreted as regulation data (README non-goal).
public struct KeptCountRow: Equatable, Sendable {
    public var speciesId: Int64
    public var speciesName: String
    public var kept: Int
    public var totalCaught: Int
    /// The user's note verbatim; nil ⇒ plain count only, no reminder state.
    public var userNote: String?
    /// Numeric limit parsed from the note's first run of digits; nil ⇒ the
    /// note carries no comparable number, so NO reach state is claimed.
    public var parsedLimit: Int?
    /// true ⇒ `parsedLimit != nil && kept >= parsedLimit`. Never true
    /// without a parsed limit — no note, no number, no reminder.
    public var reachedOrExceeded: Bool

    public init(speciesId: Int64, speciesName: String, kept: Int, totalCaught: Int,
                userNote: String?, parsedLimit: Int?, reachedOrExceeded: Bool) {
        self.speciesId = speciesId
        self.speciesName = speciesName
        self.kept = kept
        self.totalCaught = totalCaught
        self.userNote = userNote
        self.parsedLimit = parsedLimit
        self.reachedOrExceeded = reachedOrExceeded
    }
}

// MARK: - User-note limit parsing

/// Deterministic extraction of the numeric limit a user typed in their own
/// keep-limit note: the FIRST run of decimal digits in the note.
///
/// This is deliberately dumb — the note is freeform personal text and the
/// app never treats it as regulation. A note with no digits ("keep few")
/// yields nil, so the UI shows a plain count with no reminder state.
public enum KeepLimitNote {
    public static func parsedLimit(from note: String?) -> Int? {
        guard let note, !note.isEmpty else { return nil }
        var digits = ""
        for ch in note {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Store: derived-view queries

extension CatchTallyStore {

    /// Personal-best board for every species, recomputed live from
    /// `catch_entry`. Ranking groups by unit; ties resolve to the earliest
    /// recorded entry (timestamp, then id) — the first fish that set the
    /// mark owns it.
    public func personalBestBoard() throws -> [PersonalBestRow] {
        try reader.read { r in
            let species: [Species] = try Species.order(Column("name")).fetchAll(r)

            // Every length-bearing entry with session/spot context.
            let candidateRows = try Row.fetchAll(
                r,
                sql: """
                SELECT e.id AS entryId, e.speciesId AS speciesId,
                       e.length AS length, e.lengthUnit AS lengthUnit,
                       e.timestamp AS recordedAt, s.date AS sessionDate,
                       sp.name AS spotName
                FROM catch_entry e
                JOIN session s ON s.id = e.sessionId
                LEFT JOIN spot sp ON sp.id = s.spotId
                WHERE e.length IS NOT NULL AND e.lengthUnit IS NOT NULL
                ORDER BY e.timestamp ASC, e.id ASC
                """)
            var candidatesBySpecies: [Int64: [PersonalBestDetail]] = [:]
            for row in candidateRows {
                let unitRaw: String = row["lengthUnit"]
                guard let unit = LengthUnit(rawValue: unitRaw) else {
                    throw TallyError.notFound("lengthUnit \(unitRaw)")
                }
                let detail = PersonalBestDetail(
                    entryId: row["entryId"],
                    length: row["length"],
                    unit: unit,
                    recordedAt: row["recordedAt"],
                    sessionDate: row["sessionDate"],
                    spotName: row["spotName"])
                candidatesBySpecies[row["speciesId"], default: []].append(detail)
            }

            // Count and length-less count per species, in one pass.
            var totals: [Int64: (total: Int, noLength: Int)] = [:]
            for row in try Row.fetchAll(
                r,
                sql: """
                SELECT speciesId,
                       COUNT(*) AS total,
                       SUM(CASE WHEN length IS NULL OR lengthUnit IS NULL
                                THEN 1 ELSE 0 END) AS noLength
                FROM catch_entry GROUP BY speciesId
                """) {
                let noLength: Int? = row["noLength"]
                totals[row["speciesId"]] = (row["total"], noLength ?? 0)
            }

            return species.map { sp in
                let t = totals[sp.id!] ?? (0, 0)
                return PersonalBestRow(
                    speciesId: sp.id!,
                    speciesName: sp.name,
                    bests: Self.bestPerUnit(candidatesBySpecies[sp.id!] ?? []),
                    entriesWithoutLength: t.noLength,
                    totalEntries: t.total)
            }
        }
    }

    /// History for every spot: sessions (newest first), catch totals, and
    /// per-species bests caught at that spot. Recomputed live.
    public func spotHistories() throws -> [SpotHistoryRow] {
        try reader.read { r in
            let spots: [Spot] = try Spot.order(Column("name")).fetchAll(r)
            let speciesNames: [Int64: String] = Dictionary(
                uniqueKeysWithValues: try Species.fetchAll(r).compactMap { s in
                    s.id.map { ($0, s.name) }
                })

            var rows: [SpotHistoryRow] = []
            for spot in spots {
                let spotId = spot.id!
                let sessions = try Self.spotSessionSummaries(r, spotId: spotId)

                let totals = try Row.fetchOne(
                    r,
                    sql: """
                    SELECT COUNT(*) AS total,
                           SUM(CASE WHEN e.disposition = ? THEN 1 ELSE 0 END) AS kept
                    FROM catch_entry e
                    JOIN session s ON s.id = e.sessionId
                    WHERE s.spotId = ?
                    """,
                    arguments: [Disposition.kept.rawValue, spotId])
                let totalCaught: Int = totals?["total"] ?? 0
                let kept: Int? = totals?["kept"]
                let keptTotal = kept ?? 0

                let candidateRows = try Row.fetchAll(
                    r,
                    sql: """
                    SELECT e.id AS entryId, e.speciesId AS speciesId,
                           e.length AS length, e.lengthUnit AS lengthUnit,
                           e.timestamp AS recordedAt, s.date AS sessionDate,
                           sp.name AS spotName
                    FROM catch_entry e
                    JOIN session s ON s.id = e.sessionId
                    LEFT JOIN spot sp ON sp.id = s.spotId
                    WHERE s.spotId = ? AND e.length IS NOT NULL AND e.lengthUnit IS NOT NULL
                    ORDER BY e.timestamp ASC, e.id ASC
                    """,
                    arguments: [spotId])
                var bySpecies: [Int64: [PersonalBestDetail]] = [:]
                for row in candidateRows {
                    let unitRaw: String = row["lengthUnit"]
                    guard let unit = LengthUnit(rawValue: unitRaw) else {
                        throw TallyError.notFound("lengthUnit \(unitRaw)")
                    }
                    let detail = PersonalBestDetail(
                        entryId: row["entryId"],
                        length: row["length"],
                        unit: unit,
                        recordedAt: row["recordedAt"],
                        sessionDate: row["sessionDate"],
                        spotName: row["spotName"])
                    bySpecies[row["speciesId"], default: []].append(detail)
                }
                let bests = bySpecies.keys.sorted(by: {
                    (speciesNames[$0] ?? "") < (speciesNames[$1] ?? "")
                }).compactMap { sid -> SpeciesBests? in
                    guard let name = speciesNames[sid] else { return nil }
                    return SpeciesBests(
                        speciesId: sid, speciesName: name,
                        bests: Self.bestPerUnit(bySpecies[sid] ?? []))
                }

                rows.append(SpotHistoryRow(
                    spotId: spotId, spotName: spot.name, sessions: sessions,
                    totalCaught: totalCaught, kept: keptTotal,
                    bestsPerSpecies: bests))
            }
            return rows
        }
    }

    /// Kept counts per species vs the user's own typed keep-limit note.
    /// No regulation data is involved anywhere: the note is personal text.
    public func keptCountDashboard() throws -> [KeptCountRow] {
        try reader.read { r in
            let species: [Species] = try Species.order(Column("name")).fetchAll(r)
            var counts: [Int64: (total: Int, kept: Int)] = [:]
            for row in try Row.fetchAll(
                r,
                sql: """
                SELECT speciesId,
                       COUNT(*) AS total,
                       SUM(CASE WHEN disposition = ? THEN 1 ELSE 0 END) AS kept
                FROM catch_entry GROUP BY speciesId
                """,
                arguments: [Disposition.kept.rawValue]) {
                let kept: Int? = row["kept"]
                counts[row["speciesId"]] = (row["total"], kept ?? 0)
            }
            return species.map { sp in
                let c = counts[sp.id!] ?? (0, 0)
                let limit = KeepLimitNote.parsedLimit(from: sp.keepLimitNote)
                return KeptCountRow(
                    speciesId: sp.id!,
                    speciesName: sp.name,
                    kept: c.kept,
                    totalCaught: c.total,
                    userNote: sp.keepLimitNote,
                    parsedLimit: limit,
                    reachedOrExceeded: limit.map { c.kept >= $0 } ?? false)
            }
        }
    }

    /// Set (or clear) a species' user-typed keep-limit note. A
    /// trimmed-empty note is stored as nil ⇒ plain counts, no reminder.
    public func setKeepLimitNote(speciesId: Int64, note: String?) throws {
        try writer.write { w in
            guard var s = try Species.fetchOne(w, key: speciesId) else {
                throw TallyError.notFound("species \(speciesId)")
            }
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            s.keepLimitNote = (trimmed?.isEmpty == true) ? nil : trimmed
            try s.update(w)
        }
    }

    /// Delete a spot WITHOUT destroying catch history: sessions that
    /// referenced it survive with `spotId = nil` (date/notes/entries intact),
    /// then the spot row goes. Its history view disappears; the catches don't.
    public func deleteSpot(id: Int64) throws {
        try writer.write { w in
            guard try Spot.fetchOne(w, key: id) != nil else {
                throw TallyError.notFound("spot \(id)")
            }
            try w.execute(
                sql: "UPDATE session SET spotId = NULL WHERE spotId = ?",
                arguments: [id])
            try Spot.deleteOne(w, key: id)
        }
    }

    // MARK: - Selection helpers

    /// One best per unit from a candidate list ordered oldest-first:
    /// strictly-greater replaces, so exact ties keep the EARLIEST entry.
    fileprivate static func bestPerUnit(
        _ ordered: [PersonalBestDetail]
    ) -> [PersonalBestDetail] {
        var bests: [LengthUnit: PersonalBestDetail] = [:]
        for c in ordered {
            if let current = bests[c.unit], current.length >= c.length { continue }
            bests[c.unit] = c
        }
        return LengthUnit.allCases.compactMap { bests[$0] }
    }

    fileprivate static func spotSessionSummaries(
        _ r: Database, spotId: Int64
    ) throws -> [SpotHistoryRow.SessionSummary] {
        let rows = try Row.fetchAll(
            r,
            sql: """
            SELECT s.id AS sessionId, s.date AS date, s.status AS status,
                   COUNT(e.rowid) AS total,
                   SUM(CASE WHEN e.disposition = ? THEN 1 ELSE 0 END) AS kept
            FROM session s
            LEFT JOIN catch_entry e ON e.sessionId = s.id
            WHERE s.spotId = ?
            GROUP BY s.id ORDER BY s.date DESC, s.id DESC
            """,
            arguments: [Disposition.kept.rawValue, spotId])
        return try rows.map { row in
            let statusRaw: String = row["status"]
            guard let status = SessionStatus(rawValue: statusRaw) else {
                throw TallyError.notFound("session status \(statusRaw)")
            }
            let kept: Int? = row["kept"]
            return SpotHistoryRow.SessionSummary(
                sessionId: row["sessionId"],
                date: row["date"],
                status: status,
                totalCaught: row["total"],
                kept: kept ?? 0)
        }
    }
}
