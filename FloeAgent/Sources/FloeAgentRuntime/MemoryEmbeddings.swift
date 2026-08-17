import Accelerate
import Crypto
import Foundation
import FloeCore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum MemoryEmbeddingModality: String, Sendable, Codable, Hashable, CaseIterable {
    case text
    case image
}

/// A versioned local or remote embedding. Keeping model identity on every
/// vector prevents scores from incompatible spaces being mixed during an
/// incremental reindex.
public struct MemoryEmbedding: Sendable, Codable, Hashable {
    public var memoryID: UUID
    public var modality: MemoryEmbeddingModality
    public var modelIdentifier: String
    public var modelRevision: String
    public var values: [Float]
    public var contentDigest: String
    public var createdAt: Date

    public init(
        memoryID: UUID,
        modality: MemoryEmbeddingModality,
        modelIdentifier: String,
        modelRevision: String,
        values: [Float],
        contentDigest: String,
        createdAt: Date = Date()
    ) {
        self.memoryID = memoryID
        self.modality = modality
        self.modelIdentifier = String(modelIdentifier.prefix(160))
        self.modelRevision = String(modelRevision.prefix(80))
        self.values = Array(values.prefix(4_096))
        self.contentDigest = String(contentDigest.prefix(160))
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        !values.isEmpty && values.count <= 4_096 && values.allSatisfy(\.isFinite)
    }
}

public struct HybridMemoryRecallRequest: Sendable, Hashable {
    public var query: String
    public var workspaceID: UUID?
    public var conversationID: UUID?
    public var queryEmbedding: [Float]?
    public var modality: MemoryEmbeddingModality
    public var modelIdentifier: String?
    public var modelRevision: String?
    public var limit: Int

    public init(
        query: String,
        workspaceID: UUID? = nil,
        conversationID: UUID? = nil,
        queryEmbedding: [Float]? = nil,
        modality: MemoryEmbeddingModality = .text,
        modelIdentifier: String? = nil,
        modelRevision: String? = nil,
        limit: Int = 6
    ) {
        self.query = String(query.prefix(8_000))
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.queryEmbedding = queryEmbedding.map { Array($0.prefix(4_096)) }
        self.modality = modality
        self.modelIdentifier = modelIdentifier
        self.modelRevision = modelRevision
        self.limit = min(20, max(1, limit))
    }
}

public struct HybridMemoryRecallItem: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var content: String
    public var relevance: Double
    public var lexicalRank: Int?
    public var semanticRank: Int?
    public var semanticSimilarity: Double?

    public init(
        id: UUID,
        content: String,
        relevance: Double,
        lexicalRank: Int? = nil,
        semanticRank: Int? = nil,
        semanticSimilarity: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.relevance = min(1, max(0, relevance))
        self.lexicalRank = lexicalRank
        self.semanticRank = semanticRank
        self.semanticSimilarity = semanticSimilarity
    }
}

public protocol MemoryEmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var modelRevision: String { get }
    var modality: MemoryEmbeddingModality { get }
    func embedding(for content: String) async throws -> [Float]
}

#if canImport(NaturalLanguage)
/// Apple's bundled sentence embedding. Assets remain on-device; if the
/// requested language is unavailable callers fall back to lexical FTS rather
/// than silently uploading memory content.
public struct AppleNaturalLanguageEmbeddingProvider: MemoryEmbeddingProvider {
    public let language: NLLanguage
    public var modelIdentifier: String { "apple.nlembedding.\(language.rawValue)" }
    public let modelRevision: String
    public let modality = MemoryEmbeddingModality.text

    public init(language: NLLanguage, modelRevision: String = "system") {
        self.language = language
        self.modelRevision = modelRevision
    }

    public func embedding(for content: String) async throws -> [Float] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let vector = embedding.vector(for: content), !vector.isEmpty else {
            throw FloeError.notFound("On-device text embedding for \(language.rawValue)")
        }
        return vector.map(Float.init)
    }
}
#endif

public enum MemoryVectorMath {
    /// Cosine similarity backed by Accelerate. Nil means the vectors cannot
    /// be compared; callers must never silently truncate dimensions.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }
        let dot = vDSP.dot(lhs, rhs)
        let lhsNormSquared = vDSP.sumOfSquares(lhs)
        let rhsNormSquared = vDSP.sumOfSquares(rhs)
        guard lhsNormSquared > 0, rhsNormSquared > 0 else { return nil }
        let value = dot / sqrt(lhsNormSquared * rhsNormSquared)
        return Double(min(1, max(-1, value)))
    }
}

public enum MemoryContentDigest {
    public static func make(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic RRF used after lexical and semantic searches. Importance,
/// pinned state and freshness are deliberately small tie-breakers: they must
/// not turn an unrelated memory into a relevant one.
public enum MemoryReciprocalRankFusion {
    public struct Candidate: Sendable, Hashable {
        public var id: UUID
        public var content: String
        public var lexicalRank: Int?
        public var semanticRank: Int?
        public var semanticSimilarity: Double?
        public var importance: Double
        public var isPinned: Bool
        public var updatedAt: Date

        public init(
            id: UUID,
            content: String,
            lexicalRank: Int? = nil,
            semanticRank: Int? = nil,
            semanticSimilarity: Double? = nil,
            importance: Double,
            isPinned: Bool,
            updatedAt: Date
        ) {
            self.id = id
            self.content = content
            self.lexicalRank = lexicalRank
            self.semanticRank = semanticRank
            self.semanticSimilarity = semanticSimilarity
            self.importance = min(1, max(0, importance))
            self.isPinned = isPinned
            self.updatedAt = updatedAt
        }
    }

    public static func fuse(
        _ candidates: [Candidate],
        limit: Int,
        now: Date = Date(),
        rankConstant: Double = 60
    ) -> [HybridMemoryRecallItem] {
        let scored = candidates.compactMap { candidate -> (Candidate, Double)? in
            var score = 0.0
            if let rank = candidate.lexicalRank { score += 1 / (rankConstant + Double(rank)) }
            if let rank = candidate.semanticRank { score += 1 / (rankConstant + Double(rank)) }
            guard score > 0 else { return nil }
            score += candidate.isPinned ? 0.0020 : 0
            score += candidate.importance * 0.0010
            let ageDays = max(0, now.timeIntervalSince(candidate.updatedAt) / 86_400)
            score += exp(-ageDays / 30) * 0.0005
            return (candidate, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.updatedAt > $1.0.updatedAt
        }
        guard let maximum = scored.first?.1, maximum > 0 else { return [] }
        return scored.prefix(min(20, max(1, limit))).map { candidate, score in
            HybridMemoryRecallItem(
                id: candidate.id,
                content: candidate.content,
                relevance: score / maximum,
                lexicalRank: candidate.lexicalRank,
                semanticRank: candidate.semanticRank,
                semanticSimilarity: candidate.semanticSimilarity
            )
        }
    }
}
