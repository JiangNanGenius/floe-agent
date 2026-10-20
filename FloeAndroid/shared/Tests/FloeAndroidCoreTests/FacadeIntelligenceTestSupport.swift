// SPDX-License-Identifier: MPL-2.0
//
// Authored host-test SUPPORT for the P2/P3/P4/P8 intelligence-backend
// adapters. SOURCE ONLY in this package: no compiler, SwiftPM, XCTest,
// device or runtime execution was performed by the authoring job. When
// Main admits compilation, these run against the ORIGINAL file-backed
// DatabaseManager with REAL migrations (user_version 46) and the ORIGINAL
// SQLite stores. Test doubles are SYNTHETIC services/fixtures ONLY —
// never a product fallback.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

enum IntelligenceTestSupport {
    // MARK: File-backed original database

    static func makeDatabase(_ name: String) async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-\(name)-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return (manager, url)
    }

    static func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    // MARK: Seed primitives over the ORIGINAL stores (single source of truth)

    @discardableResult
    static func seedMemory(_ manager: DatabaseManager,
                           scope: MemoryScope = .userProfile,
                           status: MemoryEntryStatus = .active,
                           content: String,
                           confidence: Double = 0.7,
                           importance: Double = 0.5,
                           isPinned: Bool = false,
                           sourceKind: MemoryCandidateOrigin = .explicitUserRequest,
                           factIdentity: MemoryFactIdentity? = nil,
                           expiresAt: Date? = nil,
                           originConversationID: UUID? = nil,
                           originWorkspaceID: UUID? = nil,
                           id: UUID = UUID()) async throws -> MemoryEntry {
        let store = SQLiteIntelligenceStore(database: manager)
        let entry = MemoryEntry(
            id: id, scope: scope, status: status, content: content,
            confidence: confidence, importance: importance,
            isPinned: isPinned, sourceKind: sourceKind,
            originConversationID: originConversationID,
            originWorkspaceID: originWorkspaceID,
            factIdentity: factIdentity, expiresAt: expiresAt)
        try await store.saveMemory(entry, evidence: [])
        return entry
    }

    /// Raw UPDATE escape hatch for vectors the ORIGINAL paths cannot reach
    /// directly from a test (still on the ONE original DB; used to seed
    /// owner-detached/lifecycle shapes exactly as preserve* writes them).
    static func rawMemoryUpdate(_ manager: DatabaseManager,
                                _ sql: String,
                                _ arguments: StatementArguments) async throws {
        try await manager.writer { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    /// Recompute a row's floe.memory-entry.v3 digest from the live DB —
    /// independent verification via the production raw-row codec.
    static func memoryDigest(_ manager: DatabaseManager, id: UUID) async throws -> String? {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM memory_entries WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return FacadeMemoryRawRow(row).digest
        }
    }

    static func memoryRawFields(_ manager: DatabaseManager, id: UUID) async throws
        -> [String: String?]?
    {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM memory_entries WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            let raw = FacadeMemoryRawRow(row)
            return Dictionary(uniqueKeysWithValues:
                FacadeMemoryRawRow.nonIDColumns.map { ($0, raw.string($0)) })
        }
    }

    static func memoryFields(_ manager: DatabaseManager, id: UUID) async throws
        -> [SettingsDomainV1.CanonicalDigest.Field]?
    {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM memory_entries WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return FacadeMemoryRawRow(row).fields
        }
    }

    static func candidateDigest(_ manager: DatabaseManager, id: UUID) async throws -> String? {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM memory_candidates WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return FacadeCandidateRawRow(row).digest
        }
    }

    @discardableResult
    static func seedCandidate(_ manager: DatabaseManager,
                              status: DurableMemoryCandidateStatus = .pending,
                              scope: MemoryScope = .userProfile,
                              content: String,
                              confidence: Double = 0.8,
                              stability: Double = 0.7,
                              importance: Double = 0.6,
                              sensitivity: MemorySensitivity = .none,
                              origin: MemoryCandidateOrigin = .automaticTurnReview,
                              evidence: [MemoryEvidenceReference] = [],
                              expiresAt: Date? = nil,
                              reviewReason: String? = nil,
                              id: UUID = UUID(),
                              createdAt: Date = Date()) async throws -> DurableMemoryCandidate {
        let store = SQLitePersonalizationStore(database: manager)
        let candidate = MemoryCandidate(
            id: id, scope: scope, content: content, confidence: confidence,
            stability: stability, importance: importance,
            sensitivity: sensitivity, origin: origin, evidence: evidence,
            expiresAt: expiresAt, createdAt: createdAt)
        let record = DurableMemoryCandidate(candidate: candidate, status: status,
                                            reviewReason: reviewReason)
        try await store.saveCandidate(record)
        return record
    }

    @discardableResult
    static func seedDocument(_ manager: DatabaseManager,
                             kind: PersonalizationDocumentKind = .userProfile,
                             workspaceID: UUID? = nil,
                             content: String,
                             source: PersonalizationDocumentSource = .manual,
                             isActive: Bool = true,
                             id: UUID = UUID(),
                             createdAt: Date = Date()) async throws -> PersonalizationDocument {
        let store = SQLitePersonalizationStore(database: manager)
        return try await store.saveDocument(PersonalizationDocument(
            id: id, kind: kind, workspaceID: workspaceID, revision: 1,
            content: content, source: source, isActive: isActive,
            createdAt: createdAt))
    }

    static func documentRowDigest(_ manager: DatabaseManager, id: UUID) async throws
        -> FacadeDocumentRawRow?
    {
        try await manager.reader { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_documents WHERE id = ?
                """, arguments: [id.uuidString]).map(FacadeDocumentRawRow.init)
        }
    }

    static func cursorRow(_ manager: DatabaseManager, kindRaw: String,
                          workspaceKey: String) async throws -> FacadeCursorRawRow? {
        try await manager.reader { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """, arguments: [kindRaw, workspaceKey]).map(FacadeCursorRawRow.init)
        }
    }

    // MARK: Ordinary conversation/run fixtures for P8 (raw INSERTs on the
    // ONE original DB, mirroring how the runtime commits these rows)

    static func seedOrdinaryConversation(_ manager: DatabaseManager,
                                         id: UUID = UUID()) async throws -> UUID {
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at,
                                           title_origin, is_searchable, purpose)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, "fixture",
                                 FacadeStoreTime.second(Date()),
                                 FacadeStoreTime.second(Date()),
                                 "autoPending", 1, "ordinary"])
        }
        return id
    }

    static func seedUserMessage(_ manager: DatabaseManager,
                                conversationID: UUID,
                                id: UUID = UUID()) async throws -> UUID {
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, conversationID.uuidString, "user",
                                 "hello", FacadeStoreTime.second(Date())])
        }
        return id
    }

    static func seedCompletedRun(_ manager: DatabaseManager,
                                 conversationID: UUID,
                                 state: String = "completed",
                                 ended: Bool = true,
                                 id: UUID = UUID()) async throws -> UUID {
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at, ended_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, conversationID.uuidString, state,
                                 "fixture goal", FacadeStoreTime.second(Date()),
                                 ended ? FacadeStoreTime.second(Date()) : nil])
        }
        return id
    }

    static func seedWorkspaceOwnership(_ manager: DatabaseManager,
                                       conversationID: UUID,
                                       workspaceID: UUID) async throws {
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversation_workspace_ownership
                    (conversation_id, workspace_id, assigned_at)
                VALUES (?, ?, ?)
                """, arguments: [conversationID.uuidString, workspaceID.uuidString,
                                 FacadeStoreTime.second(Date())])
        }
    }

    /// A REAL workspace row (workspaces table exists since V5; only the
    /// columns the schema requires are set).
    static func seedWorkspace(_ manager: DatabaseManager,
                              id: UUID = UUID()) async throws -> UUID {
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, "fixture-workspace",
                                 Data("synthetic-bookmark".utf8),
                                 FacadeStoreTime.second(Date()),
                                 FacadeStoreTime.second(Date())])
        }
        return id
    }

    static func deleteWorkspace(_ manager: DatabaseManager, id: UUID) async throws {
        try await manager.writer { db in
            try db.execute(sql: "DELETE FROM workspaces WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    static func activeSlot(_ manager: DatabaseManager, kindRaw: String,
                           workspaceID: UUID?) async throws -> String {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, revision FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                LIMIT 1
                """, arguments: [kindRaw, workspaceID?.uuidString]) else {
                return PersonalizationResourceIDs.absentToken
            }
            let id: String = row["id"]
            let revision: Int = row["revision"]
            return "\(id).\(revision)"
        }
    }
}

