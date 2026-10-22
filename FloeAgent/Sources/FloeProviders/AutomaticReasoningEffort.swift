// FloeProviders — Automatic reasoning-effort decision support.
//
// `ModelReasoningEffort.automatic` (the default) means "let the model's own
// default apply". For a fresh round on a model whose protocol can actually
// transmit an effort value, Floe asks the user's configured auxiliary text
// model to pick one bounded level; the decision is frozen on the run's model
// profile and reused (re-clamped for a re-selected target) by resume/retry
// and every other same-round re-entry without another request. Manual levels
// and endpoints whose protocol cannot transmit an effort value bypass this
// path entirely and keep the previous wire behavior.
//
// This file owns the strict response contract (one JSON object carrying a
// bounded enum token), the bounded, untrusted classifier input, and the
// one-shot deadline-bounded coordinator that deduplicates concurrent starts
// for the same run. Only a fresh round's first ingress may submit the one
// request; a same-round continuation never does.

import Foundation
import FloeCore
import FloeModels

// MARK: - Wire-mapping facade

/// Public view of the wire contract implemented by `ReasoningCompatibility`.
/// A decision is only requested when the selected protocol would actually
/// transmit an effort value for this provider/model family.
public enum AutomaticReasoningEffortSupport {

    /// True when the selected wire protocol transmits an effort value for
    /// this provider/model family. Unknown/custom endpoints, media endpoints
    /// and on-device engines return false and keep today's automatic
    /// (provider default) behavior with no extra request.
    public static func supportsVariableEffort(
        provider: ProviderProfile,
        model: ModelProfile
    ) -> Bool {
        ReasoningCompatibility.supportsVariableReasoningEffort(provider: provider, model: model)
    }

    /// The level whose wire value the endpoint will actually use. Today only
    /// DeepSeek's wire alias (no native medium), Ark's `maximum` downgrade
    /// and the model-specific OpenAI/Anthropic `maximum` downgrades need
    /// rewriting; everything else is already the truthful tier.
    public static func clamped(
        _ effort: ModelReasoningEffort,
        provider: ProviderProfile,
        model: ModelProfile
    ) -> ModelReasoningEffort {
        ReasoningCompatibility.clampAutomaticReasoningEffort(
            effort, provider: provider, model: model)
    }

    /// The exact effort token the current protocol would send for this model,
    /// or nil when nothing is transmitted (automatic/manual default, unknown
    /// families). Qualification diagnostics and tests use this instead of
    /// duplicating the wire mapping.
    public static func wireEffort(provider: ProviderProfile, model: ModelProfile) -> String? {
        ReasoningCompatibility.wireEffortValue(provider: provider, model: model)
    }
}

// MARK: - Decision record

/// The frozen outcome of one fresh-round decision. `level == nil` means the
/// deterministic fallback: the provider's own supported default is kept and
/// no effort field is sent.
public struct AutomaticReasoningEffortDecision: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        /// The configured auxiliary model selected the level.
        case auxiliary
        /// The auxiliary model was unavailable/unconfigured or the bounded
        /// attempt failed; the provider's own default is kept.
        case fallback
    }

    /// Threaded through a durable `.status` run event. The payload carries no
    /// user text, no attachment content and no secrets.
    public static let payloadKey = "automaticReasoningEffort"

    public var source: Source
    public var level: ModelReasoningEffort?
    /// The auxiliary model's abstract choice BEFORE any wire clamp. `level`
    /// is what the recorded target will actually use; reusing this decision
    /// for a re-selected target re-clamps this abstract choice instead of the
    /// already-clamped one (clamping is not idempotent across targets:
    /// `maximum` legitimately survives only where xhigh/max exists). `nil`
    /// for the deterministic fallback and for legacy records, which fall back
    /// to `level`.
    public var abstractLevel: ModelReasoningEffort?
    public var targetProviderID: UUID
    public var targetModelID: UUID
    public var targetRemoteModelID: String
    /// Capability snapshot of the target at decision time (audit only; the
    /// decision is about the model family's effort contract).
    public var targetCapabilitiesRawValue: Int
    public var latencyMilliseconds: Int?
    /// Bounded failure category (`unconfigured`, `timedOut`, ...); never the
    /// provider message, request text or reasoning content.
    public var errorCategory: String?

    public init(
        source: Source,
        level: ModelReasoningEffort?,
        targetProviderID: UUID,
        targetModelID: UUID,
        targetRemoteModelID: String,
        targetCapabilitiesRawValue: Int,
        latencyMilliseconds: Int? = nil,
        errorCategory: String? = nil,
        abstractLevel: ModelReasoningEffort? = nil
    ) {
        self.source = source
        self.level = level
        self.abstractLevel = abstractLevel
        self.targetProviderID = targetProviderID
        self.targetModelID = targetModelID
        self.targetRemoteModelID = targetRemoteModelID
        self.targetCapabilitiesRawValue = targetCapabilitiesRawValue
        self.latencyMilliseconds = latencyMilliseconds
        self.errorCategory = errorCategory
    }

    public func matches(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.id == targetProviderID
            && model.id == targetModelID
            && model.remoteModelID == targetRemoteModelID
    }

    /// The run's model profile with the frozen decision applied. A fallback
    /// restores `nil` (= `.automatic`), which is what the adapters already
    /// transmit as "no effort field".
    public func applied(to model: ModelProfile) -> ModelProfile {
        var resolved = model
        resolved.reasoningEffort = level
        return resolved
    }

    /// JSON for one durable run event. No input text or secrets.
    public func payloadJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(DecisionPayload(automaticReasoningEffort: self)),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// First durable decision carried by a run's own event thread. Used to
    /// reuse the frozen choice after process death without resubmitting.
    public static func find(in events: [RunEventRecord]) -> AutomaticReasoningEffortDecision? {
        let decoder = JSONDecoder()
        for event in events where event.kind == .status {
            guard let data = event.payloadJSON.data(using: .utf8),
                  let payload = try? decoder.decode(DecisionPayload.self, from: data) else { continue }
            return payload.automaticReasoningEffort
        }
        return nil
    }

    private struct DecisionPayload: Codable {
        var automaticReasoningEffort: AutomaticReasoningEffortDecision
    }
}

