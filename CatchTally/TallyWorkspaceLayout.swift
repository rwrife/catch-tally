import SwiftUI
import CatchTallyKit

/// THE single layout routing seam (issue #4).
///
/// Every full-screen layout decision in Catch Tally funnels through this
/// view and the pure `TallyWorkspaceRouting.route(band:)` domain function.
/// No other view may read `horizontalSizeClass` — a Linux source-scan test
/// (`TallyWorkspaceRoutingTests.seamIsSoleRouter`) enforces that, and the
/// routing truth table itself is covered by unit tests.
///
/// iPhone Duo design target (documented, NOT tested hardware):
///   - folded  (compact band)  → Quick Tally stays one-handed and stacked.
///   - unfolded(spanned band)  → the workbench would span list | detail.
/// There is no released fold-state SDK API; when one ships, the integration
/// point is exactly one mapping here (band detection) plus flipping
/// `TallyWorkspaceRouting.spannedSupportEnabled`. Until then the app is
/// iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) and the spanned branch of the
/// seam is inert by design — never claim tested compatibility on
/// unreleased hardware.
struct TallyWorkspaceLayout<Compact: View, Spanned: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let spanned: () -> Spanned

    /// The ONE place a size class becomes a routing band.
    private var band: WorkspaceBand {
        horizontalSizeClass == .compact ? .compact : .spanned
    }

    var body: some View {
        switch TallyWorkspaceRouting.route(band: band) {
        case .stacked:
            compact()
        case .split:
            // Inert today: reachable only when spannedSupportEnabled flips
            // on with real hardware evidence behind it.
            spanned()
        }
    }
}
