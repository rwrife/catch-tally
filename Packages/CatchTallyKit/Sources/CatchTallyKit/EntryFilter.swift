import Foundation

/// Quick filters for the session workbench entry list (issue #4):
/// released / kept / entries with no length recorded. Pure value logic so
/// the filtering shown in the UI is Linux-testable domain behavior.
public enum EntryFilter: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case all
    case kept
    case released
    case noLengthRecorded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .kept: "Kept"
        case .released: "Released"
        case .noLengthRecorded: "No length"
        }
    }

    /// Whether an entry passes this filter. `noLengthRecorded` matches
    /// entries missing either half of the length pair — unknown stays
    /// unknown (issue #2 semantics).
    public func matches(_ entry: CatchEntry) -> Bool {
        switch self {
        case .all: true
        case .kept: entry.disposition == .kept
        case .released: entry.disposition == .released
        case .noLengthRecorded: !entry.hasLength
        }
    }

    /// Applies the filter to a list, preserving input order.
    public func apply(to entries: [CatchEntry]) -> [CatchEntry] {
        entries.filter { matches($0) }
    }
}
