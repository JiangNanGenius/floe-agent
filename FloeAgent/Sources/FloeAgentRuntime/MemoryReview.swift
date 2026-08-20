import Foundation

public enum MemoryScope: Sendable, Codable, Hashable {
    case userProfile
    case agentGlobal
    case workspace(UUID)
    case task(UUID)
}

public enum MemorySensitivity: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    case personal
    case authenticationSecret
}

public enum MemoryCandidateOrigin: String, Sendable, Codable, Hashable {
    case explicitUserRequest
    case automaticTurnReview
    case goalStepReview
    case planReview
}

public struct MemoryEvidenceReference: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var messageID: UUID
    public var excerpt: String

    public init(id: UUID = UUID(), messageID: UUID, excerpt: String) {
        self.id = id
        self.messageID = messageID
        self.excerpt = String(excerpt.prefix(512))
    }
}

public struct MemoryCandidate: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scope: MemoryScope
    public var content: String
    public var confidence: Double
    public var stability: Double
    public var importance: Double
    public var sensitivity: MemorySensitivity
    public var origin: MemoryCandidateOrigin
    public var evidence: [MemoryEvidenceReference]
    public var conflictsWithEntryIDs: [UUID]
    public var expiresAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        scope: MemoryScope,
        content: String,
        confidence: Double,
        stability: Double,
        importance: Double,
        sensitivity: MemorySensitivity = .none,
        origin: MemoryCandidateOrigin,
        evidence: [MemoryEvidenceReference],
        conflictsWithEntryIDs: [UUID] = [],
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.content = String(content.prefix(4_096))
        self.confidence = min(1, max(0, confidence))
        self.stability = min(1, max(0, stability))
        self.importance = min(1, max(0, importance))
        self.sensitivity = sensitivity
        self.origin = origin
        self.evidence = Array(evidence.prefix(12))
        self.conflictsWithEntryIDs = Array(conflictsWithEntryIDs.prefix(12))
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

public enum MemoryReviewDisposition: Sendable, Codable, Hashable {
    case activate
    case pending(reason: String)
    case reject(reason: String)
}

public struct MemoryReviewLimits: Sendable, Codable, Hashable {
    public var maximumPending: Int
    public var maximumPendingPerWorkspace: Int
    public var pendingLifetime: TimeInterval
    public var maximumRecallCount: Int
    public var maximumRecallTokens: Int

    public init(
        maximumPending: Int = 24,
        maximumPendingPerWorkspace: Int = 8,
        pendingLifetime: TimeInterval = 7 * 24 * 60 * 60,
        maximumRecallCount: Int = 6,
        maximumRecallTokens: Int = 1_500
    ) {
        self.maximumPending = max(1, maximumPending)
        self.maximumPendingPerWorkspace = max(1, maximumPendingPerWorkspace)
        self.pendingLifetime = max(60, pendingLifetime)
        self.maximumRecallCount = max(1, maximumRecallCount)
        self.maximumRecallTokens = max(1, maximumRecallTokens)
    }
}

public protocol MemoryCandidateReviewer: Sendable {
    /// Implementations receive evidence-bounded input and must not expose
    /// tools. Invalid model JSON should be translated to `.pending`.
    func review(_ candidate: MemoryCandidate) async -> MemoryReviewDisposition
}

/// Local policy applied after any model review. It cannot be overridden by
/// an "activate" response from the review model.
public struct BoundedMemoryReviewPolicy: Sendable {
    public var automaticConfidenceThreshold: Double
    public var automaticStabilityThreshold: Double
    public var automaticImportanceThreshold: Double

    public init(
        automaticConfidenceThreshold: Double = 0.85,
        automaticStabilityThreshold: Double = 0.75,
        automaticImportanceThreshold: Double = 0.50
    ) {
        self.automaticConfidenceThreshold = automaticConfidenceThreshold
        self.automaticStabilityThreshold = automaticStabilityThreshold
        self.automaticImportanceThreshold = automaticImportanceThreshold
    }

    public func disposition(
        for candidate: MemoryCandidate,
        modelDisposition: MemoryReviewDisposition? = nil
    ) -> MemoryReviewDisposition {
        let normalized = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .reject(reason: "empty") }
        if candidate.sensitivity == .authenticationSecret || Self.looksLikeSecret(normalized) {
            return .reject(reason: "authentication material is never stored in memory")
        }
        guard !candidate.evidence.isEmpty else {
            return .pending(reason: "direct evidence required")
        }
        guard candidate.conflictsWithEntryIDs.isEmpty else {
            return .pending(reason: "conflicts with existing memory")
        }
        if candidate.sensitivity == .personal {
            return .pending(reason: "personal information requires review")
        }
        if case .reject = modelDisposition { return modelDisposition! }
        if case .pending = modelDisposition { return modelDisposition! }

        if candidate.origin == .explicitUserRequest {
            return .activate
        }
        guard candidate.confidence >= automaticConfidenceThreshold,
              candidate.stability >= automaticStabilityThreshold,
              candidate.importance >= automaticImportanceThreshold else {
            return .reject(reason: "low-confidence, temporary, or low-value candidate")
        }
        return modelDisposition ?? .activate
    }

    private static func looksLikeSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "api_key=", "apikey=", "authorization: bearer", "-----begin private key",
            "password:", "password=", "access_token", "refresh_token"
        ]
        return markers.contains { lower.contains($0) }
    }
}

