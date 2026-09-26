import Foundation
import GRDB

public enum DataOwnershipError: Error, Equatable, Sendable {
    case invalidBackupArchive(String)
    case missingManifest
    case backupNewerThanApp(backupVersion: Int, appSupportedVersion: Int)
    case corruptManifest(String)
    case restoreFailed(String)
}

extension DataOwnershipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidBackupArchive(reason):
            return "Invalid backup archive: \(reason)"
        case .missingManifest:
            return "Backup archive is missing manifest.json"
        case let .backupNewerThanApp(backupVersion, appSupportedVersion):
            return "Backup schema version \(backupVersion) is newer than supported version (\(appSupportedVersion)). Please update Catch Tally to restore this backup."
        case let .corruptManifest(reason):
            return "Backup manifest is corrupt: \(reason)"
        case let .restoreFailed(reason):
            return "Restore failed: \(reason)"
        }
    }
}

/// Versioned metadata stamped onto every backup file (issue #6).
public struct BackupMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultAppVersion = "0.1.0"

    public var schemaVersion: Int
    public var appVersion: String
    public var createdAt: Date
    public var migrationIdentifier: String?

    public init(
        schemaVersion: Int = BackupMetadata.currentSchemaVersion,
        appVersion: String = BackupMetadata.defaultAppVersion,
        createdAt: Date = Date(),
        migrationIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.migrationIdentifier = migrationIdentifier
    }
}

/// JSON manifest payload serialized inside `manifest.json`.
public struct BackupManifest: Codable, Equatable, Sendable {
    public var metadata: BackupMetadata
    public var species: [Species]
    public var spots: [Spot]
    public var sessions: [Session]
    public var entries: [CatchEntry]
    /// List of photo references packaged in the archive under `photos/<ref>`.
    public var photoRefs: [String]

    public init(
        metadata: BackupMetadata,
        species: [Species],
        spots: [Spot],
        sessions: [Session],
        entries: [CatchEntry],
        photoRefs: [String]
    ) {
        self.metadata = metadata
        self.species = species
        self.spots = spots
        self.sessions = sessions
        self.entries = entries
        self.photoRefs = photoRefs
    }
}

/// Storage meter metrics for the privacy surface.
public struct StorageUsage: Equatable, Sendable {
    public var databaseBytes: Int64
    public var photoBytes: Int64
    public var speciesCount: Int
    public var spotCount: Int
    public var sessionCount: Int
    public var entryCount: Int
    public var photoCount: Int

    public var totalBytes: Int64 {
        databaseBytes + photoBytes
    }

    public init(
        databaseBytes: Int64,
        photoBytes: Int64,
        speciesCount: Int,
        spotCount: Int,
        sessionCount: Int,
        entryCount: Int,
        photoCount: Int
    ) {
        self.databaseBytes = databaseBytes
        self.photoBytes = photoBytes
        self.speciesCount = speciesCount
        self.spotCount = spotCount
        self.sessionCount = sessionCount
        self.entryCount = entryCount
        self.photoCount = photoCount
    }
}

// MARK: - Backup, Restore, CSV, and Storage APIs on CatchTallyStore

extension CatchTallyStore {
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Create an in-memory backup manifest describing all domain data.
    public func createBackupManifest(
        appVersion: String = BackupMetadata.defaultAppVersion
    ) throws -> BackupManifest {
        try reader.read { r in
            let species = try Species.order(Column("id")).fetchAll(r)
            let spots = try Spot.order(Column("id")).fetchAll(r)
            let sessions = try Session.order(Column("id")).fetchAll(r)
            let entries = try CatchEntry.order(Column("id")).fetchAll(r)

            var photoRefs: [String] = []
            var seen = Set<String>()
            for e in entries {
                if let ref = e.photoRef, seen.insert(ref).inserted {
                    photoRefs.append(ref)
                }
            }
            photoRefs.sort()

            let migrationId: String?
            if try r.tableExists("grdb_migrations") {
                let applied = try String.fetchSet(
                    r, sql: "SELECT identifier FROM grdb_migrations")
                migrationId = CatchTallyStore.migrationIdentifiers.last {
                    applied.contains($0)
                }
            } else {
                migrationId = nil
            }
            let metadata = BackupMetadata(
                schemaVersion: BackupMetadata.currentSchemaVersion,
                appVersion: appVersion,
                createdAt: Date(),
                migrationIdentifier: migrationId)

            return BackupManifest(
                metadata: metadata,
                species: species,
                spots: spots,
                sessions: sessions,
                entries: entries,
                photoRefs: photoRefs)
        }
    }

