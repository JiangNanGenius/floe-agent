// FloeApp — Service-owned warm residency for the enhanced input recognizer.
//
// SPDX-License-Identifier: MPL-2.0
//
// The enhanced recognizer mounts a ~500 MB WhisperKit model. Before this
// runtime every dictation/continuous session built a fresh WhisperKit and
// unloaded it when the session ended, so the second utterance paid the whole
// cold mount again. This actor retains the mounted model for the app's
// foreground lifetime — the same residency contract as the output engine
// (`LocalSpeechRuntime` / `LocalSpeechResidencyPolicy`) — while every session
// still gets a fresh transcript stream, decoder worker, cancellation token
// and decoding options.
//
// Ownership rules encoded here:
// - The model loads on the first ACTUAL foreground acquisition, or on an
//   explicit user-enabled speculative `warmUp()` while the app is foreground.
//   There is no launch/background preload, no automatic retry loop and no
//   download; preload is best effort and never takes a session lease.
// - A speculative mount is discarded when its last preload waiter is
//   cancelled/disabled and no real acquisition is waiting. That discard uses
//   the same retirement window as background/pressure/pack management, so a
//   replacement mount can never overlap its unmount or file-lease return.
// - One session lease at a time. A live session is never stolen: a second
//   acquisition while it is still recording fails fast, so the caller keeps
//   its existing Whisper → Apple fallback / model-not-ready rules.
// - A session that signalled `finishAudio` is joined before the next lease is
//   granted, so the non-thread-safe decoder never has two users.
//   (`VoiceConversationLiveStack.deactivate()` schedules `finishAudio()`
//   without joining it; this join is the fence that makes warm reuse safe
//   there.)
// - Idle warm retention ends on background/inactive, memory pressure, model
//   identity change and pack management. A model is never dropped underneath
//   a live session; the pressure path cancels and joins the owning worker
//   first, exactly like the output engine.
// - A dropped model (deletion/replacement) first retires an idle warm lease,
//   so residency can never keep the model permanently "busy".
//
// Reentrancy contract (actor awaits are reentrant):
// - Every retirement/unmount runs inside a retirement WINDOW. A window is
//   opened synchronously (no await first) before any join or unmount, blocks
//   new grants and new mounts while it is open, and is closed only after the
//   unmount and file-lease return completed. A successor can therefore never
//   be granted, and then unmounted, by a retirement that started earlier.
// - `acquire()` revalidates cancellation, foreground state, retirement state
//   and the session slot after EVERY await that precedes a grant; a cancelled
//   waiter never consumes the lease, and a grant is never issued during
//   retirement.
// - A discarded cold mount keeps the cold-load slot occupied until its
//   unmount and lease return finish, so a newer mount cannot overlap it, and
//   a stale completion never mutates a newer generation. The acquisition that
//   was waiting on it fails; only a fresh acquire after the retirement mounts.
//
// No byte-size admission floor is encoded: the bundled model is a single
// fixed choice; downloaded file size does not establish resident memory usage.
//
// This file is Foundation-only on purpose: the exact production bytes compile
// into a host harness with a scripted loader/model seam. The
// WhisperKit/AVFoundation pieces
// live in `WhisperStreamingTranscriber.swift`.

import Foundation

// MARK: - Model seam

/// Every knob that may differ between sessions; the mounted weights are
/// shared by dictation and continuous voice.
struct SpeechRecognitionDecoding: Sendable, Equatable {
    var languageCode: String?
    var detectLanguage: Bool
}

/// One timed segment returned by the mounted model for file/caption work.
/// Times are REAL decoder timestamps relative to the supplied audio window;
/// `FileSpeechTranscriber` adds the window offset. A segment without a finite
/// positive duration is dropped rather than invented from the asset duration.
struct SpeechRecognitionTimedSegment: Sendable, Equatable {
    struct Word: Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    var start: Double
    var end: Double
    var text: String
    var words: [Word]

    /// Shifts this window's relative timestamps into the parent asset's time
    /// coordinate system. `FileSpeechTranscriber` only calls this with the
    /// offset of a real decoded chunk.
    func offsetting(by offset: Double) -> Self {
        guard offset.isFinite else { return self }
        return Self(
            start: start + offset,
            end: end + offset,
            text: text,
            words: words.map { Word(start: $0.start + offset, end: $0.end + offset, text: $0.text) })
    }
}

