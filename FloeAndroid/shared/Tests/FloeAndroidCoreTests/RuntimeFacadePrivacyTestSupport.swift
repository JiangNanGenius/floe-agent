// SPDX-License-Identifier: MPL-2.0
//
// Privacy clear lane test support — the REAL file-backed original database
// plus explicit TEST-ONLY owner doubles. (Authored source; NOT executed by
// this lane.)
//
// * `PrivacyTestBed` opens the ORIGINAL DatabaseManager on a file path and
//   migrates through the ORIGINAL pinned chain (schema 46), with same-path
//   reopen for durable-queue recoverability.
// * Every double implements the SAME typed port the production adapter
//   implements; no double replaces a production default implicitly.
// * The durable tables and triggers are the REAL schema, so cascade,
//   memory-preservation and V11/V36 behaviour are measured on real SQLite.
// * Synthetic fixtures only: no real grants, secrets or user data.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime
import FloeProviders
import FloeTools
@testable import FloeAndroidCore

enum PrivacyTestBed {
    struct FixtureError: Error { let detail: String
        init(_ detail: String) { self.detail = detail } }

    static func openMigrated(name: String) async throws -> (DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloePrivacyTests-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let manager = try DatabaseManager(
            path: root.appendingPathComponent("floe.sqlite"))
        try await manager.migrate()
        let version = try await manager.userVersion()
        guard version == DatabaseManager.currentSchemaVersion else {
            throw FixtureError("fixture must migrate to \(DatabaseManager.currentSchemaVersion), got \(version)")
        }
        return (manager, root)
    }

    struct Stores {
        let database: DatabaseManager
        let directory: URL
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let workspaces: SQLiteWorkspaceStore
        let intelligence: SQLiteIntelligenceStore
    }

    static func stores(name: String = UUID().uuidString) async throws -> Stores {
        let (database, directory) = try await openMigrated(name: name)
        return Stores(database: database, directory: directory,
                      conversations: SQLiteConversationStore(database: database),
                      runs: SQLiteRunStore(database: database),
                      workspaces: SQLiteWorkspaceStore(database: database),
                      intelligence: SQLiteIntelligenceStore(database: database))
    }

    static func reopen(_ stores: Stores) async throws -> Stores {
        try await stores.database.close()
        let manager = try DatabaseManager(
            path: stores.directory.appendingPathComponent("floe.sqlite"))
        try await manager.migrate()
        return Stores(database: manager, directory: stores.directory,
                      conversations: SQLiteConversationStore(database: manager),
                      runs: SQLiteRunStore(database: manager),
                      workspaces: SQLiteWorkspaceStore(database: manager),
                      intelligence: SQLiteIntelligenceStore(database: manager))
    }

