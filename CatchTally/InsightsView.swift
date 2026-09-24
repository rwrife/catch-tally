import SwiftUI
import Observation
import CatchTallyKit

/// Snapshot view model for the derived-views screens (issue #5):
/// personal-best board, spot history, kept-count dashboard.
///
/// It performs NO derivation itself — every row is re-read from the store's
/// derived queries, which recompute live from `catch_entry`. The view model
/// only holds the last snapshot and reports errors, matching the
/// TallyModel / SessionWorkbenchModel pattern.
@MainActor
@Observable
final class InsightsModel {
    let store: CatchTallyStore

    var board: [PersonalBestRow] = []
    var spots: [SpotHistoryRow] = []
    var kept: [KeptCountRow] = []
    var lastErrorMessage: String?

    init(store: CatchTallyStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        do {
            board = try store.personalBestBoard()
            spots = try store.spotHistories()
            kept = try store.keptCountDashboard()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }
}

/// Which derived board is showing.
enum InsightsTab: String, CaseIterable, Identifiable {
    case bests = "Bests"
    case spots = "Spots"
    case kept = "Kept"
    var id: String { rawValue }
}

/// Tabbed entry point for all three derived views.
struct InsightsView: View {
    @State private var model: InsightsModel
    @State private var tab: InsightsTab = .bests

    init(store: CatchTallyStore) {
        _model = State(initialValue: InsightsModel(store: store))
    }

    var body: some View {
        List {
            Picker("Insights", selection: $tab) {
                ForEach(InsightsTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("insights-tab-picker")

            switch tab {
            case .bests: PersonalBestBoardList(model: model)
            case .spots: SpotHistoryList(model: model)
            case .kept: KeptCountList(model: model)
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { model.refresh() }
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
}

// MARK: - Personal-best board

/// One row per species. Species/entries with no recorded length are shown
/// as "No length recorded" — the board never fabricates a PB.
private struct PersonalBestBoardList: View {
    @Bindable var model: InsightsModel

    var body: some View {
        Section {
            if model.board.isEmpty {
                Text("No species yet — add species and log catches first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.board, id: \.speciesId) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.speciesName)
                            .font(.headline)
                        if row.bests.isEmpty {
                            // Unknown stays unknown: never a zero-length "best".
                            Text(row.hasAnyEntry
                                 ? "No length recorded"
                                 : "No catches logged")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(row.bests, id: \.unit) { best in
                                HStack(alignment: .firstTextBaseline) {
                                    Label(
                                        "\(best.length, format: .number(precision: .fractionLength(0...1))) \(best.unit == .centimeters ? "cm" : "in")",
                                        systemImage: "trophy"
                                    )
                                    .font(.body.weight(.semibold))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(best.sessionDate, format: .dateTime.month().day().year())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(best.spotName ?? "No spot")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        if row.entriesWithoutLength > 0 {
                            Text("\(row.entriesWithoutLength) without length recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pb-row-\(row.speciesId)")
                }
            }
        } header: {
            Text("Personal bests")
        } footer: {
            Text("Bests come only from entries that recorded a length. Different units are ranked separately.")
        }
    }
}

// MARK: - Spot history

private struct SpotHistoryList: View {
    @Bindable var model: InsightsModel

    var body: some View {
        Section {
            if model.spots.isEmpty {
                Text("No spots yet — spots come from sessions with a location.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.spots, id: \.spotId) { spot in
                    DisclosureGroup {
                        ForEach(spot.sessions, id: \.sessionId) { s in
                            HStack {
                                Text(s.date, format: .dateTime.month().day().year())
                                Spacer()
                                Text("\(s.totalCaught) caught · \(s.kept) kept")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(spot.spotName)
                                .font(.headline)
                            Text("\(spot.totalCaught) caught · \(spot.kept) kept · \(spot.sessions.count) session\(spot.sessions.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if spot.bestsPerSpecies.isEmpty {
                                Text("No length recorded at this spot")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(spot.bestsPerSpecies, id: \.speciesId) { sb in
                                    ForEach(sb.bests, id: \.unit) { best in
                                        Text("\(sb.speciesName): best \(best.length, format: .number(precision: .fractionLength(0...1))) \(best.unit == .centimeters ? "cm" : "in")")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("spot-row-\(spot.spotId)")
                }
            }
        } header: {
            Text("Spot history")
        } footer: {
            Text("Per-spot sessions, totals, and the best of each species caught there.")
        }
    }
}

// MARK: - Kept-count dashboard

/// Kept totals against the USER'S OWN typed keep-limit note. When a count
/// meets/exceeds the note, the reminder quotes the user's text verbatim and
/// states plainly that it is their own note — the app ships no regulation
/// data and never asserts legal limits (README non-goal).
private struct KeptCountList: View {
    @Bindable var model: InsightsModel

    var body: some View {
        Section {
            if model.kept.isEmpty {
                Text("No species yet — add species and log catches first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.kept, id: \.speciesId) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.speciesName)
                                .font(.headline)
                            Spacer()
                            Text("kept \(row.kept) of \(row.totalCaught)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let note = row.userNote {
                            if row.reachedOrExceeded {
                                // Text + icon, never color-only encoding.
                                Label {
                                    Text("Your note says “\(note)” — your kept count has met or passed it. This is your own note, not current regulation advice.")
                                        .font(.callout)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle")
                                }
                                .accessibilityIdentifier("kept-reminder-\(row.speciesId)")
                            } else {
                                Text("Your note: “\(note)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // No note ⇒ plain count only; no reminder state exists.
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("kept-row-\(row.speciesId)")
                }
            }
        } header: {
            Text("Kept vs your own notes")
        } footer: {
            Text("Notes are your own words, shown verbatim. Catch Tally ships no regulation data and its reminders are never legal advice.")
        }
    }
}