    /// Export a full ZIP backup bundle containing `manifest.json` and
    /// all referenced photo binaries under `photos/<photoRef>`.
    public func exportBackup(
        photoStore: (any EntryPhotoStore)? = nil,
        appVersion: String = BackupMetadata.defaultAppVersion
    ) throws -> Data {
        let manifest = try createBackupManifest(appVersion: appVersion)
        let manifestData = try Self.jsonEncoder.encode(manifest)

        var zipEntries: [ZipArchive.Entry] = [
            ZipArchive.Entry(path: "manifest.json", data: manifestData)
        ]

        if let photoStore {
            for ref in manifest.photoRefs {
                if let data = try photoStore.readPhoto(ref: ref) {
                    zipEntries.append(ZipArchive.Entry(path: "photos/\(ref)", data: data))
                }
            }
        }

        do {
            return try ZipArchive.create(entries: zipEntries)
        } catch let zipErr as ZipArchive.ZipError {
            throw DataOwnershipError.invalidBackupArchive("\(zipErr)")
        }
    }

    /// Transactionally restore backup from a ZIP archive.
    ///
    /// Refuses backups with schema version newer than this app.
    /// All-or-nothing on corrupt archives: if manifest decoding or DB insertion
    /// fails, existing data is untouched.
    public func restoreBackup(from zipData: Data, photoStore: (any EntryPhotoStore)? = nil) throws {
        let extracted: [String: Data]
        do {
            extracted = try ZipArchive.extract(zipData)
        } catch let zipErr as ZipArchive.ZipError {
            throw DataOwnershipError.invalidBackupArchive("\(zipErr)")
        } catch {
            throw DataOwnershipError.invalidBackupArchive(error.localizedDescription)
        }

        guard let manifestData = extracted["manifest.json"] else {
            throw DataOwnershipError.missingManifest
        }

        let manifest: BackupManifest
        do {
            manifest = try Self.jsonDecoder.decode(BackupManifest.self, from: manifestData)
        } catch {
            throw DataOwnershipError.corruptManifest(error.localizedDescription)
        }

        if manifest.metadata.schemaVersion > BackupMetadata.currentSchemaVersion {
            throw DataOwnershipError.backupNewerThanApp(
                backupVersion: manifest.metadata.schemaVersion,
                appSupportedVersion: BackupMetadata.currentSchemaVersion)
        }

        // Collect photos to write if photoStore provided
        var photosToWrite: [(ref: String, data: Data)] = []
        for ref in manifest.photoRefs {
            if let data = extracted["photos/\(ref)"] {
                photosToWrite.append((ref: ref, data: data))
            }
        }

        // Snapshot current photos for rollback in case of error
        var previousPhotos: [String: Data] = [:]
        if let photoStore {
            let existingEntries = try fetchAllEntries()
            for e in existingEntries {
                if let ref = e.photoRef, previousPhotos[ref] == nil {
                    if let d = try? photoStore.readPhoto(ref: ref) {
                        previousPhotos[ref] = d
                    }
                }
            }
        }

        // Perform transactional database rewrite. Deletes go child-before-parent
        // and inserts go parent-before-child so referential integrity holds
        // throughout — no need to (and no-op inside GRDB's already-open
        // transaction to) toggle `PRAGMA foreign_keys`.
        do {
            try writer.write { w in
                // Clear all tables
                try w.execute(sql: "DELETE FROM undo_tombstone")
                try w.execute(sql: "DELETE FROM undo_entry")
                try w.execute(sql: "DELETE FROM undo_mutation")
                try w.execute(sql: "DELETE FROM catch_entry")
                try w.execute(sql: "DELETE FROM session")
                try w.execute(sql: "DELETE FROM spot")
                try w.execute(sql: "DELETE FROM species")

                // Insert species with preserved IDs
                for s in manifest.species {
                    try w.execute(
                        sql: "INSERT INTO species (id, name, keepLimitNote) VALUES (?, ?, ?)",
                        arguments: [s.id, s.name, s.keepLimitNote])
                }

                // Insert spots with preserved IDs
                for sp in manifest.spots {
                    try w.execute(
                        sql: "INSERT INTO spot (id, name, description) VALUES (?, ?, ?)",
                        arguments: [sp.id, sp.name, sp.description])
                }

                // Insert sessions with preserved IDs
                for sess in manifest.sessions {
                    try w.execute(
                        sql: """
                        INSERT INTO session (id, date, spotId, notes, status, frozenDate, dateAuditNote)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            sess.id,
                            sess.date,
                            sess.spotId,
                            sess.notes,
                            sess.status.rawValue,
                            sess.frozenDate,
                            sess.dateAuditNote,
                        ])
                }

                // Insert catch entries with preserved IDs
                for entry in manifest.entries {
                    try w.execute(
                        sql: """
                        INSERT INTO catch_entry (id, sessionId, speciesId, length, lengthUnit, disposition, photoRef, photoAltText, notes, timestamp)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            entry.id,
                            entry.sessionId,
                            entry.speciesId,
                            entry.length,
                            entry.lengthUnit?.rawValue,
                            entry.disposition.rawValue,
                            entry.photoRef,
                            entry.photoAltText,
                            entry.notes,
                            entry.timestamp,
                        ])
                }
            }
        } catch {
            throw DataOwnershipError.restoreFailed("database transaction failed: \(error)")
        }