    static func count(_ database: DatabaseManager, _ sql: String,
                      _ arguments: StatementArguments = StatementArguments())
        async throws -> Int
    {
        try await database.reader { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    // MARK: Synthetic seeds

    static func seedConversation(_ stores: Stores, id: UUID = UUID(),
                                 title: String = "task",
                                 purpose: String = "ordinary",
                                 archived: Bool = false) async throws -> UUID {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at,
                                               title_origin, purpose, archived_at)
                    VALUES (?, ?, '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z',
                            'autoPending', ?, ?)
                    """,
                arguments: [id.uuidString, title, purpose,
                            archived ? "2026-10-19T01:00:00Z" : nil])
        }
        return id
    }

    static func seedRun(_ stores: Stores, id: UUID = UUID(),
                        conversationID: UUID, state: String = "completed",
                        startedAt: String = "2026-10-19T00:00:00Z",
                        endedAt: String? = "2026-10-19T00:05:00Z")
        async throws -> UUID
    {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal,
                                      started_at, ended_at)
                    VALUES (?, ?, ?, 'goal', ?, ?)
                    """,
                arguments: [id.uuidString, conversationID.uuidString, state,
                            startedAt, endedAt])
        }
        return id
    }

    /// Seeds ONLY the workspace row (no ownership binding): for FK targets
    /// an UPDATE binds without a primary-key ownership conflict.
    static func seedWorkspace(_ stores: Stores, workspaceID: UUID,
                              conversationID: UUID) async throws {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO workspaces (
                        id, name, root_bookmark, last_opened_at,
                        active_target_kind, active_target_host_id,
                        inspector_state_json, instructions_rel_path,
                        created_at, updated_at, kind, internal_relative_path
                    ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}', NULL,
                              '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z',
                              'privateTask', ?)
                    """,
                arguments: [workspaceID.uuidString, "ws-\(workspaceID.uuidString)",
                            Data(), "PrivateTasks/\(conversationID.uuidString)"])
        }
    }

    static func seedOwnership(_ stores: Stores, conversationID: UUID,
                              workspaceID: UUID) async throws {
        try await stores.database.writer { db in
            // The ownership FK requires the workspace row to exist (the
            // real stores insert workspaces first).
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO workspaces (
                        id, name, root_bookmark, last_opened_at,
                        active_target_kind, active_target_host_id,
                        inspector_state_json, instructions_rel_path,
                        created_at, updated_at, kind, internal_relative_path
                    ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}', NULL,
                              '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z',
                              'privateTask', ?)
                    """,
                arguments: [workspaceID.uuidString, "ws-\(workspaceID.uuidString)",
                            Data(), "PrivateTasks/\(conversationID.uuidString)"])
            try db.execute(
                sql: """
                    INSERT INTO conversation_workspace_ownership
                        (conversation_id, workspace_id, assigned_at)
                    VALUES (?, ?, '2026-10-19T00:00:00Z')
                    """,
                arguments: [conversationID.uuidString, workspaceID.uuidString])
        }
    }

    static func seedPersistedGrant(_ stores: Stores, id: UUID = UUID(),
                                   toolName: String = "files.read",
                                   policyName: String = "policy.a",
                                   pathsJSON: String = "[]",
                                   workspaceID: UUID? = nil,
                                   hostID: UUID? = nil) async throws -> UUID {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO approval_grants (id, workspace_id, host_id,
                        tool_name, paths_json, single_use, policy_name,
                        decided_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, 1, ?, '2026-10-19T00:00:00Z', NULL)
                    """,
                arguments: [id.uuidString, workspaceID?.uuidString,
                            hostID?.uuidString, toolName, pathsJSON, policyName])
        }
        return id
    }

    static func seedProvider(_ stores: Stores, id: UUID = UUID(),
                             secretAccount: String? = nil,
                             synchronizable: Bool = false,
                             syncRevision: Int64 = 0,
                             kind: String = "openaiCompatible",
                             displayName: String? = nil) async throws -> UUID {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO providers (id, kind, wire_protocol, base_url,
                        secret_ref_account, secret_ref_synchronizable, region,
                        non_secret_headers_json, display_name, is_enabled,
                        allows_plain_http, tool_name_compatibility,
                        created_at, updated_at, sync_revision)
                    VALUES (?, ?, 'https', 'https://example.invalid', ?, ?, NULL,
                            '{}', ?, 1, 0, 0,
                            '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z', ?)
                    """,
                arguments: [id.uuidString, kind, secretAccount,
                            synchronizable ? 1 : nil, displayName, syncRevision])
        }
        return id
    }

    static func seedModel(_ stores: Stores, id: UUID = UUID(),
                          providerID: UUID,
                          remoteModelID: String = "model-a",
                          pricingJSON: String? = nil) async throws -> UUID {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO models (id, provider_id, remote_model_id,
                        display_name, context_tokens, max_output_tokens,
                        pricing_json, capabilities, is_enabled)
                    VALUES (?, ?, ?, 'Model', 1000, 500, ?, 1, 1)
                    """,
                arguments: [id.uuidString, providerID.uuidString,
                            remoteModelID, pricingJSON])
        }
        return id
    }

    static func seedMemory(_ stores: Stores, id: UUID = UUID(),
                           conversationID: UUID, content: String = "memory")
        async throws -> UUID
    {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO memory_entries (id, scope, workspace_id, status,
                        content, normalized_content, confidence, importance,
                        is_pinned, source_kind, sync_revision, created_at,
                        updated_at, conversation_id, origin_workspace_id,
                        origin_conversation_id, origin_owner_label,
                        owner_deleted_at, last_recalled_at, retained_until,
                        recall_count, subject_key, attribute_key)
                    VALUES (?, 'task', NULL, 'active', ?, ?, 0.5, 0.5, 0,
                            'conversation', 0, '2026-10-19T00:00:00Z',
                            '2026-10-19T00:00:00Z', ?, NULL, NULL, NULL, NULL,
                            NULL, NULL, 0, NULL, NULL)
                    """,
                arguments: [id.uuidString, content, content.lowercased(),
                            conversationID.uuidString])
        }
        return id
    }
}

