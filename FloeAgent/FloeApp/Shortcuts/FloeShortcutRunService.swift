// FloeApp — Exact-run service for App Intents and Shortcuts automation.
//
// ONE shared app environment (owned by FloeAgentApp) is projected here as a
// thin, testable service: start an ordinary durable task, read exact-run
// status/text, bounded wait, and cancel with truthful confirmation. Every
// read is scoped to the requested run ID; a conversation's "latest run" is
// never inferred, and notes/temporary conversations are rejected. No new
// runtime, database pool, permission grant, or global singleton is created.
//
// Read/status/wait/cancel join the durable-launch readiness layer only: an
// existing run can be inspected without a currently configured provider or
// model. `start` is the single action that requires the full external-
// automation readiness and a default model.
//
// The DTOs below are plain Sendable value types so the App Intent/entity
// layer can render them without touching stores or the runtime.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

// MARK: - Access mode

/// Read paths must not require a configured model; starting new work does.
enum FloeShortcutAccess: Sendable, Equatable {
    case read
    case start
}

// MARK: - Exact run value types

/// System-facing lifecycle vocabulary. Execution phases are normalized to
/// `.running`; the exact durable string stays available in `rawStateName`.
enum FloeRunState: String, Sendable, CaseIterable {
    case running
    case waitingApproval
    case paused
    case checkpointed
    case completed
    case failed
    case cancelled
    case interrupted
    case unavailable
}

/// Durable terminal marker payload written by the runtime after the final
/// assistant message is persisted.
enum FloeRunTerminalStopReason: String, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case cancelled
    case budgetLimited
    case noProgress
}

/// Why a run cannot be described truthfully.
enum FloeRunUnavailableReason: String, Sendable {
    case runNotFound
    case conversationMissing
    case notesConversation
    case temporaryConversation
    case terminalMissingOrCorrupt
    case stateUnrecognized
    case durableReadFailed
}

/// A truthful snapshot of one exact durable run.
struct FloeRunStatus: Sendable, Equatable {
    var runID: UUID?
    var conversationID: UUID?
    /// Conversation title; falls back to the run goal when the title is blank.
    var title: String?
    var goal: String?
    var state: FloeRunState
    /// Exact durable `RunRecord.state`, e.g. "cancelling" or "verifying".
    var rawStateName: String?
    var terminalStopReason: FloeRunTerminalStopReason?
    var unavailableReason: FloeRunUnavailableReason?
    /// Present only when the tail event scan observed the marker.
    var hasNoFinalTextError: Bool
    var hasOutputTruncatedNotice: Bool
    var startedAt: Date?
    var endedAt: Date?
    /// The durable header claims the run ended. A corrupt-finished run keeps
    /// this true while reporting `.unavailable` — never fabricated success.
    var finishedPerDurableRecord: Bool
    /// Proof that this run's normal completion path saved its final reply:
    /// the durable header is `completed`, exactly one valid terminal marker
    /// exists, that marker's payload carries the exact final-message id, and
    /// no `noFinalText` marker was recorded. Failure, cancellation and
    /// interruption paths never persist a final assistant message, so their
    /// stored assistant rows are not a text result.
    var finalReplyProven: Bool

    init(
        runID: UUID? = nil,
        conversationID: UUID? = nil,
        title: String? = nil,
        goal: String? = nil,
        state: FloeRunState,
        rawStateName: String? = nil,
        terminalStopReason: FloeRunTerminalStopReason? = nil,
        unavailableReason: FloeRunUnavailableReason? = nil,
        hasNoFinalTextError: Bool = false,
        hasOutputTruncatedNotice: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        finishedPerDurableRecord: Bool = false,
        finalReplyProven: Bool = false
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.title = title
        self.goal = goal
        self.state = state
        self.rawStateName = rawStateName
        self.terminalStopReason = terminalStopReason
        self.unavailableReason = unavailableReason
        self.hasNoFinalTextError = hasNoFinalTextError
        self.hasOutputTruncatedNotice = hasOutputTruncatedNotice
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finishedPerDurableRecord = finishedPerDurableRecord
        self.finalReplyProven = finalReplyProven
    }

