import Foundation
import Network

// MARK: - DLNABrowser
/// Browses a DLNA/UPnP content directory server using SOAP over HTTP.
/// Discovers servers via SSDP, then walks the content tree to enumerate audio tracks.
actor DLNABrowser {

    // MARK: - Discovery
    /// Sends an SSDP M-SEARCH multicast to find UPnP MediaServer devices on the LAN.
    /// Returns discovered device description URLs.
    func discoverServers(timeout: TimeInterval = 5) async -> [URL] {
        let ssdpMessage = """
        M-SEARCH * HTTP/1.1\r\n\
        HOST: 239.255.255.250:1900\r\n\
        MAN: "ssdp:discover"\r\n\
        MX: 3\r\n\
        ST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n
        """
        // Real SSDP uses UDP multicast via Network.framework NWConnection.
        // The response parsing and cancellation loop run below.
        return await withCheckedContinuation { continuation in
            Task {
                let discovered = await SSDPClient().search(message: ssdpMessage, timeout: timeout)
                continuation.resume(returning: discovered)
            }
        }
    }

    // MARK: - Content Directory Browse
    /// Browse a DLNA content directory starting at the given container.
    /// Returns all audio tracks found in the tree.
    func browse(serverURL: URL, sourceID: MusicSourceID, rootObjectID: String = "0") async throws -> [Track] {
        // Fetch device description to find the ContentDirectory control URL.
        let controlURL = try await fetchControlURL(descriptionURL: serverURL)
        var tracks = try await browseContainer(objectID: rootObjectID, controlURL: controlURL, sourceID: sourceID)
        // Deduplicate by resource URL. NAS DLNA servers expose the same audio files
        // through multiple virtual containers (By Album, By Artist, All Music, etc.).
        // Without deduplication every song appears hundreds of times in the library.
        var seenURLs = Set<String>()
        tracks = tracks.filter { track in
            guard case .dlnaURL(let url) = track.uri else { return true }
            return seenURLs.insert(url.absoluteString).inserted
        }
        return tracks
    }

    /// Recursively browse a container (objectID "0" = root).
    /// Paginates in blocks of 1000 items per container and enforces a recursion depth limit.
    private func browseContainer(objectID: String, controlURL: URL, sourceID: MusicSourceID, depth: Int = 0) async throws -> [Track] {
        guard depth < 10 else { return [] }    // cap recursion to avoid runaway tree walks
        var tracks: [Track] = []
        var startIndex = 0
        let pageSize = 1000

        repeat {
            let response = try await soapBrowse(objectID: objectID, controlURL: controlURL, startingIndex: startIndex)
            for item in response.items {
                if item.isContainer {
                    let children = try await browseContainer(
                        objectID: item.id,
                        controlURL: controlURL,
                        sourceID: sourceID,
                        depth: depth + 1
                    )
                    tracks.append(contentsOf: children)
                } else if let track = item.asTrack(sourceID: sourceID) {
                    tracks.append(track)
                }
            }
            if response.items.count < pageSize { break }
            startIndex += response.items.count
        } while true

        return tracks
    }

    // MARK: - SOAP Browse action
    private func soapBrowse(objectID: String, controlURL: URL, startingIndex: Int = 0) async throws -> DLNABrowseResult {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(objectID)</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>\(startingIndex)</StartingIndex>
              <RequestedCount>1000</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DLNAError.soapFailed
        }
        return try DLNAResponseParser().parse(data: data)
    }

    // MARK: - Container listing (for folder picker)
    /// Lists immediate child containers of the given objectID without recursing.
    /// Used by the NAS folder picker so the user can select which folder to scan.
    func listContainers(serverURL: URL, parentID: String = "0") async throws -> [DLNAItem] {
        let controlURL = try await fetchControlURL(descriptionURL: serverURL)
        let result = try await soapBrowse(objectID: parentID, controlURL: controlURL)
        return result.items.filter { $0.isContainer }
    }

    // MARK: - Device description
    /// Parses the UPnP device description XML to extract the ContentDirectory control URL.
    private func fetchControlURL(descriptionURL: URL) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: descriptionURL)
        return try DLNADescriptionParser().parseControlURL(data: data, baseURL: descriptionURL)
    }
}