// MARK: - Deterministic clock

final class PrivacyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_761_000_000)) {
        self.value = value
    }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

// MARK: - Controlled doubles

actor FakeInMemoryGrantStore: PrivacyInMemoryGrantStore {
    private var grants: [UUID: ApprovalGrant] = [:]
    /// Mutations applied on a specific 1-based read index, so a test can
    /// change the set BETWEEN g1 and g2 and prove the bracket/retry.
    private var mutations: [Int: ApprovalGrant] = [:]
    private var removals: [Int: UUID] = [:]
    private var reads = 0

    init(grants: [ApprovalGrant] = []) {
        for grant in grants { self.grants[grant.id] = grant }
    }

    func mutate(onRead index: Int, insert grant: ApprovalGrant) {
        mutations[index] = grant
    }

    func remove(onRead index: Int, id: UUID) { removals[index] = id }

    func snapshotGrants() async throws -> [ApprovalGrant] {
        reads += 1
        if let grant = mutations[reads] { grants[grant.id] = grant }
        if let id = removals[reads] { grants.removeValue(forKey: id) }
        return grants.values.sorted { $0.decidedAt < $1.decidedAt }
    }

    func revokeGrant(id: UUID) { grants.removeValue(forKey: id) }
    func insert(_ grant: ApprovalGrant) { grants[grant.id] = grant }
    func currentIDs() -> [UUID] { Array(grants.keys) }
}

actor ScriptedGlobalFence: PrivacyGlobalAdmissionFencing {
    struct Call: Equatable { let kind: String; let committed: Bool? }
    private(set) var calls: [Call] = []
    private var current: GlobalAdmissionFenceToken?
    private var generation: UInt64 = 0
    private var epoch: UInt64
    private var refuseWhenFenced: Bool
    /// Runs while the fence is held and BEFORE the clear snapshot; lets a
    /// test model concurrent work at the documented boundary.
    var onAwaitSettled: (@Sendable () async -> Void)?

    init(epoch: UInt64 = 1, refuseWhenFenced: Bool = true) {
        self.epoch = epoch
        self.refuseWhenFenced = refuseWhenFenced
    }

    func setOnAwaitSettled(_ body: (@Sendable () async -> Void)?) {
        onAwaitSettled = body
    }

    func beginGlobalAdmissionFence(expectedEpoch: UInt64) throws
        -> GlobalAdmissionFenceToken
    {
        calls.append(.init(kind: "begin", committed: nil))
        guard expectedEpoch == epoch else {
            throw PrivacyDomainError.sessionFenced("generationRetired")
        }
        if refuseWhenFenced, current != nil {
            throw PrivacyDomainError.duplicateInFlight
        }
        generation &+= 1
        let token = GlobalAdmissionFenceToken(epoch: epoch,
                                              generation: generation)
        current = token
        return token
    }

    func awaitPendingLaunchesSettled(expectedEpoch: UInt64) async throws {
        calls.append(.init(kind: "awaitSettled", committed: nil))
        guard expectedEpoch == epoch else {
            throw PrivacyDomainError.sessionFenced("generationRetired")
        }
        await onAwaitSettled?()
    }

    func finishGlobalAdmissionFence(_ token: GlobalAdmissionFenceToken,
                                    committed: Bool) async -> Bool {
        calls.append(.init(kind: "finish", committed: committed))
        guard current == token else { return false }
        current = nil
        return true
    }

    func isFencedNow() -> Bool { current != nil }
}