    static func unavailable(
        runID: UUID? = nil,
        conversationID: UUID? = nil,
        goal: String? = nil,
        rawStateName: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        finishedPerDurableRecord: Bool = false,
        reason: FloeRunUnavailableReason
    ) -> FloeRunStatus {
        FloeRunStatus(
            runID: runID,
            conversationID: conversationID,
            goal: goal,
            state: .unavailable,
            rawStateName: rawStateName,
            unavailableReason: reason,
            startedAt: startedAt,
            endedAt: endedAt,
            finishedPerDurableRecord: finishedPerDurableRecord
        )
    }

    /// Approval / pause / checkpoint all need explicit user or app action.
    var requiresUserAction: Bool {
        state == .waitingApproval || state == .paused || state == .checkpointed
    }

    /// Terminal lifecycle states; `.unavailable` is deliberately separate.
    var isTerminalLifecycle: Bool {
        state == .completed || state == .failed
            || state == .cancelled || state == .interrupted
    }

    /// Only a verified normal completion with a PROVEN durable final reply
    /// (the terminal marker's exact message id) and no truncation notice
    /// counts as full success. A `maxTokens`/`budgetLimited`/`noProgress`
    /// completion stays `.completed` but is never full success, and neither
    /// is a legacy/corrupt run whose terminal proves no final message.
    var isFullSuccess: Bool {
        guard state == .completed else { return false }
        guard terminalStopReason == .endTurn || terminalStopReason == .stopSequence else {
            return false
        }
        return finalReplyProven && !hasNoFinalTextError && !hasOutputTruncatedNotice
    }
}

/// Result of starting one durable ordinary task through the shared center.
struct FloeRunStartReceipt: Sendable, Equatable {
    var runID: UUID
    var conversationID: UUID
}

/// Outcome of a bounded wait. `budgetExhausted` and `waitCancelled` never
/// stop the run and never invent a terminal state.
enum FloeRunWaitOutcome: Sendable {
    case terminalReached(FloeRunStatus)
    case userActionRequired(FloeRunStatus)
    case budgetExhausted(FloeRunStatus)
    case waitCancelled(FloeRunStatus)

    var status: FloeRunStatus {
        switch self {
        case .terminalReached(let status), .userActionRequired(let status),
             .budgetExhausted(let status), .waitCancelled(let status):
            status
        }
    }
}

/// Explicit reasons a stored reply is not a trustworthy full answer.
enum FloeRunTextCaveat: String, Sendable {
    case tokenLimitReached
    case budgetLimited
    case noProgress
    /// A provider completion whose stop reason was `cancelled` still saved
    /// the text it produced before stopping.
    case cancelledMidRun
    case outputSizeCapped
}

enum FloeRunTextAbsentReason: String, Sendable {
    /// The runtime recorded that no final assistant reply was persisted.
    case noFinalText
    /// The run ended through failure/cancellation/interruption, which never
    /// persists a final assistant message; any stored assistant row may be an
    /// intermediate tool step, so no text is exported without proof.
    case finalReplyNotPersisted
    /// The exact run's assistant rows exist only as intermediate steps, or
    /// the proven final row was empty/persisted without text.
    case noAssistantTextPersisted
    /// The durable terminal marker carries no trustworthy final-message
    /// identity (missing/corrupt/legacy marker, or the referenced row does
    /// not resolve to an assistant message of this exact run and owner).
    /// Nothing is inferred from "latest row" ordering in its place.
    case finalReplyUnproven
}

enum FloeRunTextCompleteness: Sendable, Equatable {
    case complete
    case partial([FloeRunTextCaveat])
    case absent(FloeRunTextAbsentReason)
    /// Non-terminal, rejected, unknown or corrupt: never claim an answer.
    case untrustworthy
}

struct FloeRunTextResult: Sendable {
    var status: FloeRunStatus
    var text: String?
    var completeness: FloeRunTextCompleteness
}

/// Truthful cancellation observation. `requested` is true only when this
/// process actually owned a live run and asked the center to cancel it.
struct FloeRunCancelResult: Sendable {
    var requested: Bool
    var alreadyFinished: Bool
    /// Unfinished durable header with no current-process owner; nothing was
    /// cancelled and no "cancelled" state is fabricated.
    var noLiveOwner: Bool
    var confirmedTerminalState: FloeRunState?
    var status: FloeRunStatus
}

