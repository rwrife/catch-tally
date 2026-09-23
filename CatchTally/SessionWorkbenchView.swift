import SwiftUI
import CatchTallyKit

/// Session workbench (issue #4): the dock-side detail surface.
/// Entry list with quick filters, per-entry editor navigation, the
/// session close (freeze) action, and the audited frozen-date editor.
///
/// Layout is routed exclusively through `TallyWorkspaceLayout` upstream —
/// this view is layout-agnostic (it fits the compact stacked column and
/// would equally fill a future spanned detail pane).
struct SessionWorkbenchView: View {
    @Bindable var model: SessionWorkbenchModel
    @State private var showCloseConfirm = false
    @State private var showDateEditor = false

    var body: some View {
        List {
            sessionHeader
            filterBar
            entryList
        }
        .navigationTitle("Workbench")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.session?.status == .active {
                    Button("Close") { showCloseConfirm = true }
                        .accessibilityIdentifier("workbench-close-session")
                }
            }
        }
        .confirmationDialog(
            "Close this session?",
            isPresented: $showCloseConfirm,
            titleVisibility: .visible
        ) {
            Button("Close session", role: .destructive) { model.closeSession() }
            Button("Keep open", role: .cancel) {}
        } message: {
            Text("Closing freezes the session date. You can still edit entries; changing the date later requires a note explaining why.")
        }
        .sheet(isPresented: $showDateEditor) {
            if let session = model.session {
                FrozenDateEditorView(model: model, session: session)
            }
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

    // MARK: - Session header (frozen date + audit trail)

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.date, format: .dateTime.month().day().year().hour().minute())
                            .font(.headline)
                        if let spot = model.spotName {
                            Text(spot)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(session.status == .active
                             ? "Active — close to freeze the date"
                             : "Closed")
                            .font(.caption)
                            .foregroundStyle(session.status == .active ? Color.teal : .secondary)
                    }
                    Spacer()
                    Button {
                        showDateEditor = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Edit session date")
                    .accessibilityIdentifier("edit-session-date")
                }
                if let audit = session.dateAuditNote {
                    DisclosureGroup("Date edit history") {
                        Text(audit)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Date edit audit notes: \(audit)")
                    }
                    .font(.subheadline)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Quick filters (released / kept / no length recorded)

    private var filterBar: some View {
        Picker("Filter entries", selection: $model.filter) {
            ForEach(EntryFilter.allCases) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: model.filter) { _, _ in model.refresh() }
        .accessibilityIdentifier("entry-filter")
    }

    // MARK: - Entry list

    @ViewBuilder
    private var entryList: some View {
        if model.visibleEntries.isEmpty {
            Text(model.filter == .all
                 ? "No entries yet — tally some fish first."
                 : "No entries match “\(model.filter.displayName)”.")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else {
            ForEach(model.visibleEntries, id: \.id) { entry in
                NavigationLink {
                    EntryDetailView(
                        model: model,
                        entry: entry,
                        photoStore: model.photos)
                } label: {
                    EntryRow(model: model, entry: entry)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        if let id = entry.id { model.delete(entryId: id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}

/// One row: species, count context, quick keep/release toggle, and an
/// honest "no length recorded" marker (never a silent zero).
private struct EntryRow: View {
    let model: SessionWorkbenchModel
    let entry: CatchEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.speciesName(for: entry))
                    .font(.headline)
                HStack(spacing: 6) {
                    if entry.hasLength, let length = entry.length {
                        Text(LengthFormat.string(length, unit: entry.lengthUnit ?? .inches))
                            .font(.subheadline.monospacedDigit())
                    } else {
                        Text("no length recorded")
                            .font(.subheadline.italic())
                            .foregroundStyle(.secondary)
                    }
                    if entry.photoRef != nil {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.teal)
                            .accessibilityLabel(
                                entry.photoAltText ?? "Photo attached, no description")
                    }
                }
                Text(entry.timestamp, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let id = entry.id { model.toggleDisposition(entryId: id) }
            } label: {
                Text(entry.disposition == .kept ? "Kept" : "Released")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(entry.disposition == .kept ? .orange : .teal)
            .accessibilityLabel(
                "\(model.speciesName(for: entry)) was \(entry.disposition == .kept ? "kept" : "released"), double tap to flip")
            .accessibilityIdentifier("disposition-toggle-\(entry.id ?? -1)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Explicit frozen-date editor (issue #4): the date changes only with a
/// user-typed audit note, quoted verbatim into the session's trail.
private struct FrozenDateEditorView: View {
    @Bindable var model: SessionWorkbenchModel
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var newDate: Date = .now
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("New date", selection: $newDate)
                    TextField("Why is the date changing? (required)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("Audit note for date change")
                } header: {
                    Text(session.frozenDate != nil
                         ? "This session is frozen"
                         : "Session not closed yet")
                } footer: {
                    Text(session.frozenDate != nil
                         ? "The note you type is kept verbatim in the session's date edit history. It is your own record — not regulation advice."
                         : "Closing the session freezes its date first.")
                }
            }
            .navigationTitle("Edit Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editFrozenDate(newDate, auditNote: note)
                        // Only dismiss if the store accepted the edit.
                        if model.lastErrorMessage == nil { dismiss() }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("save-date-edit")
                }
            }
        }
        .onAppear { newDate = session.date }
    }
}

/// Shared length formatting (in/cm) used across workbench surfaces.
enum LengthFormat {
    static func string(_ length: Double, unit: LengthUnit) -> String {
        let value = length.formatted(.number.precision(.fractionLength(0...1)))
        switch unit {
        case .inches: return "\(value)\""
        case .centimeters: return "\(value) cm"
        }
    }
}