enum SpeechRecognitionModelFailure: Error, Sendable, Equatable {
    /// The mounted model was asked for timestamps it does not provide. The
    /// caller must fail honestly or fall back; it must not synthesize times.
    case timedTranscriptionUnsupported
}

/// Converts raw WhisperKit segment timing into the runtime's neutral timed
/// type. Kept Foundation-only so the clamping/drop rules are host-testable
/// with the exact production bytes.
enum SpeechRecognitionTimedMapping {
    struct RawWord: Sendable, Equatable {
        var start: Float
        var end: Float
        var text: String
    }

    struct RawSegment: Sendable, Equatable {
        var start: Float
        var end: Float
        var text: String
        var words: [RawWord]?
    }

    static func relativeSegments(raw: [RawSegment], duration: Double) -> [SpeechRecognitionTimedSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        return raw.compactMap { item in
            var start = Double(item.start)
            var end = Double(item.end)
            guard start.isFinite, end.isFinite else { return nil }
            start = max(0, start)
            end = min(duration, end)
            guard end > start else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let words = (item.words ?? []).compactMap { word -> SpeechRecognitionTimedSegment.Word? in
                var from = Double(word.start)
                var to = Double(word.end)
                guard from.isFinite, to.isFinite else { return nil }
                from = max(start, from)
                to = min(end, to)
                guard to > from, !word.text.isEmpty else { return nil }
                return .init(start: from, end: to, text: word.text)
            }
            return .init(start: start, end: end, text: text, words: words)
        }
    }
}

