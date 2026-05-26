import os

/// Lightweight structured logger for the playback pipeline.
/// All log calls are no-ops in release builds (os.Logger .debug level is compile-stripped).
/// View output in Xcode console or macOS Console.app — filter by subsystem "net.mohome.kenopsia".
enum PLog {
    static let engine     = Logger(subsystem: "net.mohome.kenopsia", category: "AudioEngine")
    static let service    = Logger(subsystem: "net.mohome.kenopsia", category: "PlaybackService")
    static let scheduler  = Logger(subsystem: "net.mohome.kenopsia", category: "Scheduler")
    static let stall      = Logger(subsystem: "net.mohome.kenopsia", category: "StallDetector")
}
