import Foundation

/// The core model for a single audio track, regardless of source.
/// All source adapters produce `Track` values that the player consumes uniformly.
struct Track: Identifiable, Hashable, Codable {
    let id: UUID

    // MARK: - Core metadata
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var composer: String
    var comment: String

    // MARK: - File / stream info
    var source: MusicSourceID   // which source this track comes from
    var uri: TrackURI           // opaque location (file path, stream URL, subsonic ID, etc.)
    var format: AudioFormat
    var durationSeconds: Double
    var fileSizeBytes: Int?
    var bitrateBps: Int?
    var sampleRateHz: Int?
    var bitDepth: Int?
    var channelCount: Int?
    var isLossless: Bool { format.isLossless }

    // MARK: - Artwork
    var artworkCacheKey: String?    // keyed into ArtworkCache; nil = not yet resolved

    // MARK: - ReplayGain
    var replayGainTrack: Float?     // dB, e.g. -3.2
    var replayGainAlbum: Float?

    // MARK: - Stats
    var playCount: Int
    var lastPlayedAt: Date?
    var dateAdded: Date

    // MARK: - Smart playlist helpers
    var isFavourited: Bool
    var isExplicit: Bool
    var bpm: Double?
    var acoustID: String?           // AcoustID fingerprint match
    /// Star rating 0-5. 0 = unrated.
    var rating: Int

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "",
        albumArtist: String = "",
        album: String = "",
        genre: String = "",
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        composer: String = "",
        comment: String = "",
        source: MusicSourceID,
        uri: TrackURI,
        format: AudioFormat,
        durationSeconds: Double,
        fileSizeBytes: Int? = nil,
        bitrateBps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        artworkCacheKey: String? = nil,
        replayGainTrack: Float? = nil,
        replayGainAlbum: Float? = nil,
        playCount: Int = 0,
        lastPlayedAt: Date? = nil,
        dateAdded: Date = .now,
        isFavourited: Bool = false,
        isExplicit: Bool = false,
        bpm: Double? = nil,
        acoustID: String? = nil,
        rating: Int = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.composer = composer
        self.comment = comment
        self.source = source
        self.uri = uri
        self.format = format
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.bitrateBps = bitrateBps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.artworkCacheKey = artworkCacheKey
        self.replayGainTrack = replayGainTrack
        self.replayGainAlbum = replayGainAlbum
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.dateAdded = dateAdded
        self.isFavourited = isFavourited
        self.isExplicit = isExplicit
        self.bpm = bpm
        self.acoustID = acoustID
        self.rating = rating
    }
}

// MARK: - TrackURI
/// Opaque location of a track. Each source type uses a different backing value.
enum TrackURI: Hashable, Codable {
    case localFile(path: String)
    case remoteURL(url: URL)
    case subsonicID(serverID: UUID, trackID: String)
    case dlnaURL(url: URL)
    case webRadio(streamURL: URL)
    case cloudFile(provider: CloudProvider, fileID: String)
    /// A track from the user's Apple Music library or the Apple Music catalogue,
    /// identified by its MusicItemID (a stable string from MusicKit).
    case appleMusicID(id: String)

    /// A stable string key that uniquely identifies the track's location,
    /// used for deduplication across rescans.
    var stableKey: String {
        switch self {
        case .localFile(let path):
            // Resolve symlinks so /var/... and /private/var/... (same on iOS/macOS)
            // always produce the same key, preventing duplicates across rescans.
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return "local:\(canonical)"
        case .remoteURL(let url):                      return "remote:\(url.absoluteString)"
        case .subsonicID(let sid, let tid):            return "subsonic:\(sid):\(tid)"
        case .dlnaURL(let url):                        return "dlna:\(url.absoluteString)"
        case .webRadio(let url):                       return "radio:\(url.absoluteString)"
        case .cloudFile(let provider, let fileID):     return "cloud:\(provider.rawValue):\(fileID)"
        case .appleMusicID(let id):                    return "applemusic:\(id)"
        }
    }
}

// MARK: - AudioFormat
enum AudioFormat: String, Codable, CaseIterable {
    // Lossless
    case flac, alac, dsd, wav, aiff, ape, wavpack
    // Lossy
    case mp3, aac, m4a, ogg, opus, wma, mpc, mp4

    var isLossless: Bool {
        switch self {
        case .flac, .alac, .dsd, .wav, .aiff, .ape, .wavpack: true
        case .mp3, .aac, .m4a, .ogg, .opus, .wma, .mpc, .mp4: false
        }
    }

    var displayName: String { rawValue.uppercased() }

    /// Common file extension for this format (used when creating temp files).
    var fileExtension: String {
        switch self {
        case .alac: "m4a"
        case .aiff: "aiff"
        case .wavpack: "wv"
        default: rawValue
        }
    }

    /// MIME type for use in HTTP Content-Type headers (e.g. when serving to Chromecast).
    var mimeType: String {
        switch self {
        case .mp3:     "audio/mpeg"
        case .aac:     "audio/aac"
        case .m4a:     "audio/mp4"
        case .alac:    "audio/mp4"
        case .flac:    "audio/flac"
        case .wav:     "audio/wav"
        case .aiff:    "audio/aiff"
        case .ogg:     "audio/ogg"
        case .opus:    "audio/opus"
        case .wma:     "audio/x-ms-wma"
        case .mpc:     "audio/musepack"
        case .ape:     "audio/ape"
        case .wavpack: "audio/x-wavpack"
        case .dsd:     "audio/dsd"
        case .mp4:     "video/mp4"
        }
    }
}

// MARK: - CloudProvider
enum CloudProvider: String, Codable {
    case iCloud, backblaze

    var displayName: String {
        switch self {
        case .iCloud:    "iCloud Drive"
        case .backblaze: "Backblaze B2"
        }
    }
}
