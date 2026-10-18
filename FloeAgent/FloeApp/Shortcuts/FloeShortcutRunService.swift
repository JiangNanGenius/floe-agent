// FloeApp — Exact-run service for App Intents and Shortcuts automation.
//
// ONE shared app environment (owned by FloeAgentApp) is projected here as a
// thin, testable service: start an ordinary durable task, read exact-run
// status/text, bounded wait, and cancel with truthful confirmation. Every
// read is scoped to the requested run ID; a conversation's "latest run" is
// never inferred, and notes/temporary conversations are rejected. No new
// runtime, database pool, permission grant, or global singleton is created.
//
// The DTOs below are plain Sendable value types so the App Intent/entity
// layer can render them without touching stores or the runtime.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

// MARK: - Errors

/// Machine-readable rejections surfaced to the App Intent layer. Root maps
/// these to concise product copy; no internal identifiers leak into prose.
enum FloeShortcutRunError: Error, Equatable, Sendable, LocalizedError {
    case shortcutsCapabilityDisabled
    case applicationStillStarting
    case durableStorageUnavailable
    case modelConfigurationUnavailable
    case emptyTaskPrompt
    case noDefaultModelConfigured

    var errorDescription: String? {
        switch self {
        case .shortcutsCapabilityDisabled:
            "Shortcuts is disabled in Floe Settings"
        case .applicationStillStarting:
            "Floe is still starting; retry the shortcut"
        case .durableStorageUnavailable:
            "Durable storage is unavailable. Retry after Floe finishes launching"
        case .modelConfigurationUnavailable:
            "Floe could not read the saved model configuration. Check Floe Settings"
        case .emptyTaskPrompt:
            "Task must not be empty"
        case .noDefaultModelConfigured:
            "No default Floe model is configured"
        }
    }
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
        finishedPerDurableRecord: Bool = false
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

    /// Only a verified normal completion with a durable final reply and no
    /// truncation notice counts as full success. A `maxTokens`/`budgetLimited`/
    /// `noProgress` completion stays `.completed` but is never full success.
    var isFullSuccess: Bool {
        guard state == .completed else { return false }
        guard terminalStopReason == .endTurn || terminalStopReason == .stopSequence else {
            return false
        }
        return !hasNoFinalTextError && !hasOutputTruncatedNotice
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
}

/// Explicit reasons a stored reply is not a trustworthy full answer.
enum FloeRunTextCaveat: String, Sendable {
    case tokenLimitReached
    case budgetLimited
    case noProgress
    case cancelledMidRun
    case runFailed
    case interrupted
    case outputSizeCapped
    /// A pre-tool assistant step exists but the final reply was never
    /// persisted; the stored text is a step, not the final answer.
    case stepsOnlyFinalMissing
}

enum FloeRunTextAbsentReason: String, Sendable {
    case noFinalText
    case noAssistantTextPersisted
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
struct FloeShortcutRunDeps: Sendable {
    var ensureReady: @Sendable () async throws -> Void
    var capabilityEnabled: @Sendable () -> Bool
    var defaultModel: @Sendable () async -> (provider: ProviderProfile, model: ModelProfile)?
    var startTask: @Sendable (FloeShortcutStartRequest) async throws -> FloeRunStartReceipt
    var cancelRun: @Sendable (UUID) async -> Void
    var hasLiveOwner: @Sendable (UUID) async -> Bool
    var loadRun: @Sendable (UUID) async throws -> RunRecord?
    var loadConversation: @Sendable (UUID) async throws -> ConversationRecord?
    var recentRunEvents: @Sendable (UUID, Int) async throws -> [RunEventRecord]
    var earlierRunEvents: @Sendable (UUID, Int, Int) async throws -> [RunEventRecord]
    /// Exact run+owner assistant reply (root's SQLiteRunReplyReader in
    /// production). Never a conversation-wide or reasoning-bearing read.
    var latestAssistantText: @Sendable (UUID, UUID) async throws -> String?
    var monotonicNow: @Sendable () -> TimeInterval
    var pause: @Sendable (TimeInterval) async -> Void

    init(
        ensureReady: @escaping @Sendable () async throws -> Void,
        capabilityEnabled: @escaping @Sendable () -> Bool,
        defaultModel: @escaping @Sendable () async -> (provider: ProviderProfile, model: ModelProfile)?,
        startTask: @escaping @Sendable (FloeShortcutStartRequest) async throws -> FloeRunStartReceipt,
        cancelRun: @escaping @Sendable (UUID) async -> Void,
        hasLiveOwner: @escaping @Sendable (UUID) async -> Bool,
        loadRun: @escaping @Sendable (UUID) async throws -> RunRecord?,
        loadConversation: @escaping @Sendable (UUID) async throws -> ConversationRecord?,
        recentRunEvents: @escaping @Sendable (UUID, Int) async throws -> [RunEventRecord],
        earlierRunEvents: @escaping @Sendable (UUID, Int, Int) async throws -> [RunEventRecord],
        latestAssistantText: @escaping @Sendable (UUID, UUID) async throws -> String?,
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
        self.latestAssistantText = latestAssistantText
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
        try await prepareCall()
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
        try await prepareCall()
        return await inspect(runID: runID, scanTextSignals: false).status
    }

    // MARK: Text result

    /// The exact run's persisted final assistant text, gated on a trustworthy
    /// terminal and honest completion markers. Never reasoning, tool
    /// summaries, or another run's reply.
    func textResult(runID: UUID) async throws -> FloeRunTextResult {
        try await prepareCall()
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
        let storedText: String?
        do {
            storedText = try await deps.latestAssistantText(durableRunID, conversationID)
        } catch {
            return FloeRunTextResult(status: status, text: nil, completeness: .untrustworthy)
        }
        let text = storedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(text?.isEmpty ?? true)

        if status.hasNoFinalTextError {
            // The runtime recorded "no final reply" after persisting any tool
            // steps. A stored row is then a pre-tool step, never the answer.
            if hasText, let text {
                return FloeRunTextResult(
                    status: status,
                    text: text,
                    completeness: .partial([.stepsOnlyFinalMissing])
                )
            }
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.noFinalText)
            )
        }
        guard hasText, let text else {
            return FloeRunTextResult(
                status: status, text: nil, completeness: .absent(.noAssistantTextPersisted)
            )
        }
        var caveats: [FloeRunTextCaveat] = []
        switch status.state {
        case .failed:
            caveats.append(.runFailed)
        case .cancelled:
            caveats.append(.cancelledMidRun)
        case .interrupted:
            caveats.append(.interrupted)
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
        try await prepareCall()
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
        try await prepareCall()
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
        var hasNoFinalTextError = false
        var hasOutputTruncatedNotice = false
        var reachedThreadStart = false
    }

    private func prepareCall() async throws {
        guard deps.capabilityEnabled() else {
            throw FloeShortcutRunError.shortcutsCapabilityDisabled
        }
        try await deps.ensureReady()
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
            finishedPerDurableRecord: Self.finishedStateNames.contains(run.state)
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
