/// CatchTallyKit — pure-domain core for Catch Tally.
///
/// M1 (issue #2) lands the entities, GRDB store, migrations, tally
/// arithmetic with undo, and derived views:
/// - `Entities.swift` — Species, Spot, Session, CatchEntry + value types
/// - `CatchTallyStore.swift` — migrations, CRUD, tally math, undo journal
///
/// No UI, no networking, no Apple-only frameworks: Linux-testable by design.
public enum CatchTallyKit {
    /// Namespace marker for the domain layer.
    public static let domain = "CatchTallyKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M1-domain-core"
}
