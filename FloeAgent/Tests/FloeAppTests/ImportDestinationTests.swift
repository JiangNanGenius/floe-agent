// FloeAppTests — inbound import destination chooser (导入手记 / 导入任务 / 导入画布).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this source lane.
// The unified qualification run owns execution after the primary integrates
// this file into the FloeAppTests source list, the bilingual catalog
// entries and the draft-sync job's live-owner seam wiring.
//
// Coverage:
// * durable decision ledger: atomic roundtrip, corrupt-entry fail-closed,
//   no temporary fallback when the root cannot be created
// * the choice requirement lives in the staged record (atomic intake);
//   missing/corrupt ledger entries HOLD flagged records and never silently
//   default them; unflagged legacy/explicit records keep the old pipeline
// * queue gate: flagged pending heads are skipped without damage while
//   younger ready records still import; the ungated API is unchanged
// * document event → Notes releases the drain; event → Task converts to an
//   envelope (original name/type/bytes) and discards the source only after
//   the commit; a re-run completes instead of double-staging
// * document event → Canvas persists target + identity before copy,
//   releases the record only after the proven commit, and a failed commit
//   restores a re-choosable pending record
// * share envelope → Notes imports every unit by pre-persisted planned
//   identity, joins text into one .txt document, defers on claim-busy,
//   settles a crash-after-commit-before-ack without re-importing, and keeps
//   the envelope pending on a blocked importer until resume
// * share envelope → Task to a confirmed existing task merges through the
//   SAME commitDurable + receipt primitive preserving draft text and
//   attachments; a live owner defers BEFORE any staging/commit; an
//   unavailable target copies nothing; New Task persists only a marker and
//   leaves the envelope pending for the reviewed card
// * presentation is peek/confirm: blocked choosers are never consumed;
//   Cancel on a document event uses queue cancellation and banner Retry
//   re-arms exactly one fresh choice; Cancel on an envelope keeps it
//   pending for the Home share card
// * picker seams: the task provider returns ALL ordinary non-archived
//   tasks and THROWS on store failure (never a fake-empty list); the canvas
//   list is unclipped
//
// Synthetic content only. No provider is contacted, no real user file is
// read, nothing is sent or run. Filesystem work uses unique temporary
// roots.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeModels
import FloeNotes
import FloePersistence
@testable import FloeApp

// MARK: - Helpers

private func importTestRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func importTestInbox(_ name: String = "import-inbox") -> ShareInbox {
    ShareInbox(
        rootURL: importTestRoot(name),
        limits: ShareInboxLimits(
            maxItemBytes: 64_000,
            maxEnvelopeBytes: 120_000,
            claimRecoveryGrace: 0
        )
    )
}

private func writeImportSource(_ name: String, _ data: Data) throws -> URL {
    let directory = importTestRoot("import-sources")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func pdfBytes(_ seed: UInt8, count: Int = 220) -> Data {
    var bytes: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D] // %PDF-
    bytes.append(contentsOf: (0..<count).map { UInt8((Int($0) + Int(seed)) % 251) })
    return Data(bytes)
}

private func makeEnvelope(
    in inbox: ShareInbox,
    text: String? = nil,
    files: [(name: String, data: Data, type: String)] = [],
    createdAt: Date = Date()
) throws -> ShareEnvelope {
    var inputs: [ShareInboxInput] = []
    if let text {
        inputs.append(ShareInboxInput(kind: .text, payload: .text(text)))
    }
    for file in files {
        let url = try writeImportSource(file.name, file.data)
        inputs.append(ShareInboxInput(
            kind: .file,
            payload: .file(url),
            displayName: file.name,
            typeIdentifier: file.type
        ))
    }
    return try inbox.stage(inputs: inputs, producer: "tests", createdAt: createdAt)
}

@MainActor
private func poll(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ body: @MainActor () async -> Bool
) async -> Bool {
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
        if await body() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
        waited += 25_000_000
    }
    return await body()
}

private func makeDecisionStore(_ root: URL) -> ImportDestinationDecisionStore {
    ImportDestinationDecisionStore(root: root)
}

private func sharePending(_ inbox: ShareInbox, _ id: UUID) -> Bool {
    ((try? inbox.pending()) ?? []).contains { $0.id == id }
}

private func request(for envelope: ShareEnvelope, fileNames: [String]) -> ImportDestinationRequest {
    ImportDestinationRequest(
        id: UUID(),
        origin: .shareEnvelope(envelope.id),
        itemCount: envelope.items.count,
        fileNames: fileNames,
        includesText: !envelope.textItems.isEmpty,
        sourceUpdated: envelope.createdAt
    )
}

// MARK: - Fakes

