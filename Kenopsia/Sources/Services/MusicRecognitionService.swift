import Foundation
import AVFoundation
import ShazamKit

// MARK: - MusicRecognitionService
/// Identifies local audio files via ShazamKit fingerprinting and enriches the
/// result with album / release-year data from the iTunes Search API.
/// Only local files can be fingerprinted — remote streams are not supported.
actor MusicRecognitionService {
    static let shared = MusicRecognitionService()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    // Active Shazam matchers, retained until their delegate callback fires.
    private var shazamMatchers: [UUID: ShazamMatcher] = [:]

    // MARK: - Public API

    struct RecognizedMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: Int?
        var artworkURL: URL?
    }

    enum RecognitionError: LocalizedError {
        case noMatch
        case unsupportedFormat
        case audioReadFailed

        var errorDescription: String? {
            switch self {
            case .noMatch:           return "Track not recognised — try a different section of the file."
            case .unsupportedFormat: return "This file type cannot be fingerprinted."
            case .audioReadFailed:   return "Could not read audio from this file."
            }
        }
    }

    /// Identify a local audio file and return the best available metadata.
    func recognize(localURL: URL) async throws -> RecognizedMetadata {
        guard AudioFormat(fileExtension: localURL.pathExtension) != nil else {
            throw RecognitionError.unsupportedFormat
        }
        let signature = try generateSignature(from: localURL)
        let item      = try await matchShazam(signature: signature)

        var meta = RecognizedMetadata(
            title:      item.title,
            artist:     item.artist,
            genre:      item.genres.first,
            artworkURL: item.artworkURL
        )

        // Enrich with iTunes Search for album name + release year.
        if let title = item.title, let artist = item.artist {
            if let extra = await fetchItunesMeta(artist: artist, title: title) {
                meta.album = extra.album
                meta.year  = extra.year
                if meta.genre == nil { meta.genre = extra.genre }
            }
        }
        return meta
    }

    // MARK: - Signature generation

    private func generateSignature(from url: URL) throws -> SHSignature {
        let audioFile = try AVAudioFile(forReading: url)
        let format    = audioFile.processingFormat
        let generator = SHSignatureGenerator()

        // Read up to 30 s — Shazam typically needs 5–12 s of audio.
        let maxFrames   = Int(format.sampleRate * 30)
        let totalFrames = min(Int(audioFile.length), maxFrames)
        var framesRead  = 0

        while framesRead < totalFrames {
            let toRead = AVAudioFrameCount(min(8192, totalFrames - framesRead))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
            try audioFile.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            let time = AVAudioTime(sampleTime: AVAudioFramePosition(framesRead),
                                   atRate: format.sampleRate)
            try generator.append(buffer, at: time)
            framesRead += Int(buffer.frameLength)
        }
        return try generator.signature()
    }

    // MARK: - ShazamKit matching

    private func matchShazam(signature: SHSignature) async throws -> SHMediaItem {
        let key     = UUID()
        let matcher = ShazamMatcher()
        shazamMatchers[key] = matcher
        defer { shazamMatchers.removeValue(forKey: key) }

        guard let item = try await matcher.match(signature) else {
            throw RecognitionError.noMatch
        }
        return item
    }

    // MARK: - iTunes enrichment

    private struct ItunesMeta { var album: String?; var genre: String?; var year: Int? }

    private func fetchItunesMeta(artist: String, title: String) async -> ItunesMeta? {
        let term = "\(artist) \(title)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=5")
        else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["results"] as? [[String: Any]],
              let best  = items.first
        else { return nil }

        var meta = ItunesMeta()
        meta.album = best["collectionName"] as? String
        meta.genre = best["primaryGenreName"] as? String
        if let dateStr = best["releaseDate"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate, .withDashSeparatorInDate]
            if let date = fmt.date(from: dateStr) {
                meta.year = Calendar.current.component(.year, from: date)
            }
        }
        return meta
    }
}

// MARK: - ShazamMatcher
/// Wraps SHSession + delegate into a single awaitable call.
/// The actor retains instances in shazamMatchers until the callback fires.
private final class ShazamMatcher: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let shSession = SHSession()
    private var continuation: CheckedContinuation<SHMediaItem?, Error>?

    override init() {
        super.init()
        shSession.delegate = self
    }

    func match(_ signature: SHSignature) async throws -> SHMediaItem? {
        try await withCheckedThrowingContinuation { [self] cont in
            continuation = cont
            shSession.match(signature)
        }
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        continuation?.resume(returning: match.mediaItems.first)
        continuation = nil
    }

    func session(_ session: SHSession,
                 didNotFindMatchFor signature: SHSignature,
                 error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else         { continuation?.resume(returning: nil) }
        continuation = nil
    }
}
