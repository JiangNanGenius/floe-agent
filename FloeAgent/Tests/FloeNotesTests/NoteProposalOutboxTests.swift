// FloeNotesTests — durable decision outbox crash-consistency (Build265).
import Foundation
import Testing
@testable import FloeNotes

/// Proposal store wrapper with injectable write faults: the proposal state
/// write is one of the three writes the durability contract covers.
actor FaultyProposalStore: NoteProposalPersisting {
    let base: NoteProposalStore
    private var failNextSaves = 0
    private var failNextRemoves = 0
    private(set) var saveCount = 0

    init(base: NoteProposalStore) { self.base = base }

    func failSaves(_ count: Int = 1) { failNextSaves += count }
    func failRemoves(_ count: Int = 1) { failNextRemoves += count }

    func save(_ proposal: NoteProposal) async throws {
        saveCount += 1
        if failNextSaves > 0 {
            failNextSaves -= 1
            throw NoteError.invalidOperation("injected proposal save failure")
        }
        try await base.save(proposal)
    }
    func load(_ id: UUID) async -> NoteProposal? { await base.load(id) }
    func remove(_ id: UUID) async throws {
        if failNextRemoves > 0 {
            failNextRemoves -= 1
            throw NoteError.invalidOperation("injected proposal remove failure")
        }
        try await base.remove(id)
    }
    func pending(documentID: UUID) async -> [NoteProposal] { await base.pending(documentID: documentID) }
    func all() async -> [NoteProposal] { await base.all() }
}

/// Intent outbox wrapper with injectable faults on its own writes (intent save
/// and the delivered mark).
actor FaultyIntentStore: NoteProposalIntentPersisting {
    let base: NoteProposalOutbox
    private var failNextSaves = 0
    private var failNextMarks = 0
    private(set) var saveCount = 0

    init(base: NoteProposalOutbox) { self.base = base }

    func failSaves(_ count: Int = 1) { failNextSaves += count }
    func failMarks(_ count: Int = 1) { failNextMarks += count }

    func save(_ intent: NoteProposalDecisionIntent) async throws {
        saveCount += 1
        if failNextSaves > 0 {
            failNextSaves -= 1
            throw NoteError.invalidOperation("injected intent save failure")
        }
        try await base.save(intent)
    }
    func load(_ id: UUID) async -> NoteProposalDecisionIntent? { await base.load(id) }
    func pendingDecisions() async -> [NoteProposalDecisionIntent] { await base.pendingDecisions() }
    func claim(_ id: UUID, at date: Date) async -> Bool { await base.claim(id, at: date) }
    func markDelivered(_ id: UUID, at date: Date) async throws {
        if failNextMarks > 0 {
            failNextMarks -= 1
            throw NoteError.invalidOperation("injected delivered-mark failure")
        }
        try await base.markDelivered(id, at: date)
    }
    func recordFailure(_ id: UUID, reason: String) async throws { try await base.recordFailure(id, reason: reason) }
    func remove(_ id: UUID) async throws { try await base.remove(id) }
}

/// Models the two runtime writes behind delivery with injectable failures
/// before the enqueue, after the enqueue, before the append and after both.
final class RecordingDecisionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var inputContents: [UUID: String] = [:]
    private var messageContents: [UUID: String] = [:]
    private var conversations: [UUID: UUID] = [:]
    private(set) var enqueueAttempts = 0

    var failEnqueueBeforeWrite = false
    var failAppendBeforeWrite = false
    var crashAfterEnqueue = false
    var crashAfterAppend = false

    func hasInput(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inputContents[id] != nil
    }

    func enqueue(_ event: NoteProposalDecisionEvent) throws {
        lock.lock(); defer { lock.unlock() }
        enqueueAttempts += 1
        if failEnqueueBeforeWrite { throw NoteError.invalidOperation("injected enqueue failure") }
        inputContents[event.id] = event.content
        conversations[event.id] = event.conversationID
        if crashAfterEnqueue { throw NoteError.invalidOperation("simulated crash after enqueue") }
    }

    func append(_ event: NoteProposalDecisionEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if failAppendBeforeWrite { throw NoteError.invalidOperation("injected append failure") }
        messageContents[event.id] = event.content
        if crashAfterAppend { throw NoteError.invalidOperation("simulated crash after append") }
    }

    var inputs: [UUID: String] { lock.lock(); defer { lock.unlock() }; return inputContents }
    var messages: [UUID: String] { lock.lock(); defer { lock.unlock() }; return messageContents }
    var deliveredConversations: [UUID: UUID] { lock.lock(); defer { lock.unlock() }; return conversations }
}

