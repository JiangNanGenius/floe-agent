// FloeAppTests — native CAD proposal persistence, recovery and origin
// notification.
//
// The durable store must survive a "relaunch" (a fresh CadDocumentCenter over
// the same store file): pending proposals restore, preview/apply enforce the
// recorded owner/environment/canonical target, applied receipts replay, an
// interrupted apply is recovered HONESTLY (never a fabricated "applied"), a
// manual change supersedes a pending proposal and the originating task
// receives adoption/rejection/manual-conflict decisions through the shared
// durable outbox.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloeWorkbench

@MainActor
final class NativeCADProposalPersistenceTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var storeFile: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-native-persist-\(UUID().uuidString)")
        root = base.appendingPathComponent("workspace")
        storeFile = base.appendingPathComponent("native-proposals.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let url = root.appendingPathComponent("part.floecad")
        if FileManager.default.fileExists(atPath: url.path) {
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func access(owner: UUID, environment: String = "env-1") -> CadDocumentAccess {
        CadDocumentAccess(environmentID: environment, workspacePath: root.path,
                          ownerKind: "chat", ownerID: owner)
    }

    private func makeDocument() async throws {
        _ = try await FloeCADDocument.create(at: root.appendingPathComponent("part.floecad"),
                                             name: "PartA")
    }

    @discardableResult
    private func propose(_ center: CadDocumentCenter, _ access: CadDocumentAccess,
                         summary: String = "Probe sketch") async throws -> UUID {
        let request: [String: Any] = ["kind": "propose", "op": "sketch.create",
                                      "args": ["name": "Probe"], "summary": summary]
        let reply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: request),
                                encoding: .utf8)!,
            access: access)
        let object = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
        let proposal = try XCTUnwrap(object["proposal"] as? [String: Any])
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
    }

    @discardableResult
    private func apply(_ center: CadDocumentCenter, _ proposal: UUID, _ grant: String,
                       _ access: CadDocumentAccess, requestID: String) async throws -> [String: Any] {
        let request: [String: Any] = ["kind": "apply", "proposal_id": proposal.uuidString,
                                      "grant_id": grant, "request_id": requestID]
        let reply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: request),
                                encoding: .utf8)!,
            access: access)
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
    }

    private func preview(_ center: CadDocumentCenter, _ proposal: UUID,
                         _ access: CadDocumentAccess) async throws -> String {
        let request: [String: Any] = ["kind": "preview", "proposal_id": proposal.uuidString]
        return try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: request),
                                encoding: .utf8)!,
            access: access)
    }

    private func store() -> NativeCADProposalStore {
        NativeCADProposalStore(fileURL: storeFile)
    }

    private func assertThrows(_ message: String,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected an error: \(message)", file: file, line: line)
        } catch { /* expected */ }
    }

    // MARK: - Persistence across a center restart

    /// Propose with center A; a FRESH center B over the same store file
    /// (the relaunch) serves preview under the same access, refuses foreign
    /// access, restores the banner proposal, mints a grant and applies.
    func testProposalPersistsAcrossCenterRestart() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let centerA = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)

        let proposal = try await propose(centerA, accessA)
        XCTAssertNotNil(store().record(for: proposal), "propose must persist before the reply")

        // Relaunch: fresh center, same store file, empty in-process state.
        let centerB = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let restored = await centerB.pendingNativeProposals(for: root.appendingPathComponent("part.floecad"))
        XCTAssertTrue(restored.contains { $0.id == proposal },
                      "the restored banner must list the durable pending proposal")

        let previewReply = try await preview(centerB, proposal, accessA)
        let previewObject = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(previewReply.utf8))) as? [String: Any])
        XCTAssertEqual(previewObject["ok"] as? Bool, true)
        XCTAssertEqual(previewObject["summary"] as? String, "Probe sketch")

        // Foreign owner cannot even preview: same denial as unknown.
        let foreign = access(owner: UUID(), environment: "env-2")
        await assertThrows("foreign preview") {
            _ = try await self.preview(centerB, proposal, foreign)
        }
        // Cross-document preview is refused.
        await assertThrows("cross-document preview") {
            let request: [String: Any] = ["kind": "preview", "proposal_id": proposal.uuidString]
            _ = try await centerB.threeDAction(
                documentID: "other.floecad",
                requestJSON: String(data: try JSONSerialization.data(withJSONObject: request),
                                    encoding: .utf8)!,
                access: accessA)
        }

        // The restored proposal confirms and applies through the fresh center.
        let grant = try await centerB.issueNativeCADGrant(proposalID: proposal)
        let applied = try await apply(centerB, proposal, grant, accessA, requestID: "restart-1")
        XCTAssertEqual(applied["ok"] as? Bool, true)

        let reopened = try await FloeCADDocument.open(at: root.appendingPathComponent("part.floecad"))
        XCTAssertEqual(reopened.summary().sketchCount, 1)
        reopened.close()
    }

    /// The applied receipt replays after a restart for the same request id;
    /// a different request id is refused; a foreign access is unauthorized.
    func testAppliedReceiptReplaysAcrossRestart() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let centerA = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(centerA, accessA)
        let grant = try await centerA.issueNativeCADGrant(proposalID: proposal)
        let applied = try await apply(centerA, proposal, grant, accessA, requestID: "req-a")
        let revision = try XCTUnwrap((applied["receipt"] as? [String: Any])?["revision"] as? Int)

        let centerB = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let replay = try await apply(centerB, proposal, grant, accessA, requestID: "req-a")
        XCTAssertEqual(replay["replay"] as? Bool, true)
        XCTAssertEqual((replay["receipt"] as? [String: Any])?["revision"] as? Int, revision)

        await assertThrows("different request id after restart") {
            _ = try await self.apply(centerB, proposal, grant, accessA, requestID: "req-b")
        }
        await assertThrows("foreign access replay") {
            _ = try await self.apply(centerB, proposal, grant,
                                     self.access(owner: UUID(), environment: "env-9"),
                                     requestID: "req-a")
        }
        // Exactly one mutation despite the replay attempts.
        let reopened = try await FloeCADDocument.open(at: root.appendingPathComponent("part.floecad"))
        XCTAssertEqual(reopened.summary().sketchCount, 1)
        reopened.close()
    }

    // MARK: - Failure between commit and receipt

    /// An `.applying` record whose package advanced WITHOUT a verified
    /// receipt is recovered as `.interrupted`: the origin task is told the
    /// outcome is unknown, nothing claims "applied", and the proposal never
    /// implies a safe retry.
    func testInterruptedApplyRecoveredHonestly() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)

        // Simulate the crash window: intent written (bound to the expected
        // result revision), then the document committed through the shared
        // live session with NO receipt journal entry — exactly the gap
        // between package commit and receipt persistence.
        let docURL = root.appendingPathComponent("part.floecad")
        let base = try await FloeCADDocument.storedIdentity(at: docURL)
        try await store().markApplying(proposal, expectedResultRevision: (base?.revision ?? 0) + 1)
        let live = try await FloeCAD3DBridge.shared.openDocument(at: docURL)
        XCTAssertTrue(live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Manual"}}"#.utf8)).isOK)
        let manualSave = await live.save()
        XCTAssertTrue(manualSave.succeeded)

        // A fresh center (relaunch) reconciles from the durable store only.
        let centerB = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        await centerB.reconcileNativeProposals()

        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .interrupted,
                       "an unverified advanced package must not recover as applied or retryable-pending")
        XCTAssertNotEqual(record.status, .applied)
        XCTAssertTrue(record.statusNote?.contains("interrupted") == true
                      || record.statusNote?.contains("Re-read") == true)
        let decisions = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal }
        XCTAssertTrue(decisions.contains { $0.decision.contains("interrupted") },
                      "the origin task must learn the outcome is unknown: \(decisions.map(\.decision))")
        XCTAssertFalse(decisions.contains { $0.decision == "applied" })

        // The interrupted proposal cannot be applied or re-confirmed.
        await assertThrows("apply after interruption") {
            let grant = try await centerB.issueNativeCADGrant(proposalID: proposal)
            _ = try await self.apply(centerB, proposal, grant, accessA, requestID: "late")
        }
        await assertThrows("tool apply after interruption") {
            _ = try await self.apply(centerB, proposal, "forged", accessA, requestID: "late-2")
        }
    }

    /// Crash BEFORE the commit: the verified revision is still the base, so
    /// recovery returns the proposal to pending and the same confirmed change
    //  can be applied after a relaunch — with idempotent receipt replay.
    func testCrashBeforeCommitAllowsHonestRetryAfterRelaunch() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)

        // Intent persisted, then the process dies before any mutation.
        let docURL = root.appendingPathComponent("part.floecad")
        let base = try await FloeCADDocument.storedIdentity(at: docURL)
        try await store().markApplying(proposal, expectedResultRevision: (base?.revision ?? 0) + 1)

        let centerB = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        await centerB.reconcileNativeProposals()
        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .pending,
                       "nothing reached the package, so an honest retry remains possible")

        // The grant does not survive a relaunch (in-memory store): the UI
        // re-confirms through the restored proposal, then the apply commits
        // exactly once and replays without re-applying.
        let freshGrant = try await centerB.issueNativeCADGrant(proposalID: proposal)
        let applied = try await apply(centerB, proposal, freshGrant, accessA, requestID: "retry-1")
        XCTAssertEqual(applied["ok"] as? Bool, true)
        let replay = try await apply(centerB, proposal, freshGrant, accessA, requestID: "retry-1")
        XCTAssertEqual(replay["replay"] as? Bool, true)

        let centerC = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let replayAgain = try await apply(centerC, proposal, freshGrant, accessA, requestID: "retry-1")
        XCTAssertEqual(replayAgain["replay"] as? Bool, true,
                       "a second relaunch replays the recorded receipt")
        let identity = try await FloeCADDocument.storedIdentity(at: docURL)
        let document = try await FloeCADDocument.open(at: docURL)
        XCTAssertEqual(document.summary().sketchCount, 1, "exactly one apply ever ran")
        XCTAssertEqual(document.revision, identity?.revision)
        document.close()
    }

    /// The commit→receipt gap closed by reconciliation: a package that
    /// actually committed while the receipt write was interrupted is
    /// recovered as APPLIED when the completed journal entry validates
    /// against the VERIFIED store identity (never a directory hash), the
    /// original owner is notified, and a replay returns the receipt without
    /// re-applying.
    func testCrashAfterCommitReconstructsAppliedFromVerifiedJournal() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)

        // Commit through the live session while the center's receipt path
        // never ran (crash window), leaving only the durable intent.
        let docURL = root.appendingPathComponent("part.floecad")
        let base = try await FloeCADDocument.storedIdentity(at: docURL)
        try await store().markApplying(proposal, expectedResultRevision: (base?.revision ?? 0) + 1)
        let live = try await FloeCAD3DBridge.shared.openDocument(at: docURL)
        XCTAssertTrue(live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Adopted"}}"#.utf8)).isOK)
        let save = await live.save()
        XCTAssertTrue(save.succeeded)

        // The receipt journal DID land before the crash (bounded gap), with
        // the verified store content hash — not a package-directory hash.
        guard let verified = await FloeCADDocument.storedIdentity(at: docURL) else {
            XCTFail("the committed package must have a verified store identity")
            return
        }
        XCTAssertEqual(verified.contentSHA256, save.contentSHA256,
                       "the live commit hash must equal the verified store identity")
        let receipt = CadDocumentReceipt(documentID: "part.floecad",
                                         revision: Int64(save.revision),
                                         sha256: verified.contentSHA256,
                                         created: [], saved: true, note: "test")
        try CadAppliedReceiptJournal.shared.prepare(proposalID: proposal,
                                                    expectedSHA256: verified.contentSHA256,
                                                    pendingReceipt: receipt)
        try CadAppliedReceiptJournal.shared.complete(proposalID: proposal, receipt: receipt)

        // Relaunch: fresh center, no in-process tombstones.
        let centerB = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        await centerB.reconcileNativeProposals()

        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .applied)
        XCTAssertEqual(record.receipt?.revision, save.revision)
        let decisions = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal }
        XCTAssertTrue(decisions.contains { $0.decision == "applied" },
                      "the original owner must be notified of the adoption: \(decisions.map(\.decision))")

        // The same request id replays the receipt on the reconstructed
        // center WITHOUT re-applying; the recovered receipt keeps the
        // recorded "recovered" request key.
        let replay = try await apply(centerB, proposal, "consumed-grant", accessA,
                                     requestID: "recovered")
        XCTAssertEqual(replay["replay"] as? Bool, true)
        let document = try await FloeCADDocument.open(at: docURL)
        XCTAssertEqual(document.summary().sketchCount, 1, "reconciliation must not re-apply")
        document.close()
    }

    // MARK: - Decisions to the originating task

    func testRejectionIsDurableAndNotifiesOrigin() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)

        await center.rejectNativeCADProposal(proposal)

        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .rejected)
        let decisions = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal && $0.conversationID == owner }
        XCTAssertTrue(decisions.contains { $0.decision == "rejected" })

        // A rejected proposal cannot be applied or re-confirmed.
        await assertThrows("apply after reject") {
            let grant = try await center.issueNativeCADGrant(proposalID: proposal)
            _ = try await self.apply(center, proposal, grant, accessA, requestID: "late")
        }
    }

    func testAppliedDecisionDeliveredThroughInjectedDeliverer() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        struct Delivery: Sendable, Equatable {
            var conversation: UUID
            var proposal: UUID
            var decision: String
            var revision: Int64?
        }
        final class DeliveryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Delivery] = []
            func append(_ delivery: Delivery) {
                lock.lock(); defer { lock.unlock() }
                values.append(delivery)
            }
            func all() -> [Delivery] {
                lock.lock(); defer { lock.unlock() }
                return values
            }
        }
        let box = DeliveryBox()
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile) { conversation, proposal, decision, revision, _ in
            box.append(Delivery(conversation: conversation, proposal: proposal,
                                decision: decision, revision: revision))
        }
        let proposal = try await propose(center, accessA)
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)
        _ = try await apply(center, proposal, grant, accessA, requestID: "notify-1")

        // Delivery runs on a detached task; allow it to land.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if box.all().contains(where: { $0.proposal == proposal && $0.decision == "applied" }) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let deliveries = box.all()
        XCTAssertTrue(deliveries.contains { $0.conversation == owner && $0.proposal == proposal
            && $0.decision == "applied" && $0.revision != nil })
        // The durable copy is marked delivered.
        let pending = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal && $0.decision == "applied" }
        XCTAssertTrue(pending.isEmpty, "a delivered decision must be marked delivered: \(pending)")
    }

    /// A manual edit past the base revision supersedes a pending proposal;
    /// the banner restore reports the conflict and the origin task is told.
    func testManualChangeSupersedesPendingProposal() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)

        // Manual edit through the shared live session, committed.
        let live = try await FloeCAD3DBridge.shared.openDocument(at: root.appendingPathComponent("part.floecad"))
        XCTAssertTrue(live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"ByHand"}}"#.utf8)).isOK)
        let byHandSave = await live.save()
        XCTAssertTrue(byHandSave.succeeded)

        let pending = await center.pendingNativeProposals(for: root.appendingPathComponent("part.floecad"))
        XCTAssertFalse(pending.contains { $0.id == proposal },
                       "a stale proposal must not stay in the banner")
        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .superseded)
        let decisions = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal }
        XCTAssertTrue(decisions.contains { $0.decision == "invalidated by a manual change" })

        // Applying the superseded proposal fails with the honest reason.
        do {
            let grant = try await center.issueNativeCADGrant(proposalID: proposal)
            _ = try await apply(center, proposal, grant, accessA, requestID: "stale-apply")
            XCTFail("a superseded proposal must not apply")
        } catch {
            // The grant cannot even be minted (not pending) — either refusal
            // is acceptable; the document must be untouched by the proposal.
        }
        let reopened = try await FloeCADDocument.open(at: root.appendingPathComponent("part.floecad"))
        XCTAssertEqual(reopened.summary().sketchCount, 1, "only the manual sketch exists")
        reopened.close()
    }

    // MARK: - Store hardening (review: versioned envelope, bounded growth)

    private func syntheticRecord(_ id: UUID, status: NativeCADProposalStore.Status,
                                 created: Date = Date()) -> NativeCADProposalStore.Record {
        NativeCADProposalStore.Record(
            proposalID: id,
            canonicalDocumentPath: "/tmp/part.floecad",
            access: NativeCADProposalStore.AccessRecord(
                CadDocumentAccess(environmentID: "env", workspacePath: "/tmp",
                                  ownerKind: "chat", ownerID: UUID())),
            baseRevision: 1,
            baseContentSHA256: "abc",
            summary: "Synthetic",
            operationJSON: #"{"op":"sketch.create","args":{}}"#,
            proposalJSON: #"{"id":"\#(id.uuidString)","documentPath":"/tmp/part.floecad","baseRevision":1,"baseContentSHA256":"abc","summary":"Synthetic","operationJSON":"{}","createdAt":"2026-10-10T00:00:00Z","preview":{"bodyCountBefore":0,"bodyCountAfter":0,"addedBodyNames":[],"removedBodyNames":[],"volumeBeforeMM3":0,"volumeAfterMM3":0,"evalErrors":[],"failed":false}}"#,
            createdAt: created,
            status: status,
            statusNote: nil,
            receipt: nil)
    }

    /// Missing file is a clean slate; the first save creates the envelope.
    func testMissingFileStartsCleanAndPersists() async throws {
        let store = self.store()
        XCTAssertNil(store.recoveryHint)
        try await store.save(syntheticRecord(UUID(), status: .pending))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFile.path))
        XCTAssertEqual(store.allRecords().count, 1)
    }

    /// Corrupt bytes are preserved, every write throws a recoverable error,
    /// and quarantine moves the evidence aside so persistence can resume.
    func testCorruptStateIsNotOverwrittenAndQuarantines() async throws {
        try Data("{ this is not valid json".utf8).write(to: storeFile)
        let corruptBytes = try Data(contentsOf: storeFile)
        let store = self.store()
        XCTAssertNotNil(store.recoveryHint)
        await assertThrows("save over corrupt state") {
            try await store.save(self.syntheticRecord(UUID(), status: .pending))
        }
        // The evidence is byte-identical — nothing overwrote it.
        XCTAssertEqual(try Data(contentsOf: storeFile), corruptBytes)
        XCTAssertTrue(store.allRecords().isEmpty)

        // Explicit recovery quarantines the bytes and resumes persistence.
        let sidecar = store.quarantineCorruptState()
        XCTAssertNotNil(sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar!.path))
        XCTAssertEqual(try Data(contentsOf: sidecar!), corruptBytes)
        XCTAssertNil(store.recoveryHint)
        try await store.save(syntheticRecord(UUID(), status: .pending))
        XCTAssertEqual(store.allRecords().count, 1)
    }

    /// A newer schema version is rejected (downgrade must not destroy newer
    /// state), the file stays untouched, and quarantine recovers.
    func testNewerSchemaIsRejectedAndPreserved() async throws {
        let envelope: [String: Any] = ["schemaVersion": 99, "records": [:]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: storeFile)
        let store = self.store()
        XCTAssertNotNil(store.recoveryHint)
        await assertThrows("save over newer schema") {
            try await store.save(self.syntheticRecord(UUID(), status: .pending))
        }
        XCTAssertEqual(try Data(contentsOf: storeFile), data, "newer-schema state must be preserved")
        XCTAssertNotNil(store.quarantineCorruptState())
        XCTAssertNil(store.recoveryHint)
    }

    /// Active-record saturation refuses a new pending proposal with a clear
    /// resource error — it never drops pending/applying records.
    func testActiveRecordSaturationRefusesWithoutDropping() async throws {
        let store = self.store()
        let limit = store.maximumActiveRecords
        var oldestActive: UUID?
        for index in 0..<limit {
            let id = UUID()
            if index == 0 { oldestActive = id }
            try await store.save(syntheticRecord(id, status: .pending,
                                                 created: Date().addingTimeInterval(TimeInterval(-index))))
        }
        await assertThrows("active saturation") {
            try await store.save(self.syntheticRecord(UUID(), status: .pending))
        }
        // Everything active survived; the refused record is not persisted.
        XCTAssertEqual(store.allRecords().count, limit)
        XCTAssertNotNil(store.record(for: oldestActive!))

        // Settling one opens a slot again.
        if let first = oldestActive {
            try await store.markApplied(
                first,
                receipt: NativeCADProposalStore.ReceiptRecord(
                    revision: 2, contentSHA256: "def", message: "ok",
                    requestID: "r", appliedAt: Date()))
        }
        try await store.save(syntheticRecord(UUID(), status: .pending))
        let activeAfter = store.allRecords().filter {
            $0.status == .pending || $0.status == .applying
        }.count
        XCTAssertEqual(activeAfter, limit, "one settled record opened one active slot")
    }

    /// Total-record overflow prunes the oldest SETTLED records only; active
    /// records always survive.
    func testSettledRecordsPruneOldestFirstActiveSurvives() async throws {
        let store = self.store()
        let total = store.maximumRecords
        let now = Date()
        // Fill the store with settled records, oldest first.
        for index in 0..<total {
            try await store.save(syntheticRecord(UUID(), status: .applied,
                                                 created: now.addingTimeInterval(TimeInterval(-1000 + index))))
        }
        // One active record that must survive every prune.
        let activeID = UUID()
        try await store.save(syntheticRecord(activeID, status: .pending, created: now))
        // Overflow by one: the oldest settled record prunes, the active stays.
        try await store.save(syntheticRecord(UUID(), status: .applied, created: now.addingTimeInterval(TimeInterval(1))))
        let records = store.allRecords()
        XCTAssertEqual(records.count, total, "total count stays bounded")
        XCTAssertNotNil(store.record(for: activeID), "active records are never pruned")
        XCTAssertEqual(records.filter { $0.status == .pending || $0.status == .applying }.count, 1)
    }

    /// A manual change after grant issuance fails honestly: the grant binds
    /// the proposal's base revision, so the reserve succeeds, the bridge
    /// refuses the stale binding, the reservation is released, the durable
    /// record returns to pending and the originating task is told "failed to
    /// apply" — never a silent swallow.
    func testFailedApplyReturnsToPendingAndNotifies() async throws {
        try await makeDocument()
        let owner = UUID()
        let accessA = access(owner: owner)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeFile)
        let proposal = try await propose(center, accessA)
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)

        // Stale the proposal after the grant exists: the reserve reports the
        // real revision mismatch, no mutation happens, the durable record is
        // untouched and no failure decision fires (the proposal stays pending).
        let live = try await FloeCAD3DBridge.shared.openDocument(at: root.appendingPathComponent("part.floecad"))
        XCTAssertTrue(live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Manual"}}"#.utf8)).isOK)
        let manualSave = await live.save()
        XCTAssertTrue(manualSave.succeeded)

        do {
            _ = try await apply(center, proposal, grant, accessA, requestID: "will-stale")
            XCTFail("stale apply must fail")
        } catch { /* expected */ }

        let record = try XCTUnwrap(store().record(for: proposal))
        XCTAssertEqual(record.status, .pending,
                       "the released reservation leaves an honest retry")
        XCTAssertNotNil(record.statusNote)
        let decisions = DrawingAssistantDecisionStore.shared.pendingDeliveries()
            .filter { $0.proposalID == proposal }
        XCTAssertTrue(decisions.contains { $0.decision == "failed to apply" },
                      "the origin task must be told the confirmed change failed: \(decisions.map(\.decision))")
    }
}
#endif
