// FloeApp — task PiP audio: ambient loops, generic stage speech, cues.
//
// SPDX-License-Identifier: MPL-2.0
//
// One shared, service-owned playback authority lives outside the views. The
// owner is the real running task, claimed by either the task PiP surface or
// the standalone audio capability (run-coordinator-driven, no PiP view
// required): a real running task starts the service — ambient enabled by
// default with initial gain 0, where the loop is *really playing*, just
// muted, so raising the volume is instant with no restart. Explicit PiP
// close with no standalone owner, task terminal with an emptied batch, or
// run-surface teardown stops it; an automatic foreground-return collapse
// does NOT. Settings changes alone never start or stop the owner.
//
// Shared-session ownership is an explicit lease with exactly one holder:
// this service activates (or adopts a deferred video-side activation), and
// releases only when loop, preview, narration, cues AND borrowed answer
// speech are all idle and the video cross-check agrees. Dictation is gated
// synchronously at activation time — a live `.record` session is never
// reconfigured on publisher lag, and the yield surfaces as Paused, not as a
// playback failure.
//
// Everything audio-hardware-facing sits behind small injected seams so the
// real lifecycle (owner start/stop, stale callbacks, loaded preferences,
// batch-terminal stop, interruptions, route changes, transport pause,
// bounded preview, cue/answer leases, recording yields) is testable without
// a device or the full app.

import Foundation
import AVFoundation
import FloeCore

// MARK: - Public surface types

/// Honest user-facing playback state. `.muted` is deliberately distinct from
/// `.stopped`: the loop runs while muted, which is what makes volume changes
/// instant and is what the UI tells the user.
enum PiPAudioSurfaceState: String, Sendable, Equatable {
    case stopped
    case muted
    case playing
    case paused

    var localizationKey: String { "pip.audio.state.\(rawValue)" }
    var title: String { FloeL10n.l(localizationKey) }
}

/// Typed run stages the coordinator publishes. Speech only ever speaks these
/// generic labels — never a task title, tool log, message or path.
enum PiPAudioTaskStage: String, Sendable, Hashable, Equatable {
    case needsInput
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { self != .needsInput }

    var speechLocalizationKey: String {
        switch self {
        case .needsInput: "pip.audio.speech.needs_input"
        case .completed: "pip.audio.speech.completed"
        case .failed: "pip.audio.speech.failed"
        case .cancelled: "pip.audio.speech.cancelled"
        }
    }
}

// MARK: - Injected seams

/// The single looping ambient playback owner. `play` (re)starts a loop;
/// `setGain` changes volume on the live loop — including from 0 — with no
/// restart; pause/resume keep the loaded sound; stop releases the buffer.
@MainActor
protocol PiPAmbientPlaying: AnyObject {
    var isPlaying: Bool { get }
    @discardableResult func play(sound: PiPAmbientSound, gain: Double) -> Bool
    func setGain(_ gain: Double)
    func pause()
    @discardableResult func resume() -> Bool
    func stop()
}

/// One-shot generic-stage speech. Completion fires exactly once per accepted
/// speak, including cancellation paths, so ducking and the session lease
/// always unwind.
@MainActor
protocol PiPSpeechPlaying: AnyObject {
    var isSpeaking: Bool { get }
    @discardableResult func speak(
        text: String,
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool
    func stopAll()
}

/// Short finite attention chime with an exactly-once bounded completion:
/// natural end, replacement by a newer cue, or `stop()` each deliver the
/// pending completion exactly once, so the session lease can never stick.
@MainActor
protocol PiPCuePlaying: AnyObject {
    var isPlaying: Bool { get }
    @discardableResult func playCue(
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool
    func stop()
}

/// Session facts the service acts on, delivered as one event stream so
/// tests can synthesize the exact system notifications.
enum PiPAudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case externalOutputLost
    case externalOutputAvailable
}

/// Owns AVAudioSession activation for Floe audio playback. The lease has
/// exactly one holder: `activate` takes it, `adoptActivation` receives it
/// from another Floe surface that deferred its own release here, and
/// `deactivateIfOwned` gives it back. Real ownership rules live in the
/// implementation: never deactivate a session another feature (PiP video,
/// voice input) has taken over.
@MainActor
protocol PiPAudioSessionControlling: AnyObject {
    func activate() throws
    func adoptActivation()
    func deactivateIfOwned()
    /// Deactivation is additionally gated by this caller-provided check so a
    /// still-live PiP controller keeps its own activation untouched.
    var canReleaseSession: (@MainActor () -> Bool)? { get set }
    var isExternalOutputPresent: Bool { get }
}

// MARK: - Pure lifecycle policy

/// The whole state machine as pure decisions. The service applies exactly
/// what this computes, and the tests pin the contract at both levels.
enum PiPAudioPlaybackPolicy {
    /// Whether ambient loop playback is currently wanted. A terminal batch
    /// (no remaining runs in the owning PiP batch) stops it until the next
    /// run starts or a fresh PiP session opens.
    static func wantsAmbientLoop(
        ownerActive: Bool,
        batchTerminal: Bool,
        ambientEnabled: Bool
    ) -> Bool {
        ownerActive && !batchTerminal && ambientEnabled
    }

