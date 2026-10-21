// SPDX-License-Identifier: MPL-2.0
//
// RB-3 test support — REAL file-backed database plus narrow test-only
// doubles (private source candidate; NOT compiled, NOT executed here).
//
// Every double exists to PROVE an ordering/fail-closed property of the
// production adapter; none is a production implementation and none replaces
// a store:
// * `RB3TestBed` opens the ORIGINAL DatabaseManager on a FILE path, runs the
//   ORIGINAL pinned migration chain to schema 46, and supports same-path
//   reopen (process-death recoverability of the durable queues).
// * `ScriptedLifecycle` records the exact fence/drain sequence and can
//   mutate inside the drain window — both the legitimate owned final write
//   (appendMessage) and the illegitimate external metadata mutation cases.
// * `MemoryContentPublisher` is a bounded test mirror of the RB-1
//   FacadeContentReader contract (scalar-safe slices + explicit saturation)
//   so the production authority paths run against a faithful shape; the
//   bytes still live ONLY in the double, never in the binding index.
// * `RecordingCredentialDrain` / `TempWorkspaceCleaning` simulate ONLY the
//   side effects of the real RB-2b vault drain and the host file removal
//   the facade has no entitlement for; the durable queue tables stay real
//   (V11/V36 triggers), so the tests measure ACTUAL cascade/trigger
//   behaviour, not double behaviour.

import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

enum RB3TestBed {
    /// Opens the ORIGINAL DatabaseManager on a real file path and migrates
    /// through the ORIGINAL pinned chain (schema 46). The directory is
    /// removed at test teardown; the path is stable for a `reopen` test.
    static func openMigrated(name: String) async throws -> (DatabaseManager, URL) {
        // Deterministic-prefixed system-temp fixtures: the host's periodic
        // purge owns final removal (same convention the existing shared-core
        // suites use); keeping this helper free of XCTestCase instance calls
        // lets every test share it.
        let root = androidTestFixtureDirectory
            .appendingPathComponent("FloeRB3Tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: root.appendingPathComponent("floe.sqlite"))
        try await manager.migrate()
        let version = try await manager.userVersion()
        guard version == DatabaseManager.currentSchemaVersion else {
            throw RB3FixtureError("fixture must migrate to exactly schema 46, got \(version)")
        }
        return (manager, root)
    }

    struct RB3FixtureError: Error { let detail: String; init(_ detail: String) { self.detail = detail } }

    struct Stores {
        let database: DatabaseManager
        let directory: URL
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let inputs: SQLiteRunningInputStore
        let workspaces: SQLiteWorkspaceStore
        let intelligence: SQLiteIntelligenceStore
    }

    static func stores(name: String = UUID().uuidString) async throws -> Stores {
        let (database, directory) = try await openMigrated(name: name)
        return Stores(database: database,
                      directory: directory,
                      conversations: SQLiteConversationStore(database: database),
                      runs: SQLiteRunStore(database: database),
                      inputs: SQLiteRunningInputStore(database: database),
                      workspaces: SQLiteWorkspaceStore(database: database),
                      intelligence: SQLiteIntelligenceStore(database: database))
    }

    /// Same-path reopen: new manager + new stores over the SAME file.
    static func reopen(_ stores: Stores) async throws -> Stores {
        try await stores.database.close()
        let manager = try DatabaseManager(path: stores.directory.appendingPathComponent("floe.sqlite"))
        // No migrate(): the ORIGINAL open path validates the existing chain;
        // migrate() is idempotent for already-applied identifiers.
        try await manager.migrate()
        return Stores(database: manager,
                      directory: stores.directory,
                      conversations: SQLiteConversationStore(database: manager),
                      runs: SQLiteRunStore(database: manager),
                      inputs: SQLiteRunningInputStore(database: manager),
                      workspaces: SQLiteWorkspaceStore(database: manager),
                      intelligence: SQLiteIntelligenceStore(database: manager))
    }

    static func rawDigest(_ database: DatabaseManager, _ conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try ConversationRowRevision.digest(db: db, conversationID: conversationID)
        }
    }

