import SwiftUI
import CatchTallyKit

/// Root view for the Quick Tally vertical slice (issue #3).
///
/// Routes: session list ⇄ Quick Tally (when a session is active), plus a
/// species management sheet. iPhone-only compact layout — sized for the
/// smallest iPhone size class and Dynamic Type up to AX sizes.
///
/// NOTE (issue #4): full-screen routing will later move behind
/// `TallyWorkspaceLayout` when the session workbench lands; this slice keeps
/// a plain NavigationStack until that seam exists.
struct ContentView: View {
    @State private var model = TallyModel()
    @State private var showSpecies = false
    @State private var showStartSession = false

    var body: some View {
        NavigationStack {
            Group {
                if let session = model.activeSession {
                    QuickTallyView(model: model, session: session)
                } else {
                    SessionListView(model: model, showStartSession: $showStartSession)
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
    }
}

#Preview {
    ContentView()
}
