import SwiftUI
import CatchTallyKit

/// Session list + start-session entry point (issue #3; workbench hook in #4).
/// Active sessions resume Quick Tally; closed sessions open the Session
/// Workbench (issue #4) via `onOpenWorkbench`.
struct SessionListView: View {
    @Bindable var model: TallyModel
    @Binding var showStartSession: Bool
    var onOpenWorkbench: (_ sessionId: Int64) -> Void

    var body: some View {
        List {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "waterwaves",
                    description: Text("Start a session to begin tallying.")
                )
                .listRowSeparator(.hidden)
            } else {
                Section("Sessions") {
                    ForEach(model.sessions, id: \.id) { session in
                        SessionRow(model: model, session: session)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if session.status == .active {
                                    model.openSession(session)
                                } else if let id = session.id {
                                    onOpenWorkbench(id)
                                }
                            }
                            .accessibilityHint(
                                session.status == .active
                                    ? "Double tap to resume tallying"
                                    : "Double tap to open the session workbench"
                            )
                    }
                }
            }
        }
        .navigationTitle("Catch Tally")
        .safeAreaInset(edge: .bottom) {
            Button {
                showStartSession = true
            } label: {
                Label("Start Session", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .accessibilityIdentifier("start-session-button")
        }
    }
}

private struct SessionRow: View {
    let model: TallyModel
    let session: Session

    var body: some View {
        let total = (try? model.store.sessionGrandTotal(sessionId: session.id!))
            ?? SpeciesTally(total: 0, kept: 0)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                if let spot = model.spotName(for: session) {
                    Text(spot)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(total.total) fish")
                    .font(.headline.monospacedDigit())
                Text(session.status == .active ? "Active" : "Closed")
                    .font(.caption)
                    .foregroundStyle(session.status == .active ? Color.teal : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Start-session sheet: date defaults to now (fixed by contract), with an
/// optional inline spot name field.
struct StartSessionView: View {
    @Bindable var model: TallyModel
    @Environment(\.dismiss) private var dismiss
    @State private var spotName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Date") {
                        Text(Date.now, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    TextField("Spot (optional)", text: $spotName)
                        .accessibilityLabel("New spot name")
                } header: {
                    Text("New Session")
                } footer: {
                    Text("The spot is saved as a new named location — no coordinates, ever.")
                }
            }
            .navigationTitle("Start Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        model.startSession(spotName: spotName.isEmpty ? nil : spotName)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("begin-session-button")
                }
            }
        }
    }
}
