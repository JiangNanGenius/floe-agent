import Foundation
import FloeToolboxUtilities
#if os(iOS)
import AVFoundation
#endif

public enum ToolboxSoundPhase: String, Sendable, Equatable {
    case idle, starting, running, stopping
}

/// Microphone authorization mirrored without exposing AVFoundation types to the
/// cross-platform surface.
public enum ToolboxSoundAuthorization: String, Sendable, Equatable {
    case notDetermined, granted, denied
    public var isGranted: Bool { self == .granted }
}

/// Who owns the shared `AVAudioSession` while the instrument runs. The App host
/// injects its lease through the view (`acquireAudio`/`releaseAudio`) and picks
/// `.hostManaged`; standalone previews measure with a locally owned session.
public enum ToolboxSoundSessionOwnership: String, Sendable, Equatable {
    /// The service sets `.record` + `.mixWithOthers` on the shared session and
    /// deactivates only that own activation on stop. Never touches the output
    /// route and never forces a category over another feature.
    case standalone
    /// A host lease owns the session; the service must not mutate category or
    /// activation at all.
    case hostManaged
}

/// One retained analysis result. Levels are relative digital full-scale values,
/// never calibrated sound-pressure levels.
public struct ToolboxSoundSample: Sendable, Equatable {
    /// Seconds since the measurement started (retained across pause/resume until reset).
    public let timestamp: TimeInterval
    public let levelDBFS: Double
    public let peakDBFS: Double
    /// Dominant frequency in Hz; nil when no clear tone was present.
    public let dominantFrequency: Double?
    public init(timestamp: TimeInterval, levelDBFS: Double, peakDBFS: Double, dominantFrequency: Double?) {
        self.timestamp = timestamp
        self.levelDBFS = levelDBFS
        self.peakDBFS = peakDBFS
        self.dominantFrequency = dominantFrequency
    }
}

/// Display-ready spectrum: `bands` are linear 0...1 heights (dB-mapped) aligned
/// with `bandFrequencies` in Hz, log-spaced across the audible input range.
public struct ToolboxSoundSpectrum: Sendable, Equatable {
    public let bands: [Float]
    public let bandFrequencies: [Double]
    public init(bands: [Float], bandFrequencies: [Double]) {
        self.bands = bands
        self.bandFrequencies = bandFrequencies
    }
}

/// Typed start/capture failures. Views map these to localized state notes; the
/// diagnostic string stays out of user-facing copy.
public enum ToolboxSoundError: Error, Equatable {
    case microphoneNotAuthorized
    case microphoneUnavailable
    case invalidInputFormat
    case mediaServicesReset

    /// Diagnostic text for logs/hints only; user-facing copy is localized by the view.
    public var diagnosticDescription: String {
        switch self {
        case .microphoneNotAuthorized: return "Microphone access is not authorized."
        case .microphoneUnavailable: return "No microphone input is available."
        case .invalidInputFormat: return "The microphone input format is invalid."
        case .mediaServicesReset: return "Media services were reset."
        }
    }
}

#if os(iOS)

/// Microphone analyzer with an explicit user start. The engine tap copies PCM off
/// the realtime thread into a bounded one-deep relay; a serial queue computes
/// RMS/peak dBFS and an FFT spectrum, and every publish is fenced by a generation
/// counter. Stop removes the tap, stops the engine, then releases only what this
/// service owns — the shared session is touched only in `.standalone` mode.
@MainActor @Observable public final class ToolboxSoundService {
    public static let shared = ToolboxSoundService()

    public private(set) var phase: ToolboxSoundPhase = .idle
    public private(set) var authorization: ToolboxSoundAuthorization
    /// Current smoothed relative level in dBFS; nil before the first frame.
    public private(set) var levelDBFS: Double?
    /// Loudest frame peak since the last reset, in dBFS.
    public private(set) var peakDBFS: Double?
    /// Dominant frequency of the latest frame; nil for silence or no clear tone.
    public private(set) var dominantFrequency: Double?
    public private(set) var spectrum: ToolboxSoundSpectrum?
    /// Last engine/capture error; cleared on the next successful start.
    public private(set) var streamError: String?
    /// Set while a phone-call style interruption suspends capture; resumes only
    /// when the system says the interruption ended with resume allowed.
    public private(set) var isInterrupted = false

    /// ~5 minutes at the ~2 Hz retained cadence; oldest samples drop off.
    public let historyCapacity = 600
    public private(set) var history = SignalSampleBuffer<ToolboxSoundSample>(capacity: 600)

