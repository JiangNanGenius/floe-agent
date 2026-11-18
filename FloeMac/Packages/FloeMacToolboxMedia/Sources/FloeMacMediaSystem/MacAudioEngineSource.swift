import Foundation
import AVFoundation
import FloeMacMediaCore

/// Observes only the owning engine. Callbacks may arrive on an audio system
/// queue, so the callback never performs engine teardown synchronously.
final class MacAudioConfigurationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private let onChange: @Sendable () -> Void
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var signaled = false

    init(center: NotificationCenter = .default, object: AnyObject,
         onChange: @escaping @Sendable () -> Void) {
        self.center = center
        self.onChange = onChange
        observer = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                      object: object, queue: nil) { [weak self] _ in
            self?.receive()
        }
    }
    private func receive() {
        let first = lock.withLock {
            guard !stopped, !signaled else { return false }
            signaled = true
            return true
        }
        guard first else { return }
        onChange()
    }
    func stop() {
        let token = lock.withLock {
            stopped = true
            let token = observer
            observer = nil
            return token
        }
        if let token { center.removeObserver(token) }
    }
    deinit { stop() }
}

/// Opens the default Mac microphone. Probing availability never opens a stream
/// and never triggers a permission prompt.
public final class MacAudioInputProvider: MacAudioInputProviding, @unchecked Sendable {
    public let frameSize: Int

    public init(frameSize: Int = MacSoundAnalyzer.defaultFrameSize) {
        self.frameSize = frameSize
    }

    public func inputAvailable() -> Bool {
        // `AVCaptureDevice.default(for: .audio)` is the longest-supported
        // macOS probe and does not open a stream or prompt for permission.
        AVCaptureDevice.default(for: .audio) != nil
    }

    public func makeSource() throws -> any MacAudioInputSource {
        guard inputAvailable() else { throw MacMediaFailure.noDevice }
        return MacAudioEngineSource(frameSize: frameSize)
    }
}

/// One-shot `AVAudioEngine` tap. The engine is created per start and is never
/// reused after `stop()`, so no configuration from a previous device survives a
/// restart. PCM is copied on the realtime thread into a one-deep relay; the
/// analyzer runs only on its own serial queue.
public final class MacAudioEngineSource: NSObject, MacAudioInputSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let frameSize: Int
    private let analysisQueue = DispatchQueue(label: "org.floe.mac.toolbox.sound.analysis", qos: .userInitiated)
    private let relay = MacAudioFrameRelay()
    private let stateLock = NSLock()
    private var stopped = false
    private var tapInstalled = false
    private var analyzer: MacSoundAnalyzer?
    private var sampleRate: Double = 0
    private var expectedChannels: AVAudioChannelCount = 0
    private var reportedFailure = false
    private var configurationMonitor: MacAudioConfigurationMonitor?

    public init(frameSize: Int) {
        self.frameSize = frameSize
        super.init()
    }

    public func start(
        onReading: @escaping @Sendable (MacSoundReading) -> Void,
        onFailure: @escaping @Sendable (MacMediaFailure) -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate >= 8_000, format.sampleRate <= 768_000,
              format.channelCount > 0 else {
            throw MacMediaFailure.invalidFormat
        }
        guard let analyzer = MacSoundAnalyzer(sampleRate: format.sampleRate, frameSize: frameSize) else {
            throw MacMediaFailure.invalidFormat
        }
        self.analyzer = analyzer
        self.sampleRate = format.sampleRate
        self.expectedChannels = format.channelCount

        let maxFrames = frameSize * 2
        let relay = self.relay
        let analysisQueue = self.analysisQueue
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self, !self.isStopped() else { return }
            // A device/format switch arrives as a new buffer format. Report it
            // once instead of analyzing mismatched PCM and publishing a
            // plausible-looking but wrong spectrum.
            if abs(buffer.format.sampleRate - self.sampleRate) > 1
                || buffer.format.channelCount != self.expectedChannels {
                self.reportFailure(.mediaServicesReset, onFailure: onFailure)
                return
            }
            let frame: [Float]
            do {
                guard let copied = try Self.copyMonoFrame(buffer, maxFrames: maxFrames) else { return }
                frame = copied
            } catch {
                self.reportFailure(.invalidFormat, onFailure: onFailure)
                return
            }
            guard relay.offer(frame) else { return }
            analysisQueue.async {
                guard let frame = relay.take() else { return }
                defer { relay.complete() }
                guard !self.isStopped() else { return }
                guard let result = analyzer.process(frame) else { return }
                onReading(result)
            }
        }

        configurationMonitor = MacAudioConfigurationMonitor(object: engine) { [weak self] in
            self?.reportFailure(.mediaServicesReset, onFailure: onFailure)
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(maxFrames), format: format, block: tap)
        withStateLock { tapInstalled = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw MacMediaFailure.engine(String(String(describing: error).prefix(200)))
        }
        guard engine.isRunning else {
            stop()
            throw MacMediaFailure.engine("engine-not-running")
        }
    }

    public func stop() {
        let shouldStop = withStateLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop {
            configurationMonitor?.stop()
            configurationMonitor = nil
            if withStateLock({ tapInstalled }) {
                engine.inputNode.removeTap(onBus: 0)
                withStateLock { tapInstalled = false }
            }
        }
        engine.stop()
        relay.reset()
        // Device worker, never the analysis queue. A completion here includes
        // already queued analysis callbacks and their stale-generation fence.
        analysisQueue.sync {}
    }

    public var stopConfirmed: Bool {
        withStateLock { stopped && !tapInstalled } && !engine.isRunning
    }

    deinit {
        configurationMonitor?.stop()
        if withStateLock({ tapInstalled }) {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    // MARK: - Internals

    private func isStopped() -> Bool {
        withStateLock { stopped }
    }

    private func reportFailure(
        _ failure: MacMediaFailure,
        onFailure: @escaping @Sendable (MacMediaFailure) -> Void
    ) {
        let first = withStateLock { () -> Bool in
            guard !stopped, !reportedFailure else { return false }
            reportedFailure = true
            return true
        }
        guard first else { return }
        onFailure(failure)
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Copies mono PCM inside the realtime callback. Stereo input averages the
    /// first two channels; frames are bounded so a broken driver cannot grow
    /// memory.
    static func copyMonoFrame(_ buffer: AVAudioPCMBuffer, maxFrames: Int) throws -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount > 0, buffer.stride > 0,
              let channels = buffer.floatChannelData else { throw MacMediaFailure.invalidFormat }
        let frames = max(0, min(Int(buffer.frameLength), maxFrames))
        guard frames > 0 else { return nil }
        let stride = Int(buffer.stride)
        var frame = [Float](repeating: 0, count: frames)
        let channelCount = min(Int(buffer.format.channelCount), 2)
        for index in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][index * stride] }
            frame[index] = sum / Float(channelCount)
        }
        return frame
    }
}

/// One-deep handoff between the realtime tap and the analysis queue.
final class MacAudioFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float]?
    private var busy = false

    func offer(_ frame: [Float]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy, pending == nil else { return false }
        pending = frame
        busy = true
        return true
    }

    func take() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }

    func complete() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    func reset() {
        lock.lock()
        pending = nil
        busy = false
        lock.unlock()
    }
}
