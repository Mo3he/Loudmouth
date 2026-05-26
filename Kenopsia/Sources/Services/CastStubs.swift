// CastStubs.swift
// No-op implementations of ChromecastService and CastHTTPServer used when the
// Google Cast SDK is not linked. When the SDK is available, add
// GOOGLE_CAST_AVAILABLE to Swift Active Compilation Conditions in project.yml
// and these stubs will be excluded automatically.

#if !canImport(GoogleCast)

import Foundation
import Combine

@MainActor
final class ChromecastService: ObservableObject {
    static let shared = ChromecastService()
    @Published private(set) var isCasting: Bool = false
    @Published private(set) var connectedDeviceName: String? = nil
    @Published private(set) var castPositionSeconds: Double = 0
    @Published private(set) var castDurationSeconds: Double = 0
    private init() {}
    static func setup() {}
    func cast(track: Track, streamURL: URL) {}
    func pause()  {}
    func resume() {}
    func stop()   {}
    func seek(to seconds: Double) {}
}

actor CastHTTPServer {
    static let shared = CastHTTPServer()
    private init() {}
    func start() async {}
    func stop()  async {}
    func register(fileURL: URL, trackID: UUID, format: AudioFormat) async -> URL? { nil }
}

#endif // !canImport(GoogleCast)