    /// Whether the single shared loop owner should be actually running.
    /// A preview tap is an explicit in-app action and is not gated by the
    /// PiP transport-pause control; ambient playback under the owner is.
    static func wantsLoopRunning(
        wantsAmbient: Bool,
        previewActive: Bool,
        pausedByTransport: Bool,
        pausedByInterruption: Bool,
        pausedByRoute: Bool,
        pausedByRecording: Bool
    ) -> Bool {
        guard !pausedByInterruption, !pausedByRecording else { return false }
        if previewActive {
            // A preview is the user's explicit current intent; it plays on
            // the active route like the owner loop but never after the
            // system holds all sound.
            return !pausedByRoute
        }
        return wantsAmbient && !pausedByTransport && !pausedByRoute
    }

    /// Target gain of the live loop. The preview respects the ambient slider
    /// exactly — including 0, which stays a real, muted, running loop — and
    /// raising the slider updates the live loop with no restart.
    static func loopGain(
        ambientGain: Double,
        ducked: Bool,
        duckFactor: Double
    ) -> Double {
        ducked ? ambientGain * duckFactor : ambientGain
    }

    /// Honest surface label. "Paused" only appears while something actually
    /// wants sound; a surface with no intent is simply stopped.
    static func surfaceState(
        loopRunning: Bool,
        wantsAmbient: Bool,
        previewActive: Bool,
        gain: Double,
        pausedByTransport: Bool,
        pausedByInterruption: Bool,
        pausedByRoute: Bool,
        pausedByRecording: Bool
    ) -> PiPAudioSurfaceState {
        if !loopRunning {
            let wantsAnything = wantsAmbient || previewActive
            let held = (pausedByTransport && wantsAmbient)
                || pausedByInterruption
                || pausedByRoute
                || pausedByRecording
            return wantsAnything && held ? .paused : .stopped
        }
        return gain > 0.0001 ? .playing : .muted
    }

    /// Dedupe/throttle: a stage is announced once, and repeated attention
    /// requests inside the window are suppressed so the surface never
    /// becomes a message ticker. Terminal stages announce once per owner.
    static func allowsAnnouncement(
        stage: PiPAudioTaskStage,
        now: Date,
        lastAnnouncedAt: [PiPAudioTaskStage: Date],
        sameStageThrottle: TimeInterval
    ) -> Bool {
        guard let last = lastAnnouncedAt[stage] else { return true }
        if stage.isTerminal { return false }
        return now.timeIntervalSince(last) >= sameStageThrottle
    }

    /// Whether new speech/cue audio may start right now. While the user has
    /// paused the PiP transport, the system holds an interruption, a
    /// recording owns the session or the headphones were pulled, sound must
    /// not continue or spill onto another route.
    static func allowsFreshAnnouncement(
        ownerActive: Bool,
        pausedByTransport: Bool,
        pausedByInterruption: Bool,
        pausedByRoute: Bool,
        pausedByRecording: Bool
    ) -> Bool {
        ownerActive
            && !pausedByTransport
            && !pausedByInterruption
            && !pausedByRoute
            && !pausedByRecording
    }
}

// MARK: - Service

/// App-lifetime PiP sound owner. Created by `AppEnvironment` and wired
/// there: the video service drives start/stop and transport pause/resume,
/// voice input and answer speech gate/duck the loop, and the run coordinator
/// publishes typed stage events. Views only read state and send intents.
@MainActor
final class PiPAudioService: ObservableObject {
    static let ambientDuckFactor = 0.15
    static let needsInputThrottle: TimeInterval = 20
    /// Hard bound for a preview started from the settings page.
    static let defaultPreviewBound: TimeInterval = 20

    @Published private(set) var state: PiPAudioSurfaceState = .stopped
    @Published private(set) var isPreviewing = false
    /// Actionable, quiet error text for the settings surface only. It never
    /// blocks PiP itself: video keeps working when audio fails.
    @Published private(set) var lastActionableError: String?

    private let ambient: any PiPAmbientPlaying
    private let speech: any PiPSpeechPlaying
    private let cue: any PiPCuePlaying
    private let session: any PiPAudioSessionControlling

