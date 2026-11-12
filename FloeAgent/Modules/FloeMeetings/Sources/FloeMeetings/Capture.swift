// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CaptureKind: String, Sendable, Codable {
    case liveRecording
    case importedAudio
    case importedVideo
}

public enum CaptureSessionState: String, Sendable, Codable {
    case pending
    case capturing
    case stopping
    case stopped
    case cancelled
    case failed
}

public enum CaptureStopReason: String, Sendable, Codable {
    case userStopped
    case finished
    case timeout
    /// A previous process ended while this capture was still marked active.
    /// The original file is preserved and the session is finalized as stopped
    /// so it can be played and transcribed again.
    case recovered
}

public struct CaptureConfiguration: Sendable, Codable {
    public var kind: CaptureKind
    /// Directory the host wants capture files written into.
    public var directory: URL
    public var filePrefix: String
    /// How long `stop()` waits for the backend's final flush before keeping
    /// partial data and reporting a timeout.
    public var stopTimeout: TimeInterval

    public init(kind: CaptureKind = .liveRecording, directory: URL, filePrefix: String = "meeting", stopTimeout: TimeInterval = 5) {
        self.kind = kind
        self.directory = directory
        self.filePrefix = filePrefix
        self.stopTimeout = stopTimeout
    }
}

public enum CaptureEvent: Sendable {
    case started(session: CaptureSessionID)
    /// A finalized chunk of the recording on disk with its media-time span.
    case chunkFinalized(session: CaptureSessionID, file: URL, range: MediaTimeRange)
    case stopped(session: CaptureSessionID, reason: CaptureStopReason)
    case cancelled(session: CaptureSessionID)
    case failed(session: CaptureSessionID?, message: String)
}

