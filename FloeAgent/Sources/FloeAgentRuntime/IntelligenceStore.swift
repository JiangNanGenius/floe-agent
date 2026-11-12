import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeSecurity

public enum MemoryEntryStatus: String, Sendable, Codable, Hashable {
    case pending, active, rejected, superseded
}

public struct MemoryEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scope: MemoryScope
    public var status: MemoryEntryStatus
    public var content: String
    public var confidence: Double
    public var importance: Double
    public var isPinned: Bool
    public var sourceKind: MemoryCandidateOrigin
    public var originConversationID: UUID?
    public var originWorkspaceID: UUID?
    public var factIdentity: MemoryFactIdentity?
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), scope: MemoryScope, status: MemoryEntryStatus,
        content: String, confidence: Double, importance: Double,
        isPinned: Bool = false, sourceKind: MemoryCandidateOrigin,
        originConversationID: UUID? = nil, originWorkspaceID: UUID? = nil,
        factIdentity: MemoryFactIdentity? = nil,
        expiresAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.status = status
        self.content = String(content.prefix(4_096))
        self.confidence = min(1, max(0, confidence))
        self.importance = min(1, max(0, importance))
        self.isPinned = isPinned
        self.sourceKind = sourceKind
        if case .task(let taskID) = scope {
            self.originConversationID = originConversationID ?? taskID
        } else {
            self.originConversationID = originConversationID
        }
        if case .workspace(let workspaceID) = scope {
            self.originWorkspaceID = originWorkspaceID ?? workspaceID
        } else {
            self.originWorkspaceID = originWorkspaceID
        }
        self.factIdentity = factIdentity?.isValid == true ? factIdentity : nil
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol PlanDraftStore: Sendable {
    func savePlanRevision(_ plan: PlanDraft) async throws
    func latestPlan(conversationID: UUID) async throws -> PlanDraft?
    func planRevisions(conversationID: UUID) async throws -> [PlanDraft]
}

public protocol ConversationGoalStore: Sendable {
    func saveGoal(_ goal: ConversationGoal) async throws
    /// Atomically replaces an existing goal only when its durable revision
    /// still matches the caller's snapshot. The stored revision becomes
    /// `expectedRevision + 1` on success.
    func saveGoalIfRevisionMatches(
        _ goal: ConversationGoal,
        expectedRevision: Int
    ) async throws -> Bool
    func goal(id: UUID) async throws -> ConversationGoal?
    func goals(conversationID: UUID) async throws -> [ConversationGoal]
}

public protocol DurableMemoryStore: Sendable {
    func saveMemory(_ entry: MemoryEntry, evidence: [MemoryEvidenceReference]) async throws
    func memories(scope: MemoryScope, status: MemoryEntryStatus?) async throws -> [MemoryEntry]
    func recall(query: String, workspaceID: UUID?, conversationID: UUID?, limit: Int) async throws -> [MemoryRecallItem]
    func saveEmbedding(_ embedding: MemoryEmbedding) async throws
    func embeddingNeedsRefresh(
        memoryID: UUID, modality: MemoryEmbeddingModality,
        modelIdentifier: String, modelRevision: String, contentDigest: String
    ) async throws -> Bool
    func hybridRecall(_ request: HybridMemoryRecallRequest) async throws -> [HybridMemoryRecallItem]
    func deleteMemory(id: UUID, syncRevision: Int64) async throws
    func memory(id: UUID) async throws -> MemoryEntry?
    func memories(factIdentity: MemoryFactIdentity, scope: MemoryScope?) async throws -> [MemoryEntry]
    func organizationPreview(limit: Int) async throws -> MemoryOrganizationProposal
    func applyMaintenanceBatch(_ batch: MemoryMaintenanceBatch) async throws -> MemoryMaintenanceBatchResult
    func listMemories(_ request: MemoryListRequest) async throws -> MemoryListPage
    func recordMemoryUse(_ ids: [UUID], runID: UUID) async
}

public extension DurableMemoryStore {
    func recordMemoryUse(_ ids: [UUID], runID: UUID) async {}
    /// Compatibility fallback for lightweight stores used by extensions and
    /// tests. Production SQLite storage overrides this with true SQL paging.
    func listMemories(_ request: MemoryListRequest) async throws -> MemoryListPage {
        let scopes: [MemoryScope] = request.scope.map { [$0] } ?? [.userProfile, .agentGlobal]
        var values: [MemoryEntry] = []
        for scope in scopes {
            values += try await memories(scope: scope, status: request.status)
        }
        values = values.filter { entry in
            if let id = request.originConversationID, entry.originConversationID != id { return false }
            if let id = request.originWorkspaceID, entry.originWorkspaceID != id { return false }
            if let fact = request.factIdentity, entry.factIdentity != fact { return false }
            if let pinned = request.isPinned, entry.isPinned != pinned { return false }
            return true
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
        guard let offset = Int(request.cursor ?? "0"), offset >= 0 else {
            throw FloeError.validationFailed("memory.list cursor is invalid")
        }
        let start = min(offset, values.count)
        let end = min(start + request.limit, values.count)
        return MemoryListPage(
            entries: Array(values[start..<end]),
            nextCursor: end < values.count ? String(end) : nil
        )
    }
}

/// One durable implementation for plans, goals, bounded memory and explicit
/// cross-conversation history access. The runtime owns semantic types while
/// the shared DatabaseManager preserves serialized writes and foreign keys.
public actor SQLiteIntelligenceStore: PlanDraftStore, ConversationGoalStore, DurableMemoryStore, ConversationHistoryReader, ConversationContextCompactionStore {
    private struct ConversationTimelineCursor: Codable {
        var createdAt: String
        var sequence: Int
        var itemID: String
        /// UTF-8 byte offset inside `itemID`'s content at which the next page
        /// resumes. 0 means the next page starts strictly after this item.
        /// Decoded cursors written before segmentation default to 0.
        var contentOffset: Int = 0

        init(createdAt: String, sequence: Int, itemID: String, contentOffset: Int = 0) {
            self.createdAt = createdAt
            self.sequence = sequence
            self.itemID = itemID
            self.contentOffset = max(0, contentOffset)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            sequence = try container.decode(Int.self, forKey: .sequence)
            itemID = try container.decode(String.self, forKey: .itemID)
            contentOffset = try container.decodeIfPresent(Int.self, forKey: .contentOffset) ?? 0
        }
    }
    private let database: DatabaseManager
    private nonisolated let memoryUseRegistry = MemoryUseRegistry()

    public nonisolated func beginMemoryUse(runID: UUID) -> MemoryRunUseLease {
        memoryUseRegistry.begin(runID: runID)
    }

    public nonisolated func recordMemoryUse(_ ids: [UUID], runID: UUID) async {
        memoryUseRegistry.record(ids, runID: runID)
    }

    public nonisolated func withMemoryUseProtection<T>(_ body: (Set<UUID>) throws -> T) rethrows -> T {
        try memoryUseRegistry.withProtectedIDs(body)
    }

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Rebuild compacted model context without deleting the original audit
    /// timeline. Summary IDs are stable so later compactions can replace them.
    public func applyingCompactions(_ messages: [ConversationMessage], conversationID: UUID) async throws -> [ConversationMessage] {
        let rows = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.source_message_ids_json, c.summary
                FROM context_compactions c JOIN runs r ON r.id = c.run_id
                WHERE r.conversation_id = ? AND (c.summary LIKE ? OR c.summary LIKE ?)
                ORDER BY c.created_at, c.rowid
                """, arguments: [conversationID.uuidString,
                    ContextHistorySnapshot.manualPrefix + "%",
                    ContextHistorySnapshot.automaticPrefix + "%"]
                ).map { row -> [String: String] in
                    ["id": row["id"], "source_message_ids_json": row["source_message_ids_json"], "summary": row["summary"]]
                }
        }
        var result = messages
        var coverageBySummary: [UUID: Set<UUID>] = [:]
        for row in rows {
            let idText = row["id"] ?? ""
            let sourceJSON = row["source_message_ids_json"] ?? "[]"
            let summary = row["summary"] ?? ""
            guard let id = UUID(uuidString: idText),
                  let sources = try? JSONDecoder().decode([UUID].self, from: Data(sourceJSON.utf8)),
                  !sources.isEmpty, !summary.isEmpty else { continue }
            // Older manual snapshots can point only to their predecessor's
            // summary ID. Resolve that lineage while all rows are available.
            var replaced = Set(sources)
            for source in sources { replaced.formUnion(coverageBySummary[source] ?? []) }
            coverageBySummary[id] = replaced
            result.removeAll { replaced.contains($0.id) || $0.id == id }
            result.insert(ConversationMessage(id: id, role: "system", content: summary,
                contextSourceMessageIDs: replaced.sorted { $0.uuidString < $1.uuidString }), at: 0)
        }
        return result
    }

    public func saveCompaction(
        runID: UUID,
        record: ContextCompactionRecord,
        summary: String
    ) async throws {
        guard summary.utf8.count <= 131_072 else {
            throw FloeError.validationFailed("Compaction summary exceeds the durable record limit; history was not replaced")
        }
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO context_compactions (
                    id, run_id, source_message_ids_json, boundary_start_id,
                    boundary_end_id, summary, source_digest, input_tokens,
                    output_tokens, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    record.id.uuidString,
                    runID.uuidString,
                    try Self.json(record.sourceMessageIDs),
                    record.sourceMessageIDs.first?.uuidString,
                    record.sourceMessageIDs.last?.uuidString,
                    summary,
                    record.sourceDigest,
                    record.beforeEstimatedTokens,
                    record.afterEstimatedTokens,
                    Self.date(record.createdAt)
                ])
        }
    }

    public func savePlanRevision(_ plan: PlanDraft) async throws {
        try await database.writer { db in try Self.writePlan(plan, in: db) }
    }

    private static func writePlan(_ plan: PlanDraft, in db: Database) throws {
        let sections = try Self.json(plan.sections)
        let assumptions = try Self.json(plan.assumptions)
        let risks = try Self.json(plan.risks)
        let criteria = try Self.json(plan.acceptanceCriteria)
        let messages = try Self.json(plan.sourceMessageIDs)
        let references = try Self.json(plan.sourceReferences)
        try db.execute(sql: """
            INSERT INTO plan_drafts (
                id, conversation_id, workspace_id, revision, status, title, summary,
                sections_json, assumptions_json, risks_json, criteria_json,
                source_message_ids_json, source_conversation_refs_json, digest,
                execution_recommendation, recommendation_reason, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                plan.id.uuidString, plan.conversationID.uuidString, plan.workspaceID?.uuidString,
                plan.revision, plan.status.rawValue, plan.title, plan.summary, sections,
                assumptions, risks, criteria, messages, references, plan.digest,
                plan.executionRecommendation?.rawValue, plan.recommendationReason,
                Self.date(plan.createdAt), Self.date(plan.updatedAt)
            ])
    }