    private let engine = AVAudioEngine()
    /// Fixed analysis frame; power of two for the FFT.
    private let analysisFrameSize = 4096
    private let analysisQueue = DispatchQueue(label: "com.floe.toolbox.sound.analysis", qos: .userInitiated)
    private let relay = SoundFrameRelay()
    private var tapInstalled = false
    private var generation = 0
    private var measurementStart: Date?
    private var sessionOwnership: ToolboxSoundSessionOwnership = .standalone
    private var standaloneSessionActive = false
    private var observerTokens: [NSObjectProtocol] = []

    public init() {
        authorization = Self.currentAuthorization()
    }

    public var isMicrophoneAvailable: Bool {
        !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
    }

    public func refreshAuthorization() {
        authorization = Self.currentAuthorization()
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        authorization = granted ? .granted : .denied
        return granted
    }

    /// Starts capture. The caller owns lease ordering: any host `acquireAudio`
    /// must run BEFORE this call, and the matching `releaseAudio` only after the
    /// service has stopped the engine (phase back to `.idle`).
    public func start(sessionOwnership: ToolboxSoundSessionOwnership) throws {
        guard phase == .idle else { return }
        refreshAuthorization()
        guard authorization == .granted else {
            throw ToolboxSoundError.microphoneNotAuthorized
        }
        self.sessionOwnership = sessionOwnership
        streamError = nil
        isInterrupted = false
        if measurementStart == nil { measurementStart = Date() }
        if sessionOwnership == .standalone {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            standaloneSessionActive = true
            // Validate the input route only after own activation: a session left
            // in a playback category can report no inputs even with a real
            // microphone present.
            guard !session.currentRoute.inputs.isEmpty else {
                deactivateStandaloneSession()
                throw ToolboxSoundError.microphoneUnavailable
            }
        } else {
            // The host lease already activated a record-capable session.
            guard isMicrophoneAvailable else {
                throw ToolboxSoundError.microphoneUnavailable
            }
        }
        generation += 1
        phase = .starting
        do {
            try startEngine(generation: generation)
            addSessionObservers()
            phase = .running
        } catch {
            stopEngine()
            deactivateStandaloneSession()
            phase = .idle
            throw error
        }
    }

    /// Stops capture, removes the tap and releases only locally owned session
    /// state. History, peak and spectrum are retained until `reset()`.
    public func pause() {
        generation += 1
        stopEngine()
        removeSessionObservers()
        deactivateStandaloneSession()
        isInterrupted = false
        phase = .idle
    }

    /// Clears retained history, session peak and spectrum; phase is unaffected.
    public func reset() {
        history.reset()
        peakDBFS = nil
        spectrum = nil
        levelDBFS = nil
        dominantFrequency = nil
    }

