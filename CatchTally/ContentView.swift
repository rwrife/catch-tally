import SwiftUI
import CatchTallyKit

/// Root view for Catch Tally.
///
/// The full-screen layout decision routes through `TallyWorkspaceLayout`
/// (issue #4) — the single seam. Compact = stacked NavigationStack;
/// the spanned branch is the documented iPhone Duo hook point and is
/// inert in every shipping build (`TallyWorkspaceRouting
/// spannedSupportEnabled == false`).
///
/// Routes: session list ⇄ Quick Tally (when a session is active), a
/// species management sheet, and the session workbench (presented for
/// closed sessions, or on demand from Quick Tally).
struct ContentView: View {
    @State private var model = TallyModel()
    @State private var showSpecies = false
    @State private var showStartSession = false
    @State private var workbenchRoute: SessionRoute?

    /// Identifiable wrapper for workbench presentation state.
    private struct SessionRoute: Identifiable { let id: Int64 }

    var body: some View {
        TallyWorkspaceLayout {
            NavigationStack {
                Group {
                    if let session = model.activeSession {
                        QuickTallyView(
                            model: model,
                            session: session,
                            onOpenWorkbench: {
                                if let id = session.id { workbenchRoute = SessionRoute(id: id) }
                            })
                    } else {
                        SessionListView(
                            model: model,
                            showStartSession: $showStartSession,
                            onOpenWorkbench: { workbenchRoute = SessionRoute(id: $0) })
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSpecies = true
                        } label: {
                            Label("Species", systemImage: "fish")
                        }
                        .accessibilityIdentifier("species-manager-button")
                    }
                }
                .sheet(isPresented: $showSpecies) {
                    SpeciesManagerView(model: model)
                }
                .sheet(isPresented: $showStartSession) {
                    StartSessionView(model: model)
                }
                .alert(
                    "Something went wrong",
                    isPresented: Binding(
                        get: { model.lastErrorMessage != nil },
                        set: { if !$0 { model.lastErrorMessage = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.lastErrorMessage ?? "")
                }
            }
            .tint(.teal)
        } spanned: {
            // Inert documented hook point for the future iPhone Duo
            // unfolded workbench (see TallyWorkspaceLayout header). This
            // branch is unreachable in shipping builds because the routing
            // seam's spanned gate is off; it exists so the seam is the
            // ONLY code a real Duo integration must touch.
            NavigationSplitView {
                SessionListView(
                    model: model,
                    showStartSession: $showStartSession,
                    onOpenWorkbench: { workbenchRoute = SessionRoute(id: $0) })
            } detail: {
                ContentUnavailableView(
                    "Spanned workbench",
                    systemImage: "square.split.2x1",
                    description: Text("Unfolded layout is a documented future target.")
                )
            }
        }
        .fullScreenCover(item: $workbenchRoute) { route in
            SessionWorkbenchContainer(store: model.store, sessionId: route.id)
        }
    }
}

/// Hosts a `SessionWorkbenchModel` whose lifetime matches one workbench
/// presentation, so each open snapshots fresh state from the store.
private struct SessionWorkbenchContainer: View {
    let store: CatchTallyStore
    let sessionId: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var workbench: SessionWorkbenchModel?

    var body: some View {
        NavigationStack {
            Group {
                if let workbench {
                    SessionWorkbenchView(model: workbench)
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("workbench-done")
                }
            }
        }
        .tint(.teal)
        .task {
            if workbench == nil {
                workbench = SessionWorkbenchModel(
                    store: store,
                    photos: SessionWorkbenchModel.openDefaultPhotoStore(),
                    sessionId: sessionId)
            }
        }
    }
}

#Preview {
    ContentView()
}
