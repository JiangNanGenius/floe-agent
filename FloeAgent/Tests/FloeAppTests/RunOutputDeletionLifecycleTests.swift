// S3-D focused App tests for the run-output deletion lifecycle.
//
// These drive the REAL production ordering
// (`ConversationCenter.runOutputAwareDeletion`, the exact sequence
// `stopRunsAndDelete` runs per conversation after writers are stopped and
// joined) against the REAL SQLite stores (in-memory), the REAL
// RunOutputCleanupQueue and REAL snapshot trees under a private temporary
// artifact root.
//
// Honest boundaries:
//   * "writers are stopped/joined before cleanup" is a structural property
//     of `stopRunsAndDelete` (the helper is only reached after every launch
//     task is awaited); it is not re-simulated here.
//   * Full ConversationCenter/AppEnvironment execution belongs to the
//     hosted App acceptance; nothing here claims it ran.

import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

final class RunOutputDeletionLifecycleTests: XCTestCase {

    private var database: DatabaseManager!
    private var conversations: SQLiteConversationStore!
    private var runs: SQLiteRunStore!
    private var storeRoot: URL!
    private var artifactRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        database = try DatabaseManager.inMemory()
        try await database.migrate()
        conversations = SQLiteConversationStore(database: database)
        runs = SQLiteRunStore(database: database)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-app-deletion-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        artifactRoot = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactRoot.appendingPathComponent("RunOutputs", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let artifactRoot {
            try? FileManager.default.removeItem(at: artifactRoot.deletingLastPathComponent())
        }
        database = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeConversation(id: UUID = UUID(), title: String = "Deletion lifecycle") async throws {
        try await conversations.saveConversation(.init(
            id: id, title: title, createdAt: Date(), updatedAt: Date()))
    }

    private func makeRun(id: UUID = UUID(), conversationID: UUID) async throws {
        try await runs.saveRun(.init(
            id: id, conversationID: conversationID,
            state: "completed", goal: "lifecycle fixture",
            startedAt: Date(), endedAt: Date()))
    }

    @discardableResult
    private func seedSnapshot(runID: UUID, name: String = "out.bin",
                              payload: Data = Data("owned-output".utf8)) throws -> URL {
        let dir = artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try payload.write(to: file, options: .atomic)
        return file
    }

    private func snapshotTreeExists(runID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true).path)
    }

    private func tombstoneExists(conversationID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: storeRoot
            .appendingPathComponent("RunOutputCleanupRequests", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString)
            .appendingPathExtension("json").path)
    }

    // MARK: - Tests

    /// Single deletion: tombstone BEFORE the cascade, snapshots only after,
    /// request completed, other runs/user files untouched.
    func testSingleDeletionOrderingCleansOnlyOwnedSnapshots() async throws {
        let conversation = UUID()
        let run = UUID(), otherRun = UUID()
        try await makeConversation(id: conversation)
        try await makeRun(id: run, conversationID: conversation)
        try await makeRun(id: otherRun, conversationID: conversation)
        try seedSnapshot(runID: run)
        let foreignPayload = Data("other-run-kept".utf8)
        try seedSnapshot(runID: otherRun, name: "keep.bin", payload: foreignPayload)
        let userFile = artifactRoot.appendingPathComponent("user-note.txt")
        try Data("user".utf8).write(to: userFile)

        // Only `run` is being deleted (e.g. its outputs belonged to the
        // removed slice); the other run's tree must survive.
        var tombstoneVisibleBeforeCascade = false
        let cleaned = try await ConversationCenter.runOutputAwareDeletion(
            conversationID: conversation,
            durableRunIDs: [run],
            storeRoot: storeRoot,
            artifactRoot: artifactRoot
        ) { [self] in
            tombstoneVisibleBeforeCascade = self.tombstoneExists(conversationID: conversation)
            try await self.conversations.deleteConversation(id: conversation)
        }

        XCTAssertTrue(cleaned)
        XCTAssertTrue(tombstoneVisibleBeforeCascade,
                      "the cleanup tombstone must be persisted BEFORE the DB cascade")
        let deletedConversation = try await conversations.conversation(id: conversation)
        XCTAssertNil(deletedConversation)
        XCTAssertFalse(snapshotTreeExists(runID: run))
        XCTAssertTrue(snapshotTreeExists(runID: otherRun))
        XCTAssertFalse(tombstoneExists(conversationID: conversation))
        XCTAssertEqual(try Data(contentsOf: userFile), Data("user".utf8))
        let keptEnumerator = FileManager.default.enumerator(
            at: artifactRoot.appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(otherRun.uuidString, isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertNotNil(keptEnumerator?.nextObject())
    }

    /// Bulk deletion where the second conversation's DB cascade fails: the
    /// first conversation is fully cleaned; the failed conversation keeps
    /// its outputs and its tombstone; the bootstrap-style retry then skips
    /// the live conversation and later completes it once it is truly gone.
    func testBulkPartialDBFailurePreservesFailedConversationOutputs() async throws {
        let first = UUID(), second = UUID()
        let firstRun = UUID(), secondRun = UUID()
        try await makeConversation(id: first, title: "First")
        try await makeConversation(id: second, title: "Second")
        try await makeRun(id: firstRun, conversationID: first)
        try await makeRun(id: secondRun, conversationID: second)
        try seedSnapshot(runID: firstRun)
        try seedSnapshot(runID: secondRun)

        // First conversation deletes cleanly through the production order.
        let firstCleaned = try await ConversationCenter.runOutputAwareDeletion(
            conversationID: first,
            durableRunIDs: [firstRun],
            storeRoot: storeRoot,
            artifactRoot: artifactRoot
        ) { [self] in
            try await self.conversations.deleteConversation(id: first)
        }
        XCTAssertTrue(firstCleaned)
        XCTAssertFalse(snapshotTreeExists(runID: firstRun))

        // Second conversation's DB cascade fails (e.g. disk/DB error): the
        // helper must propagate the failure, keep the tombstone and never
        // touch the snapshots.
        struct SimulatedDBFailure: Error {}
        do {
            _ = try await ConversationCenter.runOutputAwareDeletion(
                conversationID: second,
                durableRunIDs: [secondRun],
                storeRoot: storeRoot,
                artifactRoot: artifactRoot
            ) { [self] in
                throw SimulatedDBFailure()
            }
            XCTFail("the DB failure must propagate")
        } catch is SimulatedDBFailure {
            // expected
        }
        let retainedConversation = try await conversations.conversation(id: second)
        XCTAssertNotNil(retainedConversation)
        XCTAssertTrue(snapshotTreeExists(runID: secondRun))
        XCTAssertTrue(tombstoneExists(conversationID: second),
                      "the pre-cascade tombstone survives the DB failure")

        // Bootstrap-style retry: the live conversation is verified present,
        // so its outputs stay; nothing is scanned or guessed.
        let firstPass = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { [self] conversationID in
            try await self.conversations.conversation(id: conversationID) != nil
        }
        XCTAssertEqual(firstPass.completedRequests, 0)
        XCTAssertEqual(firstPass.retainedLiveConversationRequests, 1)
        XCTAssertTrue(snapshotTreeExists(runID: secondRun))

        // Once the conversation is genuinely gone, the retry completes.
        try await conversations.deleteConversation(id: second)
        let secondPass = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { [self] conversationID in
            try await self.conversations.conversation(id: conversationID) != nil
        }
        XCTAssertEqual(secondPass.completedRequests, 1)
        XCTAssertFalse(snapshotTreeExists(runID: secondRun))
        XCTAssertFalse(tombstoneExists(conversationID: second))
    }

    /// A cleanup failure after a confirmed DB deletion keeps the tombstone,
    /// surfaces `false`, and the next bootstrap retry completes it.
    func testCleanupFailurePersistsRequestAndRetryCompletes() async throws {
        let conversation = UUID()
        let run = UUID()
        try await makeConversation(id: conversation)
        try await makeRun(id: run, conversationID: conversation)
        let tree = try seedSnapshot(runID: run)
        // Make the owned tree unremovable (read-only directory).
        let runDir = tree.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: runDir.path)

        let cleaned = try await ConversationCenter.runOutputAwareDeletion(
            conversationID: conversation,
            durableRunIDs: [run],
            storeRoot: storeRoot,
            artifactRoot: artifactRoot
        ) { [self] in
            try await self.conversations.deleteConversation(id: conversation)
        }
        XCTAssertFalse(cleaned, "cleanup failure must be reported, never swallowed")
        let deletedConversation = try await conversations.conversation(id: conversation)
        XCTAssertNil(deletedConversation)
        XCTAssertTrue(snapshotTreeExists(runID: run))
        XCTAssertTrue(tombstoneExists(conversationID: conversation))

        // Same readiness retry the AppEnvironment bootstrap performs.
        var outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { _ in false }
        XCTAssertEqual(outcome.failedRequestCount, 1)
        XCTAssertTrue(snapshotTreeExists(runID: run))

        // Repair and reattempt: idempotent completion.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runDir.path)
        outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { _ in false }
        XCTAssertEqual(outcome.completedRequests, 1)
        XCTAssertFalse(snapshotTreeExists(runID: run))
        XCTAssertFalse(tombstoneExists(conversationID: conversation))
    }

    /// A symlinked snapshot tree is refused: the conversation still deletes,
    /// the request survives, and the aliased bytes are never followed or
    /// removed — across repeated retries.
    func testUnsafeSymlinkedTreeRefusedAndRetained() async throws {
        let conversation = UUID()
        let run = UUID()
        try await makeConversation(id: conversation)
        try await makeRun(id: run, conversationID: conversation)
        let real = artifactRoot.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let payload = Data("precious".utf8)
        try payload.write(to: real.appendingPathComponent("keep.bin"))
        let namespace = artifactRoot.appendingPathComponent(
            ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        let alias = namespace.appendingPathComponent(run.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let cleaned = try await ConversationCenter.runOutputAwareDeletion(
            conversationID: conversation,
            durableRunIDs: [run],
            storeRoot: storeRoot,
            artifactRoot: artifactRoot
        ) { [self] in
            try await self.conversations.deleteConversation(id: conversation)
        }
        XCTAssertFalse(cleaned)
        var info = stat()
        XCTAssertEqual(lstat(alias.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("keep.bin")), payload)

        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { _ in false }
        XCTAssertEqual(outcome.failedRequestCount, 1)
        XCTAssertTrue(tombstoneExists(conversationID: conversation))
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("keep.bin")), payload)
    }

    /// A conversation that owns no durable runs never creates a tombstone
    /// and still deletes; an already-absent tree completes idempotently.
    func testEmptyRunListDeletesWithoutTombstoneAndAbsenceIsIdempotent() async throws {
        let conversation = UUID()
        try await makeConversation(id: conversation)
        let cleaned = try await ConversationCenter.runOutputAwareDeletion(
            conversationID: conversation,
            durableRunIDs: [],
            storeRoot: storeRoot,
            artifactRoot: artifactRoot
        ) { [self] in
            try await self.conversations.deleteConversation(id: conversation)
        }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(tombstoneExists(conversationID: conversation))

        // A tombstone naming a tree that no longer exists completes cleanly.
        let ghostConversation = UUID()
        let ghostRun = UUID()
        try await makeConversation(id: ghostConversation)
        try await makeRun(id: ghostRun, conversationID: ghostConversation)
        try await conversations.deleteConversation(id: ghostConversation)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: ghostConversation, runIDs: [ghostRun]),
            storeRoot: storeRoot)
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: storeRoot, artifactRoot: artifactRoot
        ) { _ in false }
        XCTAssertEqual(outcome.completedRequests, 1)
        XCTAssertFalse(tombstoneExists(conversationID: ghostConversation))
    }
}