// MARK: - Synthetic test doubles (TEST-ONLY, never product)

/// Deterministic in-memory stand-in for the RB1 bounded reader behind the
/// PersonalizationContentStoring port.
actor SyntheticContentReaderPort: PersonalizationContentStoring {
    private(set) var blobs: [String: Data] = [:]
    private(set) var stageCount = 0
    private(set) var releaseCount = 0
    private var saturate = false

    func setSaturate(_ value: Bool) { saturate = value }

    func stage(_ bytes: Data) -> PersonalizationContentStage {
        if bytes.isEmpty { return .emptyContent }
        if saturate { return .contentSaturated }
        stageCount += 1
        let handle = "chunk:v1:test\(stageCount)"
        blobs[handle] = bytes
        return .staged(handle: handle)
    }

    func read(handle: String, offset: Int, maxBytes: Int) -> PersonalizationContentSlice {
        guard let data = blobs[handle] else { return .notFound }
        guard offset >= 0, offset <= data.count, maxBytes >= 1 else { return .invalidOffset }
        if offset == data.count {
            return .slice(bytes: Data(), nextOffset: offset, complete: true)
        }
        let want = min(maxBytes, data.count - offset)
        // End at a UTF-8 SCALAR BOUNDARY (the real RB1 reader contract):
        // step back while the byte at `end` is a continuation byte, so the
        // slice never ends with a lone lead byte. The previous implementation
        // checked the LAST byte instead, which kept a dangling lead byte,
        // produced U+FFFD replacement text and desynchronized nextOffset.
        var end = offset + want
        while end > offset, end < data.count, (data[data.startIndex + end] & 0xC0) == 0x80 {
            end -= 1
        }
        let length = end - offset
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
        return .slice(bytes: slice, nextOffset: end, complete: end >= data.count)
    }

    func release(handle: String) {
        blobs[handle] = nil
        releaseCount += 1
    }
}