// MARK: - Classifier contract

/// One-way failure vocabulary for the classifier hop. The coordinator turns
/// any of these into the deterministic fallback; a provider message or model
/// output is never carried through to durable state or logs.
public enum AutomaticReasoningEffortFailureCategory: String, Sendable, Equatable, Error {
    case unconfigured
    case unavailable
    case timedOut
    case malformedResponse
    case providerError
    case cancelled
}

/// Thrown by classifier implementations. The `detail` stays bounded and
/// non-secret (provider kind/HTTP status only).
public struct AutomaticReasoningEffortClassifyFailure: Error, Sendable, Equatable {
    public var category: AutomaticReasoningEffortFailureCategory
    public var detail: String?

    public init(
        category: AutomaticReasoningEffortFailureCategory,
        detail: String? = nil
    ) {
        self.category = category
        self.detail = detail
    }
}

/// A tool-free, one-shot classifier. Implementations must treat the input as
/// untrusted data, must not expose tools/delegation and must return one
/// bounded level or throw a typed failure.
public protocol AutomaticReasoningEffortClassifying: Sendable {
    func classify(_ input: String) async throws -> ModelReasoningEffort
}

// MARK: - Strict response contract

/// Strict parser for the classifier answer: exactly one JSON object with an
/// `effort` key whose value is one canonical token. Anything else — prose,
/// substring guesses, unknown tokens, oversized text — is rejected and the
/// caller falls back.
public enum AutomaticReasoningEffortResponse {
    public static let maximumCharacters = 2_048

    private struct Envelope: Decodable {
        var effort: String
    }

