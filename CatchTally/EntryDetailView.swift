import SwiftUI
import PhotosUI
import CatchTallyKit

/// Per-entry detail editor (issue #4): length + unit, keep/release,
/// optional app-private photo copy with a user-typed alt-text field for
/// VoiceOver, and notes. Full VoiceOver traversal: every control is a
/// real, labeled SwiftUI control inside a Form.
struct EntryDetailView: View {
    @Bindable var model: SessionWorkbenchModel
    let entry: CatchEntry
    let photoStore: any EntryPhotoStore

    @State private var lengthText: String = ""
    @State private var unit: LengthUnit = .inches
    @State private var hasLength: Bool = false
    @State private var disposition: Disposition = .kept
    @State private var notes: String = ""
    @State private var altText: String = ""

    @State private var pickerItem: PhotosPickerItem?
    @State private var importingPhoto = false

    var body: some View {
        Form {
            Section {
                Toggle("Length recorded", isOn: $hasLength)
                    .accessibilityIdentifier("has-length-toggle")
                if hasLength {
                    TextField("Length", text: $lengthText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Catch length")
                    Picker("Unit", selection: $unit) {
                        Text("inches").tag(LengthUnit.inches)
                        Text("centimeters").tag(LengthUnit.centimeters)
                    }
                    .accessibilityIdentifier("length-unit")
                }
            } header: {
                Text(model.speciesName(for: entry))
            } footer: {
                if !hasLength {
                    Text("No length recorded stays unknown — never a zero.")
                }
            }

            Section("Disposition") {
                Picker("Kept or released", selection: $disposition) {
                    Text("Kept").tag(Disposition.kept)
                    Text("Released").tag(Disposition.released)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("detail-disposition")
            }

            Section {
                photoSection
            } header: {
                Text("Photo")
            } footer: {
                Text("The app stores its own downscaled copy privately — your photo library is never modified, and the app never touches the network.")
            }

            Section("Notes") {
                    TextField("Entry notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityLabel("Entry notes")
            }

            Section {
                Button("Save entry") { save() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("save-entry")
            }
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear { load(entry) }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
    }

    // MARK: - Photo surface (optional, one copy per entry)

    @ViewBuilder
    private var photoSection: some View {
        if entry.photoRef != nil {
            if let data = model.photoData(for: entry), let image = PlatformImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .accessibilityLabel(entry.photoAltText ?? "Entry photo, no description yet")
            }
            TextField("Describe this photo for VoiceOver", text: $altText, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityLabel("Photo description")
                .onSubmit { saveAltText() }
            Button("Remove photo", role: .destructive) {
                if let id = entry.id {
                    model.removePhoto(entryId: id)
                    altText = ""
                }
            }
            .accessibilityIdentifier("remove-photo")
        } else {
            // Permission is requested by the system only when the user
            // first picks — the picker is fully optional otherwise.
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Add photo (optional)", systemImage: "camera")
            }
            .disabled(importingPhoto)
            .accessibilityIdentifier("add-photo")
            if importingPhoto {
                ProgressView("Saving private copy…")
            }
        }
    }

    // MARK: - Load / save

    private func load(_ entry: CatchEntry) {
        hasLength = entry.hasLength
        lengthText = entry.length.map {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        } ?? ""
        unit = entry.lengthUnit ?? .inches
        disposition = entry.disposition
        notes = entry.notes ?? ""
        altText = entry.photoAltText ?? ""
    }

    private func save() {
        guard let id = entry.id else { return }
        let parsedLength: Double? = hasLength ? Double(lengthText) : nil
        // A visible-but-unparseable length field must not silently become
        // "unknown" — surface it instead (unknown is a user choice, not a
        // coercion).
        if hasLength, parsedLength == nil {
            model.lastErrorMessage = "Enter a number for the length, or switch 'Length recorded' off."
            return
        }
        // Persist alt text BEFORE the detail write so one Save covers both.
        if entry.photoRef != nil, altText != (entry.photoAltText ?? "") {
            saveAltText(silentRefresh: true)
        }
        model.saveDetail(
            entryId: id,
            length: parsedLength,
            unit: parsedLength == nil ? nil : unit,
            disposition: disposition,
            notes: notes)
    }

    private func saveAltText(silentRefresh: Bool = false) {
        guard let id = entry.id else { return }
        model.setPhotoAltText(entryId: id, altText: altText)
        _ = silentRefresh
    }

    /// Picker hands over full-res data; we build our own downscaled JPEG
    /// copy. The library item itself is never written back or modified.
    private func importPhoto(_ item: PhotosPickerItem) {
        importingPhoto = true
        Task {
            defer { importingPhoto = false }
            guard let raw = try? await item.loadTransferable(type: Data.self) else {
                model.lastErrorMessage = "Couldn't load the picked photo."
                pickerItem = nil
                return
            }
            guard let jpeg = PhotoProcessing.downscaledJPEG(from: raw) else {
                model.lastErrorMessage = "That file isn't a readable image."
                pickerItem = nil
                return
            }
            if let id = entry.id {
                model.attachPhoto(entryId: id, jpegData: jpeg, altText: altText)
            }
            pickerItem = nil
        }
    }
}

/// Minimal platform-image shim so this file compiles on non-UIKit hosts
/// (the view itself only ever runs on iOS; Linux CI compiles the package,
/// never the app target — this keeps the shim honest and tiny).
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
final class PlatformImage {
    init?(_ data: Data) { _ = data }
}
#endif
