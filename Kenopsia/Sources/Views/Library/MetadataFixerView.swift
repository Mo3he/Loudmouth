import SwiftUI

// MARK: - MetadataFixerView
/// Scans the library for local tracks with incomplete metadata and lets the
/// user identify them automatically via ShazamKit.
struct MetadataFixerView: View {
    @EnvironmentObject var library: LibraryViewModel

    @State private var problems: [MetadataProblem] = []
    @State private var isScanning  = false
    @State private var isFixingAll = false
    @State private var fixProgress: Double = 0

    private let writer = TagWriter()

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    ProgressView("Scanning library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if problems.isEmpty {
                    ContentUnavailableView(
                        "All Good",
                        systemImage: "checkmark.seal.fill",
                        description: Text("Every local track has artist and album tags.")
                    )
                } else {
                    problemList
                }
            }
            .navigationTitle("Metadata Fixer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Scan") { Task { await scan() } }
                        .disabled(isScanning || isFixingAll)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fix All") { Task { await fixAll() } }
                        .disabled(problems.isEmpty || isFixingAll)
                }
            }
            .overlay(alignment: .bottom) {
                if isFixingAll {
                    VStack(spacing: 8) {
                        ProgressView(value: fixProgress)
                        Text("Identifying… \(Int(fixProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .task { await scan() }
        }
    }

    // MARK: - Problem list

    private var problemList: some View {
        List(problems) { problem in
            MetadataProblemRow(problem: problem)
                .swipeActions(edge: .trailing) {
                    Button("Identify") {
                        Task { await identify(id: problem.id) }
                    }
                    .tint(.indigo)
                }
        }
    }

    // MARK: - Scanning

    private func scan() async {
        isScanning = true
        // LibraryStore is @MainActor; access directly since View is @MainActor.
        let allTracks = Array(LibraryStore.shared.tracks.values)
        problems = allTracks.filter { track in
            guard case .localFile = track.uri else { return false }
            return track.artist.isEmpty || track.album.isEmpty
        }.map { MetadataProblem(track: $0) }
        isScanning = false
    }

    // MARK: - Fix actions

    /// Identify a single problem by ID. Uses index lookup to avoid inout-across-await.
    private func identify(id: UUID) async {
        guard let idx = problems.firstIndex(where: { $0.id == id }),
              case .localFile(let path) = problems[idx].track.uri
        else { return }
        let track = problems[idx].track
        problems[idx].status = .identifying
        do {
            let meta = try await MusicRecognitionService.shared.recognize(
                localURL: URL(fileURLWithPath: path)
            )
            if let i = problems.firstIndex(where: { $0.id == id }) {
                problems[i].status = .found(meta)
            }
            await apply(meta: meta, to: track)
            if let i = problems.firstIndex(where: { $0.id == id }) {
                problems[i].status = .applied
            }
            // Brief pause so the user can see the result before the row disappears.
            try? await Task.sleep(nanoseconds: 800_000_000)
            problems.removeAll { $0.id == id }
        } catch MusicRecognitionService.RecognitionError.noMatch {
            if let i = problems.firstIndex(where: { $0.id == id }) {
                problems[i].status = .notFound
            }
        } catch {
            if let i = problems.firstIndex(where: { $0.id == id }) {
                problems[i].status = .error(error.localizedDescription)
            }
        }
    }

    private func fixAll() async {
        isFixingAll = true
        // Snapshot IDs so we iterate only over the original set.
        let ids = problems.map { $0.id }
        for (i, id) in ids.enumerated() {
            fixProgress = Double(i) / Double(ids.count)
            await identify(id: id)
        }
        fixProgress = 1
        isFixingAll = false
    }

    // MARK: - Apply metadata

    private func apply(meta: MusicRecognitionService.RecognizedMetadata, to track: Track) async {
        var updated = track
        if let v = meta.title,  !v.isEmpty, updated.title.isEmpty  { updated.title  = v }
        if let v = meta.artist, !v.isEmpty, updated.artist.isEmpty  { updated.artist = v; updated.albumArtist = v }
        if let v = meta.album,  !v.isEmpty, updated.album.isEmpty   { updated.album  = v }
        if let v = meta.genre,  !v.isEmpty, updated.genre.isEmpty   { updated.genre  = v }
        if let v = meta.year,   updated.year == nil                  { updated.year   = v }

        // Cache artwork if a URL was provided.
        if let artURL = meta.artworkURL, let key = updated.artworkCacheKey ?? track.artworkCacheKey {
            Task.detached(priority: .utility) {
                guard !ArtworkCache.shared.hasArtwork(forKey: key),
                      let (data, response) = try? await URLSession.shared.data(from: artURL),
                      (response as? HTTPURLResponse)?.statusCode == 200
                else { return }
                ArtworkCache.shared.store(imageData: data, forKey: key)
            }
        }

        // Write tags back to the file for local tracks.
        if case .localFile(let path) = track.uri {
            var tags = TrackTags(track: updated)
            tags.title       = updated.title
            tags.artist      = updated.artist
            tags.albumArtist = updated.albumArtist
            tags.album       = updated.album
            tags.genre       = updated.genre
            tags.year        = updated.year
            _ = try? await writer.write(tags: tags, to: URL(fileURLWithPath: path))
        }

        await MainActor.run { library.update(track: updated) }
    }
}

// MARK: - MetadataProblem

struct MetadataProblem: Identifiable {
    var id: UUID { track.id }
    let track: Track
    var status: Status = .pending

    enum Status {
        case pending
        case identifying
        case found(MusicRecognitionService.RecognizedMetadata)
        case applied
        case notFound
        case error(String)
    }

    var missingFields: String {
        var missing: [String] = []
        if track.artist.isEmpty { missing.append("artist") }
        if track.album.isEmpty  { missing.append("album")  }
        if track.genre.isEmpty  { missing.append("genre")  }
        if track.year == nil    { missing.append("year")   }
        return missing.isEmpty ? "incomplete" : missing.joined(separator: ", ")
    }
}

// MARK: - MetadataProblemRow

private struct MetadataProblemRow: View {
    let problem: MetadataProblem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.track.title.isEmpty ? problem.track.uri.displayName : problem.track.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                statusLine
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch problem.status {
        case .pending:
            Text("Missing: \(problem.missingFields)")
                .font(.caption).foregroundStyle(.secondary)
        case .identifying:
            Label("Identifying…", systemImage: "waveform.and.magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
        case .found(let meta):
            Text("\(meta.artist ?? "—") · \(meta.album ?? "—")")
                .font(.caption).foregroundStyle(.green)
        case .applied:
            Text("Applied")
                .font(.caption).foregroundStyle(.green)
        case .notFound:
            Text("Not recognised")
                .font(.caption).foregroundStyle(.orange)
        case .error(let msg):
            Text(msg)
                .font(.caption).foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch problem.status {
        case .identifying:
            ProgressView().scaleEffect(0.8)
        case .found, .applied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notFound:
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .pending:
            EmptyView()
        }
    }
}

// MARK: - TrackURI display helper

private extension TrackURI {
    var displayName: String {
        if case .localFile(let path) = self {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return "Unknown"
    }
}
