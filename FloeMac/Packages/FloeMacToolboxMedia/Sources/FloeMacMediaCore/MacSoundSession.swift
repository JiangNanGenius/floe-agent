import Foundation
import Observation
import FloeToolboxUtilities

public enum MacSoundPhase: String, Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping

    public var isActive: Bool { self == .starting || self == .running || self == .stopping }
}

/// A started microphone stream. Implementations own their realtime queue and
/// must deliver readings independently of the main actor. `stop()` is
/// idempotent and must remove the input tap before returning.
public protocol MacAudioInputSource: AnyObject, Sendable {
    /// Starts sampling. `onFailure` reports a device loss/configuration change
    /// after start; the session stops and releases the lease when it fires.
    func start(
        onReading: @escaping @Sendable (MacSoundReading) -> Void,
        onFailure: @escaping @Sendable (MacMediaFailure) -> Void
    ) throws
    func stop()
    /// True only when the source has confirmed its platform stream is stopped.
    var stopConfirmed: Bool { get }
}

public extension MacAudioInputSource {
    var stopConfirmed: Bool { false }
}

/// Opens the platform input. `inputAvailable()` must not open a stream or show
/// a permission prompt; it only probes whether an input device exists.
public protocol MacAudioInputProviding: Sendable {
    func inputAvailable() -> Bool
    func makeSource() throws -> MacAudioInputSource
}

/// Serializes potentially blocking device operations away from the main actor.
/// Invalidation is a short locked write; the lease stays held until stop returns.
private final class MacAudioWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.floe.mac.toolbox.sound.device")
    private let lock = NSLock()
    // The queue serializes the entire admitted start and its later stop.
    // A start claimed by the final `permitted` read is in flight; cancellation
    // cannot complete until the queued start and subsequent stop have drained.
    private let admissionLock = NSLock()
    private var active = true
    private var source: (any MacAudioInputSource)? // device queue only

    func invalidate() { lock.withLock { active = false } }
    private var permitted: Bool { lock.withLock { active } }

    func start(provider: any MacAudioInputProviding,
               onReading: @escaping @Sendable (MacSoundReading) -> Void,
               onFailure: @escaping @Sendable (MacMediaFailure) -> Void) async -> Result<Void, MacMediaFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard permitted else { continuation.resume(returning: .failure(.engine("cancelled"))); return }
                do {
                    let made = try provider.makeSource()
                    source = made
                    admissionLock.lock()
                    let admitted = permitted
                    guard admitted else {
                        admissionLock.unlock()
                        continuation.resume(returning: .failure(.engine("cancelled")))
                        return
                    }
                    do {
                        try made.start(onReading: onReading, onFailure: onFailure)
                        admissionLock.unlock()
                    } catch {
                        admissionLock.unlock()
                        throw error
                    }
                    continuation.resume(returning: .success(()))
                } catch let failure as MacMediaFailure {
                    continuation.resume(returning: .failure(failure))
                } catch {
                    continuation.resume(returning: .failure(.engine(String(String(describing: error).prefix(200)))))
                }
            }
        }
    }

    func stop() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                source?.stop()
                let confirmed = source?.stopConfirmed ?? true
                if confirmed { source = nil }
                continuation.resume(returning: confirmed)
            }
        }
    }
}

/// One pending reading and at most one main-actor drain for each run. New
/// readings replace older ones while the consumer is busy.
final class MacSoundLatestReadingRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var pending: MacSoundReading?
    private var draining = false
    private var failureClaimed = false

    /// True only for the producer that must schedule the single drain.
    func offer(_ reading: MacSoundReading) -> Bool {
        lock.withLock {
            guard active else { return false }
            if let previous = pending {
                pending = MacSoundReading(
                    levelDBFS: reading.levelDBFS,
                    peakDBFS: max(previous.peakDBFS, reading.peakDBFS),
                    dominantFrequency: reading.dominantFrequency,
                    spectrum: reading.spectrum,
                    appendToHistory: previous.appendToHistory || reading.appendToHistory
                )
            } else {
                pending = reading
            }
            guard !draining else { return false }
            draining = true
            return true
        }
    }

    func take() -> MacSoundReading? {
        lock.withLock {
            guard active, let value = pending else {
                pending = nil
                draining = false
                return nil
            }
            pending = nil
            return value
        }
    }

    func invalidate() {
        lock.withLock { active = false; pending = nil }
    }

    func claimFailure() -> Bool {
        lock.withLock {
            guard active, !failureClaimed else { return false }
            failureClaimed = true
            return true
        }
    }
}