// MARK: - SSDP Client
/// Sends M-SEARCH and collects LOCATION headers from responses using UDP multicast.
actor SSDPClient {
    func search(message: String, timeout: TimeInterval) async -> [URL] {
        await withCheckedContinuation { continuation in
            var results: [URL] = []
            var done = false

            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let connection = NWConnection(
                host: "239.255.255.250",
                port: 1900,
                using: params
            )

            func finish() {
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: results)
            }

            func receiveNext() {
                connection.receiveMessage { data, _, _, error in
                    if let data, let text = String(data: data, encoding: .utf8),
                       let url = SSDPClient.parseLocation(from: text) {
                        if !results.contains(url) { results.append(url) }
                    }
                    guard !done, error == nil else { finish(); return }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: message.data(using: .utf8),
                                    completion: .contentProcessed { _ in receiveNext() })
                case .failed, .cancelled:
                    finish()
                default: break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private static func parseLocation(from response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                return URL(string: value)
            }
        }
        return nil
    }
}

// MARK: - DLNA Browse Result
struct DLNABrowseResult {
    var items: [DLNAItem]
}

/// One `<res>` entry from a DIDL-Lite item. DLNA items routinely expose
/// multiple resources for the same audio file: the original plus one or more
/// on-the-fly transcoded variants. Capturing all of them lets us pick the
/// highest-quality one rather than blindly trusting parser order.
struct DLNAResource {
    var url: URL
    var mimeType: String?
    var bitrate: Int?            // bits-per-second from `bitrate` attribute
    var size: Int64?             // bytes from `size` attribute
    var sampleFrequency: Int?    // Hz from `sampleFrequency` attribute
    var bitsPerSample: Int?
    var nrAudioChannels: Int?
}

struct DLNAItem {
    var id: String
    var parentID: String
    var title: String
    var isContainer: Bool
    var resources: [DLNAResource] = []
    var artist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var durationSeconds: Double?
    var albumArtURL: URL?
    var upnpClass: String?

    /// First resource URL, retained for callers that don't care about scoring
    /// (the folder-picker container list never reaches this, and the parser
    /// uses it for legacy "did we see a res yet" checks).
    var resourceURL: URL? { resources.first?.url }

    func asTrack(sourceID: MusicSourceID) -> Track? {
        guard !isContainer else { return nil }
        // Only accept audio items. DLNA servers expose video, images, etc. under
        // different upnp:class values. Audio items have class "object.item.audioItem*".
        if let cls = upnpClass, !cls.hasPrefix("object.item.audioItem") { return nil }
        guard let res = Self.pickBestResource(from: resources) else { return nil }
        // Determine format from MIME type first so extensionless URLs (e.g.
        // http://host:8200/MediaItems/123) are not silently dropped.
        let format: AudioFormat
        if let mime = res.mimeType, let f = AudioFormat(mimeType: mime) {
            format = f
        } else {
            let ext = res.url.pathExtension
            guard let f = AudioFormat(fileExtension: ext) else { return nil }
            format = f
        }
        // Use the albumArtURI as the artwork cache key so DLNA tracks get artwork.
        let artKey = albumArtURL.map { "dlna_art_\($0.absoluteString)" }
        return Track(
            title:           title,
            artist:          artist ?? "",
            album:           album ?? "",
            genre:           genre ?? "",
            year:            year,
            trackNumber:     trackNumber,
            source:          sourceID,
            uri:             .dlnaURL(url: res.url),
            format:          format,
            durationSeconds: durationSeconds ?? 0,
            artworkCacheKey: artKey
        )
    }

