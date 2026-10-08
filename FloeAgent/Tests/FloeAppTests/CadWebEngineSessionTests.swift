// FloeAppTests — real WKWebView → cad-host → Worker → wasm smoke test.
//
// Covers the native bridge contract end to end: open, inspect (JSON string, not
// "[object Object]"), query, edit with a JSON-string request, undo, save bytes
// and the DXF projection. These paths cannot be proven by builder or tool
// tests alone.

#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
@testable import FloeApp
import FloeCore
import FloeTools
import FloeWorkspace
import FloeWorkbench

@Suite("CAD WKWebView worker bridge", .serialized)
@MainActor
struct CadWebEngineSessionTests {
    private func sampleDXF() throws -> Data {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        return data
    }

    private func object(_ json: String) throws -> [String: Any] {
        guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw FloeError.storageCorrupted("expected a JSON object from the CAD bridge")
        }
        return parsed
    }

    private func entityCount(_ session: CadWebEngineSession) async throws -> Int {
        let info = try object(try await session.inspect(offset: 0, limit: 1))
        return info["entityCount"] as? Int ?? -1
    }

    @Test func fullWorkerBridgeRoundTrip() async throws {
        let sample = try sampleDXF()
        let session = CadWebEngineSession()
        try await session.start()
        do {
            // open
            let opened = try object(try await session.open(bytes: sample, format: "dxf"))
            let base = opened["entityCount"] as? Int ?? 0
            #expect(base > 0, "sample drawing must parse with entities")
            #expect((opened["unit"] as? String)?.isEmpty == false)

            // inspect must be a JSON string, never "[object Object]".
            let inspected = try await session.inspect(offset: 0, limit: 5)
            #expect(inspected.hasPrefix("{"))
            #expect(inspected.contains("entityCount"))

            // query (JSON string passthrough must not be double-encoded)
            let layers = try await session.query(#"{"operation":"layers"}"#)
            #expect(layers.contains("layers"))

            // edit with a JSON-string request: the worker must hand the engine
            // a command object, not a JSON string literal.
            let edit = try object(try await session.edit(
                #"{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}"#))
            let created = edit["created"] as? [String] ?? []
            #expect(created.count == 1, "addLine must report one created handle")
            #expect(try await entityCount(session) == base + 1)

            // undo restores the pre-edit revision.
            try await session.undo()
            #expect(try await entityCount(session) == base)

            // save returns verified DXF bytes for this format.
            let saved = try await session.save()
            #expect(!saved.isEmpty)
            let savedHead = String(decoding: saved.prefix(256), as: UTF8.self)
            #expect(savedHead.contains("SECTION") || savedHead.hasPrefix("  0"))

            // DXF projection is a distinct worker operation (regression).
            let dxf = try await session.displayDXF()
            let dxfText = String(decoding: dxf, as: UTF8.self)
            #expect(dxfText.contains("SECTION"))
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    @Test func queryRejectsDoubleEncodedRequest() async throws {
        let session = CadWebEngineSession()
        try await session.start()
        _ = try await session.open(bytes: try sampleDXF(), format: "dxf")
        await #expect(throws: (any Error).self) {
            _ = try await session.query("\"{\\\"operation\\\":\\\"layers\\\"}\"")
        }
        await session.shutdown()
    }
}
/// Real transaction serialization: two distinct grants at the same revision
/// must not both edit, and the same request id in flight must replay rather
/// than double-apply. These exercise the actual CadDocumentCenter gate against
/// the real engine + file CAS, not a string helper.
@Suite("CAD document transaction serialization", .serialized)
@MainActor
struct CadDocumentCenterConcurrencyTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let sample = try? Data(contentsOf: bundleRoot.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        try sample.write(to: root.appendingPathComponent("plan.dxf"))
        return root
    }

    private func access(_ root: URL) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                          ownerKind: "workspace", ownerID: nil)
    }

    private let addLineOperations =
        #"[{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}]"#

    @Test func distinctGrantsAtSameRevisionOnlyOneEdits() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant1 = await center.issueUserGrant(for: proposal)
        let grant2 = await center.issueUserGrant(for: proposal)
        #expect(grant1 != grant2)

        let successes = await withTaskGroup(of: Bool.self) { group in
            for (grant, request) in [(grant1, "req-a"), (grant2, "req-b")] {
                group.addTask {
                    do {
                        _ = try await center.apply(proposal: proposal, grantID: grant,
                                                   requestID: request, access: access)
                        return true
                    } catch { return false }
                }
            }
            var total = 0
            for await value in group where value { total += 1 }
            return total
        }
        #expect(successes == 1, "exactly one of two same-revision grants may edit")
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision > snapshot.revision)
        #expect(after.sha256 != snapshot.sha256)
    }

    @Test func sameRequestInFlightReplaysInsteadOfDoubleApplying() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let receipts = await withTaskGroup(of: CadDocumentReceipt?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await center.apply(proposal: proposal, grantID: grant,
                                            requestID: "same-request", access: access)
                }
            }
            var values: [CadDocumentReceipt] = []
            for await receipt in group { if let receipt { values.append(receipt) } }
            return values
        }
        #expect(receipts.count == 2, "both callers receive a result")
        #expect(receipts.filter { $0.replay }.count == 1, "the second call must be a replay")
        #expect(Set(receipts.map(\.revision)).count == 1)
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision == snapshot.revision + 1, "the document advanced exactly once")
    }

    /// The central live-draft guard: a dirty on-screen viewer blocks BOTH the
    /// confirmed UI apply and the tool save/apply path; the file is untouched
    /// and the draft stays in the viewer. A clean viewer no longer blocks, and
    /// the committed receipt is journaled for decision recovery.
    @Test func liveDirtyDraftBlocksApplyAndSave() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let documentURL = root.appendingPathComponent("plan.dxf")
        let before = try Data(contentsOf: documentURL)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let package = try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: before)
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        // A live dirty draft blocks the confirmed apply...
        session.coordinator?.dirty = true
        await #expect(throws: (any Error).self) {
            _ = try await center.apply(proposal: proposal, grantID: grant,
                                       requestID: "blocked-apply", access: access)
        }
        // ...and the tool save path, with the file byte-identical.
        await #expect(throws: (any Error).self) {
            _ = try await center.save(documentID: "plan.dxf", expectedSHA256: snapshot.sha256,
                                      requestID: "blocked-save", access: access)
        }
        #expect(FloeDigest.sha256Hex(try Data(contentsOf: documentURL)) == snapshot.sha256)

        // The same confirmed grant applies once the viewer is clean, and the
        // receipt is durably journaled for the decision outbox.
        session.coordinator?.dirty = false
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "applied", access: access)
        #expect(receipt.sha256 != snapshot.sha256)
        let journaled = await center.committedReceipt(proposalID: proposal.id, access: access)
        #expect(journaled?.sha256 == receipt.sha256)
        #expect(journaled?.revision == receipt.revision)
    }

    /// A manual edit landing during the engine transaction (simulated by the
    /// test seam right before the final commit boundary) aborts the commit,
    /// rolls the engine draft back, preserves the file and the user's draft,
    /// and restores viewer interaction. The proposal can then be retried.
    @Test func concurrentLiveEditAbortsCommitAndPreservesDraft() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let documentURL = root.appendingPathComponent("plan.dxf")
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let package = try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: try Data(contentsOf: documentURL))
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        // The user edits while the transaction is between edit and commit.
        await center.setTestHook({ await MainActor.run { [weak session] in
            session?.coordinator?.dirty = true
        } })
        await #expect(throws: (any Error).self) {
            _ = try await center.apply(proposal: proposal, grantID: grant,
                                       requestID: "interleaved", access: access)
        }
        await center.setTestHook(nil)
        // File untouched, interaction restored, and the engine draft rolled
        // back: the document still has its original entity count.
        #expect(FloeDigest.sha256Hex(try Data(contentsOf: documentURL)) == snapshot.sha256)
        #expect(session.web?.isUserInteractionEnabled == true)
        let afterRollback = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(afterRollback.revision == snapshot.revision)
        #expect(afterRollback.sha256 == snapshot.sha256)

        // Save/discard the manual edit, then the same proposal applies.
        session.coordinator?.dirty = false
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "retried", access: access)
        #expect(receipt.sha256 != snapshot.sha256)
    }

    /// The lease itself: dirty drafts refuse a lease, validation catches an
    /// edit that arrived after the lease, and ending the lease restores
    /// interaction.
    @Test func liveDraftLeaseSuspendsInteractionAndDetectsEdits() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try EngineeringPreviewPackage.single(
            name: "plan.dxf", bytes: try Data(contentsOf: root.appendingPathComponent("plan.dxf")))
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        let lease = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        #expect(session.web?.isUserInteractionEnabled == false)
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .clean)

        // An edit arriving after the lease invalidates it.
        session.coordinator?.dirty = true
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .dirty)
        CadLiveDraftRegistry.shared.endLease(lease)
        #expect(session.web?.isUserInteractionEnabled == true)

        // A dirty viewer cannot take a new lease at all.
        #expect(throws: (any Error).self) {
            _ = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        }
        session.coordinator?.dirty = false
    }

    /// The document-level lease survives a viewer replacement: a session that
    /// registers while a transaction is running starts suspended, and its dirty
    /// draft still aborts the commit instead of escaping through the old
    /// session reference.
    @Test func documentLeaseSuspendsReplacementViewer() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent("plan.dxf"))
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        let first = EngineeringWebSession()
        _ = first.attach(package: try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: bytes),
                         error: Box<String?>(nil).binding, onReview: nil,
                         onSave: { _, _ in "sha" }, onDirty: nil, dark: false, locale: "en")
        CadLiveDraftRegistry.shared.register(key: key, session: first)
        defer { first.tearDown() }

        let lease = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        #expect(first.web?.isUserInteractionEnabled == false)

        // The viewer is replaced mid-transaction.
        CadLiveDraftRegistry.shared.unregister(key: key, session: first)
        let replacement = EngineeringWebSession()
        _ = replacement.attach(package: try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: bytes),
                               error: Box<String?>(nil).binding, onReview: nil,
                               onSave: { _, _ in "sha" }, onDirty: nil, dark: false, locale: "en")
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: replacement)
            replacement.tearDown()
        }
        CadLiveDraftRegistry.shared.register(key: key, session: replacement)
        #expect(replacement.web?.isUserInteractionEnabled == false,
                "a replacement viewer must start suspended while the lease runs")

        // Its dirty draft is detected, not bypassed by the stale reference.
        replacement.coordinator?.dirty = true
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .dirty)

        CadLiveDraftRegistry.shared.endLease(lease)
        #expect(replacement.web?.isUserInteractionEnabled == true)
    }

    /// A failed durable journal write never mutates the in-memory map.
    @Test func journalWriteFailureKeepsInMemoryStateUnchanged() async throws {
        let proposalID = UUID()
        let pending = CadDocumentReceipt(documentID: "plan.dxf", revision: 1,
                                         sha256: String(repeating: "a", count: 64),
                                         created: [], saved: false)
        let journal = CadAppliedReceiptJournal.shared
        journal.setTestWriteFailure(true)
        #expect(throws: (any Error).self) {
            try journal.prepare(proposalID: proposalID, expectedSHA256: pending.sha256,
                                pendingReceipt: pending)
        }
        #expect(journal.entry(proposalID: proposalID) == nil,
                "a failed write must not leave a phantom prepared entry")
        journal.setTestWriteFailure(false)
        try journal.prepare(proposalID: proposalID, expectedSHA256: pending.sha256,
                            pendingReceipt: pending)
        #expect(journal.entry(proposalID: proposalID)?.expectedSHA256 == pending.sha256)
    }

    /// Write-ahead recovery: an apply whose completion write was lost is
    /// reconstructed ONLY when the file currently has the prepared expected
    /// SHA; a different revision yields no applied receipt.
    @Test func preparedWriteAheadRecordReconcilesOnlyOnExactBytes() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)
        let intent = try DrawingAssistantDecisionStore.shared.record(
            conversationID: UUID(), proposalID: proposal.id, decision: "applied",
            revision: nil, sha256: nil, phase: .intent)
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "commit", access: access)

        // Simulate the crash window: the prepared record exists, the completion
        // write never reached disk. A fresh center has no in-memory outcome and
        // must reconcile against the committed file SHA.
        let pending = CadDocumentReceipt(documentID: receipt.documentID,
                                         revision: receipt.revision,
                                         sha256: receipt.sha256, created: receipt.created,
                                         saved: false, note: "prepared write-ahead record")
        try CadAppliedReceiptJournal.shared.prepare(proposalID: proposal.id,
                                                    expectedSHA256: receipt.sha256,
                                                    pendingReceipt: pending)
        let restarted = CadDocumentCenter()
        guard let recovered = await restarted.committedReceipt(proposalID: proposal.id, access: access) else {
            Issue.record("the prepared record must reconcile against the committed bytes")
            return
        }
        #expect(recovered.saved == true)
        #expect(recovered.sha256 == receipt.sha256)
        #expect(recovered.revision == receipt.revision)
        let upgraded = try DrawingAssistantDecisionStore.shared.recoverCommit(
            id: intent.id, receiptRevision: recovered.revision, sha256: recovered.sha256)
        #expect(upgraded?.phase == .committed)

        // A prepared expected SHA that does not match the file is NOT applied.
        let bogus = CadDocumentReceipt(documentID: receipt.documentID, revision: receipt.revision + 5,
                                       sha256: String(repeating: "0", count: 64), created: [],
                                       saved: false, note: "prepared write-ahead record")
        try CadAppliedReceiptJournal.shared.prepare(proposalID: proposal.id,
                                                    expectedSHA256: bogus.sha256,
                                                    pendingReceipt: bogus)
        let stillRestarted = CadDocumentCenter()
        let unmatched = await stillRestarted.committedReceipt(proposalID: proposal.id, access: access)
        #expect(unmatched == nil, "a non-matching prepared SHA must never yield an applied receipt")
    }

    /// Earlier persisted decision lines have no `phase`; they are committed
    /// records, never silently dropped or misread as intents.
    @Test func legacyDecisionLineDecodesAsCommitted() throws {
        let data = Data(#"{"id":"x","conversationID":"00000000-0000-0000-0000-000000000001","proposalID":"00000000-0000-0000-0000-000000000002","decision":"applied","revision":3,"sha256":"ab","recordedAt":0,"delivered":false}"#.utf8)
        let decision = try JSONDecoder().decode(DrawingAssistantDecisionStore.Decision.self, from: data)
        #expect(decision.phase == .committed)
        #expect(decision.revision == 3)
    }
}