/// Explicit-start microphone analyzer. Permission is only requested when the
/// user presses Start, the device lease is only held while sampling, and every
/// stop path (stop button, window close, app background, start failure) stops
/// the stream and returns the lease. Late frames and late permission answers
/// are fenced by a monotonic run token.
@MainActor
@Observable
public final class MacSoundSession {
    public let historyCapacity: Int

    public private(set) var phase: MacSoundPhase = .idle
    public private(set) var authorization: MacMediaAuthorization
    /// Smoothed relative level in dBFS; nil before the first frame.
    public private(set) var levelDBFS: Double?
    /// Loudest frame peak since the last reset, in dBFS.
    public private(set) var peakDBFS: Double?
    public private(set) var dominantFrequency: Double?
    public private(set) var spectrum: MacSoundSpectrum?
    /// Stable failure code; cleared on the next successful start.
    public private(set) var streamFailure: MacMediaFailure?
    public private(set) var history: [MacSoundSample] = []
    public private(set) var droppedHistoryCount = 0
    public private(set) var lease: MacDeviceLease?
    /// True while the app must not tear the stream down for an inactivity
    /// change because a system permission prompt is expected.
    public private(set) var awaitingPermissionPrompt = false

    @ObservationIgnored private let authorizer: any MacMediaAuthorizing
    @ObservationIgnored private let broker: MacDeviceLeaseBroker
    @ObservationIgnored private let provider: any MacAudioInputProviding
    @ObservationIgnored private let ownerID: UUID
    @ObservationIgnored private var worker: MacAudioWorker?
    @ObservationIgnored private var readingRelay: MacSoundLatestReadingRelay?
    @ObservationIgnored private var stopTask: Task<Bool, Never>?
    @ObservationIgnored private var captureAvailability: @MainActor () -> Bool
    @ObservationIgnored private var runToken: UInt64 = 0
    @ObservationIgnored private var measurementStart: Date?
    @ObservationIgnored private var buffer: SignalSampleBuffer<MacSoundSample>

    public init(
        authorizer: any MacMediaAuthorizing,
        broker: MacDeviceLeaseBroker,
        provider: any MacAudioInputProviding,
        ownerID: UUID = UUID(),
        historyCapacity: Int = 600,
        captureAvailability: @escaping @MainActor () -> Bool = { false }
    ) {
        self.authorizer = authorizer
        self.broker = broker
        self.provider = provider
        self.ownerID = ownerID
        self.historyCapacity = historyCapacity
        self.captureAvailability = captureAvailability
        self.buffer = SignalSampleBuffer(capacity: historyCapacity)
        self.authorization = authorizer.authorization(for: .microphone)
    }

    public var isMicrophoneAvailable: Bool { provider.inputAvailable() }
    public var isActive: Bool { phase.isActive }
    public var hasLease: Bool { lease != nil }

    public func refreshAuthorization() {
        authorization = authorizer.authorization(for: .microphone)
    }

    /// The owning window supplies an activity/visibility predicate. Missing
    /// ownership is fail-closed. Closing the surface fences pending starts.
    public func setCaptureAvailability(_ predicate: @escaping @MainActor () -> Bool) {
        captureAvailability = predicate
        if !predicate() { stop() }
    }