    private var preferences = PiPAudioPreferences()
    /// Fresh-prefs hook so an owner start reads what SettingsCenter actually
    /// persisted (loaded preferences survive every later open — no
    /// reset-to-zero per open).
    var preferencesProvider: (@MainActor () -> PiPAudioPreferences)?
    /// Synchronous dictation gate from the owning environment. Publisher
    /// delivery can lag the real voice-input state; this is consulted before
    /// any category/activation decision so a live `.record` session is never
    /// reconfigured. Consults real `hasSession`, never category equality, so
    /// a retained `.record` category after recording cannot block resume.
    var isRecordingActiveNow: (@MainActor () -> Bool)?
    /// Injectable clock for deterministic throttle/announcement tests.
    var nowProvider: @MainActor () -> Date = { Date() }
    /// Preview hard bound (tests shrink it; production uses 20s).
    var previewBound: TimeInterval = PiPAudioService.defaultPreviewBound

    private(set) var isTaskOwnerActive = false
    /// The two independent owner inputs behind the single task ownership:
    /// the PiP surface (video service) and the standalone audio capability
    /// (run coordinator, for a real running task batch with the audio
    /// capability honored and no PiP surface required). The owner is active
    /// while EITHER input claims the batch; ownership semantics — fresh
    /// generation, cleared holds, batch re-arm — are identical because the
    /// task, not a view, owns the session.
    private(set) var isPiPSurfaceOwnerActive = false
    private(set) var isStandaloneAudioOwnerActive = false
    private var previewActive = false
    private var previewSoundSelection: PiPAmbientSound?
    private var previewGeneration: UInt64 = 0
    private var previewBoundTask: Task<Void, Never>?
    /// True once the owning PiP batch reached a real terminal state with no
    /// remaining active runs. New runs and fresh PiP sessions clear it.
    private var batchTerminal = false

    private var pausedByTransport = false
    /// True while an interruption is running, or ended without the system
    /// resume hint. An explicit transport play clears the stale no-hint hold
    /// (that is fresh user intent); a stopped owner never auto-resumes.
    private var pausedByInterruption = false
    /// Only ever set by a real `.oldDeviceUnavailable` event (or cleared by
    /// explicit user intent / a new external device). A fresh owner start
    /// plays on the current route — no headset-only requirement.
    private var pausedByRoute = false
    private var pausedByRecording = false
    private var duckedByOwnSpeech = false
    private var duckedByAnswerSpeech = false

    private var loopStarted = false
    private var currentLoopSound: PiPAmbientSound?
    private var currentLoopGain: Double = 0
    private var lastAnnouncedAt: [PiPAudioTaskStage: Date] = [:]
    /// True while an accepted cue has not delivered its bounded completion.
    private var cueInFlight = false
    /// Bumps on every owner start/end so late AVFoundation callbacks
    /// (speech completion, bounded timers) can never touch a session their
    /// owner no longer holds.
    private var ownerGeneration: UInt64 = 0
    /// The shared-session lease: exactly one holder. Set by `activate` or by
    /// adopting a video-side deferral; cleared only by a real release.
    private var sessionLeaseHeld = false
    /// One activation attempt per owner generation: a system refusal is
    /// reported once, not retried on every reconcile tick.
    private var sessionActivationAttemptedGeneration: UInt64?
    private var systemEventTokens: [NSObjectProtocol] = []

    init(
        ambient: any PiPAmbientPlaying = AVPiPAmbientPlayer(),
        speech: any PiPSpeechPlaying = AVPiPSpeechPlayer(),
        cue: any PiPCuePlaying = AVPiPCuePlayer(),
        session: any PiPAudioSessionControlling = AVPiPAudioSessionController()
    ) {
        self.ambient = ambient
        self.speech = speech
        self.cue = cue
        self.session = session
        // Only the real session controller subscribes to AVAudioSession
        // notifications; injected seams receive events through
        // `handleSessionEvent` directly. The service is an app-lifetime
        // singleton, so the observers share its lifetime and no deinit
        // teardown is needed (tests never register real observers).
        if session is AVPiPAudioSessionController {
            systemEventTokens = PiPAudioSystemEvents.installObservers { [weak self] event in
                self?.handleSessionEvent(event)
            }
        }
    }

    // MARK: - Preferences

    func applyPreferences(_ newValue: PiPAudioPreferences) {
        let normalized = newValue.normalized
        guard normalized != preferences else { return }
        let soundChanged = normalized.ambientSound != preferences.ambientSound
        preferences = normalized
        // Sound selection swaps the loop content; gain/toggles only
        // re-reconcile the live intent. Settings changes alone never start
        // or stop the owner.
        if soundChanged, loopStarted, !previewActive {
            currentLoopSound = nil // force a (re)start on next reconcile
        }
        reconcile()
    }

    var currentPreferences: PiPAudioPreferences { preferences }

    // MARK: - Owner lifecycle (task PiP surface / standalone audio start/stop)

    /// The task PiP surface is one owner input: a real running task with its
    /// PiP source prepared/active starts the service; explicit close, system
    /// close or run-surface teardown stops it. An automatic foreground-return
    /// collapse never reaches here (the video service keeps the owner).
    func handleTaskPiPActiveChanged(_ active: Bool) {
        applyOwnerInputs(pip: active, standalone: isStandaloneAudioOwnerActive)
    }