/// UI-to-runtime binding contract for the Canvas Drawing Assistant staged
/// document: the review sheet and the tool context resolve the SAME
/// CadDocumentAccess; proposals prepared through the tool path are
/// discoverable only by the bound sheet access, never by unrelated chats;
/// and a staged context authorizes exactly the staged path — quoting any
/// other path in the prompt grants nothing.
@Suite("Canvas drawing assistant staged binding", .serialized)
@MainActor
struct CanvasDrawingAssistantBindingTests {
    private let addLineOperations =
        #"[{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}]"#

    private func stagedWorkspace() throws -> (root: URL, stagedPath: String, canvasID: UUID) {
        let canvasID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("CanvasDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let sample = try? Data(contentsOf: bundleRoot.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        // Deterministic staged layout like the canvas registry:
        // <canvas>/<node>/name.dxf.
        let stagedPath = "\(canvasID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/plan.dxf"
        let destination = root.appendingPathComponent(stagedPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try sample.write(to: destination)
        return (root, stagedPath, canvasID)
    }

    /// The review sheet builds exactly this access from the capture
    /// (`documentAccess` in EngineeringReviewSheet); the tool builds it from
    /// the seeded ToolContext. They must be identical for proposals to match.
    private func sheetAccess(root: URL, canvasID: UUID) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                          ownerKind: "canvas", ownerID: canvasID)
    }

