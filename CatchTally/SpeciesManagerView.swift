import SwiftUI
import CatchTallyKit

/// Species management: add / rename / delete, persisted through the store.
struct SpeciesManagerView: View {
    @Bindable var model: TallyModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renaming: Species?
    @State private var renameText = ""
    @State private var pendingDelete: Species?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New species name", text: $newName)
                            .accessibilityLabel("New species name")
                            .onSubmit(addSpecies)
                        Button("Add", action: addSpecies)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("add-species-button")
                    }
                }
                if model.species.isEmpty {
                    Section {
                        Text("No species yet — add the fish you fish for.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Species") {
                        ForEach(model.species, id: \.id) { sp in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sp.name)
                                    if let note = sp.keepLimitNote {
                                        Text(note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Rename") {
                                    renameText = sp.name
                                    renaming = sp
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    pendingDelete = sp
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Species")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename species", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
            ) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let sp = renaming {
                        model.renameSpecies(id: sp.id!, to: renameText)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Delete this species?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete \(pendingDelete?.name ?? "")", role: .destructive) {
                    if let sp = pendingDelete, let id = sp.id {
                        model.deleteSpecies(id: id)
                    }
                    pendingDelete = nil
                }
                Button("Keep", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Entries for this species in past sessions will be removed too.")
            }
        }
    }

    private func addSpecies() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.addSpecies(name: trimmed)
        newName = ""
    }
}
