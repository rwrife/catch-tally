import Foundation

// MARK: - Workspace routing (issue #4 — the single dual-screen seam)
//
// iPhone Duo (folded → Quick Tally, unfolded → spanned workbench) is a
// DOCUMENTED DESIGN TARGET, not a supported configuration. There is no
// released SDK API for fold state, and this codebase must never reference
// unreleased hardware APIs. All size-class routing therefore funnels
// through exactly one pure decision point: `TallyWorkspaceRouting.route`.
//
// The SwiftUI `TallyWorkspaceLayout` view in the app target observes the
// environment size class, converts it to a `WorkspaceBand`, and calls
// `route(band:)` — it contains NO routing logic of its own. A Linux test
// (`TallyWorkspaceRoutingTests`) proves the truth table, and a source-scan
// test proves the size class is consulted nowhere else in app sources.

/// Coarse size-class band fed into the routing seam. The app maps
/// `horizontalSizeClass == .compact` to `.compact` and anything regular to
/// `.spanned`; nothing else may classify a workspace.
public enum WorkspaceBand: String, Codable, Sendable, CaseIterable {
    case compact
    case spanned
}

/// The layout the seam selects for the current band.
public enum WorkspaceLayout: Equatable, Sendable {
    /// Stacked list → detail navigation (NavigationStack push).
    case stacked
    /// Side-by-side list | detail — the spanned hook point for the future
    /// iPhone Duo target. Reachable ONLY when `spannedSupportEnabled`
    /// is explicitly flipped on; no shipping build does that today.
    case split
}

/// The single routing decision point for Catch Tally layouts.
public enum TallyWorkspaceRouting {
    /// Master gate for the spanned/split workbench. `false` is the shipped
    /// state: even a regular-size environment (e.g. Stage Manager on iPad,
    /// should it ever appear — the app is iPhone-only anyway) keeps the
    /// stacked layout. Flipping this to `true` is the documented hook for
    /// the iPhone Duo unfolded workbench and must come with real hardware
    /// evidence before it ever lands (never claimed as tested otherwise).
    public static let spannedSupportEnabled: Bool = false

    /// Pure routing truth table:
    /// - `.compact`                      → `.stacked` (always)
    /// - `.spanned`, gate off (shipped)  → `.stacked` (hook point, inert)
    /// - `.spanned`, gate on (future)    → `.split`
    public static func route(
        band: WorkspaceBand,
        spannedSupportEnabled: Bool = spannedSupportEnabled
    ) -> WorkspaceLayout {
        switch band {
        case .compact:
            return .stacked
        case .spanned:
            return spannedSupportEnabled ? .split : .stacked
        }
    }
}
