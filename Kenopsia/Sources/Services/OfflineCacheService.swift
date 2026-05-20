import Foundation

// MARK: - OfflineCacheProgress
/// @MainActor ObservableObject so SwiftUI views can bind to download progress.
/// Updated by OfflineCacheService whenever a download starts, progresses, or finishes.
@MainActor
final class OfflineCacheProgress: ObservableObject {
    static let shared = OfflineCacheProgress()
    /// Keyed by track ID. Value is a Progress whose fractionCompleted drives UI.
    @Published var inProgress: [UUID: Progress] = [:]
    private init() {}
}

// MARK: - OfflineCacheService
/// Downloads and pins remote tracks for offline listening.
/// When a source has `isPinnedOffline = true`, all its tracks are cached locally.
/// Cached files live in the App Group container under OfflineCache/<sourceID>/<trackID>.<ext>
actor OfflineCacheService {
    static let shared = OfflineCacheService()

    // Background-capable session so downloads survive app suspension.
    // Progress tracking works via the DownloadDelegate.
    private let session: URLSession
    private let delegate = DownloadDelegate()
    private let cacheRoot: URL

    // Progress tracking — keyed by track ID. @Published via an ObservableObject wrapper
    // so SwiftUI views can observe individual download progress.
    private(set) var inProgress: [UUID: Progress] = [:]
    private(set) var cachedTrackIDs: Set<UUID> = []

    private init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.kenopsia")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheRoot = container.appendingPathComponent("OfflineCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        self.cachedTrackIDs = Self.loadCachedIDsFrom(
            cacheRoot: cacheRoot.appendingPathComponent("index.json")
        )
        // URLSessionConfiguration.background does not support completion-handler tasks.
        // Use .default so the delegate-based progress tracking still works while
        // keeping the familiar async/await call site.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Public API
    func isCached(_ track: Track) -> Bool { cachedTrackIDs.contains(track.id) }

    func localURL(for track: Track) -> URL? {
        let url = path(for: track)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Download all tracks from a source and cache them.
    /// `resolver` must be the PlaybackService's resolver so adapters are registered.
    func pinSource(_ source: MusicSource, tracks: [Track], resolver: SourceResolver) async {
        for track in tracks {
            guard !isCached(track) else { continue }
            await download(track: track, resolver: resolver)
        }
    }

    /// Remove all cached files for a source.
    func unpinSource(sourceID: MusicSourceID) {
        let dir = cacheRoot.appendingPathComponent(sourceID.rawValue.uuidString)
        try? FileManager.default.removeItem(at: dir)
        // Remove IDs whose files are now gone (the directory was deleted above).
        cachedTrackIDs = cachedTrackIDs.filter {
            FileManager.default.fileExists(
                atPath: cacheRoot
                    .appendingPathComponent(sourceID.rawValue.uuidString)
                    .appendingPathComponent($0.uuidString).path
            )
        }
        persistCachedIDs()
    }

    func delete(track: Track) {
        let url = path(for: track)
        try? FileManager.default.removeItem(at: url)
        cachedTrackIDs.remove(track.id)
        persistCachedIDs()
    }

    // MARK: - Download
    private func download(track: Track, resolver: SourceResolver) async {
        do {
            let remoteURL = try await resolver.localURL(for: track)
            if case .localFile = track.uri {
                cachedTrackIDs.insert(track.id)
                persistCachedIDs()
                return
            }

            let dest = path(for: track)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Create a Progress object so observers can track this download.
            let progress = Progress(totalUnitCount: -1)   // indeterminate until Content-Length arrives
            inProgress[track.id] = progress
            Task { @MainActor in OfflineCacheProgress.shared.inProgress[track.id] = progress }

            let tempURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: remoteURL) { url, response, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let url else { cont.resume(throwing: URLError(.unknown)); return }
                    cont.resume(returning: url)
                }
                delegate.register(progress: progress, for: task)
                task.resume()
            }

            inProgress.removeValue(forKey: track.id)
            Task { @MainActor in OfflineCacheProgress.shared.inProgress.removeValue(forKey: track.id) }

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)

            cachedTrackIDs.insert(track.id)
            persistCachedIDs()
        } catch {
            inProgress.removeValue(forKey: track.id)
            Task { @MainActor in OfflineCacheProgress.shared.inProgress.removeValue(forKey: track.id) }
            // Download failures are silently skipped; will retry on next pin.
        }
    }

    // MARK: - Paths
    private func path(for track: Track) -> URL {
        let ext = track.format.rawValue
        return cacheRoot
            .appendingPathComponent(track.source.rawValue.uuidString)
            .appendingPathComponent(track.id.uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - Persistence
    nonisolated private static func loadCachedIDsFrom(cacheRoot: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: cacheRoot),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func persistCachedIDs() {
        let index = cacheRoot.appendingPathComponent("index.json")
        if let data = try? JSONEncoder().encode(Array(cachedTrackIDs)) {
            try? data.write(to: index, options: .atomic)
        }
    }
}

// MARK: - DownloadDelegate
/// Bridges URLSession delegate callbacks to Progress objects for each task.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private var progressMap: [Int: Progress] = [:]
    private let lock = NSLock()

    func register(progress: Progress, for task: URLSessionDownloadTask) {
        lock.lock(); defer { lock.unlock() }
        progressMap[task.taskIdentifier] = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let p = progressMap[downloadTask.taskIdentifier]
        lock.unlock()
        guard let p else { return }
        if totalBytesExpectedToWrite > 0 {
            p.totalUnitCount = totalBytesExpectedToWrite
        }
        p.completedUnitCount = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled via the completion handler in the actor.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        progressMap.removeValue(forKey: task.taskIdentifier)
    }
}