actor ScriptedDeletionLifecycle: ConversationDeletionLifecycle {
    struct Entry: Equatable {
        let kind: String
        let conversationID: UUID
        let operationID: UUID
    }
    private(set) var entries: [Entry] = []
    private var refuse: Set<UUID> = []
    private var failDrain: Set<UUID> = []
    private var emptyReceipt = false
    var onDrain: (@Sendable () -> Void)?

    func refuseFence(_ id: UUID) { refuse.insert(id) }
    func failDrainFor(_ id: UUID) { failDrain.insert(id) }
    func setReceiptEmpty(_ value: Bool) { emptyReceipt = value }

    func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                            operationID: UUID) async throws
        -> ConversationDeletionFence
    {
        entries.append(.init(kind: "begin", conversationID: conversationID,
                             operationID: operationID))
        if refuse.contains(conversationID) {
            throw ConversationDeletionLifecycleFailure.fenceHeld
        }
        return ConversationDeletionFence(
            conversationID: conversationID, epoch: epoch,
            operationID: operationID,
            authorityReceipt: emptyReceipt ? "" : "authority:\(operationID.uuidString)")
    }

    func drainOwnedWork(fence: ConversationDeletionFence) async throws
        -> ConversationQuiescenceReport
    {
        entries.append(.init(kind: "drain", conversationID: fence.conversationID,
                             operationID: fence.operationID))
        onDrain?()
        if failDrain.contains(fence.conversationID) {
            throw ConversationDeletionLifecycleFailure.drainUnavailable(
                "scriptedDrainFailure")
        }
        return ConversationQuiescenceReport(
            conversationID: fence.conversationID,
            launchesFenced: true,
            inFlightLaunchesAwaited: 0,
            runServicesCancelled: 0,
            ownedTasksDrained: 0,
            childRunsReconciled: 0,
            endCountsByKind: ["run": 0],
            countsEpoch: fence.epoch,
            targetOwnedWork: [],
            pendingLaunchCount: 0)
    }

    func abortDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
    {
        entries.append(.init(kind: "abort", conversationID: fence.conversationID,
                             operationID: fence.operationID))
        return .released
    }

    func commitDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
    {
        entries.append(.init(kind: "commit", conversationID: fence.conversationID,
                             operationID: fence.operationID))
        return .released
    }
}

actor FakeSecretOrdering: PrivacySecretDeletionOrdering {
    struct Record: Equatable { let kind: String; let account: String }
    private(set) var records: [Record] = []
    private var registered: Bool
    private var failDelete: Set<String> = []
    private var failEnqueue: Set<String> = []
    private var queue: [String: String] = [:]
    var nextOutcome: PrivacySecretDeletionOutcome?

    init(registered: Bool) { self.registered = registered }

    func setRegistered(_ value: Bool) { registered = value }
    func failDeleteFor(_ account: String) { failDelete.insert(account) }
    func failEnqueueFor(_ account: String) { failEnqueue.insert(account) }
    func setNextOutcome(_ outcome: PrivacySecretDeletionOutcome?) {
        nextOutcome = outcome
    }

    func hasRegisteredGateway() async -> Bool { registered }
    func credentialAvailability() async -> PrivacyCredentialAvailability {
        registered ? .available : .needsConfiguration
    }

    func enqueuePendingDeletion(account: String,
                                synchronizable: Bool) async throws -> String {
        records.append(.init(kind: "enqueue", account: account))
        if failEnqueue.contains(account) {
            throw PrivacyDomainError.persistenceUnavailable("enqueueFailed")
        }
        let generation = "gen-\(queue.count + 1)"
        queue[account] = generation
        return generation
    }

    func deleteSecret(reference: String) async throws
        -> PrivacySecretDeletionOutcome {
        records.append(.init(kind: "delete", account: reference))
        if failDelete.contains(reference) {
            throw PrivacyDomainError.runtimeUnavailable("gatewayDeleteFailed")
        }
        if let nextOutcome {
            self.nextOutcome = nil
            return nextOutcome
        }
        return PrivacySecretDeletionOutcome(settled: true)
    }

    func completeDeletion(account: String, generation: String) async throws {
        records.append(.init(kind: "complete", account: account))
        guard queue[account] == generation else {
            throw PrivacyDomainError.persistenceUnavailable(
                "queueGenerationAdvanced")
        }
        queue[account] = nil
    }

    func recordDeletionFailure(account: String, generation: String,
                               message: String) async throws {
        records.append(.init(kind: "recordFailure", account: account))
    }

    func queuedAccounts() -> [String] { queue.keys.sorted() }
}

