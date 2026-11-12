import Foundation

/// Only a real run resource owner can hold this protection. Goal status and
/// memory availability are deliberately unrelated to ownership.
public final class MemoryRunUseLease: @unchecked Sendable {
    private let registry: MemoryUseRegistry
    private let token: UUID

    init(registry: MemoryUseRegistry, token: UUID) {
        self.registry = registry
        self.token = token
    }

    public func include(_ memoryIDs: [UUID]) { registry.include(memoryIDs, token: token) }
    func withUse<T>(_ ids: [UUID], _ body: () throws -> T) rethrows -> T? {
        try registry.withUse(ids, token: token, body)
    }
    public func finish() { registry.release(token) }
    deinit { finish() }
}

/// Synchronous fencing lets the maintenance writer recheck ownership in the
/// same critical section as its mutation. No timer or background task is owned
/// here, and a late release cannot remove another owner's protection.
final class MemoryUseRegistry: @unchecked Sendable {
    private struct Owner {
        var runID: UUID
        var memoryIDs: Set<UUID>
    }
    private let lock = NSLock()
    private var owners: [UUID: Owner] = [:]

    func begin(runID: UUID) -> MemoryRunUseLease {
        let token = UUID()
        lock.withLock { owners[token] = Owner(runID: runID, memoryIDs: []) }
        return MemoryRunUseLease(registry: self, token: token)
    }

    func include(_ ids: [UUID], token: UUID) {
        lock.withLock {
            guard owners[token] != nil else { return }
            owners[token]?.memoryIDs.formUnion(ids)
        }
    }

    func record(_ ids: [UUID], runID: UUID) {
        lock.withLock {
            // Tools extend an existing real owner; a search cannot create a
            // permanent protection after its run has already ended.
            for token in Array(owners.keys) where owners[token]?.runID == runID {
                owners[token]?.memoryIDs.formUnion(ids)
            }
        }
    }

    func release(_ token: UUID) { lock.withLock { _ = owners.removeValue(forKey: token) } }

    func withUse<T>(_ ids: [UUID], token: UUID, _ body: () throws -> T) rethrows -> T? {
        try lock.withLock {
            guard owners[token] != nil else { return nil }
            owners[token]?.memoryIDs.formUnion(ids)
            return try body()
        }
    }

    func withProtectedIDs<T>(_ body: (Set<UUID>) throws -> T) rethrows -> T {
        try lock.withLock {
            try body(owners.values.reduce(into: Set<UUID>()) { $0.formUnion($1.memoryIDs) })
        }
    }
}

public enum MemoryForgettingPolicy {
    public static let importanceHalfLife: TimeInterval = 30 * 86_400
    public static let recallRetention: TimeInterval = 90 * 86_400
    public static let archiveAfter: TimeInterval = 90 * 86_400
    public static let releaseVectorsAfter: TimeInterval = 180 * 86_400

    /// Shared by the SQLite lifecycle and App's later compaction pass. A
    /// failed deletion (owner still present) must never start forgetting.
    public static let deletedOwnerSQL = """
        CASE WHEN m.scope = 'task' THEN
            COALESCE(m.conversation_id, m.origin_conversation_id) IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM conversations c
                WHERE c.id = COALESCE(m.conversation_id, m.origin_conversation_id))
        WHEN m.scope = 'workspace' THEN
            COALESCE(m.workspace_id, m.origin_workspace_id) IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM workspaces w
                WHERE w.id = COALESCE(m.workspace_id, m.origin_workspace_id))
        ELSE (m.origin_conversation_id IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM conversations c WHERE c.id = m.origin_conversation_id))
            OR (m.origin_conversation_id IS NULL AND m.origin_workspace_id IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM workspaces w WHERE w.id = m.origin_workspace_id)) END
        """

    /// A task-local explicit fact is not automatically a lifelong preference.
    /// Explicit expiry remains authoritative even for a preference.
    public static func isLongTerm(_ memory: MemoryEntry) -> Bool {
        if memory.isPinned { return true }
        guard memory.expiresAt == nil else { return false }
        if memory.scope == .userProfile { return true }
        return memory.scope == .agentGlobal && memory.sourceKind == .explicitUserRequest
    }

    /// Unconditional prompt context must not renew unrelated automatic facts
    /// from older tasks. They remain available to query-based recall.
    public static func isDefaultContext(_ memory: MemoryEntry, conversationID: UUID,
                                        workspaceID: UUID?) -> Bool {
        if isLongTerm(memory) { return true }
        switch memory.scope {
        case .task(let owner): return owner == conversationID
        case .workspace(let owner): return owner == workspaceID
        case .agentGlobal: return memory.originConversationID == conversationID
        case .userProfile: return false
        }
    }

    public static func relevanceWeight(since anchor: Date, now: Date) -> Double {
        pow(0.5, max(0, now.timeIntervalSince(anchor)) / importanceHalfLife)
    }
}

/// Stable identity for a mutable fact. Content changes over time, while the
/// subject/attribute slot remains stable (for example host:hk4h4g + address).
public struct MemoryFactIdentity: Sendable, Codable, Hashable {
    public var subjectKey: String
    public var attributeKey: String

