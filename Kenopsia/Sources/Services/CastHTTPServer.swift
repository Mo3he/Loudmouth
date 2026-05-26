#if canImport(GoogleCast)
import Foundation
import Network

// MARK: - CastHTTPServer
/// Minimal HTTP/1.1 server that serves a single local audio file over the local
/// network so a Chromecast receiver (which requires a reachable URL) can pull the
/// audio directly from this device.
///
/// Only one file is registered at a time; the Chromecast buffers the content
/// itself, so there is no need to support concurrent multi-file serving.
///
/// The server binds on all interfaces at a fixed port (9087). The Chromecast and
/// the iPhone must be on the same Wi-Fi network for the URL to be reachable.
actor CastHTTPServer {

    // MARK: - Singleton
    static let shared = CastHTTPServer()

    // MARK: - Constants
    private let port: UInt16 = 9087

    // MARK: - State
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The single file currently being served: (URL path component, file URL on disk).
    private var servedFile: (path: String, fileURL: URL, mimeType: String)?

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        servedFile = nil
    }

    // MARK: - File registration

    /// Registers `fileURL` for serving and returns the HTTP URL the Chromecast should
    /// use to fetch it. Returns nil if the device's local IPv4 address is unavailable
    /// (e.g. not connected to Wi-Fi).
    func register(fileURL: URL, trackID: UUID, format: AudioFormat) -> URL? {
        guard let ip = localIPv4Address() else {
            print("[CastHTTP] register() FAILED - could not determine local IPv4 address")
            return nil
        }
        let ext = format.fileExtension
        let path = "/cast/\(trackID.uuidString).\(ext)"
        servedFile = (path: path, fileURL: fileURL, mimeType: format.mimeType)
        let url = URL(string: "http://\(ip):\(port)\(path)")!
        print("[CastHTTP] Registered file. Serving at: \(url)")
        return url
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.remove(id: id) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, id: id)
    }

    private func remove(id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
    }

    private func receiveRequest(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { await self?.handleRequest(data: data, connection: connection, id: id) }
        }
    }

    private func handleRequest(data: Data?, connection: NWConnection, id: ObjectIdentifier) {
        guard let data, let request = String(data: data, encoding: .utf8) else {
            connection.cancel(); remove(id: id); return
        }

        // Parse method and path from the first request line ("GET /path HTTP/1.1").
        let lines = request.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); remove(id: id); return }

        let method = parts[0]
        let requestPath = parts[1]

        // Parse optional Range header (e.g. "Range: bytes=0-1023").
        var rangeStart: Int? = nil
        var rangeEnd: Int? = nil
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("range: bytes=") {
                let rangeStr = line.dropFirst("range: bytes=".count)
                let rangeParts = rangeStr.components(separatedBy: "-")
                rangeStart = Int(rangeParts[0].trimmingCharacters(in: .whitespaces))
                if rangeParts.count > 1, !rangeParts[1].trimmingCharacters(in: .whitespaces).isEmpty {
                    rangeEnd = Int(rangeParts[1].trimmingCharacters(in: .whitespaces))
                }
            }
        }

        print("[CastHTTP] \(method) \(requestPath) rangeStart=\(rangeStart?.description ?? "none")")

        guard let (servedPath, fileURL, mimeType) = servedFile, requestPath == servedPath else {
            print("[CastHTTP] 404 for \(requestPath) (serving: \(servedFile?.path ?? "nothing"))")
            send(status: 404, headers: [], body: nil, on: connection, id: id)
            return
        }

        if method == "HEAD" {
            let fileSize = fileSizeBytes(at: fileURL)
            send(status: 200,
                 headers: ["Content-Length: \(fileSize)", "Content-Type: \(mimeType)",
                           "Accept-Ranges: bytes", "Access-Control-Allow-Origin: *"],
                 body: nil,
                 on: connection,
                 id: id)
        } else {
            sendFile(at: fileURL, mimeType: mimeType,
                     rangeStart: rangeStart, rangeEnd: rangeEnd,
                     on: connection, id: id)
        }
    }

    // MARK: - Response helpers

    private func sendFile(
        at fileURL: URL,
        mimeType: String,
        rangeStart: Int?,
        rangeEnd: Int?,
        on connection: NWConnection,
        id: ObjectIdentifier
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            // .mappedIfSafe uses memory-mapped I/O so the OS pages file data on
            // demand rather than loading the entire file into the heap at once.
            guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                await self?.send(status: 404, headers: [], body: nil, on: connection, id: id)
                return
            }
            let totalSize = fileData.count
            let start = rangeStart ?? 0
            let end = min(rangeEnd ?? (totalSize - 1), totalSize - 1)
            guard start <= end, start < totalSize else {
                await self?.send(status: 416, headers: ["Content-Range: bytes */\(totalSize)"], body: nil, on: connection, id: id)
                return
            }
            let slice = fileData[start...end]
            let body = Data(slice)

            if rangeStart != nil {
                await self?.send(
                    status: 206,
                    headers: [
                        "Content-Length: \(body.count)",
                        "Content-Type: \(mimeType)",
                        "Content-Range: bytes \(start)-\(end)/\(totalSize)",
                        "Accept-Ranges: bytes",
                        "Access-Control-Allow-Origin: *"
                    ],
                    body: body,
                    on: connection,
                    id: id
                )
            } else {
                await self?.send(
                    status: 200,
                    headers: [
                        "Content-Length: \(body.count)",
                        "Content-Type: \(mimeType)",
                        "Accept-Ranges: bytes",
                        "Access-Control-Allow-Origin: *"
                    ],
                    body: body,
                    on: connection,
                    id: id
                )
            }
        }
    }

    private func send(
        status: Int,
        headers: [String],
        body: Data?,
        on connection: NWConnection,
        id: ObjectIdentifier
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 404: reason = "Not Found"
        case 416: reason = "Range Not Satisfiable"
        default:  reason = "Error"
        }
        var headerLines = "HTTP/1.1 \(status) \(reason)\r\n"
        for h in headers { headerLines += "\(h)\r\n" }
        headerLines += "Connection: close\r\n\r\n"

        var responseData = headerLines.data(using: .utf8)!
        if let body { responseData.append(body) }

        connection.send(content: responseData, isComplete: true, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { await self?.remove(id: id) }
        })
    }

    // MARK: - Network helpers

    private func fileSizeBytes(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Returns the device's primary IPv4 address on Wi-Fi (en0) or the first
    /// active non-loopback IPv4 interface as fallback.
    private func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String? = nil
        var ptr = ifaddr
        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               let name = String(validatingUTF8: iface.ifa_name), name != "lo0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(iface.ifa_addr,
                            socklen_t(iface.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count),
                            nil, 0,
                            NI_NUMERICHOST)
                let ip = String(cString: host)
                if name == "en0" { return ip }   // prefer Wi-Fi
                if fallback == nil { fallback = ip }
            }
            ptr = current.pointee.ifa_next
        }
        return fallback
    }
}

#endif // canImport(GoogleCast)