actor FakeProviderOperations: PrivacyProviderOperationOwning {
    private var conflicts: Set<UUID> = []
    private(set) var began: [UUID] = []
    private(set) var ended: [UUID] = []
    private(set) var parked: [UUID] = []
    private var claimCounter = 0

    func conflict(_ id: UUID) { conflicts.insert(id) }

    func beginOperation(providerID: UUID,
                        kind: ProviderOperationKind) async
        -> ProviderOperationBeginOutcome
    {
        began.append(providerID)
        if conflicts.contains(providerID) { return .conflict }
        claimCounter += 1
        return .attached(ProviderOperationTicket(
            providerID: providerID, kind: kind, claimID: UUID()))
    }

    func endOperation(_ ticket: ProviderOperationTicket) async {
        ended.append(ticket.providerID)
    }

    func parkPending(_ ticket: ProviderOperationTicket,
                     receipt: PhysicalOperationReceipt?,
                     witness: (any PhysicalObservingSecretGateway)?) async -> Bool {
        parked.append(ticket.providerID)
        return true
    }
}

/// A real witness double for the physical-claim tests.
final class FakeObservingGateway: PhysicalObservingSecretGateway, @unchecked Sendable {
    func readObserved(reference: String,
                      onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws -> Data? { nil }
    func writeObserved(reference: String, value: Data,
                       onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws {}
    func deleteObserved(reference: String,
                        onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws {}
    func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        .claimedOutstanding
    }
    func resolvePhysical(claim: Int64) -> Bool { true }
    func awaitPhysicalSettlement(claim: Int64) async
        -> PhysicalOperationSnapshot { .claimedOutstanding }
}

final class FakeOwnedWork: PrivacyOwnedWorkOwning, @unchecked Sendable {
    private let lock = NSLock()
    private var attached: Set<String> = []
    private var next = 0
    private(set) var attaches = 0
    private(set) var detaches = 0
    var refuse = false

    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkToken? {
        lock.lock(); defer { lock.unlock() }
        attaches += 1
        guard !refuse else { return nil }
        next += 1
        let raw = String(next, radix: 16)
        let receipt = "work:v1:" + String(repeating: "0",
                                          count: max(0, 32 - raw.count)) + raw
        attached.insert(receipt)
        return RuntimeOwnedWorkToken(receipt: receipt, epoch: epoch,
                                     kind: kind, ownerID: ownerID)
    }

    func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        detaches += 1
        return attached.remove(token.receipt) != nil
    }
}

actor FakeCredentialDrain: ConversationCredentialDeletionDraining {
    private(set) var drainCount = 0
    func drainDeletionQueue() async -> CredentialDeletionDrainSummary {
        drainCount += 1
        return CredentialDeletionDrainSummary(drained: 0, deferredCount: 0,
                                              failedCount: 0)
    }
}

actor FakeWorkspaceCleaning: ConversationOwnedWorkspaceCleaning {
    private(set) var removed: [String] = []
    func removePrivateTaskDirectory(relativePath: String) async throws {
        removed.append(relativePath)
    }
}

struct FailingPersistedGrants: PrivacyPersistedGrantStore {
    let store: SQLiteWorkspaceStore
    let failing: Set<UUID>
    func deleteGrant(id: UUID) async throws {
        if failing.contains(id) {
            throw PrivacyDomainError.persistenceUnavailable("scriptedGrantFailure")
        }
        try await store.deleteGrant(id: id)
    }
}

// MARK: - Minimal runtime doubles (actual runtime grant adapter surface)

/// A silent provider adapter: the grant-adapter tests never start a run,
/// so no stream is ever requested.
struct SilentProviderAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIChatCompletions

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        []
    }
}

