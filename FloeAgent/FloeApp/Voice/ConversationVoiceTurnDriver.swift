// FloeApp — Canonical voice-conversation turn driver over ConversationCenter.
//
// SPDX-License-Identifier: MPL-2.0
//
// The REAL default `VoiceConversationTurnDriving`: it launches model rounds
// through the existing runtime exactly the way the ordinary chat send paths
// do — no parallel upstream reconstruction, no cloud URL guessing. The voice
// lane reads `ConversationCenter`'s published surface only; it never edits it.
//
//   - Deferred Home entry (`conversationID == nil`): opening or denying the
//     microphone NEVER creates a conversation. Each launch WITHOUT a target
//     yet goes through `startTask(goal:title:…)`, so a saved chat exists
//     only together with its first real message and run;
//     `onConversationCreated` fires before any later navigation so the app
//     layer can bind `presentation.activeConversationID` first.
//   - Continuing conversations (thread entry, temporary included — the center
//     keeps RAM authority): `startRun(goal:in:…)`.
//   - Attachments: `stageAttachments(_:)` snapshots the composer's staged
//     files for the NEXT owned launch (either path). A launch that fails
//     before a run identity exists, a busy rejection or a cancellation
//     restores the snapshot — staged files are never silently dropped.
//     Temporary targets are validated against the center's authority: the
//     driver passes no attachments when `isTemporaryConversation` says the
//     text-only ceiling applies (the host hides the intake UI as well).
//   - Provider/model are resolved per turn through the injected resolver, so
//     selecting another model applies to the next round without replacing
//     the coordinator or this driver.
//   - `StartedConversationRun.result`, `service(for:)` + `events()` /
//     `snapshot()` cover the live stream; `sessionEvents(conversationID:)`
//     covers the preparation gap where the launch identity exists before any
//     service does, and fast completions before subscription — the final
//     text then comes from ACTUALLY STORED assistant messages, never a guess.
//
// Read-aloud projection (settled requirement: tool progress and intermediate
// assistant commentary are NEVER spoken; no keyword guessing; the round is
// never replayed):
//   - display follows `.answerUpdated` (full visible round text, monotonic);
//   - SPEECH is FINAL-ONLY: this driver deliberately never emits the
//     speculative `.finalAnswerUpdated`/`.finalAnswerRetracted` live
//     projection. `.completed(fullText:)` carries ONLY the canonical
//     confirmed final body (durable event order, last tool boundary
//     respected) projected once through the provider-independent
//     `AnswerSpeechText` cloud projection (code/tables removed, URLs retained);
//     the selected output source applies its own URL/local projection;
//   - an unconfirmed or unreadable final means the completed speech body is
//     EMPTY — live segments, joined round text and empty-event fallbacks are
//     never substituted into speech.
//
// Safety rules encoded here (previously agreed fencing, now with the review
// corrections):
// - The cancellation barrier is CANCELLABLE and has a REAL timeout; an
//   unsettled cancelled round rejects the next start as a retryable busy
//   (`.failed`) instead of waiting forever or starting a second owner.
// - A cancellation arriving before the run identity exists still cancels
//   that exact run when the late launch returns, and yields NO events.
// - New launches serialize behind the previous cancellation barrier.
// - Snapshot values are reconciled through `VoiceConversationSegmentAggregator`
//   so tool/reasoning boundaries neither duplicate nor drop audio.
// - Speech receipts persist via `VoicePlaybackReceipt` on the exact run's
//   append-only `.status` event; marked written ONLY on durable success;
//   failures keep the receipt retryable and surface through a redacted host
//   hook. One receipt per round; temporary authority stays RAM-only through
//   the center's own store routing.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine
import FloeCore
import FloeProviders
import FloeModels
import FloePersistence
import FloeAgentRuntime

/// Canonical driver: one instance per voice session owner. The stable Root
/// presentation host builds it from the `ContinuousVoiceRequest` the user
/// tapped; the coordinator is created against it via
/// `VoiceConversationCoordinator.live(driving:language:)`.
@MainActor
final class VoiceConversationRunDriver: VoiceConversationTurnDriving, ObservableObject {