private actor ImportTestNotesLibrary {
    private var documents: [UUID: NoteDocument] = [:]
    private var blocked: Set<UUID> = []
    private(set) var imports: [(
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        bytes: Int,
        displayName: String
    )] = []

    func block(_ id: UUID) { blocked.insert(id) }
    func unblock(_ id: UUID) { blocked.remove(id) }

    func existing(_ id: UUID) -> NoteDocument? { documents[id] }

    func importDocument(
        from url: URL,
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        displayName: String
    ) throws -> NotesImportOutcome {
        if blocked.contains(plannedRootID) {
            throw DocumentIntakeError.importFailed
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        imports.append((kind, plannedRootID, data.count, displayName))
        var document = NoteDocument(id: plannedRootID, title: "Imported \(imports.count)")
        document.pages = [NotePage()]
        documents[plannedRootID] = document
        return NotesImportOutcome(
            rootDocumentID: plannedRootID,
            documentIDs: [plannedRootID],
            title: document.title
        )
    }
}

private struct FakeNotesImporter: NotesDocumentImporting {
    let library: ImportTestNotesLibrary

    func existingDocument(id: UUID) async throws -> NoteDocument? {
        await library.existing(id)
    }

    func documentIDs(inBundle rootID: UUID) async throws -> [UUID] {
        [rootID]
    }

    func importNotes(
        from url: URL,
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        displayName: String
    ) async throws -> NotesImportOutcome {
        try await library.importDocument(
            from: url,
            kind: kind,
            plannedRootID: plannedRootID,
            displayName: displayName
        )
    }
}

private final class FakeStaging: ShareAttachmentStaging, @unchecked Sendable {
    private(set) var stagedURLs: [URL] = []
    private(set) var discarded: [AttachmentRef] = []

    func stageShareAttachment(
        from url: URL,
        displayName: String,
        typeIdentifier: String,
        kind: ShareInboxItemKind,
        envelopeID: UUID
    ) async throws -> AttachmentRef {
        stagedURLs.append(url)
        return AttachmentRef(
            kind: .document,
            displayName: displayName,
            uti: typeIdentifier,
            byteCount: ((try? Data(contentsOf: url)) ?? Data()).count,
            storage: .applicationSupport,
            relativePath: "fake-staged-\(stagedURLs.count).bin"
        )
    }

    func discardShareAttachment(_ attachment: AttachmentRef) async {
        discarded.append(attachment)
    }
}

@MainActor
private final class FakeCommitter: CanvasDestinationCommitting {
    var failNext = false
    var lastOperation: CanvasImportOperation?
    var payloadsAtCommit: [Data] = []
    var operations: [CanvasImportOperation] = []
    var commitCanvasID = UUID()
    var calls = 0
    var targetsResult: [CanvasImportTarget] = [
        .init(id: UUID(), name: "Floor plan"),
        .init(id: UUID(), name: "Ink study"),
    ]

    func canvasImportTargets() throws -> [CanvasImportTarget] { targetsResult }

    func commitImport(_ operation: CanvasImportOperation) async -> CanvasCommitResult {
        calls += 1
        lastOperation = operation
        operations.append(operation)
        // Payload URLs are borrowed for this call. A successful destination
        // releases the source, so assertions must retain bytes here.
        do {
            payloadsAtCommit = try operation.units.map { try Data(contentsOf: $0.payloadURL) }
        } catch {
            return .failed(message: "Test committer could not read its payload")
        }
        if failNext { return .failed(message: nil) }
        return .committed(
            canvasID: operation.plannedNewCanvasID ?? commitCanvasID,
            nodeIDs: operation.units.map(\.plannedNodeID)
        )
    }
}

private final class FakeTaskProvider: TaskDestinationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _targets: [TaskImportTarget] = []
    private var _failNext = false
    private var _available: Set<UUID> = []

    func setTargets(_ value: [TaskImportTarget]) {
        lock.withLock { _targets = value.sorted { $0.updatedAt > $1.updatedAt } }
    }
    func setFailNext(_ value: Bool) { lock.withLock { _failNext = value } }
    func setAvailable(_ value: Set<UUID>) { lock.withLock { _available = value } }

    func taskImportTargets() async throws -> [TaskImportTarget] {
        let (fail, targets): (Bool, [TaskImportTarget]) = lock.withLock {
            (_failNext, _targets)
        }
        if fail { throw DocumentIntakeError.ioFailure }
        return targets
    }

    func isTaskTargetAvailable(_ conversationID: UUID) async -> Bool {
        lock.withLock { _available.contains(conversationID) }
    }
}

@MainActor
private final class RecordingLiveDraftOwner: ComposerDraftStore.ImportedDraftLiveAccepting {
    var landings: [ComposerDraftStore.ImportedDraftLanding] = []
    func acceptImportedDraftLanding(_ landing: ComposerDraftStore.ImportedDraftLanding) {
        landings.append(landing)
    }
}

// MARK: - Ledger

@Suite("FloeApp.ImportDestinationLedger")
@MainActor
struct ImportDestinationLedgerTests {

