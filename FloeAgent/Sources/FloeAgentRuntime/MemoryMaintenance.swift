import Foundation

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

public struct MemoryOrganizationProposal: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var generatedAt: Date
    public var scannedCount: Int
    public var suggestions: [MemoryOrganizationSuggestion]

    public init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        scannedCount: Int,
        suggestions: [MemoryOrganizationSuggestion]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.scannedCount = scannedCount
        self.suggestions = suggestions
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
