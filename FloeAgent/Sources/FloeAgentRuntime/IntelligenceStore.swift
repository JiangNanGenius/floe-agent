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
}

public extension DurableMemoryStore {
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
public actor SQLiteIntelligenceStore: PlanDraftStore, ConversationGoalStore, DurableMemoryStore, ConversationHistoryReader {
    private struct ConversationTimelineCursor: Codable {
        var createdAt: String
        var sequence: Int
        var itemID: String
    }
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
        let replacementRevision = Int64(Date().timeIntervalSince1970 * 1_000)
        try await database.writer { db in
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
                        entry.originConversationID?.uuidString, reference.messageID.uuidString,
                        Self.stableDigest(reference.excerpt), Self.date(entry.updatedAt)])
            }
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
                reason: "内容完全相同；跨范围删除仍需确认。",
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
                    ? "同一范围的事实槽位存在多个当前值，应保留最新值。"
                    : "同一事实槽位跨多个范围存在不同值，需要确认后再整理。",
                canApplyAutomatically: staysWithinOneScope
            ))
        }
        for entry in entries where entry.expiresAt.map({ $0 <= Date() }) == true {
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .expired, memoryIDs: [entry.id], reason: "记忆已超过有效期。",
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
                sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                arguments: [request.conversationID.uuidString]
            ) == true else {
                throw FloeError.validationFailed("The requested task no longer exists")
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
            let hasMore = rows.count > request.limit
            let selectedRows = Array(rows.prefix(request.limit))
            let items = try selectedRows.map(Self.historyItem)
            let nextCursor: String? = if hasMore, let last = selectedRows.last {
                try Self.encodeTimelineCursor(ConversationTimelineCursor(
                    createdAt: last["created_at"],
                    sequence: last["sort_sequence"],
                    itemID: last["item_id"]
                ))
            } else { nil }
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
