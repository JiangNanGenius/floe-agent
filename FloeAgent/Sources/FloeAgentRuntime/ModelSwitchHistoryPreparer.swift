import Foundation
import FloeCore
import FloeTools

/// Decide once, from the INCOMING model's real configured window and the same
/// reservations the dispatch path uses, whether a conversation's projected
/// history must be compacted before the switch takes effect.
///
/// Mirrors ``AgentRuntime``'s private `contextCompressionPolicy` /
/// `needsCompaction` arithmetic so a pre-switch pass never disagrees with the
/// first dispatch it is protecting:
/// - output reserve: the identical window-derived rule exposed by
///   ``CompactionSummarizerBudget/outputReserveTokens(contextTokens:configuredMaxOutputTokens:)``
///   (the runtime's `contextOutputReservation` is the same formula);
/// - image tokens: 1 600 per inline image on the projected history;
/// - tool-schema tokens: the runtime charges the ACTUAL rendered schemas of
///   the previous request (measured) and 0 when no measurement exists, while
///   a local incoming model with tool capability always charges the adapter's
///   own ~2 000-token curated schema budget. A model switch never has a
///   measured receipt for the incoming model — compaction snapshots are
///   in-memory run-UI projections and each fresh run re-measures from zero —
///   so the caller supplies ``Reservation``: a measured value when it really
///   has one, otherwise the planner derives a bounded initial-schema reserve
///   from the live ``ToolCatalog`` sizes clamped by the public
///   ``ToolSchemaOfferPlanner`` budget for this exact window. This bounded
///   reserve does NOT reproduce per-run schema admission (progressive
///   discovery defers/trims schemas at dispatch); the real first request still
///   sizes, schema-reduces and overflow-recovers through the unchanged
///   in-run path, which remains authoritative.
public enum ModelSwitchHistoryPlanner {
    public struct Reservation: Sendable, Equatable {
        /// Whether the next run's mode may carry tool schemas at all.
        public var toolsEnabledForNextRun: Bool
        /// An actually-measured rendered schema size (tokens) for the
        /// incoming model. The switch seam has none, so the App passes 0 and
        /// the bounded channel below applies.
        public var measuredToolSchemaTokens: Int
        /// Caller-imposed bound on the initial schema reservation. `nil` lets
        /// the planner derive it from the live tool catalog and the public
        /// schema-offer budget for this exact window.
        public var boundedSchemaReserveTokens: Int?
        /// Conservative bound for the live system envelope the first dispatch
        /// prepends (personalization/workspace contract) — durable-history
        /// assembly alone does not contain it. Never claims the full request;
        /// the real dispatch inserts the actual envelope and re-checks.
        public var systemContextTokenEstimate: Int

        public init(
            toolsEnabledForNextRun: Bool = true,
            measuredToolSchemaTokens: Int = 0,
            boundedSchemaReserveTokens: Int? = nil,
            systemContextTokenEstimate: Int = 0
        ) {
            self.toolsEnabledForNextRun = toolsEnabledForNextRun
            self.measuredToolSchemaTokens = max(0, measuredToolSchemaTokens)
            self.boundedSchemaReserveTokens = boundedSchemaReserveTokens.map { max(0, $0) }
            self.systemContextTokenEstimate = max(0, systemContextTokenEstimate)
        }

        /// A plain chat turn: no schemas are offered and no system envelope
        /// overhead is charged beyond what the history already contains.
        public static let chatOnly = Reservation(toolsEnabledForNextRun: false)
    }

    public struct Projection: Sendable, Equatable {
        public let policy: ContextCompressionPolicy
        public let estimatedHistoryTokens: Int
        public let availableInputTokens: Int
        /// The schema-channel component of the fixed non-history reservation
        /// actually charged into the budget (measured or bounded, zero when
        /// tools are not offered).
        public let reservedSchemaTokens: Int
        /// The live-system-envelope bound charged alongside the schemas.
        public let reservedSystemContextTokens: Int
        public let needsCompaction: Bool
    }