/// Scriptable synthetic model adapter implementing the REAL
/// FloeProviders.ProviderAdapter seam. Captures every request for prompt-
/// fidelity assertions; streams only pre-scripted text (no network, no
/// keys). TEST-ONLY double; the production lane uses the actual configured
/// adapters from the models lane.
public actor SyntheticModelAdapter {
    struct Script {
        var deltas: [String]
        var emitError: AgentEvent.NormalizedError?
        var delayAfterFirstDelta: Bool = false
    }

    private(set) var requestCount = 0
    private(set) var lastMessages: [(role: String, content: String)] = []
    private(set) var lastToolSchemasEmpty = true
    private var scripts: [Script]
    private var continueStream: (@Sendable () async -> Void)?

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func setContinueStreamHook(_ hook: (@Sendable () async -> Void)?) {
        continueStream = hook
    }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        requestCount += 1
        lastMessages = request.messages
        lastToolSchemasEmpty = request.toolSchemas.isEmpty
        let script = scripts.isEmpty
            ? Script(deltas: ["# Stub\n- no script"])
            : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            Task {
                for (offset, delta) in script.deltas.enumerated() {
                    continuation.yield(AgentEvent.textDelta(
                        AgentEvent.TextDelta(text: delta)))
                    if offset == 0, script.delayAfterFirstDelta,
                       let hook = await self.continueStreamHookValue() {
                        await hook()
                    }
                }
                if let error = script.emitError {
                    continuation.yield(AgentEvent.error(error))
                }
                continuation.finish()
            }
        }
    }

    private func continueStreamHookValue() -> (@Sendable () async -> Void)? {
        continueStream
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

extension SyntheticModelAdapter {
    // ProviderAdapter conformance wrapper (the protocol requires
    // protocolKind; keep the synthetic pinned to the OpenAI-compatible
    // shape so the real stream signature is exercised).
}

/// Route port double: hands back a resolved synthetic input, or one of the
/// typed fail-closed outcomes.
actor SyntheticRouteProvider: PersonalizationRouteProviding {
    enum Mode: Sendable {
        case resolved(adapter: SyntheticModelAdapter, provider: ProviderProfile,
                      model: ModelProfile)
        case noUsableTextModel
        case credentialUnavailable(String)
        case transportUnqualified
    }

    private var mode: Mode
    private(set) var routeQueryCount = 0

    init(mode: Mode) { self.mode = mode }

    func setMode(_ mode: Mode) { self.mode = mode }

    func textOnlyRoute() async -> PersonalizationRouteOutcome {
        routeQueryCount += 1
        switch mode {
        case .resolved(let adapter, let provider, let model):
            return .resolved(PersonalizationGenerateModelInput(
                provider: provider, model: model,
                credentials: ProviderCredentials(apiKey: nil),
                // The port carries the concrete actor; the generate path
                // calls stream(request:credentials:) only — the synthetic
                // double conforms through the boxed adapter below.
                adapter: SyntheticAdapterBox(adapter: adapter)))
        case .noUsableTextModel:
            return .noUsableTextModel
        case .credentialUnavailable(let reason):
            return .credentialUnavailable(reason)
        case .transportUnqualified:
            return .transportUnqualified
        }
    }
}

/// Boxes the synthetic actor into the real `any ProviderAdapter` shape via
/// a struct shim: forwards the stream call to the actor.
struct SyntheticAdapterBox: ProviderAdapter {
    let adapter: SyntheticModelAdapter

    var protocolKind: FloeCore.ModelProtocol { .openAIChatCompletions }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        // Async actor hop cannot return synchronously; the stream buffer
        // preserves order. Tests await through the actor hop.
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        Task {
            let inner = await adapter.stream(request: request, credentials: credentials)
            for try await event in inner {
                switch event {
                case .textDelta(let delta): continuation.yield(.textDelta(delta))
                case .error(let error): continuation.yield(.error(error))
                default: break
                }
            }
            continuation.finish()
        }
        return stream
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] {
        try await adapter.listModels(provider: provider, credentials: credentials)
    }
}