    @Test("Decision roundtrip, corrupt entry and removal")
    func decisionRoundtrip() throws {
        let root = importTestRoot("ledger-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        // The ledger's ISO-8601 wire format stores whole seconds.
        let store = ImportDestinationDecisionStore(root: root, now: { Date(timeIntervalSince1970: 9_000) })
        #expect(store.isAvailable)
        let envelopeID = UUID()
        let origin = ImportDestinationOrigin.shareEnvelope(envelopeID)
        let planned = UUID()
        #expect(store.load(origin) == nil)
        let saved = try store.save(ImportDestinationDecision(
            origin: origin,
            status: .notes,
            chosenAt: Date(timeIntervalSince1970: 9_000),
            units: [.init(key: "items/item-1.pdf", plannedDocumentID: planned)],
            updatedAt: Date(timeIntervalSince1970: 9_000)
        ))
        let loaded = store.load(origin)
        #expect(loaded?.status == .notes)
        #expect(loaded?.units.first?.plannedDocumentID == planned)
        #expect(loaded?.updatedAt == saved.updatedAt)

        // A corrupt ledger file loads as absent: the gate then HOLDS a
        // flagged record; it never permits a silent import.
        let url = root.appendingPathComponent("share-\(envelopeID.uuidString).json")
        try Data("not-json".utf8).write(to: url)
        #expect(store.load(origin) == nil)
        store.remove(origin)
        #expect(store.load(origin) == nil)
        #expect(!store.all().contains { $0.origin == origin })
    }

    @Test("Gate requires the durable flag; only an explicit Notes decision releases")
    func gateFailClosed() {
        func record(flag: Bool?) -> DocumentIntakeRecord {
            DocumentIntakeRecord(
                id: UUID(),
                kind: .pdf,
                displayName: "plan.pdf",
                stagedFileName: "payload.pdf",
                byteCount: 3,
                sha256: String(repeating: "a", count: 64),
                contentTypeIdentifier: "com.adobe.pdf",
                plannedRootDocumentID: UUID(),
                createdAt: Date(),
                sceneID: nil,
                requestSequence: 1,
                destinationChoiceRequired: flag
            )
        }
        let eventID = UUID()
        let flagged = record(flag: true)
        let plain = record(flag: nil)
        let explicit = record(flag: false)

        // No requirement (legacy entry or explicit in-product import):
        // unchanged pipeline.
        #expect(ImportDestinationDecisionStore.autoImportIsCleared(for: plain, decision: nil))
        #expect(ImportDestinationDecisionStore.autoImportIsCleared(for: explicit, decision: nil))
        // Requirement present: a missing decision can only HOLD.
        #expect(!ImportDestinationDecisionStore.autoImportIsCleared(for: flagged, decision: nil))
        let taskCleared = ImportDestinationDecisionStore.autoImportIsCleared(
            for: flagged,
            decision: .init(origin: .documentEvent(eventID), status: .task, chosenAt: nil, updatedAt: Date())
        )
        let canvasCleared = ImportDestinationDecisionStore.autoImportIsCleared(
            for: flagged,
            decision: .init(origin: .documentEvent(eventID), status: .canvas, chosenAt: nil, updatedAt: Date())
        )
        #expect(!taskCleared)
        #expect(!canvasCleared)
        #expect(ImportDestinationDecisionStore.autoImportIsCleared(
            for: flagged,
            decision: .init(origin: .documentEvent(eventID), status: .notes, chosenAt: nil, updatedAt: Date())
        ))
    }

    @Test("Store root has no temporary fallback and reports unavailable")
    func storeAvailabilityFailsClosed() throws {
        let blockedParent = importTestRoot("blocked-parent")
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        try Data("file-not-directory".utf8).write(to: blockedParent)
        let store = ImportDestinationDecisionStore(
            root: blockedParent.appendingPathComponent("child", isDirectory: true)
        )
        #expect(!store.isAvailable)
        let center = ImportDestinationCenter(
            inbox: importTestInbox("no-ledger-inbox"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: store
        )
        #expect(!center.isLedgerAvailable)
        // Fail closed: even through the instance helper, a flagged record
        // is never released without a ledger answer.
        let flagged = DocumentIntakeRecord(
            id: UUID(),
            kind: .pdf,
            displayName: "hold.pdf",
            stagedFileName: "payload.pdf",
            byteCount: 3,
            sha256: String(repeating: "c", count: 64),
            contentTypeIdentifier: nil,
            plannedRootDocumentID: UUID(),
            createdAt: Date(),
            sceneID: nil,
            requestSequence: 1,
            destinationChoiceRequired: true
        )
        #expect(!store.autoImportIsCleared(for: flagged))
    }
}

// MARK: - Queue requirement + gate

@Suite("FloeApp.ImportDestinationGate")
@MainActor
struct ImportDestinationGateTests {

    @Test("Ambiguous intake persists the requirement atomically; explicit intake does not")
    func requirementLandsInEntry() async throws {
        let root = importTestRoot("requirement-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportTestNotesLibrary()
        // markStoresReady is deliberately NOT called: staging still runs,
        // the drain never starts, so both records remain verifiable.
        let doc = DocumentIntakeCenter(
            root: root,
            limits: .production,
            notes: FakeNotesImporter(library: library)
        )
        let queue = try #require(doc.queue)
        let ambiguous = try writeImportSource("open.pdf", pdfBytes(3))
        let plain = try writeImportSource("plain.pdf", pdfBytes(4))

        let flaggedEvent = try #require(
            doc.submit(ambiguous, sceneID: "scene-a", destinationChoiceRequired: true)
        )
        let plainEvent = try #require(doc.submit(plain, sceneID: "scene-a"))

        let flaggedOK = await poll {
            guard let staged = try? await queue.pendingPayload(id: flaggedEvent) else { return false }
            return staged.record.destinationChoiceRequired == true
        }
        #expect(flaggedOK)
        let plainStaged = try #require(await queue.pendingPayload(id: plainEvent))
        #expect(plainStaged.record.destinationChoiceRequired != true)
        var imports = await library.imports
        #expect(imports.isEmpty)
    }

