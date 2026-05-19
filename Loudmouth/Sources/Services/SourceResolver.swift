import Foundation
import CryptoKit
import Network

// MARK: - SourceResolver
/// Translates a TrackURI into a local URL that AVFoundation can open.
/// For remote tracks, this may involve downloading or generating a temp auth URL.
actor SourceResolver {
    private var adapters: [MusicSourceID: any MusicSourceAdapter] = [:]

    func register(adapter: some MusicSourceAdapter, for sourceID: MusicSourceID) {
        adapters[sourceID] = adapter
    }

    func adapter(for sourceID: MusicSourceID) -> (any MusicSourceAdapter)? {
        adapters[sourceID]
    }

    func localURL(for track: Track) async throws -> URL {
        // Check offline cache first — works for any source type
        if let cachedURL = await OfflineCacheService.shared.localURL(for: track) {
            return cachedURL
        }

        switch track.uri {
        case .localFile(let path):
            return URL(fileURLWithPath: path)

        case .remoteURL(let url):
            return url
        case .dlnaURL(let url):
            return url
        case .webRadio(let streamURL):
            return streamURL

        case .subsonicID(let serverID, let trackID):
            guard let adapter = adapters[MusicSourceID(serverID)] as? SubsonicSourceAdapter else {
                throw SourceError.adapterNotFound
            }
            return try await adapter.streamURL(for: trackID)

        case .cloudFile(let provider, let fileID):
            guard let adapter = adapters.values.first(where: {
                ($0 as? CloudSourceAdapter)?.provider == provider
            }) as? CloudSourceAdapter else {
                throw SourceError.adapterNotFound
            }
            return try await adapter.downloadURL(for: fileID)
        }
    }
}

enum SourceError: Error {
    case adapterNotFound
    case authenticationFailed
    case networkUnavailable
    case fileNotFound
}

// MARK: - MusicSourceAdapter protocol
protocol MusicSourceAdapter: Actor {
    var sourceID: MusicSourceID { get }
    /// Enumerate all tracks available from this source.
    func fetchTracks() async throws -> [Track]
}

// MARK: - Concrete adapters (stubs — each filled in with full logic)

// LocalSource is handled directly by LibraryScanner + SourceResolver (local file path).
// Adapters below handle sources that require network or auth.

