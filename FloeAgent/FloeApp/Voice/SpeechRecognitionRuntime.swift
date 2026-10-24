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
// - The model loads on the first ACTUAL foreground acquisition only; there is
//   no launch preload, no background preload and no automatic retry loop.
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
    /// Release the resident weights.
    func unmount() async
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
        /// A retirement window (pack management, background or memory
        /// pressure) discarded the mount before it could be installed; its
        /// unmount and lease return already completed. Terminal for this
        /// acquisition: only a fresh explicit acquire may remount.
        case retired
        /// The mount completed for a stale installed identity without a
        /// retirement; the acquisition may retry the current revision.
        case staleIdentity
    }

    private struct Warm {
        let model: any SpeechRecognitionModelInstance
        let leaseID: UUID
    }

    private struct Session {
        enum Phase { case active, finishing }
        let token: UUID
        var phase: Phase
        var worker: Task<Void, Never>?
    }

    private struct ColdLoad {
        let id: UUID
        let task: Task<ColdOutcome, Never>
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
            let outcome = await load.task.value
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
        isForeground = value
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
        let load = ColdLoad(id: id, task: task)
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
        clearColdLoad(id: id)
        warm = Warm(model: loaded.model, leaseID: loaded.leaseID)
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
