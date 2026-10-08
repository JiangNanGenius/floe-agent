// FloeAppTests — the bounded edit-entry acknowledgement and the Office exit
// state machine.
//
// The Build 223 PPT edit stall could wedge a session for good when the native
// host's edit-entry completion was lost: the edit acknowledgement suspended
// forever, `operating` never cleared, and every later recovery was refused.
// `OfficeEditEntryAck` bounds that wait — the first resolver (host callback or
// timeout) wins, and a timeout reads as unverified-read-only so the session's
// re-probe and fallback decide from the engine's real state. These tests pin
// the one-shot semantics the bounded edit path relies on.
//
// The same one-shot contract protects every exit path: `OfficeSaveReceipt`
// must replay its settled result verbatim to late waiters (never degrade a
// bounded save failure into a fabricated success and never orphan a second
// waiter's continuation), and `OfficeFileSession` teardown must settle
// exactly once however many times release/save/discard race into it — the
// reentrant close/save and stale-callback regressions behind the Build 228
// exit interlock. No simulator, engine or native host is required.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeDocuments

@Suite("FloeApp.OfficeEditEntryAck")
@MainActor
struct OfficeEditEntryAckTests {

    @Test("A resolution that lands before the wait is replayed verbatim")
    func resolveBeforeWait() async {
        let ack = OfficeEditEntryAck()
        ack.resolve((false, true))
        let result = await ack.wait()
        #expect(result.readOnly == false)
        #expect(result.pendingPassword == true)
    }

    @Test("A resolution after the wait resumes the waiter once")
    func resolveAfterWait() async {
        let ack = OfficeEditEntryAck()
        async let result = ack.wait()
        ack.resolve((false, false))
        let value = await result
        #expect(value.readOnly == false)
        #expect(value.pendingPassword == false)
    }

    @Test("The first resolver wins; a late host callback can never resume twice")
    func firstResolverWins() async {
        let ack = OfficeEditEntryAck()
        ack.resolve((true, false))
        // A late native completion (or the timeout) must be ignored.
        ack.resolve((false, false))
        let result = await ack.wait()
        #expect(result.readOnly == true)
        #expect(result.pendingPassword == false)
    }

    @Test("The timeout resolution unblocks the acknowledgement as unverified read-only")
    func timeoutUnblocksAsReadOnly() async {
        let ack = OfficeEditEntryAck()
        async let result = ack.wait()
        // The bounded wait's timeout resolver.
        ack.resolve((true, false))
        let value = await result
        #expect(value.readOnly == true)
        #expect(value.pendingPassword == false)
    }
}

@Suite("FloeApp.OfficeSaveReceipt")
@MainActor
struct OfficeSaveReceiptTests {

    @Test("A success settled before the wait is replayed to every late waiter")
    func settledSuccessIsReplayed() async throws {
        let receipt = OfficeSaveReceipt()
        receipt.resolve(.success(()))
        try await receipt.wait()
        try await receipt.wait()
    }

    @Test("A failure settled before the wait keeps failing every late waiter — never a fabricated success")
    func settledFailureIsReplayedVerbatim() async {
        let receipt = OfficeSaveReceipt()
        receipt.resolve(.failure(NSError(domain: "org.floeagent.tests", code: 1)))
        for _ in 0..<2 {
            do {
                try await receipt.wait()
                Issue.record("a settled save failure must keep failing late waits")
            } catch {
                #expect((error as NSError).code == 1)
            }
        }
    }

    @Test("The first resolver wins; a stale engine receipt landing after the timeout never resumes twice")
    func firstResolverWins() async {
        let receipt = OfficeSaveReceipt()
        async let wait = receipt.wait()
        receipt.resolve(.failure(NSError(domain: "org.floeagent.tests", code: 8)))
        receipt.resolve(.success(()))
        do {
            try await wait
            Issue.record("the first (timeout) resolver must win over the stale receipt")
        } catch {
            #expect((error as NSError).code == 8)
        }
    }
}

@Suite("FloeApp.OfficeSessionExit")
@MainActor
struct OfficeSessionExitTests {

    @Test("A save on a session that never opened is refused cleanly: no error claim, no phase change")
    func saveWithoutOpenIsRefusedCleanly() async {
        let session = OfficeFileSession()
        let saved = await session.saveAndReturn()
        #expect(!saved)
        #expect(session.error == nil, "a policy refusal is not a save failure and must not surface an error")
        #expect(session.phase == .idle)
        let kept = await session.keepChangesAndReturn()
        #expect(!kept)
        #expect(session.phase == .idle)
    }

