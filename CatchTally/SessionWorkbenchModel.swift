import SwiftUI
import Observation
import CatchTallyKit

/// App-side view model for the Session Workbench (issue #4).
///
/// Like `TallyModel`, it performs **no arithmetic or validation itself** —
/// every edit goes through `CatchTallyStore`; the model only snapshots
/// state for the views and reports errors. Photos flow through the
/// injected `EntryPhotoStore` (app-private copies; never written back to
/// the user's photo library).
@MainActor
@Observable
final class SessionWorkbenchModel {
    let store: CatchTallyStore
    let photos: any EntryPhotoStore
    let sessionId: Int64

    // Published snapshot state (refreshed after every mutation).
    var session: Session?
    var entries: [CatchEntry] = []
    var speciesNames: [Int64: String] = [:]
    var spotName: String?
    var filter: EntryFilter = .all
    var lastErrorMessage: String?

    init(store: CatchTallyStore, photos: any EntryPhotoStore, sessionId: Int64) {
        self.store = store
        self.photos = photos
        self.sessionId = sessionId
        refresh()
    }

    /// App-private photo directory. Photos live beside the database in the
    /// app's own container — no photo-library write-back, no network.
    static func openDefaultPhotoStore() -> any EntryPhotoStore {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            return try DirectoryPhotoStore(
                directory: dir.appendingPathComponent("EntryPhotos", isDirectory: true))
        } catch {
            // A volatile fallback loses nothing the durable store holds —
            // the DB reference is written only after a successful copy, and
            // issue #6's backup path re-picks bytes from wherever they are.
            return InMemoryPhotoStore()
        }
    }

    // MARK: - Snapshot refresh

    func refresh() {
        do {
            session = try store.fetchSession(id: sessionId)
            entries = try store.fetchEntries(sessionId: sessionId, filter: filter)
            speciesNames = Dictionary(
                uniqueKeysWithValues: try store.fetchSpecies().map { ($0.id!, $0.name) })
            if let spotId = session?.spotId {
                spotName = try store.fetchSpots().first { $0.id == spotId }?.name
            } else {
                spotName = nil
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    var visibleEntries: [CatchEntry] { entries }

    func speciesName(for entry: CatchEntry) -> String {
        speciesNames[entry.speciesId] ?? "species"
    }

    // MARK: - Entry edits (domain validation lives in the store)

    func saveDetail(
        entryId: Int64, length: Double?, unit: LengthUnit?,
        disposition: Disposition, notes: String?
    ) {
        do { _ = try store.updateEntryDetail(
            id: entryId, length: length, lengthUnit: unit,
            disposition: disposition, notes: notes) }
        catch { report(error) }
        refresh()
    }

    func toggleDisposition(entryId: Int64) {
        do { _ = try store.toggleDisposition(id: entryId) } catch { report(error) }
        refresh()
    }

    func delete(entryId: Int64) {
        do { try store.deleteEntry(id: entryId, from: photos) } catch { report(error) }
        refresh()
    }

    // MARK: - Photo lifecycle (app-private copies, one per entry)

    /// Attach a downscaled JPEG copy the app took from the picker's data.
    func attachPhoto(entryId: Int64, jpegData: Data, altText: String?) {
        let ref = "entry-\(entryId)-\(UUID().uuidString).jpg"
        do {
            _ = try store.attachEntryPhoto(
                id: entryId, data: jpegData, ref: ref, altText: altText, to: photos)
        } catch { report(error) }
        refresh()
    }

    func removePhoto(entryId: Int64) {
        do { try store.detachEntryPhoto(id: entryId, from: photos) } catch { report(error) }
        refresh()
    }

    func setPhotoAltText(entryId: Int64, altText: String?) {
        do { try store.setEntryPhotoAltText(id: entryId, altText: altText) }
        catch { report(error) }
        refresh()
    }

    func photoData(for entry: CatchEntry) -> Data? {
        guard let ref = entry.photoRef else { return nil }
        return try? photos.readPhoto(ref: ref)
    }

    // MARK: - Session close / frozen-date editing

    func closeSession() {
        do { try store.closeSession(id: sessionId) } catch { report(error) }
        refresh()
    }

    /// Explicit frozen-date edit — the store rejects empty audit notes.
    func editFrozenDate(_ newDate: Date, auditNote: String) {
        do { try store.editSessionDate(id: sessionId, to: newDate, auditNote: auditNote) }
        catch { report(error) }
        refresh()
    }

    private func report(_ error: Error) {
        lastErrorMessage = "\(error)"
    }
}