    private func toolContext(root: URL, stagedPath: String, canvasID: UUID) -> ToolContext {
        ToolContext(
            runID: UUID(),
            canvasStagedDocument: CanvasStagedDocumentAccess(
                canvasID: canvasID, draftRootPath: root.path,
                stagedRelativePath: stagedPath),
            cancellation: CancellationToken())
    }

    @Test("tool context and review sheet derive the identical staged access")
    func toolAndSheetAccessIdentical() throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = toolContext(root: root, stagedPath: stagedPath, canvasID: canvasID)
        #expect(CadDocumentTool.access(for: context) == sheetAccess(root: root, canvasID: canvasID))
        // A run WITHOUT the staged seed keeps the ordinary derivation and
        // can never alias the canvas identity.
        let ordinary = CadDocumentTool.access(for: ToolContext(
            runID: UUID(), workspaceRootURL: root,
            cancellation: CancellationToken(),
            conversationID: UUID()))
        #expect(ordinary.ownerKind == "chat")
        #expect(ordinary != sheetAccess(root: root, canvasID: canvasID))
    }

    @Test("a staged context authorizes exactly the staged path and nothing else")
    func stagedPathRestriction() throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = toolContext(root: root, stagedPath: stagedPath, canvasID: canvasID)
        try CadDocumentTool.authorizeDocumentPath(stagedPath, context: context)
        #expect(throws: FloeError.self) {
            try CadDocumentTool.authorizeDocumentPath("other.dxf", context: context)
        }
        // No staged seed: no restriction (ordinary workspace rules apply),
        // and a nil path (capabilities-only upstream) is never an escape.
        let ordinary = ToolContext(runID: UUID(), cancellation: CancellationToken())
        try CadDocumentTool.authorizeDocumentPath("anything.dxf", context: ordinary)
        try CadDocumentTool.authorizeDocumentPath(nil, context: ordinary)
    }

    @Test("runtime proposals are discoverable by the bound sheet access only")
    func proposalBindingContract() async throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let center = CadDocumentCenter()
        let access = sheetAccess(root: root, canvasID: canvasID)

        // Runtime path: snapshot + propose through the tool-derived access.
        let toolAccess = CadDocumentTool.access(for: toolContext(
            root: root, stagedPath: stagedPath, canvasID: canvasID))
        let snapshot = try await center.snapshot(documentID: stagedPath, access: toolAccess)
        let proposal = try await center.prepareProposal(
            documentID: stagedPath, snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: toolAccess)
        try await center.storeProposal(proposal)

        // The SAME sheet access discovers the pending proposal...
        let sheetVisible = try await center.pendingProposals(documentID: stagedPath, access: access)
        #expect(sheetVisible.map(\.id) == [proposal.id])
        // ...including when derived from the tool context again.
        let viaTool = try await center.pendingProposals(documentID: stagedPath, access: toolAccess)
        #expect(viaTool.map(\.id) == [proposal.id])

        // Unrelated chats with the same root or another canvas see nothing
        // and cannot load the proposal.
        let strangers: [CadDocumentAccess] = [
            CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                              ownerKind: "chat", ownerID: UUID()),
            CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                              ownerKind: "canvas", ownerID: UUID()),
        ]
        for stranger in strangers {
            let visible = try await center.pendingProposals(documentID: stagedPath, access: stranger)
            #expect(visible.isEmpty)
            // Foreign access gets the same denial as an unknown proposal:
            // ids are not enumerable across owners.
            let loaded = try await center.loadProposal(id: proposal.id, access: stranger)
            #expect(loaded == nil)
        }
    }
}

