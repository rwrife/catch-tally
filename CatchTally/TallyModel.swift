import SwiftUI
import Observation
import CatchTallyKit

/// App-side view model for the Quick Tally vertical slice (issue #3).
///
/// Every mutation goes through `CatchTallyKit` domain calls — the view model
/// performs **no tally arithmetic**; totals are always re-read from the
/// store's derived views, so what the user sees is exactly what is durable.
@MainActor
@Observable
final class TallyModel {
    let store: CatchTallyStore

    // Published snapshot state (refreshed after every mutation).
    var species: [Species] = []
    var sessions: [Session] = []
    var spots: [Spot] = []
    var activeSession: Session?
    var tallies: [Int64: SpeciesTally] = [:]
    var grandTotal = SpeciesTally(total: 0, kept: 0)
    var lastMutation: LastMutation?
    var canUndo = false
    var lastErrorMessage: String?

    init() {
        do {
            store = try Self.openDefaultStore()
        } catch {
            // A failed store open is fatal for the product's premise; surface
            // it rather than silently falling back to volatile memory.
            store = try! CatchTallyStore()
            lastErrorMessage = "Could not open the local store: \(error)"
        }
        refresh()
    }

    /// File-backed store in Application Support (survives relaunch — the
    /// acceptance criterion "relaunching the app restores exact state").
    private static func openDefaultStore() throws -> CatchTallyStore {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let url = dir.appendingPathComponent("catchtally.sqlite")
        return try CatchTallyStore(url: url)
    }

    // MARK: - Snapshot refresh

    /// Re-read all derived state from the store. Called after every mutation
    /// and on appear — the store is the single source of truth.
    func refresh() {
        do {
            species = try store.fetchSpecies()
            sessions = try store.fetchSessions()
            spots = try store.fetchSpots()
            if let active = activeSession,
               let activeId = active.id,
               let fresh = try store.fetchSession(id: activeId) {
                activeSession = fresh
                tallies = try store.sessionTotals(sessionId: fresh.id)
                grandTotal = try store.sessionGrandTotal(sessionId: fresh.id)
                lastMutation = try store.lastMutation()
                canUndo = try store.canUndo()
            } else {
                tallies = [:]
                grandTotal = SpeciesTally(total: 0, kept: 0)
                lastMutation = nil
                canUndo = false
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    // MARK: - Species management (persisted through the store)

    func addSpecies(name: String) {
        var s = Species(name: name.trimmingCharacters(in: .whitespaces))
        do { try store.saveSpecies(&s) } catch { report(error) }
        refresh()
    }

    func renameSpecies(id: Int64, to name: String) {
        do { try store.renameSpecies(id: id, to: name.trimmingCharacters(in: .whitespaces)) }
        catch { report(error) }
        refresh()
    }

    func deleteSpecies(id: Int64) {
        do { try store.deleteSpecies(id: id) } catch { report(error) }
        refresh()
    }

    // MARK: - Sessions

    /// Start a session now. Optional inline spot: if `spotName` is non-empty
    /// a new Spot is created first and attached to the session.
    func startSession(spotName: String?) {
        var spotId: Int64?
        if let spotName, !spotName.trimmingCharacters(in: .whitespaces).isEmpty {
            var spot = Spot(name: spotName.trimmingCharacters(in: .whitespaces))
            do { try store.saveSpot(&spot) } catch { report(error); return }
            spotId = spot.id
        }
        var session = Session(date: Date(), spotId: spotId, status: .active)
        do { try store.saveSession(&session) } catch { report(error); return }
        activeSession = session
        refresh()
    }

    func openSession(_ session: Session) {
        activeSession = session
        refresh()
    }

    func closeActiveSession() {
        guard let id = activeSession?.id else { return }
        do { try store.closeSession(id: id) } catch { report(error) }
        activeSession = nil
        refresh()
    }

    // MARK: - Tally mutations (all arithmetic lives in CatchTallyKit)

    /// +1 tap.
    func tallyOne(_ speciesId: Int64) {
        guard let sessionId = activeSession?.id else { return }
        do { try store.addCatch(sessionId: sessionId, speciesId: speciesId) }
        catch { report(error) }
        refresh()
    }

    /// Long-press batch add, already confirmed by the user in the UI.
    func tallyBatch(_ speciesId: Int64, count: Int) {
        guard let sessionId = activeSession?.id else { return }
        do { try store.addBatch(sessionId: sessionId, speciesId: speciesId, count: count) }
        catch { report(error) }
        refresh()
    }

    /// −1 tap (clamped at zero inside the store).
    func tallyOneOff(_ speciesId: Int64) {
        guard let sessionId = activeSession?.id else { return }
        do { try store.decrement(sessionId: sessionId, speciesId: speciesId) }
        catch TallyError.clampedAtZero { refresh() }  // no-op; just repaint
        catch { report(error) }
        refresh()
    }

    func undo() {
        do { try store.undoLast() } catch { report(error) }
        refresh()
    }

    // MARK: - Helpers

    func tally(for speciesId: Int64) -> SpeciesTally {
        tallies[speciesId] ?? SpeciesTally(total: 0, kept: 0)
    }

    func spotName(for session: Session) -> String? {
        guard let spotId = session.spotId else { return nil }
        return spots.first { $0.id == spotId }?.name
    }

    func speciesName(id: Int64) -> String {
        species.first { $0.id == id }?.name ?? "species"
    }

    private func report(_ error: Error) {
        lastErrorMessage = "\(error)"
    }
}
