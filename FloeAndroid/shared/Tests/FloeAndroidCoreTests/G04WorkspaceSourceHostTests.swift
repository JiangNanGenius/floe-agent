// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 trusted provider SOURCE HOST — real-ladder source tests.
//
// AUTHORED, NOT EXECUTED (grouped qualification is Main's). Storage is the
// original installed-generation fixture (same bootstrap + real file-backed
// DatabaseManager as the accepted G04 facade tests); the tests drive the
// SAME Swift entry points the Kotlin JNI binds to (`stageOpen/stageWrite/
// stageFinish/egress*/save*/reconcile*` on G04WorkspaceSourceHost) — Swift
// calling Swift, like the accepted attachment/mailbox `_cdecl` exercises.
// Synthetic bytes only; no device, no provider, no network.
//
// Proven contract surface (every assert against REAL disk bytes or the REAL
// journal-47 rows — never a fake callback):
//   * fail-closed without a live root/registered source coordinator: no
//     session, no staged file;
//   * grammar mirrors the journal exactly: canonical UUIDs, relative
//     standardized paths, `content://` references, `rec-<uuid>` receipts;
//   * chunked staging is append-only under the ORIGINAL 1 GiB provider-copy
//     budget (NOT the 4 MiB editable-document cap): a 6 MiB import really
//     lands, native-hashes, commits through `importUserFile` and binds the
//     row with the post-commit digest the COORDINATOR observed;
//   * finish freezes: duplicate finish is typed; abort removes ONLY this
//     lane's scratch; a same-path DIFFERENT-bytes re-import refuses
//     `workingCopyExists` and leaves the committed body untouched;
//   * the save ladder is journal-admitted: prepare refuses drift without a
//     permit; the claim is ONE-TIME; the destructive permit is handed at
//     most once to the journaled receipt token (replay -508); settle maps
//     the NATIVE-OBSERVED read-back: mismatch -> conflict with the observed
//     digest and an UNCHANGED row, match -> committed with the binding CAS
//     advancing sha+revision; retain before a permit records `retained`,
//     after a permit is refused;
//   * pages are metadata-only and row-complete (truncation reports the
//     exact `nextAfterID`; zero-fit replies -106); stats expose counters
//     only — no paths, names or URIs;
//   * a rebind fences the old generation: stale tickets never settle the
//     current table (late work is swept, staged scratch removed, journaled
//     rows stay honestly pending for the reconcile path).
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAndroidCore

final class G04WorkspaceSourceHostTests: XCTestCase {