    /// Picks the highest-quality resource. Many DLNA servers (Plex, Synology,
    /// some Asset UPnP configs) advertise transcoded variants before the
    /// original, so picking the first `<res>` silently downgrades the user to
    /// MP3 even when the source is lossless. Strategy:
    ///   1. Prefer entries whose MIME type indicates a lossless codec.
    ///   2. Among equally-rated codecs, prefer the highest declared bitrate.
    ///   3. If no bitrate metadata, prefer the largest declared size.
    ///   4. As a final tie-breaker, preserve the server's original order.
    static func pickBestResource(from resources: [DLNAResource]) -> DLNAResource? {
        guard let first = resources.first else { return nil }
        if resources.count == 1 { return first }
        let scored = resources.enumerated().map { (index, r) in
            (resource: r, score: scoreResource(r), order: index)
        }
        return scored.max { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.order > b.order   // earlier index wins on tie
        }?.resource
    }

    /// Higher = better. Codec class is the dominant factor; bitrate/size break
    /// ties only when codec class is equal.
    private static func scoreResource(_ r: DLNAResource) -> Int {
        var score = 0
        // Codec class (multiplied so it always outranks bitrate)
        switch codecClass(mimeType: r.mimeType, url: r.url) {
        case .lossless: score += 1_000_000_000
        case .lossyHigh: score += 500_000_000
        case .lossy:    score += 100_000_000
        case .unknown:  break
        }
        // Bitrate (bps). Caps to avoid overflowing past the next class boundary.
        if let bps = r.bitrate { score += min(bps, 50_000_000) }
        // Size (bytes / 1000) as a secondary signal when bitrate missing.
        else if let bytes = r.size { score += Int(min(bytes / 1000, 50_000_000)) }
        return score
    }

    private enum CodecClass { case lossless, lossyHigh, lossy, unknown }
    private static func codecClass(mimeType: String?, url: URL) -> CodecClass {
        let mime = mimeType?.lowercased() ?? ""
        let ext  = url.pathExtension.lowercased()
        let losslessMimes: Set<String> = [
            "audio/flac", "audio/x-flac",
            "audio/wav",  "audio/x-wav", "audio/wave",
            "audio/aiff", "audio/x-aiff",
            "audio/alac", "audio/x-alac",
            "audio/dsd",  "audio/x-dsd"
        ]
        let losslessExts: Set<String> = ["flac", "wav", "aiff", "aif", "alac", "ape", "wv", "dsf", "dff"]
        let lossyHighMimes: Set<String> = ["audio/mp4", "audio/x-m4a"]   // ambiguous (ALAC or AAC)
        let lossyHighExts: Set<String>  = ["m4a"]
        let lossyMimes: Set<String> = [
            "audio/mpeg", "audio/mp3",
            "audio/aac",  "audio/x-aac",
            "audio/ogg",  "audio/vorbis", "audio/opus",
            "audio/webm"
        ]
        let lossyExts: Set<String> = ["mp3", "aac", "ogg", "opus", "oga", "webm"]
        if losslessMimes.contains(mime) || losslessExts.contains(ext) { return .lossless }
        if lossyHighMimes.contains(mime) || lossyHighExts.contains(ext) { return .lossyHigh }
        if lossyMimes.contains(mime)    || lossyExts.contains(ext)    { return .lossy }
        return .unknown
    }
}

// MARK: - XML Parsers
/// Parses the DIDL-Lite XML returned inside a SOAP Browse response.
class DLNAResponseParser: NSObject, XMLParserDelegate {
    private var items: [DLNAItem] = []
    private var current: DLNAItem?
    private var currentText = ""
    private var insideResult = false
    /// Resource being built from the current `<res>` element. The element's
    /// attributes are read in didStartElement; its URL is taken from the
    /// element's text in didEndElement, then the resource is appended to the
    /// current item.
    private var currentResource: DLNAResource?