    /// Actual retained samples as CSV with honest dBFS columns.
    public func makeCSV() -> String {
        var lines = ["time_s,level_dbfs,peak_dbfs,dominant_hz"]
        for point in history.values {
            let frequency = point.dominantFrequency.map { String(format: "%.1f", $0) } ?? ""
            lines.append(String(format: "%.3f,%.1f,%.1f,%@",
                                point.timestamp, point.levelDBFS, point.peakDBFS, frequency))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Engine

    private func startEngine(generation streamGeneration: Int) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ToolboxSoundError.invalidInputFormat
        }
        let frameSize = analysisFrameSize
        let relay = self.relay
        let queue = analysisQueue
        let fft = EnvironmentalSignalFFT(frameSize: frameSize)
        let core = SoundAnalysisCore(sampleRate: format.sampleRate, fft: fft,
                                     frameSize: frameSize)
        let tap = Self.makeInputTap(maxFrames: frameSize * 2, relay: relay,
            analysisQueue: queue, core: core, generation: streamGeneration,
            currentGeneration: { [weak self] in self?.generation },
            receive: { [weak self] result in
                guard let self, self.phase != .idle else { return }
                self.publish(result)
            })
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(frameSize * 2),
                         format: format, block: tap)
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// AVFAudio invokes its legacy, non-Sendable tap block on a realtime thread.
    /// Build the actual callback outside MainActor isolation, copying SDK values
    /// before handing a bounded PCM frame to the analysis queue.
    nonisolated static func makeInputTap(
        maxFrames: Int, relay: SoundFrameRelay, analysisQueue: DispatchQueue,
        core: SoundAnalysisCore, generation streamGeneration: Int,
        currentGeneration: @escaping @MainActor @Sendable () -> Int?,
        receive: @escaping @MainActor @Sendable (SoundAnalysisCore.Result) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in
            guard let frame = Self.copyMonoFrame(buffer, maxFrames: maxFrames) else { return }
            // Realtime thread: bounded one-deep handoff, never a growing queue.
            guard relay.offer(frame) else { return }
            analysisQueue.async { @Sendable in
                guard let frame = relay.take() else { return }
                defer { relay.complete() }
                guard let result = core.process(frame) else { return }
                Task { @MainActor in
                    guard currentGeneration() == streamGeneration else { return }
                    receive(result)
                }
            }
        }
    }

    /// Copies mono PCM within the realtime callback. Stereo input averages channels;
    /// frames are bounded so a broken driver cannot grow memory.
    nonisolated private static func copyMonoFrame(_ buffer: AVAudioPCMBuffer, maxFrames: Int) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = min(Int(buffer.frameLength), maxFrames)
        guard frames > 0 else { return nil }
        if buffer.format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var frame = [Float](repeating: 0, count: frames)
        let channelCount = min(Int(buffer.format.channelCount), 2)
        for index in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][index] }
            frame[index] = sum / Float(channelCount)
        }
        return frame
    }

    private func publish(_ result: SoundAnalysisCore.Result) {
        levelDBFS = result.levelDBFS
        peakDBFS = max(peakDBFS ?? result.peakDBFS, result.peakDBFS)
        dominantFrequency = result.dominantFrequency
        spectrum = result.spectrum
        if result.appendToHistory, let start = measurementStart {
            history.append(ToolboxSoundSample(timestamp: Date().timeIntervalSince(start),
                                              levelDBFS: result.levelDBFS,
                                              peakDBFS: peakDBFS ?? result.peakDBFS,
                                              dominantFrequency: result.dominantFrequency))
        }
        if phase == .starting { phase = .running }
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        relay.reset()
    }

    // MARK: - Session events

    private func addSessionObservers() {
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
                // Only Sendable values cross into the main-actor task.
                let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleRouteChange() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
            }
        ]
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        for token in observerTokens { center.removeObserver(token) }
        observerTokens = []
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard phase == .running || phase == .starting,
              let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            isInterrupted = true
            generation += 1
            stopEngine()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            guard options.contains(.shouldResume), isInterrupted else { return }
            isInterrupted = false
            generation += 1
            do {
                try startEngine(generation: generation)
                phase = .running
            } catch {
                streamError = error.localizedDescription
                pause()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange() {
        guard phase == .running else { return }
        guard isMicrophoneAvailable else {
            streamError = ToolboxSoundError.microphoneUnavailable.diagnosticDescription
            pause()
            return
        }
        // Input route/sample rate changed: re-install the tap with the new format.
        generation += 1
        stopEngine()
        do {
            try startEngine(generation: generation)
            phase = .running
        } catch {
            streamError = error.localizedDescription
            pause()
        }
    }

    private func handleMediaServicesReset() {
        guard phase != .idle else { return }
        streamError = ToolboxSoundError.mediaServicesReset.diagnosticDescription
        pause()
    }

    private func deactivateStandaloneSession() {
        guard standaloneSessionActive else { return }
        standaloneSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func currentAuthorization() -> ToolboxSoundAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// One-deep handoff between the realtime tap and the analysis queue.
final class SoundFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float]?
    private var busy = false

    func offer(_ frame: [Float]) -> Bool {
        lock.withLock {
            guard !busy, pending == nil else { return false }
            pending = frame
            busy = true
            return true
        }
    }

    func take() -> [Float]? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    func complete() {
        lock.withLock { busy = false }
    }

    func reset() {
        lock.withLock {
            pending = nil
            busy = false
        }
    }
}

/// Per-stream analysis state. The lock protects the FFT scratch buffers and
/// cadence/smoothing state; production also uses a serial analysis queue.
final class SoundAnalysisCore: @unchecked Sendable {
    struct Result: Sendable {
        let levelDBFS: Double
        let peakDBFS: Double
        let dominantFrequency: Double?
        let spectrum: ToolboxSoundSpectrum
        let appendToHistory: Bool
    }

    private let lock = NSLock()
    private let sampleRate: Double
    private let fft: EnvironmentalSignalFFT?
    private let frameSize: Int
    private let bandPlan: [(lowBin: Int, highBin: Int, centerHz: Double)]
    private var smoothedDB = EnvironmentalSignalMath.dbFloor
    private var frameCounter = 0

    /// Tones quieter than this (relative amplitude after the 2/N scale) report no
    /// dominant frequency instead of inventing one from the noise floor.
    private let minimumDetectableAmplitude: Float = 1e-4

    init(sampleRate: Double, fft: EnvironmentalSignalFFT?, frameSize: Int) {
        self.sampleRate = sampleRate
        self.fft = fft
        self.frameSize = frameSize
        self.bandPlan = Self.makeBandPlan(binCount: (fft?.binCount ?? frameSize / 2) + 1,
                                          sampleRate: sampleRate, frameSize: frameSize)
    }

