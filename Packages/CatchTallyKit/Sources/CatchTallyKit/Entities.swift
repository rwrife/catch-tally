import Foundation
import GRDB

// MARK: - Value types

/// Unit a catch length was recorded in. Stored per entry; lengths in different
/// units are never mixed inside a single comparison (PB ranking groups by unit).
public enum LengthUnit: String, Codable, Sendable, CaseIterable {
    case centimeters
    case inches
}

/// Whether a caught fish was kept or released.
public enum Disposition: String, Codable, Sendable, CaseIterable {
    case kept
    case released
}

/// Lifecycle of a fishing session.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case closed
}

// MARK: - Entities

/// A user-defined species with an optional user-typed keep-limit note.
///
/// The note is *verbatim user text* — the app never interprets it as
/// regulation data and never ships regulation content (README non-goal).
public struct Species: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "species"

    public var id: Int64?
    public var name: String
    /// User-typed keep-limit note, quoted verbatim with a not-legal-advice
    /// framing at display time. nil ⇒ plain counts, no reminder state.
    public var keepLimitNote: String?

    public init(id: Int64? = nil, name: String, keepLimitNote: String? = nil) {
        self.id = id
        self.name = name
        self.keepLimitNote = keepLimitNote
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A user-defined fishing spot: name plus optional freeform description.
/// Deliberately NO coordinates — location stays freeform text by design.
public struct Spot: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "spot"

    public var id: Int64?
    public var name: String
    public var description: String?

    public init(id: Int64? = nil, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A fishing session: when it happened, optionally where, its notes, and
/// whether it is still active.
public struct Session: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "session"

    public var id: Int64?
    public var date: Date
    public var spotId: Int64?
    public var notes: String?
    public var status: SessionStatus

    public init(
        id: Int64? = nil,
        date: Date,
        spotId: Int64? = nil,
        notes: String? = nil,
        status: SessionStatus = .active
    ) {
        self.id = id
        self.date = date
        self.spotId = spotId
        self.notes = notes
        self.status = status
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A single tally unit: one fish of a species inside a session.
///
/// Length and keep-limit semantics: an absent length is *unknown*, not zero —
/// such entries are excluded from personal-best eligibility and stay visibly
/// distinct from a recorded zero (issue #2 acceptance criteria).
public struct CatchEntry: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "catch_entry"

    public var id: Int64?
    public var sessionId: Int64
    public var speciesId: Int64
    /// nil ⇒ no length recorded (unknown — excluded from PB eligibility).
    public var length: Double?
    public var lengthUnit: LengthUnit?
    public var disposition: Disposition
    /// App-private photo reference (filename of a copied image). nil ⇒ none.
    public var photoRef: String?
    public var notes: String?
    public var timestamp: Date

    public init(
        id: Int64? = nil,
        sessionId: Int64,
        speciesId: Int64,
        length: Double? = nil,
        lengthUnit: LengthUnit? = nil,
        disposition: Disposition = .kept,
        photoRef: String? = nil,
        notes: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.speciesId = speciesId
        self.length = length
        self.lengthUnit = lengthUnit
        self.disposition = disposition
        self.photoRef = photoRef
        self.notes = notes
        self.timestamp = timestamp
    }

    /// Whether this entry carries a usable length for personal-best ranking.
    public var hasLength: Bool { length != nil && lengthUnit != nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Derived views (never stored as independent truth)

/// Live tally for one (session, species) pair, derived from the entry table.
public struct SpeciesTally: Equatable, Sendable {
    public var total: Int
    public var kept: Int

    public init(total: Int, kept: Int) {
        self.total = total
        self.kept = kept
    }
}

/// A personal-best candidate: one entry that actually recorded a length.
public struct PersonalBestCandidate: Equatable, Sendable {
    public var entryId: Int64
    public var sessionId: Int64
    public var length: Double
    public var unit: LengthUnit
    public var timestamp: Date
}