actor SubsonicSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: SubsonicSourceConfig
    private var session: URLSession

    init(sourceID: MusicSourceID, config: SubsonicSourceConfig) {
        self.sourceID = sourceID
        self.config = config
        self.session = URLSession.shared
    }

    func fetchTracks() async throws -> [Track] {
        let tracks = try await fetchAlbumList()
        return tracks
    }

    func streamURL(for trackID: String) async throws -> URL {
        let (salt, token) = try makeAuthTokens()
        var comps = URLComponents(string: config.serverURL)!
        comps.path = "/rest/stream.view"
        comps.queryItems = authQueryItems(salt: salt, token: token) + [
            URLQueryItem(name: "id",           value: trackID),
            URLQueryItem(name: "maxBitRate",   value: "0"),    // 0 = original quality
            URLQueryItem(name: "format",       value: "raw")
        ]
        guard let url = comps.url else { throw SourceError.networkUnavailable }
        return url
    }

    // MARK: - Library fetch
    /// Fetches all albums via getAlbumList2, then each album's tracks via getAlbum.
    private func fetchAlbumList() async throws -> [Track] {
        var offset = 0
        let size = 500
        var allTracks: [Track] = []

        while true {
            let (salt, token) = try makeAuthTokens()
            var comps = URLComponents(string: config.serverURL)!
            comps.path = "/rest/getAlbumList2.view"
            comps.queryItems = authQueryItems(salt: salt, token: token) + [
                URLQueryItem(name: "type",   value: "alphabeticalByArtist"),
                URLQueryItem(name: "size",   value: "\(size)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            guard let url = comps.url else { break }
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(SubsonicResponse<AlbumList2>.self, from: data)
            guard response.isOK else { throw SourceError.authenticationFailed }
            let albums = response.subsonicResponse.albumList2?.album ?? []
            if albums.isEmpty { break }

            for album in albums {
                let tracks = try await fetchAlbumTracks(albumID: album.id)
                allTracks.append(contentsOf: tracks)
            }
            offset += albums.count
            if albums.count < size { break }
        }
        return allTracks
    }

    private func fetchAlbumTracks(albumID: String) async throws -> [Track] {
        let (salt, token) = try makeAuthTokens()
        var comps = URLComponents(string: config.serverURL)!
        comps.path = "/rest/getAlbum.view"
        comps.queryItems = authQueryItems(salt: salt, token: token) + [
            URLQueryItem(name: "id", value: albumID)
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(SubsonicResponse<AlbumDetail>.self, from: data)
        guard response.isOK else { return [] }
        return (response.subsonicResponse.album?.song ?? []).map { song in
            Track(
                title:           song.title,
                artist:          song.artist ?? "",
                albumArtist:     song.albumArtist ?? song.artist ?? "",
                album:           song.album ?? "",
                genre:           song.genre ?? "",
                year:            song.year,
                trackNumber:     song.track,
                discNumber:      song.discNumber,
                source:          sourceID,
                uri:             .subsonicID(serverID: sourceID.rawValue, trackID: song.id),
                format:          AudioFormat(fileExtension: song.suffix ?? "") ?? .mp3,
                durationSeconds: Double(song.duration ?? 0),
                bitrateBps:      song.bitRate.map { $0 * 1000 },
                artworkCacheKey: song.coverArt.map { "subsonic_\(sourceID.rawValue)_\($0)" }
            )
        }
    }

    // MARK: - Token-based auth (Subsonic API 1.13.0+)
    /// Generates a cryptographically random salt and computes MD5(password + salt).
    /// The password is never transmitted in plain text.
    private func makeAuthTokens() throws -> (salt: String, token: String) {
        let password = try KeychainHelper.shared.read(key: config.keychainKey)
        // Random hex salt (16 bytes)
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = bytes.map { String(format: "%02x", $0) }.joined()
        let token = md5(password + salt)
        return (salt, token)
    }

    private func authQueryItems(salt: String, token: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "c", value: "Loudmouth"),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    /// MD5 via CryptoKit — Subsonic API spec requires it.
    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

actor NASSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: NASSourceConfig
    private let browser = DLNABrowser()

    init(sourceID: MusicSourceID, config: NASSourceConfig) {
        self.sourceID = sourceID
        self.config = config
    }

    func fetchTracks() async throws -> [Track] {
        // Build the device description URL from host + port.
        // Real DLNA servers advertise their description URL via SSDP;
        // here we accept a direct host:port as a fallback for manual NAS config.
        let scheme = "http"
        guard let descURL = URL(string: "\(scheme)://\(config.host):\(config.port)/description.xml") else {
            throw SourceError.networkUnavailable
        }
        return try await browser.browse(serverURL: descURL, sourceID: sourceID)
    }
}

actor CloudSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    let provider: CloudProvider
    private var config: CloudSourceConfig

    init(sourceID: MusicSourceID, config: CloudSourceConfig) {
        self.sourceID = sourceID
        self.provider = config.provider
        self.config = config
    }

    func updateConfig(_ newConfig: CloudSourceConfig) {
        config = newConfig
    }

    func fetchTracks() async throws -> [Track] {
        switch config.provider {
        case .iCloud:      return try await fetchICloudTracks()
        case .backblaze:   return try await fetchBackblazeTracks()
        case .dropbox:     return try await fetchDropboxTracks()
        case .googleDrive: return try await fetchGoogleDriveTracks()
        case .oneDrive:    return try await fetchOneDriveTracks()
        }
    }

    func downloadURL(for fileID: String) async throws -> URL {
        switch config.provider {
        case .iCloud:
            return URL(fileURLWithPath: fileID)

        case .backblaze:
            // fileID is the full HTTPS download URL stored during fetchBackblazeTracks
            guard let url = URL(string: fileID) else { throw SourceError.fileNotFound }
            return url

        case .dropbox:
            // Use /2/files/get_temporary_link to obtain a short-lived direct download URL
            guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
                  !token.isEmpty else { throw SourceError.authenticationFailed }
            var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["path": "id:\(fileID)"])
            let (data, _) = try await URLSession.shared.data(for: req)
            struct TempLink: Decodable { let link: String }
            guard let resp = try? JSONDecoder().decode(TempLink.self, from: data),
                  let url = URL(string: resp.link) else { throw SourceError.fileNotFound }
            return url

        case .googleDrive:
            // Append ?alt=media to stream the file content directly
            guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
                  !token.isEmpty else { throw SourceError.authenticationFailed }
            guard var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)") else {
                throw SourceError.fileNotFound
            }
            comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
            guard let url = comps.url else { throw SourceError.fileNotFound }
            // We need to attach the auth header; return a custom URL and intercept via URLProtocol
            // Instead, build a URLRequest and download to a temp file so AVPlayer can use a local URL
            var dlReq = URLRequest(url: url)
            dlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension((fileID as NSString).pathExtension.isEmpty ? "mp3" : (fileID as NSString).pathExtension)
            let (downloadedURL, _) = try await URLSession.shared.download(for: dlReq)
            try? FileManager.default.moveItem(at: downloadedURL, to: tmpURL)
            return tmpURL

        case .oneDrive:
            // /me/drive/items/{id}/content follows redirects to the actual CDN URL
            guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
                  !token.isEmpty else { throw SourceError.authenticationFailed }
            guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(fileID)/content") else {
                throw SourceError.fileNotFound
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // The Graph API returns a 302 redirect to a pre-signed CDN URL — follow it
            let session = URLSession(configuration: .default)  // default follows redirects
            let (_, response) = try await session.data(for: req)
            if let httpResp = response as? HTTPURLResponse,
               let location = httpResp.value(forHTTPHeaderField: "Location"),
               let redirectURL = URL(string: location) {
                return redirectURL
            }
            // If response was followed directly (200), return a temp download
            var dlReq = URLRequest(url: url)
            dlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp3")
            let (downloadedURL, _) = try await URLSession.shared.download(for: dlReq)
            try? FileManager.default.moveItem(at: downloadedURL, to: tmpURL)
            return tmpURL
        }
    }

    // MARK: - iCloud Drive
    private func fetchICloudTracks() async throws -> [Track] {
        return try await withCheckedThrowingContinuation { continuation in
            let query = NSMetadataQuery()
            query.searchScopes = [
                NSMetadataQueryUbiquitousDocumentsScope,
                NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope
            ]
            let exts = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus", "wv", "dsf"]
            query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates:
                exts.map { NSPredicate(format: "%K ENDSWITH[c] '.%@'", NSMetadataItemFSNameKey, $0) }
            )

            var observer: Any?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak query] _ in
                guard let q = query else { continuation.resume(returning: []); return }
                q.stop()
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }

                let sid = self.sourceID
                let tracks: [Track] = (0..<q.resultCount).compactMap { i in
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    let url = URL(fileURLWithPath: path)
                    // Trigger download of the stub if not local yet
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    return Track(
                        title: url.deletingPathExtension().lastPathComponent,
                        source: sid,
                        uri: .cloudFile(provider: .iCloud, fileID: path),
                        format: AudioFormat(fileExtension: url.pathExtension) ?? .mp3,
                        durationSeconds: 0
                    )
                }
                continuation.resume(returning: tracks)
            }
            DispatchQueue.main.async { query.start() }
        }
    }

    // MARK: - Backblaze B2
    // Uses the B2 Native API: https://www.backblaze.com/b2/docs/
    private func fetchBackblazeTracks() async throws -> [Track] {
        guard !config.accountID.isEmpty,
              let appKey = try? KeychainHelper.shared.read(key: config.keychainKey) else {
            throw SourceError.authenticationFailed
        }

        // 1. Authorize
        let credential = Data("\(config.accountID):\(appKey)".utf8).base64EncodedString()
        var authReq = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        authReq.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let (authData, _) = try await URLSession.shared.data(for: authReq)

        struct B2Auth: Decodable {
            let apiInfo: APIInfo
            let authorizationToken: String
            struct APIInfo: Decodable {
                let storageApi: StorageAPI
                struct StorageAPI: Decodable { let apiUrl: String; let bucketId: String? }
            }
        }
        let auth = try JSONDecoder().decode(B2Auth.self, from: authData)
        let apiURL = auth.apiInfo.storageApi.apiUrl
        let authToken = auth.authorizationToken

        // 2. List buckets to find audio files
        var listReq = URLRequest(url: URL(string: "\(apiURL)/b2api/v3/b2_list_buckets")!)
        listReq.setValue(authToken, forHTTPHeaderField: "Authorization")
        let (bucketsData, _) = try await URLSession.shared.data(for: listReq)

        struct B2Buckets: Decodable { let buckets: [B2Bucket] }
        struct B2Bucket: Decodable { let bucketId: String; let bucketName: String }
        let buckets = (try? JSONDecoder().decode(B2Buckets.self, from: bucketsData))?.buckets ?? []

        // 3. List files in each bucket
        let audioExts = Set(["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus", "wv"])
        var tracks: [Track] = []
        for bucket in buckets {
            var startFileName: String? = nil
            repeat {
                var params: [String: Any] = ["bucketId": bucket.bucketId, "maxFileCount": 1000]
                if let start = startFileName { params["startFileName"] = start }
                var listFilesReq = URLRequest(url: URL(string: "\(apiURL)/b2api/v3/b2_list_file_names")!)
                listFilesReq.setValue(authToken, forHTTPHeaderField: "Authorization")
                listFilesReq.httpMethod = "POST"
                listFilesReq.httpBody = try? JSONSerialization.data(withJSONObject: params)
                listFilesReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (filesData, _) = try await URLSession.shared.data(for: listFilesReq)

                struct B2FileList: Decodable { let files: [B2File]; let nextFileName: String? }
                struct B2File: Decodable { let fileId: String; let fileName: String; let contentLength: Int64 }
                guard let list = try? JSONDecoder().decode(B2FileList.self, from: filesData) else { break }

                for file in list.files {
                    let ext = (file.fileName as NSString).pathExtension.lowercased()
                    guard audioExts.contains(ext) else { continue }
                    let name = (file.fileName as NSString).lastPathComponent
                    let downloadURL = "\(apiURL)/file/\(bucket.bucketName)/\(file.fileName)"
                    tracks.append(Track(
                        title: (name as NSString).deletingPathExtension,
                        source: sourceID,
                        uri: .cloudFile(provider: .backblaze, fileID: downloadURL),
                        format: AudioFormat(fileExtension: ext) ?? .mp3,
                        durationSeconds: 0
                    ))
                }
                startFileName = list.nextFileName
            } while startFileName != nil
        }
        return tracks
    }

    // MARK: - Dropbox
    // Dropbox API v2: https://www.dropbox.com/developers/documentation/http/documentation
    private func fetchDropboxTracks() async throws -> [Track] {
        guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
              !token.isEmpty else { throw SourceError.authenticationFailed }

        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/search_v2")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": "audio",
            "options": ["file_categories": ["audio"], "max_results": 1000]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)

        struct SearchResult: Decodable {
            let matches: [Match]
            struct Match: Decodable {
                let metadata: MetadataWrapper
                struct MetadataWrapper: Decodable {
                    let metadata: FileMetadata
                    struct FileMetadata: Decodable { let name: String; let id: String; let pathLower: String? }
                    enum CodingKeys: String, CodingKey { case metadata }
                }
            }
        }
        guard let result = try? JSONDecoder().decode(SearchResult.self, from: data) else { return [] }
        let audioExts = Set(["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus"])
        return result.matches.compactMap { match in
            let meta = match.metadata.metadata
            let ext = (meta.name as NSString).pathExtension.lowercased()
            guard audioExts.contains(ext) else { return nil }
            return Track(
                title: (meta.name as NSString).deletingPathExtension,
                source: sourceID,
                uri: .cloudFile(provider: .dropbox, fileID: meta.id),
                format: AudioFormat(fileExtension: ext) ?? .mp3,
                durationSeconds: 0
            )
        }
    }

    // MARK: - Google Drive
    // Google Drive API v3: https://developers.google.com/drive/api/v3
    private func fetchGoogleDriveTracks() async throws -> [Track] {
        guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
              !token.isEmpty else { throw SourceError.authenticationFailed }

        let audioMimes = ["audio/mpeg", "audio/flac", "audio/mp4", "audio/x-wav", "audio/aiff",
                          "audio/ogg", "audio/opus", "audio/x-m4a"]
        let qParam = "(\(audioMimes.map { "mimeType='\($0)'" }.joined(separator: " or "))) and trashed=false"

        var allFiles: [Track] = []
        var pageToken: String? = nil

        repeat {
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "q",        value: qParam),
                URLQueryItem(name: "fields",   value: "nextPageToken,files(id,name,mimeType,size)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pt = pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pt)) }
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            comps.queryItems = queryItems
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)

            struct DriveFiles: Decodable {
                let files: [DriveFile]
                let nextPageToken: String?
                struct DriveFile: Decodable { let id: String; let name: String; let mimeType: String }
            }
            guard let result = try? JSONDecoder().decode(DriveFiles.self, from: data) else { break }
            let newTracks: [Track] = result.files.map { file in
                let ext = (file.name as NSString).pathExtension.lowercased()
                return Track(
                    title: (file.name as NSString).deletingPathExtension,
                    source: sourceID,
                    uri: .cloudFile(provider: .googleDrive, fileID: file.id),
                    format: AudioFormat(fileExtension: ext) ?? .mp3,
                    durationSeconds: 0
                )
            }
            allFiles.append(contentsOf: newTracks)
            pageToken = result.nextPageToken
        } while pageToken != nil

        return allFiles
    }

    // MARK: - OneDrive (Microsoft Graph)
    // Graph API: https://learn.microsoft.com/en-us/graph/api/driveitem-list-children
    private func fetchOneDriveTracks() async throws -> [Track] {
        guard let token = try? KeychainHelper.shared.read(key: config.keychainKey),
              !token.isEmpty else { throw SourceError.authenticationFailed }

        // Use /me/drive/root/search with a wildcard — filter by extension client-side
        // because Graph does not support mimeType filter in drive search
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/search(q='')?$select=id,name,file,size&$top=1000")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)

        struct GraphResult: Decodable {
            let value: [GraphItem]
            struct GraphItem: Decodable {
                let id: String; let name: String
                let file: FileInfo?
                struct FileInfo: Decodable { let mimeType: String }
            }
        }
        let audioExts = Set(["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus"])
        guard let result = try? JSONDecoder().decode(GraphResult.self, from: data) else { return [] }
        return result.value.compactMap { item in
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard audioExts.contains(ext) else { return nil }
            return Track(
                title: (item.name as NSString).deletingPathExtension,
                source: sourceID,
                uri: .cloudFile(provider: .oneDrive, fileID: item.id),
                format: AudioFormat(fileExtension: ext) ?? .mp3,
                durationSeconds: 0
            )
        }
    }
}

