import SwiftUI
import UniformTypeIdentifiers
import CatchTallyKit

/// Settings + data ownership controls (issue #6).
///
/// Covers:
/// - local-storage/privacy disclosure (zero network by construction)
/// - storage usage meter + record counts
/// - full ZIP backup export and restore
/// - CSV preview/export
/// - destructive full-data wipe confirmation
struct SettingsView: View {
    @Bindable var model: TallyModel

    @Environment(\.dismiss) private var dismiss

    @State private var usage: StorageUsage?
    @State private var isLoadingUsage = false

    @State private var backupDocument: BackupZipDocument?
    @State private var backupFilename = "catchtally-backup.zip"
    @State private var showBackupExporter = false

    @State private var showRestoreImporter = false

    @State private var csvPreview: CSVPreviewPayload?

    @State private var showDeleteConfirmation = false

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                privacySection
                storageSection
                backupSection
                csvSection
                dangerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refreshUsage() }
            .fileExporter(
                isPresented: $showBackupExporter,
                document: backupDocument,
                contentType: .zip,
                defaultFilename: backupFilename
            ) { result in
                switch result {
                case .success:
                    alertMessage = "Backup exported."
                case let .failure(error):
                    alertMessage = "Backup export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showRestoreImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                handleRestoreSelection(result)
            }
            .sheet(item: $csvPreview) { payload in
                CSVPreviewSheet(payload: payload)
            }
            .confirmationDialog(
                "Delete all local data?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permanently removes all species, spots, sessions, catch entries, and stored photos from this device. This cannot be undone.")
            }
            .alert(
                "Data Ownership",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy & Data Ownership") {
            Text(
                "All catches, spots, notes, and attached photos are stored locally on this device. Catch Tally does not use network APIs by design.")
                .font(.subheadline)

            LabeledContent("Stored Data") {
                Text("Species, spots, sessions, catch entries, and app-private photo copies")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Permissions") {
                Text("Photo picker access only; no photo-library write-back")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Network") {
                Text("Disabled by construction (zero network)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storageSection: some View {
        Section("Storage Usage") {
            if isLoadingUsage {
                ProgressView("Measuring local storage…")
            } else if let usage {
                let total = max(usage.totalBytes, 1)
                let photoFraction = Double(usage.photoBytes) / Double(total)
                ProgressView(value: photoFraction) {
                    Text("Photo share of total storage")
                } currentValueLabel: {
                    Text(Self.formatBytes(usage.photoBytes))
                }

                LabeledContent("Database") { Text(Self.formatBytes(usage.databaseBytes)) }
                LabeledContent("Photos") { Text(Self.formatBytes(usage.photoBytes)) }
                LabeledContent("Total") { Text(Self.formatBytes(usage.totalBytes)).bold() }

                LabeledContent("Species") { Text("\(usage.speciesCount)") }
                LabeledContent("Spots") { Text("\(usage.spotCount)") }
                LabeledContent("Sessions") { Text("\(usage.sessionCount)") }
                LabeledContent("Catch Entries") { Text("\(usage.entryCount)") }
                LabeledContent("Photos") { Text("\(usage.photoCount)") }

                Button("Refresh Usage") {
                    Task { await refreshUsage() }
                }
            } else {
                Text("No storage metrics available.")
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await refreshUsage() } }
            }
        }
    }

    private var backupSection: some View {
        Section("Backup & Restore") {
            Button("Export Full Backup (.zip)…") {
                exportBackup()
            }
            .accessibilityIdentifier("settings-export-backup")

            Button("Restore From Backup (.zip)…", role: .none) {
                showRestoreImporter = true
            }
            .accessibilityIdentifier("settings-restore-backup")

            Text(
                "Backups include schema/app version metadata plus all species, spots, sessions, entries, and copied photo binaries.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var csvSection: some View {
        Section("CSV Export") {
            Button("Preview Catch CSV…") {
                previewCSV()
            }
            .accessibilityIdentifier("settings-preview-csv")

            Text(
                "Preview before sharing. Columns: date, species, length, unit, keep/release, spot, session note, entry note.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dangerSection: some View {
        Section("Danger Zone") {
            Button("Delete All Data", role: .destructive) {
                showDeleteConfirmation = true
            }
            .accessibilityIdentifier("settings-delete-all-data")
        }
    }

    private func exportBackup() {
        do {
            let data = try model.makeBackupData()
            backupDocument = BackupZipDocument(data: data)
            backupFilename = "catchtally-backup-\(Self.fileStampDate()).zip"
            showBackupExporter = true
        } catch {
            alertMessage = "Backup export failed: \(error.localizedDescription)"
        }
    }

    private func handleRestoreSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            try model.restoreBackup(from: data)
            alertMessage = "Backup restored successfully."
            Task { await refreshUsage() }
        } catch {
            alertMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func previewCSV() {
        do {
            let csv = try model.makeCSV()
            csvPreview = CSVPreviewPayload(
                csv: csv,
                filename: "catchtally-catches-\(Self.fileStampDate()).csv")
        } catch {
            alertMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func deleteAllData() {
        do {
            try model.deleteAllData()
            alertMessage = "All local data deleted."
            Task { await refreshUsage() }
        } catch {
            alertMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func refreshUsage() async {
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            usage = try model.storageUsage()
        } catch {
            usage = nil
            alertMessage = "Could not load storage usage: \(error.localizedDescription)"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private static func fileStampDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

private struct CSVPreviewPayload: Identifiable {
    let id = UUID()
    let csv: String
    let filename: String
}

private struct CSVPreviewSheet: View {
    let payload: CSVPreviewPayload

    @Environment(\.dismiss) private var dismiss

    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.csv)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("CSV Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save / Share") { showExporter = true }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: CSVDocument(text: payload.csv),
                contentType: .commaSeparatedText,
                defaultFilename: payload.filename
            ) { _ in }
        }
    }
}

private struct BackupZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let content = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = content
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let content = configuration.file.regularFileContents,
              let text = String(data: content, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