    func parse(data: Data) throws -> DLNABrowseResult {
        // The Browse result is double-XML: the SOAP response contains a
        // URL-escaped DIDL-Lite document in <Result>. Extract and re-parse it.
        guard let soap = String(data: data, encoding: .utf8),
              let resultStart = soap.range(of: "<Result>"),
              let resultEnd   = soap.range(of: "</Result>") else {
            throw DLNAError.parseError
        }
        let escaped = String(soap[resultStart.upperBound..<resultEnd.lowerBound])
        let unescaped = escaped
            .replacingOccurrences(of: "&lt;",  with: "<")
            .replacingOccurrences(of: "&gt;",  with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard let didlData = unescaped.data(using: .utf8) else { throw DLNAError.parseError }

        let parser = XMLParser(data: didlData)
        parser.delegate = self
        parser.parse()
        return DLNABrowseResult(items: items)
    }

    // XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        switch elementName {
        case "container":
            current = DLNAItem(id: attributes["id"] ?? "",
                               parentID: attributes["parentID"] ?? "",
                               title: "", isContainer: true)
        case "item":
            current = DLNAItem(id: attributes["id"] ?? "",
                               parentID: attributes["parentID"] ?? "",
                               title: "", isContainer: false)
        case "res":
            // Collect all <res> entries. DLNA items often include several variants
            // (original + transcoded). DLNAItem.pickBestResource picks the highest
            // quality one when constructing the Track.
            guard current?.isContainer == false else { break }
            var res = DLNAResource(url: URL(fileURLWithPath: "/"))   // url filled in didEndElement
            // protocolInfo format: "http-get:*:audio/mpeg:DLNA.ORG_PN=..."
            // The MIME type is the 3rd colon-separated field (index 2).
            if let proto = attributes["protocolInfo"] {
                let fields = proto.split(separator: ":")
                if fields.count > 2 { res.mimeType = String(fields[2]) }
            }
            if let bps = attributes["bitrate"].flatMap(Int.init) { res.bitrate = bps }
            if let sz = attributes["size"].flatMap(Int64.init)   { res.size = sz }
            if let sf = attributes["sampleFrequency"].flatMap(Int.init) { res.sampleFrequency = sf }
            if let bs = attributes["bitsPerSample"].flatMap(Int.init)   { res.bitsPerSample = bs }
            if let ch = attributes["nrAudioChannels"].flatMap(Int.init) { res.nrAudioChannels = ch }
            // Parse duration: "h:mm:ss.xxx" — duration is per-resource in DIDL
            // but in practice every variant reports the same value, so write it
            // to the item once (first non-empty wins).
            if var item = current, item.durationSeconds == nil || item.durationSeconds == 0,
               let durStr = attributes["duration"] {
                item.durationSeconds = parseDuration(durStr)
                current = item
            }
            currentResource = res
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard var item = current else { return }
        switch elementName {
        case "dc:title":        item.title = currentText
        case "upnp:artist":     item.artist = currentText
        case "upnp:album":      item.album = currentText
        case "upnp:genre":      item.genre = currentText
        case "upnp:originalTrackNumber": item.trackNumber = Int(currentText)
        case "dc:date":         item.year = Int(currentText.prefix(4))
        case "upnp:class":      item.upnpClass = currentText
        case "res":
            if !item.isContainer, var res = currentResource,
               let url = URL(string: currentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                res.url = url
                item.resources.append(res)
            }
            currentResource = nil
        case "upnp:albumArtURI":
            item.albumArtURL = URL(string: currentText)
        case "container", "item":
            if !item.title.isEmpty { items.append(item) }
            current = nil
            // Do NOT fall through to "current = item" below — we just cleared it.
            return
        default: break
        }
        current = item
    }

    /// Parses DLNA duration "h:mm:ss.xxx" or "mm:ss" into seconds.
    private func parseDuration(_ str: String) -> Double {
        let parts = str.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }
}

/// Parses a UPnP device description XML to find the ContentDirectory control URL.
class DLNADescriptionParser: NSObject, XMLParserDelegate {
    private var controlURL: String?
    private var inContentDirectory = false
    private var inControlURL = false
    private var currentText = ""

    func parseControlURL(data: Data, baseURL: URL) throws -> URL {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        guard let path = controlURL else { throw DLNAError.controlURLNotFound }
        return baseURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        if elementName == "serviceType" { inContentDirectory = false }
        if elementName == "controlURL" && inContentDirectory { inControlURL = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "serviceType",
           currentText.contains("ContentDirectory") { inContentDirectory = true }
        if elementName == "controlURL" && inControlURL {
            controlURL = currentText
            inControlURL = false
        }
    }
}

// MARK: - Errors
enum DLNAError: Error {
    case soapFailed
    case parseError
    case controlURLNotFound
}
