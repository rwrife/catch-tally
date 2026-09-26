import Foundation
import Testing
@testable import CatchTallyKit

@Suite("Data ownership & privacy (issue #6)")
struct DataOwnershipTests {

    private func makeFixture() throws -> (store: CatchTallyStore, photos: InMemoryPhotoStore) {
        let store = try CatchTallyStore()
        let photos = InMemoryPhotoStore()

        var sp1 = Species(name: "Walleye", keepLimitNote: "4 per day (min 15\")")
        try store.saveSpecies(&sp1)
        var sp2 = Species(name: "Perch")
        try store.saveSpecies(&sp2)

        var spot1 = Spot(name: "Cedar Point", description: "Near the lighthouse")
        try store.saveSpot(&spot1)
        var spot2 = Spot(name: "Dock")
        try store.saveSpot(&spot2)

        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        var sess1 = Session(date: d1, spotId: spot1.id, notes: "Morning drift", status: .active)
        try store.saveSession(&sess1)

        let d2 = Date(timeIntervalSince1970: 1_700_100_000)
        var sess2 = Session(date: d2, spotId: spot2.id, notes: "Evening dock", status: .active)
        try store.saveSession(&sess2)
        try store.closeSession(id: sess2.id!, closedAt: Date(timeIntervalSince1970: 1_700_103_600))
        try store.editSessionDate(
            id: sess2.id!,
            to: Date(timeIntervalSince1970: 1_700_105_000),
            auditNote: "Corrected launch time")

        let t1 = Date(timeIntervalSince1970: 1_700_000_500)
        let e1 = try store.addCatch(sessionId: sess1.id!, speciesId: sp1.id!, disposition: .kept, timestamp: t1)
        _ = try store.updateEntryDetail(
            id: e1, length: 19.5, lengthUnit: .inches, disposition: .kept, notes: "Caught on jig")
        let photo1 = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])
        _ = try store.attachEntryPhoto(id: e1, data: photo1, ref: "photo-1.jpg", altText: "19.5 inch walleye", to: photos)

        let t2 = Date(timeIntervalSince1970: 1_700_001_000)
        let e2 = try store.addCatch(sessionId: sess1.id!, speciesId: sp2.id!, disposition: .released, timestamp: t2)
        _ = try store.updateEntryDetail(
            id: e2, length: nil, lengthUnit: nil, disposition: .released, notes: "Small one, released safely")

        let t3 = Date(timeIntervalSince1970: 1_700_101_000)
        let e3 = try store.addCatch(sessionId: sess2.id!, speciesId: sp1.id!, disposition: .kept, timestamp: t3)
        _ = try store.updateEntryDetail(
            id: e3, length: 48.0, lengthUnit: .centimeters, disposition: .kept, notes: "Keeper, nice fight")
        let photo2 = Data([0xCA, 0xFE, 0xBA, 0xBE, 0xAA, 0xBB])
        _ = try store.attachEntryPhoto(id: e3, data: photo2, ref: "photo-2.jpg", altText: "Walleye on scale", to: photos)

        return (store, photos)
    }

    @Test("Backup round-trip: export -> wipe -> restore restores byte-equivalent domain snapshot")
    func backupRoundTrip() throws {
        let (store, photos) = try makeFixture()

        // Capture source snapshot
        let origSpecies = try store.fetchSpecies()
        let origSpots = try store.fetchSpots()
        let origSessions = try store.fetchSessions()
        let origSess1Entries = try store.fetchEntries(sessionId: origSessions[1].id!)
        let origSess2Entries = try store.fetchEntries(sessionId: origSessions[0].id!)
        let origPhotos = photos.refs.sorted()

        // Export backup
        let zipData = try store.exportBackup(photoStore: photos)
        #expect(!zipData.isEmpty)

        // Verify ZIP contents inspectable
        let extracted = try ZipArchive.extract(zipData)
        #expect(extracted["manifest.json"] != nil)
        #expect(extracted["photos/photo-1.jpg"] == Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]))
        #expect(extracted["photos/photo-2.jpg"] == Data([0xCA, 0xFE, 0xBA, 0xBE, 0xAA, 0xBB]))

        // Wipe data completely
        try store.deleteAllData(photoStore: photos)
        #expect(try store.fetchSpecies().isEmpty)
        #expect(try store.fetchSpots().isEmpty)
        #expect(try store.fetchSessions().isEmpty)
        #expect(photos.refs.isEmpty)

        // Restore into wiped store
        try store.restoreBackup(from: zipData, photoStore: photos)

        // Assert exact domain snapshot restored
        let restoredSpecies = try store.fetchSpecies()
        #expect(restoredSpecies == origSpecies)

        let restoredSpots = try store.fetchSpots()
        #expect(restoredSpots == origSpots)

        let restoredSessions = try store.fetchSessions()
        #expect(restoredSessions == origSessions)
        #expect(restoredSessions[0].frozenDate != nil)
        #expect(restoredSessions[0].dateAuditNote?.contains("Corrected launch time") == true)

        let restoredSess1Entries = try store.fetchEntries(sessionId: origSessions[1].id!)
        #expect(restoredSess1Entries == origSess1Entries)

        let restoredSess2Entries = try store.fetchEntries(sessionId: origSessions[0].id!)
        #expect(restoredSess2Entries == origSess2Entries)

        #expect(photos.refs.sorted() == origPhotos)
        #expect(try photos.readPhoto(ref: "photo-1.jpg") == Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]))
        #expect(try photos.readPhoto(ref: "photo-2.jpg") == Data([0xCA, 0xFE, 0xBA, 0xBE, 0xAA, 0xBB]))
    }

    @Test("Restore refuses newer-than-app backup schema version with descriptive message")
    func refuseNewerSchema() throws {
        let (store, photos) = try makeFixture()
        var manifest = try store.createBackupManifest()
        manifest.metadata.schemaVersion = 99

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)

        let zipData = try ZipArchive.create(entries: [
            ZipArchive.Entry(path: "manifest.json", data: manifestData)
        ])

        #expect(throws: DataOwnershipError.backupNewerThanApp(backupVersion: 99, appSupportedVersion: 1)) {
            try store.restoreBackup(from: zipData, photoStore: photos)
        }
    }

    @Test("Restore is transactional: corrupt archive leaves existing store intact")
    func restoreTransactionalRollback() throws {
        let (store, photos) = try makeFixture()
        let origSpecies = try store.fetchSpecies()
        let origEntries = try store.fetchEntries(sessionId: try store.fetchSessions().first!.id!)

        // 1. Completely bogus data
        let corruptData = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        #expect(throws: DataOwnershipError.self) {
            try store.restoreBackup(from: corruptData, photoStore: photos)
        }
        #expect(try store.fetchSpecies() == origSpecies)

        // 2. ZIP with missing manifest
        let noManifestZip = try ZipArchive.create(entries: [
            ZipArchive.Entry(path: "random.txt", data: Data("hello".utf8))
        ])
        #expect(throws: DataOwnershipError.missingManifest) {
            try store.restoreBackup(from: noManifestZip, photoStore: photos)
        }
        #expect(try store.fetchSpecies() == origSpecies)

        // 3. ZIP with unparseable manifest
        let badManifestZip = try ZipArchive.create(entries: [
            ZipArchive.Entry(path: "manifest.json", data: Data("not-valid-json".utf8))
        ])
        #expect(throws: DataOwnershipError.self) {
            try store.restoreBackup(from: badManifestZip, photoStore: photos)
        }
        #expect(try store.fetchSpecies() == origSpecies)
        #expect(try store.fetchEntries(sessionId: try store.fetchSessions().first!.id!) == origEntries)
    }

    @Test("CSV export produces golden-format output with proper escaping")
    func csvGoldenExport() throws {
        let store = try CatchTallyStore()
        var sp1 = Species(name: "Largemouth Bass")
        try store.saveSpecies(&sp1)
        var sp2 = Species(name: "Northern Pike, \"Trophy\"")
        try store.saveSpecies(&sp2)

        var spot = Spot(name: "Weedbed #3, West Bay")
        try store.saveSpot(&spot)

        let sessDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        var sess = Session(date: sessDate, spotId: spot.id, notes: "Windy, overcast", status: .active)
        try store.saveSession(&sess)

        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let e1 = try store.addCatch(sessionId: sess.id!, speciesId: sp1.id!, disposition: .kept, timestamp: t1)
        _ = try store.updateEntryDetail(
            id: e1, length: 18.0, lengthUnit: .inches, disposition: .kept, notes: "Topwater frog")

        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let e2 = try store.addCatch(sessionId: sess.id!, speciesId: sp2.id!, disposition: .released, timestamp: t2)
        _ = try store.updateEntryDetail(
            id: e2, length: 75.5, lengthUnit: .centimeters, disposition: .released, notes: "Line broke in net;\r\nrescued fish")

        let t3 = Date(timeIntervalSince1970: 1_700_000_300)
        _ = try store.addCatch(sessionId: sess.id!, speciesId: sp1.id!, disposition: .released, timestamp: t3)

        let csv = try store.exportCatchCSV()

        let expectedHeader = "Date,Species,Length,Unit,Disposition,Spot,Session Notes,Entry Notes\r\n"
        #expect(csv.hasPrefix(expectedHeader))

        // Check line 1: 18 inch bass, kept
        #expect(csv.contains("Largemouth Bass,18,inches,kept,\"Weedbed #3, West Bay\",\"Windy, overcast\",Topwater frog"))

        // Check line 2: Northern Pike with commas & quotes, newline in notes, escaped quotes
        #expect(csv.contains("\"Northern Pike, \"\"Trophy\"\"\",75.5,centimeters,released,\"Weedbed #3, West Bay\",\"Windy, overcast\",\"Line broke in net;\r\nrescued fish\""))

        // Check line 3: unmeasured released bass
        #expect(csv.contains("Largemouth Bass,,,released,\"Weedbed #3, West Bay\",\"Windy, overcast\","))
    }

    @Test("Storage meter and deleteAllData privacy controls")
    func storageUsageAndWipe() throws {
        let (store, photos) = try makeFixture()

        let usage = try store.storageUsage(photoStore: photos)
        #expect(usage.speciesCount == 2)
        #expect(usage.spotCount == 2)
        #expect(usage.sessionCount == 2)
        #expect(usage.entryCount == 3)
        #expect(usage.photoCount == 2)
        #expect(usage.photoBytes > 0)
        #expect(usage.databaseBytes > 0)
        #expect(usage.totalBytes == usage.databaseBytes + usage.photoBytes)

        // Delete all data
        try store.deleteAllData(photoStore: photos)

        let wipedUsage = try store.storageUsage(photoStore: photos)
        #expect(wipedUsage.speciesCount == 0)
        #expect(wipedUsage.spotCount == 0)
        #expect(wipedUsage.sessionCount == 0)
        #expect(wipedUsage.entryCount == 0)
        #expect(wipedUsage.photoCount == 0)
        #expect(wipedUsage.photoBytes == 0)
        #expect(photos.refs.isEmpty)
    }
}