    @Test("Flagged pending heads are skipped without damage; ready records still import")
    func gateSkipsFlaggedHeads() async throws {
        let root = importTestRoot("gate-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DocumentIntakeQueue(root: root)
        let flaggedFile = try writeImportSource("held.pdf", pdfBytes(5))
        let readyFile = try writeImportSource("ready.pdf", pdfBytes(6))
        let flaggedID = UUID()
        let readyID = UUID()
        let now = Date()
        let flaggedRequest = DocumentIntakeStagingRequest(
            eventID: flaggedID, plannedRootDocumentID: UUID(),
            sceneID: nil, requestSequence: 1, receivedAt: now,
            destinationChoiceRequired: true
        )
        let readyRequest = DocumentIntakeStagingRequest(
            eventID: readyID, plannedRootDocumentID: UUID(),
            sceneID: nil, requestSequence: 2, receivedAt: now.addingTimeInterval(1),
            destinationChoiceRequired: false
        )
        let flaggedStaged = try await DocumentIntakeStager.stage(
            flaggedFile, root: queue.root, limits: .production, request: flaggedRequest,
            lease: DocumentIntakeProviderLease(url: flaggedFile)
        )
        _ = try await queue.enqueue(flaggedStaged)
        let readyStaged = try await DocumentIntakeStager.stage(
            readyFile, root: queue.root, limits: .production, request: readyRequest,
            lease: DocumentIntakeProviderLease(url: readyFile)
        )
        _ = try await queue.enqueue(readyStaged)

        let gate: @Sendable (DocumentIntakeRecord) -> Bool = { record in
            record.destinationChoiceRequired != true
        }
        let claim = try #require(await queue.claimNext(where: gate))
        #expect(claim.record.id == readyID)
        try await queue.requeue(claim)

        let held = try #require(await queue.record(id: flaggedID))
        #expect(held.state == .pending)
        #expect(held.attemptCount == 0)

        // Ungated callers keep the original head-first FIFO unchanged.
        let unfiltered = try #require(await queue.claimNext())
        #expect(unfiltered.record.id == flaggedID)
    }

    @Test("Wired chooser holds a flagged arrival and Canvas choice completes before release")
    func eventChoicesThroughWiredCenter() async throws {
        let inbox = importTestInbox("wired-inbox")
        let docRoot = importTestRoot("wired-doc")
        let decisionRoot = importTestRoot("wired-decisions")
        defer {
            try? FileManager.default.removeItem(at: docRoot)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let doc = DocumentIntakeCenter(
            root: docRoot,
            limits: .production,
            notes: FakeNotesImporter(library: library)
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let committer = FakeCommitter()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot),
            canvas: committer
        )
        // Same production order: gate installed before stores are ready.
        center.start(shareCenter: share, documentCenter: doc)
        doc.markStoresReady()

        let file = try writeImportSource("report.pdf", pdfBytes(9))
        let eventID = try #require(
            doc.submit(file, sceneID: "scene-a", destinationChoiceRequired: true)
        )
        let presented = await poll {
            center.peekDestinationRequest()?.origin == .documentEvent(eventID)
        }
        #expect(presented)
        let request = try #require(center.peekDestinationRequest())
        center.beginPresentation()
        center.confirmPresentation(request)
        try? await Task.sleep(for: .milliseconds(150))
        var imports = await library.imports
        #expect(imports.isEmpty) // gated: nothing auto-imported to Notes

        let result = await center.perform(.canvas, for: request, canvasTarget: .newCanvas)
        guard case .canvasReady(let count) = result else {
            Issue.record("expected canvasReady, got \(result)")
            return
        }
        #expect(count == 1)
        #expect(committer.calls == 1)
        let operation = try #require(committer.lastOperation)
        #expect(operation.originID == eventID)
        #expect(operation.units.count == 1)
        #expect(operation.units.first?.key == "file")
        #expect(operation.plannedNewCanvasID != nil)
        let committed = committer.payloadsAtCommit.first
        #expect(committed == pdfBytes(9))
        let released = await poll {
            (try? await doc.queue?.record(id: eventID)) == nil
        }
        #expect(released)
        imports = await library.imports
        #expect(imports.isEmpty) // Canvas choice never imports to Notes
    }

    @Test("Event Task choice converts without ever staging a second envelope")
    func eventToTaskSingleEnvelope() async throws {
        let inbox = importTestInbox("event-task")
        let docRoot = importTestRoot("event-task-doc")
        let decisionRoot = importTestRoot("event-task-decisions")
        defer {
            try? FileManager.default.removeItem(at: docRoot)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let doc = DocumentIntakeCenter(
            root: docRoot,
            limits: .production,
            notes: FakeNotesImporter(library: library)
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot)
        )
        center.start(shareCenter: share, documentCenter: doc)
        doc.markStoresReady()

        let source = pdfBytes(10)
        let file = try writeImportSource("converted.pdf", source)
        let eventID = try #require(
            doc.submit(file, sceneID: "scene-a", destinationChoiceRequired: true)
        )
        _ = await poll { center.peekDestinationRequest()?.origin == .documentEvent(eventID) }
        let request = try #require(center.peekDestinationRequest())
        center.confirmPresentation(request)
        let first = await center.perform(.task, for: request, taskTarget: .newTask)
        #expect(first == .taskReady(target: .newTask))
        let envelopes = (try? inbox.pending()) ?? []
        #expect(envelopes.count == 1)
        let envelope = try #require(envelopes.first)
        let item = try #require(envelope.attachmentItems.first)
        #expect(item.fileName == "converted.pdf")
        #expect(item.typeIdentifier == "com.adobe.pdf")
        let payload = try inbox.payloadURL(for: item, in: envelope)
        #expect(try Data(contentsOf: payload) == source)
        let released = await poll { (try? await doc.queue?.record(id: eventID)) == nil }
        #expect(released)