/// Fail-closed authoritative reachability for creative-asset prune
/// protection: a corrupt/unreadable/newer-schema canvas project makes the
/// scan return `.unknown` (retain), never `.notReachable`, and a pending
/// reconciliation op retains the asset while bookkeeping is mid-flight.
@Suite("Canvas reachability fails closed", .serialized)
@MainActor
struct CanvasReachabilityFailClosedTests {
    private var canvasesDirectory: URL {
        get throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("Canvases", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    private func plantCanvasProjectFile(
        named fileID: UUID,
        project: CanvasProject
    ) throws -> URL {
        let url = try canvasesDirectory.appendingPathComponent("\(fileID.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder).write(
            to: url, options: .atomic)
        return url
    }

    @Test("a corrupt canvas project makes reachability unknown, never notReachable")
    func corruptProjectFailsClosed() throws {
        let directory = try canvasesDirectory
        let corruptID = UUID()
        let corruptURL = directory.appendingPathComponent("\(corruptID.uuidString).json")
        try Data("{ not a canvas project".utf8).write(to: corruptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        // Even an asset no project references is retained: the scan cannot
        // prove unreferencedness past a corrupt file.
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .unknown)
    }

    @Test("a valid project referencing an asset reports reachable; unrelated assets are notReachable")
    func validProjectReachability() throws {
        let canvasID = UUID()
        let assetID = UUID()
        let node = CanvasNode(
            id: UUID(), kind: .image, text: "img",
            position: .init(x: 0, y: 0), size: .init(width: 10, height: 10),
            asset: CanvasAssetReference(
                id: assetID, contentHash: String(repeating: "a", count: 64),
                localRelativePath: "Materials/a.png", mimeType: "image/png",
                byteCount: 10))
        let document = CanvasDocument(name: "D", nodes: [node])
        let project = CanvasProject(
            id: canvasID, name: "C", documents: [document],
            selectedDocumentID: document.id)
        let url = try plantCanvasProjectFile(named: canvasID, project: project)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WorkspaceCanvasRegistry.reachability(of: assetID) == .reachable)
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .notReachable)
    }

    @Test("a pending reconciliation op retains the asset while bookkeeping is mid-flight")
    func pendingOpRetains() throws {
        let assetID = UUID()
        let journal = try canvasesDirectory
            .appendingPathComponent("asset-reconciliation-\(UUID().uuidString).json")
        let record = CanvasAssetReconciliation.Record(ops: [
            .init(id: "op-1", assetID: assetID, delta: 1)
        ])
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        defer { try? FileManager.default.removeItem(at: journal) }
        #expect(WorkspaceCanvasRegistry.reachability(of: assetID) == .reachable)
    }
}

/// Mutable box so tests can share a Binding target without inout captures.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
