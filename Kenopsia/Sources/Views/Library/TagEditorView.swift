import SwiftUI
import PhotosUI

// MARK: - TagEditorView
/// Inline tag editor. Opened from the track context menu or swipe action.
/// Writes back to the file on Save using TagWriter.
struct TagEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var library: LibraryViewModel

    let track: Track
    @State private var tags: TrackTags
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var artworkPhotoItem: PhotosPickerItem?
    @State private var pendingArtworkData: Data?
    @State private var isIdentifying = false
    @State private var identifyError: String?
    @State private var identifyMessage: String?

    private let writer = TagWriter()

    init(track: Track) {
        self.track = track
        _tags = State(initialValue: TrackTags(track: track))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Track Info") {
                    LabeledTextField("Title",       text: bindStr(\.title))
                    LabeledTextField("Artist",      text: bindStr(\.artist))
                    LabeledTextField("Album Artist",text: bindStr(\.albumArtist))
                    LabeledTextField("Album",       text: bindStr(\.album))
                    LabeledTextField("Composer",    text: bindStr(\.composer))
                    LabeledTextField("Genre",       text: bindStr(\.genre))
                    LabeledTextField("Comment",     text: bindStr(\.comment))
                }

                Section("Numbers") {
                    LabeledIntField("Year",         value: $tags.year)
                    LabeledIntField("Track Number", value: $tags.trackNumber)
                    LabeledIntField("Disc Number",  value: $tags.discNumber)
                }

                Section("Artwork") {
                    artworkRow
                }

                Section("File Info") {
                    LabeledContent("Format",   value: track.format.displayName)
                    LabeledContent("Source",   value: sourceLabel)
                    if let rate = track.sampleRateHz { LabeledContent("Sample Rate", value: "\(rate) Hz") }
                    if let bits = track.bitDepth     { LabeledContent("Bit Depth",   value: "\(bits)-bit") }
                    if let bps  = track.bitrateBps   { LabeledContent("Bitrate",     value: "\(bps / 1000) kbps") }
                }

                if case .localFile = track.uri {
                    Section("Auto-Identify") {
                        Button {
                            autoIdentify()
                        } label: {
                            if isIdentifying {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Identifying…").foregroundStyle(.secondary)
                                }
                            } else {
                                Label("Identify Track", systemImage: "waveform.and.magnifyingglass")
                            }
                        }
                        .disabled(isIdentifying)
                        if let err = identifyError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        if let msg = identifyMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let err = saveError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                        .bold()
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Artwork row
    private var artworkRow: some View {
        HStack(spacing: 16) {
            // Current / pending artwork preview
            Group {
                if let data = pendingArtworkData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                } else if !tags.removeArtwork,
                          let key = track.artworkCacheKey,
                          let img = ArtworkCache.shared.gridImage(forKey: key) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay { Image(systemName: "music.note").foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $artworkPhotoItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo")
                }
                .onChange(of: artworkPhotoItem) { loadArtworkPhoto() }

                Button(role: .destructive) {
                    pendingArtworkData = nil
                    tags.artworkData = nil
                    tags.removeArtwork = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(pendingArtworkData == nil && track.artworkCacheKey == nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Save
    private func save() {
        guard case .localFile(let path) = track.uri else {
            saveError = "Can only edit tags on local files."
            return
        }
        isSaving = true
        saveError = nil
        let url = URL(fileURLWithPath: path)
        var finalTags = tags
        finalTags.artworkData = pendingArtworkData ?? tags.artworkData
        // If removeArtwork was requested but new artwork was then picked, cancel the removal.
        if pendingArtworkData != nil { finalTags.removeArtwork = false }

        Task {
            do {
                try await writer.write(tags: finalTags, to: url)
                // Update the store with new tag values
                var updated = track
                updated.title       = finalTags.title       ?? track.title
                updated.artist      = finalTags.artist      ?? track.artist
                updated.albumArtist = finalTags.albumArtist ?? track.albumArtist
                updated.album       = finalTags.album       ?? track.album
                updated.genre       = finalTags.genre       ?? track.genre
                updated.year        = finalTags.year        ?? track.year
                updated.trackNumber = finalTags.trackNumber ?? track.trackNumber
                updated.discNumber  = finalTags.discNumber  ?? track.discNumber
                updated.composer    = finalTags.composer    ?? track.composer
                updated.comment     = finalTags.comment     ?? track.comment
                if finalTags.removeArtwork, let key = updated.artworkCacheKey {
                    ArtworkCache.shared.remove(forKey: key)
                    updated.artworkCacheKey = nil
                }
                await MainActor.run {
                    library.update(track: updated)
                    isSaving = false
                    dismiss()
                }
            } catch TagWriteError.unsupportedFormat {
                await MainActor.run {
                    saveError = "Tag editing is not supported for \(track.format.displayName) files."
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private func autoIdentify() {
        guard case .localFile(let path) = track.uri else { return }
        isIdentifying = true
        identifyError = nil
        identifyMessage = nil
        Task {
            do {
                let meta = try await MusicRecognitionService.shared.recognize(
                    localURL: URL(fileURLWithPath: path)
                )
                // Fill only empty / nil fields so existing tags are not overwritten,
                // and tally what we changed so the user gets visible feedback even
                // when every field was already populated.
                var filled: [String] = []
                if let v = meta.title,  !v.isEmpty, (tags.title  ?? "").isEmpty {
                    tags.title = v; filled.append("title")
                }
                if let v = meta.artist, !v.isEmpty, (tags.artist ?? "").isEmpty {
                    tags.artist = v; filled.append("artist")
                    if (tags.albumArtist ?? "").isEmpty { tags.albumArtist = v }
                }
                if let v = meta.album,  !v.isEmpty, (tags.album  ?? "").isEmpty {
                    tags.album = v; filled.append("album")
                }
                if let v = meta.genre,  !v.isEmpty, (tags.genre  ?? "").isEmpty {
                    tags.genre = v; filled.append("genre")
                }
                if let v = meta.year, tags.year == nil {
                    tags.year = v; filled.append("year")
                }

                let identifiedAs = [meta.artist, meta.title]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " – ")
                if filled.isEmpty {
                    identifyMessage = identifiedAs.isEmpty
                        ? "Identified — no new fields to fill."
                        : "Identified as \(identifiedAs). All fields already match."
                } else {
                    let prefix = identifiedAs.isEmpty ? "" : "\(identifiedAs) — "
                    identifyMessage = "\(prefix)filled \(filled.joined(separator: ", "))."
                }
            } catch {
                identifyError = error.localizedDescription
            }
            isIdentifying = false
        }
    }

    private func loadArtworkPhoto() {
        guard let item = artworkPhotoItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await MainActor.run { pendingArtworkData = data }
            }
        }
    }

    // MARK: - Binding helpers
    private func bindStr(_ keyPath: WritableKeyPath<TrackTags, String?>) -> Binding<String> {
        Binding(
            get: { tags[keyPath: keyPath] ?? "" },
            set: { tags[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var sourceLabel: String {
        switch track.uri {
        case .localFile:      "Local File"
        case .remoteURL:      "Remote URL"
        case .subsonicID:     "Subsonic"
        case .dlnaURL:        "DLNA / NAS"
        case .webRadio:       "Web Radio"
        case .cloudFile(let p, _): p.rawValue.capitalized
        case .appleMusicID:   "Apple Music"
        }
    }
}

// MARK: - Subviews
struct LabeledTextField: View {
    let label: String
    let text: Binding<String>
    init(_ label: String, text: Binding<String>) { self.label = label; self.text = text }
    var body: some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LabeledIntField: View {
    let label: String
    let value: Binding<Int?>
    init(_ label: String, value: Binding<Int?>) { self.label = label; self.value = value }
    var body: some View {
        LabeledContent(label) {
            TextField(label, text: Binding(
                get: { value.wrappedValue.map { "\($0)" } ?? "" },
                set: { value.wrappedValue = Int($0) }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }
    }
}