        // Re-running the same decision (crash-after-commit shape) must
        // settle the hand-off instead of staging a second envelope.
        let store = makeDecisionStore(decisionRoot)
        _ = try store.save(ImportDestinationDecision(
            origin: .documentEvent(eventID),
            status: .task,
            chosenAt: Date(),
            envelopeID: envelope.id,
            taskTarget: .newTask,
            updatedAt: Date()
        ))
        let again = await center.perform(.task, for: request, taskTarget: .newTask)
        #expect(again == .taskReady(target: .newTask))
        #expect(((try? inbox.pending()) ?? []).count == 1)
    }

    @Test("Cancel on a document event uses queue cancellation and retry re-arms one choice")
    func eventCancelRetry() async throws {
        let inbox = importTestInbox("cancel-inbox")
        let docRoot = importTestRoot("cancel-doc")
        let decisionRoot = importTestRoot("cancel-decisions")
        defer {
            try? FileManager.default.removeItem(at: docRoot)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let doc = DocumentIntakeCenter(
            root: docRoot,
            limits: .production,
            notes: FakeNotesImporter(library: library)
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot)
        )
        center.start(shareCenter: share, documentCenter: doc)
        doc.markStoresReady()

        let file = try writeImportSource("cancel.pdf", pdfBytes(11))
        let eventID = try #require(
            doc.submit(file, sceneID: "scene-a", destinationChoiceRequired: true)
        )
        _ = await poll { center.peekDestinationRequest()?.origin == .documentEvent(eventID) }
        let request = try #require(center.peekDestinationRequest())
        center.confirmPresentation(request)
        center.cancelPresentation(request)

        let cancelled = await poll {
            ((try? await doc.queue?.record(id: eventID)) ?? nil)?.state == .cancelled
        }
        #expect(cancelled)
        var imports = await library.imports
        #expect(imports.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await doc.retry(eventID)
        let rearmed = await poll {
            center.peekDestinationRequest()?.origin == .documentEvent(eventID)
        }
        #expect(rearmed)
        imports = await library.imports
        #expect(imports.isEmpty)
    }

    @Test("Blocked presentation is never consumed")
    func peekDoesNotConsume() async throws {
        let inbox = importTestInbox("peek-inbox")
        let decisionRoot = importTestRoot("peek-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot)
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let doc = DocumentIntakeCenter(
            root: importTestRoot("peek-doc"),
            notes: FakeNotesImporter(library: library)
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("peek.pdf", pdfBytes(21), "com.adobe.pdf")]
        )
        await share.refresh()
        let ready = await poll { center.peekDestinationRequest() != nil }
        #expect(ready)
        let first = center.peekDestinationRequest()
        let second = center.peekDestinationRequest()
        #expect(first?.origin == .shareEnvelope(envelope.id))
        #expect(second?.origin == first?.origin)
        if let first {
            center.beginPresentation()
            center.confirmPresentation(first)
        }
        #expect(center.peekDestinationRequest()?.origin != .shareEnvelope(envelope.id))
        #expect(sharePending(inbox, envelope.id))
    }

    @Test("Cancel on an envelope keeps it pending and is not re-offered this process")
    func envelopeCancelKeepsSource() async throws {
        let inbox = importTestInbox("envelope-cancel")
        let decisionRoot = importTestRoot("envelope-cancel-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot)
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let doc = DocumentIntakeCenter(
            root: importTestRoot("envelope-cancel-doc"),
            notes: FakeNotesImporter(library: library)
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("keep.pdf", pdfBytes(22), "com.adobe.pdf")]
        )
        await share.refresh()
        _ = await poll { center.peekDestinationRequest() != nil }
        let request = try #require(center.peekDestinationRequest())
        center.confirmPresentation(request)
        center.cancelPresentation(request)
        await center.observeShareArrival(focusedEnvelopeID: envelope.id)
        #expect(center.peekDestinationRequest()?.origin != .shareEnvelope(envelope.id))
        #expect(sharePending(inbox, envelope.id))
    }

    @Test("Task and Canvas lists: full retrieval, real failures surface")
    func pickerListSemantics() async throws {
        let library = ImportTestNotesLibrary()
        let provider = FakeTaskProvider()
        let ids = (0..<45).map { _ in UUID() }
        provider.setTargets(ids.enumerated().map { index, id in
            TaskImportTarget(
                id: id,
                title: "Task \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(1_000 + index))
            )
        })
        let committer = FakeCommitter()
        let center = ImportDestinationCenter(
            inbox: nil,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(importTestRoot("lists-decisions")),
            canvas: committer,
            taskProvider: provider
        )
        let all = try await center.loadTaskImportTargets()
        #expect(all.count == 45)
        #expect(all.first?.title == "Task 44") // newest first, nothing clipped
        provider.setFailNext(true)
        await #expect(throws: (any Error).self) {
            _ = try await center.loadTaskImportTargets()
        }
        #expect(try center.loadCanvasImportTargets().count == 2)
        let noProvider = ImportDestinationCenter(
            inbox: nil,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(importTestRoot("lists-decisions-2"))
        )
        await #expect(throws: (any Error).self) {
            _ = try await noProvider.loadTaskImportTargets()
        }
        #expect(noProvider.canvasImportTargets().isEmpty)
    }
}

// MARK: - Envelope choices

@Suite("FloeApp.ImportDestinationEnvelope")
@MainActor
struct ImportDestinationEnvelopeTests {

    @Test("Notes choice imports every unit by planned identity, joins text, acks only after")
    func notesImportDurablePlan() async throws {
        let inbox = importTestInbox("notes-envelope")
        let decisionRoot = importTestRoot("notes-envelope-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let library = ImportTestNotesLibrary()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: makeDecisionStore(decisionRoot)
        )
        let envelope = try makeEnvelope(
            in: inbox,
            text: "first line\nsecond line",
            files: [
                ("a.pdf", pdfBytes(1), "com.adobe.pdf"),
                ("b.pdf", pdfBytes(2), "com.adobe.pdf"),
            ]
        )
        let result = await center.perform(
            .notes,
            for: request(for: envelope, fileNames: ["a.pdf", "b.pdf"])
        )
        guard case .notesImported(let count) = result else {
            Issue.record("expected notesImported, got \(result)")
            return
        }
        #expect(count == 3) // two files + one joined text document
        let imports = await library.imports
        #expect(imports.count == 3)
        #expect(imports.contains { $0.kind == .text })
        // Original bytes are preserved for the file documents.
        #expect(imports.contains { $0.bytes == pdfBytes(1).count })
        #expect(imports.contains { $0.bytes == pdfBytes(2).count })
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        let store = makeDecisionStore(decisionRoot)
        #expect(store.load(.shareEnvelope(envelope.id)) == nil)
    }