/// The task handoff passed to the App's center in the live wiring.
struct FloeShortcutStartRequest: Sendable {
    /// Original prompt (only outer whitespace trimmed). The center runs its
    /// secret-ingress scanner and owns credential capture — never pre-scrub
    /// or drop captures here.
    var goal: String
    /// Redacted, human-readable title; never derived from raw secret values.
    var title: String
    var provider: ProviderProfile
    var model: ModelProfile
}

// MARK: - Title sanitizer

/// Titles are persisted separately from the goal and do NOT pass through the
/// center's secret-ingress scanner, so they are redacted here. The scanner
/// projection replaces labeled credential values with opaque
/// `⟨credential:…⟩` placeholders that belong to captures this title can never
/// own; those placeholders are collapsed to `SecretRedactor.replacement`, and
/// credential-shaped text the scanner intentionally leaves alone (bearer
/// tokens, `sk-…`, long key/token values) is masked by `SecretRedactor`.
/// The prompt itself is never altered: the center's capture semantics stay.
enum FloeShortcutTitleSanitizer {
    static func resolve(prompt: String, explicitTitle: String?) -> String {
        if let explicit = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let redacted = redacted(explicit)
            return redacted.isEmpty ? SecretRedactor.replacement : redacted
        }
        let derived = String(redacted(prompt).trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return derived.isEmpty ? SecretRedactor.replacement : derived
    }

    /// Secret-safe projection used for titles only (never for the goal).
    static func redacted(_ text: String) -> String {
        let scanned = SecretIngressScanner.scan(text).sanitizedText
        return SecretRedactor.redact(collapsingCredentialPlaceholders(in: scanned))
    }

    private static func collapsingCredentialPlaceholders(in text: String) -> String {
        guard text.contains("⟨credential:") else { return text }
        guard let expression = try? NSRegularExpression(
            pattern: #"⟨credential:[0-9A-Fa-f-]{36}⟩"#
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: SecretRedactor.replacement)
        )
    }
}

// MARK: - Injectable dependencies

/// Everything the service needs, as Sendable closures. Production wiring lives
/// in `AppEnvironment.floeShortcutRunService()`; deterministic tests inject
/// their own stores/clock/start/cancel. No global test override exists.
///
/// Closures that reach the App's MainActor services are `@MainActor` so the
/// live environment is never captured as a non-Sendable value by a detached
/// task. Durable store reads stay plain `@Sendable`: the protocols themselves
/// are Sendable and do not depend on the UI graph.
struct FloeShortcutRunDeps: Sendable {
    var ensureReady: @MainActor @Sendable (FloeShortcutAccess) async throws -> Void
    var capabilityEnabled: @Sendable () -> Bool
    var defaultModel: @MainActor @Sendable () async -> (provider: ProviderProfile, model: ModelProfile)?
    var startTask: @MainActor @Sendable (FloeShortcutStartRequest) async throws -> FloeRunStartReceipt
    var cancelRun: @MainActor @Sendable (UUID) async -> Void
    var hasLiveOwner: @MainActor @Sendable (UUID) async -> Bool
    var loadRun: @Sendable (UUID) async throws -> RunRecord?
    var loadConversation: @Sendable (UUID) async throws -> ConversationRecord?
    var recentRunEvents: @Sendable (UUID, Int) async throws -> [RunEventRecord]
    var earlierRunEvents: @Sendable (UUID, Int, Int) async throws -> [RunEventRecord]
    /// The proven final-reply row only: resolves the terminal marker's exact
    /// message id against this run + owner + assistant role (root's
    /// `SQLiteRunReplyReader.provenFinalReplyText` in production). Never a
    /// conversation-wide, latest-row or reasoning-bearing read.
    var provenFinalReplyText: @Sendable (UUID, UUID, UUID) async throws -> String?
    var monotonicNow: @Sendable () -> TimeInterval
    var pause: @Sendable (TimeInterval) async -> Void