    public static func parse(_ text: String) -> ModelReasoningEffort? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= maximumCharacters else { return nil }
        // Tolerate one surrounding markdown fence; anything else outside the
        // single object (prose, labels, prefixes) is rejected rather than
        // guessed from a substring.
        if candidate.hasPrefix("```") {
            guard let newline = candidate.firstIndex(of: "\n") else { return nil }
            candidate = String(candidate[candidate.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasSuffix("```") {
                candidate = String(candidate.dropLast(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard candidate.hasPrefix("{"), candidate.hasSuffix("}") else { return nil }
        guard let data = candidate.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch envelope.effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "maximum": return .maximum
        default: return nil
        }
    }
}

// MARK: - Bounded classifier input

/// The only text the classifier ever sees: the bounded latest user request
/// plus minimal attachment metadata. Never the conversation history, file
/// contents, workspace listings or secrets.
public enum AutomaticReasoningEffortInputBuilder {
    public static let maximumGoalCharacters = 2_000
    public static let maximumAttachmentMetadataCount = 8

    public static func build(goal: String, attachments: [AttachmentRef]) -> String {
        var parts: [String] = []
        let boundedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("Request: \(String(boundedGoal.prefix(maximumGoalCharacters)))")
        if !attachments.isEmpty {
            let lines = attachments.prefix(maximumAttachmentMetadataCount).enumerated().map { index, attachment in
                "- Attachment \(index + 1): kind=\(attachment.kind.rawValue)\(fileExtensionSuffix(attachment)) bytes=\(attachment.byteCount)"
            }
            parts.append("Attachments:\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    private static func fileExtensionSuffix(_ attachment: AttachmentRef) -> String {
        let extensionName = (attachment.displayName as NSString).pathExtension.lowercased()
        let sanitized = extensionName.filter { $0.isLetter || $0.isNumber }
        guard !sanitized.isEmpty, sanitized.count <= 8 else { return "" }
        return " ext=\(sanitized)"
    }
}

// MARK: - One-shot deadline arbiter

/// One-shot race arbiter for the bounded classifier call: only the first
/// completion (result, timeout or cancellation) resumes the continuation.
/// Mirrors the existing `DeadlineArbiter` pattern used for blocking lookups.
private final class AutomaticReasoningEffortDeadlineArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var resolved = false

    func arm(_ continuation: CheckedContinuation<
             Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ work: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            work.cancel()
            return
        }
        self.work = work
        lock.unlock()
    }

    func attachTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }

    func resolve(_ outcome: Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        self.work = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        // The deadline only matters until the first outcome; a resolved race
        // never leaves a sleeping timer behind.
        timer?.cancel()
        continuation.resume(returning: outcome)
    }

    func timedOut() {
        resolveAndCancelWork(.failure(.timedOut))
    }

    func cancel() {
        resolveAndCancelWork(.failure(.cancelled))
    }

    private func resolveAndCancelWork(
        _ outcome: Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>
    ) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        let work = self.work
        self.work = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        continuation.resume(returning: outcome)
        work?.cancel()
        timer?.cancel()
    }
}

// MARK: - Ingress

/// Where one resolve enters the coordinator from.
///
/// Only `.freshRound` — the first ingress of a newly launched round — may
/// submit the one bounded classifier request. `.continuation` covers every
/// same-round re-entry (resume, retry, recovery after process death, model
/// re-selection, queued input on the same run): it never submits, it only
/// reuses a frozen choice (re-clamped for the current target) or freezes the
/// provider default.
public enum AutomaticReasoningEffortIngress: Sendable, Equatable {
    case freshRound
    case continuation
}

// MARK: - Coordinator

/// Freezes one automatic reasoning-effort decision per run.
///
/// * A `.freshRound` ingress performs at most one bounded classifier request
///   for the run; concurrent callers for the same target join that request.
///   A `.continuation` ingress never submits one.
/// * Resume/retry/recovery reuses the in-memory decision, or a durable
///   `.status` run event supplied by `seedReader`, without another request;
///   a target re-selected inside the same round re-clamps the frozen
///   abstract level instead of deciding again.
/// * Manual selections and families whose protocol cannot transmit an effort
///   value pass through untouched.
/// * A timed-out, cancelled or failed attempt stores the deterministic
///   fallback (provider default) so a resume never resubmits.
public actor AutomaticReasoningEffortCoordinator {

    /// Reads the run's durable decision (`nil` when the run has none yet).
    public typealias SeedReader = @Sendable (UUID) async -> AutomaticReasoningEffortDecision?
    /// Persists the frozen decision exactly once per run.
    public typealias Recorder = @Sendable (UUID, AutomaticReasoningEffortDecision) async -> Void

    private struct TargetIdentity: Sendable, Equatable {
        var providerID: UUID
        var modelID: UUID
        var remoteModelID: String

        init(provider: ProviderProfile, model: ModelProfile) {
            self.providerID = provider.id
            self.modelID = model.id
            self.remoteModelID = model.remoteModelID
        }
    }

    private struct InFlight {
        var handle: UUID
        var target: TargetIdentity
        var task: Task<AutomaticReasoningEffortDecision, Never>
    }

    private let timeout: Duration
    private let cacheLimit: Int
    private let logger: FloeLogger
    private var decisions: [UUID: AutomaticReasoningEffortDecision] = [:]
    private var recency: [UUID] = []
    private var inFlight: [UUID: InFlight] = [:]
    /// Monotonic lifecycle generation per FORGOTTEN (deleted / torn down)
    /// run. `cancelAndForget` bumps it; an in-flight resolve captures it
    /// before its first await and re-checks it before any late store or
    /// record, so a deletion that interleaved can never be resurrected by
    /// that write. Only bumped runs are retained, and only the newest
    /// `cacheLimit` of them: a bounded handoff, never a growing tombstone
    /// table.
    private var forgottenGenerations: [UUID: UInt64] = [:]
    private var forgottenRecency: [UUID] = []

    public init(
        timeout: Duration = .seconds(2),
        cacheLimit: Int = 128,
        logger: FloeLogger = FloeLogger(category: .providers)
    ) {
        self.timeout = timeout
        self.cacheLimit = max(1, cacheLimit)
        self.logger = logger
    }

    /// Resolves the run's effective model profile.
    ///
    /// * `.freshRound` is the only ingress that may submit the one bounded
    ///   classifier request for a run; a duplicate concurrent start for the
    ///   same target joins that request instead of adding a second one.
    /// * `.continuation` (resume/retry/recovery and every other same-round
    ///   re-entry) never submits: it reuses the frozen abstract choice,
    ///   re-clamped for a re-selected target, or freezes the provider's own
    ///   default when no choice was ever made for the round.
    public func resolvedModel(
        runID: UUID,
        provider: ProviderProfile,
        model: ModelProfile,
        boundedInput: String,
        classifier: (any AutomaticReasoningEffortClassifying)?,
        ingress: AutomaticReasoningEffortIngress,
        seedReader: SeedReader? = nil,
        recorder: Recorder? = nil
    ) async -> ModelProfile {
        guard !Task.isCancelled else { return model }
        guard model.effectiveReasoningEffort == .automatic else {
            logger.info(
                "automaticReasoningEffortSkipped reason=manual model=\(model.id.uuidString)")
            return model
        }
        guard AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: provider, model: model) else {
            return model
        }
        let target = TargetIdentity(provider: provider, model: model)
        // Lifecycle token for this run, captured BEFORE the first await. A
        // deletion bumps it; every path that would store or record after an
        // await re-checks it instead of resurrecting a deleted run.
        let generation = forgottenGeneration(for: runID)

        // A decision already frozen for this run (RAM first, else the durable
        // record read after process death). The abstract level IS the
        // decision: a re-selected target only re-clamps which wire tier it
        // lands on and never starts another request.
        if let frozen = decisions[runID] {
            return await reuse(
                frozen, runID: runID, generation: generation,
                provider: provider, model: model, recorder: recorder)
        }
        if let seedReader, let seeded = await seedReader(runID) {
            // The durable read suspended: a Stop/Delete/End that interleaved
            // must not be answered with a late freeze or record.
            guard !Task.isCancelled, generation == forgottenGeneration(for: runID) else {
                logger.info(
                    "automaticReasoningEffortWriteSkipped run=\(runID.uuidString) reason=forgottenDuringSeedRead")
                return model
            }
            return await reuse(
                seeded, runID: runID, generation: generation,
                provider: provider, model: model, recorder: recorder)
        }

        // No frozen decision. An in-flight request belongs to the round that
        // started it (only a fresh-round start ever creates one).
        if let existing = inFlight[runID] {
            if existing.target == target, ingress == .freshRound {
                // A duplicate start for the same round joins the one request.
                let decision = await existing.task.value
                if Task.isCancelled || existing.task.isCancelled { return model }
                guard decision.matches(provider: provider, model: model) else { return model }
                return decision.applied(to: model)
            }
            if existing.target != target {
                // The target changed while only a request for the old target
                // existed: cancel it — its late result must never reach the
                // new model — and freeze the provider default without
                // resubmitting a second request for the new target.
                existing.task.cancel()
                inFlight[runID] = nil
                return await freezeFallback(
                    runID: runID,
                    generation: generation,
                    provider: provider,
                    model: model,
                    errorCategory: .cancelled,
                    recorder: recorder
                )
            }
            // Same target but not the fresh-round ingress: the pending
            // request still belongs to the round that started it. This
            // invocation keeps the provider default and neither waits on the
            // request nor starts a second one.
            return model
        }

        // With no frozen and no in-flight state, only a fresh round's first
        // ingress may ask the helper. A same-round re-entry (a run that
        // started manual/unsupported and was switched to automatic on resume)
        // keeps and freezes the provider default instead of deciding late.
        guard ingress == .freshRound else {
            return await freezeFallback(
                runID: runID,
                generation: generation,
                provider: provider,
                model: model,
                errorCategory: nil,
                recorder: recorder
            )
        }

        // The one classification for this round.
        let handle = UUID()
        let task = Self.startClassification(
            runID: runID,
            boundedInput: boundedInput,
            classifier: classifier,
            provider: provider,
            model: model,
            timeout: timeout,
            logger: logger,
            coordinator: self,
            handle: handle,
            recorder: recorder
        )
        inFlight[runID] = InFlight(handle: handle, target: target, task: task)

        let decision = await task.value
        if Task.isCancelled || task.isCancelled { return model }
        guard decision.matches(provider: provider, model: model) else { return model }
        return decision.applied(to: model)
    }

    /// Reuses a frozen abstract choice for the current target. A target that
    /// changed inside the same round keeps the abstract level (the helper's
    /// own choice, not the previous target's downgraded tier) and rewrites
    /// which concrete wire tier it maps to — never a second request — and
    /// realigns the durable record with the target actually in use.
    private func reuse(
        _ frozen: AutomaticReasoningEffortDecision,
        runID: UUID,
        generation: UInt64,
        provider: ProviderProfile,
        model: ModelProfile,
        recorder: Recorder?
    ) async -> ModelProfile {
        guard !Task.isCancelled, generation == forgottenGeneration(for: runID) else {
            logger.info(
                "automaticReasoningEffortWriteSkipped run=\(runID.uuidString) reason=forgottenDuringReuse")
            return model
        }
        let abstract = frozen.abstractLevel ?? frozen.level
        let matched = frozen.matches(provider: provider, model: model)
        var reused = frozen
        reused.level = abstract.map {
            AutomaticReasoningEffortSupport.clamped($0, provider: provider, model: model)
        }
        // `reused.abstractLevel` intentionally keeps `frozen.abstractLevel`:
        // a legacy record whose abstract choice was not recorded keeps its
        // nil marker and its level as the only known choice.
        reused.targetProviderID = provider.id
        reused.targetModelID = model.id
        reused.targetRemoteModelID = model.remoteModelID
        reused.targetCapabilitiesRawValue = model.capabilities.rawValue
        store(reused, runID: runID)
        if !matched {
            // Recovery after process death and a model re-selected inside the
            // original round both land here: the durable record is rewritten
            // for the target in use, still without any helper request.
            await recorder?(runID, reused)
        }
        logger.info(
            "automaticReasoningEffortReused run=\(runID.uuidString) source=\(reused.source.rawValue) level=\(reused.level?.rawValue ?? "providerDefault")")
        return reused.applied(to: model)
    }

    /// Freezes the deterministic fallback (the provider's own default, no
    /// effort field) for a round that must not submit a helper request. The
    /// record is stored and — when the caller supplies a recorder — persisted
    /// exactly like a classifier decision, so recovery never resubmits.
    private func freezeFallback(
        runID: UUID,
        generation: UInt64,
        provider: ProviderProfile,
        model: ModelProfile,
        errorCategory: AutomaticReasoningEffortFailureCategory?,
        recorder: Recorder?
    ) async -> ModelProfile {
        guard !Task.isCancelled, generation == forgottenGeneration(for: runID) else {
            logger.info(
                "automaticReasoningEffortWriteSkipped run=\(runID.uuidString) reason=forgottenDuringFallback")
            return model
        }
        let fallback = AutomaticReasoningEffortDecision(
            source: .fallback,
            level: nil,
            targetProviderID: provider.id,
            targetModelID: model.id,
            targetRemoteModelID: model.remoteModelID,
            targetCapabilitiesRawValue: model.capabilities.rawValue,
            latencyMilliseconds: nil,
            errorCategory: errorCategory?.rawValue
        )
        store(fallback, runID: runID)
        logger.info(
            "automaticReasoningEffortDecided source=fallback level=providerDefault reason=\(errorCategory?.rawValue ?? "noPriorDecision") run=\(runID.uuidString)")
        await recorder?(runID, fallback)
        return fallback.applied(to: model)
    }

    /// Seeds a decision directly (tests, or an app that already read the
    /// durable event). Ignores a decision whose target does not match.
    public func seed(
        runID: UUID,
        decision: AutomaticReasoningEffortDecision,
        provider: ProviderProfile,
        model: ModelProfile
    ) {
        guard decision.matches(provider: provider, model: model) else { return }
        store(decision, runID: runID)
    }

    /// The frozen decision for a run, if any.
    public func decision(runID: UUID) -> AutomaticReasoningEffortDecision? {
        decisions[runID]
    }

    /// Cancels an in-flight classifier request and drops every trace of the
    /// run's decision. Used when a run is torn down (temporary session
    /// destroy, failed launch, conversation deletion) so a late helper can
    /// never overwrite a later round or model. The run's lifecycle generation
    /// is bumped so a resolve suspended in an await cannot write it back.
    public func cancelAndForget(runID: UUID) {
        inFlight[runID]?.task.cancel()
        inFlight[runID] = nil
        bumpForgottenGeneration(runID: runID)
        forget(runID: runID)
    }

    public func cancelAndForget(runIDs: Set<UUID>) {
        for runID in runIDs {
            cancelAndForget(runID: runID)
        }
    }

    /// Cancels a pending classifier request WITHOUT touching an already
    /// frozen decision. Normal Stop, Notes stop and any other non-deletion
    /// cancellation use this: the helper stops holding the launch open
    /// immediately, while a deliberate same-round Continue still reuses the
    /// frozen choice with no new request.
    public func cancelPending(runID: UUID) {
        inFlight[runID]?.task.cancel()
        inFlight[runID] = nil
    }

    public func cancelPending(runIDs: Set<UUID>) {
        for runID in runIDs {
            cancelPending(runID: runID)
        }
    }

    // MARK: Private

    private func forget(runID: UUID) {
        decisions[runID] = nil
        recency.removeAll { $0 == runID }
    }

    private func forgottenGeneration(for runID: UUID) -> UInt64 {
        forgottenGenerations[runID] ?? 0
    }

    private func bumpForgottenGeneration(runID: UUID) {
        forgottenGenerations[runID] = (forgottenGenerations[runID] ?? 0) + 1
        forgottenRecency.removeAll { $0 == runID }
        forgottenRecency.append(runID)
        while forgottenRecency.count > cacheLimit, let oldest = forgottenRecency.first {
            forgottenRecency.removeFirst()
            forgottenGenerations[oldest] = nil
        }
    }

    private func store(_ decision: AutomaticReasoningEffortDecision, runID: UUID) {
        if decisions.updateValue(decision, forKey: runID) == nil {
            recency.append(runID)
        }
        while recency.count > cacheLimit, let oldest = recency.first {
            recency.removeFirst()
            decisions[oldest] = nil
        }
    }

    private func finish(
        runID: UUID,
        handle: UUID,
        decision: AutomaticReasoningEffortDecision,
        cancelled: Bool,
        recorder: Recorder?
    ) async {
        // Only the surviving request for this run may freeze its decision; a
        // cancelled (destroyed/replaced) request leaves nothing behind. The
        // decision was built from this request's snapshotted target, so its
        // identity matches by construction.
        guard !cancelled,
              inFlight[runID]?.handle == handle else { return }
        inFlight[runID] = nil
        store(decision, runID: runID)
        await recorder?(runID, decision)
    }

    private nonisolated static func startClassification(
        runID: UUID,
        boundedInput: String,
        classifier: (any AutomaticReasoningEffortClassifying)?,
        provider: ProviderProfile,
        model: ModelProfile,
        timeout: Duration,
        logger: FloeLogger,
        coordinator: AutomaticReasoningEffortCoordinator,
        handle: UUID,
        recorder: Recorder?
    ) -> Task<AutomaticReasoningEffortDecision, Never> {
        Task {
            let decision = await classify(
                boundedInput: boundedInput,
                classifier: classifier,
                provider: provider,
                model: model,
                timeout: timeout,
                logger: logger
            )
            let cancelled = Task.isCancelled
            await coordinator.finish(
                runID: runID,
                handle: handle,
                decision: decision,
                cancelled: cancelled,
                recorder: recorder
            )
            return decision
        }
    }

    /// One bounded classifier attempt. Never throws: every outcome is either
    /// a clamped auxiliary decision or the deterministic fallback record.
    private nonisolated static func classify(
        boundedInput: String,
        classifier: (any AutomaticReasoningEffortClassifying)?,
        provider: ProviderProfile,
        model: ModelProfile,
        timeout: Duration,
        logger: FloeLogger
    ) async -> AutomaticReasoningEffortDecision {
        let started = ContinuousClock.now
        func decision(
            source: AutomaticReasoningEffortDecision.Source,
            level: ModelReasoningEffort?,
            abstractLevel: ModelReasoningEffort? = nil,
            errorCategory: AutomaticReasoningEffortFailureCategory?
        ) -> AutomaticReasoningEffortDecision {
            let elapsed = started.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            return AutomaticReasoningEffortDecision(
                source: source,
                level: level,
                targetProviderID: provider.id,
                targetModelID: model.id,
                targetRemoteModelID: model.remoteModelID,
                targetCapabilitiesRawValue: model.capabilities.rawValue,
                latencyMilliseconds: milliseconds,
                errorCategory: errorCategory?.rawValue,
                abstractLevel: abstractLevel
            )
        }

        guard let classifier else {
            let fallback = decision(source: .fallback, level: nil, errorCategory: .unconfigured)
            logger.info(
                "automaticReasoningEffortDecided source=fallback level=providerDefault latencyMs=\(fallback.latencyMilliseconds ?? 0) error=unconfigured")
            return fallback
        }

        let outcome = await resultWithinDeadline(timeout: timeout) {
            try await classifier.classify(boundedInput)
        }
        switch outcome {
        case .success(let effort):
            let clamped = AutomaticReasoningEffortSupport.clamped(
                effort, provider: provider, model: model)
            // `level` is the wire tier for THIS target; `abstractLevel` keeps
            // the helper's own choice so a later re-selection can re-clamp it
            // instead of inheriting this target's downgrade.
            let resolved = decision(
                source: .auxiliary, level: clamped, abstractLevel: effort,
                errorCategory: nil)
            logger.info(
                "automaticReasoningEffortDecided source=auxiliary level=\(clamped.rawValue) latencyMs=\(resolved.latencyMilliseconds ?? 0)")
            return resolved
        case .failure(let failure):
            let fallback = decision(source: .fallback, level: nil, errorCategory: failure)
            logger.warning(
                "automaticReasoningEffortDecided source=fallback level=providerDefault latencyMs=\(fallback.latencyMilliseconds ?? 0) error=\(failure.rawValue)")
            return fallback
        }
    }

    /// Runs one classification under a hard deadline. A classifier that
    /// ignores cancellation cannot delay the caller past the deadline, and
    /// its late result is discarded by the one-shot arbiter.
    private nonisolated static func resultWithinDeadline(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> ModelReasoningEffort
    ) async -> Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory> {
        let arbiter = AutomaticReasoningEffortDeadlineArbiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<
                Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>, Never>) in
                arbiter.arm(continuation)
                guard !Task.isCancelled else {
                    arbiter.cancel()
                    return
                }
                let work = Task {
                    let outcome: Result<ModelReasoningEffort, AutomaticReasoningEffortFailureCategory>
                    do {
                        outcome = .success(try await operation())
                    } catch is CancellationError {
                        outcome = .failure(.cancelled)
                    } catch let failure as AutomaticReasoningEffortClassifyFailure {
                        outcome = .failure(failure.category)
                    } catch {
                        outcome = .failure(.providerError)
                    }
                    arbiter.resolve(outcome)
                }
                arbiter.attach(work)
                // The deadline task is attached to the same one-shot arbiter:
                // whichever of result/timeout/cancellation resolves first
                // cancels the other side, so a completed request leaves no
                // sleeping timer behind and a timeout cancels the request.
                arbiter.attachTimer(Task {
                    try? await Task.sleep(for: timeout)
                    arbiter.timedOut()
                })
            }
        } onCancel: {
            arbiter.cancel()
        }
    }
}