    /// One user decision: safe accepted revision, optional Goal and the
    /// existing conversation's user-message snapshot commit together. Secret
    /// capture finishes before this transaction; provider/VM work stays later.
    public func confirmPlan(
        _ expected: PlanDraft, conversationID: UUID,
        execution: PlanExecutionRecommendation,
        captureSecrets: (@Sendable ([CapturedSecret]) async throws -> Void)? = nil
    ) async throws -> PlanConfirmationReceipt {
        guard expected.conversationID == conversationID, expected.revision > 0,
              expected.revision < Int.max else { throw FloeError.unauthorized }
        let prior = try await database.reader { db -> PlanConfirmationReceipt? in
            let source = try Self.confirmationSource(expected, in: db)
            if let receipt = try Self.existingConfirmation(source, execution: execution, in: db) { return receipt }
            try Self.requireCurrentPlan(source, in: db)
            return nil
        }
        if let prior { return prior }
        let ingress = try PlanConfirmationIngress(expected)
        if !ingress.captures.isEmpty {
            guard let captureSecrets else {
                throw FloeError.validationFailed(FloeL10n.isChinese
                    ? "请通过计划卡片确认，以安全保存所需凭据。" : "Confirm from the plan card to securely save its credentials.")
            }
            try await captureSecrets(ingress.captures)
        }
        try Task.checkCancellation()
        return try await database.writer { db in
            let source = try Self.confirmationSource(expected, in: db)
            // A concurrent confirmation won while credentials were captured.
            // Keep that exact committed decision and planned run identity.
            if let receipt = try Self.existingConfirmation(source, execution: execution, in: db) { return receipt }
            try Self.requireCurrentPlan(source, in: db)
            let accepted = ingress.plan.revised(status: .accepted, digest: source.digest)
            var goal: ConversationGoal?
            if execution == .goal {
                var value = try GoalFromPlanFactory.makeGoal(from: accepted)
                value.status = .active; value.progress.startedAt = accepted.updatedAt
                goal = value
            }
            let snapshot = try PlanConfirmationSnapshot.decode(PlanConfirmationSnapshot(
                plan: accepted, sourceRevision: source.revision, execution: execution,
                executionRunID: UUID(), goalID: goal?.id,
                executionPrompt: ingress.executionPrompt).encoded())
            try Self.writePlan(snapshot.plan, in: db)
            if let goal { try Self.writeGoal(goal, in: db) }
            try db.execute(sql: """
                INSERT INTO messages(id,conversation_id,role,content,created_at,run_id)
                VALUES(?,?,'user',?,?,NULL)
                """, arguments: [snapshot.messageID.uuidString, conversationID.uuidString,
                    snapshot.executionPrompt, Self.date(snapshot.plan.updatedAt)])
            try db.execute(sql: """
                INSERT INTO message_parts(id,message_id,part_index,kind,text,attachment_id,metadata_json,created_at)
                VALUES(?,?,0,'text',?,NULL,?,?)
                """, arguments: [UUID().uuidString, snapshot.messageID.uuidString, snapshot.executionPrompt,
                    try Self.json([PlanConfirmationSnapshot.metadataKey: snapshot.encoded()]),
                    Self.date(snapshot.plan.updatedAt)])
            try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                           arguments: [Self.date(snapshot.plan.updatedAt), conversationID.uuidString])
            guard db.changesCount == 1 else { throw FloeError.notFound("Conversation") }
            return PlanConfirmationReceipt(snapshot: snapshot, goal: goal, wasCreated: true)
        }
    }

    /// An explicit retry may launch only the exact committed, unused message
    /// and planned run. It cannot confirm again or revive a superseded plan.
    public func planConfirmationForLaunch(
        _ expected: PlanConfirmationSnapshot, conversationID: UUID
    ) async throws -> PlanConfirmationReceipt {
        guard expected.plan.conversationID == conversationID else { throw FloeError.unauthorized }
        return try await database.reader { db in
            guard let sourceRow = try Row.fetchOne(db,
                sql: "SELECT * FROM plan_drafts WHERE id=? AND conversation_id=? AND revision=?",
                arguments: [expected.plan.id.uuidString, conversationID.uuidString, expected.sourceRevision]),
                  let receipt = try Self.existingConfirmation(Self.plan(sourceRow), execution: expected.execution, in: db),
                  receipt.snapshot == expected,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id=? AND conversation_id=? AND run_id IS NULL)",
                    arguments: [expected.messageID.uuidString, conversationID.uuidString]) == true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM runs WHERE id=?)",
                    arguments: [expected.executionRunID.uuidString]) == false else {
                throw FloeError.validationFailed(FloeL10n.isChinese
                    ? "此计划已开始或已改变，请重新打开任务后继续。" : "This plan has started or changed. Reopen the task to continue.")
            }
            return receipt
        }
    }

    private static func confirmationSource(_ expected: PlanDraft, in db: Database) throws -> PlanDraft {
        guard let row = try Row.fetchOne(db,
            sql: "SELECT * FROM plan_drafts WHERE id=? AND conversation_id=? AND revision=?",
            arguments: [expected.id.uuidString, expected.conversationID.uuidString, expected.revision]) else {
            throw FloeError.notFound("Plan")
        }
        let source = try Self.plan(row)
        var definition = expected
        definition.createdAt = source.createdAt; definition.updatedAt = source.updatedAt
        guard source.status == .ready, source.isDecisionComplete, source == definition else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "计划已改变或仍需补充，请重新打开后确认。" : "The plan changed or still needs clarification; reopen it before confirming")
        }
        return source
    }

    private static func requireCurrentPlan(_ plan: PlanDraft, in db: Database) throws {
        guard let current = try Row.fetchOne(db,
            sql: "SELECT id,revision FROM plan_drafts WHERE conversation_id=? ORDER BY revision DESC LIMIT 1",
            arguments: [plan.conversationID.uuidString]),
              current["id"] as String == plan.id.uuidString, current["revision"] as Int == plan.revision else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "已有更新的计划，请重新打开后确认。" : "A newer plan is available; reopen it before confirming")
        }
    }

    private static func existingConfirmation(
        _ source: PlanDraft, execution: PlanExecutionRecommendation, in db: Database
    ) throws -> PlanConfirmationReceipt? {
        let messageID = PlanConfirmationSnapshot.messageID(
            conversationID: source.conversationID, planID: source.id, sourceRevision: source.revision)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id=?",
                                         arguments: [messageID.uuidString]) else { return nil }
        guard row["conversation_id"] as String == source.conversationID.uuidString,
              row["role"] as String == "user",
              let metadata = try String.fetchOne(db,
                sql: "SELECT metadata_json FROM message_parts WHERE message_id=? AND part_index=0 AND kind='text'",
                arguments: [messageID.uuidString]),
              let raw = try Self.decode([String: String].self, metadata)[PlanConfirmationSnapshot.metadataKey] else {
            throw FloeError.storageCorrupted(FloeL10n.isChinese
                ? "计划确认记录暂时不可用，请重新打开任务。" : "The plan confirmation message is unavailable")
        }
        let snapshot = try PlanConfirmationSnapshot.decode(raw)
        guard snapshot.messageID == messageID, snapshot.plan.conversationID == source.conversationID,
              snapshot.plan.id == source.id, snapshot.sourceRevision == source.revision,
              snapshot.plan.digest == source.digest, snapshot.execution == execution,
              snapshot.executionPrompt == row["content"] as String,
              let accepted = try Row.fetchOne(db,
                sql: "SELECT * FROM plan_drafts WHERE id=? AND conversation_id=? AND revision=? AND status='accepted'",
                arguments: [source.id.uuidString, source.conversationID.uuidString, snapshot.plan.revision]),
              try Self.plan(accepted) == snapshot.plan else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "此计划的确认记录已改变，请重新打开当前计划。" : "This plan's confirmation changed; reopen the current plan")
        }
        try Self.requireCurrentPlan(snapshot.plan, in: db)
        let goal: ConversationGoal?
        if let goalID = snapshot.goalID {
            guard let goalRow = try Row.fetchOne(db,
                sql: "SELECT * FROM conversation_goals WHERE id=? AND conversation_id=?",
                arguments: [goalID.uuidString, source.conversationID.uuidString]) else {
                throw FloeError.storageCorrupted(FloeL10n.isChinese
                    ? "对应目标暂时不可用，请重新打开任务。" : "The confirmed Goal is unavailable")
            }
            goal = try Self.goal(goalRow)
        } else { goal = nil }
        return PlanConfirmationReceipt(snapshot: snapshot, goal: goal, wasCreated: false)
    }

    public func latestPlan(conversationID: UUID) async throws -> PlanDraft? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM plan_drafts WHERE conversation_id = ?
                ORDER BY revision DESC LIMIT 1
                """, arguments: [conversationID.uuidString]) else { return nil }
            return try Self.plan(row)
        }
    }

    public func planRevisions(conversationID: UUID) async throws -> [PlanDraft] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM plan_drafts WHERE conversation_id = ? ORDER BY revision
                """, arguments: [conversationID.uuidString]).map(Self.plan)
        }
    }

    public func saveGoal(_ goal: ConversationGoal) async throws {
        try await database.writer { db in try Self.writeGoal(goal, in: db) }
    }

    private static func writeGoal(_ goal: ConversationGoal, in db: Database) throws {
        let criteria = try Self.json(goal.acceptanceCriteria)
        let steps = try Self.json(goal.steps)
        let evidence = try Self.json(goal.evidence)
        let budgets = try Self.json(goal.budgets)
        let progress = try Self.json(goal.progress)
        let blockingConditions = try Self.json(goal.blockingConditions ?? [])
        let stoppingConditions = try Self.json(goal.stoppingConditions ?? [])
        try db.execute(sql: """
            INSERT INTO conversation_goals (
                id, conversation_id, source_plan_id, source_plan_digest, objective,
                status, criteria_json, steps_json, evidence_json, budgets_json,
                progress_json, blocking_fingerprint, consecutive_blocked_cycles,
                blocking_conditions_json, stopping_conditions_json, revision,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                objective=excluded.objective, status=excluded.status,
                criteria_json=excluded.criteria_json, steps_json=excluded.steps_json,
                evidence_json=excluded.evidence_json, budgets_json=excluded.budgets_json,
                progress_json=excluded.progress_json,
                blocking_fingerprint=excluded.blocking_fingerprint,
                consecutive_blocked_cycles=excluded.consecutive_blocked_cycles,
                blocking_conditions_json=excluded.blocking_conditions_json,
                stopping_conditions_json=excluded.stopping_conditions_json,
                revision=excluded.revision,
                updated_at=excluded.updated_at
            """, arguments: [
                goal.id.uuidString, goal.conversationID.uuidString, goal.sourcePlanID?.uuidString,
                goal.sourcePlanDigest, goal.objective, goal.status.rawValue, criteria, steps,
                evidence, budgets, progress, goal.progress.repeatedBlockerKey,
                goal.progress.repeatedBlockerCount, blockingConditions, stoppingConditions,
                goal.revision ?? 1, Self.date(goal.createdAt), Self.date(goal.updatedAt)
            ])
        try db.execute(sql: "DELETE FROM goal_criteria WHERE goal_id = ?", arguments: [goal.id.uuidString])
        for (index, criterion) in goal.acceptanceCriteria.enumerated() {
            try db.execute(sql: """
                INSERT INTO goal_criteria (id, goal_id, criterion_index, text, status, evidence_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [criterion.id.uuidString, goal.id.uuidString, index,
                    criterion.text, criterion.isSatisfied ? "satisfied" : "pending",
                    try Self.json(criterion.evidenceIDs), Self.date(goal.updatedAt)])
        }
        try db.execute(sql: "DELETE FROM goal_steps WHERE goal_id = ?", arguments: [goal.id.uuidString])
        for (index, step) in goal.steps.enumerated() {
            try db.execute(sql: """
                INSERT INTO goal_steps (id, goal_id, step_index, title, detail, status, evidence_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [step.id.uuidString, goal.id.uuidString, index, step.title,
                    step.detail, step.status.rawValue, try Self.json(step.evidenceIDs), Self.date(goal.updatedAt)])
        }
    }

    /// The model can refine its current task, never supply another task ID,
    /// change permissions/budgets, or replace unfinished user work. Creation
    /// and assignment to this exact executing run share one SQL transaction.
    public func createGoalForCurrentRun(_ input: TaskGoalCreateArguments, runID: UUID,
        conversationID: UUID, callID: String, budgets: GoalBudgets, cancellation: CancellationToken) async throws -> ConversationGoal {
        try input.validate(); try cancellation.throwIfCancelled()
        let goalID = TaskGoalCreateArguments.identity("goal:\(runID):\(callID)")
        return try await database.writer { db in
            try cancellation.throwIfCancelled()
            guard !callID.isEmpty,
                  let run = try Row.fetchOne(db, sql: """
                    SELECT r.* FROM runs r WHERE r.id=? AND r.conversation_id=?
                    AND r.state NOT IN ('completed','failed','cancelled','canceled','aborted')
                    AND NOT EXISTS (
                        SELECT 1 FROM runs newer WHERE newer.conversation_id=r.conversation_id
                        AND (newer.started_at>r.started_at OR (newer.started_at=r.started_at AND newer.id>r.id))
                    )
                    """,
                    arguments: [runID.uuidString, conversationID.uuidString]),
                  (run["ended_at"] as String?) == nil,
                  (run["conversation_mode"] as String?) != "plan",
                  let conversation = try Row.fetchOne(db, sql: "SELECT purpose FROM conversations WHERE id=?",
                    arguments: [conversationID.uuidString]),
                  (conversation["purpose"] as String?) != "temporary" else { throw TaskGoalError.staleRun }
            let task = (run["goal"] as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, task.utf8.count <= 128_000 else { throw TaskGoalError.invalidArguments }
            let criteria = input.acceptanceCriteria.enumerated().map {
                GoalCriterion(id: TaskGoalCreateArguments.identity("\(goalID):criterion:\($0.offset)"),
                    text: $0.element.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let steps = input.steps.enumerated().map {
                GoalStep(id: TaskGoalCreateArguments.identity("\(goalID):step:\($0.offset)"),
                    title: $0.element.trimmingCharacters(in: .whitespacesAndNewlines),
                    detail: $0.offset == 0 ? input.objective.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                    status: $0.offset == 0 ? .inProgress : .pending, order: $0.offset)
            }
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM conversation_goals WHERE id=?",
                arguments: [goalID.uuidString]) {
                let saved = try Self.goal(existing)
                guard (run["goal_id"] as String?) == goalID.uuidString,
                      saved.conversationID == conversationID, saved.objective == task,
                      saved.acceptanceCriteria.map(\.text) == criteria.map(\.text),
                      saved.steps.map(\.title) == steps.map(\.title),
                      saved.steps.map(\.detail) == steps.map(\.detail) else { throw TaskGoalError.identityReused }
                return saved // Exact call replay retains progress and evidence.
            }
            guard (run["goal_id"] as String?) == nil else { throw TaskGoalError.staleRun }
            let unfinished = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM conversation_goals WHERE conversation_id=?
                AND status NOT IN ('completed','cancelled','failed')
                """, arguments: [conversationID.uuidString]) ?? 0
            guard unfinished == 0 else { throw TaskGoalError.activeGoalExists }
            let goal = ConversationGoal(id: goalID, conversationID: conversationID,
                objective: task, acceptanceCriteria: criteria, steps: steps, status: .active,
                budgets: budgets, progress: .init(startedAt: Date()))
            try Self.writeGoal(goal, in: db)
            try cancellation.throwIfCancelled()
            try db.execute(sql: """
                UPDATE runs SET goal_id=? WHERE id=? AND conversation_id=? AND goal_id IS NULL AND ended_at IS NULL
                AND state NOT IN ('completed','failed','cancelled','canceled','aborted')
                """, arguments: [goalID.uuidString, runID.uuidString, conversationID.uuidString])
            guard db.changesCount == 1 else { throw TaskGoalError.staleRun }
            try Self.appendGoalRoundAdmission(goal, runID: runID, in: db)
            return goal
        }
    }

    public func goalForCurrentRun(runID: UUID, conversationID: UUID) async throws -> ConversationGoal? {
        try await database.reader { db in
            guard let run = try Row.fetchOne(db, sql: "SELECT goal_id,ended_at FROM runs WHERE id=? AND conversation_id=?",
                arguments: [runID.uuidString, conversationID.uuidString]), (run["ended_at"] as String?) == nil else {
                throw TaskGoalError.staleRun
            }
            if let id = run["goal_id"] as String? {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversation_goals WHERE id=? AND conversation_id=?",
                    arguments: [id, conversationID.uuidString]) else { throw TaskGoalError.staleRun }
                return try Self.goal(row)
            }
            return try Row.fetchOne(db, sql: """
                SELECT * FROM conversation_goals WHERE conversation_id=? ORDER BY updated_at DESC LIMIT 1
                """, arguments: [conversationID.uuidString]).map(Self.goal)
        }
    }

    /// Native direct-start compatibility: create/bind once, never select a
    /// different unfinished Goal or overwrite a later user's saved Goal.
    public func bindNewGoalToRun(_ goal: ConversationGoal, runID: UUID) async throws -> ConversationGoal {
        try await database.writer { db in
            guard let run = try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id=? AND conversation_id=?",
                arguments: [runID.uuidString, goal.conversationID.uuidString]),
                  (run["ended_at"] as String?) == nil,
                  !["completed","failed","cancelled","canceled","aborted"].contains(run["state"] as String) else { throw TaskGoalError.staleRun }
            if let bound = run["goal_id"] as String? {
                guard bound == goal.id.uuidString,
                      let row = try Row.fetchOne(db, sql: "SELECT * FROM conversation_goals WHERE id=? AND conversation_id=?",
                        arguments: [bound, goal.conversationID.uuidString]) else { throw TaskGoalError.staleRun }
                return try Self.goal(row)
            }
            guard (run["conversation_mode"] as String?) == "goal",
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_goals WHERE conversation_id=? AND status NOT IN ('completed','cancelled','failed')",
                    arguments: [goal.conversationID.uuidString]) == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_goals WHERE id=?", arguments: [goal.id.uuidString]) == 0 else {
                throw TaskGoalError.activeGoalExists
            }
            try Self.writeGoal(goal, in: db)
            try db.execute(sql: "UPDATE runs SET goal_id=? WHERE id=? AND conversation_id=? AND goal_id IS NULL",
                arguments: [goal.id.uuidString, runID.uuidString, goal.conversationID.uuidString])
            guard db.changesCount == 1 else { throw TaskGoalError.staleRun }
            try Self.appendGoalRoundAdmission(goal, runID: runID, in: db)
            return goal
        }
    }

    private static func appendGoalRoundAdmission(_ goal: ConversationGoal, runID: UUID, in db: Database) throws {
        let payload = try Self.json(["kind":"goalRoundAdmission", "goalID":goal.id.uuidString,
            "goalRevision":String(goal.revision ?? 1), "goalDefinitionFingerprint":try GoalRunDefinitionFingerprint.make(goal)])
        let sequence = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence),0)+1 FROM run_events WHERE run_id=?",
            arguments: [runID.uuidString]) ?? 1
        try db.execute(sql: "INSERT INTO run_events(id,run_id,sequence,kind,payload_json,created_at) VALUES (?,?,?,'status',?,?)",
            arguments: [UUID().uuidString, runID.uuidString, sequence, payload, Self.date(Date())])
    }

    /// One existing writer transaction records native accounting plus a CAS
    /// on the CURRENT Goal. It never writes definition/criteria/steps/budgets.
    /// Nil means the exact run/Goal binding was retired: no replacement or
    /// arbitrary first Goal may be created or selected.
    public func settleGoalRun(_ input: GoalRunSettlementInput) async throws -> GoalRunSettlementResult? {
        guard input.modelCallCount >= 0, input.toolIterationCount >= 0 else { throw TaskGoalError.invalidArguments }
        return try await database.writer { db in
            guard let run = try Row.fetchOne(db, sql: "SELECT goal_id,started_at FROM runs WHERE id=? AND conversation_id=?",
                    arguments: [input.runID.uuidString, input.conversationID.uuidString]),
                  (run["goal_id"] as String?) == input.goalID.uuidString,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM conversation_goals WHERE id=? AND conversation_id=?",
                    arguments: [input.goalID.uuidString, input.conversationID.uuidString]) else { return nil }
            var goal = try Self.goal(row)
            let marker = try Row.fetchOne(db, sql: "SELECT payload_json FROM goal_events WHERE goal_id=? AND run_id=? AND kind='nativeRunAccounting.v1' ORDER BY sequence DESC LIMIT 1",
                arguments: [input.goalID.uuidString, input.runID.uuidString])
            let prior = try marker.map { try JSONDecoder().decode(GoalRunAccountingReceipt.self, from: Data(($0["payload_json"] as String).utf8)) }
            guard prior == nil || (prior?.goalID == input.goalID && prior?.runID == input.runID) else { throw TaskGoalError.staleRun }
            let admissionRevision = prior == nil ? input.admissionRevision : prior?.admissionRevision
            let fingerprint = prior?.admissionDefinitionFingerprint ?? input.admissionDefinitionFingerprint
            // A legacy nil fingerprint must remain unknown, even if a later
            // caller offers the current edited definition as a replacement.
            let originalFingerprint = prior == nil ? fingerprint : prior?.admissionDefinitionFingerprint
            let currentFingerprint = try GoalRunDefinitionFingerprint.make(goal)
            let matched = originalFingerprint.map { $0 == currentFingerprint } ?? false
            let calls = max(prior?.modelCallCount ?? 0, input.modelCallCount)
            let iterations = max(prior?.toolIterationCount ?? 0, input.toolIterationCount)
            let callDelta = calls - (prior?.modelCallCount ?? 0)
            let iterationDelta = iterations - (prior?.toolIterationCount ?? 0)
            let countCycle = input.completed && prior?.cycleCounted != true
            let cycleCounted = prior?.cycleCounted == true || input.completed
            let known = Set(goal.evidence.map(\.reference))
            let fresh = input.evidence.filter { !known.contains($0.reference) && $0.reference.hasPrefix("run:\(input.runID.uuidString):event:") }
            guard callDelta > 0 || iterationDelta > 0 || countCycle || !fresh.isEmpty else {
                return .init(goal: goal, definitionMatched: matched, didRecordChange: false, cycleCounted: cycleCounted)
            }
            let oldRevision = goal.revision ?? 1
            let newCalls = goal.progress.modelCallCount.addingReportingOverflow(callDelta)
            let newIterations = goal.progress.totalIterationCount.addingReportingOverflow(iterationDelta)
            let newCycles = goal.progress.cycleCount.addingReportingOverflow(countCycle ? 1 : 0)
            guard !newCalls.overflow, !newIterations.overflow, !newCycles.overflow else { throw TaskGoalError.invalidArguments }
            goal.progress.modelCallCount = newCalls.partialValue
            goal.progress.totalIterationCount = newIterations.partialValue
            goal.progress.cycleCount = newCycles.partialValue
            if goal.progress.startedAt == nil { goal.progress.startedAt = Self.parseDate(run["started_at"] as String) }
            goal.progress.lastCheckpointAt = Date()
            goal.evidence.append(contentsOf: fresh)
            if countCycle && matched && goal.status == .active { goal.status = .verifying }
            goal.revision = oldRevision + 1; goal.updatedAt = Date()
            try db.execute(sql: """
                UPDATE conversation_goals SET status=?,evidence_json=?,progress_json=?,revision=?,updated_at=?
                WHERE id=? AND conversation_id=? AND revision=?
                """, arguments: [goal.status.rawValue, try Self.json(goal.evidence), try Self.json(goal.progress),
                    oldRevision + 1, Self.date(goal.updatedAt), input.goalID.uuidString, input.conversationID.uuidString, oldRevision])
            guard db.changesCount == 1 else { throw TaskGoalError.staleRun }
            let receipt = GoalRunAccountingReceipt(runID: input.runID, goalID: input.goalID,
                admissionRevision: admissionRevision, admissionDefinitionFingerprint: originalFingerprint,
                modelCallCount: calls, toolIterationCount: iterations, cycleCounted: cycleCounted)
            let sequence = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence),0)+1 FROM goal_events WHERE goal_id=?",
                arguments: [input.goalID.uuidString]) ?? 1
            try db.execute(sql: "INSERT INTO goal_events(id,goal_id,run_id,sequence,kind,payload_json,created_at) VALUES (?,?,?,?,'nativeRunAccounting.v1',?,?)",
                arguments: [UUID().uuidString, input.goalID.uuidString, input.runID.uuidString, sequence, try Self.json(receipt), Self.date(Date())])
            return .init(goal: goal, definitionMatched: matched, didRecordChange: true, cycleCounted: cycleCounted)
        }
    }

    public func saveGoalIfRevisionMatches(
        _ goal: ConversationGoal,
        expectedRevision: Int
    ) async throws -> Bool {
        let criteria = try Self.json(goal.acceptanceCriteria)
        let steps = try Self.json(goal.steps)
        let evidence = try Self.json(goal.evidence)
        let budgets = try Self.json(goal.budgets)
        let progress = try Self.json(goal.progress)
        let blockingConditions = try Self.json(goal.blockingConditions ?? [])
        let stoppingConditions = try Self.json(goal.stoppingConditions ?? [])
        return try await database.writer { db in
            try db.execute(sql: """
                UPDATE conversation_goals SET
                    source_plan_id = ?, source_plan_digest = ?, objective = ?,
                    status = ?, criteria_json = ?, steps_json = ?, evidence_json = ?,
                    budgets_json = ?, progress_json = ?, blocking_fingerprint = ?,
                    consecutive_blocked_cycles = ?, blocking_conditions_json = ?,
                    stopping_conditions_json = ?, revision = ?, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [
                    goal.sourcePlanID?.uuidString, goal.sourcePlanDigest, goal.objective,
                    goal.status.rawValue, criteria, steps, evidence, budgets, progress,
                    goal.progress.repeatedBlockerKey, goal.progress.repeatedBlockerCount,
                    blockingConditions, stoppingConditions, expectedRevision + 1,
                    Self.date(goal.updatedAt), goal.id.uuidString, expectedRevision
                ])
            guard db.changesCount == 1 else { return false }
            try db.execute(
                sql: "DELETE FROM goal_criteria WHERE goal_id = ?",
                arguments: [goal.id.uuidString]
            )
            for (index, criterion) in goal.acceptanceCriteria.enumerated() {
                try db.execute(sql: """
                    INSERT INTO goal_criteria (id, goal_id, criterion_index, text, status, evidence_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        criterion.id.uuidString, goal.id.uuidString, index,
                        criterion.text, criterion.isSatisfied ? "satisfied" : "pending",
                        try Self.json(criterion.evidenceIDs), Self.date(goal.updatedAt)
                    ])
            }
            try db.execute(
                sql: "DELETE FROM goal_steps WHERE goal_id = ?",
                arguments: [goal.id.uuidString]
            )
            for (index, step) in goal.steps.enumerated() {
                try db.execute(sql: """
                    INSERT INTO goal_steps (id, goal_id, step_index, title, detail, status, evidence_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        step.id.uuidString, goal.id.uuidString, index, step.title,
                        step.detail, step.status.rawValue, try Self.json(step.evidenceIDs),
                        Self.date(goal.updatedAt)
                    ])
            }
            return true
        }
    }

    public func goal(id: UUID) async throws -> ConversationGoal? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversation_goals WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.goal(row)
        }
    }

    public func goals(conversationID: UUID) async throws -> [ConversationGoal] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM conversation_goals WHERE conversation_id = ? ORDER BY updated_at DESC
                """, arguments: [conversationID.uuidString]).map(Self.goal)
        }
    }

    public func saveMemory(_ entry: MemoryEntry, evidence: [MemoryEvidenceReference]) async throws {
        try await database.writer { db in
            try Self.saveMemory(entry, evidence: evidence, in: db)
        }
    }

    /// Shared transaction body: pending review can commit activation and its
    /// compare-and-swap status change without an intervening eviction writer.
    static func saveMemory(_ entry: MemoryEntry, evidence: [MemoryEvidenceReference], in db: Database) throws {
        let (scope, workspaceID, conversationID) = Self.scope(entry.scope)
        let normalized = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw FloeError.validationFailed("Memory must not be empty") }
        guard !Self.looksLikeSecret(normalized) else {
            throw FloeError.validationFailed("Authentication material cannot be saved to memory")
        }
        let replacementRevision = Int64(Date().timeIntervalSince1970 * 1_000)
        if let identity = entry.factIdentity {
            let arguments: StatementArguments = [
                identity.subjectKey, identity.attributeKey, entry.id.uuidString, scope,
                workspaceID?.uuidString, workspaceID?.uuidString,
                conversationID?.uuidString, conversationID?.uuidString
            ]
            let superseded = try String.fetchAll(db, sql: """
                SELECT id FROM memory_entries
                WHERE subject_key = ? AND attribute_key = ? AND id <> ? AND scope = ?
                  AND (workspace_id IS ? OR origin_workspace_id IS ?)
                  AND (conversation_id IS ? OR origin_conversation_id IS ?)
                """, arguments: arguments)
            let deletedAt = Self.date(Date())
            for oldID in superseded {
                try db.execute(sql: "DELETE FROM memory_entries WHERE id = ?", arguments: [oldID])
                try db.execute(sql: """
                    INSERT INTO memory_tombstones (memory_id, deleted_at, sync_revision)
                    VALUES (?, ?, ?) ON CONFLICT(memory_id) DO UPDATE SET
                        deleted_at=excluded.deleted_at,
                        sync_revision=MAX(memory_tombstones.sync_revision, excluded.sync_revision)
                    """, arguments: [oldID, deletedAt, replacementRevision])
            }
        }
        try db.execute(sql: """
            INSERT INTO memory_entries (
                id, scope, workspace_id, conversation_id, status, content, normalized_content,
                confidence, importance, is_pinned, source_kind, expires_at,
                origin_conversation_id, origin_workspace_id, subject_key, attribute_key,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, content=excluded.content,
                normalized_content=excluded.normalized_content, confidence=excluded.confidence,
                importance=excluded.importance, is_pinned=excluded.is_pinned,
                expires_at=excluded.expires_at,
                subject_key=excluded.subject_key, attribute_key=excluded.attribute_key,
                origin_conversation_id=COALESCE(memory_entries.origin_conversation_id, excluded.origin_conversation_id),
                origin_workspace_id=COALESCE(memory_entries.origin_workspace_id, excluded.origin_workspace_id),
                updated_at=excluded.updated_at
            """, arguments: [entry.id.uuidString, scope, workspaceID?.uuidString,
                conversationID?.uuidString,
                entry.status.rawValue, entry.content, normalized, entry.confidence,
                entry.importance, entry.isPinned, entry.sourceKind.rawValue,
                entry.expiresAt.map(Self.date), entry.originConversationID?.uuidString,
                entry.originWorkspaceID?.uuidString, entry.factIdentity?.subjectKey,
                entry.factIdentity?.attributeKey, Self.date(entry.createdAt), Self.date(entry.updatedAt)])
        try db.execute(sql: "DELETE FROM memory_evidence WHERE memory_id = ?", arguments: [entry.id.uuidString])
        for reference in evidence {
            try db.execute(sql: """
                INSERT INTO memory_evidence (
                    id, memory_id, conversation_id, message_id, excerpt_digest, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [reference.id.uuidString, entry.id.uuidString,
                    entry.originConversationID?.uuidString, reference.messageID?.uuidString,
                    Self.stableDigest(reference.excerpt), Self.date(entry.updatedAt)])
        }
    }

    public func memory(id: UUID) async throws -> MemoryEntry? {
        try await database.reader { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memory_entries WHERE id = ?", arguments: [id.uuidString])
                .map(Self.memory)
        }
    }

    public func listMemories(_ request: MemoryListRequest) async throws -> MemoryListPage {
        guard let offset = Int(request.cursor ?? "0"), offset >= 0 else {
            throw FloeError.validationFailed("memory.list cursor is invalid")
        }
        return try await database.reader { db in
            var filters: [String] = []
            var arguments = StatementArguments()
            if let scope = request.scope {
                let (scopeName, workspaceID, conversationID) = Self.scope(scope)
                filters.append("scope = ?")
                arguments += [scopeName]
                if let workspaceID {
                    filters.append("(workspace_id = ? OR origin_workspace_id = ?)")
                    arguments += [workspaceID.uuidString, workspaceID.uuidString]
                }
                if let conversationID {
                    filters.append("(conversation_id = ? OR origin_conversation_id = ?)")
                    arguments += [conversationID.uuidString, conversationID.uuidString]
                }
            }
            if let status = request.status {
                filters.append("status = ?")
                arguments += [status.rawValue]
            }
            if let conversationID = request.originConversationID {
                filters.append("origin_conversation_id = ?")
                arguments += [conversationID.uuidString]
            }
            if let workspaceID = request.originWorkspaceID {
                filters.append("origin_workspace_id = ?")
                arguments += [workspaceID.uuidString]
            }
            if let fact = request.factIdentity {
                filters.append("subject_key = ? AND attribute_key = ?")
                arguments += [fact.subjectKey, fact.attributeKey]
            }
            if let isPinned = request.isPinned {
                filters.append("is_pinned = ?")
                arguments += [isPinned]
            }
            let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
            arguments += [request.limit + 1, offset]
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries
                \(whereClause)
                ORDER BY is_pinned DESC, importance DESC, updated_at DESC, id
                LIMIT ? OFFSET ?
                """, arguments: arguments)
            let hasMore = rows.count > request.limit
            let entries = try rows.prefix(request.limit).map(Self.memory)
            return MemoryListPage(
                entries: entries,
                nextCursor: hasMore ? String(offset + request.limit) : nil
            )
        }
    }

    public func memories(factIdentity: MemoryFactIdentity, scope: MemoryScope? = nil) async throws -> [MemoryEntry] {
        try await database.reader { db in
            var sql = "SELECT * FROM memory_entries WHERE subject_key = ? AND attribute_key = ?"
            var arguments: StatementArguments = [factIdentity.subjectKey, factIdentity.attributeKey]
            if let scope {
                let (scopeName, workspaceID, conversationID) = Self.scope(scope)
                sql += " AND scope = ? AND (workspace_id IS ? OR origin_workspace_id IS ?)"
                sql += " AND (conversation_id IS ? OR origin_conversation_id IS ?)"
                arguments += [scopeName, workspaceID?.uuidString, workspaceID?.uuidString,
                              conversationID?.uuidString, conversationID?.uuidString]
            }
            sql += " ORDER BY updated_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.memory)
        }
    }

    public func organizationPreview(limit: Int = 10_000) async throws -> MemoryOrganizationProposal {
        let entries = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries ORDER BY updated_at DESC LIMIT ?
                """, arguments: [min(10_000, max(1, limit))]).map(Self.memory)
        }
        var suggestions: [MemoryOrganizationSuggestion] = []
        let exactGroups = Dictionary(grouping: entries) {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for group in exactGroups.values where group.count > 1 {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .exactDuplicate,
                memoryIDs: ordered.map(\.id),
                preferredMemoryID: ordered.first?.id,
                reason: FloeL10n.l("runtime.intelligence_store.the_content_is_identical_cross_scope"),
                canApplyAutomatically: Set(ordered.map(\.scope)).count == 1
            ))
        }
        let factGroups = Dictionary(grouping: entries.filter { $0.factIdentity != nil }) {
            $0.factIdentity!
        }
        for group in factGroups.values where group.count > 1 {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            let staysWithinOneScope = Set(ordered.map(\.scope)).count == 1
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .sameFactReplacement,
                memoryIDs: ordered.map(\.id),
                preferredMemoryID: ordered.first?.id,
                reason: staysWithinOneScope
                    ? FloeL10n.l("runtime.intelligence_store.a_fact_slot_in_the_same")
                    : FloeL10n.l("runtime.intelligence_store.the_same_fact_slot_has_different"),
                canApplyAutomatically: staysWithinOneScope
            ))
        }
        for entry in entries where entry.expiresAt.map({ $0 <= Date() }) == true {
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .expired, memoryIDs: [entry.id], reason: FloeL10n.l("runtime.intelligence_store.the_memory_has_passed_its_validity"),
                canApplyAutomatically: false
            ))
        }
        let referencedIDs = Set(suggestions.flatMap(\.memoryIDs))
        return MemoryOrganizationProposal(
            scannedCount: entries.count,
            suggestions: suggestions,
            entries: entries.filter { referencedIDs.contains($0.id) }
                .map(MemoryOrganizationEntrySummary.init)
        )
    }

    public func applyMaintenanceBatch(_ batch: MemoryMaintenanceBatch) async throws -> MemoryMaintenanceBatchResult {
        try await database.writer { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_maintenance_batches WHERE id = ?)", arguments: [batch.id.uuidString]) == true {
                return MemoryMaintenanceBatchResult(
                    batchID: batch.id, appliedCount: 0, deletedCount: 0,
                    replacedCount: 0, wasAlreadyApplied: true
                )
            }
            var addressedIDs = Set<UUID>()
            for operation in batch.operations {
                let memoryID: UUID
                switch operation {
                case .delete(let id): memoryID = id
                case .replace(let id, let entry):
                    guard id == entry.id else {
                        throw FloeError.validationFailed("Replacement must preserve the memory ID")
                    }
                    memoryID = id
                }
                guard addressedIDs.insert(memoryID).inserted else {
                    throw FloeError.validationFailed("A maintenance batch cannot modify the same memory twice")
                }
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM memory_entries WHERE id = ?)",
                    arguments: [memoryID.uuidString]
                ) ?? false
                guard exists else {
                    throw FloeError.validationFailed("Memory \(memoryID.uuidString) no longer exists")
                }
            }
            var deleted = 0
            var replaced = 0
            let deletedAt = Self.date(Date())
            for operation in batch.operations {
                switch operation {
                case .delete(let memoryID):
                    try Self.deleteMemory(memoryID, revision: batch.syncRevision, deletedAt: deletedAt, db: db)
                    deleted += 1
                case .replace(let memoryID, let entry):
                    let normalized = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !normalized.isEmpty, !Self.looksLikeSecret(normalized) else {
                        throw FloeError.validationFailed("Replacement memory is empty or contains authentication material")
                    }
                    try db.execute(sql: """
                        UPDATE memory_entries SET content = ?, normalized_content = ?, status = ?,
                            confidence = ?, importance = ?, is_pinned = ?, expires_at = ?,
                            subject_key = ?, attribute_key = ?, updated_at = ? WHERE id = ?
                        """, arguments: [entry.content, normalized, entry.status.rawValue,
                            entry.confidence, entry.importance, entry.isPinned,
                            entry.expiresAt.map(Self.date), entry.factIdentity?.subjectKey,
                            entry.factIdentity?.attributeKey, Self.date(entry.updatedAt), memoryID.uuidString])
                    guard db.changesCount == 1 else {
                        throw FloeError.validationFailed("Memory \(memoryID.uuidString) no longer exists")
                    }
                    replaced += 1
                }
            }
            try db.execute(sql: """
                INSERT INTO memory_maintenance_batches (
                    id, operation_count, deleted_count, replaced_count, sync_revision, applied_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [batch.id.uuidString, batch.operations.count, deleted, replaced,
                    batch.syncRevision, Self.date(Date())])
            return MemoryMaintenanceBatchResult(
                batchID: batch.id, appliedCount: batch.operations.count,
                deletedCount: deleted, replacedCount: replaced
            )
        }
    }

    public func memories(scope: MemoryScope, status: MemoryEntryStatus? = nil) async throws -> [MemoryEntry] {
        let (scopeName, workspaceID, conversationID) = Self.scope(scope)
        return try await database.reader { db in
            var sql = """
                SELECT * FROM memory_entries
                WHERE scope = ?
                  AND (workspace_id IS ? OR origin_workspace_id IS ?)
                  AND (conversation_id IS ? OR origin_conversation_id IS ?)
                """
            var arguments: StatementArguments = [
                scopeName,
                workspaceID?.uuidString, workspaceID?.uuidString,
                conversationID?.uuidString, conversationID?.uuidString
            ]
            if let status { sql += " AND status = ?"; arguments += [status.rawValue] }
            sql += " ORDER BY is_pinned DESC, importance DESC, updated_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.memory)
        }
    }

    /// Detaches task-scoped memories before the conversation FK cascade while
    /// retaining their original owner. They remain searchable, then age only
    /// after their owner has actually been deleted.
    public func preserveMemoriesBeforeConversationDeletion(
        conversationID: UUID,
        ownerLabel: String,
        now: Date = Date()
    ) async throws {
        let deletedAt = Self.date(now)
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE memory_entries SET
                    origin_conversation_id = COALESCE(origin_conversation_id, conversation_id),
                    origin_owner_label = COALESCE(origin_owner_label, ?),
                    owner_deleted_at = COALESCE(owner_deleted_at, ?),
                    conversation_id = NULL,
                    retained_until = COALESCE(retained_until, ?)
                WHERE conversation_id = ? OR (conversation_id IS NULL
                    AND origin_conversation_id = ? AND scope IN ('task', 'user', 'agent'))
                """, arguments: [String(ownerLabel.prefix(120)), deletedAt,
                    Self.date(now.addingTimeInterval(MemoryForgettingPolicy.recallRetention)),
                    conversationID.uuidString, conversationID.uuidString])
        }
    }

    /// Workspace records have ON DELETE CASCADE in the published schema.
    /// Detach memory first so deleting a project/private workspace preserves
    /// ownership history instead of silently erasing durable memory.
    public func preserveMemoriesBeforeWorkspaceDeletion(
        workspaceID: UUID,
        ownerLabel: String,
        now: Date = Date()
    ) async throws {
        let deletedAt = Self.date(now)
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE memory_entries SET
                    origin_workspace_id = COALESCE(origin_workspace_id, workspace_id),
                    origin_owner_label = COALESCE(origin_owner_label, ?),
                    owner_deleted_at = COALESCE(owner_deleted_at, ?),
                    workspace_id = NULL,
                    retained_until = COALESCE(retained_until, ?)
                WHERE workspace_id = ? OR (workspace_id IS NULL
                    AND origin_workspace_id = ? AND conversation_id IS NULL)
                """, arguments: [String(ownerLabel.prefix(120)), deletedAt,
                    Self.date(now.addingTimeInterval(MemoryForgettingPolicy.recallRetention)),
                    workspaceID.uuidString, workspaceID.uuidString])
        }
    }

    public func recall(
        query: String,
        workspaceID: UUID?,
        conversationID: UUID? = nil,
        limit: Int = 6
    ) async throws -> [MemoryRecallItem] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        try await maintainMemoryLifecycle()
        let recalled: [MemoryRecallItem] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT m.*, bm25(memory_fts) AS rank
                FROM memory_fts JOIN memory_entries m ON m.rowid = memory_fts.rowid
                WHERE memory_fts MATCH ? AND m.status = 'active'
                  AND (
                    m.scope IN ('user', 'agent', 'task', 'workspace')
                    OR m.workspace_id = ?
                    OR m.origin_workspace_id = ?
                  )
                  AND (m.expires_at IS NULL OR m.expires_at > ?)
                ORDER BY m.is_pinned DESC,
                    CASE WHEN m.conversation_id = ? THEN 0
                         WHEN m.owner_deleted_at IS NULL THEN 1 ELSE 2 END,
                    rank, m.importance DESC LIMIT ?
                """, arguments: [
                    match, workspaceID?.uuidString, workspaceID?.uuidString,
                    Self.date(Date()),
                    conversationID?.uuidString, min(20, max(1, limit))
                ])
                .compactMap { row -> MemoryRecallItem? in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    let rank: Double = row["rank"]
                    return MemoryRecallItem(id: id, content: row["content"], relevance: 1 / (1 + abs(rank)))
                }
        }
        try await reinforceMemories(recalled.map(\.id))
        return recalled
    }

    public func saveEmbedding(_ embedding: MemoryEmbedding) async throws {
        guard embedding.isValid else {
            throw FloeError.validationFailed("Embedding must contain finite values with a supported dimension")
        }
        guard !embedding.modelIdentifier.isEmpty, !embedding.modelRevision.isEmpty,
              !embedding.contentDigest.isEmpty else {
            throw FloeError.validationFailed("Embedding identity and content digest are required")
        }
        var values = embedding.values
        let blob = values.withUnsafeMutableBytes { Data($0) }
        try await database.writer { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_entries WHERE id = ?)",
                arguments: [embedding.memoryID.uuidString]) ?? false
            guard exists else { throw FloeError.validationFailed("Embedding memory entry does not exist") }
            try db.execute(sql: """
                INSERT INTO memory_embeddings (
                    memory_id, modality, model_identifier, model_revision,
                    dimensions, vector_blob, content_digest, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(memory_id, modality, model_identifier, model_revision)
                DO UPDATE SET dimensions=excluded.dimensions,
                    vector_blob=excluded.vector_blob,
                    content_digest=excluded.content_digest,
                    created_at=excluded.created_at
                """, arguments: [embedding.memoryID.uuidString, embedding.modality.rawValue,
                    embedding.modelIdentifier, embedding.modelRevision, embedding.values.count,
                    blob, embedding.contentDigest, Self.date(embedding.createdAt)])
        }
    }

    public func embeddingNeedsRefresh(
        memoryID: UUID,
        modality: MemoryEmbeddingModality,
        modelIdentifier: String,
        modelRevision: String,
        contentDigest: String
    ) async throws -> Bool {
        try await database.reader { db in
            let stored: String? = try String.fetchOne(db, sql: """
                SELECT content_digest FROM memory_embeddings
                WHERE memory_id = ? AND modality = ? AND model_identifier = ?
                  AND model_revision = ?
                """, arguments: [memoryID.uuidString, modality.rawValue,
                    modelIdentifier, modelRevision])
            return stored != contentDigest
        }
    }

    public func hybridRecall(_ request: HybridMemoryRecallRequest) async throws
        -> [HybridMemoryRecallItem] {
        try await hybridRecall(request, now: Date())
    }

    public func hybridRecall(_ request: HybridMemoryRecallRequest, now: Date) async throws
        -> [HybridMemoryRecallItem] {
        try await findMemories(request, reinforcing: true, now: now)
    }

    /// Opening or searching the memory library is observation, not model use.
    public func browseMemories(_ request: HybridMemoryRecallRequest, now: Date = Date()) async throws
        -> [HybridMemoryRecallItem] {
        try await findMemories(request, reinforcing: false, now: now)
    }

    /// Revalidates the exact bounded prompt projection, not a stale list
    /// snapshot. Ownership and real-use reinforcement commit together. A
    /// finished owner cannot resurrect a deleted/archived memory or renew use.
    public func retainRuntimeMemories(
        _ ids: [UUID], useLease: MemoryRunUseLease,
        alreadyRecalled: Set<UUID> = [], now: Date = Date()
    ) async throws -> [MemoryRecallItem] {
        try await maintainMemoryLifecycle(now: now)
        var seen = Set<UUID>()
        let selected = ids.prefix(20).filter { seen.insert($0).inserted }
        return try await database.writer { db in
            let entries = try selected.compactMap { id -> MemoryEntry? in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_entries WHERE id=? AND status='active'
                        AND (expires_at IS NULL OR julianday(expires_at)>julianday(?))
                    """, arguments: [id.uuidString, Self.date(now)]) else { return nil }
                return try Self.memory(row)
            }
            return try useLease.withUse(entries.map(\.id)) {
                for entry in entries where !alreadyRecalled.contains(entry.id) {
                    try db.execute(sql: """
                        UPDATE memory_entries SET last_recalled_at=?,retained_until=?,
                            recall_count=recall_count+1,importance=MIN(1.0,importance+0.05)
                        WHERE id=?
                        """, arguments: [Self.date(now), Self.date(now.addingTimeInterval(MemoryForgettingPolicy.recallRetention)), entry.id.uuidString])
                }
                return entries.map { MemoryRecallItem(id: $0.id, content: $0.content, relevance: 1) }
            } ?? []
        }
    }

    private func findMemories(_ request: HybridMemoryRecallRequest, reinforcing: Bool, now: Date) async throws
        -> [HybridMemoryRecallItem] {
        try await maintainMemoryLifecycle(now: now)
        let lexicalMatch = Self.ftsQuery(request.query)
        let lexicalRows: [HybridRecallDatabaseRow]
        if lexicalMatch.isEmpty {
            lexicalRows = []
        } else {
            lexicalRows = try await database.reader { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.*, (\(Self.deletedMemoryOwnerPredicate)) AS owner_is_deleted
                    FROM memory_fts JOIN memory_entries m ON m.rowid = memory_fts.rowid
                    WHERE memory_fts MATCH ? AND m.status = 'active'
                      AND (m.scope IN ('user', 'agent', 'task', 'workspace')
                           OR m.workspace_id = ? OR m.origin_workspace_id = ?)
                      AND (m.expires_at IS NULL OR m.expires_at > ?)
                    ORDER BY CASE WHEN m.conversation_id = ? THEN 0
                                  WHEN m.owner_deleted_at IS NULL THEN 1 ELSE 2 END,
                             bm25(memory_fts), m.is_pinned DESC, m.importance DESC, m.id
                    LIMIT 50
                    """, arguments: [lexicalMatch, request.workspaceID?.uuidString,
                        request.workspaceID?.uuidString, Self.date(now),
                        request.conversationID?.uuidString])
                    .compactMap { Self.hybridRow($0, now: now) }
            }
        }

        var semanticRows: [(HybridRecallDatabaseRow, Double)] = []
        if let queryVector = request.queryEmbedding,
           !queryVector.isEmpty, queryVector.count <= 4_096,
           queryVector.allSatisfy(\.isFinite),
           let modelIdentifier = request.modelIdentifier,
           let modelRevision = request.modelRevision {
            let rows: [(HybridRecallDatabaseRow, Data, Int)] = try await database.reader { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.*, (\(Self.deletedMemoryOwnerPredicate)) AS owner_is_deleted,
                           e.vector_blob, e.dimensions
                    FROM memory_embeddings e
                    JOIN memory_entries m ON m.id = e.memory_id
                    WHERE e.modality = ? AND e.model_identifier = ?
                      AND e.model_revision = ? AND e.dimensions = ?
                      AND m.status = 'active'
                      AND (m.scope IN ('user', 'agent', 'task', 'workspace')
                           OR m.workspace_id = ? OR m.origin_workspace_id = ?)
                      AND (m.expires_at IS NULL OR m.expires_at > ?)
                    LIMIT 2000
                    """, arguments: [request.modality.rawValue, modelIdentifier, modelRevision,
                        queryVector.count, request.workspaceID?.uuidString,
                        request.workspaceID?.uuidString, Self.date(now)])
                    .compactMap { row in
                        guard let candidate = Self.hybridRow(row, now: now) else { return nil }
                        let blob: Data = row["vector_blob"]
                        let dimensions: Int = row["dimensions"]
                        return (candidate, blob, dimensions)
                    }
            }
            semanticRows = rows.compactMap { row, blob, dimensions in
                guard let values = Self.floatValues(blob, dimensions: dimensions),
                      let similarity = MemoryVectorMath.cosineSimilarity(queryVector, values),
                      similarity > 0 else { return nil }
                return (row, similarity)
            }.sorted { $0.1 > $1.1 }
        }

        var fused: [UUID: MemoryReciprocalRankFusion.Candidate] = [:]
        for (offset, row) in lexicalRows.enumerated() {
            fused[row.id] = MemoryReciprocalRankFusion.Candidate(id: row.id,
                content: row.content, lexicalRank: offset + 1, importance: row.importance,
                isPinned: row.isPinned, updatedAt: row.updatedAt)
        }
        for (offset, pair) in semanticRows.enumerated() {
            let (row, similarity) = pair
            var candidate = fused[row.id] ?? MemoryReciprocalRankFusion.Candidate(id: row.id,
                content: row.content, importance: row.importance, isPinned: row.isPinned,
                updatedAt: row.updatedAt)
            candidate.semanticRank = offset + 1
            candidate.semanticSimilarity = similarity
            fused[row.id] = candidate
        }
        let results = MemoryReciprocalRankFusion.fuse(Array(fused.values), limit: request.limit, now: now)
        if reinforcing { try await reinforceMemories(results.map(\.id), now: now) }
        return results
    }

    /// Recall temporarily strengthens orphaned memories. Active task and
    /// workspace memories are intentionally unlimited and never enter this
    /// aging path; only memories whose owner was deleted are compacted.
    private func reinforceMemories(_ ids: [UUID], now: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var mutableArguments = StatementArguments([
            Self.date(now), Self.date(now.addingTimeInterval(MemoryForgettingPolicy.recallRetention))
        ])
        for id in ids {
            mutableArguments += [id.uuidString]
        }
        let arguments = mutableArguments
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE memory_entries SET
                    last_recalled_at = ?, retained_until = ?,
                    recall_count = recall_count + 1,
                    importance = MIN(1.0, importance + 0.05)
                WHERE id IN (\(placeholders))
                """, arguments: arguments)
        }
    }

    /// A missing origin is positive evidence of a deleted owner, including old
    /// global memories that the former FK-only preservation hook missed.
    private static var deletedMemoryOwnerPredicate: String { MemoryForgettingPolicy.deletedOwnerSQL }

    /// Archive is reversible: this lifecycle never deletes memory text. A
    /// real run lease, a manual pin or a lasting preference prevents aging.
    public func maintainMemoryLifecycle(now: Date = Date()) async throws {
        let nowText = Self.date(now)
        let usage = memoryUseRegistry
        try await database.writer { db in
            // Do not stamp a fresh "use" while repairing an older orphan.
            // Its latest real write/recall is the conservative known anchor.
            try db.execute(sql: """
                UPDATE memory_entries AS m
                SET owner_deleted_at = CASE
                    WHEN julianday(last_recalled_at) > julianday(updated_at) THEN last_recalled_at
                    ELSE COALESCE(updated_at, created_at) END
                WHERE owner_deleted_at IS NULL AND (\(Self.deletedMemoryOwnerPredicate))
                """)
            try usage.withProtectedIDs { protected in
                // One JSON value avoids SQLite's variable limit without
                // loading every orphan's text into memory during a UI read.
                let protectedJSON = String(decoding: try JSONEncoder().encode(protected.map(\.uuidString)), as: UTF8.self)
                let eligible = """
                    m.is_pinned = 0 AND (m.scope <> 'user' OR m.expires_at IS NOT NULL)
                    AND NOT(m.scope = 'agent' AND m.source_kind = 'explicitUserRequest' AND m.expires_at IS NULL)
                    AND NOT EXISTS(SELECT 1 FROM json_each(?) p WHERE p.value = m.id)
                    """
                try db.execute(sql: """
                    UPDATE memory_entries AS m SET status = 'superseded'
                    WHERE m.status = 'active' AND (\(eligible)) AND (
                        (m.expires_at IS NOT NULL AND julianday(m.expires_at) <= julianday(?))
                        OR (m.owner_deleted_at IS NOT NULL AND (\(Self.deletedMemoryOwnerPredicate))
                            AND MAX(julianday(m.owner_deleted_at), COALESCE(julianday(m.last_recalled_at),0)) <= julianday(?)
                            AND (m.retained_until IS NULL OR julianday(m.retained_until) <= julianday(?))))
                    """, arguments: [protectedJSON, nowText,
                        Self.date(now.addingTimeInterval(-MemoryForgettingPolicy.archiveAfter)), nowText])
                try db.execute(sql: """
                    DELETE FROM memory_embeddings WHERE memory_id IN (
                        SELECT m.id FROM memory_entries m WHERE (\(eligible))
                            AND ((m.owner_deleted_at IS NOT NULL AND (\(Self.deletedMemoryOwnerPredicate)))
                                OR (m.expires_at IS NOT NULL AND julianday(m.expires_at) <= julianday(?)))
                            AND MAX(julianday(COALESCE(m.owner_deleted_at,m.expires_at)),
                                COALESCE(julianday(m.last_recalled_at),0)) <= julianday(?)
                            AND (m.retained_until IS NULL OR julianday(m.retained_until) <= julianday(?)))
                    """, arguments: [protectedJSON, nowText,
                        Self.date(now.addingTimeInterval(-MemoryForgettingPolicy.releaseVectorsAfter)), nowText])
            }
        }
    }

    public func deleteMemory(id: UUID, syncRevision: Int64) async throws {
        try await deleteMemories(ids: [id], syncRevision: syncRevision)
    }

    public func deleteMemories(ids: Set<UUID>, syncRevision: Int64) async throws {
        guard !ids.isEmpty else { return }
        let deletedAt = Self.date(Date())
        try await database.writer { db in
            for id in ids {
                try Self.deleteMemory(id, revision: syncRevision, deletedAt: deletedAt, db: db)
            }
        }
    }

    private static func deleteMemory(
        _ id: UUID,
        revision: Int64,
        deletedAt: String,
        db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM memory_entries WHERE id = ?", arguments: [id.uuidString])
        try db.execute(sql: """
            INSERT INTO memory_tombstones (memory_id, deleted_at, sync_revision)
            VALUES (?, ?, ?) ON CONFLICT(memory_id) DO UPDATE SET
            deleted_at=CASE
                WHEN excluded.sync_revision >= memory_tombstones.sync_revision THEN excluded.deleted_at
                ELSE memory_tombstones.deleted_at
            END,
            sync_revision=MAX(memory_tombstones.sync_revision, excluded.sync_revision)
            """, arguments: [id.uuidString, deletedAt, revision])
    }

    /// UI library search: one hit per conversation, with literal CJK/substring matching.
    /// Does not share the agent's paged message-result limit or expose non-searchable tasks.
    public func matchingConversationSnippets(_ query: String) async throws -> [UUID: String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [:] }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.conversation_id,
                    substr(m.content, max(1, instr(lower(m.content), lower(?)) - 45), 180) AS excerpt
                FROM messages m JOIN conversations c ON c.id=m.conversation_id
                WHERE c.is_searchable=1 AND c.purpose='ordinary' AND m.content LIKE ? ESCAPE '\\'
                GROUP BY m.conversation_id
                """, arguments: [value, "%\(escaped)%"])
            var matches: [UUID: String] = [:]
            for row in rows {
                if let id = UUID(uuidString: row["conversation_id"]) { matches[id] = row["excerpt"] }
            }
            return matches
        }
    }


    // MARK: - Typed library / in-chat search (query is a shared normalizer)

    /// Typed library search for the global search screen. Every body hit names
    /// the ACTUAL message it came from (so the UI can jump to it and highlight
    /// it); a conversation-title-only match keeps `messageID == nil` and is
    /// never given a fabricated body hit. The shared query normalizer applies
    /// the same whitespace-AND / quoted-phrase semantics as the in-chat find.
    /// Filters are the existing durable ones: `is_searchable = 1`,
    /// `purpose = 'ordinary'`, user/assistant message bodies only.
    ///
    /// Matching runs through the shared visible-text predicate registered on
    /// the SQLite connection. A raw `LIKE` prefilter is not a valid shortcut:
    /// it misses quoted phrases split by inline Markdown (`hello **world**`)
    /// and accent/width-folded text, and its raw/hidden hits consume the
    /// `LIMIT` before the visible projection can reject them. The predicate
    /// keeps the same bounded result count and exact message ids; the Swift
    /// re-check below is a final projection guard, not a second search.
    public func conversationSearchMatches(
        _ rawQuery: String,
        limit: Int = 40
    ) async throws -> [ConversationSearchMatch] {
        let query = ConversationSearchQuery(raw: rawQuery)
        guard !query.isEmpty else { return [] }
        let bounded = min(50, max(1, limit))
        return try await database.reader { db in
            try Task.checkCancellation()
            db.add(function: ConversationSearchQuery.visibleMatchFunction)
            var matches: [ConversationSearchMatch] = []
            var seenConversations: Set<UUID> = []
            var seenMessages: Set<UUID> = []
            // `CROSS JOIN` keeps the searchable-conversation scan outermost;
            // the normal plan filters Notes/non-searchable rows before the
            // per-message visible projection.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS message_id, m.conversation_id, m.role, m.content,
                       m.created_at, c.title
                FROM conversations c
                CROSS JOIN messages m ON m.conversation_id = c.id
                WHERE c.is_searchable = 1 AND c.purpose = 'ordinary'
                  AND m.role IN ('user', 'assistant')
                  AND floe_conversation_search_match(m.role, m.content, ?) = 1
                ORDER BY m.created_at DESC, m.id DESC
                LIMIT ?
                """, arguments: [rawQuery, bounded])
            for row in rows {
                guard matches.count < bounded,
                      let messageID = UUID(uuidString: row["message_id"]),
                      let conversationID = UUID(uuidString: row["conversation_id"]),
                      let role: String = row["role"],
                      let content: String = row["content"],
                      let createdAtRaw: String = row["created_at"],
                      seenMessages.insert(messageID).inserted else { continue }
                let visible = ConversationSearchText.visibleText(role: role, content: content)
                guard query.matches(visible) else { continue }
                matches.append(ConversationSearchMatch(
                    conversationID: conversationID,
                    conversationTitle: row["title"],
                    messageID: messageID,
                    role: role,
                    snippet: ConversationSearchText.snippet(in: visible, query: query),
                    createdAt: Self.parseDate(createdAtRaw)
                ))
                seenConversations.insert(conversationID)
            }
            guard matches.count < bounded else { return matches }
            // Title-only matches: conversations with no body hit above. The
            // row carries the title itself as its hit line and NO message id.
            // Titles are rendered as plain text, so no Markdown projection is
            // applied — but the same Unicode/case folding and term semantics.
            try Task.checkCancellation()
            let titleRows = try Row.fetchAll(db, sql: """
                SELECT c.id AS conversation_id, c.title, c.updated_at
                FROM conversations c
                WHERE c.is_searchable = 1 AND c.purpose = 'ordinary'
                  AND floe_conversation_search_match('title', c.title, ?) = 1
                ORDER BY c.updated_at DESC
                LIMIT ?
                """, arguments: [rawQuery, bounded])
            for row in titleRows {
                guard matches.count < bounded,
                      let conversationID = UUID(uuidString: row["conversation_id"]),
                      !seenConversations.contains(conversationID) else { continue }
                let title: String = row["title"]
                guard query.matches(title) else { continue }
                seenConversations.insert(conversationID)
                matches.append(ConversationSearchMatch(
                    conversationID: conversationID,
                    conversationTitle: title,
                    messageID: nil,
                    role: nil,
                    snippet: String(title.prefix(ConversationSearchText.maximumSnippetCharacters)),
                    createdAt: Self.parseDate(row["updated_at"])
                ))
            }
            return matches
        }
    }

    /// Message hits inside ONE conversation, chronological. Used by the
    /// in-chat find to address history that is not in the currently loaded
    /// page window; the UI still loads a bounded window around the selected
    /// hit and highlights the rendered visible text.
    ///
    /// The SQL predicate is the SAME visible-text matcher as the global
    /// search, so a phrase split by inline Markdown or an accent/width-folded
    /// term is found before `LIMIT` is applied. Hidden link targets and other
    /// raw matches never take a result slot.
    public func conversationMessageMatches(
        conversationID: UUID,
        rawQuery: String,
        limit: Int = 200
    ) async throws -> [ConversationMessageMatch] {
        let query = ConversationSearchQuery(raw: rawQuery)
        guard !query.isEmpty else { return [] }
        let bounded = min(200, max(1, limit))
        return try await database.reader { db in
            try Task.checkCancellation()
            db.add(function: ConversationSearchQuery.visibleMatchFunction)
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS message_id, m.role, m.content, m.created_at
                FROM conversations c
                CROSS JOIN messages m ON m.conversation_id = c.id
                WHERE c.id = ?
                  AND c.is_searchable = 1 AND c.purpose = 'ordinary'
                  AND m.role IN ('user', 'assistant')
                  AND floe_conversation_search_match(m.role, m.content, ?) = 1
                ORDER BY m.created_at ASC, m.id ASC
                LIMIT ?
                """, arguments: [conversationID.uuidString, rawQuery, bounded])
            var matches: [ConversationMessageMatch] = []
            for row in rows {
                guard matches.count < bounded,
                      let messageID = UUID(uuidString: row["message_id"]),
                      let role: String = row["role"],
                      let content: String = row["content"],
                      let createdAtRaw: String = row["created_at"] else { continue }
                let visible = ConversationSearchText.visibleText(role: role, content: content)
                guard query.matches(visible) else { continue }
                matches.append(ConversationMessageMatch(
                    conversationID: conversationID,
                    messageID: messageID,
                    role: role,
                    snippet: ConversationSearchText.snippet(in: visible, query: query),
                    createdAt: Self.parseDate(createdAtRaw)
                ))
            }
            return matches
        }
    }

    /// A bounded, chronological window containing one exact message plus a
    /// few of its neighbours. `before` older rows and `after` newer rows are
    /// returned, never the whole conversation. Parts (attachment chips) are
    /// hydrated so the merged rows render exactly like a page read.
    public func conversationMessageWindow(
        conversationID: UUID,
        around messageID: UUID,
        before: Int = 40,
        after: Int = 4
    ) async throws -> [PersistedMessage] {
        let olderLimit = min(200, max(1, before))
        let newerLimit = min(20, max(0, after))
        return try await database.reader { db in
            guard let target = try Row.fetchOne(db, sql: """
                SELECT created_at FROM messages
                WHERE id = ? AND conversation_id = ?
                """, arguments: [messageID.uuidString, conversationID.uuidString]),
                  let createdAtRaw: String = target["created_at"] else { return [] }
            let older = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE conversation_id = ?
                  AND (created_at < ? OR (created_at = ? AND id <= ?))
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """, arguments: [
                    conversationID.uuidString, createdAtRaw, createdAtRaw,
                    messageID.uuidString, olderLimit + 1
                ])
            let newer = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE conversation_id = ?
                  AND (created_at > ? OR (created_at = ? AND id > ?))
                ORDER BY created_at ASC, id ASC
                LIMIT ?
                """, arguments: [
                    conversationID.uuidString, createdAtRaw, createdAtRaw,
                    messageID.uuidString, newerLimit
                ])
            let rows = Array(older.reversed()) + newer
            var seen: Set<UUID> = []
            let ids: [UUID] = rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]), seen.insert(id).inserted else {
                    return nil
                }
                return id
            }
            let parts = try Self.messageParts(db: db, messageIDs: ids)
            return rows.compactMap { row -> PersistedMessage? in
                guard let id = UUID(uuidString: row["id"]),
                      let role: String = row["role"],
                      let content: String = row["content"],
                      let createdAtRaw: String = row["created_at"] else { return nil }
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: role,
                    content: content,
                    createdAt: Self.parseDate(createdAtRaw),
                    parts: parts[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }.sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
        }
    }

    private static func messageParts(
        db: Database,
        messageIDs: [UUID]
    ) throws -> [UUID: [MessagePart]] {
        guard !messageIDs.isEmpty else { return [:] }
        var result: [UUID: [MessagePart]] = [:]
        for chunkStart in stride(from: 0, to: messageIDs.count, by: 400) {
            let chunk = Array(messageIDs[chunkStart..<min(chunkStart + 400, messageIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM message_parts
                WHERE message_id IN (\(placeholders))
                ORDER BY message_id, part_index
                """, arguments: StatementArguments(chunk.map(\.uuidString)))
            for row in rows {
                guard let messageID = UUID(uuidString: row["message_id"]),
                      let id = UUID(uuidString: row["id"]),
                      let kind = MessagePart.Kind(rawValue: row["kind"]) else { continue }
                let createdAt = (row["created_at"] as String?).map(Self.parseDate) ?? Date()
                let metadata: [String: String]
                if let raw: String = row["metadata_json"],
                   let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                    metadata = decoded
                } else {
                    metadata = [:]
                }
                result[messageID, default: []].append(MessagePart(
                    id: id,
                    messageID: messageID,
                    partIndex: row["part_index"],
                    kind: kind,
                    text: row["text"],
                    attachmentID: (row["attachment_id"] as String?).flatMap(UUID.init(uuidString:)),
                    metadata: metadata,
                    createdAt: createdAt
                ))
            }
        }
        return result
    }

    public func search(_ request: ConversationSearchRequest) async throws -> [ConversationSearchHit] {
        let match = Self.ftsQuery(request.query)
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !match.isEmpty || !trimmed.isEmpty else { return [] }
        return try await database.reader { db in
            // bm25()/snippet() are FTS5 auxiliary functions that are only valid
            // while the FTS cursor is producing the row. Evaluating them in the
            // ORDER BY of an aggregating (GROUP BY) query runs after that cursor
            // context is gone and raises "unable to use function bm25 in the
            // requested context". They live in the inner query instead; the
            // `LIMIT -1` blocks SQLite subquery flattening, which would pull
            // them back into the aggregate and re-trigger the same error.
            var hits: [ConversationSearchHit] = []
            if !match.isEmpty {
                var innerFilters = ["message_fts MATCH ?"]
                var arguments: StatementArguments = [match]
                if let start = request.startDate { innerFilters.append("m.created_at >= ?"); arguments += [Self.date(start)] }
                if let end = request.endDate { innerFilters.append("m.created_at <= ?"); arguments += [Self.date(end)] }
                var outerFilters = ["c.is_searchable = 1", "c.purpose = 'ordinary'"]
                if let workspaceID = request.workspaceID {
                    outerFilters.append("wc.workspace_id = ?"); arguments += [workspaceID.uuidString]
                }
                arguments += [request.limit]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT f.message_id, f.conversation_id, f.created_at,
                           c.title, MIN(wc.workspace_id) AS workspace_id,
                           f.snippet, MIN(f.rank) AS best_rank
                    FROM (
                        SELECT m.id AS message_id, m.conversation_id, m.created_at,
                               bm25(message_fts) AS rank,
                               snippet(message_fts, 0, '[', ']', '…', 24) AS snippet
                        FROM message_fts
                        JOIN messages m ON m.rowid = message_fts.rowid
                        WHERE \(innerFilters.joined(separator: " AND "))
                        LIMIT -1
                    ) f
                    JOIN conversations c ON c.id = f.conversation_id
                    LEFT JOIN conversation_workspace_ownership wc ON wc.conversation_id = c.id
                    WHERE \(outerFilters.joined(separator: " AND "))
                    GROUP BY f.message_id
                    ORDER BY best_rank, f.created_at DESC LIMIT ?
                    """, arguments: arguments)
                hits = rows.compactMap(Self.searchHit)
            }
            // unicode61 tokenizes a CJK run as one token, so a Chinese
            // substring that is not a whole token can never MATCH. Titles are
            // not in the FTS table at all. Fill the remaining allowance with
            // literal, case-insensitive substring matches (content first,
            // then titles), one per conversation the FTS pass did not hit.
            if hits.count < request.limit, !trimmed.isEmpty {
                let excluded = Set(hits.map(\.conversationID))
                hits.append(contentsOf: try Self.substringHits(
                    db: db,
                    request: request,
                    query: trimmed,
                    excluding: excluded
                ))
            }
            return Array(hits.prefix(request.limit))
        }
    }

    /// Agent discovery listing: recent searchable ordinary tasks, newest
    /// activity first. Separate from FTS so a query-free "what was I working
    /// on" never depends on tokenizer behavior.
    public func list(_ request: ConversationListRequest) async throws -> [ConversationListEntry] {
        try await database.reader { db in
            var filters = ["c.is_searchable = 1", "c.purpose = 'ordinary'"]
            var arguments: StatementArguments = []
            if let workspaceID = request.workspaceID {
                filters.append("wc.workspace_id = ?"); arguments += [workspaceID.uuidString]
            }
            arguments += [request.limit]
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS conversation_id, c.title, c.updated_at,
                       MIN(wc.workspace_id) AS workspace_id
                FROM conversations c
                LEFT JOIN conversation_workspace_ownership wc ON wc.conversation_id = c.id
                WHERE \(filters.joined(separator: " AND "))
                GROUP BY c.id
                ORDER BY c.updated_at DESC LIMIT ?
                """, arguments: arguments)
            return rows.compactMap { row -> ConversationListEntry? in
                guard let id = UUID(uuidString: row["conversation_id"]) else { return nil }
                return ConversationListEntry(
                    conversationID: id,
                    workspaceID: (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:)),
                    title: row["title"],
                    updatedAt: Self.parseDate(row["updated_at"])
                )
            }
        }
    }

    public func read(_ request: ConversationPageRequest) async throws -> ConversationHistoryPage {
        let keysetCursor = try request.cursor.flatMap(Self.decodeTimelineCursor)
        let legacyOffset: Int?
        if let raw = request.cursor, !raw.hasPrefix("k1.") {
            guard let value = Int(raw), value >= 0 else {
                throw FloeError.validationFailed("conversation.read cursor is invalid")
            }
            legacyOffset = value
        } else {
            legacyOffset = nil
        }
        return try await database.reader { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ? AND purpose = 'ordinary')",
                arguments: [request.conversationID.uuidString]
            ) == true else {
                throw FloeError.validationFailed("The requested task is unavailable to conversation history tools")
            }
            let timeline = """
                WITH timeline AS (
                    SELECT m.id AS item_id, m.run_id AS run_id, 'message' AS item_kind,
                           m.role AS role, m.content AS content, m.created_at AS created_at,
                           NULL AS sequence, -1 AS sort_sequence
                    FROM messages m
                    WHERE m.conversation_id = ?
                    UNION ALL
                    SELECT e.id AS item_id, e.run_id AS run_id, e.kind AS item_kind,
                           NULL AS role, e.payload_json AS content, e.created_at AS created_at,
                           e.sequence AS sequence, e.sequence AS sort_sequence
                    FROM run_events e
                    JOIN runs r ON r.id = e.run_id
                    WHERE r.conversation_id = ?
                )
                """
            let rows: [Row]
            if let cursor = keysetCursor {
                if cursor.contentOffset > 0, request.byteBudget != nil {
                    // Intra-item continuation: include the cursor's own row so
                    // its unread content remainder starts this page.
                    rows = try Row.fetchAll(db, sql: timeline + """
                        SELECT item_id, run_id, item_kind, role, content, created_at,
                               sequence, sort_sequence
                        FROM timeline
                        WHERE created_at > ?
                           OR (created_at = ? AND sort_sequence > ?)
                           OR (created_at = ? AND sort_sequence = ? AND item_id >= ?)
                        ORDER BY created_at, sort_sequence, item_id
                        LIMIT ?
                        """, arguments: [
                            request.conversationID.uuidString,
                            request.conversationID.uuidString,
                            cursor.createdAt,
                            cursor.createdAt, cursor.sequence,
                            cursor.createdAt, cursor.sequence, cursor.itemID,
                            request.limit + 1
                        ])
                } else {
                    rows = try Row.fetchAll(db, sql: timeline + """
                        SELECT item_id, run_id, item_kind, role, content, created_at,
                               sequence, sort_sequence
                        FROM timeline
                        WHERE created_at > ?
                           OR (created_at = ? AND sort_sequence > ?)
                           OR (created_at = ? AND sort_sequence = ? AND item_id > ?)
                        ORDER BY created_at, sort_sequence, item_id
                        LIMIT ?
                        """, arguments: [
                            request.conversationID.uuidString,
                            request.conversationID.uuidString,
                            cursor.createdAt,
                            cursor.createdAt, cursor.sequence,
                            cursor.createdAt, cursor.sequence, cursor.itemID,
                            request.limit + 1
                        ])
                }
            } else {
                rows = try Row.fetchAll(db, sql: timeline + """
                    SELECT item_id, run_id, item_kind, role, content, created_at,
                           sequence, sort_sequence
                    FROM timeline
                    ORDER BY created_at, sort_sequence, item_id
                    LIMIT ? OFFSET ?
                    """, arguments: [
                        request.conversationID.uuidString,
                        request.conversationID.uuidString,
                        request.limit + 1,
                        legacyOffset ?? 0
                    ])
            }
            let hasExtraRow = rows.count > request.limit
            let selectedRows = Array(rows.prefix(request.limit))
            var items = try selectedRows.map(Self.historyItem)
            var nextCursor: String?
            if let byteBudget = request.byteBudget {
                // Budget-true page walk: the cursor is generated from the last
                // RETURNED row (whole item) or inside it (prefix segment), so
                // the next page resumes at the first undelivered byte instead
                // of skipping everything the budget dropped.
                let resumeOffset: Int = {
                    guard let cursor = keysetCursor, cursor.contentOffset > 0,
                          let first: String = selectedRows.first?["item_id"],
                          first == cursor.itemID else { return 0 }
                    return cursor.contentOffset
                }()
                let page = ConversationEnvelope.paginate(
                    items: items,
                    startContentByteOffset: resumeOffset,
                    limit: request.limit,
                    byteBudget: byteBudget,
                    hasMoreBeyond: hasExtraRow
                )
                items = page.delivered
                switch page.continuation {
                case .none:
                    nextCursor = nil
                case .afterDeliveredItems:
                    if let last = selectedRows.prefix(page.delivered.count).last {
                        nextCursor = try Self.encodeTimelineCursor(ConversationTimelineCursor(
                            createdAt: last["created_at"],
                            sequence: last["sort_sequence"],
                            itemID: last["item_id"]
                        ))
                    }
                case .insideDeliveredItem(let byteOffset):
                    if let last = selectedRows.prefix(page.delivered.count).last {
                        nextCursor = try Self.encodeTimelineCursor(ConversationTimelineCursor(
                            createdAt: last["created_at"],
                            sequence: last["sort_sequence"],
                            itemID: last["item_id"],
                            contentOffset: byteOffset
                        ))
                    }
                }
            } else {
                nextCursor = if hasExtraRow, let last = selectedRows.last {
                    try Self.encodeTimelineCursor(ConversationTimelineCursor(
                        createdAt: last["created_at"],
                        sequence: last["sort_sequence"],
                        itemID: last["item_id"]
                    ))
                } else { nil }
            }
            return ConversationHistoryPage(
                conversationID: request.conversationID,
                items: items,
                nextCursor: nextCursor
            )
        }
    }

    private static func encodeTimelineCursor(
        _ cursor: ConversationTimelineCursor
    ) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        return "k1." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeTimelineCursor(
        _ raw: String
    ) throws -> ConversationTimelineCursor? {
        guard raw.hasPrefix("k1.") else { return nil }
        var encoded = String(raw.dropFirst(3))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let cursor = try? JSONDecoder().decode(
                  ConversationTimelineCursor.self, from: data
              ), !cursor.createdAt.isEmpty, !cursor.itemID.isEmpty else {
            throw FloeError.validationFailed("conversation.read cursor is invalid")
        }
        return cursor
    }

    public func readMessages(ids: [UUID]) async throws -> [ConversationHistoryMessage] {
        guard !ids.isEmpty else { return [] }
        return try await database.reader { db in
            try ids.compactMap { id in
                try Row.fetchOne(db, sql: "SELECT id, role, content, created_at FROM messages WHERE id = ?", arguments: [id.uuidString])
            }.map(Self.historyMessage)
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(value.utf8))
    }

    private static func plan(_ row: Row) throws -> PlanDraft {
        guard let id = UUID(uuidString: row["id"]), let conversationID = UUID(uuidString: row["conversation_id"]),
              let status = PlanStatus(rawValue: row["status"]) else { throw FloeError.storageCorrupted("Invalid plan row") }
        return try PlanDraft(id: id, conversationID: conversationID,
            workspaceID: (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:)), revision: row["revision"],
            status: status, title: row["title"], summary: row["summary"],
            sections: Self.decode([PlanSection].self, row["sections_json"]),
            assumptions: Self.decode([PlanAssumption].self, row["assumptions_json"]),
            risks: Self.decode([PlanRisk].self, row["risks_json"]),
            acceptanceCriteria: Self.decode([PlanCriterion].self, row["criteria_json"]),
            sourceMessageIDs: Self.decode([UUID].self, row["source_message_ids_json"]),
            sourceReferences: Self.decode([PlanSourceReference].self, row["source_conversation_refs_json"]),
            executionRecommendation: (row["execution_recommendation"] as String?)
                .flatMap(PlanExecutionRecommendation.init(rawValue:)),
            recommendationReason: row["recommendation_reason"],
            digest: row["digest"], createdAt: Self.parseDate(row["created_at"]), updatedAt: Self.parseDate(row["updated_at"]))
    }

    private static func goal(_ row: Row) throws -> ConversationGoal {
        guard let id = UUID(uuidString: row["id"]), let conversationID = UUID(uuidString: row["conversation_id"]),
              let status = GoalStatus(rawValue: row["status"]) else { throw FloeError.storageCorrupted("Invalid goal row") }
        return try ConversationGoal(id: id, conversationID: conversationID,
            sourcePlanID: (row["source_plan_id"] as String?).flatMap(UUID.init(uuidString:)), sourcePlanDigest: row["source_plan_digest"],
            objective: row["objective"],
            blockingConditions: Self.decode([String].self, row["blocking_conditions_json"]),
            stoppingConditions: Self.decode([String].self, row["stopping_conditions_json"]),
            revision: row["revision"],
            acceptanceCriteria: Self.decode([GoalCriterion].self, row["criteria_json"]),
            steps: Self.decode([GoalStep].self, row["steps_json"]), evidence: Self.decode([GoalEvidence].self, row["evidence_json"]),
            status: status, budgets: Self.decode(GoalBudgets.self, row["budgets_json"]), progress: Self.decode(GoalProgress.self, row["progress_json"]),
            createdAt: Self.parseDate(row["created_at"]), updatedAt: Self.parseDate(row["updated_at"]))
    }

    private static func memory(_ row: Row) throws -> MemoryEntry {
        guard let id = UUID(uuidString: row["id"]), let status = MemoryEntryStatus(rawValue: row["status"]),
              let source = MemoryCandidateOrigin(rawValue: row["source_kind"]) else { throw FloeError.storageCorrupted("Invalid memory row") }
        let scopeName: String = row["scope"]
        let workspace: String? = row["workspace_id"]
        let conversation: String? = row["conversation_id"]
        let originWorkspace: String? = row["origin_workspace_id"]
        let originConversation: String? = row["origin_conversation_id"]
        let scope: MemoryScope
        if scopeName == "workspace", let owner = workspace ?? originWorkspace,
           let id = UUID(uuidString: owner) {
            scope = .workspace(id)
        } else if scopeName == "task", let owner = conversation ?? originConversation,
                  let id = UUID(uuidString: owner) {
            scope = .task(id)
        } else {
            scope = scopeName == "user" ? .userProfile : .agentGlobal
        }
        let expires: String? = row["expires_at"]
        let subjectKey: String? = row["subject_key"]
        let attributeKey: String? = row["attribute_key"]
        let factIdentity = subjectKey.flatMap { subject in
            attributeKey.map { MemoryFactIdentity(subjectKey: subject, attributeKey: $0) }
        }
        return MemoryEntry(id: id, scope: scope, status: status, content: row["content"], confidence: row["confidence"],
            importance: row["importance"], isPinned: row["is_pinned"], sourceKind: source,
            originConversationID: originConversation.flatMap(UUID.init(uuidString:)),
            originWorkspaceID: originWorkspace.flatMap(UUID.init(uuidString:)),
            factIdentity: factIdentity,
            expiresAt: expires.map(Self.parseDate), createdAt: Self.parseDate(row["created_at"]), updatedAt: Self.parseDate(row["updated_at"]))
    }

    private static func scope(_ scope: MemoryScope) -> (String, UUID?, UUID?) {
        switch scope {
        case .userProfile: ("user", nil, nil)
        case .agentGlobal: ("agent", nil, nil)
        case .workspace(let id): ("workspace", id, nil)
        case .task(let id): ("task", nil, id)
        }
    }

    private static func searchHit(_ row: Row) -> ConversationSearchHit? {
        guard let conversationID = UUID(uuidString: row["conversation_id"]), let messageID = UUID(uuidString: row["message_id"]) else { return nil }
        return ConversationSearchHit(conversationID: conversationID, messageID: messageID,
            workspaceID: (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:)), conversationTitle: row["title"],
            snippet: row["snippet"], createdAt: parseDate(row["created_at"]))
    }

    private static func historyMessage(_ row: Row) throws -> ConversationHistoryMessage {
        guard let id = UUID(uuidString: row["id"]) else { throw FloeError.storageCorrupted("Invalid message row") }
        return ConversationHistoryMessage(id: id, role: row["role"], content: row["content"], createdAt: parseDate(row["created_at"]))
    }

    private static func historyItem(_ row: Row) throws -> ConversationHistoryItem {
        guard let id = UUID(uuidString: row["item_id"]),
              let kind = ConversationHistoryItemKind(rawValue: row["item_kind"])
        else { throw FloeError.storageCorrupted("Invalid conversation history item") }
        return ConversationHistoryItem(
            id: id,
            runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:)),
            kind: kind,
            role: row["role"],
            content: row["content"],
            createdAt: parseDate(row["created_at"]),
            sequence: row["sequence"]
        )
    }

    private static func hybridRow(_ row: Row, now: Date) -> HybridRecallDatabaseRow? {
        guard let entry = try? memory(row) else { return nil }
        var importance = entry.importance
        let deleted: String? = row["owner_deleted_at"]
        let recalled: String? = row["last_recalled_at"]
        let ownerIsDeleted: Bool = row["owner_is_deleted"]
        if ownerIsDeleted, let deleted,
           !MemoryForgettingPolicy.isLongTerm(entry) {
            let anchor = max(parseDate(deleted), recalled.map(parseDate) ?? .distantPast)
            importance *= MemoryForgettingPolicy.relevanceWeight(since: anchor, now: now)
        }
        return HybridRecallDatabaseRow(id: entry.id, content: entry.content,
            importance: importance, isPinned: entry.isPinned, updatedAt: entry.updatedAt)
    }

    private static func floatValues(_ data: Data, dimensions: Int) -> [Float]? {
        guard dimensions > 0, dimensions <= 4_096,
              data.count == dimensions * MemoryLayout<Float>.stride else { return nil }
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    private static func ftsQuery(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).prefix(16)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
    }

    /// Literal substring fallback for CJK and title matching. Each query
    /// carries exactly one aggregate (MAX created_at) so SQLite's bare-column
    /// rule pins the message id and snippet to the latest in-range row per
    /// conversation. Workspace ids are bulk-loaded afterwards to keep that
    /// rule intact. Same visibility, date and workspace filters as the FTS
    /// pass; conversations already returned by FTS are excluded in SQL so
    /// they cannot consume the LIMIT.
    private static func substringHits(
        db: Database,
        request: ConversationSearchRequest,
        query: String,
        excluding: Set<UUID>
    ) throws -> [ConversationSearchHit] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"
        let excludedIDs = excluding.map(\.uuidString).sorted()
        let exclusionClause = excludedIDs.isEmpty
            ? ""
            : " AND c.id NOT IN (\(excludedIDs.map { _ in "?" }.joined(separator: ",")))"
        let workspaceClause = request.workspaceID == nil
            ? ""
            : " AND EXISTS(SELECT 1 FROM conversation_workspace_ownership wc WHERE wc.conversation_id = c.id AND wc.workspace_id = ?)"

        // Content matches: latest in-range matching message per conversation.
        // instr() needs the raw query; LIKE needs the escaped %pattern%.
        var contentSQL = """
            SELECT m.id AS message_id, m.conversation_id, MAX(m.created_at) AS created_at,
                   c.title,
                   substr(m.content, max(1, instr(lower(m.content), lower(?)) - 45), 180) AS snippet
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE c.is_searchable = 1 AND c.purpose = 'ordinary'
              AND m.content LIKE ? ESCAPE '\\'
            """
        var contentArguments: StatementArguments = [query, like]
        if let workspaceID = request.workspaceID {
            contentSQL += workspaceClause
            contentArguments += [workspaceID.uuidString]
        }
        if let start = request.startDate {
            contentSQL += " AND m.created_at >= ?"
            contentArguments += [Self.date(start)]
        }
        if let end = request.endDate {
            contentSQL += " AND m.created_at <= ?"
            contentArguments += [Self.date(end)]
        }
        contentSQL += exclusionClause
        contentArguments += StatementArguments(excludedIDs)
        contentSQL += " GROUP BY m.conversation_id ORDER BY created_at DESC LIMIT ?"
        contentArguments += [request.limit]

        struct Partial {
            var conversationID: UUID
            var messageID: UUID
            var title: String
            var snippet: String
            var createdAt: Date
        }
        var partials: [Partial] = []
        var seen = excluding
        for row in try Row.fetchAll(db, sql: contentSQL, arguments: contentArguments) {
            guard let conversationID = UUID(uuidString: row["conversation_id"]),
                  let messageID = UUID(uuidString: row["message_id"]),
                  seen.insert(conversationID).inserted else { continue }
            partials.append(Partial(
                conversationID: conversationID,
                messageID: messageID,
                title: row["title"],
                snippet: row["snippet"],
                createdAt: parseDate(row["created_at"])
            ))
        }

        // Title-only matches, anchored to the latest in-range message.
        if partials.count < request.limit {
            var titleSQL = """
                SELECT c.id AS conversation_id, c.title, c.updated_at,
                       MAX(m.created_at) AS message_created_at, m.id AS message_id
                FROM conversations c
                JOIN messages m ON m.conversation_id = c.id
                WHERE c.is_searchable = 1 AND c.purpose = 'ordinary'
                  AND c.title LIKE ? ESCAPE '\\'
                """
            var titleArguments: StatementArguments = [like]
            if let workspaceID = request.workspaceID {
                titleSQL += workspaceClause
                titleArguments += [workspaceID.uuidString]
            }
            if let start = request.startDate {
                titleSQL += " AND m.created_at >= ?"
                titleArguments += [Self.date(start)]
            }
            if let end = request.endDate {
                titleSQL += " AND m.created_at <= ?"
                titleArguments += [Self.date(end)]
            }
            titleSQL += exclusionClause
            titleArguments += StatementArguments(excludedIDs)
            titleSQL += " GROUP BY c.id ORDER BY c.updated_at DESC LIMIT ?"
            titleArguments += [request.limit]
            for row in try Row.fetchAll(db, sql: titleSQL, arguments: titleArguments) {
                guard let conversationID = UUID(uuidString: row["conversation_id"]),
                      let messageID = UUID(uuidString: row["message_id"]),
                      seen.insert(conversationID).inserted else { continue }
                let title: String = row["title"]
                let createdAt: String = row["message_created_at"] ?? row["updated_at"]
                partials.append(Partial(
                    conversationID: conversationID,
                    messageID: messageID,
                    title: title,
                    snippet: "[title match] \(title)",
                    createdAt: parseDate(createdAt)
                ))
                if partials.count >= request.limit { break }
            }
        }

        let workspaces = try Self.workspaceIDs(db: db, conversationIDs: partials.map(\.conversationID))
        return partials.prefix(request.limit).map {
            ConversationSearchHit(
                conversationID: $0.conversationID,
                messageID: $0.messageID,
                workspaceID: workspaces[$0.conversationID],
                conversationTitle: $0.title,
                snippet: $0.snippet,
                createdAt: $0.createdAt
            )
        }
    }

    private static func workspaceIDs(db: Database, conversationIDs: [UUID]) throws -> [UUID: UUID] {
        guard !conversationIDs.isEmpty else { return [:] }
        let ids = conversationIDs.map(\.uuidString)
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversation_id, MIN(workspace_id) AS workspace_id
            FROM conversation_workspace_ownership
            WHERE conversation_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            GROUP BY conversation_id
            """, arguments: StatementArguments(ids))
        var output: [UUID: UUID] = [:]
        for row in rows {
            guard let conversationID = UUID(uuidString: row["conversation_id"]),
                  let workspace: String = row["workspace_id"],
                  let workspaceID = UUID(uuidString: workspace) else { continue }
            output[conversationID] = workspaceID
        }
        return output
    }

    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func parseDate(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
    private static func looksLikeSecret(_ value: String) -> Bool {
        [
            "api_key=", "apikey=", "authorization: bearer", "-----begin private key",
            "password:", "password=", "access_token", "refresh_token"
        ].contains { value.contains($0) }
    }
    private static func stableDigest(_ value: String) -> String {
        // Evidence text itself is intentionally not persisted here. This is
        // a stable non-secret identifier; cryptographic package digests live
        // in FloeSkills/FloeSecurity.
        String(value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
    }
}

private struct HybridRecallDatabaseRow: Sendable {
    var id: UUID
    var content: String
    var importance: Double
    var isPinned: Bool
    var updatedAt: Date
}

// MARK: - Shared search query / visible-text normalizer

/// The ONE query normalizer shared by the global search screen and the in-chat
/// find bar.
///
/// Semantics:
///  * whitespace separates terms; EVERY term must be present in the same
///    message (`AND`, any order);
///  * a double-quoted run (also curly quotes) is one literal phrase that may
///    contain spaces;
///  * matching is case/diacritic/width insensitive, so mixed Chinese/English
///    and full-width punctuation behave naturally;
///  * the empty/whitespace-only query has no terms and matches nothing.
///
/// The normalizer never produces SQL itself. Durable typed search uses
/// `visibleMatchFunction` so SQL filters with the same visible-text matcher;
/// `sqlPatterns()` remains for callers that can prove a raw-bytes prefilter is
/// a superset, and they must still re-verify with `matches(_:)` against the
/// VISIBLE text so a hit in Markdown syntax or a hidden link target is not
/// presented as a body match.
public struct ConversationSearchQuery: Sendable, Equatable {
    public enum Term: Sendable, Equatable, Hashable {
        case word(String)
        case phrase(String)

        public var text: String {
            switch self {
            case .word(let value), .phrase(let value): value
            }
        }
    }

    public static let maximumTerms = 8
    public static let maximumWordCharacters = 64
    public static let maximumPhraseCharacters = 128

    public let raw: String
    public let terms: [Term]

    public init(raw: String) {
        self.raw = raw
        var parsed: [Term] = []
        var buffer = ""
        var inPhrase = false

        func emit(_ value: String, phrase: Bool) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let bounded = String(
                text.prefix(phrase ? Self.maximumPhraseCharacters : Self.maximumWordCharacters))
            let normalized = bounded.lowercased()
            guard !parsed.contains(where: { $0.text.lowercased() == normalized }) else { return }
            parsed.append(phrase ? .phrase(bounded) : .word(bounded))
        }

        for character in raw {
            if character == "\"" || character == "“" || character == "”" {
                if inPhrase {
                    emit(buffer, phrase: true)
                    buffer = ""
                    inPhrase = false
                } else {
                    emit(buffer, phrase: false)
                    buffer = ""
                    inPhrase = true
                }
                continue
            }
            if !inPhrase, character.isWhitespace {
                emit(buffer, phrase: false)
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        emit(buffer, phrase: inPhrase)
        self.terms = Array(parsed.prefix(Self.maximumTerms))
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Human-readable terms used for the accessibility summary ("2 terms").
    public var displayTerms: [String] { terms.map(\.text) }

    /// SQL `LIKE` patterns (with `%` wrapping and `\`/`%`/`_` escaped). The
    /// caller must use `ESCAPE '\'`. Typed conversation search does NOT use
    /// these as a candidate prefilter: raw Markdown bytes are not a superset
    /// of the rendered text (see `visibleMatchFunction`).
    public func sqlPatterns() -> [String] {
        terms.map { "%" + Self.escapeLike($0.text) + "%" }
    }

    public static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Connection-local SQLite predicate implementing exactly `matches(_:)`
    /// over `ConversationSearchText`'s visible projection.
    ///
    /// Typed search must not prefilter raw Markdown bytes: a quoted phrase can
    /// be split by inline syntax (`hello **world**`), and SQLite `LIKE`
    /// cannot apply case/diacritic/width folding. The predicate therefore
    /// applies the same normalizer inside SQL, so `LIMIT` counts actual
    /// visible matches instead of raw/hidden candidates. The query text is an
    /// SQL argument, so callers never build SQL from user input.
    static let visibleMatchFunction = DatabaseFunction(
        "floe_conversation_search_match",
        argumentCount: 3,
        pure: true
    ) { values in
        guard let role = String.fromDatabaseValue(values[0]),
              let content = String.fromDatabaseValue(values[1]),
              let rawQuery = String.fromDatabaseValue(values[2]) else { return 0 }
        let query = ConversationSearchQuery(raw: rawQuery)
        guard !query.isEmpty else { return 0 }
        let visible = ConversationSearchText.visibleText(role: role, content: content)
        return query.matches(visible) ? 1 : 0
    }

    private static let compareOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    /// True when every term occurs in the supplied VISIBLE text. Uses a direct
    /// substring probe instead of collecting ranges: the store evaluates this
    /// for every candidate row and only needs the boolean.
    public func matches(_ text: String) -> Bool {
        terms.allSatisfy { term in
            !term.text.isEmpty
                && text.range(of: term.text, options: Self.compareOptions) != nil
        }
    }

    /// Character offsets (into `text`) of every term occurrence, merged and
    /// sorted. Offsets are for the SAME visible string the UI renders, never
    /// for Markdown source or a different display projection.
    public func ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        var found: [Range<Int>] = []
        for term in terms {
            for range in Self.occurrences(of: term.text, in: text) {
                let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                let upper = text.distance(from: text.startIndex, to: range.upperBound)
                guard upper > lower else { continue }
                found.append(lower..<upper)
            }
        }
        found.sort { lhs, rhs in
            lhs.lowerBound != rhs.lowerBound
                ? lhs.lowerBound < rhs.lowerBound
                : lhs.upperBound < rhs.upperBound
        }
        var merged: [Range<Int>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func occurrences(of term: String, in text: String) -> [Range<String.Index>] {
        guard !term.isEmpty, !text.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: term, options: Self.compareOptions, range: searchStart..<text.endIndex) {
            result.append(range)
            // Non-overlapping occurrences; a pathological zero-width match
            // cannot loop because term is non-empty.
            searchStart = range.upperBound
            if result.count >= 512 { break }
        }
        return result
    }
}

/// One global library search result. A body hit names its ACTUAL message; a
/// title-only hit has `messageID == nil` so the UI can open the conversation
/// without pretending a message matched.
public struct ConversationSearchMatch: Sendable, Codable, Hashable, Identifiable {
    public var conversationID: UUID
    public var conversationTitle: String
    public var messageID: UUID?
    public var role: String?
    public var snippet: String
    public var createdAt: Date

    public var id: String {
        "\(conversationID.uuidString):\(messageID?.uuidString ?? "title")"
    }

    public var isTitleOnly: Bool { messageID == nil }

    public init(
        conversationID: UUID,
        conversationTitle: String,
        messageID: UUID?,
        role: String?,
        snippet: String,
        createdAt: Date
    ) {
        self.conversationID = conversationID
        self.conversationTitle = String(conversationTitle.prefix(256))
        self.messageID = messageID
        self.role = role
        self.snippet = String(snippet.prefix(ConversationSearchText.maximumSnippetCharacters))
        self.createdAt = createdAt
    }
}

/// One in-conversation message hit (chronological order from the store).
public struct ConversationMessageMatch: Sendable, Codable, Hashable, Identifiable {
    public var conversationID: UUID
    public var messageID: UUID
    public var role: String
    public var snippet: String
    public var createdAt: Date

    public var id: UUID { messageID }

    public init(
        conversationID: UUID,
        messageID: UUID,
        role: String,
        snippet: String,
        createdAt: Date
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.role = role
        self.snippet = String(snippet.prefix(ConversationSearchText.maximumSnippetCharacters))
        self.createdAt = createdAt
    }
}

/// Visible-text projection used by every search surface.
///
/// Assistant content is Markdown SOURCE. Search must address what the reader
/// actually sees, so inline syntax is flattened before matching/snippeting;
/// code fence markers and language hints are dropped while the code itself is
/// kept. User content is shown verbatim, so it is used verbatim. The returned
/// string is the one whose character offsets the UI highlights.
public enum ConversationSearchText {
    public static let maximumSnippetCharacters = 160

    private struct InlineRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    /// Compiled once. NSRegularExpression is immutable and documented as
    /// thread-safe for matching, so sharing these rules is safe.
    private static let inlineRules: [InlineRule] = {
        let rules: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"`([^`\n]+)`"#, "$1"),
            (#"\*\*([^*\n]+)\*\*"#, "$1"),
            (#"__([^_\n]+)__"#, "$1"),
            (#"~~([^~\n]+)~~"#, "$1"),
            (#"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, "$1"),
            (#"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "$1"),
            (#"\\([\\`*_{}\[\]()#+\-.!>])"#, "$1"),
        ]
        return rules.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return InlineRule(regex: regex, template: template)
        }
    }()

    /// Every inline rule needs at least one of these characters. A line with
    /// none of them already equals its flattened form, which keeps the bounded
    /// search scan off the regex engine for ordinary prose.
    private static let inlineTriggerCharacters = CharacterSet(
        charactersIn: "*_~`[]()<>!\\\t")

    public static func visibleText(role: String, content: String) -> String {
        role == "assistant" ? visibleText(markdown: content) : content
    }

    public static func visibleText(markdown source: String) -> String {
        var output: [String] = []
        var inFence = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                output.append(rawLine)
                continue
            }
            if isTableSeparator(trimmed) || isThematicBreak(trimmed) { continue }
            var line = stripBlockMarkers(rawLine)
            if line.rangeOfCharacter(from: Self.inlineTriggerCharacters) != nil {
                line = flattenInline(line)
            }
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty {
                if output.last?.isEmpty == false { output.append("") }
            } else {
                output.append(cleaned)
            }
        }
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One readable line around the first match, never longer than
    /// `maximumCharacters`. Used as the global/detail hit line.
    public static func snippet(
        in text: String,
        query: ConversationSearchQuery,
        maximumCharacters: Int = 160
    ) -> String {
        let limit = max(24, maximumCharacters)
        guard let first = query.ranges(in: text).first,
              first.lowerBound < text.count else {
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? text
            return String(firstLine.prefix(limit))
        }
        let matchStart = text.index(text.startIndex, offsetBy: first.lowerBound)
        var lineStart = matchStart
        while lineStart > text.startIndex {
            let previous = text.index(before: lineStart)
            if text[previous] == "\n" { break }
            lineStart = previous
        }
        var lineEnd = matchStart
        while lineEnd < text.endIndex, text[lineEnd] != "\n" {
            lineEnd = text.index(after: lineEnd)
        }
        let line = String(text[lineStart..<lineEnd])
        let matchOffset = text.distance(from: lineStart, to: matchStart)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit { return trimmed }
        let windowStart = max(0, min(matchOffset - limit / 3, max(0, line.count - limit)))
        let startIndex = line.index(line.startIndex, offsetBy: windowStart)
        let endIndex = line.index(
            startIndex,
            offsetBy: min(limit, line.distance(from: startIndex, to: line.endIndex)))
        var window = String(line[startIndex..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if windowStart > 0 { window = "…" + window }
        if endIndex < line.endIndex { window += "…" }
        return window
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") || line.contains("|") else { return false }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count > 1 else { return false }
        return cells.allSatisfy { cell in
            let value = String(cell).trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let allowed: Set<Character> = ["-", "*", "_", " "]
        guard line.allSatisfy({ allowed.contains($0) }) else { return false }
        return line.contains("-") || line.contains("*") || line.contains("_")
    }

    private static func stripBlockMarkers(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1 {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cells.joined(separator: " ")
        }
        while line.hasPrefix(">") {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        for marker in ["#", "######", "#####", "####", "###", "##"] {
            if line.hasPrefix(marker + " ") {
                line = String(line.dropFirst(marker.count + 1))
                break
            }
        }
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
        }
        if let first = line.first, first.isNumber,
           let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        if line.hasPrefix("["),
           let range = line.range(of: #"^\[[ xX]\]\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        return line
    }

    private static func flattenInline(_ line: String) -> String {
        var value = line
        for rule in inlineRules {
            value = rule.regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: rule.template)
        }
        return value.replacingOccurrences(of: "\t", with: " ")
    }
}
