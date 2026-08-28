import Foundation
import GRDB
import FloeCore
import FloePersistence

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
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), scope: MemoryScope, status: MemoryEntryStatus,
        content: String, confidence: Double, importance: Double,
        isPinned: Bool = false, sourceKind: MemoryCandidateOrigin,
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
}

/// One durable implementation for plans, goals, bounded memory and explicit
/// cross-conversation history access. The runtime owns semantic types while
/// the shared DatabaseManager preserves serialized writes and foreign keys.
public actor SQLiteIntelligenceStore: PlanDraftStore, ConversationGoalStore, DurableMemoryStore, ConversationHistoryReader {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveCompaction(
        runID: UUID,
        record: ContextCompactionRecord,
        summary: String
    ) async throws {
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
                    String(summary.prefix(24_000)),
                    record.sourceDigest,
                    record.beforeEstimatedTokens,
                    record.afterEstimatedTokens,
                    Self.date(record.createdAt)
                ])
        }
    }

    public func savePlanRevision(_ plan: PlanDraft) async throws {
        let sections = try Self.json(plan.sections)
        let assumptions = try Self.json(plan.assumptions)
        let risks = try Self.json(plan.risks)
        let criteria = try Self.json(plan.acceptanceCriteria)
        let messages = try Self.json(plan.sourceMessageIDs)
        let references = try Self.json(plan.sourceReferences)
        try await database.writer { db in
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
        let criteria = try Self.json(goal.acceptanceCriteria)
        let steps = try Self.json(goal.steps)
        let evidence = try Self.json(goal.evidence)
        let budgets = try Self.json(goal.budgets)
        let progress = try Self.json(goal.progress)
        let blockingConditions = try Self.json(goal.blockingConditions ?? [])
        let stoppingConditions = try Self.json(goal.stoppingConditions ?? [])
        try await database.writer { db in
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
        let (scope, workspaceID, conversationID) = Self.scope(entry.scope)
        let normalized = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw FloeError.validationFailed("Memory must not be empty") }
        guard !Self.looksLikeSecret(normalized) else {
            throw FloeError.validationFailed("Authentication material cannot be saved to memory")
        }
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO memory_entries (
                    id, scope, workspace_id, conversation_id, status, content, normalized_content,
                    confidence, importance, is_pinned, source_kind, expires_at,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status=excluded.status, content=excluded.content,
                    normalized_content=excluded.normalized_content, confidence=excluded.confidence,
                    importance=excluded.importance, is_pinned=excluded.is_pinned,
                    expires_at=excluded.expires_at, updated_at=excluded.updated_at
                """, arguments: [entry.id.uuidString, scope, workspaceID?.uuidString,
                    conversationID?.uuidString,
                    entry.status.rawValue, entry.content, normalized, entry.confidence,
                    entry.importance, entry.isPinned, entry.sourceKind.rawValue,
                    entry.expiresAt.map(Self.date), Self.date(entry.createdAt), Self.date(entry.updatedAt)])
            try db.execute(sql: "DELETE FROM memory_evidence WHERE memory_id = ?", arguments: [entry.id.uuidString])
            for reference in evidence {
                try db.execute(sql: """
                    INSERT INTO memory_evidence (id, memory_id, message_id, excerpt_digest, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [reference.id.uuidString, entry.id.uuidString,
                        reference.messageID.uuidString, Self.stableDigest(reference.excerpt), Self.date(entry.updatedAt)])
            }
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
        ownerLabel: String
    ) async throws {
        let now = Self.date(Date())
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE memory_entries SET
                    origin_conversation_id = COALESCE(origin_conversation_id, conversation_id),
                    origin_owner_label = COALESCE(origin_owner_label, ?),
                    owner_deleted_at = COALESCE(owner_deleted_at, ?),
                    conversation_id = NULL,
                    retained_until = COALESCE(retained_until, ?)
                WHERE conversation_id = ?
                """, arguments: [String(ownerLabel.prefix(120)), now,
                    Self.date(Date().addingTimeInterval(90 * 86_400)),
                    conversationID.uuidString])
        }
    }

    /// Workspace records have ON DELETE CASCADE in the published schema.
    /// Detach memory first so deleting a project/private workspace preserves
    /// ownership history instead of silently erasing durable memory.
    public func preserveMemoriesBeforeWorkspaceDeletion(
        workspaceID: UUID,
        ownerLabel: String
    ) async throws {
        let now = Self.date(Date())
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE memory_entries SET
                    origin_workspace_id = COALESCE(origin_workspace_id, workspace_id),
                    origin_owner_label = COALESCE(origin_owner_label, ?),
                    owner_deleted_at = COALESCE(owner_deleted_at, ?),
                    workspace_id = NULL,
                    retained_until = COALESCE(retained_until, ?)
                WHERE workspace_id = ?
                """, arguments: [String(ownerLabel.prefix(120)), now,
                    Self.date(Date().addingTimeInterval(90 * 86_400)),
                    workspaceID.uuidString])
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
                    m.scope IN ('user', 'agent', 'task')
                    OR m.workspace_id = ?
                    OR m.origin_workspace_id = ?
                  )
                  AND (m.expires_at IS NULL OR m.expires_at > ?)
                  AND (
                    m.owner_deleted_at IS NULL OR m.is_pinned = 1
                    OR m.retained_until > ?
                    OR m.owner_deleted_at > ?
                  )
                ORDER BY m.is_pinned DESC,
                    CASE WHEN m.conversation_id = ? THEN 0
                         WHEN m.owner_deleted_at IS NULL THEN 1 ELSE 2 END,
                    rank, m.importance DESC LIMIT ?
                """, arguments: [
                    match, workspaceID?.uuidString, workspaceID?.uuidString,
                    Self.date(Date()), Self.date(Date()),
                    Self.date(Date().addingTimeInterval(-365 * 86_400)),
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
        try await maintainMemoryLifecycle()
        let lexicalMatch = Self.ftsQuery(request.query)
        let lexicalRows: [HybridRecallDatabaseRow]
        if lexicalMatch.isEmpty {
            lexicalRows = []
        } else {
            lexicalRows = try await database.reader { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.id, m.content, m.importance, m.is_pinned, m.updated_at
                    FROM memory_fts JOIN memory_entries m ON m.rowid = memory_fts.rowid
                    WHERE memory_fts MATCH ? AND m.status = 'active'
                      AND (m.scope IN ('user', 'agent', 'task')
                           OR m.workspace_id = ? OR m.origin_workspace_id = ?)
                      AND (m.expires_at IS NULL OR m.expires_at > ?)
                      AND (m.owner_deleted_at IS NULL OR m.is_pinned = 1
                           OR m.retained_until > ? OR m.owner_deleted_at > ?)
                    ORDER BY CASE WHEN m.conversation_id = ? THEN 0
                                  WHEN m.owner_deleted_at IS NULL THEN 1 ELSE 2 END,
                             bm25(memory_fts), m.is_pinned DESC, m.importance DESC
                    LIMIT 50
                    """, arguments: [lexicalMatch, request.workspaceID?.uuidString,
                        request.workspaceID?.uuidString, Self.date(Date()), Self.date(Date()),
                        Self.date(Date().addingTimeInterval(-365 * 86_400)),
                        request.conversationID?.uuidString])
                    .compactMap(Self.hybridRow)
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
                    SELECT m.id, m.content, m.importance, m.is_pinned, m.updated_at,
                           e.vector_blob, e.dimensions
                    FROM memory_embeddings e
                    JOIN memory_entries m ON m.id = e.memory_id
                    WHERE e.modality = ? AND e.model_identifier = ?
                      AND e.model_revision = ? AND e.dimensions = ?
                      AND m.status = 'active'
                      AND (m.scope IN ('user', 'agent', 'task')
                           OR m.workspace_id = ? OR m.origin_workspace_id = ?)
                      AND (m.expires_at IS NULL OR m.expires_at > ?)
                      AND (m.owner_deleted_at IS NULL OR m.is_pinned = 1
                           OR m.retained_until > ? OR m.owner_deleted_at > ?)
                    LIMIT 2000
                    """, arguments: [request.modality.rawValue, modelIdentifier, modelRevision,
                        queryVector.count, request.workspaceID?.uuidString,
                        request.workspaceID?.uuidString, Self.date(Date()), Self.date(Date()),
                        Self.date(Date().addingTimeInterval(-365 * 86_400))])
                    .compactMap { row in
                        guard let candidate = Self.hybridRow(row) else { return nil }
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
        let results = MemoryReciprocalRankFusion.fuse(Array(fused.values), limit: request.limit)
        try await reinforceMemories(results.map(\.id))
        return results
    }

    /// Recall temporarily strengthens orphaned memories. Active task and
    /// workspace memories are intentionally unlimited and never enter this
    /// aging path; only memories whose owner was deleted are compacted.
    private func reinforceMemories(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let now = Date()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var mutableArguments = StatementArguments([
            Self.date(now), Self.date(now.addingTimeInterval(90 * 86_400))
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

    /// Forgetting curve for deleted owners: vectors are released after 180
    /// days without reinforcement, and unpinned memories become search-only
    /// superseded records after one year. Text is retained for audit and can
    /// still be restored manually instead of being destructively erased.
    public func maintainMemoryLifecycle(now: Date = Date()) async throws {
        let vectorCutoff = Self.date(now.addingTimeInterval(-180 * 86_400))
        let archiveCutoff = Self.date(now.addingTimeInterval(-365 * 86_400))
        let nowText = Self.date(now)
        try await database.writer { db in
            try db.execute(sql: """
                DELETE FROM memory_embeddings
                WHERE memory_id IN (
                    SELECT id FROM memory_entries
                    WHERE owner_deleted_at IS NOT NULL AND is_pinned = 0
                      AND owner_deleted_at < ?
                      AND (retained_until IS NULL OR retained_until < ?)
                )
                """, arguments: [vectorCutoff, nowText])
            try db.execute(sql: """
                UPDATE memory_entries SET status = 'superseded'
                WHERE owner_deleted_at IS NOT NULL AND is_pinned = 0
                  AND owner_deleted_at < ?
                  AND (retained_until IS NULL OR retained_until < ?)
                  AND status = 'active'
                """, arguments: [archiveCutoff, nowText])
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
                try db.execute(
                    sql: "DELETE FROM memory_entries WHERE id = ?",
                    arguments: [id.uuidString]
                )
                try db.execute(sql: """
                    INSERT INTO memory_tombstones (memory_id, deleted_at, sync_revision)
                    VALUES (?, ?, ?) ON CONFLICT(memory_id) DO UPDATE SET
                    deleted_at=excluded.deleted_at, sync_revision=excluded.sync_revision
                    """, arguments: [id.uuidString, deletedAt, syncRevision])
            }
        }
    }

    public func search(_ request: ConversationSearchRequest) async throws -> [ConversationSearchHit] {
        let match = Self.ftsQuery(request.query)
        guard !match.isEmpty else { return [] }
        return try await database.reader { db in
            var filters = ["message_fts MATCH ?", "c.is_searchable = 1"]
            var arguments: StatementArguments = [match]
            if let workspaceID = request.workspaceID {
                filters.append("wc.workspace_id = ?"); arguments += [workspaceID.uuidString]
            }
            if let start = request.startDate { filters.append("m.created_at >= ?"); arguments += [Self.date(start)] }
            if let end = request.endDate { filters.append("m.created_at <= ?"); arguments += [Self.date(end)] }
            arguments += [request.limit]
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS message_id, m.conversation_id, m.created_at,
                       c.title, MIN(wc.workspace_id) AS workspace_id,
                       snippet(message_fts, 0, '[', ']', '…', 24) AS snippet
                FROM message_fts
                JOIN messages m ON m.rowid = message_fts.rowid
                JOIN conversations c ON c.id = m.conversation_id
                LEFT JOIN conversation_workspace_ownership wc ON wc.conversation_id = c.id
                WHERE \(filters.joined(separator: " AND "))
                GROUP BY m.id ORDER BY bm25(message_fts), m.created_at DESC LIMIT ?
                """, arguments: arguments)
            return rows.compactMap(Self.searchHit)
        }
    }

    public func read(_ request: ConversationPageRequest) async throws -> ConversationHistoryPage {
        let offset = Int(request.cursor ?? "0") ?? 0
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, role, content, created_at FROM messages
                WHERE conversation_id = ? ORDER BY created_at, rowid LIMIT ? OFFSET ?
                """, arguments: [request.conversationID.uuidString, request.limit + 1, offset])
            let hasMore = rows.count > request.limit
            let messages = try rows.prefix(request.limit).map(Self.historyMessage)
            return ConversationHistoryPage(
                conversationID: request.conversationID,
                messages: messages,
                nextCursor: hasMore ? String(offset + request.limit) : nil
            )
        }
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
        return MemoryEntry(id: id, scope: scope, status: status, content: row["content"], confidence: row["confidence"],
            importance: row["importance"], isPinned: row["is_pinned"], sourceKind: source,
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

    private static func hybridRow(_ row: Row) -> HybridRecallDatabaseRow? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return HybridRecallDatabaseRow(id: id, content: row["content"],
            importance: row["importance"], isPinned: row["is_pinned"],
            updatedAt: parseDate(row["updated_at"]))
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