// MARK: - Chat reasoning support (fast conversation lane)

/// Public view of the conversation-local chat reasoning contract. Unlike the
/// automatic-effort helper this never asks a second model: the resolution is
/// a deterministic function of the frozen conversation preference and the
/// selected endpoint, following the documented wire truth exactly — a
/// disable knob only where the official contract documents one, otherwise
/// the lowest supported known tier, otherwise no reasoning fields at all.
public enum ChatReasoningSupport {

    /// Resolves one frozen preference for the current target. Manual/global
    /// stored profiles are never written; callers apply the result to the
    /// run's model copy.
    public static func resolve(
        _ preference: ChatReasoningPreference,
        provider: ProviderProfile,
        model: ModelProfile
    ) -> (policy: ProviderReasoningPolicy, level: ModelReasoningEffort?) {
        ReasoningCompatibility.resolveChatReasoning(preference, provider: provider, model: model)
    }

    /// True when the endpoint actually transmits a documented disable field
    /// for this family/protocol (used by qualification and the composer
    /// honesty labels).
    public static func supportsDocumentedDisable(
        provider: ProviderProfile,
        model: ModelProfile
    ) -> Bool {
        ReasoningCompatibility.documentsDisabledReasoning(provider: provider, model: model)
    }

    /// The first durable chat decision carried by a run's own `.status`
    /// event thread. Lives here (not in FloeCore) because `RunEventRecord`
    /// belongs to FloeModels and Core must not import it.
    public static func findDecision(in events: [RunEventRecord]) -> ChatReasoningDecision? {
        for event in events where event.kind == .status {
            if let decision = ChatReasoningDecision.decision(fromEventPayloadJSON: event.payloadJSON) {
                return decision
            }
        }
        return nil
    }
}