    /// Resolves the current provider+model pair for the NEXT turn (the host
    /// holds the selected model id; a change applies to the next round).
    typealias ModelResolver = @MainActor () -> (provider: ProviderProfile, model: ModelProfile)?

    /// The voice-launched run currently owned, for the UI badge / history.
    @Published private(set) var activeRunID: UUID?

    private let center: ConversationCenter
    private let resolveModel: ModelResolver
    private let workspaceID: UUID?
    private let chatReasoningDraftOwnerID: UUID?
    private let preferredModeForNewConversation: AgentExecutionMode?
    private let onConversationCreated: (@MainActor (UUID) -> Void)?
    private let titleProvider: @MainActor (String) -> String
    private let diagnostics: (any VoiceConversationDiagnostics)?

    /// Raised to the host when a receipt could not be persisted. Redacted by
    /// construction (token only — never transcript bodies).
    var onAttachmentsConsumed: (@MainActor ([AttachmentRef]) -> Void)?
    var onSpeechReceiptSaveIssue: (@MainActor (VoiceConversationRoundToken) -> Void)?

    /// Current conversation target. nil until a launch creates it via
    /// `startTask` (or the app binds one explicitly).
    private(set) var conversationID: UUID?

    /// Staged-file snapshot for the NEXT owned launch; replaced by
    /// `stageAttachments`. Generation-tracked so a restore after a failed
    /// launch never clobbers a newer snapshot the host pushed meanwhile.
    private var pendingAttachments: [AttachmentRef] = []
    private var attachmentGeneration: UInt64 = 0

    init(
        center: ConversationCenter,
        conversationID: UUID? = nil,
        resolveModel: @escaping ModelResolver,
        workspaceID: UUID? = nil,
        attachments: [AttachmentRef] = [],
        chatReasoningDraftOwnerID: UUID? = nil,
        preferredModeForNewConversation: AgentExecutionMode? = nil,
        onConversationCreated: (@MainActor (UUID) -> Void)? = nil,
        titleProvider: (@MainActor (String) -> String)? = nil,
        diagnostics: (any VoiceConversationDiagnostics)? = nil
    ) {
        self.center = center
        self.conversationID = conversationID
        self.resolveModel = resolveModel
        self.workspaceID = workspaceID
        self.chatReasoningDraftOwnerID = chatReasoningDraftOwnerID
        self.preferredModeForNewConversation = preferredModeForNewConversation
        self.pendingAttachments = attachments
        self.onConversationCreated = onConversationCreated
        self.titleProvider = titleProvider ?? Self.defaultTitle
        self.diagnostics = diagnostics
    }

    /// Thread entry (conversation exists — including temporary sessions,
    /// where the center keeps RAM authority for every store route).
    convenience init(
        center: ConversationCenter,
        existingConversationID: UUID,
        resolveModel: @escaping ModelResolver,
        workspaceID: UUID? = nil,
        attachments: [AttachmentRef] = [],
        chatReasoningDraftOwnerID: UUID? = nil,
        onConversationCreated: (@MainActor (UUID) -> Void)? = nil,
        titleProvider: (@MainActor (String) -> String)? = nil,
        diagnostics: (any VoiceConversationDiagnostics)? = nil
    ) {
        self.init(
            center: center,
            conversationID: existingConversationID,
            resolveModel: resolveModel,
            workspaceID: workspaceID,
            attachments: attachments,
            chatReasoningDraftOwnerID: chatReasoningDraftOwnerID,
            onConversationCreated: onConversationCreated,
            titleProvider: titleProvider,
            diagnostics: diagnostics
        )
    }