/// A tool executor double with an empty catalog: it exists only so the
/// runtime initializer is complete; no tool ever runs in these tests.
struct NoopToolExecutor: ToolExecutor {
    func execute(
        _ call: ToolCall,
        context: ToolContext
    ) async throws -> ToolResult {
        ToolResult(callID: call.id, status: .ok,
                   outputSummary: "", outputDigest: "")
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
}

// MARK: - Facade assembly

struct PrivacyFacadeAssembly {
    let facade: RuntimeFacadePrivacy
    let stores: PrivacyTestBed.Stores
    let inMemory: FakeInMemoryGrantStore
    let fence: ScriptedGlobalFence
    let lifecycle: ScriptedDeletionLifecycle
    let secrets: FakeSecretOrdering
    let operations: FakeProviderOperations
    let owned: FakeOwnedWork
    let host: PrivacyHostConfirmationStore
    let reportStore: PrivacyReportStore
    let clock: PrivacyTestClock
    let rootToken: String
}

enum PrivacyFacadeFactory {
    static func make(
        stores: PrivacyTestBed.Stores,
        inMemory: FakeInMemoryGrantStore = FakeInMemoryGrantStore(),
        fence: ScriptedGlobalFence = ScriptedGlobalFence(),
        lifecycle: ScriptedDeletionLifecycle = ScriptedDeletionLifecycle(),
        bindLifecycle: Bool = true,
        bindOwnedWork: Bool = true,
        secrets: FakeSecretOrdering = FakeSecretOrdering(registered: true),
        operations: FakeProviderOperations = FakeProviderOperations(),
        owned: FakeOwnedWork = FakeOwnedWork(),
        workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)? = nil,
        persistedGrants: (any PrivacyPersistedGrantStore)? = nil,
        secretOrdering: (any PrivacySecretDeletionOrdering)? = nil,
        bindSecretOrdering: Bool = true,
        credentialDrain: (any ConversationCredentialDeletionDraining)? = nil,
        epoch: UInt64 = 1,
        faultInjection: (@Sendable (String) async throws -> Void)? = nil
    ) -> PrivacyFacadeAssembly {
        let clock = PrivacyTestClock()
        let rootToken = PrivacyRootIdentity.token(rootPath: stores.directory.path)
        let host = PrivacyHostConfirmationStore(root: rootToken, epoch: epoch,
                                                clock: { clock.now })
        let reportStore = PrivacyReportStore(rootPath: stores.directory.path)
        let engine = PrivacySnapshotEngine(database: stores.database,
                                           inMemoryGrants: inMemory,
                                           rootPath: stores.directory.path,
                                           epoch: epoch)
        let facade = RuntimeFacadePrivacy(
            database: stores.database,
            snapshotEngine: engine,
            conversationStore: stores.conversations,
            workspaceStore: stores.workspaces,
            persistedGrants: persistedGrants ?? stores.workspaces,
            inMemoryGrants: inMemory,
            globalFence: fence,
            deletionLifecycle: bindLifecycle ? lifecycle : nil,
            secretOrdering: bindSecretOrdering ? (secretOrdering ?? secrets) : nil,
            credentialDrain: credentialDrain ?? FakeCredentialDrain(),
            providerOperations: operations,
            ownedWork: bindOwnedWork ? owned : nil,
            workspaceCleaning: workspaceCleaning,
            confirmation: host,
            reportStore: reportStore,
            hostEpoch: { epoch },
            rootIdentity: rootToken,
            rootPath: stores.directory.path,
            clock: { clock.now },
            faultInjection: faultInjection)
        return PrivacyFacadeAssembly(
            facade: facade, stores: stores, inMemory: inMemory, fence: fence,
            lifecycle: lifecycle, secrets: secrets, operations: operations,
            owned: owned, host: host, reportStore: reportStore, clock: clock,
            rootToken: rootToken)
    }
}

func privacyIssue(_ assembly: PrivacyFacadeAssembly,
                  operation: String = RuntimeFacadePrivacy.historyClearOperation,
                  digest: String,
                  invocation: String) -> String? {
    let action = PrivacyHostConfirmationStore.expectedAction(for: operation) ?? ""
    return assembly.host.issue(operation: operation, action: action,
                               previewDigest: digest, invocationID: invocation)
}