    init(
        ensureReady: @escaping @MainActor @Sendable (FloeShortcutAccess) async throws -> Void,
        capabilityEnabled: @escaping @Sendable () -> Bool,
        defaultModel: @escaping @MainActor @Sendable () async -> (provider: ProviderProfile, model: ModelProfile)?,
        startTask: @escaping @MainActor @Sendable (FloeShortcutStartRequest) async throws -> FloeRunStartReceipt,
        cancelRun: @escaping @MainActor @Sendable (UUID) async -> Void,
        hasLiveOwner: @escaping @MainActor @Sendable (UUID) async -> Bool,
        loadRun: @escaping @Sendable (UUID) async throws -> RunRecord?,
        loadConversation: @escaping @Sendable (UUID) async throws -> ConversationRecord?,
        recentRunEvents: @escaping @Sendable (UUID, Int) async throws -> [RunEventRecord],
        earlierRunEvents: @escaping @Sendable (UUID, Int, Int) async throws -> [RunEventRecord],
        provenFinalReplyText: @escaping @Sendable (UUID, UUID, UUID) async throws -> String?,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            FloeShortcutServiceSystemClock.monotonicNow()
        },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            await FloeShortcutServiceSystemClock.pause(seconds)
        }
    ) {
        self.ensureReady = ensureReady
        self.capabilityEnabled = capabilityEnabled
        self.defaultModel = defaultModel
        self.startTask = startTask
        self.cancelRun = cancelRun
        self.hasLiveOwner = hasLiveOwner
        self.loadRun = loadRun
        self.loadConversation = loadConversation
        self.recentRunEvents = recentRunEvents
        self.earlierRunEvents = earlierRunEvents
        self.provenFinalReplyText = provenFinalReplyText
        self.monotonicNow = monotonicNow
        self.pause = pause
    }
}

// MARK: - Service