/// One mounted recognition model behind the residency runtime.
///
/// Inference is NOT thread-safe. The runtime guarantees exactly one session
/// user at a time and joins a finishing session's worker before the next
/// lease starts. `unmount()` is only called after every session that used the
/// model has ended (joined), or when no session ever acquired it.
protocol SpeechRecognitionModelInstance: Sendable {
    /// Identity of the mounted weights (bundled manifest id + revision).
    var identity: String { get }
    /// Decode one audio window. Never called concurrently.
    func transcribe(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [String]
    /// Decode one audio window while preserving the decoder's real segment
    /// and word timestamps. Never called concurrently with `transcribe` or
    /// another timed call; the runtime lease is the serialization boundary.
    func transcribeTimed(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [SpeechRecognitionTimedSegment]
    /// Release the resident weights.
    func unmount() async
}

extension SpeechRecognitionModelInstance {
    /// Voice-only models and test seams do not have to fabricate timing.
    func transcribeTimed(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [SpeechRecognitionTimedSegment] {
        throw SpeechRecognitionModelFailure.timedTranscriptionUnsupported
    }
}

/// One session's claim on the warm model. The transcription worker reports
/// its lifecycle here; the token fences callbacks from a retired session so
/// a late `sessionEnded` can never release a newer session's model.
struct SpeechRecognitionLease: Sendable {
    private let runtime: SpeechRecognitionRuntime
    private let token: UUID
    let model: any SpeechRecognitionModelInstance

    init(runtime: SpeechRecognitionRuntime, token: UUID, model: any SpeechRecognitionModelInstance) {
        self.runtime = runtime
        self.token = token
        self.model = model
    }

    /// Attaches the session's single inference worker and reports whether the
    /// claim still owns the model. `false` means the claim was retired
    /// (memory pressure / pack management) between `acquire()` and this
    /// attachment: the worker has been cancelled and must never run, and the
    /// factory must fail instead of handing out a transcriber over a released
    /// model. `start` opens the worker's start gate and runs in the SAME actor
    /// step as admission (or after the cancellation on rejection), so no
    /// retirement can slip between registration and the worker starting.
    @discardableResult
    func attachWorker(_ worker: Task<Void, Never>, start: @Sendable () -> Void = {}) async -> Bool {
        await runtime.attachWorker(token: token, worker: worker, start: start)
    }

    /// The consumer has asked for end of audio. From this point a new
    /// acquisition may wait for the worker to exit instead of failing.
    func beginFinishing() async {
        await runtime.beginFinishing(token: token)
    }

    /// The worker has exited. `healthy == false` means a real decoder fault
    /// (not cancellation), which retires the warm model like the output
    /// engine's render failure.
    func sessionEnded(healthy: Bool) async {
        await runtime.sessionEnded(token: token, healthy: healthy)
    }
}

// MARK: - Lease arbitration

/// Arbitration between the warm recognition resident and other exclusive users
/// of the same model directory (file/caption transcription, install/remove).
///
/// The resident's own cold mount must NEVER ask to retire itself: doing so
/// would wait on the very load that is calling the store, i.e. a Store↔Runtime
/// self-wait. External callers keep the pack-management behavior and retire an
/// idle warm model before taking the directory.
enum SpeechModelLeaseArbitration {
    enum Request: Sendable {
        /// The recognition runtime mounting its own warm model.
        case resident
        /// File/caption transcription or any other exclusive directory user.
        case external
    }
    enum Decision: Equatable, Sendable {
        case proceed
        /// Another lease is held and this is the resident's own mount: fail
        /// fast, never invoke the retirement hook.
        case unavailable
        /// An external user wants the directory: retire the idle warm model
        /// first, then acquire.
        case retireResident
    }

    static func decision(for request: Request, heldLeases: Int) -> Decision {
        guard heldLeases > 0 else { return .proceed }
        switch request {
        case .resident: return .unavailable
        case .external: return .retireResident
        }
    }
}

// MARK: - Worker exit classification

/// How a recognition worker's audio stream ended.
///
/// Memory pressure cancels an ACTIVE worker. That must not look like a healthy
/// stream renewal — the continuous coordinator would immediately restart and
/// reload the model that was just released — and must not look like decoder
/// corruption, which would trigger fallback/retry loops. An owning consumer's
/// `finishAudio()` is a normal end; a stream that ended without that request
/// was interrupted while still active and is reported through the existing
/// `.interrupted` reason.
enum SpeechRecognitionWorkerExit: Equatable, Sendable {
    case normal
    case forcedInterruption
    case decoderFailure

    static func classify(endedByConsumer: Bool, decoderFailed: Bool) -> SpeechRecognitionWorkerExit {
        if decoderFailed { return .decoderFailure }
        if endedByConsumer { return .normal }
        return .forcedInterruption
    }
}

// MARK: - Residency policy

/// Foreground residency policy for the enhanced recognizer.
///
/// Mirrors `LocalSpeechResidencyPolicy` (the output engine): a successfully
/// mounted model stays warm across ordinary stop/end and language/voice
/// changes while the app is in the foreground. Background, memory pressure
/// and pack management release it; a live session always keeps it.
enum SpeechRecognitionResidencyPolicy {
    /// Ordinary session end keeps the model unless a real decoder fault
    /// occurred or the app already left the foreground.
    static func unloadsAfterSessionEnd(healthy: Bool, isForeground: Bool) -> Bool {
        !healthy || !isForeground
    }

    /// Background/inactive idle release never takes the model from a session
    /// that still owns it.
    static func releasesOnIdleLifecycle(hasActiveSession: Bool) -> Bool { !hasActiveSession }
}

// MARK: - Runtime

actor SpeechRecognitionRuntime {
    /// Injected seams. Production wiring lives next to the WhisperKit
    /// conformance in `WhisperStreamingTranscriber.swift`; the host harness
    /// injects a scripted loader/model with the same contract.
    struct Dependencies: Sendable {
        /// Installed model identity, `nil` when the model is not installed.
        /// Cheap: the bundled manifest plus its install marker.
        var installedIdentity: @Sendable () async -> String?
        /// Verify the installed files, acquire the file lease and mount.
        var load: @Sendable () async throws -> Loaded
        /// Return the file lease after `unmount()` completed.
        var releaseLease: @Sendable (UUID) async -> Void
        /// Register the pack-management handshake once, before the first
        /// load. Deletion/replacement asks the runtime to retire an idle
        /// warm model instead of reporting it permanently busy.
        var installResidencyHook: @Sendable (SpeechRecognitionRuntime) async -> Void
    }

    struct Loaded: Sendable {
        let model: any SpeechRecognitionModelInstance
        /// File lease that keeps the model directory alive on disk.
        let leaseID: UUID
    }

    enum Failure: Error, Sendable {
        case busy
        case unavailable
    }

    private enum ColdOutcome: Sendable {
        case loaded
        case failed
        case cancelled
        /// A retirement window (pack management, background, memory
        /// pressure or speculative-disable) discarded the mount before it
        /// could be installed; its unmount and lease return already
        /// completed. Terminal for this acquisition: only a fresh explicit
        /// acquire may remount.
        case retired
        /// The mount completed for a stale installed identity without a
        /// retirement; the acquisition may retry the current revision.
        case staleIdentity
    }

    private struct Warm {
        let model: any SpeechRecognitionModelInstance
        let leaseID: UUID
        /// The mount was requested only by speculative preload and no real
        /// session has used it yet. Disabling preload may release it.
        var speculative: Bool
    }

    private struct Session {
        enum Phase { case active, finishing }
        let token: UUID
        var phase: Phase
        var worker: Task<Void, Never>?
    }

    private struct ColdLoad {
        let id: UUID
        let identity: String
        let task: Task<ColdOutcome, Never>
        /// Real acquisitions currently awaiting this mount. A speculative
        /// cancel must never discard a mount a session is waiting for.
        var acquirers = 0
        /// Individual preload waiters, keyed so cancelling one waiter only
        /// cancels the mount after the last speculative demand is gone.
        var speculations: Set<UUID> = []
    }

    private let dependencies: Dependencies
    private var warm: Warm?
    private var session: Session?
    private var coldLoad: ColdLoad?
    /// Chained "unmount + return file lease" work. Chained so two releases
    /// never run out of order.
    private var retirement: Task<Void, Never>?
    /// Retirement window depth. While > 0 no acquisition may grant or start a
    /// mount, so an unmount can never overlap a newer session.
    private var retirementDepth = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    /// Monotonic fence: a cold mount started in an older generation is
    /// discarded (never installed) when retirement/failure intervened.
    private var generation: UInt64 = 0
    private var isForeground = true
    /// A memory warning retires the resident for this foreground lifetime.
    /// Speculative preload must not immediately recreate the model that the
    /// system just asked us to release; a real acquire still may.
    private var speculativeWarmUpSuppressed = false
    /// Explicit enable/disable state for speculative preload. `warmUp()`
    /// starts enabled so direct host use works; the app hook calls
    /// `cancelSpeculativeWarmUp()` on OFF and `allowSpeculativeWarmUp()` on
    /// ON. The epoch fences a warm-up already suspended across a disable.
    private var speculativeWarmUpEnabled = true
    private var speculativeWarmUpEpoch: UInt64 = 0
    private var hookInstalled = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Acquisition

    /// Claims the warm model for one session. Throws `.busy` when another
    /// session is still recording, `.unavailable` when the model is not
    /// installed, the app is backgrounded or a cold mount failed, and
    /// `CancellationError` when the caller was cancelled (a cancelled waiter
    /// never disturbs the mount another waiter needs and never takes a
    /// lease). A waiter whose in-flight cold mount was retired by pack
    /// management, background or memory pressure fails instead of mounting
    /// again: only a fresh `acquire()` after that retirement may remount.
    func acquire() async throws -> SpeechRecognitionLease {
        try Task.checkCancellation()
        guard isForeground else { throw Failure.unavailable }
        if !hookInstalled {
            hookInstalled = true
            await dependencies.installResidencyHook(self)
        }
        // Two rounds cover one stale-identity retry (a warm model or a cold
        // mount built for a revision that moved on). A cold mount discarded
        // by a retirement is terminal, not retryable; anything more is a
        // genuine contention and stays busy.
        for _ in 0..<2 {
            try await settlePreviousSession()
            try await revalidateForGrant()
            if let retirement { await retirement.value }
            try await revalidateForGrant()
            guard session == nil else { throw Failure.busy }
            let identity = await dependencies.installedIdentity()
            try await revalidateForGrant()
            guard session == nil else { throw Failure.busy }
            guard let identity else { throw Failure.unavailable }
            if let warm {
                guard warm.model.identity == identity else {
                    // Installed revision/selection moved on: never reuse stale
                    // weights. Retire inside a window, then retry.
                    await retireWarmInWindow()
                    continue
                }
                return grant(warm.model)
            }
            let load = coldLoad ?? startColdLoad(identity: identity)
            // Register real demand BEFORE awaiting. A cancelled speculative
            // warm-up then sees an acquirer and keeps this mount alive for it.
            joinColdLoad(id: load.id, asAcquirer: true)
            let outcome = await load.task.value
            leaveColdLoad(id: load.id, asAcquirer: true)
            try await revalidateForGrant()
            guard session == nil else { throw Failure.busy }
            switch outcome {
            case .loaded:
                guard let warm, warm.model.identity == identity else { throw Failure.unavailable }
                return grant(warm.model)
            case .failed: throw Failure.unavailable
            case .cancelled: throw CancellationError()
            case .retired:
                // A retirement window discarded this acquisition's cold
                // mount. Never mount again from this waiter: pack
                // management/background/pressure asked for the model to be
                // gone, and an implicit remount after the window closed would
                // resurrect it behind that decision.
                throw Failure.unavailable
            case .staleIdentity: continue
            }
        }
        throw Failure.busy
    }

    /// Speculatively mounts the installed model without taking a session
    /// lease. Returns `true` when the model is already warm or this call
    /// completed the mount, and `false` when the app is backgrounded, the
    /// model is not installed, a memory warning suppressed speculation, the
    /// caller was cancelled, or a retirement discarded the pending mount.
    ///
    /// `warmUp()` joins the SAME cold load as a real `acquire()`: either can
    /// start it, the other waits, and exactly one verification/mount happens.
    /// A cancelled warm-up discards the mount only when no real acquisition
    /// is waiting for it and no session owns the model.
    @discardableResult
    func warmUp() async -> Bool {
        guard isForeground, !speculativeWarmUpSuppressed, speculativeWarmUpEnabled,
              !Task.isCancelled else { return false }
        let epoch = speculativeWarmUpEpoch
        // Do not report a warm model that a retirement is already unmounting,
        // and do not start a speculative mount inside its window.
        if retirementDepth > 0 {
            do { try await revalidateForGrant() } catch { return false }
            guard speculationStillValid(epoch) else { return false }
        }
        if session != nil { return true }
        if !hookInstalled {
            hookInstalled = true
            await dependencies.installResidencyHook(self)
            guard speculationStillValid(epoch) else { return false }
        }
        let speculationID = UUID()
        for _ in 0..<2 {
            do { try await revalidateForGrant() } catch { return false }
            guard speculationStillValid(epoch) else { return false }
            if session != nil { return true }
            let identity = await dependencies.installedIdentity()
            do { try await revalidateForGrant() } catch { return false }
            guard speculationStillValid(epoch) else { return false }
            guard session == nil else { return true }
            guard let identity else { return false }
            if let warm {
                guard warm.model.identity == identity else {
                    // Never report stale weights as preloaded. Retire the
                    // idle warm model in the normal window, then mount the
                    // current installed revision below.
                    await retireWarmInWindow()
                    continue
                }
                return true
            }
            let load = coldLoad ?? startColdLoad(identity: identity)
            joinColdLoad(id: load.id, speculationID: speculationID)
            let loadID = load.id
            let task = load.task
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelSpeculativeDemand(loadID: loadID, speculationID: speculationID)
                }
            }
            leaveColdLoad(id: load.id, speculationID: speculationID)
            guard speculationStillValid(epoch) else { return false }
            switch outcome {
            case .loaded:
                return warm != nil
            case .staleIdentity:
                continue
            case .failed, .cancelled, .retired:
                return false
            }
        }
        return false
    }

    /// Re-arms speculative preload after an explicit user enable. A genuine
    /// foreground return also clears memory-pressure suppression, but only
    /// this call re-enables speculation after an OFF decision. Ordinary
    /// scheduling must not call it, so a pressure release is not undone.
    func allowSpeculativeWarmUp() {
        // Only a real OFF→ON / suppressed→allowed transition fences an
        // older warm-up. A redundant enable (for example, re-entering the
        // settings screen) must not cancel the warm-up already in flight.
        if !speculativeWarmUpEnabled || speculativeWarmUpSuppressed {
            speculativeWarmUpEpoch &+= 1
        }
        speculativeWarmUpSuppressed = false
        speculativeWarmUpEnabled = true
    }

    /// Disabling preload cancels an unused speculative mount and releases an
    /// idle model that was mounted only by preload. It never disturbs a live
    /// session or a cold mount a real acquisition is waiting for. Returns
    /// `true` when something speculative was discarded.
    @discardableResult
    func cancelSpeculativeWarmUp() async -> Bool {
        // Fence any warm-up already suspended before its cold load starts,
        // and keep future speculative mounts out until an explicit enable.
        speculativeWarmUpEnabled = false
        speculativeWarmUpEpoch &+= 1
        guard retirementDepth == 0 else { return false }
        if let load = coldLoad {
            guard load.acquirers == 0, session == nil else { return false }
            beginRetirement()
            defer { endRetirement() }
            await discardColdLoad()
            return true
        }
        guard session == nil, let warm, warm.speculative else { return false }
        beginRetirement()
        defer { endRetirement() }
        await retireWarm()
        return true
    }

    /// Claims the same single model owner for a timed file/caption pass.
    /// This is a real exclusive session, not speculative preload: voice and
    /// file transcription never share the decoder, and a healthy end keeps
    /// the foreground warm model for the next user.
    func acquireForTimedTranscription() async throws -> SpeechRecognitionLease {
        try await acquire()
    }

    /// A finishing session (its `finishAudio()` started) is joined before the
    /// next grant; a live one keeps the decoder and the caller fails fast.
    private func settlePreviousSession() async throws {
        guard let previous = session else { return }
        switch previous.phase {
        case .active:
            throw Failure.busy
        case .finishing:
            if let worker = previous.worker { await worker.value }
            if session?.token == previous.token { session = nil }
        }
    }

    /// Waits out any retirement window, then revalidates cancellation and
    /// foreground state. Runs after every await that precedes a grant.
    private func revalidateForGrant() async throws {
        while retirementDepth > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                retirementWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard isForeground else { throw Failure.unavailable }
    }

    private func grant(_ model: any SpeechRecognitionModelInstance) -> SpeechRecognitionLease {
        let token = UUID()
        // A real session (dictation, continuous voice or file/caption) owns
        // the model now; disabling preload must not unload it.
        warm?.speculative = false
        session = Session(token: token, phase: .active, worker: nil)
        return SpeechRecognitionLease(runtime: self, token: token, model: model)
    }

    // MARK: Session callbacks (fenced by token)

    /// Admits (or rejects) the session's inference worker. Admission is
    /// atomic on the actor: no await runs between the checks and the
    /// registration, so a retirement that cleared the claim can never be
    /// overwritten by a late attachment, and a retired claim's worker can
    /// never register on a successor (the token differs).
    func attachWorker(token: UUID, worker: Task<Void, Never>, start: @Sendable () -> Void) -> Bool {
        guard retirementDepth == 0,
              let current = session, current.token == token,
              current.phase == .active, current.worker == nil else {
            // Rejected: cancel before it can decode against a released model,
            // then release its start gate so the gated worker exits promptly.
            worker.cancel()
            start()
            return false
        }
        session?.worker = worker
        // Atomic with registration: the worker cannot be left waiting on a
        // gate after a retirement has seen the claim.
        start()
        return true
    }

    func beginFinishing(token: UUID) {
        guard let current = session, current.token == token, current.phase == .active else { return }
        session?.phase = .finishing
    }

    func sessionEnded(token: UUID, healthy: Bool) async {
        // A late callback from a retired session is ignored: the token no
        // longer matches, so it cannot release a newer session's model.
        guard let current = session, current.token == token else { return }
        session = nil
        guard SpeechRecognitionResidencyPolicy.unloadsAfterSessionEnd(healthy: healthy, isForeground: isForeground) else { return }
        beginRetirement()
        defer { endRetirement() }
        await drainRetirement()
    }

    // MARK: Lifecycle and resource policy

    /// Scene-phase forwarding. Leaving the foreground releases an idle warm
    /// model (and a mount that is still being built); a session that still
    /// owns the model keeps it until it ends.
    func setForeground(_ value: Bool) async {
        let wasForeground = isForeground
        isForeground = value
        // A genuine return to the foreground is a fresh preload opportunity;
        // a redundant `true` while already active must not clear the memory
        // pressure suppression.
        if value, !wasForeground { speculativeWarmUpSuppressed = false }
        guard !value else { return }
        // Synchronous decision + window: no grant or mount can interleave
        // between deciding to retire and closing the window.
        guard SpeechRecognitionResidencyPolicy.releasesOnIdleLifecycle(hasActiveSession: session != nil) else { return }
        beginRetirement()
        defer { endRetirement() }
        await drainRetirement()
    }

    /// Memory-pressure forwarding, mirroring the output engine: cancel and
    /// join the owning worker, then release. Never overlaps a live decode and
    /// never unmounts a successor (the window blocks grants first).
    func handleMemoryWarning() async {
        // Speculation must not rebuild the resident immediately after the
        // system asked for memory back. Explicit acquisition still may.
        speculativeWarmUpSuppressed = true
        beginRetirement()
        defer { endRetirement() }
        if let current = session {
            current.worker?.cancel()
            if let worker = current.worker { await worker.value }
        }
        // No grant can occur inside a retirement window, so whatever is still
        // in `session` is the claim being retired — never a successor.
        session = nil
        await drainRetirement()
    }

    /// Pack deletion/replacement handshake (called through the model store).
    /// Joins a finishing session and returns `true` only when every lease was
    /// released, so an idle warm model never blocks removal; a live session
    /// still reports busy exactly as before.
    func releaseForModelManagement() async -> Bool {
        guard session?.phase != .active else { return false }
        beginRetirement()
        defer { endRetirement() }
        if let worker = session?.worker { await worker.value }
        session = nil
        await drainRetirement()
        return true
    }

    // MARK: Retirement window

    private func beginRetirement() { retirementDepth += 1 }

    private func endRetirement() {
        retirementDepth = max(0, retirementDepth - 1)
        guard retirementDepth == 0 else { return }
        let waiters = retirementWaiters
        retirementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Caller holds a retirement window. Unmounts the warm model and returns
    /// its file lease; never runs under a session that still owns it.
    private func retireWarm() async {
        guard session == nil, let warm else { return }
        self.warm = nil
        generation &+= 1
        await enqueueUnmount(warm)
    }

    /// Drains a pending cold mount and the warm model. Only call inside a
    /// retirement window: the window keeps new grants/mounts out while the
    /// old mount is unmounted and its lease returned.
    private func drainRetirement() async {
        await discardColdLoad()
        if let retirement { await retirement.value }
        await retireWarm()
    }

    private func retireWarmInWindow() async {
        beginRetirement()
        defer { endRetirement() }
        await retireWarm()
    }

    private func enqueueUnmount(_ warm: Warm) async {
        let dependencies = self.dependencies
        let previous = retirement
        let task = Task {
            await previous?.value
            await warm.model.unmount()
            await dependencies.releaseLease(warm.leaseID)
        }
        retirement = task
        await task.value
    }

    // MARK: Cold load

    private func speculationStillValid(_ epoch: UInt64) -> Bool {
        speculativeWarmUpEnabled && speculativeWarmUpEpoch == epoch
            && !speculativeWarmUpSuppressed && isForeground && !Task.isCancelled
    }

    private func joinColdLoad(id: UUID, asAcquirer: Bool) {
        guard var load = coldLoad, load.id == id else { return }
        if asAcquirer { load.acquirers += 1 }
        coldLoad = load
    }

    private func joinColdLoad(id: UUID, speculationID: UUID) {
        guard var load = coldLoad, load.id == id else { return }
        load.speculations.insert(speculationID)
        coldLoad = load
    }

    private func leaveColdLoad(id: UUID, asAcquirer: Bool) {
        guard var load = coldLoad, load.id == id else { return }
        if asAcquirer { load.acquirers = max(0, load.acquirers - 1) }
        coldLoad = load
    }

    private func leaveColdLoad(id: UUID, speculationID: UUID) {
        guard var load = coldLoad, load.id == id else { return }
        load.speculations.remove(speculationID)
        coldLoad = load
    }

    /// Cancels the cold load only when the cancelled preload was its last
    /// speculative user and no real acquisition is waiting. The discard runs
    /// inside a retirement window so a new grant cannot overlap the unmount.
    private func cancelSpeculativeDemand(loadID: UUID, speculationID: UUID) async {
        guard var load = coldLoad, load.id == loadID,
              load.speculations.contains(speculationID) else { return }
        load.speculations.remove(speculationID)
        coldLoad = load
        guard load.acquirers == 0, load.speculations.isEmpty,
              session == nil, retirementDepth == 0 else { return }
        beginRetirement()
        defer { endRetirement() }
        await discardColdLoad()
    }

    private func startColdLoad(identity: String) -> ColdLoad {
        generation &+= 1
        let expected = generation
        let id = UUID()
        let dependencies = self.dependencies
        let pendingRetirement = retirement
        let task = Task<ColdOutcome, Never> { [weak self] in
            // The previous mount must have returned its file lease before a
            // new verification acquires one (no overlapping file access).
            await pendingRetirement?.value
            do {
                let loaded = try await dependencies.load()
                guard let self else {
                    await loaded.model.unmount()
                    await dependencies.releaseLease(loaded.leaseID)
                    return .failed
                }
                return await self.finishColdLoad(id: id, generation: expected,
                                                 identity: identity, loaded: loaded)
            } catch is CancellationError {
                await self?.clearColdLoad(id: id)
                return .cancelled
            } catch {
                await self?.clearColdLoad(id: id)
                return .failed
            }
        }
        let load = ColdLoad(id: id, identity: identity, task: task)
        coldLoad = load
        return load
    }

    private func clearColdLoad(id: UUID) {
        guard coldLoad?.id == id else { return }
        coldLoad = nil
    }

    /// Publishes the mount only when no retirement intervened, the app is
    /// still in the foreground, the session slot is free and the identity
    /// still matches. Otherwise the freshly built model is unmounted and its
    /// file lease returned while the cold-load slot is STILL occupied, so no
    /// newer mount can overlap it and a stale completion never touches a
    /// newer generation. A retirement-discarded mount is terminal for the
    /// waiting acquisition, including a retirement that starts while a stale
    /// mount is being unmounted; only a stale installed identity without any
    /// intervening retirement is retried.
    private func finishColdLoad(id: UUID, generation expected: UInt64,
                                identity: String, loaded: Loaded) async -> ColdOutcome {
        guard expected == generation else {
            // Only a retirement window bumps the generation while this mount
            // is being built (discardColdLoad/retireWarm), so this waiter
            // must fail rather than mount after the window.
            await loaded.model.unmount()
            await dependencies.releaseLease(loaded.leaseID)
            clearColdLoad(id: id)
            return .retired
        }
        guard isForeground, session == nil else {
            await loaded.model.unmount()
            await dependencies.releaseLease(loaded.leaseID)
            clearColdLoad(id: id)
            return .retired
        }
        guard loaded.model.identity == identity else {
            // The installed revision moved on between the identity read and
            // this mount; this is not a retirement, so the acquisition may
            // retry with the current revision instead of installing stale
            // weights.
            await loaded.model.unmount()
            await dependencies.releaseLease(loaded.leaseID)
            clearColdLoad(id: id)
            // Those awaits are reentrant: an explicit retirement window can
            // start while this stale mount is being discarded, bump the
            // generation and wait on this very task (discardColdLoad). A
            // retirement is terminal — returning `.staleIdentity` here would
            // let the acquisition retry and mount after the window closed.
            guard expected == generation, isForeground else { return .retired }
            return .staleIdentity
        }
        // Provenance for the preload toggle: only a mount that NO real
        // acquisition waited for may be released by disabling preload.
        let speculative = coldLoad?.id == id && coldLoad?.acquirers == 0
        clearColdLoad(id: id)
        warm = Warm(model: loaded.model, leaseID: loaded.leaseID, speculative: speculative)
        return .loaded
    }

    /// Cancels an in-flight cold mount. The slot stays occupied until the
    /// task has discarded (or installed) the model, so a newer mount can never
    /// overlap the old unmount.
    private func discardColdLoad() async {
        guard let load = coldLoad else { return }
        generation &+= 1
        load.task.cancel()
        _ = await load.task.value
    }
}