    /// The bounded initial schema reservation the switch seam can honestly
    /// derive: the full registered catalog's rendered cost, clamped by the
    /// same public planner budget the first dispatch would use for this
    /// window. `catalogDescriptors` is injectable so qualification can pin
    /// the cost instead of trusting registration order.
    public static func boundedInitialSchemaReservation(
        contextWindowTokens: Int,
        reservedOutputTokens: Int,
        messageTokens: Int,
        imageTokens: Int,
        toolSchemasVisible: Bool,
        catalogDescriptors: [ToolCatalog.Descriptor] = ToolCatalog.allDescriptors
    ) -> Int {
        guard toolSchemasVisible else { return 0 }
        // Mirror of the runtime's provisional tool-result channel reserve
        // (AgentRuntime turn sizing): leave a realistic share for results.
        let window = max(1, contextWindowTokens)
        let toolResultReserve = min(window / 3, max(1_024, window / 4))
        let budget = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: window,
            reservedOutputTokens: reservedOutputTokens,
            messageTokens: messageTokens,
            imageTokens: imageTokens,
            replayTokens: 0,
            toolResultReserveTokens: toolResultReserve
        )
        let catalogCost = catalogDescriptors.reduce(0) { $0 + ToolSchemaOfferPlanner.tokenCost($1) }
        return min(catalogCost, budget)
    }

    public static func projection(
        incomingProviderKind: ProviderKind,
        incomingModel: ModelProfile,
        history: [ConversationMessage],
        reservation: Reservation = Reservation(),
        estimator: ContextTokenEstimator = ContextTokenEstimator()
    ) -> Projection {
        let limits = incomingModel.limits
        let reservedOutput = CompactionSummarizerBudget.outputReserveTokens(
            contextTokens: limits.contextTokens,
            configuredMaxOutputTokens: limits.configuredMaxOutputTokens
        )
        let imageTokens = history.reduce(0) { $0 + $1.images.count * 1_600 }
        let estimated = estimator.estimate(history)
        let toolSchemasVisible = reservation.toolsEnabledForNextRun
            && incomingModel.capabilities.contains(.tools)
        let schemaTokens: Int
        if toolSchemasVisible {
            let candidate = reservation.measuredToolSchemaTokens > 0
                ? reservation.measuredToolSchemaTokens
                : reservation.boundedSchemaReserveTokens
                ?? Self.boundedInitialSchemaReservation(
                    contextWindowTokens: limits.contextTokens,
                    reservedOutputTokens: reservedOutput,
                    messageTokens: estimated,
                    imageTokens: imageTokens,
                    toolSchemasVisible: true
                )
            schemaTokens = incomingProviderKind == .local ? max(2_000, candidate) : candidate
        } else {
            // No schemas are offered on the next turn: neither a measured
            // receipt nor a bounded catalog cost may be charged.
            schemaTokens = 0
        }
        // `ContextBudget.toolSchemaTokens` is this engine's fixed
        // non-history reservation dimension: a fresh engine has no observed
        // provider usage to reconcile against it, so folding the system
        // envelope bound in here only tightens the usable input window
        // (never double-charging measured tokens).
        let fixedNonHistoryTokens = schemaTokens + reservation.systemContextTokenEstimate
        let policy: ContextCompressionPolicy
        if incomingProviderKind == .local {
            policy = .local(
                contextWindowTokens: limits.contextTokens,
                reservedOutputTokens: reservedOutput,
                toolSchemaTokens: fixedNonHistoryTokens,
                imageTokens: imageTokens
            )
        } else {
            policy = .cloud(
                contextWindowTokens: limits.contextTokens,
                reservedOutputTokens: reservedOutput,
                toolSchemaTokens: fixedNonHistoryTokens,
                imageTokens: imageTokens
            )
        }
        let available = policy.budget.availableInputTokens
        let needs = Double(estimated) >= Double(available) * policy.budget.triggerRatio
        return Projection(
            policy: policy,
            estimatedHistoryTokens: estimated,
            availableInputTokens: available,
            reservedSchemaTokens: schemaTokens,
            reservedSystemContextTokens: reservation.systemContextTokenEstimate,
            needsCompaction: needs
        )
    }

    /// Commit CAS on the FULL native identity of the projected history: every
    /// message's durable UUID, role, content, inline image evidence, reasoning
    /// continuation and compaction coverage set (`ConversationMessage`'s
    /// synthesized equality covers all stored fields). Equal role+text alone
    /// must NOT commit: identical text with different message IDs, changed
    /// images, changed reasoning payloads, or a tool call/result pair whose
    /// envelope evidence moved means the pre-compaction snapshot no longer
    /// describes what the durable store holds, so the caller discards the
    /// result and keeps the originals.
    public static func isIdenticalHistory(
        _ before: [ConversationMessage],
        _ current: [ConversationMessage]
    ) -> Bool {
        before == current
    }
}