/// Freezes one chat reasoning decision per run.
///
/// * The FIRST resolve for a run captures the conversation preference at
///   that moment and records it durably (invisible `.status` event, payload
///   key `chatReasoning`) through the caller-supplied recorder. Resume,
///   retry, recovery and queued steering are continuations: they reuse the
///   frozen preference and re-resolve it deterministically against the
///   CURRENT target (a re-selected model re-derives the disable/tier/omit
///   answer and the clamp; there is no helper request to duplicate).
/// * A preference or mode switch while a run is active therefore applies to
///   the NEXT run only.
/// * Temporary sessions pass a RAM-backed store, so nothing here leaves
///   memory.
/// * The coordinator performs no async I/O of its own beyond the injected
///   seed reader/recorder, so the freeze completes before the caller builds
///   the run configuration.
public actor ChatReasoningCoordinator {

    public typealias SeedReader = @Sendable (UUID) async -> ChatReasoningDecision?
    public typealias Recorder = @Sendable (UUID, ChatReasoningDecision) async -> Void

    private let cacheLimit: Int
    private let logger: FloeLogger
    private var decisions: [UUID: ChatReasoningDecision] = [:]
    private var recency: [UUID] = []
    /// Run lifecycle token bumped by `cancelAndForget`. A resolve suspended
    /// across the durable seed read must not resurrect a forgotten run.
    private var forgottenGenerations: [UUID: UInt64] = [:]
    private var forgottenRecency: [UUID] = []

    public init(
        cacheLimit: Int = 128,
        logger: FloeLogger = FloeLogger(category: .providers)
    ) {
        self.cacheLimit = max(1, cacheLimit)
        self.logger = logger
    }

    /// Resolves the run's effective model profile and request reasoning
    /// policy from the frozen chat decision.
    public func resolve(
        runID: UUID,
        provider: ProviderProfile,
        model: ModelProfile,
        preference: ChatReasoningPreference,
        seedReader: SeedReader? = nil,
        recorder: Recorder? = nil
    ) async -> (model: ModelProfile, policy: ProviderReasoningPolicy) {
        guard !Task.isCancelled else { return (model, .modelDefault) }
        let generation = forgottenGeneration(for: runID)

        if let frozen = decisions[runID] {
            return reuse(frozen, runID: runID, provider: provider, model: model, loggerNote: "ram")
        }
        if let seedReader, let seeded = await seedReader(runID) {
            guard !Task.isCancelled, generation == forgottenGeneration(for: runID) else {
                logger.info(
                    "chatReasoningWriteSkipped run=\(runID.uuidString) reason=forgottenDuringSeedRead")
                return (model, .modelDefault)
            }
            return reuse(seeded, runID: runID, provider: provider, model: model, loggerNote: "durable")
        }

        // Fresh round: freeze the preference as it stands right now.
        let decision = makeDecision(preference: preference, provider: provider, model: model)
        store(decision, runID: runID)
        await recorder?(runID, decision)
        logger.info(
            "chatReasoningFrozen run=\(runID.uuidString) preference=\(preference.rawValue) disabled=\(decision.appliesDisabledPolicy) level=\(decision.level?.rawValue ?? "omit")")
        return (decision.applied(to: model),
                decision.appliesDisabledPolicy ? .disabled : .modelDefault)
    }

    /// Continuation path: the frozen input is the PREFERENCE; the wire
    /// answer is derived against the current target every time
    /// (deterministic, no request). A re-selected model re-derives the
    /// disable/tier/omit decision and re-clamps the explicit abstract level.
    private func reuse(
        _ frozen: ChatReasoningDecision,
        runID: UUID,
        provider: ProviderProfile,
        model: ModelProfile,
        loggerNote: String
    ) -> (model: ModelProfile, policy: ProviderReasoningPolicy) {
        let resolved = makeDecision(preference: frozen.preference, provider: provider, model: model)
        store(resolved, runID: runID)
        logger.info(
            "chatReasoningReused source=\(loggerNote) run=\(runID.uuidString) preference=\(frozen.preference.rawValue) disabled=\(resolved.appliesDisabledPolicy) level=\(resolved.level?.rawValue ?? "omit")")
        return (resolved.applied(to: model),
                resolved.appliesDisabledPolicy ? .disabled : .modelDefault)
    }

    private func makeDecision(
        preference: ChatReasoningPreference,
        provider: ProviderProfile,
        model: ModelProfile
    ) -> ChatReasoningDecision {
        let resolution = ChatReasoningSupport.resolve(preference, provider: provider, model: model)
        return ChatReasoningDecision(
            preference: preference,
            appliesDisabledPolicy: resolution.policy == .disabled,
            level: resolution.level,
            abstractLevel: preference.modelEffortOverride,
            targetProviderID: provider.id,
            targetModelID: model.id,
            targetRemoteModelID: model.remoteModelID
        )
    }

    /// The frozen decision for a run, if any (diagnostics/qualification).
    public func decision(runID: UUID) -> ChatReasoningDecision? {
        decisions[runID]
    }

    /// Drops every trace of a run so a deleted/torn-down conversation can
    /// never be re-frozen by a late continuation read.
    public func cancelAndForget(runID: UUID) {
        bumpForgottenGeneration(runID: runID)
        decisions[runID] = nil
        recency.removeAll { $0 == runID }
    }

    public func cancelAndForget(runIDs: Set<UUID>) {
        for runID in runIDs { cancelAndForget(runID: runID) }
    }

    // MARK: Private

    private func store(_ decision: ChatReasoningDecision, runID: UUID) {
        if decisions.updateValue(decision, forKey: runID) == nil {
            recency.append(runID)
        }
        while recency.count > cacheLimit, let oldest = recency.first {
            recency.removeFirst()
            decisions[oldest] = nil
        }
    }

    private func forgottenGeneration(for runID: UUID) -> UInt64 {
        forgottenGenerations[runID] ?? 0
    }

    private func bumpForgottenGeneration(runID: UUID) {
        forgottenGenerations[runID] = (forgottenGenerations[runID] ?? 0) + 1
        forgottenRecency.removeAll { $0 == runID }
        forgottenRecency.append(runID)
        while forgottenRecency.count > cacheLimit, let oldest = forgottenRecency.first {
            forgottenRecency.removeFirst()
            forgottenGenerations[oldest] = nil
        }
    }
}
