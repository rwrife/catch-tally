/// CatchTallyKit — pure-domain core for Catch Tally.
///
/// M1 (issue #2) landed the entities, GRDB store, migrations, tally
/// arithmetic with undo, and derived views.
/// M2 (issue #3) adds the reads the Quick Tally slice needs:
/// - `sessionGrandTotal` — live per-session totals across species
/// - `lastMutation` — describes the newest undoable mutation so the UI
///   labels its undo control without any view-side arithmetic
/// - `Entities.swift` — Species, Spot, Session, CatchEntry, LastMutation
/// - `CatchTallyStore.swift` — migrations, CRUD, tally math, undo journal
///
/// No UI, no networking, no Apple-only frameworks: Linux-testable by design.
public enum CatchTallyKit {
    /// Namespace marker for the domain layer.
    public static let domain = "CatchTallyKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M2-quick-tally"
}