    @Test("Claim-busy defers without touching the source")
    func notesClaimBusy() async throws {
        let inbox = importTestInbox("notes-busy")
        let decisionRoot = importTestRoot("notes-busy-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot)
        )
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("busy.pdf", pdfBytes(40), "com.adobe.pdf")]
        )
        let claim = try inbox.claim(id: envelope.id)
        let result = await center.perform(.notes, for: request(for: envelope, fileNames: ["busy.pdf"]))
        #expect(result == .deferred)
        #expect(sharePending(inbox, envelope.id))
        try inbox.release(claim)
    }

    @Test("Crash after commit before ack settles from planned ids without re-import")
    func notesIdempotentAfterCommit() async throws {
        let inbox = importTestInbox("notes-idempotent")
        let decisionRoot = importTestRoot("notes-idempotent-decisions")
        let store = makeDecisionStore(decisionRoot)
        let library = ImportTestNotesLibrary()
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: store
        )
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("only.pdf", pdfBytes(7), "com.adobe.pdf")]
        )
        let item = try #require(envelope.items.first)
        let storageName = try #require(item.storageName)

        // Simulate the crash window: the planned document already exists
        // (durable import), the ledger persists that planned id with no
        // committedAt, and the envelope is still pending (ack never ran).
        let plannedID = UUID()
        let url = try inbox.payloadURL(for: item, in: envelope)
        _ = try await library.importDocument(
            from: url, kind: .pdf, plannedRootID: plannedID, displayName: "only.pdf"
        )
        _ = try store.save(ImportDestinationDecision(
            origin: .shareEnvelope(envelope.id),
            status: .notes,
            chosenAt: Date(),
            units: [.init(key: storageName, plannedDocumentID: plannedID)],
            updatedAt: Date()
        ))
        let importsBefore = await library.imports.count
        #expect(importsBefore == 1)

        let result = await center.perform(.notes, for: request(for: envelope, fileNames: ["only.pdf"]))
        guard case .notesImported = result else {
            Issue.record("expected notesImported recovery, got \(result)")
            return
        }
        let importsAfter = await library.imports.count
        #expect(importsAfter == importsBefore) // no second import for the proven id
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        #expect(store.load(.shareEnvelope(envelope.id)) == nil)
    }

    @Test("A blocked importer keeps the envelope pending; resume imports exactly once")
    func notesFailureResumes() async throws {
        let inbox = importTestInbox("notes-failure")
        let decisionRoot = importTestRoot("notes-failure-decisions")
        let store = makeDecisionStore(decisionRoot)
        let library = ImportTestNotesLibrary()
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: library),
            store: store
        )
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("late.pdf", pdfBytes(9), "com.adobe.pdf")]
        )
        let item = try #require(envelope.items.first)
        let blockedID = UUID()
        await library.block(blockedID)
        _ = try store.save(ImportDestinationDecision(
            origin: .shareEnvelope(envelope.id),
            status: .notes,
            chosenAt: Date(),
            units: [.init(key: try #require(item.storageName), plannedDocumentID: blockedID)],
            updatedAt: Date()
        ))
        let failedResult = await center.perform(.notes, for: request(for: envelope, fileNames: ["late.pdf"]))
        guard case .failed = failedResult else {
            Issue.record("expected failed while blocked, got \(failedResult)")
            return
        }
        #expect(sharePending(inbox, envelope.id))
        let heldDecision = try #require(store.load(.shareEnvelope(envelope.id)))
        #expect(heldDecision.status == .notes) // durable plan is KEPT on failure

        await library.unblock(blockedID)
        let resumed = await center.perform(.notes, for: request(for: envelope, fileNames: ["late.pdf"]))
        guard case .notesImported = resumed else {
            Issue.record("expected notesImported after unblock, got \(resumed)")
            return
        }
        let imports = await library.imports
        #expect(imports.filter { $0.plannedRootID == blockedID }.count == 1)
        // Settled: the ledger record leaves with the acknowledged envelope.
        #expect(store.load(.shareEnvelope(envelope.id)) == nil)
    }

    @Test("Canvas choice persists target before copy and releases only after")
    func canvasChoiceOrdering() async throws {
        let inbox = importTestInbox("canvas-envelope")
        let decisionRoot = importTestRoot("canvas-envelope-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let committer = FakeCommitter()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            canvas: committer
        )
        let envelope = try makeEnvelope(
            in: inbox,
            text: "caption",
            files: [("sheet.pdf", pdfBytes(12), "com.adobe.pdf")]
        )
        let target = CanvasDestinationTarget.existing(canvasID: UUID())
        let result = await center.perform(
            .canvas,
            for: request(for: envelope, fileNames: ["sheet.pdf"]),
            canvasTarget: target
        )
        guard case .canvasReady(let count) = result else {
            Issue.record("expected canvasReady, got \(result)")
            return
        }
        #expect(count == 2) // file + joined text .txt material; nothing omitted
        let operation = try #require(committer.lastOperation)
        #expect(operation.target == target)
        #expect(operation.originID == envelope.id)
        #expect(operation.units.count == 2)
        let datas = committer.payloadsAtCommit
        #expect(datas.contains { $0 == pdfBytes(12) })
        #expect(datas.contains { $0 == Data("caption".utf8) })
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        #expect(makeDecisionStore(decisionRoot).load(.shareEnvelope(envelope.id)) == nil)
    }

    @Test("A failed Canvas commit keeps the envelope pending and re-choosable")
    func canvasFailureKeepsSource() async throws {
        let inbox = importTestInbox("canvas-failure")
        let decisionRoot = importTestRoot("canvas-failure-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let committer = FakeCommitter()
        committer.failNext = true
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            canvas: committer
        )
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("no.pdf", pdfBytes(13), "com.adobe.pdf")]
        )
        let store = makeDecisionStore(decisionRoot)
        let result = await center.perform(
            .canvas,
            for: request(for: envelope, fileNames: ["no.pdf"]),
            canvasTarget: .newCanvas
        )
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(sharePending(inbox, envelope.id))
        // The failed attempt must NOT forget its durable identity: the
        // retained decision keeps the operationID, planned canvas id and
        // planned node ids so a retry can never create a second canvas or
        // duplicate nodes.
        let retained = try #require(store.load(.shareEnvelope(envelope.id)))
        #expect(retained.status == .canvas)
        #expect(retained.canvasOperationID != nil)
        #expect(retained.plannedCanvasID != nil)
        #expect(retained.units.first?.plannedNodeID != nil)
        let firstOperation = try #require(committer.lastOperation)

        committer.failNext = false
        let retry = await center.perform(
            .canvas,
            for: request(for: envelope, fileNames: ["no.pdf"]),
            canvasTarget: .newCanvas
        )
        guard case .canvasReady(let count) = retry else {
            Issue.record("expected canvasReady retry, got \(retry)")
            return
        }
        #expect(count == 1)
        let secondOperation = try #require(committer.lastOperation)
        // Same-origin retry reuses the persisted identities verbatim.
        #expect(secondOperation.operationID == firstOperation.operationID)
        #expect(secondOperation.plannedNewCanvasID == firstOperation.plannedNewCanvasID)
        #expect(secondOperation.units.map(\.plannedNodeID)
                == firstOperation.units.map(\.plannedNodeID))
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        #expect(store.load(.shareEnvelope(envelope.id)) == nil)
    }

    @Test("Existing-task merge preserves the draft through commitDurable + receipt")
    func existingTaskMerge() async throws {
        let inbox = importTestInbox("task-envelope")
        let draftRoot = importTestRoot("task-draft")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        let conversationID = UUID()
        let draftStore = ComposerDraftStore(fileURL: draftRoot.appendingPathComponent("drafts.json"))
        _ = draftStore.save(text: "human draft stays", attachments: [], conversationID: conversationID)
        let staging = FakeStaging()
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let envelope = try makeEnvelope(
            in: inbox,
            text: "shared note",
            files: [("attach.pdf", pdfBytes(14), "com.adobe.pdf")]
        )
        let destination = ConversationDraftDestination(
            conversationID: conversationID,
            draftStore: draftStore
        )
        let outcome = await share.apply(envelope, to: destination)
        switch outcome {
        case .applied: break
        default:
            Issue.record("expected applied, got \(outcome)")
            return
        }
        let entry = try #require(draftStore.entry(for: conversationID))
        #expect(entry.text.contains("human draft stays"))
        #expect(entry.text.contains("shared note"))
        #expect(entry.attachments.count == 1)
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        #expect(draftStore.unsettledHandoffReceipts.isEmpty)
    }

    @Test("A LIVE composer folds the landing in the same turn; only then the source acks")
    func existingTaskLiveFoldAcceptance() async throws {
        let inbox = importTestInbox("task-livefold")
        let decisionRoot = importTestRoot("task-livefold-decisions")
        let draftRoot = importTestRoot("task-livefold-draft")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        let conversationID = UUID()
        let draftStore = ComposerDraftStore(fileURL: draftRoot.appendingPathComponent("drafts.json"))
        _ = draftStore.save(text: "live typing", attachments: [], conversationID: conversationID)
        let owner = RecordingLiveDraftOwner()
        draftStore.registerLiveDraftOwner(owner, for: conversationID)
        #expect(draftStore.hasLiveDraftOwner(for: conversationID))
        let provider = FakeTaskProvider()
        provider.setAvailable([conversationID])
        let staging = FakeStaging()
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            taskProvider: provider,
            taskDraftStore: draftStore
        )
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-livefold-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            text: "later file text",
            files: [("later.pdf", pdfBytes(15), "com.adobe.pdf")]
        )
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["later.pdf"]),
            taskTarget: .existing(conversationID: conversationID)
        )
        #expect(result == .taskReady(target: .existing(conversationID: conversationID)))
        #expect(owner.landings.count == 1)
        let landing = try #require(owner.landings.first)
        #expect(landing.landedText.contains("live typing"))
        #expect(landing.landedText.contains("later file text"))
        #expect(landing.addedAttachments.count == 1)
        let entry = try #require(draftStore.entry(for: conversationID))
        #expect(entry.text.contains("live typing"))
        // Acked: the destination owns the landing AND the live view folded it.
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        #expect(landing.landedRevision == entry.revision)
    }

    @Test("A temporary chat is never an import destination: refusal copies nothing")
    func temporaryTargetRejected() async throws {
        let inbox = importTestInbox("task-temp")
        let decisionRoot = importTestRoot("task-temp-decisions")
        let draftRoot = importTestRoot("task-temp-draft")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        let tempID = UUID()
        let draftStore = ComposerDraftStore(fileURL: draftRoot.appendingPathComponent("drafts.json"))
        draftStore.setTemporaryDraftExcluded(tempID, true)
        let provider = FakeTaskProvider()
        provider.setAvailable([tempID]) // provider-only check still allows; the store must refuse
        let staging = FakeStaging()
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            taskProvider: provider,
            taskDraftStore: draftStore
        )
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-temp-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("nope.pdf", pdfBytes(19), "com.adobe.pdf")]
        )
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["nope.pdf"]),
            taskTarget: .existing(conversationID: tempID)
        )
        guard case .failed = result else {
            Issue.record("expected failed for a temporary target, got \(result)")
            return
        }
        #expect(draftStore.entry(for: tempID) == nil)
        #expect(staging.discarded.count == staging.stagedURLs.count) // rollback, nothing kept
        #expect(sharePending(inbox, envelope.id)) // source untouched
    }

    @Test("An unavailable target copies nothing")
    func existingTaskUnavailable() async throws {
        let inbox = importTestInbox("task-unavailable")
        let decisionRoot = importTestRoot("task-unavailable-decisions")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let provider = FakeTaskProvider() // available: none
        let staging = FakeStaging()
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            taskProvider: provider
        )
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-unavailable-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("none.pdf", pdfBytes(16), "com.adobe.pdf")]
        )
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["none.pdf"]),
            taskTarget: .existing(conversationID: UUID())
        )
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(staging.stagedURLs.isEmpty)
        #expect(sharePending(inbox, envelope.id))
    }

    @Test("Home auto-apply consumes confirmed New Task envelopes once, preserving the draft")
    func homeAutoAppliesConfirmedEnvelopes() async throws {
        let inbox = importTestInbox("task-homeauto")
        let decisionRoot = importTestRoot("task-homeauto-decisions")
        let draftRoot = importTestRoot("task-homeauto-draft")
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        let draftStore = ComposerDraftStore(fileURL: draftRoot.appendingPathComponent("drafts.json"))
        _ = draftStore.save(
            text: "existing home draft",
            attachments: [],
            conversationID: ComposerDraftStore.homeDraftID
        )
        let staging = FakeStaging()
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: makeDecisionStore(decisionRoot),
            taskProvider: FakeTaskProvider()
        )
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-homeauto-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            text: "confirmed share",
            files: [("home.pdf", pdfBytes(18), "com.adobe.pdf")]
        )
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["home.pdf"]),
            taskTarget: .newTask
        )
        #expect(result == .taskReady(target: .newTask))
        // No copy has happened yet: the marker only records the choice.
        let earlyEntry = try #require(draftStore.entry(for: ComposerDraftStore.homeDraftID))
        #expect(!earlyEntry.text.contains("confirmed share"))
        #expect(sharePending(inbox, envelope.id))

        // Home's existing intake .task runs the one-line auto-apply.
        await share.refresh()
        let home = ConversationDraftDestination(
            conversationID: ComposerDraftStore.homeDraftID,
            draftStore: draftStore
        )
        let outcome = await center.applyConfirmedNewTaskEnvelopes(to: home)
        switch outcome {
        case .applied?: break
        default:
            Issue.record("expected applied auto-consume, got \(String(describing: outcome))")
            return
        }
        let entry = try #require(draftStore.entry(for: ComposerDraftStore.homeDraftID))
        #expect(entry.text.contains("existing home draft"))
        #expect(entry.text.contains("confirmed share"))
        #expect(entry.attachments.count == 1)
        await #expect(throws: (any Error).self) { _ = try inbox.claim(id: envelope.id) }
        // Nothing left to consume on the next appearance.
        #expect(await center.applyConfirmedNewTaskEnvelopes(to: home) == nil)
    }

    @Test("Confirmed New Task advances the durable-marker signal exactly where expected")
    func confirmedNewTaskSignal() async throws {
        let inbox = importTestInbox("task-signal")
        let decisionRoot = importTestRoot("task-signal-decisions")
        let store = makeDecisionStore(decisionRoot)
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: store,
            taskProvider: FakeTaskProvider()
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: FakeStaging())
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-signal-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("signal.pdf", pdfBytes(23), "com.adobe.pdf")]
        )
        #expect(center.confirmedNewTaskRevision == 0)
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["signal.pdf"]),
            taskTarget: .newTask
        )
        #expect(result == .taskReady(target: .newTask))
        // The signal moves only AFTER the durable marker exists.
        #expect(center.confirmedNewTaskRevision == 1)
        #expect(store.load(.shareEnvelope(envelope.id))?.status == .task)
        // Notes choice over the marker re-plans durably; no task signal moves.
        let notesResult = await center.perform(
            .notes,
            for: request(for: envelope, fileNames: ["signal.pdf"])
        )
        guard case .notesImported = notesResult else {
            Issue.record("expected notes re-choice over task marker, got \(notesResult)")
            return
        }
        #expect(center.confirmedNewTaskRevision == 1)
        _ = share
    }

    @Test("New Task persists only the target marker and copies nothing itself")
    func newTaskMarker() async throws {
        let inbox = importTestInbox("task-newmarker")
        let decisionRoot = importTestRoot("task-newmarker-decisions")
        let store = makeDecisionStore(decisionRoot)
        defer {
            try? FileManager.default.removeItem(at: inbox.rootURL)
            try? FileManager.default.removeItem(at: decisionRoot)
        }
        let staging = FakeStaging()
        let center = ImportDestinationCenter(
            inbox: inbox,
            notes: FakeNotesImporter(library: ImportTestNotesLibrary()),
            store: store,
            taskProvider: FakeTaskProvider()
        )
        let share = ShareIntakeCenter(inbox: inbox, staging: staging)
        let doc = DocumentIntakeCenter(
            root: importTestRoot("task-newmarker-doc"),
            notes: FakeNotesImporter(library: ImportTestNotesLibrary())
        )
        center.start(shareCenter: share, documentCenter: doc)
        let envelope = try makeEnvelope(
            in: inbox,
            files: [("card.pdf", pdfBytes(17), "com.adobe.pdf")]
        )
        let result = await center.perform(
            .task,
            for: request(for: envelope, fileNames: ["card.pdf"]),
            taskTarget: .newTask
        )
        #expect(result == .taskReady(target: .newTask))
        let decision = try #require(store.load(.shareEnvelope(envelope.id)))
        #expect(decision.status == .task)
        #expect(decision.taskTarget == .newTask)
        // The envelope stays exactly pending for the reviewed Home card.
        #expect(sharePending(inbox, envelope.id))
        #expect(staging.stagedURLs.isEmpty)
    }
}
#endif
