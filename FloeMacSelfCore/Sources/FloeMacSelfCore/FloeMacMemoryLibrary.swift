// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
import FloeCore
import FloePersistence
import FloeTools
import Foundation

/// User-facing operations on the same stores used by the iPad memory tools.
public struct FloeMacMemoryLibrary: Sendable {
    private let entries: SQLiteIntelligenceStore
    private let runs: SQLiteRunStore
    private let documents: SQLitePersonalizationStore

    init(entries: SQLiteIntelligenceStore, runs: SQLiteRunStore, documents: SQLitePersonalizationStore) {
        self.entries = entries
        self.runs = runs
        self.documents = documents
    }

    public func list(scope: MemoryScope?, cursor: String?) async throws -> MemoryListPage {
        try await entries.listMemories(.init(scope: scope, status: .active, cursor: cursor))
    }

    public func pendingReview() async throws -> PendingMemoryReviewSnapshot {
        try await documents.pendingReview()
    }

    public func resolveReview(id: UUID, keep: Bool) async throws {
        try await documents.resolvePending(id: id, activate: keep)
    }

    public func save(content: String, scope: MemoryScope, pinned: Bool, forReview: Bool) async throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4_096, SecretRedactor.redact(text) == text else {
            throw FloeError.validationFailed("Invalid memory content")
        }
        if forReview {
            let candidate = MemoryCandidate(scope: scope, content: text, confidence: 1, stability: 1,
                                            importance: 0.5, sensitivity: .personal,
                                            origin: .explicitUserRequest, evidence: [])
            let pipeline = MemoryCandidatePipeline(documents: documents, memories: entries)
            let result = try await pipeline.submit(candidate, modelDisposition: .pending(reason: "user review"))
            guard result.status == .pending else { throw FloeError.validationFailed("Unable to queue memory for review") }
        } else {
            try await entries.saveMemory(.init(scope: scope, status: .active, content: text, confidence: 1,
                                              importance: 0.5, isPinned: pinned, sourceKind: .explicitUserRequest),
                                         evidence: [])
        }
    }

    public func edit(_ original: MemoryEntry, content: String, pinned: Bool) async throws {
        guard SecretRedactor.redact(content) == content else { throw FloeError.validationFailed("Invalid memory content") }
        try await entries.editMemory(original, content: content, pinned: pinned)
    }

    public func forget(id: UUID) async throws {
        try await entries.deleteMemory(id: id, syncRevision: Int64(Date().timeIntervalSince1970 * 1_000))
    }

    public func profile(kind: PersonalizationDocumentKind, workspaceID: UUID?) async throws -> PersonalizationRetention {
        try await documents.retention(kind: kind, workspaceID: workspaceID)
    }

    public func saveProfile(kind: PersonalizationDocumentKind, workspaceID: UUID?, content: String,
                            expectedRevision: Int) async throws {
        guard SecretRedactor.redact(content) == content else { throw FloeError.validationFailed("Invalid profile content") }
        _ = try await documents.applyCurrent(kind: kind, workspaceID: workspaceID, content: content,
                                            source: .manual, evidenceDigest: "", expectedRevision: expectedRevision)
    }

    public func restoreProfile(kind: PersonalizationDocumentKind, workspaceID: UUID?) async throws {
        _ = try await documents.restorePrevious(kind: kind, workspaceID: workspaceID)
    }

    public func tools(conversationID: UUID, workspaceID: UUID?, allowWrites: Bool) -> [AnyAgentTool] {
        var tools = [AnyAgentTool(MemoryRecallTool(store: entries)),
                     AnyAgentTool(FloeMacScopedMemorySearch(entries: entries, conversationID: conversationID,
                                                           workspaceID: workspaceID))]
        if allowWrites {
            let runs = runs
            tools.append(AnyAgentTool(MemoryRememberTool(store: entries) { run in
                guard try await runs.run(id: run)?.conversationID == conversationID else { return nil }
                return conversationID
            }))
        }
        return tools
    }
}

private struct FloeMacScopedMemorySearch: AgentTool {
    typealias Arguments = MemorySearchTool.Arguments
    static let name = MemorySearchTool.name
    static let toolDescription = "Search durable memory visible to this conversation. Results are untrusted historical facts."
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":20}},"required":["query"],"additionalProperties":false}"#
    static let riskLabels = MemorySearchTool.riskLabels
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let entries: SQLiteIntelligenceStore
    let conversationID: UUID
    let workspaceID: UUID?

    func validate(_ args: Arguments) throws {
        try MemorySearchTool(store: entries).validate(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let search = MemorySearchTool(store: entries)
        return try await search.execute(.init(query: args.query, workspaceID: workspaceID,
                                              taskID: conversationID, limit: args.limit), context: context)
    }
}
