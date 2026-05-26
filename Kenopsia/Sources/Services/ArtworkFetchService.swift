import Foundation
import UIKit

// MARK: - ArtworkFetchService
/// Fetches album artwork from three sources in priority order:
///   1. MusicBrainz Cover Art Archive (free, no key required)
///   2. iTunes Search API (free, no key required)
///   3. Last.fm API (requires API key stored in UserDefaults)
///
/// Results are written to ArtworkCache. Never modifies audio files unless
/// the user explicitly triggers an embed operation.
actor ArtworkFetchService {
    static let shared = ArtworkFetchService()

    private let session: URLSession
    private let cache: ArtworkCache
    private let mbBaseURL  = URL(string: "https://musicbrainz.org/ws/2")!
    private let caaBaseURL = URL(string: "https://coverartarchive.org")!
    private let itunesURL  = URL(string: "https://itunes.apple.com/search")!
    private let lastfmURL  = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    private var inFlight = Set<String>()   // cache keys currently being fetched
    // MusicBrainz policy: max 1 req/sec. Track when the last request fired.
    private var lastMBRequestDate: Date = .distantPast

    private init(cache: ArtworkCache = .shared) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Kenopsia/1.0 (https://github.com/Mo3he)"]
        self.session = URLSession(configuration: config)
        self.cache = cache
    }

    // MARK: - Public API
    /// Fetch artwork for a track if not already cached. Fire-and-forget safe.
    /// Returns the cache key used (may differ from track.artworkCacheKey if generated).
    @discardableResult
    func fetchIfNeeded(for track: Track) async -> String? {
        let key = track.artworkCacheKey ?? Self.generateCacheKey(artist: track.artist, album: track.album)
        guard !key.isEmpty else { return nil }
        guard !cache.hasArtwork(forKey: key) else { return key }
        guard !inFlight.contains(key)        else { return key }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // DLNA tracks embed the artwork URL in the cache key ("dlna_art_<url>").
        // Download directly from the NAS rather than via MusicBrainz/iTunes/Last.fm.
        if key.hasPrefix("dlna_art_") {
            let urlStr = String(key.dropFirst("dlna_art_".count))
            if let artURL = URL(string: urlStr),
               let (data, response) = try? await session.data(from: artURL),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                cache.store(imageData: data, forKey: key)
                return key
            }
            // Fall through to online lookup if the direct URL fetch failed.
        }

        await fetch(artist: track.artist, album: track.album, cacheKey: key)
        return cache.hasArtwork(forKey: key) ? key : nil
    }

    /// Generate a stable cache key from artist + album when no embedded key exists.
    static func generateCacheKey(artist: String, album: String) -> String {
        let combined = "\(artist.lowercased()):\(album.lowercased())"
        return combined.data(using: .utf8)
            .map { Data($0).base64EncodedString() }
            ?? ""
    }

    /// Fetch album artwork by artist + album when the caller doesn't have a
    /// Track in hand (e.g. the library album grid cells). Idempotent and
    /// deduplicated via the inFlight set, so calling it for every visible cell
    /// on first appearance is safe.
    @discardableResult
    func fetchAlbumArtIfNeeded(artist: String, album: String) async -> String? {
        let key = Self.generateCacheKey(artist: artist, album: album)
        guard !key.isEmpty else { return nil }
        guard !cache.hasArtwork(forKey: key) else { return key }
        guard !inFlight.contains(key)        else { return key }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        await fetch(artist: artist, album: album, cacheKey: key)
        return cache.hasArtwork(forKey: key) ? key : nil
    }

    /// Fetch artwork for an album. Used by the bulk fixer and album detail view.
    func fetch(artist: String, album: String, cacheKey: String) async {
        // 1. MusicBrainz + Cover Art Archive
        if let data = await fetchFromMusicBrainz(artist: artist, album: album) {
            cache.store(imageData: data, forKey: cacheKey)
            return
        }
        // 2. iTunes Search
        if let data = await fetchFromItunes(artist: artist, album: album) {
            cache.store(imageData: data, forKey: cacheKey)
            return
        }
        // 3. Last.fm
        if let data = await fetchFromLastFm(artist: artist, album: album) {
            cache.store(imageData: data, forKey: cacheKey)
        }
    }

    // MARK: - MusicBrainz / Cover Art Archive
    /// Step 1: find the release MBID via MusicBrainz search.
    /// Step 2: fetch the front cover from Cover Art Archive.
    private func fetchFromMusicBrainz(artist: String, album: String) async -> Data? {
        guard !artist.isEmpty, !album.isEmpty else { return nil }

        // Enforce MusicBrainz rate limit: 1 request per second.
        let elapsed = Date().timeIntervalSince(lastMBRequestDate)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastMBRequestDate = Date()
        var comps = URLComponents(url: mbBaseURL.appendingPathComponent("release"), resolvingAgainstBaseURL: true)!
        let query = #"release:"\#(album.escapedForLucene)" AND artist:"\#(artist.escapedForLucene)""#
        comps.queryItems = [
            URLQueryItem(name: "query",  value: query),
            URLQueryItem(name: "limit",  value: "1"),
            URLQueryItem(name: "fmt",    value: "json")
        ]
        guard let searchURL = comps.url else { return nil }

        do {
            let (data, response) = try await session.data(from: searchURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(MBReleaseSearchResult.self, from: data)
            guard let mbid = result.releases.first?.id else { return nil }

            // Cover Art Archive front image
            let caaURL = caaBaseURL
                .appendingPathComponent("release")
                .appendingPathComponent(mbid)
                .appendingPathComponent("front")
            // CAA redirects to the actual image; follow redirects.
            let (imageData, imageResponse) = try await session.data(from: caaURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return imageData
        } catch {
            return nil
        }
    }

    // MARK: - iTunes Search API
    /// Returns the 100x100 thumbnail URL then fetches the 600x600 version
    /// by replacing "100x100bb" with "600x600bb" in the URL.
    private func fetchFromItunes(artist: String, album: String) async -> Data? {
        var comps = URLComponents(url: itunesURL, resolvingAgainstBaseURL: true)!
        comps.queryItems = [
            URLQueryItem(name: "term",   value: "\(artist) \(album)"),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit",  value: "1")
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(ItunesSearchResult.self, from: data)
            guard let artURLString = result.results.first?.artworkUrl100 else { return nil }
            // Upscale: replace 100x100bb with 600x600bb
            let highResString = artURLString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let highResURL = URL(string: highResString) else { return nil }
            let (imageData, _) = try await session.data(from: highResURL)
            return imageData
        } catch {
            return nil
        }
    }

    // MARK: - Last.fm
    /// Requires Last.fm API key saved in UserDefaults under "lastFmAPIKey".
    private func fetchFromLastFm(artist: String, album: String) async -> Data? {
        guard let apiKey = UserDefaults.standard.string(forKey: "lastFmAPIKey"),
              !apiKey.isEmpty else { return nil }

        var comps = URLComponents(url: lastfmURL, resolvingAgainstBaseURL: true)!
        comps.queryItems = [
            URLQueryItem(name: "method",  value: "album.getinfo"),
            URLQueryItem(name: "artist",  value: artist),
            URLQueryItem(name: "album",   value: album),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format",  value: "json")
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(LastFmAlbumResult.self, from: data)
            // Pick the largest image (Last.fm returns multiple sizes; "mega" is biggest)
            let imageURLString = result.album.image
                .last(where: { $0.size == "mega" || $0.size == "extralarge" })?
                .text
            guard let imageURLString, let imageURL = URL(string: imageURLString) else { return nil }
            let (imageData, _) = try await session.data(from: imageURL)
            return imageData
        } catch {
            return nil
        }
    }

    // MARK: - Artist photos

    /// Stable cache key for artist photos — kept separate from album art keys.
    static func generateArtistPhotoKey(name: String) -> String {
        let k = "artist_photo:\(name.lowercased())"
        return k.data(using: .utf8)
            .map { Data($0).base64EncodedString() }
            ?? ""
    }

    /// Fetch an artist photo if not already cached. Tries TheAudioDB first,
    /// falls back to Last.fm when TheAudioDB has no result or its demo API key
    /// is rate-limited / disabled. Fire-and-forget safe.
    @discardableResult
    func fetchArtistPhotoIfNeeded(name: String) async -> String? {
        let key = Self.generateArtistPhotoKey(name: name)
        guard !key.isEmpty else { return nil }
        guard !cache.hasArtwork(forKey: key) else { return key }
        guard !inFlight.contains(key)        else { return key }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        if let data = await fetchArtistPhotoFromAudioDB(name: name) {
            cache.store(imageData: data, forKey: key)
            return key
        }
        if let data = await fetchArtistPhotoFromLastFm(name: name) {
            cache.store(imageData: data, forKey: key)
            return key
        }
        return nil
    }

    /// Free public endpoint (API key "2" is TheAudioDB's demo key — shared with
    /// every tutorial app, rate-limited and may stop working without notice).
    /// Returns the artist thumb — typically a square press/promo photo.
    private func fetchArtistPhotoFromAudioDB(name: String) async -> Data? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://www.theaudiodb.com/api/v1/json/2/search.php?s=\(encoded)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(AudioDBArtistResult.self, from: data)
            guard let thumbString = result.artists?.first?.strArtistThumb,
                  !thumbString.isEmpty,
                  let thumbURL = URL(string: thumbString) else { return nil }
            let (imageData, _) = try await session.data(from: thumbURL)
            return imageData
        } catch {
            return nil
        }
    }

    /// Last.fm artist.getInfo fallback. Requires the same `lastFmAPIKey` that
    /// album-art lookups already use. Last.fm's `image` field still serves
    /// historical artist photos for established artists; for newer artists the
    /// images are often the "star" placeholder and we drop those.
    private func fetchArtistPhotoFromLastFm(name: String) async -> Data? {
        guard let apiKey = UserDefaults.standard.string(forKey: "lastFmAPIKey"),
              !apiKey.isEmpty else { return nil }
        var comps = URLComponents(url: lastfmURL, resolvingAgainstBaseURL: true)!
        comps.queryItems = [
            URLQueryItem(name: "method",  value: "artist.getinfo"),
            URLQueryItem(name: "artist",  value: name),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format",  value: "json")
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(LastFmArtistResult.self, from: data)
            let urlString = result.artist.image
                .last(where: { $0.size == "mega" || $0.size == "extralarge" })?
                .text
            guard let urlString,
                  !urlString.isEmpty,
                  // Last.fm returns a star-shaped placeholder when no photo exists.
                  !urlString.contains("2a96cbd8b46e442fc41c2b86b821562f"),
                  let imageURL = URL(string: urlString) else { return nil }
            let (imageData, _) = try await session.data(from: imageURL)
            return imageData
        } catch {
            return nil
        }
    }
}

