// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeAgentRuntime

nonisolated enum GlobalSourceKind: String, Codable, Sendable { case personalFile, personalWork, note, workspaceFile, conversationMessage }
nonisolated enum GlobalSourceAvailability: String, Codable, Sendable { case available, needsTextExtraction, unavailable, deleted, excluded }
nonisolated struct GlobalSourceDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var providerID: String
    var kind: GlobalSourceKind
    var ownerID: String
    var revision: String
    var title: String
    /// Owning service's opaque locator, never a model-authored arbitrary path.
    var locator: String
    var workspaceID: UUID?
    var conversationID: UUID?
    var messageID: UUID?
    var modifiedAt: Date
    var availability: GlobalSourceAvailability = .available
}
nonisolated struct GlobalSourceSnapshot: Sendable {
    var source: GlobalSourceDescriptor
    var text: String
    var truncated = false
}
nonisolated struct GlobalSourcePage: Sendable {
    var sources: [GlobalSourceDescriptor]
    var nextCursor: String?
    var unavailableOwners: [String] = []
}
nonisolated protocol GlobalSourceProvider: Sendable {
    var id: String { get }
    /// Runtime inventory over existing authorized stores/leases, excluding temporary state.
    func inventory(cursor: String?, limit: Int) async throws -> GlobalSourcePage
    /// Re-check native ownership/access on each read, including recalled hits.
    func read(_ source: GlobalSourceDescriptor) async throws -> GlobalSourceSnapshot
    func isAccessible(_ source: GlobalSourceDescriptor) async -> Bool
}
nonisolated struct GlobalSourceChunk: Codable, Sendable, Identifiable {
    var id: String
    var sourceID: String
    var revision: String
    var ordinal: Int
    var offset: Int
    var text: String
    var digest: String
    var vector: [Float]?
    var vectorModel: String?
    var vectorRevision: String?
}
nonisolated struct GlobalSourceHit: Codable, Sendable, Identifiable {
    var id: String
    var source: GlobalSourceDescriptor
    var excerpt: String
    var offset: Int
    var score: Double
    var semantic: Bool
    var sourceAvailable: Bool
    var layer = "sourceExcerpt"
}
nonisolated struct GlobalSourceSearchContext: Sendable {
    var workspaceID: UUID?
    var conversationID: UUID?
    var limit = 8
}
nonisolated struct GlobalSourceDerivedCandidate: Codable, Sendable {
    var content: String
    var quote: String
    var confidence: Double
    var stability: Double
    var importance: Double
    var sensitivity: MemorySensitivity
}
nonisolated struct GlobalSourceSummaryResult: Sendable { var candidates: [GlobalSourceDerivedCandidate] }
nonisolated enum GlobalSourceJobError: Error { case textModelUnavailable, localFallbackDisabled, sourceChanged, excluded, suppressed, invalidEvidence, unavailable }
nonisolated protocol GlobalSourceSummaryGenerator: Sendable {
    func summarize(_ source: GlobalSourceSnapshot, prior: [MemoryEntry]) async throws -> GlobalSourceSummaryResult
}
nonisolated struct GlobalSourceStatus: Sendable {
    var indexedSources = 0
    var indexedChunks = 0
    var pendingSummaries = 0
    var unavailableSources = 0
    var semanticModel: String?
    var semanticChinese = false
    var lastPass: Date?
    var paused = false
    var localTextFallback = false
}
nonisolated enum GlobalSourceTextPolicy {
    static func permittedName(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: "/").map(String.init)
        let blocked = Set(["credentials", "operations", ".ssh", ".aws", ".gnupg", "keychain", "node_modules", ".git", ".build"])
        return !parts.contains { blocked.contains($0) || $0.hasPrefix(".env") || $0.hasPrefix("id_rsa") || ["pem", "key", "p12", "pfx", "keystore"].contains(($0 as NSString).pathExtension) }
    }
    static func safeText(_ text: String) -> String {
        // Drop complete credential-bearing lines before any index or model request.
        let markers = ["authorization:", "bearer ", "password=", "password:", "token=", "api_key", "api-key", "secret=", "private key-----"]
        var pem = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let value = line.lowercased()
            if value.contains("-----begin"), value.contains("private key") { pem = true; return nil }
            if pem { if value.contains("-----end") { pem = false }; return nil }
            return markers.contains(where: value.contains) ? nil : String(line)
        }.joined(separator: "\n")
    }
    static func memoryID(source: String, content: String) -> UUID {
        let hex = Array(MemoryContentDigest.make(source + ":" + GlobalSourceIndexStore.suppressionDigest(content)).prefix(32))
        let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        return UUID(uuidString: value)!
    }
    static func chunks(_ snapshot: GlobalSourceSnapshot) -> [GlobalSourceChunk] {
        let text = Array(safeText(String(snapshot.text.prefix(1_000_000))))
        return stride(from: 0, to: text.count, by: 1_200).enumerated().map { ordinal, start in
            let body = String(text[start..<min(text.count, start + 1_400)]), digest = MemoryContentDigest.make(body)
            return .init(id: snapshot.source.id + ":\(ordinal)", sourceID: snapshot.source.id, revision: snapshot.source.revision,
                ordinal: ordinal, offset: start, text: body, digest: digest)
        }
    }
}
#endif