    @Test("Concurrent edit intents on a never-opened session all complete exactly once")
    func concurrentEditIntentsCompleteOnce() async {
        let session = OfficeFileSession()
        async let first = session.requestEditing()
        async let second = session.requestEditing()
        async let third = session.requestEditing()
        // No edit intent may hang or be dropped, whatever order the queued
        // intent replays behind the owning operation.
        _ = await (first, second, third)
        #expect(session.phase == .idle)
    }

    @Test("Reentrant release settles exactly once and never hangs")
    func reentrantReleaseSettlesOnce() async {
        let session = OfficeFileSession()
        async let first = session.release()
        async let second = session.release()
        _ = await (first, second)
        #expect(session.phase == .idle)
        // A later release (a second disappear/teardown) is a harmless no-op.
        await session.release()
        #expect(session.phase == .idle)
    }

    @Test("A pre-mount open failure is recoverable: the loader re-arms instead of dead-ending")
    func preMountFailureRecoveryRearmsLoader() async {
        let session = OfficeFileSession()
        session.reportOpenFailure(NSError(domain: "org.floeagent.tests", code: 2))
        #expect(session.phase == .failed)
        #expect(session.canRecoverFailedSession)
        let recovered = await session.recoverFailedSession()
        #expect(recovered)
        #expect(session.phase == .idle)
        #expect(session.error == nil)
    }
}

@Suite("FloeApp.OfficeOpenGeneration")
@MainActor
struct OfficeOpenGenerationTests {

    @Test("The generation advances monotonically per mounted open")
    func advancesMonotonically() {
        var generation = OfficeOpenGeneration()
        #expect(generation.current == 0)
        #expect(generation.advance() == 1)
        #expect(generation.advance() == 2)
        #expect(generation.current == 2)
    }

    @Test("A callback from an older generation can never settle the current session")
    func staleGenerationIsRejected() {
        var generation = OfficeOpenGeneration()
        let preview = generation.advance()
        #expect(generation.isCurrent(preview))
        // The preview-to-edit switch mounts a new controller: the generation
        // the preview's callbacks captured is stale from here on.
        let editing = generation.advance()
        #expect(generation.isCurrent(editing))
        #expect(!generation.isCurrent(preview), "a stale callback must not settle the new session")
        // A late render/permission report from the preview's controller is
        // ignored even though it arrives after the edit mount.
        #expect(!generation.isCurrent(preview))
        #expect(generation.isCurrent(editing))
    }

    @Test("Generation zero is never current once the first open advanced")
    func zeroIsNeverCurrentAfterFirstAdvance() {
        var generation = OfficeOpenGeneration()
        #expect(generation.isCurrent(0), "before any open, generation zero is the current one")
        _ = generation.advance()
        #expect(!generation.isCurrent(0))
    }
}
#endif

/// Durable stage diagnostics: correlation identity, bounded retention,
/// content-free sanitizing and on-disk JSONL. These tests do not need an
/// engine, simulator or native host; the cloud simulator run verifies the
/// real entry-path wiring against the pinned blocker.
@Suite("FloeApp.OfficeStageDiagnostics")
@MainActor
struct OfficeStageRecorderTests {

