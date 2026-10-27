// FloeWorkspaceTests — Durable exact run-output cleanup semantics (S3-D).
// Ported (job-3135f83ef97c4a21) byte-for-byte from iOS main 8f185ac
// FloeAgent/Tests/FloeToolsTests/RunOutputCleanupQueueTests.swift
// (blob 2e51d033267ea73118252444f67322cc90956621); only the suite location
// changed (the Android shared package's host-runnable real-filesystem
// suite). The upstream assertions are unchanged: real files, real request
// records, real snapshot trees under an injected artifact root;
// enqueue/pending/complete, owned-only removal, symlink and
// foreign-component refusal, idempotent absence, malformed-record refusal,
// and the bootstrap tombstone retry that only cleans conversations verified
// absent. No global scans, no guessed orphans. The ANDROID delta tests at
// the bottom of this file exercise the live-ownership hook and the trusted
// deletion-order helper added to the ported queue (retain failed/live
// requests, resume after restart) — the queue-level ordering that on iOS
// production lives in the App layer.

import Foundation
import Testing
@testable import FloeTools
import FloeCore
import FloeModels

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("FloeTools.RunOutputCleanupQueue")
struct RunOutputCleanupQueueTests {

    private final class Fixture: @unchecked Sendable {
        let storeRoot: URL
        let artifactRoot: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
            storeRoot = base.appendingPathComponent("store", isDirectory: true)
            artifactRoot = base.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: artifactRoot.appendingPathComponent("RunOutputs", isDirectory: true),
                withIntermediateDirectories: true)
        }

        /// Creates the canonical snapshot tree for one run with one real
        /// committed user file.
        func seedSnapshot(runID: UUID, name: String = "out.bin", payload: Data = Data("owned".utf8)) throws -> URL {
            let dir = artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try payload.write(to: file, options: .atomic)
            return file
        }

        func snapshotTreeExists(runID: UUID) -> Bool {
            FileManager.default.fileExists(atPath: artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true).path)
        }

        func requestFile(conversationID: UUID) -> URL {
            storeRoot.appendingPathComponent("RunOutputCleanupRequests", isDirectory: true)
                .appendingPathComponent(conversationID.uuidString)
                .appendingPathExtension("json")
        }

        deinit {
            try? FileManager.default.removeItem(at: storeRoot.deletingLastPathComponent())
        }
    }

    // MARK: - Request records

    @Test("enqueue persists the exact request atomically; pending round-trips it")
    func enqueueAndPendingRoundTrip() throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let runs = [UUID(), UUID()]
        let request = RunOutputCleanupRequest(conversationID: conversation, runIDs: runs)
        try RunOutputCleanupQueue.enqueue(request, storeRoot: fixture.storeRoot)

        #expect(FileManager.default.fileExists(atPath: fixture.requestFile(conversationID: conversation).path))
        let pending = try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot)
        #expect(pending == [request])
        // Run IDs are sorted + de-duplicated at the boundary.
        #expect(pending.first?.runIDs == Array(Set(runs)).sorted { $0.uuidString < $1.uuidString })
    }

    @Test("an empty run list is refused and persists nothing")
    func emptyRunListRefused() throws {
        let fixture = try Fixture()
        let conversation = UUID()
        #expect(throws: (any Error).self) {
            try RunOutputCleanupQueue.enqueue(
                .init(conversationID: conversation, runIDs: []), storeRoot: fixture.storeRoot)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.requestFile(conversationID: conversation).path))
    }

    @Test("complete removes the record and is idempotent when already absent")
    func completeIsIdempotent() throws {
        let fixture = try Fixture()
        let conversation = UUID()
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [UUID()]), storeRoot: fixture.storeRoot)
        try RunOutputCleanupQueue.complete(conversationID: conversation, storeRoot: fixture.storeRoot)
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).isEmpty)
        try RunOutputCleanupQueue.complete(conversationID: conversation, storeRoot: fixture.storeRoot)
    }

    @Test("a malformed request record is a visible storage error, never silently dropped")
    func malformedRequestRefused() throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let root = try RunOutputCleanupQueue.requestRoot(storeRoot: fixture.storeRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.requestFile(conversationID: conversation))
        #expect(throws: (any Error).self) {
            _ = try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot)
        }
    }

    // MARK: - Owned snapshot removal

    @Test("removal deletes only the named runs' trees and preserves everything else")
    func removalIsExactAndOwned() throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let runA = UUID(), runB = UUID(), otherRun = UUID()
        try fixture.seedSnapshot(runID: runA, name: "a.bin")
        try fixture.seedSnapshot(runID: runB, name: "b.bin")
        let foreignPayload = Data("other-run".utf8)
        try fixture.seedSnapshot(runID: otherRun, name: "keep.bin", payload: foreignPayload)
        // Unrelated user file beside the namespace.
        let userFile = fixture.artifactRoot.appendingPathComponent("user-note.txt")
        try Data("user".utf8).write(to: userFile)

        let request = RunOutputCleanupRequest(conversationID: conversation, runIDs: [runA, runB])
        try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: fixture.artifactRoot)

        #expect(!fixture.snapshotTreeExists(runID: runA))
        #expect(!fixture.snapshotTreeExists(runID: runB))
        #expect(fixture.snapshotTreeExists(runID: otherRun))
        #expect(try Data(contentsOf: userFile) == Data("user".utf8))
        let kept = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(otherRun.uuidString, isDirectory: true)
        let keptFiles = try FileManager.default.enumerator(at: kept, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(keptFiles?.isEmpty == false)
    }

    @Test("an already-absent tree — or an entirely missing store — is a successful no-op")
    func absentTreeIsIdempotent() throws {
        let fixture = try Fixture()
        let request = RunOutputCleanupRequest(conversationID: UUID(), runIDs: [UUID()])
        try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: fixture.artifactRoot)
        // A missing artifact root never throws either: there is nothing below
        // it to delete, and deletion is never guessed at.
        let missingBase = fixture.artifactRoot.appendingPathComponent("missing-store", isDirectory: true)
        try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: missingBase)
    }

    @Test("a symlinked run tree is refused, not followed or deleted")
    func symlinkedTreeRefused() throws {
        let fixture = try Fixture()
        let runID = UUID()
        let real = fixture.artifactRoot.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let payload = Data("precious".utf8)
        try payload.write(to: real.appendingPathComponent("keep.bin"))
        let namespace = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        let link = namespace.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let request = RunOutputCleanupRequest(conversationID: UUID(), runIDs: [runID])
        #expect(throws: (any Error).self) {
            try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: fixture.artifactRoot)
        }
        // The symlink and its target survive untouched.
        var info = stat()
        #expect(lstat(link.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        #expect(try Data(contentsOf: real.appendingPathComponent("keep.bin")) == payload)
    }

    @Test("a regular file sitting at the run tree path is foreign and refused")
    func foreignFileRefused() throws {
        let fixture = try Fixture()
        let runID = UUID()
        let namespace = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        let foreign = namespace.appendingPathComponent(runID.uuidString, isDirectory: true)
        try Data("not a directory".utf8).write(to: foreign)
        let request = RunOutputCleanupRequest(conversationID: UUID(), runIDs: [runID])
        #expect(throws: (any Error).self) {
            try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: fixture.artifactRoot)
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("a symlinked namespace component is refused before anything is removed")
    func symlinkedNamespaceRefused() throws {
        let fixture = try Fixture()
        let runID = UUID(), victimRun = UUID()
        try fixture.seedSnapshot(runID: victimRun, name: "victim.bin")
        // Move the real namespace aside and alias it.
        let namespace = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        let moved = fixture.artifactRoot.appendingPathComponent("RunOutputs-real", isDirectory: true)
        try FileManager.default.moveItem(at: namespace, to: moved)
        try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: moved)
        let request = RunOutputCleanupRequest(conversationID: UUID(), runIDs: [victimRun, runID])
        #expect(throws: (any Error).self) {
            try RunOutputCleanupQueue.removeOwnedSnapshots(for: request, artifactRoot: fixture.artifactRoot)
        }
        // Nothing was deleted through the alias.
        #expect(FileManager.default.fileExists(atPath: moved
            .appendingPathComponent(victimRun.uuidString, isDirectory: true).path))
    }

    // MARK: - Bootstrap tombstone retry

    @Test("retry cleans only conversations verified absent and completes their records")
    func retryCleansOnlyVerifiedAbsent() async throws {
        let fixture = try Fixture()
        let goneConversation = UUID(), liveConversation = UUID()
        let goneRun = UUID(), liveRun = UUID()
        try fixture.seedSnapshot(runID: goneRun)
        try fixture.seedSnapshot(runID: liveRun)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: goneConversation, runIDs: [goneRun]), storeRoot: fixture.storeRoot)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: liveConversation, runIDs: [liveRun]), storeRoot: fixture.storeRoot)

        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot
        ) { conversationID in
            conversationID == liveConversation
        }

        #expect(outcome.completedRequests == 1)
        #expect(outcome.retainedLiveConversationRequests == 1)
        #expect(outcome.failedRequestCount == 0)
        #expect(!fixture.snapshotTreeExists(runID: goneRun))
        #expect(fixture.snapshotTreeExists(runID: liveRun))
        let remaining = try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot)
        #expect(remaining == [.init(conversationID: liveConversation, runIDs: [liveRun])])
    }

    @Test("a deletion failure keeps the request and reports a visible failure")
    func deletionFailurePersistsRequest() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let runA = UUID(), runB = UUID()
        try fixture.seedSnapshot(runID: runA)
        let protected = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runB.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: protected.appendingPathComponent("real.bin"))
        // A read-only directory makes the owned-tree removal fail
        // deterministically (unlink requires write permission).
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: protected.path)

        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [runA, runB]), storeRoot: fixture.storeRoot)
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot
        ) { _ in false }

        #expect(outcome.completedRequests == 0)
        #expect(outcome.failedRequestCount == 1)
        #expect(!outcome.failureDescriptions.isEmpty)
        // The run that failed keeps its whole tree; the request survives so
        // the next pass reattempts it (any already-removed sibling run stays
        // idempotently absent).
        #expect(fixture.snapshotTreeExists(runID: runB))
        let remaining = try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot)
        #expect(remaining.count == 1)
        // Repair permissions so cleanup can proceed on the "next pass".
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protected.path)
        let second = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot
        ) { _ in false }
        #expect(second.completedRequests == 1)
        #expect(!fixture.snapshotTreeExists(runID: runA))
        #expect(!fixture.snapshotTreeExists(runID: runB))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).isEmpty)
    }

    @Test("bulk requests are independent: one failure never blocks the others")
    func bulkRequestsAreIndependent() async throws {
        let fixture = try Fixture()
        let failing = UUID(), succeeding = UUID()
        let failingRun = UUID(), succeedingRun = UUID()
        try fixture.seedSnapshot(runID: failingRun)
        try fixture.seedSnapshot(runID: succeedingRun)
        let namespace = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        // Make the failing request's tree a regular file (foreign): refused,
        // while the independent succeeding request still completes.
        try FileManager.default.removeItem(at: namespace.appendingPathComponent(failingRun.uuidString, isDirectory: true))
        try Data("foreign".utf8).write(to: namespace.appendingPathComponent(failingRun.uuidString, isDirectory: false))

        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: failing, runIDs: [failingRun]), storeRoot: fixture.storeRoot)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: succeeding, runIDs: [succeedingRun]), storeRoot: fixture.storeRoot)

        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot
        ) { _ in false }
        #expect(outcome.completedRequests == 1)
        #expect(outcome.failedRequestCount == 1)
        #expect(!fixture.snapshotTreeExists(runID: succeedingRun))
        let remaining = try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot)
        #expect(remaining.count == 1)
    }

    @Test("a conversation-existence check failure retains the request")
    func existenceCheckFailureRetainsRequest() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [run]), storeRoot: fixture.storeRoot)
        struct CheckError: Error {}
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot
        ) { _ in throw CheckError() }
        #expect(outcome.failedRequestCount == 1)
        #expect(fixture.snapshotTreeExists(runID: run))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).count == 1)
    }
    @Test("an unreadable request directory reports failure without removing snapshots")
    func requestDirectoryReadFailureIsObservable() async throws {
        let fixture = try Fixture()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        let requestRoot = try RunOutputCleanupQueue.requestRoot(storeRoot: fixture.storeRoot)
        try FileManager.default.createDirectory(at: fixture.storeRoot,
                                               withIntermediateDirectories: true)
        let original = Data("not-a-directory".utf8)
        try original.write(to: requestRoot)
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { _ in false }
        #expect(outcome.completedRequests == 0)
        #expect(outcome.failedRequestCount == 1)
        #expect(!outcome.failureDescriptions.isEmpty)
        #expect(fixture.snapshotTreeExists(runID: run))
        #expect(try Data(contentsOf: requestRoot) == original)
    }

    // MARK: - ANDROID delta: live-ownership hook (D04 producer batch)

    /// A deterministic in-test trusted probe. Production composes the
    /// facade's generation-bound leases plus the deletion's exact RB1
    /// owned-work tokens (`OwnedRunOutputWorkProbe` /
    /// `RunOutputLeaseLiveOwnership`); the queue only ever sees the
    /// protocol either way.
    private final class FixedLiveOwnership: RunOutputLiveOwnership, @unchecked Sendable {
        private let lock = NSLock()
        private var live: Set<UUID>
        init(_ live: Set<UUID> = []) { self.live = live }
        func setLive(_ ids: Set<UUID>) {
            lock.lock(); live = ids; lock.unlock()
        }
        func ownsRunOutput(runID: UUID) async throws -> Bool {
            containsLocked(runID)
        }
        private func containsLocked(_ id: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return live.contains(id)
        }
    }

    @Test("a live output owner retains the request AND the trees; the next pass completes")
    func liveOwnershipRetainsUntilReleased() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [run]), storeRoot: fixture.storeRoot)
        let probe = FixedLiveOwnership([run])
        let first = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            liveOwnership: probe
        ) { _ in false } // conversation already gone; only the owner keeps it alive
        #expect(first.completedRequests == 0)
        #expect(first.retainedLiveOutputRequests == 1)
        #expect(first.failedRequestCount == 0)
        #expect(fixture.snapshotTreeExists(runID: run))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).count == 1)
        // The service releases the output; the next readiness pass finishes
        // the SAME request idempotently — nothing was re-created or guessed.
        probe.setLive([])
        let second = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            liveOwnership: probe
        ) { _ in false }
        #expect(second.completedRequests == 1)
        #expect(!fixture.snapshotTreeExists(runID: run))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).isEmpty)
    }

    @Test("live ownership wins over conversation absence only for the owned run")
    func liveOwnershipIsPerRun() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let runA = UUID(), runB = UUID()
        try fixture.seedSnapshot(runID: runA)
        try fixture.seedSnapshot(runID: runB)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [runA, runB]), storeRoot: fixture.storeRoot)
        // One live owner in the request retains the WHOLE request: the
        // queue never performs a partial delete of one task's tombstone.
        let probe = FixedLiveOwnership([runB])
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            liveOwnership: probe
        ) { _ in false }
        #expect(outcome.retainedLiveOutputRequests == 1)
        #expect(fixture.snapshotTreeExists(runID: runA))
        #expect(fixture.snapshotTreeExists(runID: runB))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).count == 1)
    }

    @Test("a failing ownership probe keeps the request, never deletes blindly")
    func ownershipProbeFailureRetains() async throws {
        let fixture = try Fixture()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: UUID(), runIDs: [run]), storeRoot: fixture.storeRoot)
        struct ProbeError: Error {}
        final class FailingProbe: RunOutputLiveOwnership, @unchecked Sendable {
            func ownsRunOutput(runID: UUID) async throws -> Bool { throw ProbeError() }
        }
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            liveOwnership: FailingProbe()
        ) { _ in false }
        #expect(outcome.failedRequestCount == 1)
        #expect(fixture.snapshotTreeExists(runID: run))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.storeRoot).count == 1)
    }
}

