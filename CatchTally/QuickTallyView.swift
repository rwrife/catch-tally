import SwiftUI
import CatchTallyKit

/// The Quick Tally screen (issue #3): large one-handed targets for wet-hands
/// tallying. +1 tap, long-press batch add with confirmation, −1, and a
/// visible undo of the last mutation. All arithmetic lives in CatchTallyKit;
/// this view only reads derived totals.
struct QuickTallyView: View {
    @Bindable var model: TallyModel
    let session: Session
    /// Opens the Session Workbench for this session (issue #4).
    var onOpenWorkbench: () -> Void

    /// Long-press pending batch: species + candidate count shown in the
    /// confirmation dialog. The count is only *proposed* here — the store
    /// applies it as one journaled mutation after confirmation.
    @State private var pendingBatch: (species: Species, count: Int)?
    @State private var batchCounter = 1

    var body: some View {
        VStack(spacing: 0) {
            sessionBanner
            Divider()
            speciesTallyList
        }
        .navigationTitle("Quick Tally")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("End Session") { model.closeActiveSession() }
                    .accessibilityIdentifier("end-session-button")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onOpenWorkbench()
                } label: {
                    Label("Workbench", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("open-workbench-button")
            }
        }
        .safeAreaInset(edge: .bottom) { undoBar }
        .confirmationDialog(
            "Add \(batchCounter) \(pendingBatch.map { $0.species.name } ?? "")?",
            isPresented: Binding(
                get: { pendingBatch != nil },
                set: { if !$0 { pendingBatch = nil } }),
            titleVisibility: .visible
        ) {
            Button("Confirm add \(batchCounter)") {
                if let pb = pendingBatch, let id = pb.species.id {
                    model.tallyBatch(id, count: batchCounter)
                }
                pendingBatch = nil
            }
            Button("Cancel", role: .cancel) { pendingBatch = nil }
        } message: {
            Text("Long-press adds a batch as a single undoable step.")
        }
    }

    // MARK: - Session banner (live totals)

    private var sessionBanner: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let spot = model.spotName(for: session) {
                    Text(spot)
                        .font(.subheadline.weight(.medium))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Total \(model.grandTotal.total)")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text("kept \(model.grandTotal.kept)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Session total \(model.grandTotal.total) fish, kept \(model.grandTotal.kept)")
        .accessibilityIdentifier("session-total-banner")
    }

    // MARK: - Per-species tally rows

    private var speciesTallyList: some View {
        Group {
            if model.species.isEmpty {
                ContentUnavailableView(
                    "No species yet",
                    systemImage: "fish",
                    description: Text("Add species with the Species button first.")
                )
            } else {
                List {
                    ForEach(model.species, id: \.id) { sp in
                        SpeciesTallyRow(
                            model: model,
                            species: sp,
                            onBatchRequest: { count in
                                batchCounter = count
                                pendingBatch = (sp, count)
                            }
                        )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Undo bar

    @ViewBuilder
    private var undoBar: some View {
        if model.canUndo, let last = model.lastMutation {
            Button {
                model.undo()
            } label: {
                Label(
                    "Undo \(last.kind == .added ? "+" : "−")\(last.count) "
                        + model.speciesName(id: last.speciesId),
                    systemImage: "arrow.uturn.backward"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding()
            .accessibilityIdentifier("undo-button")
        }
    }
}

/// One species row: huge +1 target (also long-press for batch), small −1,
/// live derived count. Sized for one-handed wet-glove operation; every
/// control ≥ 44pt (the +1 is deliberately oversized).
private struct SpeciesTallyRow: View {
    let model: TallyModel
    let species: Species
    /// Requests UI confirmation of a batch add of `count` fish.
    let onBatchRequest: (_ count: Int) -> Void

    var body: some View {
        let tally = model.tally(for: species.id!)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(species.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("total \(tally.total) · kept \(tally.kept)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)

            Button {
                model.tallyOneOff(species.id!)
            } label: {
                Image(systemName: "minus")
                    .font(.title2.weight(.bold))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(tally.total == 0)
            .accessibilityLabel("Remove one \(species.name)")
            .accessibilityIdentifier("minus-\(species.id!)")

            // Count lives inside the big target so VoiceOver announces
            // species AND current count with the primary control.
            Button {
                model.tallyOne(species.id!)
            } label: {
                VStack(spacing: 0) {
                    Text("\(tally.total)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: "plus")
                        .font(.footnote)
                }
                .frame(width: 84, height: 72)
            }
            .buttonStyle(.borderedProminent)
            // Long-press (0.45s) proposes a batch of 5; releasing before that
            // fires the plain +1 tap. The batch goes through a confirmation
            // dialog and lands as ONE undoable mutation in the store.
            .onLongPressGesture(minimumDuration: 0.45) {
                onBatchRequest(5)
            }
            .accessibilityLabel("Add one \(species.name), current count \(tally.total)")
            .accessibilityIdentifier("plus-\(species.id!)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(species.name), total \(tally.total), kept \(tally.kept)")
    }
}
