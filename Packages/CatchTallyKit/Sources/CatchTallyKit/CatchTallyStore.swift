import Foundation
import GRDB

/// Errors surfaced by tally mutations.
public enum TallyError: Error, Equatable, Sendable {
    /// A decrement was requested at or below zero; the store clamps at zero
    /// and reports the no-op instead of going negative.
    case clampedAtZero
    /// The referenced session/species (or an undo record) does not exist.
    case notFound(String)
    /// Undo was requested with an empty journal.
    case nothingToUndo
    /// A frozen session date was submitted for editing without the required
    /// explicit audit note (issue #4).
    case missingAuditNote
    /// Length and unit must be provided together (or both cleared) — a
    /// length with no unit, or a unit with no length, is meaningless.
    case incompleteLength
}

/// The durable local store: schema migrations, CRUD, tally arithmetic with a
/// per-mutation undo journal, and derived views.
///
/// Totals and kept-counts are always derived from `catch_entry` — never
/// stored as independent counters that could drift (PLAN.md determinism rule).
public final class CatchTallyStore: Sendable {
    private let reader: any DatabaseReader
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        self.reader = writer
        try migrate()
    }

    /// Escape hatch for tests and later features (issue #4 entry edits):
    /// run raw SQL/record work in a write transaction.
    public func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    /// In-memory store for tests and transient sessions.
    public convenience init() throws {
        try self.init(DatabaseQueue())
    }

    /// Open (and migrate) a file-backed store.
    public convenience init(url: URL) throws {
        try self.init(DatabaseQueue(path: url.path))
    }

    // MARK: - Migrations

    /// Apply pending schema migrations. Tested on both fresh-create and
    /// upgrade paths (issue #2 acceptance criteria).
    public func migrate() throws {
        var m = DatabaseMigrator()

        // v1 — initial schema.
        m.registerMigration("v1-initial") { db in
            try db.create(table: "species") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("keepLimitNote", .text)
            }
            try db.create(table: "spot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
            }
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .datetime).notNull()
                t.column("spotId", .integer).indexed().references("spot")
                t.column("notes", .text)
                t.column("status", .text).notNull()
            }
            try db.create(table: "catch_entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull()
                t.belongsTo("species", onDelete: .cascade).notNull()
                t.column("length", .double)
                t.column("lengthUnit", .text)
                t.column("disposition", .text).notNull()
                t.column("photoRef", .text)
                t.column("notes", .text)
                t.column("timestamp", .datetime).notNull()
            }
            // Undo journal: each applied tally mutation can be undone once,
            // newest first. Undo deletes the listed entry ids and is itself
            // consumed (one level of undo, per acceptance criteria).
            try db.create(table: "undo_mutation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("appliedAt", .datetime).notNull()
            }
            try db.create(table: "undo_entry") { t in
                t.column("mutationId", .integer)
                    .notNull()
                    .indexed()
                    .references("undo_mutation", onDelete: .cascade)
                t.column("entryId", .integer).notNull()
            }
            // Tombstones: full JSON snapshot of a hard-deleted entry so a
            // decrement can be undone (restored verbatim, original id).
            try db.create(table: "undo_tombstone") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer).notNull().indexed()
                t.column("removedSnapshot", .blob).notNull()
            }
        }

        // v2 — forward-compatibility fixture for the upgrade-path test:
        // species names get a uniqueness index once user feedback lands.
        // Fresh databases and v1 databases both arrive here, so the index
        // creation doubles as proof the migrator replays ordered steps.
        m.registerMigration("v2-species-name-index") { db in
            try db.create(index: "species_name", on: "species", columns: ["name"])
        }

        // v3 — session workbench (issue #4):
        // - session: frozen date + audit trail for explicit frozen-date edits
        // - catch_entry: photo alt-text for VoiceOver description
        m.registerMigration("v3-session-workbench") { db in
            try db.alter(table: "session") { t in
                t.add(column: "frozenDate", .datetime)
                t.add(column: "dateAuditNote", .text)
            }
            try db.alter(table: "catch_entry") { t in
                t.add(column: "photoAltText", .text)
            }
        }

        // Ordered registry of applied migrations — used for version reporting.
        try m.migrate(writer)
    }

    /// Registered migration identifiers, oldest first.
    public static let migrationIdentifiers = [
        "v1-initial",
        "v2-species-name-index",
        "v3-session-workbench",
    ]

    /// Latest applied schema version (nil on an unmigrated database).
    public func currentSchemaVersion() throws -> String? {
        try dbAppliedMigrations().last
    }

    /// Applied migrations in registration order.
    private func dbAppliedMigrations() throws -> [String] {
        try reader.read { r in
            guard try r.tableExists("grdb_migrations") else { return [] }
            let applied = try String.fetchSet(r, sql: "SELECT identifier FROM grdb_migrations")
            return Self.migrationIdentifiers.filter { applied.contains($0) }
        }
    }

    // MARK: - CRUD

    public func saveSpecies(_ species: inout Species) throws {
        try writer.write { w in try species.save(w) }
    }

    public func renameSpecies(id: Int64, to name: String) throws {
        try writer.write { w in
            guard var s = try Species.fetchOne(w, key: id) else { throw TallyError.notFound("species \(id)") }
            s.name = name
            try s.update(w)
        }
    }

    public func deleteSpecies(id: Int64) throws {
        try writer.write { w in
            guard try Species.fetchOne(w, key: id) != nil else { throw TallyError.notFound("species \(id)") }
            try Species.deleteOne(w, key: id)  // cascades to entries
        }
    }

    public func fetchSpecies() throws -> [Species] {
        try reader.read { r in try Species.order(Column("name")).fetchAll(r) }
    }

    public func saveSpot(_ spot: inout Spot) throws {
        try writer.write { w in try spot.save(w) }
    }

    public func fetchSpots() throws -> [Spot] {
        try reader.read { r in try Spot.order(Column("name")).fetchAll(r) }
    }

    public func saveSession(_ session: inout Session) throws {
        try writer.write { w in try session.save(w) }
    }

    /// Close a session and FREEZE its date (issue #4): `frozenDate` records
    /// the close time and the session date can afterwards only change via
    /// `editSessionDate`, which demands an explicit user audit note.
    /// Closing an already-closed session is a no-op on the freeze — the
    /// original frozen date is preserved, never overwritten.
    public func closeSession(id: Int64, closedAt: Date = Date()) throws {
        try writer.write { w in
            guard var s = try Session.fetchOne(w, key: id) else { throw TallyError.notFound("session \(id)") }
            s.status = .closed
            if s.frozenDate == nil { s.frozenDate = closedAt }
            try s.update(w)
        }
    }

    /// Explicitly change a frozen session's date, requiring the user's own
    /// audit note explaining why (issue #4 acceptance criteria). The note is
    /// appended to the session's audit trail with the prior date, verbatim.
    /// - Parameter note: trimmed-empty notes are rejected with
    ///   `TallyError.missingAuditNote` — an unfrozen (active) session may be
    ///   re-dated freely, so this method refuses to launder a silent edit
    ///   onto a frozen one.
    public func editSessionDate(id: Int64, to newDate: Date, auditNote note: String) throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TallyError.missingAuditNote }
        try writer.write { w in
            guard var s = try Session.fetchOne(w, key: id) else { throw TallyError.notFound("session \(id)") }
            guard s.frozenDate != nil else {
                // Active sessions aren't frozen; date edits go through
                // saveSession. Routing them here would skip the audit
                // requirement the caller *thinks* it is satisfying.
                throw TallyError.notFound("session \(id) is not frozen — no audit edit needed")
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) — '\(trimmed)' (was \(ISO8601DateFormatter().string(from: s.date)))"
            s.dateAuditNote = s.dateAuditNote.map { $0 + "\n" + line } ?? line
            s.date = newDate
            try s.update(w)
        }
    }

    /// Change an ACTIVE session's date (no audit needed — freezing hasn't
    /// happened yet). Frozen sessions must go through `editSessionDate`.
    public func setSessionDate(id: Int64, to newDate: Date) throws {
        try writer.write { w in
            guard var s = try Session.fetchOne(w, key: id) else { throw TallyError.notFound("session \(id)") }
            guard s.frozenDate == nil else { throw TallyError.missingAuditNote }
            s.date = newDate
            try s.update(w)
        }
    }

    public func fetchSessions() throws -> [Session] {
        try reader.read { r in try Session.order(Column("date").desc).fetchAll(r) }
    }

    public func fetchSession(id: Int64) throws -> Session? {
        try reader.read { r in try Session.fetchOne(r, key: id) }
    }

    public func fetchEntries(sessionId: Int64) throws -> [CatchEntry] {
        try reader.read { r in
            try CatchEntry
                .filter(Column("sessionId") == sessionId)
                .order(Column("timestamp"), Column("id"))
                .fetchAll(r)
        }
    }

    /// Entries for a session filtered by a quick filter (issue #4). The
    /// filter runs in the domain layer via `EntryFilter` so UI and tests
    /// share one definition of "released / kept / no length recorded".
    public func fetchEntries(sessionId: Int64, filter: EntryFilter) throws -> [CatchEntry] {
        filter.apply(to: try fetchEntries(sessionId: sessionId))
    }

    public func fetchEntry(id: Int64) throws -> CatchEntry? {
        try reader.read { r in try CatchEntry.fetchOne(r, key: id) }
    }

    // MARK: - Entry editing (session workbench, issue #4)

    /// Update one entry's length/unit/disposition/notes from the detail
    /// editor. Length and unit must be set together or both cleared
    /// (`TallyError.incompleteLength`). The stored row's photoRef and
    /// photoAltText are preserved — photos change only through the
    /// dedicated attach/detach methods so files can never orphan.
    /// Editing an entry in a CLOSED session is allowed (dock-side editing
    /// is the whole point of the workbench).
    public func updateEntryDetail(
        id: Int64,
        length: Double?,
        lengthUnit: LengthUnit?,
        disposition: Disposition,
        notes: String?
    ) throws -> CatchEntry {
        guard (length == nil) == (lengthUnit == nil) else {
            throw TallyError.incompleteLength
        }
        return try writer.write { w in
            guard var entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            entry.length = length
            entry.lengthUnit = lengthUnit
            entry.disposition = disposition
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.notes = (trimmed?.isEmpty == true) ? nil : trimmed
            try entry.update(w)
            return entry
        }
    }

    /// Flip keep ↔ release (quick transition from the entry list).
    @discardableResult
    public func toggleDisposition(id: Int64) throws -> Disposition {
        try writer.write { w in
            guard var entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            entry.disposition = entry.disposition == .kept ? .released : .kept
            try entry.update(w)
            return entry.disposition
        }
    }

    /// Attach (or re-attach) an alt-text description for the entry's photo.
    /// Refusing alt-text edits on a photo-less entry keeps the pair atomic.
    public func setEntryPhotoAltText(id: Int64, altText: String?) throws {
        try writer.write { w in
            guard var entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            guard entry.photoRef != nil else { throw PhotoStoreError.photoMissing("(none)") }
            let trimmed = altText?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.photoAltText = (trimmed?.isEmpty == true) ? nil : trimmed
            try entry.update(w)
        }
    }

    /// Attach a photo copy to an entry through the injected photo store
    /// (issue #4): bytes are written FIRST, then the reference is stored —
    /// if the DB write throws, the just-written file is deleted, so a
    /// failure never leaves an orphan file behind.
    /// - Throws: `PhotoStoreError.photoAlreadyAttached` when the entry
    ///   already has a photo (call `detachEntryPhoto` first — one photo per
    ///   entry keeps lifecycle bookkeeping trivial).
    @discardableResult
    public func attachEntryPhoto(
        id: Int64,
        data: Data,
        ref: String,
        altText: String?,
        to photoStore: any EntryPhotoStore
    ) throws -> CatchEntry {
        try writer.write { w in
            guard var entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            guard entry.photoRef == nil else { throw PhotoStoreError.photoAlreadyAttached }
            try photoStore.writePhoto(data: data, ref: ref)
            do {
                let trimmed = altText?.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.photoRef = ref
                entry.photoAltText = (trimmed?.isEmpty == true) ? nil : trimmed
                try entry.update(w)
            } catch {
                // Roll back the file so DB and store stay consistent.
                try? photoStore.deletePhoto(ref: ref)
                throw error
            }
            return entry
        }
    }

    /// Detach and delete an entry's photo copy (user-initiated removal).
    /// Idempotent: detaching an entry without a photo mutates nothing.
    public func detachEntryPhoto(id: Int64, from photoStore: any EntryPhotoStore) throws {
        try writer.write { w in
            guard var entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            guard let ref = entry.photoRef else { return }
            try photoStore.deletePhoto(ref: ref)
            entry.photoRef = nil
            entry.photoAltText = nil
            try entry.update(w)
        }
    }

    /// Hard-delete a single entry from the workbench list, removing its
    /// photo copy through the injected store. Unlike `decrement` this is a
    /// workbench edit, not tally arithmetic — it is NOT journaled for undo.
    public func deleteEntry(id: Int64, from photoStore: (any EntryPhotoStore)? = nil) throws {
        try writer.write { w in
            guard let entry = try CatchEntry.fetchOne(w, key: id) else {
                throw TallyError.notFound("entry \(id)")
            }
            if let ref = entry.photoRef, let photoStore {
                try photoStore.deletePhoto(ref: ref)
            }
            try entry.delete(w)
        }
    }

    /// Count how many entries currently reference a photo ref — used by
    /// tests and future GC passes to prove no orphan/dangling references.
    public func entryCount(usingPhotoRef ref: String) throws -> Int {
        try reader.read { r in
            try Int.fetchOne(
                r, sql: "SELECT COUNT(*) FROM catch_entry WHERE photoRef = ?",
                arguments: [ref]) ?? 0
        }
    }

    // MARK: - Tally arithmetic (every mutation journaled for undo)

    /// +1: append one entry for (session, species) with the given disposition.
    @discardableResult
    public func addCatch(
        sessionId: Int64,
        speciesId: Int64,
        disposition: Disposition = .kept,
        timestamp: Date = Date()
    ) throws -> Int64 {
        try writer.write { w in
            let entry = CatchEntry(
                sessionId: sessionId, speciesId: speciesId,
                disposition: disposition, timestamp: timestamp)
            var stored = entry
            try stored.insert(w)
            try Self.journal(w, appliedAt: timestamp, entryIds: [stored.id!])
            return stored.id!
        }
    }

    /// Batch add: append `count` entries in one mutation (one undo step).
    @discardableResult
    public func addBatch(
        sessionId: Int64,
        speciesId: Int64,
        count: Int,
        disposition: Disposition = .kept,
        timestamp: Date = Date()
    ) throws -> [Int64] {
        precondition(count >= 0, "batch count must be non-negative")
        return try writer.write { w in
            var ids: [Int64] = []
            for _ in 0..<count {
                var stored = CatchEntry(
                    sessionId: sessionId, speciesId: speciesId,
                    disposition: disposition, timestamp: timestamp)
                try stored.insert(w)
                ids.append(stored.id!)
            }
            if !ids.isEmpty { try Self.journal(w, appliedAt: timestamp, entryIds: ids) }
            return ids
        }
    }

    /// −1: remove the most recent entry for (session, species).
    /// Clamped at zero — calling decrement on an empty tally raises
    /// `TallyError.clampedAtZero` and mutates nothing.
    public func decrement(sessionId: Int64, speciesId: Int64, timestamp: Date = Date()) throws {
        try writer.write { w in
            guard let last = try CatchEntry
                .filter(Column("sessionId") == sessionId && Column("speciesId") == speciesId)
                .order(Column("timestamp").desc, Column("id").desc)
                .fetchOne(w)
            else { throw TallyError.clampedAtZero }
            let snapshot = try JSONEncoder().encode(last)
            try last.delete(w)
            try Self.journal(w, appliedAt: timestamp, entryIds: [-last.id!], snapshots: [last.id!: snapshot])
        }
    }

    /// Undo the most recent journaled mutation. Add-mutations restore the
    /// removed entries; decrement-mutations re-remove the re-added ones.
    /// Each mutation is undoable exactly once (journal row is consumed).
    public func undoLast() throws {
        try writer.write { w in
            guard let mutationId: Int64 = try Int64
                .fetchOne(w, sql: "SELECT id FROM undo_mutation ORDER BY id DESC LIMIT 1")
            else { throw TallyError.nothingToUndo }

            let deltas: [Int64] = try Int64
                .fetchAll(w, sql: "SELECT entryId FROM undo_entry WHERE mutationId = ? ORDER BY entryId", arguments: [mutationId])

            for delta in deltas {
                if delta >= 0 {
                    // mutation added this entry ⇒ undo removes it
                    try w.execute(
                        sql: "DELETE FROM catch_entry WHERE id = ?",
                        arguments: [delta])
                } else {
                    // mutation removed this entry ⇒ undo restores it
                    let removedId = -delta
                    let exists = try Int64.fetchOne(
                        w, sql: "SELECT COUNT(*) FROM catch_entry WHERE id = ?",
                        arguments: [removedId]) ?? 0
                    if exists == 0,
                       let data: Data = try Data.fetchOne(
                           w,
                           sql: """
                           SELECT removedSnapshot FROM undo_tombstone
                           WHERE entryId = ? ORDER BY id DESC LIMIT 1
                           """,
                           arguments: [removedId])
                    {
                        // Restore verbatim from the decrement-time snapshot,
                        // preserving the original row id.
                        let entry = try JSONDecoder().decode(CatchEntry.self, from: data)
                        try w.execute(
                            sql: """
                            INSERT INTO catch_entry
                                (id, sessionId, speciesId, length, lengthUnit,
                                 disposition, photoRef, photoAltText, notes, timestamp)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                removedId,
                                entry.sessionId,
                                entry.speciesId,
                                entry.length,
                                entry.lengthUnit?.rawValue,
                                entry.disposition.rawValue,
                                entry.photoRef,
                                entry.photoAltText,
                                entry.notes,
                                entry.timestamp,
                            ])
                    }
                }
            }
            // Clear tombstones consumed by this mutation's negative deltas.
            for delta in deltas where delta < 0 {
                try w.execute(
                    sql: "DELETE FROM undo_tombstone WHERE entryId = ?",
                    arguments: [-delta])
            }
            // Consume the journal row: no re-undo of the same mutation.
            try w.execute(sql: "DELETE FROM undo_mutation WHERE id = ?", arguments: [mutationId])
        }
    }

    /// Whether any mutation is currently undoable.
    public func canUndo() throws -> Bool {
        try reader.read { r in
            let c = try Int64.fetchOne(r, sql: "SELECT COUNT(*) FROM undo_mutation") ?? 0
            return c > 0
        }
    }

    // MARK: - Derived views

    /// Total and kept counts for one (session, species), derived live.
    public func tally(sessionId: Int64, speciesId: Int64) throws -> SpeciesTally {
        try reader.read { r in
            let total = try Int.fetchOne(
                r,
                sql: "SELECT COUNT(*) FROM catch_entry WHERE sessionId = ? AND speciesId = ?",
                arguments: [sessionId, speciesId]) ?? 0
            let kept = try Int.fetchOne(
                r,
                sql: """
                SELECT COUNT(*) FROM catch_entry
                WHERE sessionId = ? AND speciesId = ? AND disposition = ?
                """,
                arguments: [sessionId, speciesId, Disposition.kept.rawValue]) ?? 0
            return SpeciesTally(total: total, kept: kept)
        }
    }

    /// Session totals per species (all species with any entry in session).
    public func sessionTotals(sessionId: Int64) throws -> [Int64: SpeciesTally] {
        try reader.read { r in
            let rows = try Row.fetchAll(
                r,
                sql: """
                SELECT speciesId,
                       COUNT(*) AS total,
                       SUM(CASE WHEN disposition = ? THEN 1 ELSE 0 END) AS kept
                FROM catch_entry WHERE sessionId = ? GROUP BY speciesId
                """,
                arguments: [Disposition.kept.rawValue, sessionId])
            var result: [Int64: SpeciesTally] = [:]
            for row in rows {
                let sid: Int64 = row["speciesId"]
                result[sid] = SpeciesTally(
                    total: row["total"],
                    kept: row["kept"] ?? 0)
            }
            return result
        }
    }

    /// Grand totals across all species for one session (total entries, kept).
    public func sessionGrandTotal(sessionId: Int64) throws -> SpeciesTally {
        try reader.read { r in
            let total = try Int.fetchOne(
                r,
                sql: "SELECT COUNT(*) FROM catch_entry WHERE sessionId = ?",
                arguments: [sessionId]) ?? 0
            let kept = try Int.fetchOne(
                r,
                sql: """
                SELECT COUNT(*) FROM catch_entry
                WHERE sessionId = ? AND disposition = ?
                """,
                arguments: [sessionId, Disposition.kept.rawValue]) ?? 0
            return SpeciesTally(total: total, kept: kept)
        }
    }

    /// Description of the most recent journaled mutation, so the UI can
    /// render a visible, correctly-labeled undo affordance without doing
    /// arithmetic view-side. nil ⇒ nothing to undo.
    public func lastMutation() throws -> LastMutation? {
        try reader.read { r in
            guard let row = try Row.fetchOne(
                r,
                sql: """
                SELECT m.id AS id,
                       (SELECT COUNT(*) FROM undo_entry e
                         WHERE e.mutationId = m.id AND e.entryId >= 0) AS added,
                       (SELECT COUNT(*) FROM undo_entry e
                         WHERE e.mutationId = m.id AND e.entryId < 0) AS removed
                FROM undo_mutation m ORDER BY m.id DESC LIMIT 1
                """)
            else { return nil }

            let mutationId: Int64 = row["id"]
            let added: Int = row["added"]
            let removed: Int = row["removed"]
            let kind: LastMutation.Kind = added > 0 ? .added : .removed
            let count = added > 0 ? added : removed

            // The species a mutation applied to: every entry it touched
            // belongs to one species (add/decrement are per species).
            var speciesId: Int64?
            if added > 0 {
                speciesId = try Int64.fetchOne(
                    r,
                    sql: """
                    SELECT speciesId FROM catch_entry
                    WHERE id IN (SELECT entryId FROM undo_entry
                                 WHERE mutationId = ? AND entryId >= 0)
                    LIMIT 1
                    """,
                    arguments: [mutationId])
            } else if let data: Data = try Data.fetchOne(
                r,
                sql: """
                SELECT removedSnapshot FROM undo_tombstone
                WHERE entryId IN (SELECT -entryId FROM undo_entry
                                  WHERE mutationId = ? AND entryId < 0)
                ORDER BY id DESC LIMIT 1
                """,
                arguments: [mutationId])
            {
                // Decrement mutations removed rows, so read the species back
                // out of the tombstone snapshot (JSON-decoded, not SQL-JSON,
                // to stay portable across SQLite builds).
                speciesId = try JSONDecoder().decode(CatchEntry.self, from: data).speciesId
            }
            guard let speciesId else { return nil }
            return LastMutation(kind: kind, speciesId: speciesId, count: count)
        }
    }

    /// Personal-best candidates for a species: only entries that actually
    /// recorded a length. Length-less entries are absent — unknown stays
    /// unknown, never zero. Ranking groups by unit (issue #5 consumes this).
    public func personalBestCandidates(speciesId: Int64) throws -> [PersonalBestCandidate] {
        try reader.read { r in
            let rows = try Row.fetchAll(
                r,
                sql: """
                SELECT id, sessionId, length, lengthUnit, timestamp
                FROM catch_entry
                WHERE speciesId = ? AND length IS NOT NULL AND lengthUnit IS NOT NULL
                ORDER BY timestamp
                """,
                arguments: [speciesId])
            return try rows.map { row in
                let unitRaw: String = row["lengthUnit"]
                guard let unit = LengthUnit(rawValue: unitRaw) else {
                    throw TallyError.notFound("lengthUnit \(unitRaw)")
                }
                return PersonalBestCandidate(
                    entryId: row["id"],
                    sessionId: row["sessionId"],
                    length: row["length"],
                    unit: unit,
                    timestamp: row["timestamp"])
            }
        }
    }
}

// MARK: - Undo journal plumbing

extension CatchTallyStore {
    /// Record a mutation in the undo journal inside the same write transaction.
    /// Positive entryIds = entries the mutation added; negative = entries it
    /// removed (a tombstone snapshot is stored so decrement-undo can restore).
    fileprivate static func journal(
        _ w: Database,
        appliedAt: Date,
        entryIds: [Int64],
        snapshots: [Int64: Data] = [:]
    ) throws {
        try w.execute(
            sql: "INSERT INTO undo_mutation (appliedAt) VALUES (?)",
            arguments: [appliedAt])
        let mutationId = w.lastInsertedRowID
        for eid in entryIds {
            if eid >= 0 {
                try w.execute(
                    sql: "INSERT INTO undo_entry (mutationId, entryId) VALUES (?, ?)",
                    arguments: [mutationId, eid])
            } else {
                let removedId = -eid
                if let snapshot = snapshots[removedId] {
                    try w.execute(
                        sql: "INSERT INTO undo_tombstone (entryId, removedSnapshot) VALUES (?, ?)",
                        arguments: [removedId, snapshot])
                }
                try w.execute(
                    sql: "INSERT INTO undo_entry (mutationId, entryId) VALUES (?, ?)",
                    arguments: [mutationId, eid])
            }
        }
    }
}