    /// Home entry (no chat is created by merely opening the sheet): the first
    /// accepted utterance launches atomically through `startTask`.
    convenience init(
        center: ConversationCenter,
        deferredConversationCreation: Bool,
        resolveModel: @escaping ModelResolver,
        workspaceID: UUID? = nil,
        attachments: [AttachmentRef] = [],
        chatReasoningDraftOwnerID: UUID? = nil,
        preferredModeForNewConversation: AgentExecutionMode? = nil,
        onConversationCreated: (@MainActor (UUID) -> Void)? = nil,
        titleProvider: (@MainActor (String) -> String)? = nil,
        diagnostics: (any VoiceConversationDiagnostics)? = nil
    ) {
        precondition(deferredConversationCreation, "use the existing-conversation initializer when an id is known")
        self.init(
            center: center,
            conversationID: nil,
            resolveModel: resolveModel,
            workspaceID: workspaceID,
            attachments: attachments,
            chatReasoningDraftOwnerID: chatReasoningDraftOwnerID,
            preferredModeForNewConversation: preferredModeForNewConversation,
            onConversationCreated: onConversationCreated,
            titleProvider: titleProvider,
            diagnostics: diagnostics
        )
    }

    /// Bind an externally created/selected conversation (idempotent; only
    /// fills the target when nothing has been created yet).
    func bindConversation(_ id: UUID) {
        if conversationID == nil { conversationID = id }
    }

    /// The composer staged files changed while the voice sheet is up:
    /// snapshot the current set for the NEXT launch. Never affects a round
    /// already launched or in flight.
    func stageAttachments(_ refs: [AttachmentRef]) {
        pendingAttachments = refs
        attachmentGeneration &+= 1
    }

    /// Map a round token back to its exact durable run (UI badge, history).
    func runID(for token: VoiceConversationRoundToken) -> UUID? {
        launches[token]?.runID
    }

    // MARK: - Launch bookkeeping

    @MainActor
    private final class Launch {
        let token: VoiceConversationRoundToken
        let text: String
        /// Attachments consumed by THIS launch (restorable pre-run-identity).
        var attachments: [AttachmentRef] = []
        /// `attachmentGeneration` at consume time (restore only if unchanged).
        var attachmentGenerationAtConsume: UInt64 = 0
        var send: (@MainActor @Sendable (VoiceConversationTurnEvent) -> Void)?
        var runID: UUID?
        var conversationID: UUID?
        var watch: Task<Void, Never>?
        var cancelled = false
        var terminal = false
        var terminalHandled = false
        /// True synchronously before the center call (so cancelTurn knows
        /// whether killing the watch task could strand a call in flight).
        var callsCenter = false
        /// True once the call returned a run identity (attachments owned).
        var callsCenterDone = false
        /// Used by the driver to decide whether the watch task can be
        /// cancelled without a side effect: the center call has not started
        /// yet. Defined on the type (not a file-scope extension) so the
        /// `private` nested class is never named outside its owner.
        var canCancelSafely: Bool { !callsCenter }
        var published = ""
        var finalPublished = ""
        var retracted = false
        var aggregator = VoiceConversationSegmentAggregator()
        var latestMessages: [PersistedMessage] = []
        var receiptWritten = false
        var pendingReceipt: VoiceConversationSpeechReceipt?
        var receiptRetryScheduled = false

        /// Cancellable one-shot settlement signal (the old non-cancellable
        /// continuation could outlive a barrier timeout and wedge the chain).
        let settledStream: AsyncStream<Void>
        private let settledYield: AsyncStream<Void>.Continuation
        private var settled = false

        init(token: VoiceConversationRoundToken, text: String) {
            self.token = token
            self.text = text
            (settledStream, settledYield) = AsyncStream.makeStream(of: Void.self)
        }

        var isSettled: Bool { settled }

        /// Awaitable settlement; iteration respects task cancellation, and
        /// the stream ALWAYS finishes when the launch settles, so a barrier
        /// waiting on this can be cancelled or time out honestly.
        func awaitSettled() async {
            if settled { return }
            for await _ in settledStream { break }
        }

        func markSettled() {
            guard !settled else { return }
            settled = true
            settledYield.yield(())
            settledYield.finish()
        }
    }

    private var launches: [VoiceConversationRoundToken: Launch] = [:]
    private var finishedOrder: [VoiceConversationRoundToken] = []
    /// Previous cancellation barrier: resolves to `true` when the cancelled
    /// round actually settled, `false` on timeout (→ next start is rejected
    /// as retryable busy while the old owner remains unsettled).
    private var launchBarrier: Task<Bool, Never>?

