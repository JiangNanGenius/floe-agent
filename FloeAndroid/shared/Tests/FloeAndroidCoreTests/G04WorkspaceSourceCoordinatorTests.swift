// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 trusted source coordinator + host mailbox — REAL journal-47 and
// real-ticket source tests.
//
// AUTHORED, NOT EXECUTED (grouped qualification is Main's). Storage is the
// original file-backed DatabaseManager (same migration chain as every other
// persistence test); the mailbox cases drive the SAME Swift entry points the
// Kotlin JNI binds to (`bind/nextClaim/describe/takePayload/complete/
// shouldStop/close`) — Swift calling Swift, like the attachment lane's
// `_cdecl` exercises. Synthetic bytes only.
//
// Proven contract surface:
//   * the journal sequence the coordinator consumes stays one-time/
//     CAS/late-settle honest across a real DB reopen;
//   * unbound/closed host pump = typed refusal with NO side effect;
//   * stale-generation claims can never settle the current table and a
//     late/duplicate settle is classified, never resumed twice;
//   * the frozen gateway failure vocabulary relays to exact typed
//     coordinator refusals (a Kotlin success string is never authority).
//
// The FULL coordinator lifecycle (live conversation/workspace validation +
// owned leases + two-phase provider replacement through a real pump) runs in
// Main's grouped cohort on the installed-generation fixture; this file keeps
// the module-runnable halves.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAndroidCore

final class G04WorkspaceSourceCoordinatorTests: XCTestCase {

    // MARK: - Real journal storage (same original DatabaseManager)

    private func withSourceDatabase(_ body: @Sendable (DatabaseManager, URL, UUID) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g04-source-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("original.sqlite")
        let database = try DatabaseManager(path: path)
        let workspaceID = UUID()
        do {
            try await database.migrate()
            try await SQLiteWorkspaceStore(database: database).saveWorkspace(
                WorkspaceRecord(id: workspaceID, name: "SAF fixture", rootBookmark: Data()))
            try await body(database, path, workspaceID)
            try await database.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// prepare -> ONE-TIME claim -> reopen (process death) -> CAS finish.
    /// Mirrors the authority MAIN's coordinator consumes byte-for-byte: the
    /// persisted `writing` row never receives a second permit, and commit
    /// advances the binding ONLY through the revision CAS with the actual
    /// read-back digest.
    func testJournalOneTimeClaimAndCasFinishSurviveReopen() async throws {
        let original = Data("provider original".utf8)
        let replacement = Data("native replacement".utf8)
        try await withSourceDatabase { database, path, workspaceID in
            let store = AndroidWorkspaceSourceStore(database: database)
            let source = try await store.bind(
                id: UUID(), workspaceID: workspaceID, logicalPath: "Imported/doc.kt",
                kind: .saf,
                sourceReference: "content://com.floe.fixture/tree/7/document/42",
                sourceDocumentID: "42",
                sourceSHA256: FloeDigest.sha256Hex(original))
            let prepared = try await store.prepareRecovery(
                id: UUID(), sourceID: source.id, expectedRevision: source.revision,
                backupRelativePath: "Source Recovery/\(source.id.uuidString)/backup.bin",
                backupSHA256: FloeDigest.sha256Hex(original),
                replacementSHA256: FloeDigest.sha256Hex(replacement))
            XCTAssertEqual(prepared.state, .prepared)
            try await database.close()

            let reopened = try DatabaseManager(path: path)
            defer { Task { try? await reopened.close() } }
            try await reopened.migrate()
            let recoveredStore = AndroidWorkspaceSourceStore(database: reopened)
            // Process death BEFORE the claim: still exactly one prepared row.
            let pending = try await recoveredStore.pendingRecovery(workspaceID: workspaceID)
            XCTAssertEqual(pending.map(\.id), [prepared.id])
            let claimed = try await recoveredStore.claimRecovery(
                id: prepared.id, observedSourceSHA256: FloeDigest.sha256Hex(original))
            XCTAssertEqual(claimed.state, .writing)
            do {
                _ = try await recoveredStore.claimRecovery(
                    id: prepared.id, observedSourceSHA256: FloeDigest.sha256Hex(original))
                XCTFail("a persisted writing receipt re-issued a second write permit")
            } catch AndroidWorkspaceSourceError.invalidTransition { }
            let committed = try await recoveredStore.finishRecovery(
                id: prepared.id, requestedState: .committed,
                observedSHA256: FloeDigest.sha256Hex(replacement))
            XCTAssertEqual(committed.state, .committed)
            let reboundRow = try await recoveredStore.source(id: source.id)
            let rebound = try XCTUnwrap(reboundRow)
            XCTAssertEqual(rebound.sourceSHA256, FloeDigest.sha256Hex(replacement))
            XCTAssertNotEqual(rebound.revision, source.revision)
        }
    }

    /// External drift at the CLAIM boundary records `conflict` (observed !=
    /// journaled backup) and the binding revision stays unchanged — the
    /// coordinator's "fresh observation" rule has no softer branch.
    func testClaimWithDriftedSourceObservesConflictNotPermit() async throws {
        let original = Data("provider original".utf8)
        let drifted = Data("someone else wrote".utf8)
        try await withSourceDatabase { database, _, workspaceID in
            let store = AndroidWorkspaceSourceStore(database: database)
            let source = try await store.bind(
                id: UUID(), workspaceID: workspaceID, logicalPath: "doc.kt", kind: .saf,
                sourceReference: "content://com.floe.fixture/document/9",
                sourceDocumentID: nil, sourceSHA256: FloeDigest.sha256Hex(original))
            let prepared = try await store.prepareRecovery(
                id: UUID(), sourceID: source.id, expectedRevision: source.revision,
                backupRelativePath: "Source Recovery/backup.bin",
                backupSHA256: FloeDigest.sha256Hex(original),
                replacementSHA256: FloeDigest.sha256Hex(original))
            let claim = try await store.claimRecovery(
                id: prepared.id, observedSourceSHA256: FloeDigest.sha256Hex(drifted))
            XCTAssertEqual(claim.state, .conflict)
            let currentRow = try await store.source(id: source.id)
            let unchanged = try XCTUnwrap(currentRow)
            XCTAssertEqual(unchanged, source)
        }
    }

    // MARK: - Host mailbox pump contract

    func testMailboxFencesStaleGenerationsAndLateSettles() async throws {
        let mailbox = G04WorkspaceSourceMailbox.shared
        let epochA = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(mailbox.bind(epoch: epochA))
        XCTAssertFalse(mailbox.bind(epoch: epochA)) // never equal
        let epochB = epochA &+ 1_000
        XCTAssertTrue(mailbox.bind(epoch: epochB))   // strictly newer
        let submission = Task {
            try await mailbox.submit(operation: "source.read",
                                     descriptor: ["taskID": UUID().uuidString],
                                     staged: Data(), cancellation: CancellationToken())
        }
        // Claim under epoch B, then rebind to an even newer generation: the
        // waiter settles typed ONCE and the old claim can never complete the
        // new table.
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertNotEqual(claim, 0)
        let epochC = epochB &+ 1_000
        XCTAssertTrue(mailbox.bind(epoch: epochC))
        do {
            _ = try await submission.value
            XCTFail("fenced waiter resumed successfully")
        } catch G04SourceMailboxError.hostFenced { }
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data("late".utf8)), -102)
        mailbox.close(epoch: epochC)
        do {
            _ = try await mailbox.submit(operation: "source.read",
                                         descriptor: ["taskID": UUID().uuidString],
                                         staged: Data(), cancellation: CancellationToken())
            XCTFail("closed mailbox admitted work")
        } catch G04SourceMailboxError.hostUnbound { }
    }