        // If DB succeeded, update photo store
        if let photoStore {
            do {
                // Delete previous photos that are not in the new manifest
                for (oldRef, _) in previousPhotos where !manifest.photoRefs.contains(oldRef) {
                    try? photoStore.deletePhoto(ref: oldRef)
                }
                // Write restored photos
                for item in photosToWrite {
                    try photoStore.writePhoto(data: item.data, ref: item.ref)
                }
            } catch {
                // Best effort rollback of photoStore
                for (ref, data) in previousPhotos {
                    try? photoStore.writePhoto(data: data, ref: ref)
                }
                throw DataOwnershipError.restoreFailed("photo store restoration failed: \(error)")
            }
        }
    }

    private func fetchAllEntries() throws -> [CatchEntry] {
        try reader.read { r in
            try CatchEntry.fetchAll(r)
        }
    }

    // MARK: - CSV Export

    /// Export all catch entries as a CSV table.
    /// Columns: Date,Species,Length,Unit,Disposition,Spot,Session Notes,Entry Notes
    /// Sorted deterministically: session date, entry timestamp, entry id.
    public func exportCatchCSV() throws -> String {
        try reader.read { r in
            let query = """
            SELECT
                e.id AS entryId,
                e.timestamp AS entryTimestamp,
                e.length AS length,
                e.lengthUnit AS lengthUnit,
                e.disposition AS disposition,
                e.notes AS entryNotes,
                sp.name AS speciesName,
                sess.date AS sessionDate,
                sess.notes AS sessionNotes,
                spot.name AS spotName
            FROM catch_entry e
            JOIN species sp ON e.speciesId = sp.id
            JOIN session sess ON e.sessionId = sess.id
            LEFT JOIN spot ON sess.spotId = spot.id
            ORDER BY sess.date ASC, e.timestamp ASC, e.id ASC
            """
            let rows = try Row.fetchAll(r, sql: query)

            var csv = "Date,Species,Length,Unit,Disposition,Spot,Session Notes,Entry Notes\r\n"
            let dateFormatter = Self.makeISO8601Formatter()

            for row in rows {
                let entryTimestamp: Date = row["entryTimestamp"]
                let dateStr = dateFormatter.string(from: entryTimestamp)

                let speciesName: String = row["speciesName"]
                let lengthVal: Double? = row["length"]
                let lengthStr = lengthVal.map { val in
                    val == val.rounded() ? String(Int(val.rounded())) : String(format: "%.1f", val)
                } ?? ""

                let unitRaw: String? = row["lengthUnit"]
                let unitStr = unitRaw ?? ""

                let disposition: String = row["disposition"]
                let spotName: String? = row["spotName"]
                let spotStr = spotName ?? ""

                let sessionNotes: String? = row["sessionNotes"]
                let sessionNotesStr = sessionNotes ?? ""

                let entryNotes: String? = row["entryNotes"]
                let entryNotesStr = entryNotes ?? ""

                let line = [
                    Self.escapeCSVField(dateStr),
                    Self.escapeCSVField(speciesName),
                    Self.escapeCSVField(lengthStr),
                    Self.escapeCSVField(unitStr),
                    Self.escapeCSVField(disposition),
                    Self.escapeCSVField(spotStr),
                    Self.escapeCSVField(sessionNotesStr),
                    Self.escapeCSVField(entryNotesStr),
                ].joined(separator: ",")

                csv += line + "\r\n"
            }
            return csv
        }
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    // MARK: - Privacy & Storage Surface

    /// Query storage metrics across SQLite and photo storage.
    public func storageUsage(photoStore: (any EntryPhotoStore)? = nil) throws -> StorageUsage {
        var dbBytes: Int64 = 0
        try reader.read { r in
            // Approximate database size via SQLite page_count * page_size
            if let pageCount = try Int64.fetchOne(r, sql: "PRAGMA page_count"),
               let pageSize = try Int64.fetchOne(r, sql: "PRAGMA page_size") {
                dbBytes = pageCount * pageSize
            }
        }

        let speciesCount = try fetchSpecies().count
        let spotsCount = try fetchSpots().count
        let sessionsCount = try fetchSessions().count
        let entries = try fetchAllEntries()
        let entriesCount = entries.count

        var photoBytes: Int64 = 0
        var photoCount = 0
        if let photoStore {
            var seen = Set<String>()
            for e in entries {
                if let ref = e.photoRef, seen.insert(ref).inserted {
                    photoCount += 1
                    photoBytes += Int64(try photoStore.byteCount(ref: ref))
                }
            }
        }

        return StorageUsage(
            databaseBytes: dbBytes,
            photoBytes: photoBytes,
            speciesCount: speciesCount,
            spotCount: spotsCount,
            sessionCount: sessionsCount,
            entryCount: entriesCount,
            photoCount: photoCount)
    }

    /// Atomic deletion of all app data across database and photo store.
    public func deleteAllData(photoStore: (any EntryPhotoStore)? = nil) throws {
        // Collect photo references before deleting DB rows
        var photosToDelete: [String] = []
        if photoStore != nil {
            let entries = try fetchAllEntries()
            for e in entries {
                if let ref = e.photoRef {
                    photosToDelete.append(ref)
                }
            }
        }

        try writer.write { w in
            try w.execute(sql: "DELETE FROM undo_tombstone")
            try w.execute(sql: "DELETE FROM undo_entry")
            try w.execute(sql: "DELETE FROM undo_mutation")
            try w.execute(sql: "DELETE FROM catch_entry")
            try w.execute(sql: "DELETE FROM session")
            try w.execute(sql: "DELETE FROM spot")
            try w.execute(sql: "DELETE FROM species")
        }

        if let photoStore {
            for ref in photosToDelete {
                try? photoStore.deletePhoto(ref: ref)
            }
        }
    }
}