actor WiFiTransferService: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: WiFiTransferConfig
    private var httpServer: SimpleHTTPServer?

    init(sourceID: MusicSourceID, config: WiFiTransferConfig) {
        self.sourceID = sourceID
        self.config = config
    }

    func start() async {
        httpServer = SimpleHTTPServer(port: UInt16(config.port))
        await httpServer?.start()
    }

    func stop() async {
        await httpServer?.stop()
        httpServer = nil
    }

    func fetchTracks() async throws -> [Track] {
        // Tracks uploaded via Wi-Fi transfer are moved into the local library.
        return []
    }
}

actor SimpleHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.mohome.loudmouth.http")

    init(port: UInt16) { self.port = port }

    func start() async {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { conn in
                Task { await self.handle(connection: conn) }
            }
            listener.start(queue: queue)
        } catch {
            // Port conflict or permission error — silently skip
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        // Read HTTP request, then receive file data
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // Only handle POST /upload
            if request.hasPrefix("POST /upload") {
                Task { await self.receiveBody(on: connection, headerData: data) }
            } else if request.hasPrefix("GET") {
                Task { await self.sendUploadPage(on: connection) }
            } else {
                connection.cancel()
            }
        }
    }

    private func sendUploadPage(on connection: NWConnection) {
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width">
        <title>Loudmouth Upload</title></head><body>
        <h2>Upload Audio to Loudmouth</h2>
        <form method="post" action="/upload" enctype="multipart/form-data">
          <input type="file" name="audio" accept="audio/*" multiple><br><br>
          <input type="submit" value="Upload">
        </form></body></html>
        """
        let body = Data(html.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\n\r\n"
        var responseData = Data(response.utf8)
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func receiveBody(on connection: NWConnection, headerData: Data) {
        // Extract boundary from Content-Type header
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let boundaryRange = headerStr.range(of: "boundary=") else {
            send400(on: connection)
            return
        }
        let boundary = "--" + String(headerStr[boundaryRange.upperBound...].prefix(while: { !$0.isNewline && !$0.isWhitespace }))

        // Read the full body (up to 500 MB)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 500 * 1024 * 1024) { [self] data, _, _, _ in
            guard let data else { connection.cancel(); return }
            Task {
                await self.saveMultipartFiles(data: data, boundary: boundary)
                let ok = "HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: Data(ok.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func saveMultipartFiles(data: Data, boundary: String) {
        guard let boundaryData = boundary.data(using: .utf8) else { return }
        let parts = data.binarySplit(separator: boundaryData)
        // parts[0] = preamble, parts.last = epilogue — skip both
        guard parts.count > 2 else { return }

        let destinationRoot = (FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.loudmouth")
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("WiFiTransfer")
        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for part in parts.dropFirst().dropLast() {
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerData = part[part.startIndex..<headerEnd.lowerBound]
            var bodyData = part[headerEnd.upperBound...]
            let crlf = Data("\r\n".utf8)
            if bodyData.count >= 2 && bodyData.suffix(2) == crlf { bodyData = bodyData.dropLast(2) }
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let filenameRange = headerStr.range(of: "filename=\"") else { continue }
            let filename = String(headerStr[filenameRange.upperBound...].prefix(while: { $0 != "\"" }))
            guard !filename.isEmpty,
                  AudioFormat(fileExtension: URL(fileURLWithPath: filename).pathExtension) != nil else { continue }
            let dest = destinationRoot.appendingPathComponent(filename)
            try? Data(bodyData).write(to: dest)
        }
        // Notify the app that new files have been dropped in so the library scanner can pick them up.
        NotificationCenter.default.post(name: .wifiTransferDidReceiveFiles,
                                        object: destinationRoot)
    }

    private func send400(on connection: NWConnection) {
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Notification names
extension Notification.Name {
    /// Posted by SimpleHTTPServer after audio files are saved from a Wi-Fi Transfer upload.
    /// `object` is the `URL` of the destination folder containing the new files.
    static let wifiTransferDidReceiveFiles = Notification.Name("wifiTransferDidReceiveFiles")
}

// MARK: - Data binary split helper
private extension Data {
    /// Splits `self` at every occurrence of `separator`, returning all parts including empty ones.
    func binarySplit(separator: Data) -> [Data] {
        var result: [Data] = []
        var searchStart = startIndex
        while let range = self[searchStart...].range(of: separator) {
            result.append(self[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        result.append(self[searchStart...])
        return result
    }
}