/// Actor-isolated exact-run service. Stateless beyond its injected deps, so
/// the App can create one per call without a second environment or graph.
actor FloeShortcutRunService {
    static let defaultWaitBudget: TimeInterval = 20
    static let minimumWaitBudget: TimeInterval = 1
    static let maximumWaitBudget: TimeInterval = 30
    static let waitPollInterval: TimeInterval = 0.5
    static let cancellationConfirmationWindow: TimeInterval = 2
    static let cancellationPollInterval: TimeInterval = 0.2
    static let terminalEventPageSize = 24
    static let terminalEventPageBudget = 4

    private static let runningStateNames: Set<String> = [
        "preparing", "streamingModel", "executingTool", "compacting",
        "verifying", "cancelling", "idle"
    ]
    private static let finishedStateNames: Set<String> = [
        "completed", "failed", "checkpointed", "interrupted", "cancelled"
    ]
    private static let textSignalStateNames: Set<String> = [
        "completed", "failed", "interrupted", "cancelled"
    ]

    private let deps: FloeShortcutRunDeps

    init(deps: FloeShortcutRunDeps) {
        self.deps = deps
    }

    // MARK: Start

    /// Creates an ordinary durable task through the shared center. Returns
    /// once the conversation/run rows exist; provider work continues in the
    /// app. The original prompt goes to the center untouched (secret capture
    /// stays the center's job); only the persisted title is redacted.
    func start(prompt: String, title: String?) async throws -> FloeRunStartReceipt {
        try await prepareCall(.start)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { throw FloeShortcutRunError.emptyTaskPrompt }
        let resolvedTitle = FloeShortcutTitleSanitizer.resolve(
            prompt: cleanPrompt,
            explicitTitle: title
        )
        guard let pair = await deps.defaultModel() else {
            throw FloeShortcutRunError.noDefaultModelConfigured
        }
        return try await deps.startTask(FloeShortcutStartRequest(
            goal: cleanPrompt,
            title: resolvedTitle,
            provider: pair.provider,
            model: pair.model
        ))
    }

    // MARK: Status

    func status(runID: UUID) async throws -> FloeRunStatus {
        try await prepareCall(.read)
        return await inspect(runID: runID, scanTextSignals: false).status
    }

    // MARK: Text result

    /// The exact run's persisted final assistant text, gated on a trustworthy
    /// terminal and honest completion markers. Never reasoning, tool
    /// summaries, an intermediate "I will check" step, or another run's reply.
    func textResult(runID: UUID) async throws -> FloeRunTextResult {
        try await prepareCall(.read)
        let inspection = await inspect(runID: runID, scanTextSignals: true)
        let status = inspection.status
        guard let durableRunID = status.runID, let conversationID = status.conversationID else {
            return FloeRunTextResult(status: status, text: nil, completeness: .untrustworthy)
        }
        switch status.state {
        case .running, .waitingApproval, .paused, .checkpointed, .unavailable:
            return FloeRunTextResult(status: status, text: nil, completeness: .untrustworthy)
        case .completed, .failed, .cancelled, .interrupted:
            break
        }
        // The runtime writes this marker after persisting any pre-tool step
        // and before the terminal event when no final assistant reply exists.
        // A stored row is then a step, never the answer: return an explicit
        // absence instead of falling back to earlier non-empty text or asking
        // the reader for "the last non-empty message".
        if status.hasNoFinalTextError {
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.noFinalText)
            )
        }
        // Without the terminal marker's exact message identity there is no
        // final result: exception headers (failed/cancelled-by-state/
        // interrupted) never run the normal completion path, and a `completed`
        // header whose terminal proves no message (missing/corrupt/legacy
        // marker) must never fall back to "the latest assistant row", which
        // can be a pre-tool "I will check" step. (A provider completion whose
        // stop reason is `cancelled` keeps the `completed` durable header and
        // is proven by its marker.)
        guard status.finalReplyProven else {
            return FloeRunTextResult(
                status: status,
                text: nil,
                completeness: .absent(
                    status.rawStateName == "completed"
                        ? .finalReplyUnproven : .finalReplyNotPersisted
                )
            )
        }
        guard let finalMessageID = inspection.facts.finalMessageID else {
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.finalReplyUnproven)
            )
        }
        let storedText: String?
        do {
            storedText = try await deps.provenFinalReplyText(
                durableRunID, conversationID, finalMessageID
            )
        } catch {
            return FloeRunTextResult(status: status, text: nil, completeness: .untrustworthy)
        }
        guard let storedText else {
            // The proven id does not resolve to an assistant row of this
            // exact run and owner (foreign/forged/deleted): honest absence,
            // never a latest-row substitute.
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.finalReplyUnproven)
            )
        }
        let text = storedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.noAssistantTextPersisted)
            )
        }
        var caveats: [FloeRunTextCaveat] = []
        switch status.state {
        case .cancelled:
            // A provider completion that stopped with `cancelled` still saved
            // its final reply before the terminal marker.
            caveats.append(.cancelledMidRun)
        case .completed:
            switch status.terminalStopReason {
            case .maxTokens:
                caveats.append(.tokenLimitReached)
            case .budgetLimited:
                caveats.append(.budgetLimited)
            case .noProgress:
                caveats.append(.noProgress)
            default:
                break
            }
        default:
            break
        }
        if status.hasOutputTruncatedNotice {
            caveats.append(.outputSizeCapped)
        }
        return FloeRunTextResult(
            status: status,
            text: text,
            completeness: caveats.isEmpty ? .complete : .partial(caveats)
        )
    }

    // MARK: Bounded wait

    /// Polls the exact durable run until a terminal/user-action state or the
    /// budget runs out (default 20s, floor 1s, hard cap 30s). Cancelling the
    /// WAITING action only abandons this wait: the run keeps executing and no
    /// cancel call is ever made here.
    func wait(runID: UUID, timeout: TimeInterval?) async throws -> FloeRunWaitOutcome {
        try await prepareCall(.read)
        let requested = timeout ?? Self.defaultWaitBudget
        let budget = min(max(requested, Self.minimumWaitBudget), Self.maximumWaitBudget)
        let deadline = deps.monotonicNow() + budget
        var latest = await inspect(runID: runID, scanTextSignals: false).status
        while true {
            if Task.isCancelled { return .waitCancelled(latest) }
            if latest.requiresUserAction { return .userActionRequired(latest) }
            if latest.isTerminalLifecycle || latest.state == .unavailable {
                return .terminalReached(latest)
            }
            let remaining = deadline - deps.monotonicNow()
            if remaining <= 0 { return .budgetExhausted(latest) }
            await deps.pause(min(Self.waitPollInterval, remaining))
            latest = await inspect(runID: runID, scanTextSignals: false).status
        }
    }

    // MARK: Cancel

    /// Requests cancellation only for an exact ordinary durable run that this
    /// process still owns, then reports what the durable state actually shows.
    /// A racing normal completion is reported as completed, not cancelled.
    func cancel(runID: UUID) async throws -> FloeRunCancelResult {
        try await prepareCall(.read)
        let initial = await inspect(runID: runID, scanTextSignals: false).status
        guard initial.runID != nil else {
            return FloeRunCancelResult(
                requested: false, alreadyFinished: false, noLiveOwner: false,
                confirmedTerminalState: nil, status: initial
            )
        }
        guard !initial.finishedPerDurableRecord else {
            return FloeRunCancelResult(
                requested: false, alreadyFinished: true, noLiveOwner: false,
                confirmedTerminalState: initial.state, status: initial
            )
        }
        let liveOwner = await deps.hasLiveOwner(runID)
        guard liveOwner else {
            return FloeRunCancelResult(
                requested: false, alreadyFinished: false, noLiveOwner: true,
                confirmedTerminalState: nil, status: initial
            )
        }
        await deps.cancelRun(runID)
        let deadline = deps.monotonicNow() + Self.cancellationConfirmationWindow
        var latest = initial
        while true {
            // A cancelled caller stops observing immediately instead of
            // polling on its own; the cancel request above already reached
            // the center's exact run.
            if Task.isCancelled { break }
            latest = await inspect(runID: runID, scanTextSignals: false).status
            if latest.finishedPerDurableRecord { break }
            // Never sleep past the window, so a monotonic deadline is honored
            // even with floating-point poll intervals.
            let remaining = deadline - deps.monotonicNow()
            if remaining <= 0 { break }
            await deps.pause(min(Self.cancellationPollInterval, remaining))
        }
        return FloeRunCancelResult(
            requested: true,
            alreadyFinished: false,
            noLiveOwner: false,
            confirmedTerminalState: latest.finishedPerDurableRecord ? latest.state : nil,
            status: latest
        )
    }

    // MARK: - Internals

    private struct Inspection: Sendable {
        var status: FloeRunStatus
        var facts: TerminalFacts
    }

    private struct TerminalFacts: Sendable {
        var scanned = false
        var terminalCount = 0
        var terminalStopReason: FloeRunTerminalStopReason?
        var terminalCorrupt = false
        /// The exact assistant-message id the terminal marker designated as
        /// this run's final reply. Written by the runtime only after the row
        /// actually persisted (normal save) or the verification CONFIRM bound
        /// the sealed draft. Absent = no proof; never inferred.
        var finalMessageID: UUID?
        var hasNoFinalTextError = false
        var hasOutputTruncatedNotice = false
        var reachedThreadStart = false
        /// Highest sequence of a flushed assistant text segment seen in the
        /// bounded tail. A normal completion flushes the final answer here
        /// immediately before the terminal marker.
        var latestAssistantTextSequence: Int?
        /// Highest sequence of any tool request/result seen in the tail. A
        /// tool event after the last assistant text proves that text was a
        /// pre-tool step rather than the final answer.
        var latestToolSequence: Int?
    }

    private func prepareCall(_ access: FloeShortcutAccess) async throws {
        guard deps.capabilityEnabled() else {
            throw FloeShortcutRunError.shortcutsCapabilityDisabled
        }
        try await deps.ensureReady(access)
    }

    private func inspect(runID: UUID, scanTextSignals: Bool) async -> Inspection {
        let run: RunRecord?
        do {
            run = try await deps.loadRun(runID)
        } catch {
            return Inspection(
                status: .unavailable(runID: runID, reason: .durableReadFailed),
                facts: TerminalFacts()
            )
        }
        guard let run else {
            return Inspection(
                status: .unavailable(runID: runID, reason: .runNotFound),
                facts: TerminalFacts()
            )
        }
        let conversation: ConversationRecord?
        do {
            conversation = try await deps.loadConversation(run.conversationID)
        } catch {
            return Inspection(
                status: .unavailable(
                    runID: run.id, conversationID: run.conversationID, goal: run.goal,
                    rawStateName: run.state, startedAt: run.startedAt, endedAt: run.endedAt,
                    reason: .durableReadFailed
                ),
                facts: TerminalFacts()
            )
        }
        guard let conversation else {
            return Inspection(
                status: .unavailable(
                    runID: run.id, conversationID: run.conversationID, goal: run.goal,
                    rawStateName: run.state, startedAt: run.startedAt, endedAt: run.endedAt,
                    reason: .conversationMissing
                ),
                facts: TerminalFacts()
            )
        }
        guard conversation.purpose != .notes else {
            return Inspection(
                status: .unavailable(
                    runID: run.id, conversationID: run.conversationID, goal: run.goal,
                    rawStateName: run.state, startedAt: run.startedAt, endedAt: run.endedAt,
                    reason: .notesConversation
                ),
                facts: TerminalFacts()
            )
        }
        guard conversation.purpose != .temporary else {
            return Inspection(
                status: .unavailable(
                    runID: run.id, conversationID: run.conversationID, goal: run.goal,
                    rawStateName: run.state, startedAt: run.startedAt, endedAt: run.endedAt,
                    reason: .temporaryConversation
                ),
                facts: TerminalFacts()
            )
        }

        let facts: TerminalFacts
        if run.state == "completed"
            || (scanTextSignals && Self.textSignalStateNames.contains(run.state)) {
            facts = await scanTerminalFacts(runID: run.id)
        } else {
            facts = TerminalFacts()
        }

        var state: FloeRunState
        var unavailableReason: FloeRunUnavailableReason?
        var stopReason: FloeRunTerminalStopReason?
        switch run.state {
        case "completed":
            if facts.terminalCount == 1,
               let reason = facts.terminalStopReason,
               reason != .toolUse,
               !facts.terminalCorrupt {
                stopReason = reason
                state = reason == .cancelled ? .cancelled : .completed
            } else {
                state = .unavailable
                unavailableReason = .terminalMissingOrCorrupt
            }
        case "failed":
            state = .failed
        case "interrupted":
            state = .interrupted
        case "cancelled":
            state = .cancelled
        case "checkpointed":
            state = .checkpointed
        case "paused":
            state = .paused
        case "waitingApproval":
            state = .waitingApproval
        case let raw where Self.runningStateNames.contains(raw):
            state = .running
        default:
            state = .unavailable
            unavailableReason = .stateUnrecognized
        }

        let conversationTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The proof itself is the terminal marker's `finalMessageID`: the
        // runtime wrote it only after the final assistant row really
        // persisted, or after a real verification CONFIRM bound the sealed
        // draft. The chronological check below is only a defensive rejection
        // (a proof may never sit behind a later tool event); it is never the
        // basis for accepting text. A legacy/corrupt run without the marker
        // has no final result no matter how its rows are ordered.
        let finalTextFollowsAllTools: Bool = {
            guard let toolSequence = facts.latestToolSequence else { return true }
            guard let textSequence = facts.latestAssistantTextSequence else { return false }
            return textSequence > toolSequence
        }()
        let finalReplyProven = run.state == "completed"
            && facts.scanned
            && facts.terminalCount == 1
            && facts.terminalStopReason != nil
            && facts.terminalStopReason != .toolUse
            && !facts.terminalCorrupt
            && !facts.hasNoFinalTextError
            && facts.finalMessageID != nil
            && finalTextFollowsAllTools
        let status = FloeRunStatus(
            runID: run.id,
            conversationID: run.conversationID,
            title: conversationTitle.isEmpty ? String(run.goal.prefix(40)) : conversation.title,
            goal: run.goal,
            state: state,
            rawStateName: run.state,
            terminalStopReason: stopReason,
            unavailableReason: unavailableReason,
            hasNoFinalTextError: facts.scanned && facts.hasNoFinalTextError,
            hasOutputTruncatedNotice: facts.scanned && facts.hasOutputTruncatedNotice,
            startedAt: run.startedAt,
            endedAt: run.endedAt,
            finishedPerDurableRecord: Self.finishedStateNames.contains(run.state),
            finalReplyProven: finalReplyProven
        )
        return Inspection(status: status, facts: facts)
    }

    /// Bounded tail scan for the terminal marker and the completion-critical
    /// markers written just before it. Never loads an unbounded event thread.
    private func scanTerminalFacts(runID: UUID) async -> TerminalFacts {
        var facts = TerminalFacts()
        facts.scanned = true
        var beforeSequence: Int?
        var previousOldest: Int?
        var scannedPages = 0
        while scannedPages < Self.terminalEventPageBudget {
            let events: [RunEventRecord]
            do {
                if let beforeSequence {
                    events = try await deps.earlierRunEvents(
                        runID, beforeSequence, Self.terminalEventPageSize
                    )
                } else {
                    events = try await deps.recentRunEvents(runID, Self.terminalEventPageSize)
                }
            } catch {
                break
            }
            scannedPages += 1
            guard !events.isEmpty else {
                facts.reachedThreadStart = true
                break
            }
            for event in events.reversed() {
                switch event.kind {
                case .terminal:
                    facts.terminalCount += 1
                    if facts.terminalCount == 1 {
                        if let reason = Self.terminalStopReason(from: event.payloadJSON) {
                            facts.terminalStopReason = reason
                        } else {
                            facts.terminalCorrupt = true
                        }
                        // The final-message identity is part of the terminal
                        // marker payload. A missing or non-UUID value is not
                        // a failure by itself: it simply proves nothing, and
                        // the caller must then report an honest absence.
                        facts.finalMessageID = Self.finalMessageID(from: event.payloadJSON)
                    } else {
                        facts.terminalCorrupt = true
                    }
                case .error:
                    if Self.payloadString(event.payloadJSON, field: "message") == "noFinalText" {
                        facts.hasNoFinalTextError = true
                    }
                case .notice:
                    if Self.payloadString(event.payloadJSON, field: "message") == "outputTruncated" {
                        facts.hasOutputTruncatedNotice = true
                    }
                case .assistantText:
                    facts.latestAssistantTextSequence = max(
                        facts.latestAssistantTextSequence ?? Int.min, event.sequence)
                case .toolRequest, .toolResult:
                    facts.latestToolSequence = max(
                        facts.latestToolSequence ?? Int.min, event.sequence)
                default:
                    break
                }
            }
            guard let oldest = events.map(\.sequence).min() else { break }
            if let previousOldest, oldest >= previousOldest { break }
            if oldest <= 1 {
                facts.reachedThreadStart = true
                break
            }
            previousOldest = oldest
            beforeSequence = oldest
        }
        return facts
    }

    private nonisolated static func payloadString(
        _ payloadJSON: String,
        field: String
    ) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return object[field]
    }

    private nonisolated static func terminalStopReason(
        from payloadJSON: String
    ) -> FloeRunTerminalStopReason? {
        guard let raw = payloadString(payloadJSON, field: "stopReason") else { return nil }
        return FloeRunTerminalStopReason(rawValue: raw)
    }

    /// The exact final-message id carried by a terminal marker payload.
    /// Anything that is not a well-formed UUID (missing, empty, garbled or
    /// non-string) proves nothing and yields nil.
    private nonisolated static func finalMessageID(
        from payloadJSON: String
    ) -> UUID? {
        guard let raw = payloadString(payloadJSON, field: "finalMessageID"),
              !raw.isEmpty,
              let candidate = UUID(uuidString: raw),
              // Reject round-tripping surprises (lower-case variants are
              // accepted by UUID(uuidString:) but must still be canonical so
              // a garbled id can never silently match a real row).
              candidate.uuidString.uppercased() == raw.uppercased()
        else { return nil }
        return candidate
    }
}

// MARK: - System timing

/// Real-time seam used by the production wiring. Tests inject a virtual
/// clock/pause so wait and cancel windows are deterministic.
enum FloeShortcutServiceSystemClock {
    private static let clock = ContinuousClock()
    private static let start = clock.now

    static func monotonicNow() -> TimeInterval {
        let duration = start.duration(to: clock.now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    static func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let bounded = min(seconds, 60)
        let nanoseconds = UInt64(bounded * 1_000_000_000)
        guard nanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