    private func temporaryTraceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("office-stage-\(UUID().uuidString).jsonl")
    }

    @Test("Events carry the correlation identity and generation and persist as JSONL")
    func recordsAndPersists() throws {
        let url = temporaryTraceURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = OfficeStageRecorder(fileURL: url, eventLimit: 16, fileLimit: 16_384)
        recorder.record(session: "session-a", generation: 2, stage: "engine.open",
                        detail: ["readOnly": "false", "success": "true"])
        recorder.record(session: "session-a", generation: 2, stage: "edit.entry")
        recorder.record(session: "session-b", generation: 1, stage: "intent.preview")

        #expect(recorder.trace(session: "session-a").map(\.stage) == ["engine.open", "edit.entry"])
        #expect(recorder.trace(session: "session-a").allSatisfy { $0.generation == 2 })
        #expect(recorder.trace(session: "session-b").map(\.stage) == ["intent.preview"])

        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n")
        #expect(lines.count == 3, "every event is one JSONL line")
        let first = try JSONDecoder().decode(OfficeStageEvent.self, from: Data(lines[0].utf8))
        #expect(first.session == "session-a")
        #expect(first.generation == 2)
        #expect(first.stage == "engine.open")
        #expect(first.detail["readOnly"] == "false")
    }

    @Test("The in-memory ring and the on-disk file stay bounded")
    func retentionIsBounded() throws {
        let url = temporaryTraceURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = OfficeStageRecorder(fileURL: url, eventLimit: 3, fileLimit: 1_024)
        for index in 0..<8 {
            recorder.record(session: "session-a", generation: index, stage: "stage.\(index)")
        }
        #expect(recorder.allEvents.count == 3, "the ring keeps only the newest events")
        #expect(recorder.allEvents.map(\.stage) == ["stage.5", "stage.6", "stage.7"])
        #expect(try Data(contentsOf: url).count <= 1_024, "the trace file stays under its byte bound")
    }

    @Test("Content-free sanitizing keeps engine facts and drops path-like values")
    func sanitizingIsContentFree() {
        #expect(OfficeStageRecorder.isContentFreeValue("pptx"))
        #expect(OfficeStageRecorder.isContentFreeValue("visible-render"))
        #expect(OfficeStageRecorder.isContentFreeValue("42"))
        #expect(!OfficeStageRecorder.isContentFreeValue("/Users/floe/secret.pptx"))
        #expect(!OfficeStageRecorder.isContentFreeValue("C:\\docs\\secret.pptx"))
        #expect(!OfficeStageRecorder.isContentFreeValue(String(repeating: "a", count: 300)))
        #expect(!OfficeStageRecorder.isContentFreeValue("line\nbreak"))
    }

    @Test("A second concurrent edit-entry wait can never orphan the first")
    func staleEditEntryWaiterSettlesReadOnly() async {
        let ack = OfficeEditEntryAck()
        async let first = ack.wait()
        await Task.yield() // first attaches
        async let second = ack.wait()
        await Task.yield() // second attaches; the stale first settles conservatively
        ack.resolve((false, false))
        let firstResult = await first
        let secondResult = await second
        #expect(firstResult.readOnly == true,
                "a superseded waiter must settle as unverified read-only, never orphaned")
        #expect(firstResult.pendingPassword == false)
        #expect(secondResult.readOnly == false, "the live waiter keeps the real resolution")
    }

    @Test("Memory samples are numeric, content-free facts with a real zero preserved")
    func memorySamplesAreContentFree() {
        let facts = OfficeMemorySample.facts()
        let physical = Int(facts["memPhysicalMB"] ?? "")
        #expect(physical != nil && physical! > 0, "physical memory must be a positive MB count")
        #if os(iOS)
        // The kernel allowance is sampled directly; a genuine 0 stays 0 and is
        // never folded into an absent fact (Build 233 execution-headroom
        // contract).
        let available = Int(facts["memAvailableMB"] ?? "")
        #expect(available != nil, "a real available-memory reading is always recorded")
        #expect(available! >= 0)
        #endif
        for value in facts.values {
            #expect(OfficeStageRecorder.isContentFreeValue(value),
                    "memory facts must stay within the content-free bound")
        }
    }

    @Test("Web-content death is a distinct recoverable render failure")
    func webContentTerminationFailure() {
        let error = OfficeRenderFailure.webContentProcessTerminated()
        #expect(error.domain == "org.floeagent.office.render")
        #expect(error.code == 2, "it must not reuse the no-visible-render code 1")
        #expect(!(error.localizedDescription.isEmpty))
    }
}

/// The IDE Office tab loader trigger. The Build 229 device pass showed the IDE
/// embedded Office surface on its opening spinner for DOCX/XLSX as well as
/// PPTX: consecutive Office tabs keep the same structural SwiftUI identity, so
/// the loader must be keyed on the active tab identity or the newly active
/// tab's session never opens.
@Suite("FloeApp.IDEOfficeLoadTrigger")
@MainActor
struct IDEOfficeLoadTriggerTests {