struct RecordingTransport: NoteProposalDecisionTransport {
    let sink: RecordingDecisionSink
    func deliver(_ event: NoteProposalDecisionEvent) async throws {
        if !sink.hasInput(event.id) { try sink.enqueue(event) }
        try sink.append(event)
    }
}

/// Holds delivery after the first runtime write until released, so a concurrent
/// flush can race against an in-flight claim deterministically.
actor DeliveryGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

struct GatedTransport: NoteProposalDecisionTransport {
    let sink: RecordingDecisionSink
    let gate: DeliveryGate
    func deliver(_ event: NoteProposalDecisionEvent) async throws {
        if !sink.hasInput(event.id) { try sink.enqueue(event) }
        await gate.wait()
        try sink.append(event)
    }
}

@Suite("Notes proposal decision outbox", .serialized)
struct NoteProposalOutboxTests {
    private struct Harness {
        let root: URL
        let proposals: FaultyProposalStore
        let outbox: FaultyIntentStore
        let sink: RecordingDecisionSink
        let transport: RecordingTransport

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-outbox-\(UUID().uuidString)")
            proposals = FaultyProposalStore(base: NoteProposalStore(
                root: root.appendingPathComponent("Proposals", isDirectory: true)))
            outbox = FaultyIntentStore(base: NoteProposalOutbox(
                root: root.appendingPathComponent("Outbox", isDirectory: true)))
            sink = RecordingDecisionSink()
            transport = RecordingTransport(sink: sink)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func originProposal(_ origin: NoteProposalOrigin,
                                documentID: UUID = UUID()) -> NoteProposal {
        NoteProposal(documentID: documentID, baseRevision: 1,
                     baseSHA256: String(repeating: "a", count: 64), title: "提案",
                     origin: origin, edits: [.rename("新")], summary: "SECRET-MODEL-TEXT")
    }

    @Test("intent write failure before the state change leaves everything retryable")
    func intentWriteFailureBeforeStateChange() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)