// MARK: - MusicBrainz response models
private struct MBReleaseSearchResult: Decodable {
    let releases: [MBRelease]
    struct MBRelease: Decodable {
        let id: String
    }
}

// MARK: - iTunes response models
private struct ItunesSearchResult: Decodable {
    let results: [ItunesAlbum]
    struct ItunesAlbum: Decodable {
        let artworkUrl100: String?
    }
}

// MARK: - Last.fm response models
private struct LastFmAlbumResult: Decodable {
    let album: LastFmAlbum
    struct LastFmAlbum: Decodable {
        let image: [LastFmImage]
    }
    struct LastFmImage: Decodable {
        let text: String
        let size: String
        enum CodingKeys: String, CodingKey { case text = "#text"; case size }
    }
}

// MARK: - TheAudioDB response models
private struct AudioDBArtistResult: Decodable {
    let artists: [AudioDBArtist]?
    struct AudioDBArtist: Decodable {
        let strArtistThumb: String?
    }
}

// MARK: - Last.fm artist response model
private struct LastFmArtistResult: Decodable {
    let artist: LastFmArtist
    struct LastFmArtist: Decodable {
        let image: [LastFmImage]
    }
    struct LastFmImage: Decodable {
        let text: String
        let size: String
        enum CodingKeys: String, CodingKey { case text = "#text"; case size }
    }
}
private extension String {
    /// Escapes special Lucene query characters for MusicBrainz search.
    var escapedForLucene: String {
        let special = #"+-&|!(){}[]^"~*?:\/"#
        return unicodeScalars.map { scalar -> String in
            let char = Character(scalar)
            return special.contains(char) ? "\\\(char)" : String(char)
        }.joined()
    }
}