    /// The standalone audio capability's owner input, driven by the run
    /// coordinator from the REAL run batch (never from a settings change and
    /// never from the PiP view): while the audio capability is honored and
    /// the batch has live runs, the SERVICE owns the ambient/task-speech
    /// session. With a PiP surface also active the two inputs share one
    /// owner; the combined transition alone bumps the generation, so a
    /// surface handover cannot restart or stop the loop silently.
    func handleStandaloneAudioOwnerChanged(_ active: Bool) {
        guard active != isStandaloneAudioOwnerActive else { return }
        applyOwnerInputs(pip: isPiPSurfaceOwnerActive, standalone: active)
    }

    private func applyOwnerInputs(pip: Bool, standalone: Bool) {
        isPiPSurfaceOwnerActive = pip
        isStandaloneAudioOwnerActive = standalone
        let combined = pip || standalone
        guard combined != isTaskOwnerActive else { return }
        if combined {
            if let provider = preferencesProvider {
                preferences = provider().normalized
            }
            isTaskOwnerActive = true
            ownerGeneration &+= 1
            batchTerminal = false
            // A fresh task owner starts un-paused on the CURRENT route and
            // regardless of how the previous one ended.
            pausedByTransport = false
            pausedByInterruption = false
            pausedByRoute = false
            lastAnnouncedAt = [:]
        } else {
            isTaskOwnerActive = false
            ownerGeneration &+= 1
            pausedByTransport = false
            pausedByInterruption = false
            pausedByRoute = false
        }
        reconcile()
        releaseSessionIfIdle()
    }

    /// The PiP window's own play/pause control. Pause is honored for
    /// everything this service produces; a late resume cannot start audio
    /// for an owner that already ended.
    func handlePiPTransportControlled(_ playing: Bool) {
        pausedByTransport = !playing
        if playing, isTaskOwnerActive || previewActive {
            // An explicit user play is a fresh intent: it clears both the
            // stale no-hint interruption hold and a headphone-removal hold
            // (the user chose to hear sound on the current route now).
            pausedByInterruption = false
            pausedByRoute = false
        }
        reconcile()
    }

    /// The PiP window went away (automatic foreground-return collapse, user
    /// close, teardown). The transport pause dies with the window; system
    /// interruption and route holds are separate and stay untouched. The
    /// owner itself is unchanged: an automatic collapse keeps the same
    /// running-task owner and the same loop.
    func handlePiPWindowDismissed() {
        guard pausedByTransport else { return }
        pausedByTransport = false
        reconcile()
    }

    /// A newly started run re-arms ambient inside the current PiP batch.
    func handleRunStarted() {
        guard isTaskOwnerActive else { return }
        batchTerminal = false
        reconcile()
    }

    /// The coordinator calls this when a terminal run left the owning batch
    /// empty. Ambient stops even though the PiP surface may still show the
    /// completion dwell; queued speech/cue finish bounded first.
    func handleRunBatchTerminal() {
        guard isTaskOwnerActive, !batchTerminal else { return }
        batchTerminal = true
        reconcile()
        releaseSessionIfIdle()
    }

    // MARK: - Preview (settings page only)