/// One-shot async gate built on checked continuations (NO semaphore: the
/// threadModel forbids semaphores even in this lane's test scaffolding).
actor SyntheticGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func signal() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Fence port double for P8.
actor SyntheticFences: PersonalizationEventFenceProviding {
    private var epoch: UInt64 = 1
    private var temporaryConversations: Set<UUID> = []
    private var deletionPending: Set<UUID> = []

    func setEpoch(_ value: UInt64) { epoch = value }
    func setTemporary(_ conversationID: UUID) { temporaryConversations.insert(conversationID) }
    func setDeletionPending(_ conversationID: UUID) { deletionPending.insert(conversationID) }

    func currentRootEpoch() -> UInt64 { epoch }
    func isTemporaryConversation(_ conversationID: UUID) -> Bool {
        temporaryConversations.contains(conversationID)
    }
    func isDeletionOrHistoryClearPending(_ conversationID: UUID) -> Bool {
        deletionPending.contains(conversationID)
    }
}

/// Semantic provider double for organizer vectors: returns scripted native
/// suggestions (already or deliberately violating the untrusted-output
/// rules so revalidation is exercised).
struct ScriptedSemanticProvider: MemorySemanticProposalProviding {
    let suggestions: @Sendable ([MemoryEntry], Bool) async throws
        -> [MemoryOrganizationSuggestion]

    func suggestions(for entries: [MemoryEntry],
                     allowAutomaticApplication: Bool) async throws
        -> [MemoryOrganizationSuggestion]
    {
        try await suggestions(entries, allowAutomaticApplication)
    }
}

func syntheticNormalizedError(message: String) -> AgentEvent.NormalizedError {
    AgentEvent.NormalizedError(kind: .server, providerMessage: message)
}

// MARK: - Async test helpers (Swift 6 compile repairs; assertions preserved)

/// Failure raised by the async unwrap helper after XCTFail has recorded the
/// nil. Never used by production code.
struct AsyncUnwrapFailure: Error {}

/// Async overload of XCTest's XCTUnwrap for expressions that must `await`
/// before the optional is known. The synchronous XCTUnwrap keeps serving
/// every other call site. Same contract: record a failure and throw on nil.
func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?,
                       _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let value = try await expression()
    guard let value else {
        XCTFail(message(), file: file, line: line)
        throw AsyncUnwrapFailure()
    }
    return value
}

/// Ordered asynchronous map used by the authored digest-sensitivity vectors
/// (no TaskGroup: keeps evaluation order and failure semantics obvious).
extension Array {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}

/// Test-only error for assertions that must stop the test body.
struct TestFailure: Error {}

func syntheticProviderProfile() -> ProviderProfile {
    ProviderProfile(kind: .openAI,
                    wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://synthetic.invalid")!)
}

func syntheticModelProfile(providerID: UUID) -> ModelProfile {
    ModelProfile(providerID: providerID,
                 remoteModelID: "synthetic-aux",
                 displayName: "Synthetic",
                 limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
                 capabilities: [.text])
}