    /// 40 log-spaced bands from 20 Hz to min(nyquist, 16 kHz).
    private static func makeBandPlan(binCount: Int, sampleRate: Double,
                                     frameSize: Int) -> [(lowBin: Int, highBin: Int, centerHz: Double)] {
        let nyquist = sampleRate / 2
        let topHz = min(nyquist * 0.95, 16_000)
        guard topHz > 20 else { return [] }
        let bandCount = 40
        let ratio = pow(topHz / 20, 1 / Double(bandCount))
        var plan: [(lowBin: Int, highBin: Int, centerHz: Double)] = []
        var lowHz = 20.0
        for _ in 0..<bandCount {
            let highHz = min(lowHz * ratio, topHz)
            let lowBin = max(1, Int((lowHz * Double(frameSize) / sampleRate).rounded(.down)))
            let highBin = min(binCount - 2, max(lowBin, Int((highHz * Double(frameSize) / sampleRate).rounded(.up))))
            let centerHz = (lowHz * highHz).squareRoot()
            plan.append((lowBin, highBin, centerHz))
            lowHz = highHz
            if highHz >= topHz { break }
        }
        return plan
    }

    func process(_ frame: [Float]) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        frameCounter += 1
        guard let rms = EnvironmentalSignalMath.rms(frame) else { return nil }
        let instantaneous = EnvironmentalSignalMath.dbFS(rms: rms)
        // Fast attack, slow release so the level reads steady without hiding peaks.
        smoothedDB = instantaneous > smoothedDB
            ? instantaneous
            : smoothedDB + (instantaneous - smoothedDB) * 0.25
        let peak = EnvironmentalSignalMath.peak(frame) ?? 0
        let peakDB = EnvironmentalSignalMath.dbFS(rms: Double(peak))
        var dominant: Double?
        var spectrum = ToolboxSoundSpectrum(bands: [], bandFrequencies: [])
        if let fft {
            let (magnitudes, frequency) = fft.analyze(samples: frame, sampleRate: sampleRate,
                                                      minAmplitude: minimumDetectableAmplitude)
            dominant = frequency
            var bands = [Float]()
            var centers = [Double]()
            bands.reserveCapacity(bandPlan.count)
            centers.reserveCapacity(bandPlan.count)
            for band in bandPlan {
                var magnitude: Float = 0
                for bin in band.lowBin...band.highBin where magnitudes[bin] > magnitude {
                    magnitude = magnitudes[bin]
                }
                bands.append(Self.displayUnit(magnitude: magnitude))
                centers.append(band.centerHz)
            }
            spectrum = ToolboxSoundSpectrum(bands: bands, bandFrequencies: centers)
        }
        return Result(levelDBFS: smoothedDB, peakDBFS: peakDB, dominantFrequency: dominant,
                      spectrum: spectrum, appendToHistory: frameCounter % 5 == 0)
    }

    /// dB-mapped display height: -100 dB → 0, 0 dB → 1.
    private static func displayUnit(magnitude: Float) -> Float {
        guard magnitude > 0 else { return 0 }
        let db = 20 * log10(Double(magnitude))
        return Float(min(max((db + 100) / 100, 0), 1))
    }
}

#else

/// macOS keeps the same public surface with honest unavailability; the analysis
/// math itself lives in FloeToolboxUtilities and is covered by shared tests.
@MainActor public final class ToolboxSoundService {
    public static let shared = ToolboxSoundService()

    public private(set) var phase: ToolboxSoundPhase = .idle
    public private(set) var authorization: ToolboxSoundAuthorization = .denied
    public private(set) var levelDBFS: Double?
    public private(set) var peakDBFS: Double?
    public private(set) var dominantFrequency: Double?
    public private(set) var spectrum: ToolboxSoundSpectrum?
    public private(set) var streamError: String?
    public private(set) var isInterrupted = false
    public let historyCapacity = 600
    public private(set) var history = SignalSampleBuffer<ToolboxSoundSample>(capacity: 600)

    public init() {}
    public var isMicrophoneAvailable: Bool { false }
    public func refreshAuthorization() {}
    public func requestAuthorization() async -> Bool { false }
    public func start(sessionOwnership: ToolboxSoundSessionOwnership) throws {
        throw ToolboxSoundError.microphoneUnavailable
    }
    public func pause() {}
    public func reset() {}
    public func makeCSV() -> String { "time_s,level_dbfs,peak_dbfs,dominant_hz\n" }
}

#endif
