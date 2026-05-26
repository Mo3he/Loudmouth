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
        let inFormat  = audioFile.processingFormat

        // Normalize to 44.1 kHz Float32 stereo before feeding ShazamKit.
        // Appending the file's native format in chunks produces SHError 101
        // (frame-position vs sample-time mismatch) on recent iOS releases when
        // AVAudioFile.read returns slightly fewer frames than requested. A
        // single, converted, well-formed buffer with `at: nil` sidesteps both
        // 101 (discontinuity) and 201 (signature duration invalid).
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ) else { throw RecognitionError.audioReadFailed }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecognitionError.audioReadFailed
        }

        // 12 seconds of source audio — comfortably inside Shazam's accepted
        // signature duration range (~3 s min, ~30 s max).
        let inFramesWanted = AVAudioFrameCount(min(inFormat.sampleRate * 12,
                                                   Double(audioFile.length)))
        guard inFramesWanted > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFramesWanted)
        else { throw RecognitionError.audioReadFailed }
        try audioFile.read(into: inBuffer, frameCount: inFramesWanted)
        guard inBuffer.frameLength > 0 else { throw RecognitionError.audioReadFailed }

        let rateRatio = outFormat.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuffer.frameLength) * rateRatio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
            throw RecognitionError.audioReadFailed
        }

        // AVAudioConverter calls the input block synchronously on the calling
        // thread, so the buffer never actually crosses an isolation boundary
        // despite the @Sendable annotation on the closure.
        nonisolated(unsafe) let inBufferCapture = inBuffer
        var fed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBufferCapture
        }
        if let convError { throw convError }
        guard outBuffer.frameLength > 0 else { throw RecognitionError.audioReadFailed }

        let generator = SHSignatureGenerator()
        try generator.append(outBuffer, at: nil)
        return generator.signature()
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
