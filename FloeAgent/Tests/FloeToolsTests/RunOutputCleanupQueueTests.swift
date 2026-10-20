// FloeToolsTests — Durable exact run-output cleanup semantics (S3-D).
// Real files, real request records, real snapshot trees under an injected
// artifact root: enqueue/pending/complete, owned-only removal, symlink and
// foreign-component refusal, idempotent absence, malformed-record refusal,
// and the bootstrap tombstone retry that only cleans conversations verified
// absent. No global scans, no guessed orphans.

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

}