    static func revision(_ database: DatabaseManager, _ conversationID: UUID) async throws -> BaseRevision {
        guard let digest = try await rawDigest(database, conversationID) else {
            throw RB3FixtureError("row missing for \(conversationID.uuidString)")
        }
        return BaseRevision(resourceID: ConversationRowRevision.resourceID(conversationID: conversationID),
                            version: digest)
    }

    static func count(_ database: DatabaseManager, _ sql: String,
                      _ arguments: StatementArguments = StatementArguments()) async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    static func seedOrdinary(_ stores: Stores,
                             title: String = "",
                             id: UUID = UUID(),
                             createdAt: Date? = nil,
                             updatedAt: Date? = nil) async throws -> ConversationRecord {
        let record = ConversationRecord(
            id: id,
            title: title,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date(timeIntervalSince1970: 1_760_000_000),
            purpose: .ordinary
        )
        try await stores.conversations.saveConversation(record)
        return record
    }

    static func seedMessage(_ stores: Stores,
                            conversationID: UUID,
                            role: String = "user",
                            content: String,
                            id: UUID = UUID(),
                            runID: UUID? = nil,
                            createdAt: Date? = nil) async throws -> PersistedMessage {
        let message = PersistedMessage(
            id: id,
            conversationID: conversationID,
            role: role,
            content: content,
            createdAt: createdAt ?? Date(),
            parts: [],
            runID: runID
        )
        try await stores.conversations.appendMessage(message)
        return message
    }