    /// Starts a bounded preview of the explicitly requested sound through
    /// the same playback owner, at the exact slider gain (0 stays a real
    /// muted loop). Never creates a task owner, never touches PiP. The
    /// service enforces the hard time bound; leaving the page also stops it
    /// (the two together mean a preview cannot outlive the page or run
    /// unbounded).
    func startPreview(_ sound: PiPAmbientSound) {
        previewActive = true
        isPreviewing = true
        previewSoundSelection = sound
        previewGeneration &+= 1
        let generation = previewGeneration
        if currentLoopSound != sound {
            currentLoopSound = nil // force start with the previewed sound
        }
        // Explicit preview intent clears the route hold for this session;
        // the loop must actually be audible.
        pausedByRoute = false
        previewBoundTask?.cancel()
        previewBoundTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.previewBound))
            guard !Task.isCancelled else { return }
            guard self.previewGeneration == generation else { return }
            self.stopPreview()
        }
        reconcile()
    }

    /// Leaving the settings page calls this; the bound timer is the second
    /// independent guard so a forgotten page can never keep playing.
    func stopPreview() {
        guard previewActive else { return }
        previewActive = false
        isPreviewing = false
        previewSoundSelection = nil
        previewGeneration &+= 1
        previewBoundTask?.cancel()
        previewBoundTask = nil
        reconcile()
        releaseSessionIfIdle()
    }

    /// Which sound the preview plays: always the explicit requested choice,
    /// falling back to the stored ambient sound only when no preview exists.
    var previewSound: PiPAmbientSound { previewSoundSelection ?? preferences.ambientSound }

    // MARK: - External duck/gate inputs

    /// Answer voice (SpeechService) borrows the shared session: while it
    /// speaks, ambient ducks AND the session lease cannot be released — a
    /// PiP close mid-answer must not interrupt the answer.
    func handleAnswerSpeechActive(_ active: Bool) {
        duckedByAnswerSpeech = active
        reconcile()
        if !active {
            releaseSessionIfIdle()
        }
    }

    /// Voice input holds the record session: the loop yields while a session
    /// exists and only resumes while its own owner still holds it.
    func handleRecordingActive(_ active: Bool) {
        pausedByRecording = active
        reconcile()
    }

    // MARK: - Typed stage events (coordinator → speech/cues)

    /// One typed stage from the run coordinator, tied to its run. Ambient
    /// teardown is NOT driven here: the coordinator separately reports the
    /// batch becoming empty via `handleRunBatchTerminal`, so run A finishing
    /// while run B still works keeps B's ambience, and a late callback for a
    /// superseded run can never stop a new owner (generation-guarded).
    func handleTaskEvent(_ stage: PiPAudioTaskStage, runID: UUID) {
        syncRecordingGate()
        FloeLogger(category: .app).debug(
            "pipAudioTaskEvent stage=\(stage.rawValue) run=\(runID.uuidString) owner=\(isTaskOwnerActive)"
        )
        guard isTaskOwnerActive else {
            return
        }
        let now = nowProvider()
        guard PiPAudioPlaybackPolicy.allowsAnnouncement(
            stage: stage,
            now: now,
            lastAnnouncedAt: lastAnnouncedAt,
            sameStageThrottle: Self.needsInputThrottle
        ) else {
            return
        }
        lastAnnouncedAt[stage] = now
        guard PiPAudioPlaybackPolicy.allowsFreshAnnouncement(
            ownerActive: isTaskOwnerActive,
            pausedByTransport: pausedByTransport,
            pausedByInterruption: pausedByInterruption,
            pausedByRoute: pausedByRoute,
            pausedByRecording: pausedByRecording
        ) else {
            // The user (or the system) currently holds all sound off. A
            // system notification still carries the terminal event.
            return
        }
        let generation = ownerGeneration
        if preferences.cuesEnabled {
            // The cue is a real finite playback with its own bounded lease:
            // it activates the shared session if needed and the completion
            // (natural end, replacement or stop) releases exactly once.
            ensureSessionActiveForPlayback()
            let accepted = cue.playCue(
                volume: preferences.taskSpeechGain,
                completion: { [weak self] in
                    guard let self else { return }
                    self.cueInFlight = false
                    self.releaseSessionIfIdle()
                }
            )
            // Set AFTER playCue: replacing an in-flight cue fires the old
            // completion synchronously, and that must not clear the new one.
            cueInFlight = accepted
        }
        if preferences.taskSpeechEnabled, stage != .cancelled {
            duckedByOwnSpeech = true
            ensureSessionActiveForPlayback()
            let text = FloeL10n.l(stage.speechLocalizationKey)
            let accepted = speech.speak(
                text: text,
                volume: preferences.taskSpeechGain
            ) { [weak self] in
                guard let self else { return }
                if self.ownerGeneration == generation {
                    self.duckedByOwnSpeech = false
                    self.reconcile()
                }
                // Session release is generation-independent: a terminal
                // announcement that outlives its owner must still be able to
                // hand the session back once it finishes.
                self.releaseSessionIfIdle()
            }
            if !accepted {
                duckedByOwnSpeech = false
            }
        }
        // Apply ducking (and any cue-side state) to the live loop now.
        reconcile()
    }

    // MARK: - System session events

    func handleSessionEvent(_ event: PiPAudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            pausedByInterruption = true
            reconcile()
        case .interruptionEnded(let shouldResume):
            // Obey the system resume hint: resume only when it says so.
            // Without the hint the surface stays paused until an explicit
            // user action (transport play, new owner, preview tap) clears
            // it, and a stopped owner never gets an automatic fresh session.
            pausedByInterruption = !shouldResume
            reconcile()
            if !isTaskOwnerActive, !previewActive {
                releaseSessionIfIdle()
            }
        case .externalOutputLost:
            pausedByRoute = true
            reconcile()
        case .externalOutputAvailable:
            guard pausedByRoute else { return }
            // Only come back for a real external route; the owner check
            // keeps a stopped owner silent.
            guard session.isExternalOutputPresent else { return }
            pausedByRoute = false
            if isTaskOwnerActive || previewActive {
                reconcile()
            }
        }
    }

    // MARK: - Session lease

    /// The PiP video service deferred its own deactivation here because this
    /// service was still borrowing the session (loop, cue, narration or
    /// answer speech). Adopting the lease keeps exactly one holder that will
    /// release it — no activation can leak when the video side hands off.
    func adoptDeferredSessionLease() {
        guard !sessionLeaseHeld else { return }
        session.adoptActivation()
        sessionLeaseHeld = true
        FloeLogger(category: .app).debug("pipAudioSessionLeaseAdopted")
    }

    /// True while this service really holds or borrows the shared playback
    /// session: a running loop, a bounded cue, a narration, an explicit
    /// preview, or borrowed answer speech. The PiP video service consults
    /// this before deactivating so the two same-category owners never pull
    /// the session from each other.
    var holdsSharedAudioSession: Bool {
        loopStarted
            || previewActive
            || cueInFlight
            || duckedByOwnSpeech
            || duckedByAnswerSpeech
            || speech.isSpeaking
    }

    // MARK: - Reconcile

    /// Consults the synchronous recording gate before any decision so a lag
    /// in the publisher stream can never reconfigure a live `.record`
    /// session. The gate reads real `hasSession`, so a retained `.record`
    /// category after recording ended cannot block a valid resume forever.
    private func syncRecordingGate() {
        guard let isRecordingActiveNow else { return }
        pausedByRecording = isRecordingActiveNow()
    }

    private func reconcile() {
        syncRecordingGate()
        let wantsAmbient = PiPAudioPlaybackPolicy.wantsAmbientLoop(
            ownerActive: isTaskOwnerActive,
            batchTerminal: batchTerminal,
            ambientEnabled: preferences.ambientEnabled
        )
        let wantsRunning = PiPAudioPlaybackPolicy.wantsLoopRunning(
            wantsAmbient: wantsAmbient,
            previewActive: previewActive,
            pausedByTransport: pausedByTransport,
            pausedByInterruption: pausedByInterruption,
            pausedByRoute: pausedByRoute,
            pausedByRecording: pausedByRecording
        )
        let ducked = duckedByOwnSpeech || duckedByAnswerSpeech
        let gain = PiPAudioPlaybackPolicy.loopGain(
            ambientGain: preferences.ambientGain,
            ducked: ducked,
            duckFactor: Self.ambientDuckFactor
        )
        let sound = previewActive ? previewSound : preferences.ambientSound

        if wantsRunning {
            ensureSessionActiveForPlayback()
            if !loopStarted || currentLoopSound != sound {
                let started = ambient.play(sound: sound, gain: gain)
                loopStarted = started
                currentLoopSound = started ? sound : nil
                currentLoopGain = started ? gain : 0
                if !started {
                    reportActionableError(FloeL10n.l("pip.audio.error.playback"))
                }
            } else if !ambient.isPlaying {
                // Held by an earlier decision (transport/interruption/route/
                // recording) that has now cleared: resume, no restart.
                if ambient.resume() {
                    currentLoopGain = gain
                }
            } else {
                ambient.setGain(gain)
                currentLoopGain = gain
            }
        } else if loopStarted {
            if !wantsAmbient && !previewActive {
                // Owner gone / batch terminal / ambient disabled: full stop.
                ambient.stop()
                loopStarted = false
                currentLoopSound = nil
                currentLoopGain = 0
            } else {
                // Still owned, but something holds sound: pause in place.
                ambient.pause()
                currentLoopGain = 0
            }
        }

        state = PiPAudioPlaybackPolicy.surfaceState(
            loopRunning: loopStarted && ambient.isPlaying,
            wantsAmbient: wantsAmbient,
            previewActive: previewActive,
            gain: currentLoopGain,
            pausedByTransport: pausedByTransport,
            pausedByInterruption: pausedByInterruption,
            pausedByRoute: pausedByRoute,
            pausedByRecording: pausedByRecording
        )
    }

    private func ensureSessionActiveForPlayback() {
        // Synchronous dictation gate: activating over a live recording
        // session would reconfigure `.record` out from under voice input.
        // The yield is a Pause, not a playback failure — no error surface.
        if let isRecordingActiveNow, isRecordingActiveNow() {
            pausedByRecording = true
            return
        }
        guard !sessionLeaseHeld,
              sessionActivationAttemptedGeneration != ownerGeneration else { return }
        sessionActivationAttemptedGeneration = ownerGeneration
        do {
            try session.activate()
            sessionLeaseHeld = true
        } catch {
            reportActionableError(FloeL10n.l("pip.audio.error.session"))
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pipAudioSessionActivateFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    /// Releases the lease only when no owner, no preview, no loop, no cue,
    /// no narration and no borrowed answer speech are left — and only when
    /// the video cross-check agrees no PiP surface still needs it.
    private func releaseSessionIfIdle() {
        guard sessionLeaseHeld else { return }
        guard !isTaskOwnerActive, !previewActive, !loopStarted,
              !cueInFlight, !duckedByAnswerSpeech, !speech.isSpeaking else { return }
        // The wiring's cross-check: a still-live PiP controller keeps its
        // own activation; releasing here would suspend the video surface.
        guard session.canReleaseSession?() ?? true else { return }
        session.deactivateIfOwned()
        sessionLeaseHeld = false
    }

    /// Set the session-release cross-check (wired by AppEnvironment).
    func setSessionReleaseCheck(_ check: (@escaping @MainActor () -> Bool)) {
        session.canReleaseSession = check
    }

    /// Stop everything this service produced (used by teardown wiring).
    /// Does not fight other owners: the session controller still refuses to
    /// deactivate a session another feature has retaken.
    func shutdownForTeardown(reason: String) {
        isTaskOwnerActive = false
        isPiPSurfaceOwnerActive = false
        isStandaloneAudioOwnerActive = false
        batchTerminal = false
        pausedByTransport = false
        pausedByInterruption = false
        pausedByRoute = false
        duckedByOwnSpeech = false
        previewBoundTask?.cancel()
        previewBoundTask = nil
        previewActive = false
        isPreviewing = false
        previewSoundSelection = nil
        // stop() delivers any bounded cue/speech completions exactly once.
        cue.stop()
        cueInFlight = false
        speech.stopAll()
        ambient.stop()
        loopStarted = false
        currentLoopSound = nil
        currentLoopGain = 0
        state = .stopped
        ownerGeneration &+= 1
        FloeLogger(category: .app).info("pipAudioShutdown reason=\(reason)")
        releaseSessionIfIdle()
    }

    private func reportActionableError(_ message: String) {
        // Quiet: the settings surface shows it; the run and PiP continue.
        lastActionableError = message
    }

    func clearActionableError() {
        lastActionableError = nil
    }
}

// MARK: - System notification translation

/// Translates the two AVAudioSession notification streams into the
/// service's Sendable event vocabulary. Parsing is fully pure and
/// nonisolated so the @Sendable observer blocks never reach into MainActor
/// state directly; delivery hops synchronously on the main queue.
enum PiPAudioSystemEvents {
    @MainActor
    static func installObservers(
        deliver: @escaping @MainActor (PiPAudioSessionEvent) -> Void
    ) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo
            let typeRaw = (userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let optionsRaw = (userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            guard let event = PiPAudioSystemEvents.interruptionEvent(
                typeRaw: typeRaw, optionsRaw: optionsRaw
            ) else { return }
            MainActor.assumeIsolated {
                deliver(event)
            }
        })
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo
            let reasonRaw = (userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            let external = PiPAudioSystemEvents.externalOutputPresent()
            guard let event = PiPAudioSystemEvents.routeEvent(
                reasonRaw: reasonRaw, externalPresentNow: external
            ) else { return }
            MainActor.assumeIsolated {
                deliver(event)
            }
        })
        return tokens
    }

    /// Pure mapping so tests cover the real interpretation of the system
    /// user info without posting AVAudioSession notifications.
    nonisolated static func interruptionEvent(
        typeRaw: UInt?,
        optionsRaw: UInt
    ) -> PiPAudioSessionEvent? {
        guard let typeValue = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    nonisolated static func routeEvent(
        reasonRaw: UInt?,
        externalPresentNow: Bool
    ) -> PiPAudioSessionEvent? {
        guard let reasonValue = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return nil }
        switch reason {
        case .oldDeviceUnavailable:
            // Only pause when NOTHING external remains; a swap between two
            // external devices keeps playing.
            return externalPresentNow ? nil : .externalOutputLost
        case .newDeviceAvailable:
            return externalPresentNow ? .externalOutputAvailable : nil
        default:
            return nil
        }
    }

    nonisolated static func externalOutputPresent() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { port in
            switch port.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                 .carAudio, .usbAudio, .airPlay:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Real AVFoundation backends

/// AVAudioPlayer-backed infinite loop of the bundled meditation asset. The
/// file is decoded once per start, never from the network or an expanding
/// on-disk cache. Gain changes apply live; zero gain is real playback.
@MainActor
final class AVPiPAmbientPlayer: PiPAmbientPlaying {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Location of the bundled loop for a sound choice. A missing asset is a
    /// real, reportable playback failure (the service surfaces
    /// `pip.audio.error.playback`), never a silent fallback to synthesized
    /// or streamed audio.
    static func bundledURL(for sound: PiPAmbientSound) -> URL? {
        Bundle.main.url(
            forResource: sound.bundledResourceName,
            withExtension: sound.bundledResourceExtension
        )
    }

    func play(sound: PiPAmbientSound, gain: Double) -> Bool {
        // Release the previous loop BEFORE validating the new asset: a failed
        // replacement must never leave the old sound playing while the
        // service reports a playback failure and marks the loop stopped.
        stop()
        guard let url = Self.bundledURL(for: sound) else { return false }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.numberOfLoops = -1
            next.volume = Float(max(0, min(1, gain)))
            next.prepareToPlay()
            let started = next.play()
            player = started ? next : nil
            return started
        } catch {
            player = nil
            return false
        }
    }

    func setGain(_ gain: Double) {
        player?.volume = Float(max(0, min(1, gain)))
    }

    func pause() {
        player?.pause()
    }

    func resume() -> Bool {
        player?.play() ?? false
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

/// One-shot chime through its own small finite buffer, with an exactly-once
/// bounded completion (natural end, replacement, or stop).
@MainActor
final class AVPiPCuePlayer: NSObject, PiPCuePlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var activePlayerID: ObjectIdentifier?
    private var pendingCompletion: (@MainActor () -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func playCue(
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        let data = AmbientAudioSynthesizer.cueWavData()
        // A replaced cue completes exactly once before the new one arms.
        deliverPendingCompletion()
        player?.stop()
        do {
            let next = try AVAudioPlayer(data: data)
            next.delegate = self
            next.volume = Float(max(0, min(1, volume)))
            next.prepareToPlay()
            let started = next.play()
            if started {
                player = next
                activePlayerID = ObjectIdentifier(next)
                pendingCompletion = completion
            } else {
                player = nil
                activePlayerID = nil
            }
            return started
        } catch {
            player = nil
            activePlayerID = nil
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        activePlayerID = nil
        deliverPendingCompletion()
    }

    private func deliverPendingCompletion() {
        let pending = pendingCompletion
        pendingCompletion = nil
        pending?()
    }

    // AVFoundation delivers these off any actor assumption; hop to MainActor
    // and re-validate the player identity so a late finish from a replaced
    // cue can never complete the new one.
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.activePlayerID == identifier else { return }
            self.player = nil
            self.activePlayerID = nil
            self.deliverPendingCompletion()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.activePlayerID == identifier else { return }
            self.player = nil
            self.activePlayerID = nil
            self.deliverPendingCompletion()
        }
    }
}

/// AVSpeechSynthesizer-backed generic stage speech. Deliberately separate
/// from Chat/SpeechService (answer voice) so neither can cancel the other;
/// both only share the process-wide session.
@MainActor
final class AVPiPSpeechPlayer: NSObject, PiPSpeechPlaying, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@MainActor () -> Void)?
    private var activeIdentifier: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { completion != nil || synthesizer.isSpeaking }

    func speak(
        text: String,
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        // Never barge a still-playing announcement; drop instead of stacking.
        guard self.completion == nil, !synthesizer.isSpeaking else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = Float(max(0, min(1, volume)))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = Self.preferredVoice(for: text) {
            utterance.voice = voice
        }
        self.completion = completion
        self.activeIdentifier = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        return true
    }

    func stopAll() {
        let pending = completion
        completion = nil
        activeIdentifier = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pending?()
    }

    func finish(identifier: ObjectIdentifier) {
        guard identifier == activeIdentifier else { return }
        let pending = completion
        completion = nil
        activeIdentifier = nil
        pending?()
    }

    // AVFoundation delivers these off any actor assumption; hop to MainActor
    // and re-validate the identifier there (same pattern as Chat/SpeechService).
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(identifier: identifier)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(identifier: identifier)
        }
    }

    private static func preferredVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let cjk = text.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter {
            (0x41...0x5A).contains(Int($0.value)) || (0x61...0x7A).contains(Int($0.value))
        }.count
        let language = cjk >= latin ? "zh-CN" : "en-US"
        return AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Real AVAudioSession lease holder for PiP audio. Uses the exact same