// MARK: - ANDROID delta: trusted deletion order (D04 producer batch)

/// Mirrors the iOS `RunOutputDeletionLifecycleTests` order assertions
/// against the shared-core `RunOutputDeletionOrder` that
/// `FacadeConversationDomain.delete` now wraps around its original store
/// call. The DB cascade is represented by an honest in-test marker
/// (Android's real store wiring is qualified by Main's combined batch);
/// the QUEUE, records, trees and ordering are the real production ones.
@Suite("FloeTools.RunOutputDeletionOrder")
struct RunOutputDeletionOrderTests {

    private final class Fixture: @unchecked Sendable {
        let storeRoot: URL
        let artifactRoot: URL
        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-deletion-order-\(UUID().uuidString)", isDirectory: true)
            storeRoot = base.appendingPathComponent("store", isDirectory: true)
            artifactRoot = base.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: artifactRoot.appendingPathComponent("RunOutputs", isDirectory: true),
                withIntermediateDirectories: true)
        }
        func seedSnapshot(runID: UUID) throws -> URL {
            let dir = artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("out.bin")
            try Data("owned".utf8).write(to: file)
            return file
        }
        func snapshotTreeExists(runID: UUID) -> Bool {
            FileManager.default.fileExists(atPath: artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true).path)
        }
        func pendingCount() throws -> Int {
            try RunOutputCleanupQueue.pending(storeRoot: storeRoot).count
        }
        deinit { try? FileManager.default.removeItem(at: storeRoot.deletingLastPathComponent()) }
    }

    @Test("no durable run ids: plain deletion, no tombstone, no store touch")
    func emptyRunIDsIsPlainDelete() async throws {
        let fixture = try Fixture()
        var deleted = false
        let outcome = try await RunOutputDeletionOrder.perform(
            conversationID: UUID(), durableRunIDs: [],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { deleted = true }
        #expect(outcome == .noOutputs)
        #expect(deleted)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.storeRoot.appendingPathComponent("RunOutputCleanupRequests", isDirectory: true).path))
    }

    @Test("enqueue failure aborts BEFORE the cascade: no tombstone-less orphaning")
    func enqueueFailureAbortsCascade() async throws {
        let fixture = try Fixture()
        // Make the request root uncreatable: a regular FILE where the
        // record directory must live.
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(
            to: fixture.storeRoot.appendingPathComponent("RunOutputCleanupRequests"))
        var deleted = false
        await #expect(throws: (any Error).self) {
            _ = try await RunOutputDeletionOrder.perform(
                conversationID: UUID(), durableRunIDs: [UUID()],
                storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
            ) { deleted = true }
        }
        #expect(!deleted, "the DB cascade must never run when the tombstone cannot be persisted")
    }

    @Test("cascade failure propagates with the tombstone persisted and trees untouched")
    func cascadeFailureRetainsTombstoneAndTrees() async throws {
        let fixture = try Fixture()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        struct CascadeError: Error {}
        await #expect(throws: CascadeError.self) {
            _ = try await RunOutputDeletionOrder.perform(
                conversationID: UUID(), durableRunIDs: [run],
                storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
            ) { throw CascadeError() }
        }
        #expect(try fixture.pendingCount() == 1)
        #expect(fixture.snapshotTreeExists(runID: run))
        // The readiness retry re-derives everything from the persisted
        // request: the surviving conversation is verified live, so the
        // tombstone is retained and NOTHING is deleted.
        let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { _ in true }
        #expect(outcome.retainedLiveConversationRequests == 1)
        #expect(fixture.snapshotTreeExists(runID: run))
    }

    @Test("successful order: tombstone first, cascade, exact trees removed, request completed")
    func successfulOrderRemovesExactlyAndCompletes() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let runA = UUID(), runB = UUID(), foreign = UUID()
        try fixture.seedSnapshot(runID: runA)
        try fixture.seedSnapshot(runID: runB)
        try fixture.seedSnapshot(runID: foreign)
        let outcome = try await RunOutputDeletionOrder.perform(
            conversationID: conversation, durableRunIDs: [runA, runB],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { /* cascade committed */ }
        #expect(outcome == .removed)
        #expect(!fixture.snapshotTreeExists(runID: runA))
        #expect(!fixture.snapshotTreeExists(runID: runB))
        #expect(fixture.snapshotTreeExists(runID: foreign), "other runs are never touched")
        #expect(try fixture.pendingCount() == 0)
    }

    @Test("a live output owner defers the file cleanup; the next pass finishes it")
    func liveOwnershipDefersUntilReleased() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        final class Holder: RunOutputLiveOwnership, @unchecked Sendable {
            var live = true
            func ownsRunOutput(runID: UUID) async throws -> Bool { live }
        }
        let holder = Holder()
        let first = try await RunOutputDeletionOrder.perform(
            conversationID: conversation, durableRunIDs: [run],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot,
            liveOwnership: holder
        ) { /* cascade committed */ }
        #expect(first == .deferredLiveOwnership)
        #expect(fixture.snapshotTreeExists(runID: run), "the live worker's output is NOT deleted")
        #expect(try fixture.pendingCount() == 1, "the tombstone survives for the retry pass")
        // Restart/resume: the readiness pass after the worker released the
        // output completes the SAME request idempotently.
        holder.live = false
        let retry = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot,
            liveOwnership: holder
        ) { _ in false }
        #expect(retry.completedRequests == 1)
        #expect(!fixture.snapshotTreeExists(runID: run))
        #expect(try fixture.pendingCount() == 0)
    }

    @Test("cleanup failure after the cascade keeps the request; the retry pass completes it")
    func cleanupFailureKeepsRequestAndRetries() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        let tree = artifactTreeParent(fixture: fixture, runID: run)
        try fixture.seedSnapshot(runID: run)
        // Read-only parent directory: the owned-tree unlink must fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tree.path)
        let outcome = try await RunOutputDeletionOrder.perform(
            conversationID: conversation, durableRunIDs: [run],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { /* cascade committed */ }
        guard case .cleanupDeferred = outcome else {
            Issue.record("expected cleanupDeferred, got \(outcome)")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.path)
            return
        }
        #expect(try fixture.pendingCount() == 1)
        // Repair and resume.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.path)
        let retry = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot
        ) { _ in false }
        #expect(retry.completedRequests == 1)
        #expect(!fixture.snapshotTreeExists(runID: run))
    }

    /// `RunOutputs/` directory — the level whose permissions gate deletion of
    /// a run tree (unlink needs write permission on the PARENT).
    private func artifactTreeParent(fixture: RunOutputDeletionOrderTests.Fixture, runID: UUID) -> URL {
        fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
    }

    // MARK: - 2026-10-27 lifetime review: cleanup claim IS the exclusion

    /// A gate whose cleanup claim is independently controllable: it models
    /// the runtime facade's lease-aware claim/admission fence.
    private final class ControllableClaimGate: RunOutputOperationGate, @unchecked Sendable {
        private let lock = NSLock()
        private var allowClaim = true
        var beginCleanupCount = 0
        var endCleanupCount = 0
        var lastClaimedRunIDs: [UUID] = []

        func beginPublication(runID: UUID) -> RunOutputPublicationTicket? { nil }
        func endPublication(_ ticket: RunOutputPublicationTicket) {}
        func isPublicationCurrent(_ ticket: RunOutputPublicationTicket) -> Bool { true }

        func setAllowClaim(_ value: Bool) {
            lock.lock(); allowClaim = value; lock.unlock()
        }
        func beginCleanup(runIDs: [UUID]) -> Bool {
            lock.lock()
            beginCleanupCount += 1
            lastClaimedRunIDs = runIDs
            let allowed = allowClaim
            lock.unlock()
            return allowed
        }
        func endCleanup(runIDs: [UUID]) {
            lock.lock(); endCleanupCount += 1; lock.unlock()
        }
    }

    @Test("a probe-says-safe window is NOT proof: the claim decides the race")
    func claimRefusalDefersEvenWhenProbeWasFalse() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        let gate = ControllableClaimGate()
        // The probe reports NO live owner (it observed the world before
        // the claim window). A publication then leases the run; the
        // runtime's beginCleanup — which re-checks leases under its lock,
        // exactly like `RuntimeFacadeRunOutput` — refuses here. Cleanup
        // must defer, keeping BOTH the trees and the tombstone. The claim
        // refusal, not the earlier boolean probe, is the exclusion.
        final class FalseProbe: RunOutputLiveOwnership, @unchecked Sendable {
            func ownsRunOutput(runID: UUID) async throws -> Bool { false }
        }
        gate.setAllowClaim(false)
        let outcome = try await RunOutputDeletionOrder.perform(
            conversationID: conversation, durableRunIDs: [run],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot,
            liveOwnership: FalseProbe(),
            operationGate: gate
        ) { /* cascade committed */ }
        #expect(outcome == .deferredLiveOwnership)
        #expect(gate.beginCleanupCount == 1 && gate.endCleanupCount == 0)
        #expect(gate.lastClaimedRunIDs == [run])
        #expect(fixture.snapshotTreeExists(runID: run), "the publication's bytes are intact")
        #expect(try fixture.pendingCount() == 1)
    }

    @Test("the claim is held across removal AND completion, then released")
    func claimIsHeldAcrossRemoveAndComplete() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        final class RecordingGate: RunOutputOperationGate, @unchecked Sendable {
            var sawTreeDuringClaim = false
            var root: URL!
            var namespace: URL!
            var beginCleanupCount = 0
            var endCleanupCount = 0
            func beginPublication(runID: UUID) -> RunOutputPublicationTicket? { nil }
            func endPublication(_ ticket: RunOutputPublicationTicket) {}
            func isPublicationCurrent(_ ticket: RunOutputPublicationTicket) -> Bool { true }
            func beginCleanup(runIDs: [UUID]) -> Bool {
                beginCleanupCount += 1
                // While the claim is held the owned tree must still exist
                // (removal happens strictly inside the claim).
                sawTreeDuringClaim = FileManager.default.fileExists(atPath: namespace.path)
                return true
            }
            func endCleanup(runIDs: [UUID]) { endCleanupCount += 1 }
        }
        let gate = RecordingGate()
        gate.root = fixture.artifactRoot
        gate.namespace = fixture.artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(run.uuidString, isDirectory: true)
        let outcome = try await RunOutputDeletionOrder.perform(
            conversationID: conversation, durableRunIDs: [run],
            storeRoot: fixture.storeRoot, artifactRoot: fixture.artifactRoot,
            liveOwnership: nil,
            operationGate: gate
        ) { /* cascade committed */ }
        #expect(outcome == .removed)
        #expect(gate.beginCleanupCount == 1 && gate.endCleanupCount == 1)
        #expect(gate.sawTreeDuringClaim, "the removal must run inside the held claim")
        #expect(!fixture.snapshotTreeExists(runID: run))
        #expect(try fixture.pendingCount() == 0)
    }

    @Test("readiness retry: claim refusal retains everything; the later claim completes")
    func retryClaimRefusalRetainsAndLaterCompletes() async throws {
        let fixture = try Fixture()
        let conversation = UUID()
        let run = UUID()
        try fixture.seedSnapshot(runID: run)
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [run]), storeRoot: fixture.storeRoot)
        let gate = ControllableClaimGate()
        gate.setAllowClaim(false)
        let first = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            operationGate: gate
        ) { _ in false }
        #expect(first.completedRequests == 0)
        #expect(first.retainedLiveOutputRequests == 1)
        #expect(first.failedRequestCount == 0)
        #expect(fixture.snapshotTreeExists(runID: run))
        #expect(try fixture.pendingCount() == 1)
        // Publication released; the next readiness claim wins and finishes
        // the SAME persisted request.
        gate.setAllowClaim(true)
        let second = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: fixture.storeRoot,
            artifactRoot: fixture.artifactRoot,
            operationGate: gate
        ) { _ in false }
        #expect(second.completedRequests == 1)
        #expect(!fixture.snapshotTreeExists(runID: run))
        #expect(try fixture.pendingCount() == 0)
        #expect(gate.beginCleanupCount == 2 && gate.endCleanupCount == 1)
    }
}