    static func seedRun(_ database: DatabaseManager,
                        conversationID: UUID,
                        id: UUID = UUID(),
                        state: String = "completed",
                        goal: String = "synthetic goal",
                        startedAt: Date = Date()) async throws {
        let started = ConversationWireDate.encode(startedAt)
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at, ended_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id.uuidString, conversationID.uuidString, state, goal, started, started]
            )
        }
    }

    /// Seed via the ORIGINAL store so pending_user_inputs rows carry the
    /// real column set (mode/status CHECKs included).
    static func seedPendingInput(_ stores: Stores,
                                 conversationID: UUID,
                                 content: String,
                                 position: Int64 = 0) async throws {
        _ = try await stores.inputs.enqueue(PendingUserInput(
            id: UUID(),
            conversationID: conversationID,
            content: content,
            position: position
        ))
    }

    /// Deterministic valid UUID for fixtures that need stable ids.
    static func deterministicUUID(_ seed: UInt64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: seed.bigEndian) { raw in
            for index in 0..<8 { bytes[8 + index] = raw[index] }
        }
        bytes[6] |= 0x40          // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant 1
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func workspaceIDColumn(_ database: DatabaseManager,
                                  conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?
                """, arguments: [conversationID.uuidString])
        }
    }
}

// MARK: - Lifecycle double (reference per-conversation authority)

/// Reference implementation of the corrected `ConversationDeletionLifecycle`
/// port for the file-backed tests. It is a TEST DOUBLE, not production:
/// the real RB4 adapter owns `LaunchEpochFence` / ConversationRunService /
/// liveTasks / child+tool cancellation. This double models the EXACT
/// contract the real adapter must satisfy, including:
///
/// * operation-owned guard: `begin` mints one authority receipt for the
///   exact conversation/epoch/operation triple and refuses a second live
///   guard (`fenceHeld`);
/// * per-conversation owned tokens: only the TARGET conversation's tokens
///   are awaited/detached by `drain`; an unrelated conversation B keeps its
///   tokens and is never cancelled;
/// * exact-token settlement: `abort`/`commit` only clear the CURRENT guard
///   for the same receipt; an old already-settled token returns
///   `.alreadySettled` and a fabricated/foreign token returns
///   `.refusedForeignToken`, never touching a newer guard;
/// * no timer release: the optional hold loop is test-only and always
///   honours task cancellation (a cancelled drain is not quiescence).
final class ScriptedLifecycle: ConversationDeletionLifecycle, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var guardFence: ConversationDeletionFence?
    private var begunFences: [ConversationDeletionFence] = []
    private var settledReceipts: Set<String> = []
    private var mintCounter: UInt64 = 0
    private var ownedByConversation: [UUID: [RuntimeOwnedWorkToken]] = [:]
    private var attachedReceipts: Set<String> = []

    /// Optional side effect executed INSIDE `drainOwnedWork` (legitimate
    /// owned final writes AND external metadata mutation cases both run
    /// here, in test order).
    var midDrain: (@Sendable () async throws -> Void)?
    /// Test-only hold. Production must never timer-release outstanding I/O.
    var holdDrain: (@Sendable () async -> Bool)?
    /// Simulates the REAL global `countsByKind(for:)` snapshot taken after
    /// the adapter's final detach. `nil` models an implementation that
    /// failed to observe counts (hard refusal). Default: explicit zeros.
    var countsProvider: (@Sendable (UInt64) -> [String: Int]?) = { _ in
        ScriptedLifecycle.drainedCounts()
    }
    /// Pending-launch evidence for the target. nil = missing evidence.
    var pendingLaunchProvider: (@Sendable (UUID) -> Int?)? = { _ in 0 }
    /// Full override for deliberately malformed/foreign reports.
    var reportOverride: (@Sendable (ConversationDeletionFence) -> ConversationQuiescenceReport)?
    var beginFailure: ConversationDeletionLifecycleFailure?
    var drainFailure: ConversationDeletionLifecycleFailure?
    var commitSettlementOverride: ConversationDeletionFenceSettlement?
    var abortSettlementOverride: ConversationDeletionFenceSettlement?
    /// When true (default) a successful drain detaches the TARGET
    /// conversation's tokens, modelling real completion. Set false to model
    /// "still attached" or to control completion from the test.
    var detachTargetOnDrain = true
    /// When false, report a foreign epoch (late old-generation callback).
    var echoExpectedEpoch = true

    init() {}

    private func appendLocked(_ event: String) { recordedEvents.append(event) }

    // Qualifier repair (2026-10-19): synchronous scoped locking helper.
    // `NSLock.lock()/unlock()` are `noasync`; every async-context use below
    // routes through this non-async helper (behavior identical).
    private func withLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func record(_ event: String) {
        lock.lock(); appendLocked(event); lock.unlock()
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }; return recordedEvents
    }

    var currentGuard: ConversationDeletionFence? {
        lock.lock(); defer { lock.unlock() }; return guardFence
    }

    /// Every fence this authority minted, in begin order (test inspection).
    var fences: [ConversationDeletionFence] {
        lock.lock(); defer { lock.unlock() }; return begunFences
    }

    // MARK: Test-owned-work fixtures

    static func token(seed: UInt64, epoch: UInt64, kind: RuntimeOwnedWorkKind,
                      ownerID: String) -> RuntimeOwnedWorkToken {
        let hex = String(format: "%032llx", seed)
        return RuntimeOwnedWorkToken(receipt: "work:v1:" + hex, epoch: epoch,
                                     kind: kind, ownerID: ownerID)
    }

    /// Registers a token for a conversation and marks it attached.
    @discardableResult
    func attachOwnedWork(conversationID: UUID, kind: RuntimeOwnedWorkKind,
                         epoch: UInt64, ownerID: String? = nil) -> RuntimeOwnedWorkToken {
        let token = Self.token(seed: UInt64.random(in: 1...UInt64.max),
                               epoch: epoch, kind: kind,
                               ownerID: ownerID ?? conversationID.uuidString)
        lock.lock()
        ownedByConversation[conversationID, default: []].append(token)
        attachedReceipts.insert(token.receipt)
        lock.unlock()
        return token
    }

    func detachOwnedWork(_ token: RuntimeOwnedWorkToken) {
        lock.lock(); attachedReceipts.remove(token.receipt); lock.unlock()
    }

    func attachedTokens(for conversationID: UUID) -> [RuntimeOwnedWorkToken] {
        lock.lock(); defer { lock.unlock() }
        return (ownedByConversation[conversationID] ?? []).filter {
            attachedReceipts.contains($0.receipt)
        }
    }

    /// Models the RB4 launch fence: false = a NEW launch for this
    /// conversation is refused because a live deletion guard owns it.
    func attemptNewLaunch(conversationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let guardFence else { return true }
        return guardFence.conversationID != conversationID
    }

    // MARK: Port

    func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                            operationID: UUID) async throws -> ConversationDeletionFence {
        if let failure = beginFailure { throw failure }
        let fence: ConversationDeletionFence = try withLocked {
            guard guardFence == nil else {
                throw ConversationDeletionLifecycleFailure.fenceHeld
            }
            mintCounter &+= 1
            let receipt = String(format: "fence:v1:%032llx", mintCounter)
            let fence = ConversationDeletionFence(conversationID: conversationID,
                                                  epoch: epoch,
                                                  operationID: operationID,
                                                  authorityReceipt: receipt)
            guardFence = fence
            begunFences.append(fence)
            appendLocked("begin:\(conversationID.uuidString):\(epoch):\(operationID.uuidString)")
            return fence
        }
        return fence
    }

    func drainOwnedWork(fence: ConversationDeletionFence) async throws
        -> ConversationQuiescenceReport
    {
        let current = withLocked { () -> Bool in
            let current = guardFence == fence
            if current { appendLocked("drainStart:\(fence.conversationID.uuidString):\(fence.epoch)") }
            return current
        }
        guard current else { throw ConversationDeletionLifecycleFailure.fenceTokenRefused }

        if let drainFailure { throw drainFailure }
        if let midDrain { try await midDrain() }
        if let holdDrain {
            while await holdDrain() {
                try await Task.sleep(nanoseconds: 2_000_000)
                try Task.checkCancellation()
            }
        }
        if detachTargetOnDrain {
            withLocked {
                for token in ownedByConversation[fence.conversationID] ?? [] {
                    attachedReceipts.remove(token.receipt)
                }
            }
        }
        record("drainEnd:\(fence.conversationID.uuidString)")

        if let reportOverride { return reportOverride(fence) }

        let evidence = withLocked { () -> [ConversationOwnedWorkObservation] in
            let tokens = ownedByConversation[fence.conversationID] ?? []
            return tokens.map { token in
                ConversationOwnedWorkObservation(
                    conversationID: fence.conversationID,
                    token: token,
                    stillAttached: attachedReceipts.contains(token.receipt))
            }
        }
        return ConversationQuiescenceReport(
            conversationID: fence.conversationID,
            launchesFenced: true,
            inFlightLaunchesAwaited: 0,
            runServicesCancelled: 0,
            ownedTasksDrained: 0,
            childRunsReconciled: 0,
            endCountsByKind: countsProvider(fence.epoch),
            countsEpoch: echoExpectedEpoch ? fence.epoch : fence.epoch &+ 1000,
            targetOwnedWork: evidence,
            pendingLaunchCount: pendingLaunchProvider.flatMap { $0(fence.conversationID) })
    }

    func abortDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
    {
        settle(fence, event: "abort", override: abortSettlementOverride)
    }

    func commitDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
    {
        settle(fence, event: "commit", override: commitSettlementOverride)
    }

    private func settle(_ fence: ConversationDeletionFence, event: String,
                        override: ConversationDeletionFenceSettlement?)
        -> ConversationDeletionFenceSettlement
    {
        lock.lock()
        if guardFence == fence {
            if let override {
                if case .unavailable = override {
                    // Authority unavailable: do NOT pretend the guard was
                    // released; the reply/precondition stays honest.
                    appendLocked("\(event):\(fence.conversationID.uuidString):\(fence.operationID.uuidString):unavailable")
                    lock.unlock()
                    return override
                }
            }
            guardFence = nil
            settledReceipts.insert(fence.authorityReceipt)
            appendLocked("\(event):\(fence.conversationID.uuidString):\(fence.operationID.uuidString)")
            lock.unlock()
            return override ?? .released
        }
        if settledReceipts.contains(fence.authorityReceipt) {
            appendLocked("\(event):\(fence.conversationID.uuidString):\(fence.operationID.uuidString):alreadySettled")
            lock.unlock()
            return .alreadySettled
        }
        appendLocked("\(event):\(fence.conversationID.uuidString):\(fence.operationID.uuidString):refused")
        lock.unlock()
        return .refusedForeignToken
    }

    /// Convenience for the honest "global root epoch drained" fixture.
    static func drainedCounts() -> [String: Int] {
        ["run": 0, "childRun": 0, "tool": 0, "conversation": 0]
    }
}

// MARK: - Content publisher double

/// Test mirror of the RB-1 `FacadeContentReader` behaviour (bounded,
/// scalar-safe slices, typed declines). Handles are minted in the same
/// opaque `chunk:v1:` style; the production authority never parses them.
actor MemoryContentPublisher: ConversationContentPublishing {
    private struct Blob { let data: Data }
    private var blobs: [String: Blob] = [:]
    private var counter = 0
    let maxLiveHandles: Int
    let maxTotalBytes: Int
    private(set) var totalBytes = 0
    private(set) var stageCalls = 0
    private(set) var readCalls = 0
    private(set) var releaseCalls = 0

    init(maxLiveHandles: Int = 32, maxTotalBytes: Int = 4_194_304) {
        self.maxLiveHandles = maxLiveHandles
        self.maxTotalBytes = maxTotalBytes
    }

    func stage(_ bytes: Data) async -> ConversationContentStageResult {
        stageCalls += 1
        guard !bytes.isEmpty else { return .rejectedEmpty }
        guard blobs.count < maxLiveHandles,
              totalBytes + bytes.count <= maxTotalBytes else {
            return .saturated
        }
        // Qualifier repair (2026-10-19): mirror the ORIGINAL reader mint
        // (16 random bytes -> 32 hex). A per-instance counter made handles
        // collide across host generations, which the opaque-handle contract
        // forbids (a stale handle must never match a fresh one).
        counter += 1
        var hex = ""
        hex.reserveCapacity(32)
        for _ in 0..<16 { hex += String(format: "%02x", UInt8.random(in: 0...255)) }
        let handle = "chunk:v1:" + hex
        blobs[handle] = Blob(data: bytes)
        totalBytes += bytes.count
        return .staged(handle: handle)
    }

    func read(handle: String, offset: Int, maxBytes: Int) async -> ConversationContentSliceOutcome {
        readCalls += 1
        guard let blob = blobs[handle] else { return .notFound }
        let bytes = [UInt8](blob.data)
        let total = bytes.count
        guard offset >= 0, offset <= total, maxBytes >= 1 else { return .invalidOffset }
        if offset == total { return .slice(bytes: Data(), nextOffset: total, complete: true) }
        // A continuation byte at the requested start cannot name a chunk.
        if (bytes[offset] & 0xC0) == 0x80 { return .invalidOffset }
        var end = min(offset + maxBytes, total)
        if end < total {
            // Back up out of any partially included scalar at the tail.
            while end > offset + 1, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            while end > offset, !scalarsAligned(bytes: bytes, start: offset, end: end) {
                end -= 1
            }
        }
        guard end > offset else { return .invalidOffset }
        let slice = blob.data.subdata(in: offset..<end)
        return .slice(bytes: slice, nextOffset: end, complete: end >= total)
    }

    private func scalarsAligned(bytes: [UInt8], start: Int, end: Int) -> Bool {
        var i = start
        while i < end {
            let lead = bytes[i]
            let width: Int
            if lead & 0x80 == 0x00 { width = 1 }
            else if lead & 0xE0 == 0xC0 { width = 2 }
            else if lead & 0xF0 == 0xE0 { width = 3 }
            else if lead & 0xF8 == 0xF0 { width = 4 }
            else { return false }
            if i + width > end { return false }
            i += width
        }
        return true
    }

    func release(handle: String) async {
        guard let blob = blobs.removeValue(forKey: handle) else { return }
        releaseCalls += 1
        totalBytes = max(0, totalBytes - blob.data.count)
    }

    func retainedBytes() -> Int { totalBytes }
    func liveHandles() -> Int { blobs.count }
}

// MARK: - Credential drain double

/// Simulates ONLY the vault-side consumption of the REAL durable V11
/// `credential_deletion_queue` (the queue rows themselves are created by
/// the production trigger path INSIDE the original delete transaction).
actor RecordingCredentialDrain: ConversationCredentialDeletionDraining {
    private let database: DatabaseManager
    private(set) var drainCalls = 0

    init(database: DatabaseManager) {
        self.database = database
    }

    func drainDeletionQueue() async -> CredentialDeletionDrainSummary {
        drainCalls += 1
        let queueDepth = (try? await RB3TestBed.count(database, """
            SELECT COUNT(*) FROM credential_deletion_queue
            """)) ?? -1
        try? await database.writer { db in
            try db.execute(sql: "DELETE FROM credential_deletion_queue")
        }
        return CredentialDeletionDrainSummary(drained: queueDepth,
                                              deferredCount: 0,
                                              failedCount: 0)
    }

    func calls() -> Int { drainCalls }
}

// MARK: - Workspace file-cleanup double

/// Performs the host-filesystem half of the native cleanup flow inside a
/// temporary managed root, with the SAME path-validation discipline as
/// WorkspaceCenter.removePrivateWorkspaceDirectory (exactly
/// `PrivateTasks/<uuid>`, canonical containment, no symlink escape).
final class TempWorkspaceCleaning: ConversationOwnedWorkspaceCleaning, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var failOnce: Bool
    private var attempts: [String] = []

    // Qualifier repair (2026-10-19): synchronous scoped locking helper; the
    // async `removePrivateTaskDirectory` routes its `noasync` NSLock use here.
    private func withLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    init(failOnce: Bool = false) throws {
        let base = androidTestFixtureDirectory
            .appendingPathComponent("FloeRB3Workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("FloeAgent/PrivateTasks", isDirectory: true),
            withIntermediateDirectories: true)
        self.root = base
        self.failOnce = failOnce
    }

    func seedPrivateTaskDirectory(conversationID: UUID) throws -> URL {
        let url = managedPrivateTasksRoot().appendingPathComponent(conversationID.uuidString,
                                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("task file".utf8).write(to: url.appendingPathComponent("notes.md"))
        return url
    }

    private func managedPrivateTasksRoot() -> URL {
        root.appendingPathComponent("FloeAgent", isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("PrivateTasks", isDirectory: true)
            .standardizedFileURL
    }

    var removalAttempts: [String] {
        lock.lock(); defer { lock.unlock() }; return attempts
    }

    func removePrivateTaskDirectory(relativePath: String) async throws
        -> PrivateTaskDirectoryRemoval
    {
        withLocked { attempts.append(relativePath) }
        if failOnce {
            withLocked { failOnce = false }
            throw CocoaError(.fileWriteUnknown)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "PrivateTasks",
              UUID(uuidString: String(components[1])) != nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let managedRoot = managedPrivateTasksRoot()
        let target = managedRoot.appendingPathComponent(String(components[1]), isDirectory: true)
        guard target.resolvingSymlinksInPath().deletingLastPathComponent() == managedRoot else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return .absent
        }
        try FileManager.default.removeItem(at: target)
        return .removed
    }
}

// MARK: - Domain factory

extension RB3TestBed {
    struct DomainBundle {
        let stores: Stores
        let publisher: MemoryContentPublisher
        let content: FacadeConversationContentAuthority
        let domain: FacadeConversationDomain
        let context: ConversationFacadeContext
    }

    static func makeDomain(stores: Stores,
                           lifecycle: (any ConversationDeletionLifecycle)?,
                           credentialDrain: (any ConversationCredentialDeletionDraining)? = nil,
                           workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)? = nil,
                           bindsDefaultWorkspace: Bool = false,
                           defaultWorkspaceID: UUID? = nil,
                           clock: (@Sendable () -> Date)? = nil,
                           faultInjection: (@Sendable (Int) throws -> Void)? = nil,
                           publisherMaxTotalBytes: Int = 4_194_304,
                           hostEpoch: UInt64 = 1) -> DomainBundle {
        let context = ConversationFacadeContext(hostEpoch: hostEpoch,
                                                defaultSharedWorkspaceID: defaultWorkspaceID)
        let publisher = MemoryContentPublisher(maxTotalBytes: publisherMaxTotalBytes)
        let content = FacadeConversationContentAuthority(
            publisher: publisher,
            database: stores.database,
            conversationStore: stores.conversations,
            context: context)
        let domain = FacadeConversationDomain(
            database: stores.database,
            conversationStore: stores.conversations,
            runStore: stores.runs,
            runningInputStore: stores.inputs,
            workspaceStore: stores.workspaces,
            intelligenceStore: stores.intelligence,
            content: content,
            context: context,
            lifecycle: lifecycle,
            credentialDrain: credentialDrain,
            workspaceCleaning: workspaceCleaning,
            bindsNewConversationsToDefaultWorkspace: bindsDefaultWorkspace,
            clock: clock ?? { Date() },
            faultInjection: faultInjection)
        return DomainBundle(stores: stores, publisher: publisher,
                            content: content, domain: domain, context: context)
    }
}
