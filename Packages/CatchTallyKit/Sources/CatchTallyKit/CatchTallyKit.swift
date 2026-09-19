/// CatchTallyKit — pure-domain core for Catch Tally.
///
/// Issue #1 ships only the skeleton namespace so CI has a real, testable
/// target. Issue #2 (domain core) lands the entities, GRDB store,
/// migrations, and tally arithmetic here.
public enum CatchTallyKit {
    /// Namespace marker for the domain layer.
    public static let domain = "CatchTallyKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M0-skeleton"
}
