import AVFoundation
import MediaPlayer

// MARK: - AudioEngine
/// Wraps AVAudioEngine to provide:
/// - Gapless playback via double-buffered scheduling
/// - 10-band parametric EQ (AVAudioUnitEQ)
/// - ReplayGain / EBU R128 volume normalisation
/// - Crossfade with configurable curve
///
/// The engine is intentionally not @Observable — callers go through PlaybackService.
final class AudioEngine {
    // MARK: - Engine graph
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let timePitch = AVAudioUnitTimePitch()

    // Two players so we can pre-schedule the next track for gapless transitions.
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    var activePlayer: AVAudioPlayerNode { isUsingPlayerA ? playerA : playerB }
    private var stagingPlayer: AVAudioPlayerNode { isUsingPlayerA ? playerB : playerA }
    private var isUsingPlayerA = true

    // MARK: - State
    private(set) var isRunning = false
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue.clamped(to: 0...1) }
    }

    // MARK: - Crossfade
    var crossfadeDuration: TimeInterval = 3.0   // seconds; 0 = gapless, no fade
    var crossfadeCurve: CrossfadeCurve = .equalPower

    // MARK: - Init
    init() {
        buildGraph()
        configureAudioSession()
    }

    // MARK: - Graph construction
    private func buildGraph() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(eq)
        engine.attach(timePitch)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerA,   to: eq,                    format: format)
        engine.connect(playerB,   to: eq,                    format: format)
        engine.connect(eq,        to: timePitch,             format: format)
        engine.connect(timePitch, to: engine.mainMixerNode,  format: format)

        // Provide a tap on the main output for visualisation (future use).
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] _, _ in
            // Reserved for spectrum analyser / VU meter
            _ = self
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
        try? session.setActive(true)
    }

    // MARK: - Playback control
    func start() throws {
        guard !isRunning else { return }
        try engine.start()
        isRunning = true
    }

    func stop() {
        playerA.stop()
        playerB.stop()
        engine.stop()
        isRunning = false
    }

    /// Schedule a file for the active player and start playback.
    func play(file: AVAudioFile, replayGainDB: Float? = nil, at time: AVAudioTime? = nil) throws {
        try ensureRunning()
        applyReplayGain(replayGainDB)
        activePlayer.stop()
        activePlayer.scheduleFile(file, at: time, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.handlePlaybackCompletion()
        }
        activePlayer.play()
        setupNowPlaying()
    }

    /// Pre-schedule the next track on the staging player so it's ready for gapless handoff.
    func scheduleNext(file: AVAudioFile) {
        stagingPlayer.stop()
        stagingPlayer.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.handlePlaybackCompletion()
        }
    }

    /// Swap players for gapless / crossfade transition.
    func transition(crossfade: Bool = false) {
        if crossfade && crossfadeDuration > 0 {
            crossfadeToStaging()
        } else {
            // True gapless: staging player was pre-scheduled; just start it.
            stagingPlayer.play()
            activePlayer.stop()
        }
        isUsingPlayerA.toggle()
    }

    // MARK: - EQ
    func applyEQPreset(_ preset: EQPreset) {
        for (i, band) in preset.bands.enumerated() {
            guard i < eq.bands.count else { break }
            let b = eq.bands[i]
            b.frequency  = band.frequencyHz
            b.gain       = band.gainDB
            b.bandwidth  = 1.0 / band.qFactor
            b.filterType = .parametric
            b.bypass     = false
        }
    }

    func setEQGain(_ gainDB: Float, bandIndex: Int) {
        guard bandIndex < eq.bands.count else { return }
        eq.bands[bandIndex].gain = gainDB.clamped(to: -12...12)
    }

    // MARK: - ReplayGain
    private func applyReplayGain(_ gainDB: Float?) {
        guard let gainDB else {
            timePitch.rate = 1.0
            return
        }
        // Apply as a pre-gain on the time pitch node's volume.
        // +/- dB -> linear gain: 10^(dB/20)
        let linear = Float(pow(10.0, Double(gainDB) / 20.0))
        timePitch.rate = 1.0   // preserve pitch; only adjust volume
        // Volume is set on the active player directly.
        activePlayer.volume = linear.clamped(to: 0...2)
    }

    // MARK: - Crossfade
    private func crossfadeToStaging() {
        let steps = 60
        let stepDuration = crossfadeDuration / Double(steps)
        let active = activePlayer
        let staging = stagingPlayer
        let curve = crossfadeCurve
        staging.volume = 0
        staging.play()
        for i in 0...steps {
            let t = DispatchTime.now() + stepDuration * Double(i)
            DispatchQueue.main.asyncAfter(deadline: t) {
                let progress = Float(i) / Float(steps)   // 0 -> 1
                let (fadeOut, fadeIn) = curve.gains(at: progress)
                active.volume  = fadeOut
                staging.volume = fadeIn
            }
        }
    }

    // MARK: - Completion
    private func handlePlaybackCompletion() {
        // PlaybackService listens via a closure — hooked up post-init.
        onTrackDidFinish?()
    }

    var onTrackDidFinish: (() -> Void)?

    // MARK: - Helpers
    private func ensureRunning() throws {
        if !isRunning { try start() }
    }

    private func setupNowPlaying() {
        // Filled in by PlaybackService with track metadata.
    }
}

// MARK: - Float clamping helper
private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}

// MARK: - CrossfadeCurve
/// Controls the volume shape of the crossfade transition.
enum CrossfadeCurve: String, CaseIterable, Codable {
    /// Linear: outgoing fades 1→0, incoming fades 0→1 at equal rate.
    case linear
    /// Equal-power: uses sqrt curves so perceived loudness stays constant through the crossfade.
    /// This is the standard DJ/broadcast curve and avoids the "dip" in the middle.
    case equalPower
    /// S-curve: slow start, fast middle, slow end — smooth for orchestral music.
    case sCurve

    var displayName: String {
        switch self {
        case .linear:     "Linear"
        case .equalPower: "Equal Power"
        case .sCurve:     "S-Curve"
        }
    }

    /// Returns (fadeOut, fadeIn) gain values [0…1] for a normalised position `t` in [0…1].
    func gains(at t: Float) -> (out: Float, in: Float) {
        switch self {
        case .linear:
            return (1 - t, t)
        case .equalPower:
            // cos/sin quarter-wave: both channels sum to constant RMS power
            let angle = t * .pi / 2
            return (cos(angle), sin(angle))
        case .sCurve:
            // Smoothstep applied to both channels
            let fadeIn  = t * t * (3 - 2 * t)
            let fadeOut = 1 - fadeIn
            return (fadeOut, fadeIn)
        }
    }
}