        await harness.outbox.failSaves(1)
        await expectError {
            _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                      proposals: harness.proposals, outbox: harness.outbox)
        }
        var stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.isPending, "a failed intent write must not resolve the proposal")
        #expect(await harness.outbox.pendingDecisions().isEmpty)

        // Retry succeeds; the proposal is resolved before delivery, and the
        // delivered file is pruned afterwards.
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.resolvedDecision == .rejected)
        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        #expect(await harness.proposals.load(proposal.id) == nil, "a delivered rejection is pruned")
        #expect(harness.sink.inputs.count == 1)
        #expect(harness.sink.messages.count == 1)
        #expect(harness.sink.deliveredConversations.values.first == origin.conversationID)
    }

    @Test("crash after the durable intent but before the proposal state write is repaired")
    func proposalStateWriteFailureAfterIntent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)

        await harness.proposals.failSaves(1)
        await expectError {
            _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .invalidated,
                                                      proposals: harness.proposals, outbox: harness.outbox)
        }
        let pendingIntents = await harness.outbox.pendingDecisions()
        #expect(pendingIntents.count == 1, "the intent must survive the state-write failure")
        var stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.isPending)

        // Keep the file after delivery so the repaired state can be inspected.
        await harness.proposals.failRemoves(1)
        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.resolvedDecision == .invalidated, "recovery repairs the proposal state")
        #expect(harness.sink.inputs.count == 1)
        #expect(harness.sink.messages.count == 1)
    }

    @Test("crashed acceptance before the commit is re-applied from the durable intent")
    func acceptanceCrashBeforeCommit() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        var document = try await store.create(NoteDocument(title: "提案文档"))
        document.pages[0].elements = [NoteElement(frame: .init(x: 20, y: 20, width: 300, height: 80), text: "旧内容")]
        document = try await store.document(document.id)
        let proposal = try await NoteProposalService.propose(
            document: document, title: "接受", edits: [.rename("已接受")], origin: origin, store: harness.proposals)
        // Simulate the crash right after the WAL intent was written.
        let committing = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        try await harness.outbox.save(committing)
        try await store.grantAccess(conversationID: origin.conversationID, documentID: document.id, canEdit: true)

        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.delivered.count == 1)
        #expect(report.repaired.count == 1)
        let applied = try await store.document(document.id)
        #expect(applied.title == "已接受")
        let stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.appliedRevision == applied.revision)
        let delivered = try #require(harness.sink.inputs.keys.first)
        #expect(harness.sink.deliveredConversations[delivered] == origin.conversationID)
        let intent = try #require(await harness.outbox.load(committing.id))
        #expect(intent.isDelivered)
        #expect(intent.revision == applied.revision)
    }

    @Test("crash between the commit and the intent finalization uses the receipt, not a second apply")
    func acceptanceCrashAfterCommit() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        var document = try await store.create(NoteDocument(title: "提案文档"))
        document = try await store.document(document.id)
        let proposal = try await NoteProposalService.propose(
            document: document, title: "接受", edits: [.rename("已接受")], origin: origin, store: harness.proposals)
        let committing = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        try await harness.outbox.save(committing)

        // The document commit happened, then the process died before finalizing.
        let requestID = NoteProposalService.applyRequestID(proposalID: proposal.id)
        _ = try await store.apply(NoteEditBatch(documentID: document.id, expectedRevision: document.revision,
                                                title: proposal.title, edits: proposal.edits, requestID: requestID))
        let afterCommit = try await store.document(document.id)

        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.delivered.count == 1)
        let final = try await store.document(document.id)
        #expect(final.revision == afterCommit.revision, "recovery must not apply the batch twice")
        let stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.appliedRevision == afterCommit.revision)
        #expect(harness.sink.inputs.count == 1)
    }

    @Test("a stale crashed acceptance converts into a durable invalidation")
    func staleAcceptanceConvertsToInvalidation() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        var document = try await store.create(NoteDocument(title: "提案文档"))
        document = try await store.document(document.id)
        let proposal = try await NoteProposalService.propose(
            document: document, title: "接受", edits: [.rename("已接受")], origin: origin, store: harness.proposals)
        let committing = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        try await harness.outbox.save(committing)
        try await store.grantAccess(conversationID: origin.conversationID, documentID: document.id, canEdit: true)
        // The document moves on while the acceptance is uncommitted.
        _ = try await store.apply(NoteEditBatch(documentID: document.id, expectedRevision: document.revision,
                                                title: "外部修改", edits: [.rename("外部修改")]))
        // Keep the resolved file after delivery so the state can be inspected.
        await harness.proposals.failRemoves(1)

        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.invalidated.count == 1)
        #expect(report.delivered == [report.invalidated[0]])
        let final = try await store.document(document.id)
        #expect(final.title == "外部修改", "a stale acceptance must never be applied")
        let stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.resolvedDecision == .invalidated)
        let remaining = await harness.outbox.pendingDecisions()
        #expect(remaining.isEmpty)
        #expect(harness.sink.inputs.count == 1)
    }

    @Test("enqueue failure leaves the intent pending and retries to exactly one delivery")
    func enqueueFailureKeepsPending() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        harness.sink.failEnqueueBeforeWrite = true

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.isEmpty)
        #expect(report.failures.count == 1)
        #expect((await harness.outbox.pendingDecisions()).count == 1)
        #expect(harness.sink.inputs.isEmpty && harness.sink.messages.isEmpty)

        harness.sink.failEnqueueBeforeWrite = false
        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        #expect(harness.sink.inputs.count == 1)
        #expect(harness.sink.messages.count == 1)
        #expect(harness.sink.deliveredConversations.values.first == origin.conversationID)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
        #expect(harness.sink.enqueueAttempts == 2)
    }

    @Test("append failure before the append write keeps the intent pending and never duplicates")
    func appendFailureBeforeAppendWrite() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        harness.sink.failAppendBeforeWrite = true

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.isEmpty)
        #expect(harness.sink.inputs.count == 1, "the enqueue succeeded before the append failed")
        #expect(harness.sink.messages.isEmpty, "the append write must not have happened")
        #expect((await harness.outbox.pendingDecisions()).count == 1)

        harness.sink.failAppendBeforeWrite = false
        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        #expect(harness.sink.inputs.count == 1)
        #expect(harness.sink.messages.count == 1)
        #expect(harness.sink.deliveredConversations.values.first == origin.conversationID)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
    }

    @Test("append failure after the enqueue keeps the intent pending and never duplicates")
    func appendFailureAfterEnqueue() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        harness.sink.crashAfterEnqueue = true

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.isEmpty)
        #expect(harness.sink.inputs.count == 1, "the enqueue already happened")
        #expect(harness.sink.messages.isEmpty)
        #expect((await harness.outbox.pendingDecisions()).count == 1,
                "a partial delivery must never be marked delivered")

        harness.sink.crashAfterEnqueue = false
        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        #expect(harness.sink.inputs.count == 1, "the retry must reuse the existing input row")
        #expect(harness.sink.messages.count == 1)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
    }

    @Test("delivered-mark failure after both writes replays without duplicating")
    func deliveredMarkFailureAfterBothWrites() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        await harness.outbox.failMarks(1)

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.isEmpty)
        #expect(harness.sink.inputs.count == 1 && harness.sink.messages.count == 1)
        #expect((await harness.outbox.pendingDecisions()).count == 1)

        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(report.delivered.count == 1)
        #expect(harness.sink.inputs.count == 1, "replay must not duplicate the durable input")
        #expect(harness.sink.messages.count == 1)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
    }

    @Test("restart reconstruction delivers pending intents from disk exactly once")
    func restartReconstruction() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        // One rejected proposal and one crashed acceptance survive the restart.
        let rejectedDocument = try await store.create(NoteDocument(title: "拒绝"))
        let rejectedProposal = try await NoteProposalService.propose(
            document: rejectedDocument, title: "拒绝", edits: [.rename("不应用")], origin: origin, store: harness.proposals)
        _ = try await NoteProposalService.resolve(proposalID: rejectedProposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        let rejectedIntent = try #require(await harness.outbox.pendingDecisions().first)

        let acceptedDocument = try await store.create(NoteDocument(title: "接受"))
        let acceptedProposal = try await NoteProposalService.propose(
            document: acceptedDocument, title: "重启接受", edits: [.rename("重启后应用")], origin: origin, store: harness.proposals)
        let acceptance = NoteProposalDecisionIntent(proposal: acceptedProposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        try await harness.outbox.save(acceptance)
        try await store.grantAccess(conversationID: origin.conversationID,
                                    documentID: acceptedDocument.id, canEdit: true)

        // "Restart": brand-new store/outbox/sink/transport instances over the
        // same durable directories, with no in-memory state.
        let reopenedProposals = FaultyProposalStore(base: NoteProposalStore(
            root: harness.root.appendingPathComponent("Proposals", isDirectory: true)))
        let reopenedOutbox = FaultyIntentStore(base: NoteProposalOutbox(
            root: harness.root.appendingPathComponent("Outbox", isDirectory: true)))
        let reopenedSink = RecordingDecisionSink()
        let reopenedTransport = RecordingTransport(sink: reopenedSink)
        #expect((await reopenedOutbox.pendingDecisions()).count == 2, "both intents survived the restart")

        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: reopenedTransport, outbox: reopenedOutbox, proposals: reopenedProposals, store: store)
        #expect(report.delivered.count == 2)
        #expect(Set(reopenedSink.inputs.keys) == Set([rejectedIntent.id, acceptance.id]))
        #expect(reopenedSink.inputs.count == 2)
        #expect(reopenedSink.messages.count == 2)
        #expect(reopenedSink.deliveredConversations.values.allSatisfy { $0 == origin.conversationID })
        let rejectedAfter = try await store.document(rejectedDocument.id)
        #expect(rejectedAfter.title == "拒绝", "the rejected proposal must not be applied")
        let acceptedAfter = try await store.document(acceptedDocument.id)
        #expect(acceptedAfter.title == "重启后应用")
        #expect((await reopenedOutbox.pendingDecisions()).isEmpty)
    }

    @Test("a UI-authored proposal with no origin notifies nobody")
    func uiAuthoredProposalNotifiesNobody() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let proposal = NoteProposal(documentID: UUID(), baseRevision: 1,
                                    baseSHA256: String(repeating: "b", count: 64), title: "UI",
                                    edits: [.rename("x")], summary: "s")
        try await harness.proposals.save(proposal)
        #expect(NoteProposalDecisions.event(for: proposal, decision: .rejected) == nil)

        let resolved = try #require(await NoteProposalService.resolve(
            proposalID: proposal.id, decision: .rejected,
            proposals: harness.proposals, outbox: harness.outbox))
        #expect(resolved.isResolved)
        #expect(await harness.outbox.pendingDecisions().isEmpty, "no intent for an origin-less proposal")
        _ = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals)
        #expect(harness.sink.inputs.isEmpty && harness.sink.messages.isEmpty)
    }

    @Test("recovery agrees with the intent's exact custom commit operation id")
    func customOperationIDRecovery() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")

        // Committed under a custom id, crash before finalize: recovery must find
        // the receipt under that exact id, not the stable default.
        let committedDocument = try await store.create(NoteDocument(title: "已提交"))
        let committedProposal = try await NoteProposalService.propose(
            document: committedDocument, title: "自定义", edits: [.rename("自定义后")],
            origin: origin, store: harness.proposals)
        let customCommitted = "caller-op-committed"
        let committingA = NoteProposalDecisionIntent(proposal: committedProposal, decision: .accepted,
                                                     revision: nil, phase: .committing,
                                                     operationID: customCommitted)
        try await harness.outbox.save(committingA)
        _ = try await store.apply(NoteEditBatch(documentID: committedDocument.id,
                                                expectedRevision: committedProposal.baseRevision,
                                                title: committedProposal.title, edits: committedProposal.edits,
                                                requestID: customCommitted))
        let afterCommit = try await store.document(committedDocument.id)

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.delivered.count == 1)
        #expect(report.repaired.count == 1)
        let finalCommitted = try await store.document(committedDocument.id)
        #expect(finalCommitted.revision == afterCommit.revision, "the custom-id receipt must prevent a second apply")
        let intentA = try #require(await harness.outbox.load(committingA.id))
        #expect(intentA.operationID == customCommitted)
        #expect(intentA.isDelivered)

        // Uncommitted custom-id acceptance: recovery re-applies under the SAME
        // id, so the receipt exists under the custom key afterwards.
        let pendingDocument = try await store.create(NoteDocument(title: "未提交"))
        let pendingProposal = try await NoteProposalService.propose(
            document: pendingDocument, title: "自定义重放", edits: [.rename("重放后")],
            origin: origin, store: harness.proposals)
        try await store.grantAccess(conversationID: origin.conversationID,
                                    documentID: pendingDocument.id, canEdit: true)
        let customUncommitted = "caller-op-uncommitted"
        let committingB = NoteProposalDecisionIntent(proposal: pendingProposal, decision: .accepted,
                                                     revision: nil, phase: .committing,
                                                     operationID: customUncommitted)
        try await harness.outbox.save(committingB)

        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.delivered.count == 1)
        let replayed = try await store.editReceipt(requestID: customUncommitted, documentID: pendingDocument.id)
        #expect(replayed != nil, "the recovered re-apply must commit under the intent's operation id")
        let appliedPending = try await store.document(pendingDocument.id)
        #expect(appliedPending.title == "重放后")
    }

    @Test("resolved proposals refuse new applies before grant reservation but allow the committed replay")
    func resolvedRefusalWithReplayAllowance() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")

        // Committed, then resolved afterwards: the same operation id replays.
        let document = try await store.create(NoteDocument(title: "已应用"))
        let proposal = try await NoteProposalService.propose(
            document: document, title: "应用", edits: [.rename("已应用后")], origin: origin, store: harness.proposals)
        let grants = NoteProposalGrantStore(idProvider: { "grant-1" })
        let grantID = await grants.issueGrant(proposal: proposal)
        _ = try await NoteProposalService.apply(proposalID: proposal.id, grantID: grantID, store: store,
                                                proposals: harness.proposals, outbox: harness.outbox, grants: grants)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        let beforeReplay = try await store.document(document.id)
        let replayed = try await NoteProposalService.apply(proposalID: proposal.id, grantID: "irrelevant",
                                                           store: store, proposals: harness.proposals,
                                                           outbox: harness.outbox, grants: grants)
        #expect(replayed.revision == beforeReplay.revision, "genuine committed replay returns the receipt")

        // Applied under one operation id but replayed with another: refused.
        await expectError {
            _ = try await NoteProposalService.apply(proposalID: proposal.id, grantID: "irrelevant",
                                                    requestID: "different-operation",
                                                    store: store, proposals: harness.proposals,
                                                    outbox: harness.outbox, grants: grants)
        }

        // Resolved without ever applying: refused BEFORE the grant is reserved.
        let neverApplied = try await store.create(NoteDocument(title: "未应用"))
        let resolvedProposal = try await NoteProposalService.propose(
            document: neverApplied, title: "拒绝", edits: [.rename("x")], origin: origin, store: harness.proposals)
        _ = try await NoteProposalService.resolve(proposalID: resolvedProposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        let freshGrants = NoteProposalGrantStore(idProvider: { "fresh-grant" })
        let freshGrant = await freshGrants.issueGrant(proposal: resolvedProposal)
        await expectError {
            _ = try await NoteProposalService.apply(proposalID: resolvedProposal.id, grantID: freshGrant,
                                                    store: store, proposals: harness.proposals,
                                                    outbox: harness.outbox, grants: freshGrants)
        }
        let untouched = try await store.document(neverApplied.id)
        #expect(untouched.revision == neverApplied.revision)
        let reservation = await freshGrants.reserve(grantID: freshGrant, proposalID: resolvedProposal.id,
                                                    documentID: neverApplied.id, revision: resolvedProposal.baseRevision,
                                                    sha256: resolvedProposal.baseSHA256)
        #expect(reservation == .reserved, "refusal must happen before the grant is touched")
    }

    @Test("recovered acceptance revalidates the origin editing grant and refuses mutation")
    func recoveryRevalidatesOriginAuthorization() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let document = try await store.create(NoteDocument(title: "无权限"))
        let proposal = try await NoteProposalService.propose(
            document: document, title: "接受", edits: [.rename("不应应用")], origin: origin, store: harness.proposals)
        // Read-only grant: the normal path would refuse to edit; recovery must too.
        try await store.grantAccess(conversationID: origin.conversationID,
                                    documentID: document.id, canEdit: false)
        let committing = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        try await harness.outbox.save(committing)
        // Keep the resolved file after delivery so the repaired state is inspectable.
        await harness.proposals.failRemoves(1)

        let report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.invalidated.count == 1)
        #expect(report.delivered == [report.invalidated[0]])
        let final = try await store.document(document.id)
        #expect(final.title == "无权限", "a recovered mutation must revalidate origin authorization")
        let stored = try #require(await harness.proposals.load(proposal.id))
        #expect(stored.resolvedDecision == .invalidated)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
        #expect(harness.sink.inputs.count == 1)
    }

    @Test("a crash between the terminal outcome and the supersede never replays the failed acceptance")
    func crashBetweenInvalidationAndSupersede() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = try NotesStore(root: harness.root.appendingPathComponent("Library", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let document = try await store.create(NoteDocument(title: "失败"))
        let proposal = try await NoteProposalService.propose(
            document: document, title: "接受", edits: [.rename("不应应用")], origin: origin, store: harness.proposals)
        try await store.grantAccess(conversationID: origin.conversationID, documentID: document.id, canEdit: true)

        // Crash window A: terminal intent written + proposal resolved, the old
        // committing intent not yet superseded.
        let committing = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                    revision: nil, phase: .committing)
        let terminal = NoteProposalDecisionIntent(proposal: proposal, decision: .invalidated,
                                                  revision: nil, phase: .recorded)
        try await harness.outbox.save(committing)
        try await harness.outbox.save(terminal)
        var resolved = proposal
        resolved.resolvedDecision = .invalidated
        resolved.resolvedAt = Date()
        try await harness.proposals.save(resolved)

        var report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harness.transport, outbox: harness.outbox, proposals: harness.proposals, store: store)
        #expect(report.delivered == [terminal.id])
        let final = try await store.document(document.id)
        #expect(final.title == "失败", "a superseded acceptance must never be replayed")
        let gone = await harness.outbox.load(committing.id)
        #expect(gone == nil, "the committing intent is superseded")
        #expect(harness.sink.inputs.count == 1)

        // Crash window B: terminal intent written but the proposal state write
        // failed, so the proposal still looks pending.
        let harnessB = try Harness()
        defer { harnessB.cleanup() }
        let storeB = try NotesStore(root: harnessB.root.appendingPathComponent("Library", isDirectory: true))
        let documentB = try await storeB.create(NoteDocument(title: "失败B"))
        let proposalB = try await NoteProposalService.propose(
            document: documentB, title: "接受B", edits: [.rename("不应应用B")], origin: origin, store: harnessB.proposals)
        try await storeB.grantAccess(conversationID: origin.conversationID, documentID: documentB.id, canEdit: true)
        let committingB = NoteProposalDecisionIntent(proposal: proposalB, decision: .accepted,
                                                     revision: nil, phase: .committing)
        let terminalB = NoteProposalDecisionIntent(proposal: proposalB, decision: .invalidated,
                                                   revision: nil, phase: .recorded)
        try await harnessB.outbox.save(committingB)
        try await harnessB.outbox.save(terminalB)
        // Keep the resolved file after delivery so the repaired state is inspectable.
        await harnessB.proposals.failRemoves(1)

        report = await NoteProposalDecisionDelivery.deliverPending(
            transport: harnessB.transport, outbox: harnessB.outbox, proposals: harnessB.proposals, store: storeB)
        #expect(report.delivered == [terminalB.id])
        let finalB = try await storeB.document(documentB.id)
        #expect(finalB.title == "失败B")
        let storedB = try #require(await harnessB.proposals.load(proposalB.id))
        #expect(storedB.resolvedDecision == .invalidated, "recovery repairs the missing resolution state")
        #expect((await harnessB.outbox.pendingDecisions()).isEmpty)
    }

    @Test("two concurrent flushes deliver exactly once through the outbox claim")
    func concurrentFlushIsIdempotent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = originProposal(origin)
        try await harness.proposals.save(proposal)
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: harness.proposals, outbox: harness.outbox)
        let gate = DeliveryGate()
        let gated = GatedTransport(sink: harness.sink, gate: gate)

        let first = Task {
            await NoteProposalDecisionDelivery.deliverPending(
                transport: gated, outbox: harness.outbox, proposals: harness.proposals)
        }
        // Wait until the first deliverer holds the claim and completed the
        // first runtime write.
        let pendingID = try #require(await harness.outbox.pendingDecisions().first?.id)
        var spins = 0
        while !harness.sink.hasInput(pendingID) && spins < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(harness.sink.hasInput(pendingID), "the first deliverer must be in flight")

        let second = Task {
            await NoteProposalDecisionDelivery.deliverPending(
                transport: gated, outbox: harness.outbox, proposals: harness.proposals)
        }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.release()
        let firstReport = await first.value
        let secondReport = await second.value

        #expect(firstReport.delivered.count + secondReport.delivered.count == 1,
                "exactly one flush owns the delivery")
        #expect(harness.sink.enqueueAttempts == 1, "the claim prevents a duplicate enqueue attempt")
        #expect(harness.sink.inputs.count == 1)
        #expect(harness.sink.messages.count == 1)
        #expect((await harness.outbox.pendingDecisions()).isEmpty)
    }

    private func expectError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected an error")
        } catch {}
    }
}