    public init(subjectKey: String, attributeKey: String) {
        self.subjectKey = Self.normalize(subjectKey)
        self.attributeKey = Self.normalize(attributeKey)
    }

    public var isValid: Bool { !subjectKey.isEmpty && !attributeKey.isEmpty }

    private static func normalize(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().prefix(160))
    }
}

public enum MemoryOrganizationSuggestionKind: String, Sendable, Codable, Hashable {
    case exactDuplicate
    case sameFactReplacement
    case possibleDuplicate
    case expired
    case missingOwnership
}

public struct MemoryOrganizationSuggestion: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: MemoryOrganizationSuggestionKind
    public var memoryIDs: [UUID]
    public var preferredMemoryID: UUID?
    public var reason: String
    public var canApplyAutomatically: Bool

    public init(
        id: UUID = UUID(),
        kind: MemoryOrganizationSuggestionKind,
        memoryIDs: [UUID],
        preferredMemoryID: UUID? = nil,
        reason: String,
        canApplyAutomatically: Bool
    ) {
        self.id = id
        self.kind = kind
        self.memoryIDs = memoryIDs
        self.preferredMemoryID = preferredMemoryID
        self.reason = String(reason.prefix(500))
        self.canApplyAutomatically = canApplyAutomatically
    }
}

public struct MemoryOrganizationEntrySummary: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scope: MemoryScope
    public var status: MemoryEntryStatus
    public var content: String
    public var factIdentity: MemoryFactIdentity?
    public var originConversationID: UUID?
    public var originWorkspaceID: UUID?
    public var updatedAt: Date

    public init(_ entry: MemoryEntry) {
        id = entry.id
        scope = entry.scope
        status = entry.status
        content = String(entry.content.prefix(1_024))
        factIdentity = entry.factIdentity
        originConversationID = entry.originConversationID
        originWorkspaceID = entry.originWorkspaceID
        updatedAt = entry.updatedAt
    }
}

public struct MemoryOrganizationProposal: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var generatedAt: Date
    public var scannedCount: Int
    public var suggestions: [MemoryOrganizationSuggestion]
    /// Exact bounded entries referenced by suggestions. This makes a preview
    /// reviewable without a second guess-based search pass.
    public var entries: [MemoryOrganizationEntrySummary]

    public init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        scannedCount: Int,
        suggestions: [MemoryOrganizationSuggestion],
        entries: [MemoryOrganizationEntrySummary] = []
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.scannedCount = scannedCount
        self.suggestions = suggestions
        self.entries = entries
    }
}

public enum MemoryMaintenanceOperation: Sendable, Codable, Hashable {
    case delete(memoryID: UUID)
    case replace(memoryID: UUID, entry: MemoryEntry)
}

public struct MemoryMaintenanceBatch: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var operations: [MemoryMaintenanceOperation]
    public var syncRevision: Int64

    public init(id: UUID = UUID(), operations: [MemoryMaintenanceOperation], syncRevision: Int64) {
        self.id = id
        self.operations = operations
        self.syncRevision = syncRevision
    }
}

public struct MemoryMaintenanceBatchResult: Sendable, Codable, Hashable {
    public var batchID: UUID
    public var appliedCount: Int
    public var deletedCount: Int
    public var replacedCount: Int
    public var wasAlreadyApplied: Bool

    public init(
        batchID: UUID,
        appliedCount: Int,
        deletedCount: Int,
        replacedCount: Int,
        wasAlreadyApplied: Bool = false
    ) {
        self.batchID = batchID
        self.appliedCount = appliedCount
        self.deletedCount = deletedCount
        self.replacedCount = replacedCount
        self.wasAlreadyApplied = wasAlreadyApplied
    }
}

/// Bounded, filterable enumeration used by the model and memory-management UI.
/// Unlike semantic recall this is an inventory API: results are ordered and
/// cursor based so a caller can eventually inspect every matching entry.
public struct MemoryListRequest: Sendable, Codable, Hashable {
    public var scope: MemoryScope?
    public var status: MemoryEntryStatus?
    public var originConversationID: UUID?
    public var originWorkspaceID: UUID?
    public var factIdentity: MemoryFactIdentity?
    public var isPinned: Bool?
    public var cursor: String?
    public var limit: Int

    public init(
        scope: MemoryScope? = nil,
        status: MemoryEntryStatus? = nil,
        originConversationID: UUID? = nil,
        originWorkspaceID: UUID? = nil,
        factIdentity: MemoryFactIdentity? = nil,
        isPinned: Bool? = nil,
        cursor: String? = nil,
        limit: Int = 100
    ) {
        self.scope = scope
        self.status = status
        self.originConversationID = originConversationID
        self.originWorkspaceID = originWorkspaceID
        self.factIdentity = factIdentity?.isValid == true ? factIdentity : nil
        self.isPinned = isPinned
        self.cursor = cursor
        self.limit = min(500, max(1, limit))
    }
}

public struct MemoryListPage: Sendable, Codable, Hashable {
    public var entries: [MemoryEntry]
    public var nextCursor: String?

    public init(entries: [MemoryEntry], nextCursor: String? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}