    /// Explicit start; an unanswered permission sheet owns no device lease.
    @discardableResult
    public func start() async -> Bool {
        guard !Task.isCancelled, captureAvailability(), phase == .idle,
              worker == nil, lease == nil, stopTask == nil else { return false }
        runToken &+= 1
        let token = runToken
        streamFailure = nil
        refreshAuthorization()
        phase = .starting

        if authorization.canRequest {
            awaitingPermissionPrompt = true
            let result = await authorizer.requestAuthorization(for: .microphone)
            guard token == runToken else { return false }
            awaitingPermissionPrompt = false
            guard !Task.isCancelled, captureAvailability() else { phase = .idle; return false }
            authorization = result
        }
        guard !Task.isCancelled, captureAvailability() else { phase = .idle; return false }
        guard authorization.isAuthorized else {
            phase = .idle; streamFailure = .notAuthorized; return false
        }
        guard provider.inputAvailable() else {
            phase = .idle; streamFailure = .noDevice; return false
        }
        guard let acquired = broker.acquire(.microphone, owner: ownerID) else {
            phase = .idle; streamFailure = .deviceBusy; return false
        }
        guard token == runToken, !Task.isCancelled, captureAvailability() else {
            broker.release(acquired); phase = .idle; return false
        }
        lease = acquired
        let currentWorker = MacAudioWorker()
        let relay = MacSoundLatestReadingRelay()
        worker = currentWorker
        readingRelay = relay
        let result = await withTaskCancellationHandler {
            await currentWorker.start(provider: provider,
                onReading: { [weak self] reading in
                    guard relay.offer(reading) else { return }
                    Task { @MainActor [weak self, relay] in
                        while let latest = relay.take() {
                            self?.ingest(latest, token: token)
                            await Task.yield()
                        }
                    }
                }, onFailure: { [weak self] failure in
                    guard relay.claimFailure() else { return }
                    Task { @MainActor [weak self] in self?.handleStreamFailure(failure, token: token) }
                })
        } onCancel: { [weak self] in
            currentWorker.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token else { return }
                self.stop()
            }
        }
        // stop owns all cleanup once it has invalidated this generation.
        guard token == runToken else { return false }
        guard !Task.isCancelled, captureAvailability() else { stop(); return false }
        switch result {
        case .success:
            if measurementStart == nil { measurementStart = Date() }
            phase = .running
            return true
        case .failure(let failure):
            stop()
            streamFailure = failure
            if let stopTask { _ = await stopTask.value }
            return false
        }
    }

    /// Immediately fences callbacks; potentially blocking stop runs on the
    /// device queue and the lease is released only when it finishes.
    public func stop() {
        runToken &+= 1
        awaitingPermissionPrompt = false
        readingRelay?.invalidate()
        readingRelay = nil
        guard stopTask == nil else { return }
        guard let currentWorker = worker else {
            if let held = lease { broker.release(held) }
            lease = nil
            phase = .idle
            return
        }
        currentWorker.invalidate()
        phase = .stopping
        let held = lease
        stopTask = Task { @MainActor [self] in
            let confirmed = await currentWorker.stop()
            if confirmed {
                if let held { broker.release(held) }
                if worker === currentWorker { worker = nil; lease = nil; phase = .idle }
            }
            stopTask = nil
            return confirmed
        }
    }

    /// Retry is explicit; retain the source and lease when stop is unconfirmed.
    public func waitUntilStopped() async -> Bool {
        if let stopTask { _ = await stopTask.value }
        if worker != nil { stop(); if let stopTask { _ = await stopTask.value } }
        return worker == nil && lease == nil && phase == .idle
    }

    /// A retry never crosses a later stop or starts before device teardown.
    @discardableResult
    public func restart() async -> Bool {
        stop()
        let token = runToken
        if let stopTask { _ = await stopTask.value }
        guard token == runToken, !Task.isCancelled, captureAvailability() else { return false }
        return await start()
    }

    /// Clears retained history, session peak and spectrum. Sampling, if any,
    /// continues; `phase` is unaffected.
    public func reset() {
        buffer.reset()
        history = []
        droppedHistoryCount = 0
        peakDBFS = nil
        spectrum = nil
        levelDBFS = nil
        dominantFrequency = nil
        measurementStart = nil
    }

    /// Actual retained samples as CSV with honest dBFS columns; identical header
    /// and column semantics to the iOS analyzer export.
    public func makeCSV() -> String {
        var lines = ["time_s,level_dbfs,peak_dbfs,dominant_hz"]
        for point in history {
            let frequency = point.dominantFrequency.map { String(format: "%.1f", $0) } ?? ""
            lines.append(String(format: "%.3f,%.1f,%.1f,%@",
                                point.timestamp, point.levelDBFS, point.peakDBFS, frequency))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A device loss stops capture and returns the lease; the failure stays
    /// visible until the next explicit start.
    private func handleStreamFailure(_ failure: MacMediaFailure, token: UInt64) {
        guard token == runToken else { return }
        stop()
        streamFailure = failure
    }

    private func ingest(_ reading: MacSoundReading, token: UInt64) {
        guard token == runToken, phase == .running,
              worker != nil, lease != nil else { return }
        levelDBFS = reading.levelDBFS
        peakDBFS = max(peakDBFS ?? reading.peakDBFS, reading.peakDBFS)
        dominantFrequency = reading.dominantFrequency
        spectrum = reading.spectrum
        if reading.appendToHistory, let start = measurementStart {
            buffer.append(MacSoundSample(
                timestamp: Date().timeIntervalSince(start),
                levelDBFS: reading.levelDBFS,
                peakDBFS: peakDBFS ?? reading.peakDBFS,
                dominantFrequency: reading.dominantFrequency
            ))
            history = buffer.values
            droppedHistoryCount = buffer.droppedCount
        }
    }

    private static func failure(from error: Error) -> MacMediaFailure {
        if let failure = error as? MacMediaFailure { return failure }
        let text = String(describing: error)
        return .engine(String(text.prefix(200)))
    }
}