    @Test("Consecutive Office tabs produce distinct loader identities")
    func consecutiveOfficeTabsAreDistinct() {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let first = store.open(relativePath: "工作区/办公一.docx")
        let second = store.open(relativePath: "工作区/办公二.pptx")
        #expect(first != nil)
        #expect(second != nil)
        let firstIdentity = IDEOfficeLoadTrigger.identity(activeTab: first)
        let secondIdentity = IDEOfficeLoadTrigger.identity(activeTab: second)
        #expect(firstIdentity != secondIdentity,
                "the active tab identity must change so the keyed loader re-runs")
        #expect(store.activeTab?.id == second?.id)
    }

    @Test("Re-opening a path keeps its existing tab identity")
    func samePathKeepsItsIdentity() {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let first = store.open(relativePath: "工作区/办公一.docx")
        let again = store.open(relativePath: "工作区/办公一.docx")
        #expect(first === again, "the same path must activate its existing tab")
        #expect(IDEOfficeLoadTrigger.identity(activeTab: first)
                == IDEOfficeLoadTrigger.identity(activeTab: again))
    }

    @Test("No active tab yields the empty identity")
    func noActiveTabIsEmpty() {
        #expect(IDEOfficeLoadTrigger.identity(activeTab: nil) == "")
    }
}

// MARK: - Office command center path/ownership boundaries

/// The document.office.edit center resolves every model-supplied path through
/// the same workspace guard as any other tool and enforces task ownership; a
/// path or an access context can never redefine workspace authority.
@Suite("Office command center path and ownership", .serialized)
@MainActor
struct OfficeCommandCenterSecurityTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func access(_ root: URL, conversation: UUID? = nil) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                            ownerKind: conversation == nil ? "workspace" : "chat",
                            ownerID: conversation, conversationID: conversation)
    }

    @Test("traversal and absolute escapes are refused before any read")
    func traversalRefused() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try OfficeDocumentBuilder.createWord(at: root.appendingPathComponent("inside.docx"),
                                             title: "T", paragraphs: ["P"])
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outside) }
        try OfficeDocumentBuilder.createWord(at: outside, title: "Outside", paragraphs: ["P"])

        let center = OfficeCommandCenter()
        let context = access(root)
        await #expect(throws: (any Error).self) {
            _ = try await center.status(documentID: "../\(outside.lastPathComponent)", access: context)
        }
        await #expect(throws: (any Error).self) {
            _ = try await center.status(documentID: outside.path, access: context)
        }
        // The legitimate file still resolves.
        let status = try await center.status(documentID: "inside.docx", access: context)
        #expect(status.documentID == "inside.docx")
    }

    @Test("a symlink inside the root cannot escape to an outside document")
    func symlinkEscapeRefused() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideDirectory = try workspace()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outside = outsideDirectory.appendingPathComponent("secret.docx")
        try OfficeDocumentBuilder.createWord(at: outside, title: "Outside", paragraphs: ["P"])
        let link = root.appendingPathComponent("alias.docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let center = OfficeCommandCenter()
        await #expect(throws: (any Error).self) {
            _ = try await center.status(documentID: "alias.docx", access: access(root))
        }
    }

    @Test("chat-origin callers must present their task identity")
    func missingTaskOwnershipRefused() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = OfficeCommandCenter()
        let anonymousChat = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                                ownerKind: "chat", ownerID: nil, conversationID: nil)
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(anonymousChat)
        }
        try await center.authorizeAccess(access(root))
    }

    @Test("a proposal made by one task is unreachable from another")
    func crossOwnerDenied() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try OfficeDocumentBuilder.createWord(at: root.appendingPathComponent("plan.docx"),
                                             title: "T", paragraphs: ["P"])
        let owner = UUID()
        let other = UUID()
        let session = OfficeFileSession()
        session.registerLiveDocument(relativePath: "plan.docx", root: root, conversationID: owner)
        defer { Task { await session.release() } }

        let center = OfficeCommandCenter()
        let ownerAccess = access(root, conversation: owner)
        let foreignAccess = access(root, conversation: other)
        // The owner's status resolves (the session is registered); it is not
        // "live" until a working document is actually opened in the editor.
        let snapshot = try await center.status(documentID: "plan.docx", access: ownerAccess)
        #expect(snapshot.documentID == "plan.docx")

        // The foreign task is refused before prepareProposal can even see the
        // live session.
        await #expect(throws: (any Error).self) {
            _ = try await center.prepareProposal(
                documentID: "plan.docx", baseSHA256: snapshot.revisionSHA256,
                summary: "insert table",
                commandsJSON: #"[{"id":"word.insertTable","arguments":{"rows":"2","columns":"2"}}]"#,
                access: foreignAccess)
        }
        // A workspace-only caller (no conversation) is also refused when the
        // session belongs to a task.
        let workspaceOnly = access(root, conversation: nil)
        await #expect(throws: (any Error).self) {
            _ = try await center.status(documentID: "plan.docx", access: workspaceOnly)
        }
    }

    @Test("an unowned live session is reachable by same-workspace callers")
    func workspaceSessionReachable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try OfficeDocumentBuilder.createWord(at: root.appendingPathComponent("plan.docx"),
                                             title: "T", paragraphs: ["P"])
        let session = OfficeFileSession()
        session.registerLiveDocument(relativePath: "plan.docx", root: root, conversationID: nil)
        defer { Task { await session.release() } }
        let center = OfficeCommandCenter()
        // Same-workspace callers are not refused; without an opened working
        // document the status is file-only rather than claiming a live editor.
        let snapshot = try await center.status(documentID: "plan.docx", access: access(root))
        #expect(snapshot.documentID == "plan.docx")
        #expect(snapshot.liveSession == false)
    }
}