    // MARK: - VoiceConversationTurnDriving

    func startTurn(_ request: VoiceConversationTurnRequest, send: @escaping VoiceConversationTurnSender) {
        guard launches[request.token] == nil else {
            send(.failed(message: "voice.error.turn"))
            return
        }
        pruneFinishedLaunches()
        let launch = Launch(token: request.token, text: request.text)
        launch.send = send
        launches[request.token] = launch
        let previousBarrier = launchBarrier
        launchBarrier = nil
        launch.watch = Task { [weak self] in
            let settled = await previousBarrier?.value ?? true
            guard let self, !launch.cancelled, self.launches[request.token] === launch else { return }
            guard settled else {
                // Retryable busy: the previous cancelled round has not
                // settled; refuse to start a second owner. The user's words
                // stay staged by the coordinator (failed-before-output path).
                self.report("launchBusy")
                self.deliver(launch, .failed(message: "voice.error.turn"))
                self.settle(launch)
                return
            }
            await self.launch(launch)
        }
    }

    func cancelTurn(_ token: VoiceConversationRoundToken) async {
        guard let launch = launches[token] else { return }
        launch.cancelled = true
        if let runID = launch.runID {
            await center.cancel(runID: runID)
        } else if launch.watch != nil, launch.canCancelSafely {
            // The launch task has not reached the center call yet: cancelling
            // it has no external side effect. (Once the call is in flight the
            // late-start fence owns the exact-run cancellation.)
            launch.watch?.cancel()
            settle(launch)
        }
        // Bounded, cancellable barrier. Never claim settlement on timeout:
        // an unsettled old owner makes the NEXT start retryable-busy instead
        // of overlapping it.
        let waiter = launch
        launchBarrier = Task { [weak waiter] in
            guard let waiter else { return true }
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await waiter.awaitSettled()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return false
                }
                let settled = await group.next() ?? false
                group.cancelAll()
                return settled
            }
        }
    }

    func reportSpeech(_ receipt: VoiceConversationSpeechReceipt) async {
        guard let launch = launches[receipt.token],
              let runID = launch.runID,
              let conversationID = launch.conversationID else {
            report("receiptWithoutRun", "status=\(receipt.status.rawValue)")
            return
        }
        guard !launch.receiptWritten else { return }
        if launch.pendingReceipt == nil {
            launch.pendingReceipt = receipt
        }
        await persist(receipt, in: launch, runID: runID, conversationID: conversationID)
        // One bounded automatic retry if the durable write failed.
        if let pending = launch.pendingReceipt,
           !launch.receiptWritten, !launch.receiptRetryScheduled {
            launch.receiptRetryScheduled = true
            Task { [weak self, weak launch, pending, runID, conversationID] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let launch, launch.pendingReceipt != nil,
                      !launch.receiptWritten else { return }
                await self.persist(pending, in: launch, runID: runID, conversationID: conversationID)
            }
        }
    }

    /// Host-triggered retry for receipts whose durable write failed
    /// (store busy, migration window). Safe to call any time; no-ops when
    /// nothing is pending or already written.
    func retryPendingSpeechReceipts() async {
        for launch in launches.values {
            guard let receipt = launch.pendingReceipt, !launch.receiptWritten,
                  let runID = launch.runID, let conversationID = launch.conversationID else { continue }
            await persist(receipt, in: launch, runID: runID, conversationID: conversationID)
        }
    }

    private func persist(
        _ receipt: VoiceConversationSpeechReceipt,
        in launch: Launch,
        runID: UUID,
        conversationID: UUID
    ) async {
        guard !launch.receiptWritten else { return }
        let status: VoicePlaybackReceipt.Status =
            receipt.status == .completed ? .completed : .interrupted
        do {
            let payload = try VoicePlaybackReceipt(
                runID: runID, status: status, spokenText: receipt.spokenText
            ).eventPayloadJSON()
            _ = try await center.runStore(for: conversationID).appendEvent(
                runID: runID, kind: .status, payloadJSON: payload
            )
            // Mark written ONLY on durable success.
            launch.receiptWritten = true
            launch.pendingReceipt = nil
            report("receiptPersisted", "status=\(status.rawValue) chars=\(receipt.spokenText.count)")
        } catch {
            // Retained for retry; surfaced redacted. Never claim saved.
            report("receiptWriteFailed", String(describing: type(of: error)))
            onSpeechReceiptSaveIssue?(receipt.token)
        }
    }

    // MARK: - Launch

    private func launch(_ launch: Launch) async {
        guard !launch.cancelled else { settle(launch); return }
        guard let pair = resolveModel() else {
            report("modelResolutionFailed")
            deliver(launch, .failed(message: "voice.error.turn"))
            settle(launch)
            return
        }
        consumeAttachments(for: launch)
        defer { if !launch.callsCenterDone { restoreAttachmentsIfNeeded(for: launch) } }
        do {
            launch.callsCenter = true
            let started: StartedConversationRun
            let conversation: UUID
            if let existing = conversationID {
                conversation = existing
                started = try await center.startRun(
                    goal: launch.text,
                    in: existing,
                    provider: pair.provider,
                    model: pair.model,
                    workspaceID: workspaceID,
                    attachments: launch.attachments,
                    executionMode: .chat,
                    startOrigin: .explicitUserAction
                )
            } else {
                let task = try await center.startTask(
                    goal: launch.text,
                    title: titleProvider(launch.text),
                    provider: pair.provider,
                    model: pair.model,
                    workspaceID: workspaceID,
                    attachments: launch.attachments,
                    executionMode: .chat,
                    chatReasoningDraftOwnerID: chatReasoningDraftOwnerID,
                    preferredModeForNewConversation: preferredModeForNewConversation,
                    startOrigin: .explicitUserAction
                )
                conversation = task.conversationID
                conversationID = task.conversationID
                onConversationCreated?(task.conversationID)
                started = task.run
            }
            launch.callsCenterDone = true
            launch.conversationID = conversation
            launch.runID = started.runID
            // Attachments are durably owned by the created run now.
            let acceptedAttachments = launch.attachments
            launch.attachments = []
            if launch.cancelled {
                // A late start returned after cancellation: cancel that exact
                // run and yield nothing (the barrier owns this guarantee).
                await center.cancel(runID: started.runID)
                settle(launch)
                return
            }
            activeRunID = started.runID
            onAttachmentsConsumed?(acceptedAttachments)
            await watch(launch, runID: started.runID, conversationID: conversation, result: started.result)
        } catch {
            // Pre-launch failure: the user's words are restored by the
            // coordinator (failed-before-output) and attachments are restored
            // through `defer` above unless the host already pushed a newer
            // snapshot.
            if launch.cancelled || launch.terminalHandled {
                settle(launch)
                return
            }
            report("launchFailed", String(describing: type(of: error)))
            deliver(launch, .failed(message: "voice.error.turn"))
            settle(launch)
        }
    }

    // MARK: - Attachments snapshot discipline

    private func consumeAttachments(for launch: Launch) {
        var refs = pendingAttachments
        if let target = conversationID, center.isTemporaryConversation(target) {
            // Temporary text-only ceiling: validate against the center's own
            // authority, drop WITHOUT consuming (the host hides intake; a
            // staged set that cannot launch must not vanish silently from
            // the composer either — dropping here keeps the composer state
            // authoritative, so clear the driver's snapshot only).
            if !refs.isEmpty { report("attachmentsRefusedTemporary", "count=\(refs.count)") }
            refs = []
        }
        launch.attachments = refs
        launch.attachmentGenerationAtConsume = attachmentGeneration
        pendingAttachments = []
    }

    /// Restore consumed attachments only while the host has not staged a
    /// newer snapshot since the consume, and only before a run owns them.
    private func restoreAttachmentsIfNeeded(for launch: Launch) {
        guard !launch.attachments.isEmpty else { return }
        if attachmentGeneration == launch.attachmentGenerationAtConsume {
            pendingAttachments = launch.attachments
        }
        launch.attachments = []
    }

    private func restoreAttachments(for launch: Launch) {
        restoreAttachmentsIfNeeded(for: launch)
    }

    // MARK: - Watching one run

    private func watch(
        _ launch: Launch,
        runID: UUID,
        conversationID: UUID,
        result: Task<Result<Void, Error>, Never>
    ) async {
        // The service may already exist (sync launch), appear later, or never
        // appear at all (fast completion). Only a settled terminal or an
        // explicit cancellation wins; an observer ending without terminal
        // must leave the other sources working.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.sessionLoop(launch: launch, runID: runID, conversationID: conversationID)
            }
            group.addTask { [weak self] in
                await self?.serviceLoop(launch: launch, runID: runID)
            }
            group.addTask { [weak self] in
                await self?.watchResult(launch: launch, runID: runID,
                    conversationID: conversationID, result: result)
            }
            while await group.next() != nil {
                if launch.terminalHandled || launch.cancelled || Task.isCancelled {
                    group.cancelAll()
                    break
                }
            }
        }
        if launch.terminalHandled || launch.cancelled { settle(launch) }
    }

    private func watchResult(launch: Launch, runID: UUID, conversationID: UUID,
                             result: Task<Result<Void, Error>, Never>) async {
        let outcome = await result.value
        guard !launch.terminalHandled, !launch.cancelled, !Task.isCancelled else { return }
        switch outcome {
        case .failure:
            await finalizeFromStore(launch: launch, runID: runID,
                conversationID: conversationID, stateHint: "failed")
        case .success:
            await finalizeFromStore(launch: launch, runID: runID,
                conversationID: conversationID, stateHint: nil)
        }
    }

    /// Session projection: caches published snapshots (the store-truth text
    /// source), and catches run-terminal BEFORE any service exists (fast
    /// completion) as well as terminal states the service stream may miss.
    private func sessionLoop(
        launch: Launch,
        runID: UUID,
        conversationID: UUID
    ) async {
        for await snapshot in center.sessionEvents(conversationID: conversationID) {
            if Task.isCancelled || launch.cancelled || launch.terminalHandled { return }
            launch.latestMessages = snapshot.messages
            guard let run = snapshot.runs.first(where: { $0.id == runID }) else { continue }
            if RunStateLocalizer.isTerminal(run.state) {
                await finalizeFromStore(launch: launch, runID: runID, conversationID: conversationID, stateHint: run.state)
                return
            }
        }
    }

    /// Waits (bounded polling on the main actor) for the run service to
    /// exist, then reconciles visible text from monotonic snapshots.
    private func serviceLoop(launch: Launch, runID: UUID) async {
        while !Task.isCancelled, !launch.cancelled, !launch.terminalHandled {
            if let service = center.service(for: runID) {
                await consumeServiceEvents(launch, service: service)
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func consumeServiceEvents(_ launch: Launch, service: ConversationRunService) async {
        // Subscribe BEFORE the first snapshot: nothing is missed at the
        // boundary. Snapshot values then flow through the segment aggregator,
        // so tool/reasoning segment resets neither duplicate nor drop audio.
        let stream = service.events()
        let initial = await service.snapshot()
        reconcileSnapshot(launch, initial)
        if initial.isTerminal {
            await finalizeFromStore(launch: launch, runID: service.runID, conversationID: service.conversationID, stateHint: nil)
            return
        }
        for await event in stream {
            if launch.cancelled || launch.terminalHandled || Task.isCancelled { return }
            switch event {
            case .terminal(let terminal):
                let snapshot = await service.snapshot()
                reconcileSnapshot(launch, snapshot)
                switch terminal {
                case .completed:
                    await finalizeFromStore(launch: launch, runID: service.runID, conversationID: service.conversationID, stateHint: "completed")
                case .failed:
                    await finalizeFromStore(launch: launch, runID: service.runID, conversationID: service.conversationID, stateHint: "failed")
                default:
                    await finalizeFromStore(launch: launch, runID: service.runID, conversationID: service.conversationID, stateHint: "cancelled")
                }
                return
            default:
                // Any other lifecycle signal (answer delta, tool boundary,
                // steer consumed, reasoning restart) is a wake-up: read the
                // authoritative snapshot and aggregate. Payload contents of
                // reasoning/tool events are never inspected here.
                let snapshot = await service.snapshot()
                reconcileSnapshot(launch, snapshot)
            }
        }
        // The service channel ended without a terminal (store torn down):
        // the session/result paths own finalization.
    }

    /// One authoritative snapshot → DISPLAY ONLY.
    ///
    /// Speech is driven exclusively by the CONFIRMED final body delivered at
    /// `.completed` (see `finalizeFromStore` → `FinalAnswerSpeech.answer` →
    /// `AnswerSpeechText` whole-body projection). The driver deliberately never emits the
    /// speculative `.finalAnswerUpdated`/`.finalAnswerRetracted` projection:
    /// confirmed-final-body-only removes any possibility of speaking tool
    /// progress or intermediate commentary, and of retract/replay. The
    /// coordinator keeps those handlers as defensive no-op-safe paths for any
    /// future driver, but this canonical driver does not use them.
    private func reconcileSnapshot(_ launch: Launch, _ snapshot: ConversationRunService.Snapshot) {
        guard !launch.cancelled, !launch.terminalHandled else { return }
        launch.aggregator.applySnapshot(snapshot.streamedText)
        let roundText = launch.aggregator.cumulative
        if roundText != launch.published {
            launch.published = roundText
            deliver(launch, .answerUpdated(cumulativeText: roundText))
        }
    }

    /// Terminal truth: the canonical durable assistant rows for this exact
    /// run. A publish may lag the terminal event by one revision, so the
    /// cached snapshot is refreshed with a bounded wait when it lacks text.
    /// FINAL-ANSWER determination uses the primary's canonical
    /// `FinalAnswerSpeech.answer(runID:events:messages:)` (durable event
    /// order, last tool boundary respected — never keyword guessing). The
    /// whole confirmed body is projected with URLs retained; the coordinator's
    /// selected-source normalizer applies the local Read-links policy before
    /// sentence splitting (fenced code blocks span units, so per-unit
    /// stripping would be unsafe). The raw round text stays available to the
    /// UI via `.answerUpdated`.
    private func finalizeFromStore(
        launch: Launch,
        runID: UUID,
        conversationID: UUID,
        stateHint: String?
    ) async {
        guard !launch.terminalHandled else { return }
        // `terminalHandled` is the PUBLICATION fence, not an in-flight
        // marker. The old watch loop cancelled siblings on its first return.
        // Setting it before the awaits below let a duplicate terminal source
        // return immediately and cancel the real finalizer; GRDB then throws
        // CancellationError and the round silently completes with no speech.
        // Concurrent watchers may repeat read-only resolution, but exactly one
        // may publish through the second guard below.
        var messages = launch.latestMessages
        var roundText = Self.assistantText(for: runID, in: messages)
        if roundText.isEmpty {
            // A publish may lag the terminal by one revision: bounded wait.
            for _ in 0..<6 {
                if launch.cancelled || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(200))
                guard !launch.cancelled, !Task.isCancelled else { break }
                if let snapshot = await nextSessionSnapshot(conversationID: conversationID) {
                    messages = snapshot.messages
                    roundText = Self.assistantText(for: runID, in: snapshot.messages)
                    if !roundText.isEmpty { break }
                }
            }
        }
        if roundText.isEmpty { roundText = launch.published }
        // Canonical final-answer text from durable event order. ONLY a
        // SUCCESSFUL store read may feed the canonical helper: a storage
        // error is never turned into an empty-events legacy fallback, and
        // no live segment or joined round text is ever substituted as the
        // spoken body. An unconfirmed final fails visibly instead.
        var finalAnswer: String?
        do {
            let events = try await center.runStore(for: conversationID).events(runID: runID)
            finalAnswer = FinalAnswerSpeech.answer(runID: runID, events: events, messages: messages)?.text
        } catch {
            finalAnswer = nil
            // Losing observers and explicit stops can cancel their reads
            // after another path has already settled the launch.
            if !launch.terminalHandled, !launch.cancelled {
                let failure = error as NSError
                FloeLogger(category: .app).warning(
                    "voiceFinalReadFailed taskCancelled=\(Task.isCancelled) errorCancelled=\(error is CancellationError) domain=\(failure.domain) code=\(failure.code)")
                report("finalAnswerUnconfirmed", "events")
            }
        }
        guard !launch.cancelled else { settle(launch); return }
        // The MainActor serializes this check and publication: only the first
        // fully resolved finalizer may emit a terminal turn event and settle.
        guard !launch.terminalHandled else { return }
        launch.terminalHandled = true
        launch.terminal = true
        if activeRunID == runID { activeRunID = nil }
        let state = stateHint ?? "completed"
        if state == "completed", finalAnswer == nil {
            // A completed run without a CONFIRMED final is not a successful
            // zero-audio answer. Surface the existing actionable failure;
            // never substitute display-only joined/intermediate text.
            report("finalAnswerUnconfirmed", "missing")
            deliver(launch, .failed(message: "voice.error.turn"))
            settle(launch)
            return
        }
        switch state {
        case "failed", "recoveryFailed":
            report("roundTerminal", state)
            deliver(launch, .failed(message: "voice.error.turn"))
        case "completed":
            if !roundText.isEmpty, roundText != launch.published {
                launch.published = roundText
                deliver(launch, .answerUpdated(cumulativeText: roundText))
            }
            // Speech body: the CONFIRMED final only. The joined round text
            // stays display-only (never spoken). A real confirmed body whose
            // speech projection is legitimately empty (for example code or
            // media-only content) still completes normally.
            let speechText = AnswerSpeechText.spokenText(
                finalAnswer ?? "", destination: .cloud)
            // completed carries ONLY the final-answer body. The coordinator's
            // selected-source projection may legitimately turn a URL-only body
            // into zero units; that completes silently, never as empty synth.
            // The whole round is never replayed into speech.
            deliver(launch, .completed(fullText: speechText))
        default:
            deliver(launch, .cancelled)
        }
        settle(launch)
    }

    private func nextSessionSnapshot(conversationID: UUID) async -> ConversationSessionSnapshot? {
        let snapshots = center.sessionEvents(conversationID: conversationID)
        return await withTaskGroup(of: ConversationSessionSnapshot?.self) { group in
            group.addTask {
                for await snapshot in snapshots {
                    return snapshot
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    // MARK: - Helpers

    private func deliver(_ launch: Launch, _ event: VoiceConversationTurnEvent) {
        guard !launch.cancelled, let send = launch.send else { return }
        send(event)
    }

    private func report(_ code: String, _ detail: String = "") {
        diagnostics?.voiceConversation(code, detail)
    }

    private func settle(_ launch: Launch) {
        launch.send = nil
        restoreAttachmentsIfNeeded(for: launch)
        if !launch.isSettled {
            finishedOrder.append(launch.token)
            launch.markSettled()
        }
    }

    private func pruneFinishedLaunches() {
        guard launches.count > 24 else { return }
        while launches.count > 24 {
            guard let idx = finishedOrder.firstIndex(where: {
                guard let launch = launches[$0] else { return true }
                return launch.terminalHandled || launch.cancelled
            }) else { break }
            let token = finishedOrder.remove(at: idx)
            launches[token] = nil
        }
    }

    /// Assistant messages of exactly this run, joined in creation order
    /// (full visible round text for display). Reasoning lives in separate
    /// roles/parts and never matches here.
    private static func assistantText(for runID: UUID, in messages: [PersistedMessage]) -> String {
        let matching = messages
            .filter { $0.runID == runID && $0.role == "assistant" }
            .sorted { $0.createdAt < $1.createdAt }
        return matching
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// First line, whitespace-collapsed, ≤ 40 characters — the minimal title
    /// treatment a typed Home first message would get.
    private static func defaultTitle(_ text: String) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { line in
                line.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                    .joined(separator: " ")
            } ?? text
        let trimmed = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(39)) + "…"
    }
}

#endif