/// category/mode/options pair as the status PiP video service so the two
/// surfaces never reconfigure each other's session — only lease ownership
/// moves. Notification streams are translated externally by
/// `PiPAudioSystemEvents`; this type only controls the session itself.
@MainActor
final class AVPiPAudioSessionController: PiPAudioSessionControlling {
    static let category: AVAudioSession.Category = .playback
    static let mode: AVAudioSession.Mode = .moviePlayback
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers]

    var canReleaseSession: (@MainActor () -> Bool)?

    private var ownsActivation = false

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        // Mirror the PiP video configuration when another Floe surface has
        // already set it; setting an identical category is a no-op, and we
        // must not fight a foreign owner mid-recording (the service gates
        // dictation synchronously before ever calling in here).
        if session.category != Self.category {
            try session.setCategory(
                Self.category,
                mode: Self.mode,
                options: Self.options
            )
        }
        try session.setActive(true)
        ownsActivation = true
    }

    func adoptActivation() {
        // Another Floe surface deferred its release here; hold the lease so
        // exactly one owner will deactivate when everything is idle.
        ownsActivation = true
    }

    func deactivateIfOwned() {
        guard ownsActivation else { return }
        ownsActivation = false
        let session = AVAudioSession.sharedInstance()
        guard session.category == Self.category else {
            // Another feature took the session over; it now owns deactivation
            // too (same rule the PiP video service follows).
            return
        }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pipAudioSessionDeactivationFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    var isExternalOutputPresent: Bool {
        PiPAudioSystemEvents.externalOutputPresent()
    }
}