/// Bounded pending queue. Expired items are discarded and are never
/// promoted implicitly. When full, the oldest lowest-importance candidate
/// is evicted first.
public actor MemoryPendingQueue {
    private let limits: MemoryReviewLimits
    private var candidates: [MemoryCandidate] = []

    public init(limits: MemoryReviewLimits = MemoryReviewLimits()) {
        self.limits = limits
    }

    @discardableResult
    public func enqueue(_ candidate: MemoryCandidate, now: Date = Date()) -> MemoryCandidate? {
        purgeExpired(now: now)
        var bounded = candidate
        bounded.expiresAt = minDate(
            candidate.expiresAt,
            now.addingTimeInterval(limits.pendingLifetime)
        )
        candidates.removeAll { $0.id == bounded.id }
        candidates.append(bounded)

        if case .workspace(let workspaceID) = bounded.scope {
            trimWorkspace(workspaceID)
        }
        trimGlobal()
        return candidates.contains(where: { $0.id == bounded.id }) ? bounded : nil
    }

    public func all(now: Date = Date()) -> [MemoryCandidate] {
        purgeExpired(now: now)
        return candidates.sorted { $0.createdAt > $1.createdAt }
    }

    public func remove(id: UUID) {
        candidates.removeAll { $0.id == id }
    }

    private func purgeExpired(now: Date) {
        candidates.removeAll { candidate in
            guard let expiresAt = candidate.expiresAt else { return false }
            return expiresAt <= now
        }
    }

    private func trimWorkspace(_ workspaceID: UUID) {
        let scoped = candidates.enumerated().filter { _, candidate in
            if case .workspace(let id) = candidate.scope { return id == workspaceID }
            return false
        }
        guard scoped.count > limits.maximumPendingPerWorkspace else { return }
        let removeCount = scoped.count - limits.maximumPendingPerWorkspace
        let indexes = scoped.sorted(by: Self.evictionOrder).prefix(removeCount).map(\.offset)
        for index in indexes.sorted(by: >) { candidates.remove(at: index) }
    }

    private func trimGlobal() {
        guard candidates.count > limits.maximumPending else { return }
        let removeCount = candidates.count - limits.maximumPending
        let indexes = candidates.enumerated().sorted(by: Self.evictionOrder)
            .prefix(removeCount).map(\.offset)
        for index in indexes.sorted(by: >) { candidates.remove(at: index) }
    }

    private static func evictionOrder(
        _ lhs: EnumeratedSequence<[MemoryCandidate]>.Element,
        _ rhs: EnumeratedSequence<[MemoryCandidate]>.Element
    ) -> Bool {
        if lhs.element.importance == rhs.element.importance {
            return lhs.element.createdAt < rhs.element.createdAt
        }
        return lhs.element.importance < rhs.element.importance
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }
}

public struct MemoryRecallItem: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var content: String
    public var relevance: Double

    public init(id: UUID, content: String, relevance: Double) {
        self.id = id
        self.content = content
        self.relevance = min(1, max(0, relevance))
    }
}

public enum MemoryRecallLimiter {
    public static func bounded(
        _ candidates: [MemoryRecallItem],
        limits: MemoryReviewLimits = MemoryReviewLimits(),
        estimator: ContextTokenEstimator = ContextTokenEstimator()
    ) -> [MemoryRecallItem] {
        var result: [MemoryRecallItem] = []
        var tokens = 0
        for item in candidates.sorted(by: { $0.relevance > $1.relevance }) {
            let itemTokens = estimator.estimate(item.content)
            guard result.count < limits.maximumRecallCount,
                  tokens + itemTokens <= limits.maximumRecallTokens else { continue }
            result.append(item)
            tokens += itemTokens
        }
        return result
    }
}

public struct MemoryCapacityPolicy: Sendable, Codable, Hashable {
    public var userProfileCharacters: Int
    public var agentGlobalCharacters: Int
    public var workspaceCharacters: Int
    public var taskCharacters: Int

    public init(
        userProfileCharacters: Int = 2_000,
        agentGlobalCharacters: Int = 3_000,
        workspaceCharacters: Int = 5_000,
        taskCharacters: Int = 4_000
    ) {
        self.userProfileCharacters = max(1, userProfileCharacters)
        self.agentGlobalCharacters = max(1, agentGlobalCharacters)
        self.workspaceCharacters = max(1, workspaceCharacters)
        self.taskCharacters = max(1, taskCharacters)
    }

    public func activeCharacterLimit(for scope: MemoryScope) -> Int {
        switch scope {
        case .userProfile: userProfileCharacters
        case .agentGlobal: agentGlobalCharacters
        case .workspace: workspaceCharacters
        case .task: taskCharacters
        }
    }

    /// Picks active memories by pinned status, importance, and freshness;
    /// remaining entries should be archived/search-only by persistence.
    public func partitionActive(
        _ entries: [MemoryActiveEntry],
        scope: MemoryScope
    ) -> (active: [MemoryActiveEntry], archive: [MemoryActiveEntry]) {
        let ordered = entries.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
        var active: [MemoryActiveEntry] = []
        var archive: [MemoryActiveEntry] = []
        var characters = 0
        for entry in ordered {
            let next = entry.content.count
            if characters + next <= activeCharacterLimit(for: scope) {
                active.append(entry)
                characters += next
            } else {
                archive.append(entry)
            }
        }
        return (active, archive)
    }
}

public struct MemoryActiveEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var content: String
    public var importance: Double
    public var isPinned: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        content: String,
        importance: Double,
        isPinned: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.importance = min(1, max(0, importance))
        self.isPinned = isPinned
        self.updatedAt = updatedAt
    }
}
