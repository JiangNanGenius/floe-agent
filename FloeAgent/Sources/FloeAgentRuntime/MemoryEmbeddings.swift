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
    /// Portable cosine similarity. Nil means the vectors cannot be compared;
    /// callers must never silently truncate dimensions.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }
        var dot = 0.0
        var lhsNormSquared = 0.0
        var rhsNormSquared = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsNormSquared += left * left
            rhsNormSquared += right * right
        }
        guard lhsNormSquared > 0, rhsNormSquared > 0 else { return nil }
        let value = dot / sqrt(lhsNormSquared * rhsNormSquared)
        guard value.isFinite else { return nil }
        return min(1, max(-1, value))
    }
}

public enum MemoryContentDigest {
    public static func make(_ content: String) -> String {
        FloeDigest.sha256Hex(Data(content.utf8))
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

/// Source evidence retains the owning service identity; it is never a tool grant.
public struct MemorySourceEvidence: Codable, Sendable, Hashable {
    public var sourceID: String
    public var revision: String
    public var ownerID: String
    public var locator: String
    public init(sourceID: String, revision: String, ownerID: String, locator: String) {
        self.sourceID = String(sourceID.prefix(512)); self.revision = String(revision.prefix(160))
        self.ownerID = String(ownerID.prefix(160)); self.locator = String(locator.prefix(2_048))
    }
    public var isValid: Bool { !sourceID.isEmpty && !revision.isEmpty && !ownerID.isEmpty }
}

#if canImport(NaturalLanguage)
/// Real Apple sentence/word vectors, with independent Chinese and English channels.
/// A word channel averages learned word vectors after native tokenization; it is
/// semantic pooling, not hashing. Channels are never treated as aligned languages.
/// One actor serializes NLEmbedding access, as required by NaturalLanguage.
public actor AppleLocalSemanticEmbeddingProvider: MemoryEmbeddingProvider {
    private struct Channel {
        let language: NLLanguage
        let embedding: NLEmbedding
        let sentence: Bool
        let dimensions: Int
    }
    public nonisolated let modelIdentifier = "apple.nl.zh-en.channels-v1"
    public nonisolated let modelRevision: String
    public nonisolated let modality = MemoryEmbeddingModality.text
    public nonisolated let supportsChinese: Bool
    private let channels: [Channel]
    public init() throws {
        var available = [Channel]()
        for language in [NLLanguage.simplifiedChinese, .english] {
            if let model = NLEmbedding.sentenceEmbedding(for: language) {
                available.append(.init(language: language, embedding: model, sentence: true, dimensions: model.dimension))
            } else if let model = NLEmbedding.wordEmbedding(for: language) {
                available.append(.init(language: language, embedding: model, sentence: false, dimensions: model.dimension))
            }
        }
        guard !available.isEmpty, available.reduce(0, { $0 + $1.dimensions }) <= 4_096 else {
            throw FloeError.notFound("On-device semantic embedding assets")
        }
        channels = available
        supportsChinese = available.contains { $0.language == .simplifiedChinese }
        modelRevision = available.map { "\($0.language.rawValue):\($0.sentence ? "sentence" : "word-pool"):\($0.embedding.revision):\($0.dimensions)" }.joined(separator: "+")
    }
    public func embedding(for content: String) async throws -> [Float] {
        let text = String(content.prefix(12_000))
        var output = [Float]()
        for channel in channels {
            var vector = [Double](repeating: 0, count: channel.dimensions)
            if channel.sentence, let generated = channel.embedding.vector(for: text), generated.count == channel.dimensions {
                vector = generated
            } else {
                let tokenizer = NLTokenizer(unit: .word); tokenizer.setLanguage(channel.language); tokenizer.string = text
                var count = 0
                tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                    guard count < 384 else { return false }
                    let token = String(text[range]).lowercased()
                    let hasHan = token.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
                    guard channel.language == .simplifiedChinese ? hasHan : !hasHan else { return true }
                    guard let value = channel.embedding.vector(for: token), value.count == vector.count else { return true }
                    for i in vector.indices { vector[i] += value[i] }; count += 1
                    return true
                }
            }
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            output += vector.map { Float(norm > 0 ? $0 / norm : 0) }
        }
        let norm = sqrt(output.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0, output.allSatisfy(\.isFinite) else { throw FloeError.notFound("No semantic vectors for the supplied text") }
        return output.map { Float(Double($0) / norm) }
    }
}
#endif