    func testMailboxSingleSettleAndCancellationIsRequestOnly() async throws {
        let mailbox = G04WorkspaceSourceMailbox.shared
        let epoch = mailbox.boundEpoch &+ 100_000
        XCTAssertTrue(mailbox.bind(epoch: epoch))
        let cancellation = CancellationToken()
        let providerData = Data("provider bytes".utf8)
        let waiter = Task {
            try await mailbox.submit(operation: "source.read",
                                     descriptor: ["taskID": UUID().uuidString],
                                     staged: Data(), cancellation: cancellation)
        }
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertNotEqual(claim, 0)
        cancellation.cancel()
        // Cancellation is only a REQUEST: the ticket stays settle-able and
        // shouldStop surfaces the intent to the host.
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: providerData), 0)
        let result = try await waiter.value
        XCTAssertEqual(result, providerData)   // the real IO already settled
        // Duplicate/late settle on the retired claim is classified.
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), -101)
    }

    func testTransportErrorVocabularyMapsFrozenGatewayCodes() {
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.remoteFailed(code: "revoked")),
                       .providerFailed(code: "revoked"))
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.remoteFailed(code: "grantMissing")),
                       .providerFailed(code: "grantMissing"))
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.remoteFailed(code: "hostBudget")),
                       .transitionRefused("hostBudget"))
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.hostUnbound), .transportNotBound)
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.hostClosed), .transportNotBound)
        XCTAssertEqual(G04WorkspaceSourceMailboxTransport.relay(.saturated),
                       .transitionRefused("mailboxSaturated"))
    }

    override func tearDown() async throws {
        G04WorkspaceSourceMailbox.shared.close(epoch: G04WorkspaceSourceMailbox.shared.boundEpoch)
        try await super.tearDown()
    }
}