/// Host-supplied capture implementation (AVFoundation recorder, importer,
/// or a test fake). The backend owns hardware/session policy; this core owns
/// lifecycle, fencing and persistence.
public protocol MeetingCaptureBackend: Sendable {
    func begin(
        session: CaptureSessionID,
        configuration: CaptureConfiguration,
        sink: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws
    /// Ask the backend to finish and flush. The controller awaits the
    /// backend's `stopped` event up to the configuration's stop timeout.
    func requestStop() async
    /// Abort immediately. Must not emit a final transcript or stopped event.
    func cancel() async
}

/// Lifecycle state machine for the single active capture. Boundary rules:
/// - `stop()` is idempotent; concurrent callers await the same outcome.
/// - `cancel()` is idempotent and never manufactures a final/stopped event.
/// - Late backend callbacks after a terminal state are dropped by a
///   generation fence (they cannot touch a newer session either).
/// - `stop()` waits for the backend's flush with a bounded deadline; on
///   timeout it keeps partial data and reports `.timeout`.
public actor MeetingCaptureController {
    public struct Outcome: Sendable, Equatable {
        public let session: CaptureSessionID
        public let state: CaptureSessionState
        public let stopReason: CaptureStopReason?
    }

    private struct Context: Sendable {
        let session: CaptureSessionID
        let generation: Int
        let configuration: CaptureConfiguration
        let backend: any MeetingCaptureBackend
        let deliver: @Sendable (CaptureEvent) -> Void
        let events: AsyncStream<CaptureEvent>.Continuation
        var beginComplete = false
        var stopRequested = false
        var stopCallComplete = true
        var cleanupStarted = false
        var cleanupComplete = false
        var terminal: Outcome?
    }

    private var context: Context?
    private var generationCounter = 0
    private var lastOutcome: Outcome?
    private var timeoutTask: Task<Void, Never>?
    private var stopWaiters: [Int: [CheckedContinuation<Outcome, Never>]] = [:]
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Remains occupied while a terminal backend still owns hardware or has
    /// an outstanding begin/stop call. A timeout must not authorize overlap.
    public var activeSession: CaptureSessionID? { context?.session }
    public var completedOutcome: Outcome? { lastOutcome }
    public var isCleaningUp: Bool { context?.terminal != nil }

    public func start(
        session: CaptureSessionID,
        configuration: CaptureConfiguration,
        backend: any MeetingCaptureBackend,
        deliver: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws {
        if let context { throw MeetingError.captureAlreadyActive(context.session) }
        guard configuration.stopTimeout.isFinite,
              (0...3600).contains(configuration.stopTimeout) else {
            throw MeetingError.captureBackendFailed("Invalid stop timeout.")
        }
        generationCounter += 1
        let generation = generationCounter
        lastOutcome = nil
        let channel = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        context = Context(session: session, generation: generation, configuration: configuration,
                          backend: backend, deliver: deliver, events: channel.continuation)
        // One consumer preserves backend event order. Per-event Tasks could
        // deliver stopped before its preceding finalized chunk.
        Task { [weak self] in
            for await event in channel.stream {
                await self?.receive(event, generation: generation)
            }
        }
        let sink: @Sendable (CaptureEvent) -> Void = { [weak self] event in
            if case .dropped = channel.continuation.yield(event) {
                Task { await self?.overflow(generation: generation) }
            }
        }
        do {
            try await backend.begin(session: session, configuration: configuration, sink: sink)
        } catch {
            guard context?.generation == generation else { throw error }
            context?.beginComplete = true
            if context?.terminal == nil {
                complete(Outcome(session: session, state: .failed, stopReason: nil),
                         event: .failed(session: session, message: String(describing: error)))
            }
            scheduleCleanup(generation: generation)
            throw MeetingError.captureBackendFailed(String(describing: error))
        }
        guard context?.generation == generation else { throw MeetingError.captureSessionEnded(session) }
        context?.beginComplete = true
        if context?.terminal != nil {
            scheduleCleanup(generation: generation)
            throw MeetingError.captureSessionEnded(session)
        }
        if context?.stopRequested == true { requestBackendStop(generation: generation) }
    }

    @discardableResult
    public func stop() async -> Result<Outcome, MeetingError> {
        guard let current = context else {
            return lastOutcome.map { .success($0) } ?? .failure(.noActiveCapture)
        }
        if let outcome = current.terminal { return .success(outcome) }
        // Register BEFORE calling a potentially synchronous or suspended backend.
        let outcome = await withCheckedContinuation { continuation in
            stopWaiters[current.generation, default: []].append(continuation)
            if context?.stopRequested == false {
                context?.stopRequested = true
                armTimeout(generation: current.generation, delay: current.configuration.stopTimeout)
                if current.beginComplete { requestBackendStop(generation: current.generation) }
            }
        }
        return .success(outcome)
    }

    /// Cancellation fences results immediately, then waits for physical owner
    /// release. A suspended backend cannot be reused in a new session meanwhile.
    @discardableResult
    public func cancel() async -> CaptureSessionID? {
        guard let current = context, current.terminal == nil else { return nil }
        complete(Outcome(session: current.session, state: .cancelled, stopReason: nil),
                 event: .cancelled(session: current.session))
        await waitForRelease(generation: current.generation)
        return current.session
    }

    private func requestBackendStop(generation: Int) {
        guard let current = context, current.generation == generation,
              current.terminal == nil, current.stopCallComplete else { return }
        context?.stopCallComplete = false
        Task { [weak self] in
            await current.backend.requestStop()
            await self?.stopCallFinished(generation: generation)
        }
    }

    private func stopCallFinished(generation: Int) {
        guard context?.generation == generation else { return }
        context?.stopCallComplete = true
        releaseIfReady(generation: generation)
    }

    private func armTimeout(generation: Int, delay: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            await self?.timeout(generation: generation)
        }
    }

    private func timeout(generation: Int) {
        guard let current = context, current.generation == generation, current.terminal == nil else { return }
        complete(Outcome(session: current.session, state: .stopped, stopReason: .timeout),
                 event: .stopped(session: current.session, reason: .timeout))
    }

    private func overflow(generation: Int) {
        guard let current = context, current.generation == generation, current.terminal == nil else { return }
        complete(Outcome(session: current.session, state: .failed, stopReason: nil),
                 event: .failed(session: current.session, message: "Capture event buffer overflow."))
    }

    private func receive(_ event: CaptureEvent, generation: Int) {
        guard let current = context, current.generation == generation, current.terminal == nil else { return }
        let session: CaptureSessionID?
        switch event {
        case .started(let s), .chunkFinalized(let s, _, _), .stopped(let s, _), .cancelled(let s): session = s
        case .failed(let s, _): session = s
        }
        guard session == nil || session == current.session else { return }
        switch event {
        case .started, .chunkFinalized: current.deliver(event)
        case .stopped(_, let reason):
            complete(Outcome(session: current.session, state: .stopped, stopReason: reason), event: event)
        case .cancelled:
            complete(Outcome(session: current.session, state: .cancelled, stopReason: nil), event: event)
        case .failed:
            complete(Outcome(session: current.session, state: .failed, stopReason: nil), event: event)
        }
    }

    private func complete(_ outcome: Outcome, event: CaptureEvent) {
        guard let current = context, current.terminal == nil else { return }
        context?.terminal = outcome
        lastOutcome = outcome
        timeoutTask?.cancel()
        timeoutTask = nil
        current.deliver(event)
        for waiter in stopWaiters.removeValue(forKey: current.generation) ?? [] { waiter.resume(returning: outcome) }
        scheduleCleanup(generation: current.generation)
    }

    private func scheduleCleanup(generation: Int) {
        guard let current = context, current.generation == generation,
              current.beginComplete, current.terminal != nil, !current.cleanupStarted else { return }
        context?.cleanupStarted = true
        Task { [weak self] in
            await current.backend.cancel()
            await self?.cleanupFinished(generation: generation)
        }
    }

    private func cleanupFinished(generation: Int) {
        guard context?.generation == generation else { return }
        context?.cleanupComplete = true
        releaseIfReady(generation: generation)
    }

    private func releaseIfReady(generation: Int) {
        guard let current = context, current.generation == generation,
              current.terminal != nil, current.beginComplete,
              current.stopCallComplete, current.cleanupComplete else { return }
        current.events.finish()
        context = nil
        for waiter in releaseWaiters.removeValue(forKey: generation) ?? [] { waiter.resume() }
    }

    private func waitForRelease(generation: Int) async {
        guard context?.generation == generation else { return }
        await withCheckedContinuation { releaseWaiters[generation, default: []].append($0) }
    }
}