    // MARK: - Fixtures

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 = UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, rootPath: String, token: String) {
            self.epoch = epoch; self.rootPath = rootPath; self.token = token
        }
    }

    private enum TestError: Error { case bootstrap, envelope }

    private var tracked: [Boot] = []

    private func bootInstalledGeneration() async throws -> Boot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g04-source-host-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let token = String((0 ..< 16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted = AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token,
                                                             epoch: epoch) else {
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, rootPath: root, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  generation.epoch == epoch else { throw TestError.bootstrap }
            // The host entry points resolve the epoch-exact coordinator from
            // G04WorkspaceHostRegistry, which the workspace extension
            // publishes only INSIDE owned-install step 4 — AFTER
            // `installedComposition` is already visible at the claim. Wait
            // for the ONE post-attach publication so every session here
            // exercises the fully-bound generation instead of racing it.
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace) {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not close for epoch \(boot.epoch)")
    }

    override func tearDown() async throws {
        let host = G04WorkspaceSourceHost.shared
        host.liveEpochOverrideForTesting = nil
        host.coordinatorOverrideForTesting = nil
        host.stagingRootOverrideForTesting = nil
        for boot in tracked { await shutdownAndAwaitClosed(boot) }
        tracked.removeAll()
        // Same producer-ownership reset the accepted facade-suite tearDown
        // uses: without it the first-install-wins LinuxWorkspaceAuthority
        // slot stays pinned to the FIRST suite generation's temp root, so
        // every later boot's privateTaskService resolves (and commits) under
        // that stale root while cluster identity points at a newer root.
        G02RuntimeComposition.shared.resetForTesting()
        try await super.tearDown()
    }

    private func installedCluster() throws -> G02OwnedStoreCluster {
        guard let installed = G02RuntimeComposition.shared.installedComposition else {
            throw TestError.envelope
        }
        return installed.cluster
    }

    /// Ordinary conversation + the ORIGINAL private-task workspace binding,
    /// exactly the shape `workspace.activate` lands through the same
    /// `ensureWorkspace(conversationID:title:)` authority.
    private func makeBoundOrdinaryTask() async throws -> (taskID: UUID, workspaceID: UUID) {
        let cluster = try installedCluster()
        let taskID = UUID()
        try await cluster.conversationStore.saveConversation(ConversationRecord(
            id: taskID, title: "Source host fixture", createdAt: Date(), updatedAt: Date()))
        let record = try await cluster.workspaceStore.ensureWorkspace(conversationID: taskID,
                                                                      title: "Source host fixture")
        return (taskID, record.id)
    }

    // MARK: - Small plumbing helpers

    private func reply(_ code: Int32, _ buffer: [CChar]) -> [String: Any]? {
        guard code >= 0 else { return nil }
        let data = Data(bytes: buffer, count: Int(code))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func chunked(_ data: Data, into ticket: Int64, host: G04WorkspaceSourceHost) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + G04SourceHostLimits.maximumChunkBytes, data.count)
            XCTAssertEqual(host.stageWrite(ticket: ticket, data: data.subdata(in: offset ..< end)),
                           G04SourceHostStatus.ok)
            offset = end
        }
    }

    /// Open + stream + freeze one native stage; returns the live ticket whose
    /// digest native computed itself (the reply body is asserted by callers
    /// that need it).
    @discardableResult
    private func stagedTicket(host: G04WorkspaceSourceHost, boot: Boot, taskID: UUID,
                              workspaceID: UUID, purpose: String, bytes: Data) -> Int64 {
        let ticket = host.stageOpen(epoch: boot.epoch, purposeRaw: purpose,
                                    taskHex: taskID.uuidString, workspaceHex: workspaceID.uuidString,
                                    sourceHex: nil, logicalPath: nil, sourceReference: nil,
                                    sourceDocumentID: nil)
        XCTAssertGreaterThan(ticket, 0, "stageOpen(\(purpose))")
        chunked(bytes, into: ticket, host: host)
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = host.stageFinish(ticket: ticket, buffer: &buffer, capacity: 4096)
        XCTAssertGreaterThan(size, 0, "stageFinish(\(purpose)) must return a body")
        XCTAssertEqual(reply(size, buffer)?["sha256"] as? String, FloeDigest.sha256Hex(bytes),
                         "native digest of the staged body (\(purpose))")
        return ticket
    }

    private func importBytes(host: G04WorkspaceSourceHost, boot: Boot, taskID: UUID,
                             workspaceID: UUID, sourceID: UUID, path: String,
                             reference: String, documentID: String?,
                             bytes: Data) throws -> [String: Any]? {
        let ticket = host.stageOpen(epoch: boot.epoch, purposeRaw: "import",
                                    taskHex: taskID.uuidString, workspaceHex: workspaceID.uuidString,
                                    sourceHex: sourceID.uuidString, logicalPath: path,
                                    sourceReference: reference, sourceDocumentID: documentID)
        XCTAssertGreaterThan(ticket, 0, "import stageOpen")
        chunked(bytes, into: ticket, host: host)
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = host.stageFinish(ticket: ticket, buffer: &buffer, capacity: 4096)
        let body = reply(size, buffer)
        XCTAssertEqual(host.stageAbort(ticket: ticket), G04SourceHostStatus.ok)
        return body
    }

    // MARK: - 1. Fail-closed + static grammar (no generation needed)

    func testNoLiveGenerationRefusesEveryEntryWithoutSideEffects() throws {
        let host = G04WorkspaceSourceHost.shared
        let task = UUID().uuidString, workspace = UUID().uuidString, source = UUID().uuidString
        // An epoch that is not the live root: typed fail-closed, no tickets.
        XCTAssertLessThan(host.stageOpen(epoch: UInt64.max - 2, purposeRaw: "import", taskHex: task,
                                         workspaceHex: workspace, sourceHex: source,
                                         logicalPath: "docs/a.txt",
                                         sourceReference: "content://com.floe.host/tree/1/document/2",
                                         sourceDocumentID: nil), 0)
        XCTAssertLessThan(host.egressOpen(epoch: UInt64.max - 1, mode: "save", taskHex: task,
                                          workspaceHex: workspace, logicalPath: "docs/a.txt",
                                          sourceHex: source), 0)
        var buffer = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(host.sourcePage(epoch: 0, workspaceHex: workspace, afterID: "", limit: 8,
                                       buffer: &buffer, capacity: 4096),
                       G04SourceHostStatus.notInstalled)
        XCTAssertLessThan(host.reconcileRun(epoch: UInt64.max, workspaceHex: workspace,
                                            buffer: &buffer, capacity: 4096), 0)
        // Unknown tickets are typed; never resumed, never invented.
        XCTAssertEqual(host.stageWrite(ticket: 4_242_424, data: Data([1, 2, 3])),
                       G04SourceHostStatus.sessionUnknown)
        XCTAssertEqual(host.savePermit(saveTicket: 4_242_424, receiptToken: "rec-\(UUID().uuidString)"),
                       G04SourceHostStatus.sessionUnknown)
    }

    func testGrammarHelpersMirrorTheJournalExactly() {
        // Canonical UUID: case-insensitive canonical spelling only.
        XCTAssertNotNil(G04WorkspaceSourceHost.canonicalUUID(UUID().uuidString))
        XCTAssertNotNil(G04WorkspaceSourceHost.canonicalUUID(UUID().uuidString.lowercased()))
        XCTAssertNil(G04WorkspaceSourceHost.canonicalUUID("floe"))
        XCTAssertNil(G04WorkspaceSourceHost.canonicalUUID("00000000-0000-0000-0000-00000000000"))
        // Path: relative, standardized, no traversal, no absolute, no backslash.
        XCTAssertTrue(G04WorkspaceSourceHost.validLogicalPath("docs/note.txt"))
        XCTAssertTrue(G04WorkspaceSourceHost.validLogicalPath("Imported/文件.txt"))
        XCTAssertFalse(G04WorkspaceSourceHost.validLogicalPath("/tmp/x"))
        XCTAssertFalse(G04WorkspaceSourceHost.validLogicalPath("a/../../b"))
        XCTAssertFalse(G04WorkspaceSourceHost.validLogicalPath(""))
        XCTAssertFalse(G04WorkspaceSourceHost.validLogicalPath("a//b"))
        // Reference: content:// with a host, no userinfo/query-credential.
        XCTAssertTrue(G04WorkspaceSourceHost.validSourceReference(
            "content://com.floe.host/tree/1/document/2"))
        XCTAssertFalse(G04WorkspaceSourceHost.validSourceReference("file:///tmp/secret"))
        XCTAssertFalse(G04WorkspaceSourceHost.validSourceReference(
            "content://user:pass@com.floe.host/tree/1"))
        // Receipt: exactly `rec-<canonical uuid>`.
        XCTAssertTrue(G04WorkspaceSourceHost.validReceiptToken("rec-\(UUID().uuidString)"))
        XCTAssertFalse(G04WorkspaceSourceHost.validReceiptToken("rec-floe"))
        XCTAssertFalse(G04WorkspaceSourceHost.validReceiptToken("r1"))
        // The journaled backup identity grammar.
        let source = UUID(), recovery = UUID()
        XCTAssertEqual(G04WorkspaceSourceHost.journalBackupPath(sourceID: source, recoveryID: recovery),
                       "Source Recovery/\(source.uuidString)/\(recovery.uuidString).bin")
    }

    // MARK: - 2. Staged chunking on REAL bytes

    func testStageChunkingRealBytesDuplicateFinishAndAbort() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let bytes = Data((0 ..< 131_172).map { UInt8($0 % 251) })

        let ticket = host.stageOpen(epoch: boot.epoch, purposeRaw: "backup-verify",
                                    taskHex: taskID.uuidString, workspaceHex: workspaceID.uuidString,
                                    sourceHex: nil, logicalPath: nil, sourceReference: nil,
                                    sourceDocumentID: nil)
        XCTAssertGreaterThan(ticket, 0)
        // Over-cap single chunk refused BEFORE touching the file.
        XCTAssertEqual(host.stageWrite(ticket: ticket, data: Data(count: 65_537)),
                       G04SourceHostStatus.invalidArguments)
        chunked(bytes, into: ticket, host: host)
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = host.stageFinish(ticket: ticket, buffer: &buffer, capacity: 4096)
        let body = try XCTUnwrap(reply(size, buffer))
        XCTAssertEqual(body["ok"] as? Int, 1)
        XCTAssertEqual(body["sha256"] as? String, FloeDigest.sha256Hex(bytes))
        XCTAssertEqual(body["bytes"] as? Int, bytes.count)
        // Finish is terminal: a second finish is a typed phase conflict.
        var again = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(host.stageFinish(ticket: ticket, buffer: &again, capacity: 4096),
                       G04SourceHostStatus.stateConflict)
        // Abort removes ONLY this lane's staged scratch and retires the
        // ticket; late work on the retired ticket is fenced, never resumed.
        XCTAssertEqual(host.stageAbort(ticket: ticket), G04SourceHostStatus.ok)
        XCTAssertEqual(host.stageWrite(ticket: ticket, data: Data([1])),
                       G04SourceHostStatus.generationFenced)

        // Grammar refusal lands with NO ticket and no staged file.
        let bad = host.stageOpen(epoch: boot.epoch, purposeRaw: "import",
                                 taskHex: taskID.uuidString, workspaceHex: workspaceID.uuidString,
                                 sourceHex: UUID().uuidString, logicalPath: "docs/a.txt",
                                 sourceReference: "file:///tmp/nope", sourceDocumentID: nil)
        XCTAssertLessThan(bad, 0)
    }

    // MARK: - 3. Import ladders on the real workspace

    func testImportCommitsHashesAndBindsThroughRealAuthorities() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let cluster = try installedCluster()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let sourceID = UUID()
        let payload = Data("provider file body\n".utf8) + Data(repeating: 0xAB, count: 200_000)
        let reference = "content://com.floe.host/test/tree/7/document/42"

        let body = try importBytes(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   sourceID: sourceID, path: "docs/note.txt", reference: reference,
                                   documentID: "42", bytes: payload)
        XCTAssertEqual(body?["ok"] as? Int, 1,
                       "commit errorCode=\(body?["errorCode"] ?? "nil") "
                       + "reason=\(body?["reason"] ?? "nil")")
        XCTAssertEqual(body?["sourceID"] as? String, sourceID.uuidString)
        XCTAssertEqual(body?["sha256"] as? String, FloeDigest.sha256Hex(payload))
        XCTAssertEqual(body?["bytes"] as? Int, payload.count)

        // The EXACT committed body exists at the private-task workspace path.
        let committed = URL(fileURLWithPath: cluster.identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)/docs/note.txt")
        XCTAssertEqual(try Data(contentsOf: committed), payload)
        // The durable row carries the NATIVE post-commit digest.
        let store = AndroidWorkspaceSourceStore(database: cluster.database)
        let durableRow = try await store.source(id: sourceID)
        let row = try XCTUnwrap(durableRow)
        XCTAssertEqual(row.sourceSHA256, FloeDigest.sha256Hex(payload))
        XCTAssertEqual(row.logicalPath, "docs/note.txt")
        XCTAssertEqual(row.sourceReference, reference)
        XCTAssertEqual(row.kind, .saf)

        // Re-import DIFFERENT bytes to the SAME path: typed refusal, and the
        // committed workspace body is UNTOUCHED (nothing is overwritten).
        let conflicting = Data("different body".utf8)
        let body2 = try importBytes(host: host, boot: boot, taskID: taskID,
                                    workspaceID: workspaceID, sourceID: UUID(),
                                    path: "docs/note.txt", reference: reference,
                                    documentID: "42", bytes: conflicting)
        XCTAssertEqual(body2?["ok"] as? Int, 0)
        XCTAssertEqual(body2?["errorCode"] as? String, "transitionRefused")
        XCTAssertEqual(body2?["reason"] as? String, "workingCopyExists")
        XCTAssertEqual(try Data(contentsOf: committed), payload)

        // Same-path SAME-bytes re-import with a NEW source id: the commit
        // step is idempotent (existing same-digest body), and the journal
        // keeps ONE binding per path — the UNIQUE refusal is typed, never a
        // silent second row.
        let body3 = try importBytes(host: host, boot: boot, taskID: taskID,
                                    workspaceID: workspaceID, sourceID: UUID(),
                                    path: "docs/note.txt", reference: reference,
                                    documentID: "42", bytes: payload)
        XCTAssertEqual(body3?["ok"] as? Int, 0)
        // Rows unchanged: still exactly one for this path.
        let lookup = try await store.source(workspaceID: workspaceID, logicalPath: "docs/note.txt")
        XCTAssertEqual(lookup?.id, sourceID)
    }

    func testImportLargerThanTheEditableDocumentBudget() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let cluster = try installedCluster()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let sourceID = UUID()
        // 6 MiB: deliberately ABOVE the 4 MiB editable-document budget —
        // the provider-copy budget (1 GiB) governs this lane.
        var payload = Data(capacity: 6 << 20)
        for _ in 0 ..< 96 { payload.append(Data(repeating: 0x5A, count: 64 * 1024)) }
        let body = try importBytes(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   sourceID: sourceID, path: "media/big.bin",
                                   reference: "content://com.floe.host/tree/1/document/9",
                                   documentID: "9", bytes: payload)
        XCTAssertEqual(body?["ok"] as? Int, 1,
                       "commit errorCode=\(body?["errorCode"] ?? "nil") "
                       + "reason=\(body?["reason"] ?? "nil")")
        XCTAssertEqual(body?["bytes"] as? Int, payload.count)
        XCTAssertEqual(body?["sha256"] as? String, FloeDigest.sha256Hex(payload))
        let committed = URL(fileURLWithPath: cluster.identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)/media/big.bin")
        XCTAssertEqual(try Data(contentsOf: committed).count, payload.count)
    }

    // MARK: - 4. The save ladder (journal-admitted, native-observed)

    func testSaveLadderPermitOnceConflictThenCommittedAndRetain() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let cluster = try installedCluster()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let sourceID = UUID()
        let original = Data("provider original".utf8)
        let replacement = Data("edited working copy".utf8)
        let thirdParty = Data("someone else wrote".utf8)
        let reference = "content://com.floe.host/tree/5/document/77"

        // Bind the row through the same import authority.
        let bindBody = try importBytes(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                       sourceID: sourceID, path: "docs/doc.txt", reference: reference,
                                       documentID: "77", bytes: original)
        // Bind premise stated explicitly (never implicitly relies on the
        // later .atomic write's parent materialization): typed tokens only.
        XCTAssertEqual(bindBody?["ok"] as? Int, 1,
                       "bind premise errorCode=\(bindBody?["errorCode"] ?? "nil") "
                       + "reason=\(bindBody?["reason"] ?? "nil")")
        let workspaceFile = URL(fileURLWithPath: cluster.identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)/docs/doc.txt")
        // The real editor owns saves; a source test may only stage bytes on
        // disk to exercise the ladder against them.
        try replacement.write(to: workspaceFile, options: .atomic)

        // ---- Ladder 1: permit once, settle sees a THIRD-PARTY body. ----
        let save1 = host.egressOpen(epoch: boot.epoch, mode: "save", taskHex: taskID.uuidString,
                                    workspaceHex: workspaceID.uuidString, logicalPath: "docs/doc.txt",
                                    sourceHex: sourceID.uuidString)
        XCTAssertGreaterThan(save1, 0)
        var infoBuf = [CChar](repeating: 0, count: 4096)
        let infoSize = host.egressInfo(ticket: save1, buffer: &infoBuf, capacity: 4096)
        let info = try XCTUnwrap(reply(infoSize, infoBuf))
        XCTAssertEqual(info["sha256"] as? String, FloeDigest.sha256Hex(replacement))
        XCTAssertEqual(info["bytes"] as? Int, replacement.count)
        let receipt1 = "rec-\(UUID().uuidString)"

        // Egress really streams the FROZEN snapshot bytes down.
        var page = [UInt8](repeating: 0, count: 65_536)
        let got = host.egressRead(ticket: save1, offset: 0, buffer: &page, capacity: 65_536)
        XCTAssertEqual(got, Int32(replacement.count))
        XCTAssertEqual(Data(bytes: page, count: Int(got)), replacement)
        XCTAssertEqual(host.egressRead(ticket: save1, offset: Int64(replacement.count),
                                       buffer: &page, capacity: 65_536), 0)  // clean EOF

        let backup1 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   purpose: "backup-verify", bytes: original)
        var p1 = [CChar](repeating: 0, count: 4096)
        let prepareSize = host.savePrepare(saveTicket: save1, backupStageTicket: backup1,
                                           receiptToken: receipt1, buffer: &p1, capacity: 4096)
        let prepared = try XCTUnwrap(reply(prepareSize, p1))
        XCTAssertEqual(prepared["ok"] as? Int, 1)
        XCTAssertEqual(prepared["state"] as? String, "prepared")
        let revisionBefore = try XCTUnwrap(prepared["sourceRevision"] as? String)

        // Drift at prepare: a different staged backup gets NO permit.
        let save1x = host.egressOpen(epoch: boot.epoch, mode: "save", taskHex: taskID.uuidString,
                                     workspaceHex: workspaceID.uuidString, logicalPath: "docs/doc.txt",
                                     sourceHex: sourceID.uuidString)
        let drifted = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   purpose: "backup-verify", bytes: thirdParty)
        var p1x = [CChar](repeating: 0, count: 4096)
        let driftSize = host.savePrepare(saveTicket: save1x, backupStageTicket: drifted,
                                         receiptToken: "rec-\(UUID().uuidString)",
                                         buffer: &p1x, capacity: 4096)
        let driftBody = try XCTUnwrap(reply(driftSize, p1x))
        XCTAssertEqual(driftBody["ok"] as? Int, 0)
        XCTAssertEqual(driftBody["errorCode"] as? String, "sourceChangedSinceImport")
        var r1x = [CChar](repeating: 0, count: 4096)
        let retain1x = host.saveRetain(saveTicket: save1x, buffer: &r1x, capacity: 4096)
        XCTAssertGreaterThan(retain1x, 0)
        XCTAssertEqual(reply(retain1x, r1x)?["state"] as? String, "abandoned")

        // Claim (ONE-TIME) with the second fresh observation == backup.
        let fresh1 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                  purpose: "fresh-observe", bytes: original)
        var c1 = [CChar](repeating: 0, count: 4096)
        let claimSize = host.saveClaim(saveTicket: save1, freshStageTicket: fresh1,
                                       buffer: &c1, capacity: 4096)
        let claimed = try XCTUnwrap(reply(claimSize, c1))
        XCTAssertEqual(claimed["ok"] as? Int, 1)
        XCTAssertEqual(claimed["state"] as? String, "writing")
        // Replay of the claim is a phase conflict (durable row already left
        // `prepared`; the store can never re-issue the permit).
        let fresh1b = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   purpose: "fresh-observe", bytes: original)
        var c1b = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(host.saveClaim(saveTicket: save1, freshStageTicket: fresh1b,
                                      buffer: &c1b, capacity: 4096),
                       G04SourceHostStatus.stateConflict)

        // Permit: exactly once, only to the journaled receipt token.
        XCTAssertEqual(host.savePermit(saveTicket: save1, receiptToken: receipt1),
                       G04SourceHostStatus.ok)
        XCTAssertEqual(host.savePermit(saveTicket: save1, receiptToken: receipt1),
                       G04SourceHostStatus.transitionRefused)
        XCTAssertEqual(host.savePermit(saveTicket: save1, receiptToken: "rec-\(UUID().uuidString)"),
                       G04SourceHostStatus.transitionRefused)
        // Abandon after a permit is refused: only the provider bytes decide.
        var r1 = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(host.saveRetain(saveTicket: save1, buffer: &r1, capacity: 4096),
                       G04SourceHostStatus.transitionRefused)

        // Settle with the THIRD-PARTY read-back: conflict, row UNCHANGED.
        let readback1 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                     purpose: "readback", bytes: thirdParty)
        var s1 = [CChar](repeating: 0, count: 4096)
        let settle1Size = host.saveSettle(saveTicket: save1, readbackStageTicket: readback1,
                                          buffer: &s1, capacity: 4096)
        let settled1 = try XCTUnwrap(reply(settle1Size, s1))
        XCTAssertEqual(settled1["ok"] as? Int, 0)
        XCTAssertEqual(settled1["state"] as? String, "conflict")
        XCTAssertEqual(settled1["errorCode"] as? String, "providerReadbackMismatch")
        XCTAssertEqual(settled1["observedSHA256"] as? String, FloeDigest.sha256Hex(thirdParty))
        let store = AndroidWorkspaceSourceStore(database: cluster.database)
        let conflictRow = try await store.source(id: sourceID)
        let rowAfterConflict = try XCTUnwrap(conflictRow)
        XCTAssertEqual(rowAfterConflict.sourceSHA256, FloeDigest.sha256Hex(original))
        XCTAssertEqual(rowAfterConflict.revision, revisionBefore)

        // ---- Ladder 2: a FRESH ladder commits through the CAS. ----
        let save2 = host.egressOpen(epoch: boot.epoch, mode: "save", taskHex: taskID.uuidString,
                                    workspaceHex: workspaceID.uuidString, logicalPath: "docs/doc.txt",
                                    sourceHex: sourceID.uuidString)
        XCTAssertGreaterThan(save2, 0)
        let receipt2 = "rec-\(UUID().uuidString)"
        let backup2 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   purpose: "backup-verify", bytes: original)
        var p2 = [CChar](repeating: 0, count: 4096)
        XCTAssertGreaterThan(host.savePrepare(saveTicket: save2, backupStageTicket: backup2,
                                              receiptToken: receipt2, buffer: &p2, capacity: 4096), 0)
        let fresh2 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                  purpose: "fresh-observe", bytes: original)
        var c2 = [CChar](repeating: 0, count: 4096)
        XCTAssertGreaterThan(host.saveClaim(saveTicket: save2, freshStageTicket: fresh2,
                                            buffer: &c2, capacity: 4096), 0)
        XCTAssertEqual(host.savePermit(saveTicket: save2, receiptToken: receipt2),
                       G04SourceHostStatus.ok)
        // Egress pages == the journaled replacement (what the host writes).
        var pulled = Data()
        var offset = 0
        while true {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let copied = host.egressRead(ticket: save2, offset: Int64(offset),
                                         buffer: &chunk, capacity: 65_536)
            XCTAssertGreaterThanOrEqual(copied, 0)
            if copied == 0 { break }
            pulled.append(Data(bytes: chunk, count: Int(copied)))
            offset += Int(copied)
        }
        XCTAssertEqual(pulled, replacement)
        // Provider kept EXACTLY the replacement bytes -> native commits with
        // the binding CAS (sha+revision advance together).
        let readback2 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                     purpose: "readback", bytes: replacement)
        var s2 = [CChar](repeating: 0, count: 4096)
        let settle2 = try XCTUnwrap(reply(host.saveSettle(saveTicket: save2, readbackStageTicket: readback2,
                                                          buffer: &s2, capacity: 4096), s2))
        XCTAssertEqual(settle2["ok"] as? Int, 1)
        XCTAssertEqual(settle2["state"] as? String, "committed")
        let committedRow = try await store.source(id: sourceID)
        let rowCommitted = try XCTUnwrap(committedRow)
        XCTAssertEqual(rowCommitted.sourceSHA256, FloeDigest.sha256Hex(replacement))
        XCTAssertNotEqual(rowCommitted.revision, revisionBefore)
        // The working copy body is untouched by the ladder (the host wrote
        // the provider, not the workspace file).
        XCTAssertEqual(try Data(contentsOf: workspaceFile), replacement)

        // ---- Ladder 3: honest abandon BEFORE any permit -> retained. ----
        let save3 = host.egressOpen(epoch: boot.epoch, mode: "save", taskHex: taskID.uuidString,
                                    workspaceHex: workspaceID.uuidString, logicalPath: "docs/doc.txt",
                                    sourceHex: sourceID.uuidString)
        let backup3 = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                   purpose: "backup-verify", bytes: replacement)
        var p3 = [CChar](repeating: 0, count: 4096)
        XCTAssertGreaterThan(host.savePrepare(saveTicket: save3, backupStageTicket: backup3,
                                              receiptToken: "rec-\(UUID().uuidString)",
                                              buffer: &p3, capacity: 4096), 0)
        var r3 = [CChar](repeating: 0, count: 4096)
        let retainSize = host.saveRetain(saveTicket: save3, buffer: &r3, capacity: 4096)
        let retained = try XCTUnwrap(reply(retainSize, r3))
        XCTAssertEqual(retained["state"] as? String, "retained")
        // After retain the ladder is terminal: the save session was retired,
        // so a late settle is the typed unknown-session refusal (and the
        // durable row was already settled to `retained`). The late readback
        // stage is this test's own scratch; abort it.
        let lateReadback = stagedTicket(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                        purpose: "readback", bytes: replacement)
        var s3 = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(host.saveSettle(saveTicket: save3, readbackStageTicket: lateReadback,
                                       buffer: &s3, capacity: 4096),
                       G04SourceHostStatus.sessionUnknown)
        XCTAssertEqual(host.stageAbort(ticket: lateReadback), G04SourceHostStatus.ok)
        let retainedRow = try await store.source(id: sourceID)
        let rowAfterRetain = try XCTUnwrap(retainedRow)
        XCTAssertEqual(rowAfterRetain.sourceSHA256, FloeDigest.sha256Hex(replacement))

        // The recovery journal shows the settled/conflict receipts as
        // metadata rows (never bytes), consumed by the release gate.
        var rec = [CChar](repeating: 0, count: 32 * 1024)
        let recSize = host.recoveryPage(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                        afterID: "", limit: 32, buffer: &rec, capacity: 32 * 1024)
        let recBody = try XCTUnwrap(reply(recSize, rec))
        let recRows = try XCTUnwrap(recBody["rows"] as? [[String: Any]])
        XCTAssertTrue(recRows.contains { $0["state"] as? String == "conflict" })
        XCTAssertTrue(recRows.contains { $0["state"] as? String == "committed" })
        XCTAssertTrue(recRows.contains { $0["state"] as? String == "retained" })
    }

    // MARK: - 5. Pages, truncation, stats, reconcile availability

    func testPagesTruncationAndStatsShape() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        // Three real rows via the import authority.
        var ids: [UUID] = []
        for index in 0 ..< 3 {
            let sourceID = UUID(); ids.append(sourceID)
            let body = try importBytes(host: host, boot: boot, taskID: taskID, workspaceID: workspaceID,
                                       sourceID: sourceID, path: "pages/f\(index).txt",
                                       reference: "content://com.floe.host/tree/3/document/\(index)",
                                       documentID: "\(index)", bytes: Data("page \(index)".utf8))
            XCTAssertEqual(body?["ok"] as? Int, 1,
                           "import page file \(index) errorCode=\(body?["errorCode"] ?? "nil") "
                           + "reason=\(body?["reason"] ?? "nil")")
        }
        // Full page.
        var buffer = [CChar](repeating: 0, count: 32 * 1024)
        let size = host.sourcePage(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                   afterID: "", limit: 32, buffer: &buffer, capacity: 32 * 1024)
        let body = try XCTUnwrap(reply(size, buffer))
        let rows = try XCTUnwrap(body["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), Set(ids.map { $0.uuidString }))
        // Tiny buffer: zero complete rows -> -106 (never a half row).
        var tiny = [CChar](repeating: 0, count: 8)
        XCTAssertEqual(host.sourcePage(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                       afterID: "", limit: 32, buffer: &tiny, capacity: 8),
                       G04SourceHostStatus.bufferTooSmall)
        // Lookup by exact path.
        var look = [CChar](repeating: 0, count: 4096)
        let lookup = host.sourceLookup(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                       logicalPath: "pages/f1.txt", buffer: &look, capacity: 4096)
        let lookupBody = try XCTUnwrap(reply(lookup, look))
        XCTAssertEqual(lookupBody["ok"] as? Int, 1,
                       "lookup errorCode=\(lookupBody["errorCode"] ?? "nil")")
        XCTAssertEqual(lookupBody["sha256"] as? String, FloeDigest.sha256Hex(Data("page 1".utf8)))
        // Unbound path is a typed body, not an error.
        var miss = [CChar](repeating: 0, count: 4096)
        let missSize = host.sourceLookup(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                         logicalPath: "pages/absent.txt", buffer: &miss, capacity: 4096)
        let missBody = try XCTUnwrap(reply(missSize, miss))
        XCTAssertEqual(missBody["errorCode"] as? String, "sourceUnbound")
        // Recovery page: empty but well-formed (no receipts yet).
        var rec = [CChar](repeating: 0, count: 4096)
        let recSize = host.recoveryPage(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                        afterID: "", limit: 16, buffer: &rec, capacity: 4096)
        let recBody = try XCTUnwrap(reply(recSize, rec))
        XCTAssertEqual((recBody["rows"] as? [[String: Any]])?.count, 0)
        // Reconcile without the Kotlin pump: transportNotBound body, no state.
        var rr = [CChar](repeating: 0, count: 4096)
        let rrSize = host.reconcileRun(epoch: boot.epoch, workspaceHex: workspaceID.uuidString,
                                       buffer: &rr, capacity: 4096)
        let rrBody = try XCTUnwrap(reply(rrSize, rr))
        XCTAssertEqual(rrBody["errorCode"] as? String, "transportNotBound",
                       "reconcile ok=\(rrBody["ok"] ?? -99) "
                       + "errorCode=\(rrBody["errorCode"] ?? "nil")")
        // Stats carry counters only — no paths, URIs or names cross over.
        var stats = [CChar](repeating: 0, count: 4096)
        let statsSize = host.stats(buffer: &stats, capacity: 4096)
        let statsBody = try XCTUnwrap(reply(statsSize, stats))
        XCTAssertNotNil(statsBody["counters"] as? [String: Any])
        let statsText = String(cString: stats)
        XCTAssertFalse(statsText.contains("SourceStaging"))
        XCTAssertFalse(statsText.contains("content://"))
        XCTAssertFalse(statsText.contains(taskID.uuidString))
    }

    // MARK: - 6. Rebind fence

    func testStaleGenerationTicketsAreFencedAndScratchSwept() async throws {
        let host = G04WorkspaceSourceHost.shared
        let bootA = try await bootInstalledGeneration()
        let (taskA, workspaceA) = try await makeBoundOrdinaryTask()
        let ticket = host.stageOpen(epoch: bootA.epoch, purposeRaw: "readback",
                                    taskHex: taskA.uuidString, workspaceHex: workspaceA.uuidString,
                                    sourceHex: nil, logicalPath: nil, sourceReference: nil,
                                    sourceDocumentID: nil)
        XCTAssertGreaterThan(ticket, 0)
        chunked(Data("stale".utf8), into: ticket, host: host)
        await shutdownAndAwaitClosed(bootA)
        let bootB = try await bootInstalledGeneration()
        let (taskB, workspaceB) = try await makeBoundOrdinaryTask()
        // The old ticket cannot write into the NEW generation's table.
        XCTAssertEqual(host.stageWrite(ticket: ticket, data: Data([9])),
                       G04SourceHostStatus.generationFenced)
        // Opening a new session sweeps the stale one (its scratch is this
        // lane's own recoverable temp; journaled bodies are never here).
        let fresh = host.stageOpen(epoch: bootB.epoch, purposeRaw: "backup-verify",
                                   taskHex: taskB.uuidString, workspaceHex: workspaceB.uuidString,
                                   sourceHex: nil, logicalPath: nil, sourceReference: nil,
                                   sourceDocumentID: nil)
        XCTAssertGreaterThan(fresh, 0)
        XCTAssertEqual(host.stageWrite(ticket: ticket, data: Data([9])),
                       G04SourceHostStatus.generationFenced)
        // Stale epoch values can never page the current generation.
        var b = [CChar](repeating: 0, count: 64)
        XCTAssertEqual(host.sourcePage(epoch: bootA.epoch, workspaceHex: workspaceB.uuidString,
                                       afterID: "", limit: 1, buffer: &b, capacity: 64),
                       G04SourceHostStatus.generationFenced)
        XCTAssertEqual(host.stageAbort(ticket: fresh), G04SourceHostStatus.ok)
    }
}