/// One recoverable pre-switch history cleanup for a smaller-context incoming
/// model. This is deliberately a value struct with injected effects so every
/// decision and commit rule is testable without the App target:
///
/// - compaction runs only when ``ModelSwitchHistoryPlanner`` says the current
///   projected history does not already fit the incoming model's real window
///   with the caller's honestly-obtainable reservations;
/// - the summarizer, budget arithmetic and compaction record are the existing
///   ``ContextEngine`` / ``ContextCompactionRecord`` lifecycle — no parallel
///   compression store or approval system is introduced;
/// - the messages handed to the engine are exactly the history the
///   conversation already owns. A newly submitted request never flows through
///   this path (the caller assembles the durable projection and the composer
///   draft is not an input here). The protection shape is identical to the
///   existing manual-compaction and ContextEngine usage: the whole latest
///   stored user message plus the engine's contiguous protected tail;
///   `ContextProtection.unresolvedToolPairMessageIDs` is left unset exactly
///   like every current production caller, so pairing boundaries follow the
///   unchanged engine rules rather than a private parallel policy;
/// - before committing, the history is rebuilt and compared with full native
///   identity (``ModelSwitchHistoryPlanner/isIdenticalHistory(_:_:)``) and the
///   `ownershipIsValid` hook re-checks the live selection, the incoming model
///   still being configured/enabled, and the conversation/run/queue
///   ownership; any mismatch returns ``Outcome/stale`` with nothing persisted;
/// - cancellation and engine failure propagate without any commit, so the
///   original history, checkpoints and the user's selection remain intact and
///   the ordinary first-dispatch compaction path still guards the next run.
public struct ModelSwitchHistoryPreparer: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Nothing durable to organize (new conversation or no history).
        case noHistory
        /// The history already fits the incoming window; zero provider calls.
        case fits(estimatedTokens: Int, availableInputTokens: Int)
        /// A launch or run currently owns the conversation; skipped. The
        /// existing first-dispatch compaction path still protects the run.
        case busy
        /// History identity or ownership changed before commit; nothing was
        /// persisted and the originals remain exactly as stored.
        case stale
        /// A sourced compaction record was committed to the existing store.
        case compacted(beforeTokens: Int, afterTokens: Int, compactedMessageCount: Int)
    }

    public init() {}

    public func prepare(
        incomingProviderKind: ProviderKind,
        incomingModel: ModelProfile,
        history: [ConversationMessage],
        reservation: ModelSwitchHistoryPlanner.Reservation,
        engine: any ContextEngine,
        loadFreshHistory: @Sendable () async throws -> [ConversationMessage],
        ownershipIsValid: @Sendable () async -> Bool,
        commit: @Sendable (_ record: ContextCompactionRecord, _ summaryWithPrefix: String) async throws -> Void
    ) async throws -> Outcome {
        try Task.checkCancellation()
        guard !history.isEmpty else { return .noHistory }
        let projection = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: incomingProviderKind,
            incomingModel: incomingModel,
            history: history,
            reservation: reservation
        )
        guard projection.needsCompaction else {
            return .fits(
                estimatedTokens: projection.estimatedHistoryTokens,
                availableInputTokens: projection.availableInputTokens
            )
        }
        // Manual-path parity: protect the latest stored user message; the
        // engine's own contiguous tail keeps tool evidence ordered exactly
        // as in the existing dispatch. Unresolved tool-pair IDs are not a
        // separate pre-switch invention — no current production caller sets
        // them, and the qualification host asserts the identical shape.
        let lastUserID = history.last(where: { $0.role == "user" }).map { $0.id }
        let request = ContextRequest(
            messages: history,
            budget: projection.policy.budget,
            protection: ContextProtection(messageIDs: Set(lastUserID.map { [$0] } ?? []))
        )
        let result = try await engine.compact(CompactionRequest(context: request, force: false))
        try Task.checkCancellation()
        guard !result.record.sourceMessageIDs.isEmpty else {
            // The engine considered the context already manageable: an honest
            // no-op. Do not manufacture an empty summary record.
            return .fits(
                estimatedTokens: result.estimatedTokens,
                availableInputTokens: projection.availableInputTokens
            )
        }
        guard let summary = result.messages.first(where: ContextHistorySnapshot.isSummary)?.content,
              !summary.isEmpty else {
            // A non-empty record without a persistable summary would strand
            // the provenance; treat it as a failed commit and keep originals.
            return .stale
        }
        let current = try await loadFreshHistory()
        try Task.checkCancellation()
        guard ModelSwitchHistoryPlanner.isIdenticalHistory(history, current),
              await ownershipIsValid() else {
            return .stale
        }
        try await commit(result.record, ContextHistorySnapshot.automaticPrefix + summary)
        return .compacted(
            beforeTokens: result.record.beforeEstimatedTokens,
            afterTokens: result.record.afterEstimatedTokens,
            compactedMessageCount: result.record.sourceMessageIDs.count
        )
    }
}