// MARK: - Office committed-batch journal / WAL reconciliation

/// The Office batch journal is the crash-window contract: a prepared entry is
/// reconciled against the exact expected file SHA before anything is treated
/// as committed, and a lost completion marker is recoverable while an uncertain
/// state fails closed.
@Suite("Office committed batch journal", .serialized)
@MainActor
struct OfficeBatchJournalTests {
    private func entry(batchID: String, documentID: String, expected: String,
                       snapshot: String = "/tmp/office-snapshot.docx") -> OfficeCommittedBatchJournal.Entry {
        OfficeCommittedBatchJournal.Entry(
            batchID: batchID, documentID: documentID, workspacePath: "/tmp/ws",
            operationID: "op-\(batchID)", expectedSHA256: expected,
            snapshotPath: snapshot, snapshotSHA256: String(repeating: "e", count: 64),
            commands: ["word.insertTable"], preparedAt: Date(), committedAt: nil, note: nil)
    }

    @Test("reconciliation trusts only the exact expected SHA")
    func reconciliationMatrix() {
        let expected = String(repeating: "a", count: 64)
        let prepared = entry(batchID: "b1", documentID: "doc.docx", expected: expected)
        // Exact bytes on disk prove the commit even without the marker.
        #expect(OfficeBatchReconciliation.decide(entry: prepared, currentFileSHA: expected) == .committed)
        // Different bytes: the commit did not land.
        #expect(OfficeBatchReconciliation.decide(entry: prepared,
                                                 currentFileSHA: String(repeating: "b", count: 64)) == .preparedNotCommitted)
        // Unknown/unreadable file fails closed.
        #expect(OfficeBatchReconciliation.decide(entry: prepared, currentFileSHA: nil) == .unknown)
        // A completed marker with different bytes is an uncertain state.
        var completed = prepared
        completed.committedAt = Date()
        #expect(OfficeBatchReconciliation.decide(entry: completed,
                                                 currentFileSHA: String(repeating: "c", count: 64)) == .unknown)
    }

    @Test("prepare, complete, latest committed and remove round-trip durably")
    func journalLifecycle() throws {
        let id = "journal-test-\(UUID().uuidString)"
        let document = "journal-test-\(UUID().uuidString).docx"
        let prepared = entry(batchID: id, documentID: document, expected: String(repeating: "d", count: 64))
        try OfficeCommittedBatchJournal.shared.prepare(prepared)
        #expect(OfficeCommittedBatchJournal.shared.entry(batchID: id)?.isCommitted == false)
        #expect(OfficeCommittedBatchJournal.shared.latestCommitted(documentID: document) == nil,
                "a prepared-only entry is never offered as a revert point")

        try OfficeCommittedBatchJournal.shared.complete(batchID: id)
        #expect(OfficeCommittedBatchJournal.shared.entry(batchID: id)?.isCommitted == true)
        #expect(OfficeCommittedBatchJournal.shared.latestCommitted(documentID: document)?.batchID == id)
        #expect(OfficeCommittedBatchJournal.shared.latestCommitted(documentID: document)?.expectedSHA256
                == prepared.expectedSHA256)

        OfficeCommittedBatchJournal.shared.remove(batchID: id)
        #expect(OfficeCommittedBatchJournal.shared.entry(batchID: id) == nil)
        #expect(OfficeCommittedBatchJournal.shared.latestCommitted(documentID: document) == nil)
    }
}
