// FloeAppTests — external import into an ALREADY OPEN task composer
// (job-86b3d2fc live/durable draft synchronization).
//
// Coverage of the bounded contract in ComposerDraftStore /
// ThreadDetailViewModel / ThreadComposerView:
// * one proven durable landing publishes its exact delta (stable receipt +
//   item ids) and synchronously renders into every live owner of exactly
//   that conversation before any source acknowledgment can run
// * the user's next edit (typing or an attachment change) rebases onto the
//   durable entry and can never drop landed imported refs
// * a landing this slot has not absorbed folds exactly once; a second
//   rebased save re-appends nothing (no text-containment guessing)
// * fences: another conversation, a reconstructed editor that already
//   restored the durable revision, and a temporary chat never absorb or
//   receive a durable import
// * a mid-send slot is a normal busy deferral, not a user error; the retry
//   after the send settles lands
// * a failed durable write publishes nothing, rolls its own placement back,
//   leaves no disk-proven receipt, and stays retryable with a fresh claim
//   token; a landed-but-unacked receipt recovers from disk after restart
// * post-ack durability (job-cf9806bee): a human edit interleaved during
//   the durable IO forces a SECOND, disk-VERIFIED reconciled placement —
//   while that second serial write is held the call reports nothing and no
//   source ack is possible; after it completes, a store reconstructed from
//   disk immediately proves human content + imported delta exactly once +
//   the receipt; a failing or cancelled reconciliation publishes nothing,
//   keeps the envelope pending, and never leaves a false durable receipt
//   (the content-aware disk proof refuses an ack whose durable snapshot lost
//   the import)
// * two live instances both absorb once
// * ThreadDetailViewModel registers as the live owner, absorbs the landing
//   into the visible draft, and refreshDraftFromDurableStore closes the
//   same-conversation navigation gap without clobbering newer live text
//
// Synthetic content only: nothing is sent, run, or acknowledged to a real
// provider; filesystem work uses unique temporary roots (except the
// explicitly shared store used for the real view-model wiring).

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeModels
@testable import FloeApp

// MARK: - Helpers

private enum ImportDraftTestFailure: Error { case writeBarrierTimedOut }

private func syncTempDraftURL(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("import-draft-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("drafts.json")
}

private func syncAttachment(_ name: String) -> AttachmentRef {
    AttachmentRef(kind: .document, displayName: name, uti: "public.data")
}

private func syncReceipt(
    for conversationID: UUID,
    entryID: UUID = UUID(),
    claimToken: String = "claim-a"
) -> ComposerDraftStore.ShortcutHandoffReceipt {
    ComposerDraftStore.ShortcutHandoffReceipt(
        destinationID: conversationID.uuidString.lowercased(),
        entryID: entryID,
        claimToken: claimToken
    )
}

/// Mirrors the production live-owner behavior (the same pure fold and the
/// same absorption marking) so the store-side contract can be exercised
/// without a full App fixture.
@MainActor
private final class FakeLiveComposer: ComposerDraftStore.ImportedDraftLiveAccepting {
    let conversationID: UUID
    weak var store: ComposerDraftStore?
    var text: String
    var attachments: [AttachmentRef]
    var adoptedRevision: Int?
    private(set) var acceptedLandings: [ComposerDraftStore.ImportedDraftLanding] = []

    init(
        conversationID: UUID,
        store: ComposerDraftStore,
        text: String = "",
        attachments: [AttachmentRef] = [],
        adoptCurrentRevision: Bool = true
    ) {
        self.conversationID = conversationID
        self.store = store
        self.text = text
        self.attachments = attachments
        if adoptCurrentRevision {
            self.adoptedRevision = store.entry(for: conversationID)?.revision
        }
        store.registerLiveDraftOwner(self, for: conversationID)
    }

    func acceptImportedDraftLanding(_ landing: ComposerDraftStore.ImportedDraftLanding) {
        guard landing.conversationID == conversationID,
              let fold = ImportedDraftLiveFold.fold(
                  landing,
                  intoText: text,
                  attachments: attachments,
                  adoptedRevision: adoptedRevision
              ) else { return }
        adoptedRevision = landing.landedRevision
        acceptedLandings.append(landing)
        store?.markImportLandingAbsorbed(landing.landingID)
        text = fold.text
        attachments = fold.attachments
    }

    /// Simulates the composer's next keystroke: CAS against the revision
    /// this view last wrote, landing-safe rebase on rejection (exactly the
    /// ThreadComposerView fallback shape).
    @discardableResult
    func simulateKeystroke(_ newText: String) -> Int? {
        text = newText
        let stored = store?.entry(for: conversationID)
        if let revision = store?.save(
            text: newText, attachments: attachments,
            conversationID: conversationID, expectedRevision: adoptedRevision
        ) {
            adoptedRevision = revision
            return revision
        }
        let rebased = store?.liveRebasedDraft(
            text: newText, attachments: attachments,
            conversationID: conversationID, knownRevision: adoptedRevision
        )
        guard let rebased else { return nil }
        adoptedRevision = store?.save(
            text: rebased.text, attachments: rebased.attachments,
            conversationID: conversationID
        )
        attachments = rebased.attachments
        if rebased.text != newText { text = rebased.text }
        return adoptedRevision
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Serial-queue test barrier with a deterministic suspension lifecycle.
/// Current libdispatch aborts the process (`_dispatch_lane_resume` trap)
/// when a queue is resumed more times than it was suspended, and these
/// fixtures legitimately need TWO release sites — the happy path that lets
/// the held-back write complete and the scope-exit safety net that keeps an
/// early throw from leaving the queue parked forever — so the fixture grants
/// exactly one resume credit: the first `release()` performs the single
/// matching `resume()`, every later call is a no-op, and the scope-exit
/// cleanup always still runs.
private final class ImportDraftBarrier {
    let queue: DispatchQueue
    private var holdsSuspension = false

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    /// Park the queue so work enqueued afterwards cannot start.
    func park() {
        precondition(!holdsSuspension, "import barrier parked twice without a release")
        queue.suspend()
        holdsSuspension = true
    }

    /// Consume the one suspension credit: resumes the parked queue at most
    /// once. A second call never over-resumes it.
    func release() {
        guard holdsSuspension else { return }
        holdsSuspension = false
        queue.resume()
    }
}

@Suite("FloeApp.ImportDraftSynchronization")
@MainActor
struct ImportDraftSynchronizationTests {

    // MARK: - Store contract: open live composer

    @Test("A proven landing renders into the open composer and survives the next edit")
    func landingRendersThenNextEditKeepsIt() async throws {
        let url = syncTempDraftURL("render")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human draft", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human draft", attachments: [human]
        )
        let pdf = syncAttachment("shared.pdf")
        let receipt = syncReceipt(for: conversationID)
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let result = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "shared note",
            incomingAttachments: [pdf],
            receipt: receipt
        )
        guard case .landed = result else {
            Issue.record("expected .landed, got \(result)")
            return
        }
        // The visible live editor absorbed the exact delta in the landing turn.
        #expect(owner.acceptedLandings.count == 1)
        #expect(owner.text.contains("human draft"))
        #expect(owner.text.contains("shared note"))
        #expect(owner.attachments.map(\.id) == [human.id, pdf.id])
        // The durable slot proves the same bytes and carries the receipt.
        let entry = try #require(store.entry(for: conversationID))
        #expect(entry.attachments.count == 2)
        #expect(store.handoffReceiptOnDisk(receipt))
        // The next edit cannot drop what landed: a real keystroke carries the
        // field's current content (imported text included), and the rebase
        // unions durable refs, so the landed import survives verbatim.
        owner.simulateKeystroke(owner.text + " typed on")
        #expect(occurrences(of: "shared note", in: owner.text) == 1)
        let afterEdit = try #require(store.entry(for: conversationID))
        #expect(afterEdit.text.contains("typed on"))
        #expect(afterEdit.text.contains("shared note"))
        #expect(afterEdit.attachments.map(\.id) == [human.id, pdf.id])
        #expect(afterEdit.revision > baseRevision)
    }

    @Test("A rebased save folds an unabsorbed landing exactly once, never twice")
    func rebasedSaveFoldsUnabsorbedLandingOnce() async throws {
        let url = syncTempDraftURL("fold")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        let baseRevision = try #require(
            store.save(text: "base", attachments: [], conversationID: conversationID)
        )
        // No live owner: the landing is published but nobody absorbed it yet.
        let receipt = syncReceipt(for: conversationID)
        let doc = syncAttachment("file.bin")
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let result = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "imported text",
            incomingAttachments: [doc],
            receipt: receipt
        )
        guard case .landed = result else {
            Issue.record("expected .landed, got \(result)")
            return
        }
        let landing = try #require(store.latestImportedDraftLanding)
        #expect(!store.isImportLandingAbsorbed(landing.landingID))
        // A stale view (still on the base revision) rebases: exact delta
        // folds in, landed refs are kept.
        let first = store.liveRebasedDraft(
            text: "base edited", attachments: [],
            conversationID: conversationID, knownRevision: baseRevision
        )
        #expect(first.text == "base edited\n\nimported text")
        #expect(first.attachments.map(\.id) == [doc.id])
        #expect(store.isImportLandingAbsorbed(landing.landingID))
        // The very next stale rebase must NOT append the same delta again.
        let second = store.liveRebasedDraft(
            text: "base edited twice", attachments: [],
            conversationID: conversationID, knownRevision: baseRevision
        )
        #expect(occurrences(of: "imported text", in: second.text) == 0)
        #expect(second.attachments.map(\.id) == [doc.id])
    }

    @Test("Two live instances of the same task each absorb the landing once")
    func twoLiveInstancesBothAbsorb() async throws {
        let url = syncTempDraftURL("two-instances")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        _ = store.save(text: "shared base", attachments: [], conversationID: conversationID)
        let first = FakeLiveComposer(
            conversationID: conversationID, store: store, text: "shared base", attachments: []
        )
        let second = FakeLiveComposer(
            conversationID: conversationID, store: store, text: "shared base", attachments: []
        )
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-two")
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let result = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "arrived",
            incomingAttachments: [syncAttachment("a.bin")],
            receipt: receipt
        )
        guard case .landed = result else {
            Issue.record("expected .landed, got \(result)")
            return
        }
        #expect(first.acceptedLandings.count == 1)
        #expect(second.acceptedLandings.count == 1)
        #expect(occurrences(of: "arrived", in: first.text) == 1)
        #expect(occurrences(of: "arrived", in: second.text) == 1)
        // A stale view of the same conversation that already adopted the
        // landing revision refuses to fold a replayed copy.
        #expect(ImportedDraftLiveFold.fold(
            try #require(store.latestImportedDraftLanding),
            intoText: first.text, attachments: first.attachments,
            adoptedRevision: first.adoptedRevision
        ) == nil)
    }

    // MARK: - Fences

    @Test("A landing for another conversation never touches this owner")
    func wrongOwnerFence() async throws {
        let url = syncTempDraftURL("wrong-owner")
        let store = ComposerDraftStore(fileURL: url)
        let targetID = UUID()
        let otherID = UUID()
        _ = store.save(text: "other draft", attachments: [], conversationID: otherID)
        let owner = FakeLiveComposer(
            conversationID: otherID, store: store, text: "other draft", attachments: []
        )
        let receipt = syncReceipt(for: targetID)
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let result = await store.acceptImportedDraft(
            conversationID: targetID,
            incomingText: "not for you",
            incomingAttachments: [syncAttachment("x.bin")],
            receipt: receipt
        )
        guard case .landed = result else {
            Issue.record("expected .landed, got \(result)")
            return
        }
        #expect(owner.acceptedLandings.isEmpty)
        #expect(owner.text == "other draft")
        // The landing exists, but the fold fence rejects a mismatched slot
        // even if a callback is delivered late to the wrong editor.
        let landing = try #require(store.latestImportedDraftLanding)
        #expect(landing.conversationID == targetID)
        owner.acceptImportedDraftLanding(landing)
        #expect(owner.acceptedLandings.isEmpty)
        #expect(owner.text == "other draft")
    }

    @Test("A reconstructed editor already restored from disk does not double-apply")
    func reconstructionFence() async throws {
        let url = syncTempDraftURL("reconstruct")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        _ = store.save(text: "closed draft", attachments: [], conversationID: conversationID)
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-restore")
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landed = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "landed once",
            incomingAttachments: [syncAttachment("one.bin")],
            receipt: receipt
        )
        guard case .landed = landed else {
            Issue.record("expected .landed, got \(landed)")
            return
        }
        // A fresh editor initialized from the durable slot (ThreadDetailViewModel
        // init reads the stored entry and adopts its revision): the same
        // landing is fenced out, so "landed once" cannot appear twice.
        let reopened = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: store.entry(for: conversationID)?.text ?? "",
            attachments: store.entry(for: conversationID)?.attachments ?? []
        )
        let replay = store.latestImportedDraftLanding
        reopened.acceptImportedDraftLanding(try #require(replay))
        #expect(reopened.acceptedLandings.isEmpty)
        #expect(occurrences(of: "landed once", in: reopened.text) == 1)
    }

    @Test("A temporary chat is refused as an import destination")
    func temporaryTargetRefused() async throws {
        let url = syncTempDraftURL("temporary")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        store.setTemporaryDraftExcluded(conversationID, true)
        let receipt = syncReceipt(for: conversationID)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "must not land",
            incomingAttachments: [syncAttachment("nope.bin")],
            receipt: receipt
        )
        #expect(result == .rejectedTarget)
        #expect(store.latestImportedDraftLanding == nil)
        #expect(store.entry(for: conversationID) == nil)
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(!store.handoffReceiptOnDisk(receipt))
    }

    @Test("A mid-send slot defers as busy; the retry after the send lands")
    func midSendDefersThenRetries() async throws {
        let url = syncTempDraftURL("mid-send")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        _ = store.save(text: "queued text", attachments: [], conversationID: conversationID)
        let sendID = UUID()
        store.beginSendHandoff(
            id: sendID, conversationID: conversationID,
            text: "queued text", attachments: []
        )
        let receipt = syncReceipt(for: conversationID)
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let deferred = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "import while sending",
            incomingAttachments: [syncAttachment("later.bin")],
            receipt: receipt
        )
        #expect(deferred == .deferredBusy)
        #expect(store.latestImportedDraftLanding == nil)
        #expect(store.unsettledHandoffReceipts.isEmpty)
        _ = store.acceptSendHandoff(id: sendID)
        let retry = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "import after send",
            incomingAttachments: [syncAttachment("later.bin")],
            receipt: syncReceipt(for: conversationID, entryID: receipt.entryID, claimToken: "claim-retry")
        )
        guard case .landed = retry else {
            Issue.record("expected .landed after send, got \(retry)")
            return
        }
        #expect(store.entry(for: conversationID)?.text.contains("import after send") == true)
    }

    // MARK: - Failure and recovery

    @Test("A failed durable write publishes nothing and stays retryable with a fresh claim")
    func failedWriteStaysRetryable() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-draft-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let blockedURL = blocker.appendingPathComponent("nested/drafts.json")
        let store = ComposerDraftStore(fileURL: blockedURL)
        let conversationID = UUID()
        _ = store.save(text: "human", attachments: [], conversationID: conversationID)
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store, text: "human", attachments: []
        )
        let incoming = syncAttachment("blocked.bin")
        let firstReceipt = syncReceipt(for: conversationID, claimToken: "claim-first")
        defer { try? FileManager.default.removeItem(at: blocker) }

        let failed = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "phantom import",
            incomingAttachments: [incoming],
            receipt: firstReceipt
        )
        #expect(failed == .failed)
        #expect(store.latestImportedDraftLanding == nil)
        // Nothing was rendered and nothing is provable: the live field keeps
        // the human text, the receipt rolled back, no source may be acked.
        #expect(owner.acceptedLandings.isEmpty)
        #expect(owner.text == "human")
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(!store.handoffReceiptOnDisk(firstReceipt))
        let rolledBack = try #require(store.entry(for: conversationID))
        #expect(occurrences(of: "phantom import", in: rolledBack.text) == 0)

        // The disk works again: the SAME envelope, freshly claimed, lands
        // exactly once — the failed attempt left nothing to duplicate.
        try FileManager.default.removeItem(at: blocker)
        let retryReceipt = syncReceipt(for: conversationID, claimToken: "claim-second")
        let retry = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "real import",
            incomingAttachments: [incoming],
            receipt: retryReceipt
        )
        guard case .landed = retry else {
            Issue.record("expected .landed after the disk recovered, got \(retry)")
            return
        }
        #expect(owner.acceptedLandings.count == 1)
        #expect(occurrences(of: "real import", in: owner.text) == 1)
        let landed = try #require(store.entry(for: conversationID))
        #expect(landed.text.contains("human"))
        #expect(landed.text.contains("real import"))
        #expect(landed.attachments.map(\.id) == [incoming.id])
        store.settleHandoff(entryID: retryReceipt.entryID, claimToken: retryReceipt.claimToken)
    }

    @Test("A landed receipt proves crash recovery in a new process")
    func crashBeforeAckRecoversFromDisk() async throws {
        let url = syncTempDraftURL("crash")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        _ = store.save(text: "before crash", attachments: [], conversationID: conversationID)
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-crash")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let landed = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "imported before death",
            incomingAttachments: [syncAttachment("crash.bin")],
            receipt: receipt
        )
        guard case .landed = landed else {
            Issue.record("expected .landed, got \(landed)")
            return
        }
        // Process death between the durable landing and the source ack: the
        // reconstructed store proves the exact receipt from disk and the
        // destination settles it without a second placement (the same
        // authority ConversationDraftDestination reads before acking).
        let restarted = ComposerDraftStore(fileURL: url)
        #expect(restarted.unsettledHandoffReceipts.contains(receipt))
        #expect(restarted.handoffReceiptOnDisk(receipt))
        #expect(restarted.entry(for: conversationID)?.text.contains("imported before death") == true)
        restarted.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
        #expect(restarted.unsettledHandoffReceipts.isEmpty)
    }

    @Test("Only files, and refs already durable, produce exact deltas")
    func filesOnlyAndAlreadyDurableRefs() async throws {
        let url = syncTempDraftURL("delta")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = UUID()
        let existing = syncAttachment("existing.bin")
        _ = store.save(text: "text stays", attachments: [existing], conversationID: conversationID)
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "text stays", attachments: [existing]
        )
        let fresh = syncAttachment("fresh.bin")
        // The same item identity that is already durable must not re-enter
        // the landing as a new ref (stable ids are the idempotence, never
        // a content comparison).
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-delta")
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landed = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "   ",
            incomingAttachments: [existing, fresh],
            receipt: receipt
        )
        guard case .landed(let revision) = landed else {
            Issue.record("expected .landed, got \(landed)")
            return
        }
        let landing = try #require(store.latestImportedDraftLanding)
        #expect(landing.landedRevision == revision)
        #expect(landing.addedAttachments.map(\.id) == [fresh.id])
        #expect(owner.text == "text stays")
        #expect(owner.attachments.map(\.id) == [existing.id, fresh.id])
    }

    @Test("The Home launchpad slot uses the same landing contract")
    func homeSlotReusability() async throws {
        let url = syncTempDraftURL("home-slot")
        let store = ComposerDraftStore(fileURL: url)
        let conversationID = ComposerDraftStore.homeDraftID
        _ = store.save(text: "launchpad draft", attachments: [], conversationID: conversationID)
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store, text: "launchpad draft", attachments: []
        )
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-home")
        defer {
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landed = await store.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "from the share card",
            incomingAttachments: [],
            receipt: receipt
        )
        guard case .landed = landed else {
            Issue.record("expected .landed, got \(landed)")
            return
        }
        #expect(owner.text.contains("from the share card"))
        #expect(store.hasLiveDraftOwner(for: conversationID))
    }

    // MARK: - Controlled write barrier: human edit DURING the durable IO

    /// Waits (bounded) until the store reports the import placement is in
    /// flight, i.e. it has written the merged slot and is suspended awaiting
    /// disk verification on the held-back serial write queue.
    private func waitForInFlightImport(
        _ store: ComposerDraftStore, conversationID: UUID
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !store.isImportedDraftCommitInFlight(for: conversationID) {
            if clock.now >= deadline {
                throw ImportDraftTestFailure.writeBarrierTimedOut
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test("A human edit during the durable IO cannot adopt unproven refs, and success re-applies the proven delta")
    func editDuringInFlightImportThenSuccess() async throws {
        let url = syncTempDraftURL("barrier-success")
        let barrier = ImportDraftBarrier(label: "app.floe.test.import-draft-barrier")
        let store = ComposerDraftStore(fileURL: url, writeQueue: barrier.queue)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human base", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human base", attachments: [human]
        )
        let imported = syncAttachment("incoming.bin")
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-barrier")
        barrier.park()
        defer {
            barrier.release()
            store.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landing = Task {
            await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "arrived during io",
                incomingAttachments: [imported],
                receipt: receipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)

        // The placement exists in memory but proves nothing yet.
        #expect(store.isImportedDraftCommitInFlight(for: conversationID))
        #expect(store.latestImportedDraftLanding == nil)
        // Readers (reconstructed editors, refreshDraftFromDurableStore, the
        // destination snapshot) still see the PROVEN pre-placement slot.
        let provenView = try #require(store.entry(for: conversationID))
        #expect(provenView.text == "human base")
        #expect(provenView.attachments.map(\.id) == [human.id])
        #expect(!store.isImportLandingAbsorbed(
            ComposerDraftStore.importedDraftLandingID(conversationID: conversationID, receipt: receipt)
        ))

        // The composer's next keystroke during that window: its CAS is stale,
        // so it rebases — and the rebase must NOT union the unproven ref.
        let rebased = store.liveRebasedDraft(
            text: "human base typed while io", attachments: [human],
            conversationID: conversationID, knownRevision: baseRevision
        )
        #expect(rebased.attachments.map(\.id) == [human.id])
        #expect(occurrences(of: "arrived during io", in: rebased.text) == 0)
        let humanRevision = try #require(store.save(
            text: rebased.text, attachments: rebased.attachments, conversationID: conversationID
        ))
        #expect(humanRevision > baseRevision)

        // Now the bytes land. The proven placement becomes authoritative, is
        // re-applied onto the newer human content, and only then renders.
        barrier.release()
        let result = await landing.value
        guard case .landed = result else {
            Issue.record("expected .landed after the write completed, got \(result)")
            return
        }
        let landedEntry = try #require(store.entry(for: conversationID))
        #expect(landedEntry.attachments.map(\.id) == [human.id, imported.id])
        #expect(landedEntry.text.contains("human base typed while io"))
        #expect(occurrences(of: "arrived during io", in: landedEntry.text) == 1)
        #expect(!store.isImportedDraftCommitInFlight(for: conversationID))
        #expect(store.handoffReceiptOnDisk(receipt))
        let landingValue = try #require(store.latestImportedDraftLanding)
        #expect(landingValue.addedAttachments.map(\.id) == [imported.id])
        #expect(owner.acceptedLandings.count == 1)
        #expect(owner.attachments.map(\.id) == [human.id, imported.id])
        #expect(occurrences(of: "arrived during io", in: owner.text) == 1)
    }

    @Test("A failed in-flight import with an interleaved edit leaves no dangling ref")
    func editDuringInFlightImportThenFailure() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-draft-barrier-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let blockedURL = blocker.appendingPathComponent("nested/drafts.json")
        let barrier = ImportDraftBarrier(label: "app.floe.test.import-draft-failure-barrier")
        let store = ComposerDraftStore(fileURL: blockedURL, writeQueue: barrier.queue)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human base", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human base", attachments: [human]
        )
        let imported = syncAttachment("incoming.bin")
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-fail-barrier")
        barrier.park()
        defer {
            barrier.release()
            try? FileManager.default.removeItem(at: blocker)
        }
        let landing = Task {
            await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "phantom",
                incomingAttachments: [imported],
                receipt: receipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)
        // Interleaved human edit through the composer's guarded fallback.
        let rebased = store.liveRebasedDraft(
            text: "human base typed while io", attachments: [human],
            conversationID: conversationID, knownRevision: baseRevision
        )
        #expect(!rebased.attachments.contains { $0.id == imported.id })
        _ = store.save(
            text: rebased.text, attachments: rebased.attachments, conversationID: conversationID
        )
        // The write fails. The source is never acknowledged and it discards
        // its staged files — nothing in the live or durable draft may be
        // holding those ids.
        barrier.release()
        let result = await landing.value
        #expect(result == .failed)
        let afterFailure = try #require(store.entry(for: conversationID))
        #expect(afterFailure.attachments.map(\.id) == [human.id])
        #expect(occurrences(of: "phantom", in: afterFailure.text) == 0)
        #expect(store.latestImportedDraftLanding == nil)
        #expect(owner.acceptedLandings.isEmpty)
        #expect(owner.attachments.map(\.id) == [human.id])
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(!store.handoffReceiptOnDisk(receipt))
        #expect(!store.isImportedDraftCommitInFlight(for: conversationID))
        _ = baseRevision
    }

    /// Waits (bounded) until the RECONCILED placement attempt is the one in
    /// flight: the fence is armed again AND the proven view external readers
    /// see is the NEWER human slot (the reconciliation placement's mask base),
    /// while nothing has been published yet. This is only true after the
    /// first placement verified and while the SECOND (reconciled) serial
    /// write is held back.
    private func waitForReconciledPlacement(
        _ store: ComposerDraftStore,
        conversationID: UUID,
        maskContains humanMarker: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(
            store.isImportedDraftCommitInFlight(for: conversationID)
                && store.latestImportedDraftLanding == nil
                && store.entry(for: conversationID)?.text.contains(humanMarker) == true
        ) {
            if clock.now >= deadline {
                throw ImportDraftTestFailure.writeBarrierTimedOut
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test("The reconciled second write gates .landed: disk reconstruction proves human+import+receipt")
    func reconcileSecondWriteGatesLandedUntilDurable() async throws {
        let url = syncTempDraftURL("reconcile-second-write")
        let barrier = ImportDraftBarrier(label: "app.floe.test.reconcile-second-write-barrier")
        let store = ComposerDraftStore(fileURL: url, writeQueue: barrier.queue)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human base", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human base", attachments: [human]
        )
        let imported = syncAttachment("incoming.bin")
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-reconcile")
        var outcome: ComposerDraftStore.ImportedDraftLandingResult?
        barrier.park()
        defer {
            barrier.release()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landing = Task {
            outcome = await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "arrived during reconcile",
                incomingAttachments: [imported],
                receipt: receipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)
        // The interleaved human edit replaces the slot while the FIRST
        // placement still awaits its disk verification.
        let rebased = store.liveRebasedDraft(
            text: "human base typed during io", attachments: [human],
            conversationID: conversationID, knownRevision: baseRevision
        )
        _ = store.save(
            text: rebased.text, attachments: rebased.attachments,
            conversationID: conversationID
        )
        // Let the first placement complete, then park the serial queue on
        // this test's own item so the reconciled (second) write cannot run.
        // The gate item is enqueued BEFORE resuming, so it sits behind
        // exactly the first placement's write + verdict blocks.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        barrier.queue.async { gate.wait() }
        barrier.release()
        try await waitForReconciledPlacement(
            store, conversationID: conversationID, maskContains: "typed during io"
        )
        // While the second write is held: the call has NOT reported
        // `.landed`, nothing is published, no live owner rendered anything,
        // and therefore no source acknowledgment path exists — the only ack
        // authority for an import is the landed result itself. The held
        // await ends only on the serial writer's actual completion (no
        // timeout verdict), so no failure result can be returned while the
        // in-flight snapshot still can publish imported refs.
        #expect(outcome == nil)
        #expect(store.latestImportedDraftLanding == nil)
        #expect(owner.acceptedLandings.isEmpty)
        #expect(store.isImportedDraftCommitInFlight(for: conversationID))
        // Ownership invariant for the intake side: the receipt visible at
        // this moment is proven ONLY because the FIRST placement's bytes
        // really landed (its snapshot carries the delta + receipt + proof).
        // Should this apply end busy/failed, the staged file behind
        // `imported.id` is referenced by that durable snapshot and MUST be
        // retained — the ShareIntakeCenter regression covers exactly this
        // durable-proof gate. Nothing here may be discarded or acked.
        #expect(store.handoffReceiptOnDisk(receipt))
        #expect(store.unsettledHandoffReceipts.contains(receipt))
        // Complete the reconciled write, then IMMEDIATELY — before any
        // optional flush — reconstruct the store from disk: the newest
        // durable snapshot carries the interleaved human content, the
        // imported delta exactly once (stable ids, no containment merge
        // guess), and the receipt.
        gate.signal()
        _ = await landing.value
        let result = try #require(outcome)
        guard case .landed = result else {
            Issue.record("expected .landed after the reconciled write completed, got \(result)")
            return
        }
        let reconstructed = ComposerDraftStore(fileURL: url)
        let entry = try #require(reconstructed.entry(for: conversationID))
        #expect(entry.text.contains("human base typed during io"))
        #expect(occurrences(of: "arrived during reconcile", in: entry.text) == 1)
        #expect(entry.attachments.map(\.id) == [human.id, imported.id])
        #expect(reconstructed.unsettledHandoffReceipts.contains(receipt))
        #expect(reconstructed.handoffReceiptOnDisk(receipt))
        #expect(owner.acceptedLandings.count == 1)
        reconstructed.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
    }

    @Test("A failing reconciled write never acks, rolls back, and proves nothing false")
    func reconcileWriteFailureKeepsEnvelopePendingAndHonest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-draft-reconcile-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("nested/drafts.json")
        let barrier = ImportDraftBarrier(label: "app.floe.test.reconcile-failure-barrier")
        let store = ComposerDraftStore(fileURL: url, writeQueue: barrier.queue)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human base", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human base", attachments: [human]
        )
        let imported = syncAttachment("incoming.bin")
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-reconcile-fail")
        var outcome: ComposerDraftStore.ImportedDraftLandingResult?
        barrier.park()
        defer {
            barrier.release()
            try? FileManager.default.removeItem(at: root)
        }
        let landing = Task {
            outcome = await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "phantom reconcile",
                incomingAttachments: [imported],
                receipt: receipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)
        let rebased = store.liveRebasedDraft(
            text: "human base typed during io", attachments: [human],
            conversationID: conversationID, knownRevision: baseRevision
        )
        _ = store.save(
            text: rebased.text, attachments: rebased.attachments,
            conversationID: conversationID
        )
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        barrier.queue.async { gate.wait() }
        barrier.release()
        try await waitForReconciledPlacement(
            store, conversationID: conversationID, maskContains: "typed during io"
        )
        // Break the durable path AFTER the first placement landed: the
        // reconciled write must fail. Replace the drafts directory with a
        // plain file so the writer's createDirectory + atomic write both
        // fail, exactly like a corrupted volume.
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try Data("synthetic blocker".utf8).write(to: url.deletingLastPathComponent())
        gate.signal()
        _ = await landing.value
        let result = try #require(outcome)
        #expect(result == .failed)
        // Nothing published, nothing rendered, and the slot rolled back to
        // the newer human content: no in-memory draft is left holding the
        // imported ref whose staged file a failed apply may let the source
        // release (and the intake only releases when NOTHING durable proves
        // for this envelope — see the ShareIntakeCenter regression).
        #expect(store.latestImportedDraftLanding == nil)
        #expect(owner.acceptedLandings.isEmpty)
        #expect(!store.isImportedDraftCommitInFlight(for: conversationID))
        let rolledBack = try #require(store.entry(for: conversationID))
        #expect(rolledBack.text.contains("human base typed during io"))
        #expect(occurrences(of: "phantom reconcile", in: rolledBack.text) == 0)
        #expect(rolledBack.attachments.map(\.id) == [human.id])
        // The FIRST placement's landing stays honestly unsettled-but-proven
        // in this process (its snapshot really landed before the volume was
        // broken): the intake must retain the staged file that durable
        // snapshot references rather than discard it on this failure.
        #expect(store.unsettledHandoffReceipts.contains(receipt))
        // The disk bytes are gone (this test destroyed them), so NO fresh
        // process may believe this receipt: without a readable document the
        // content-aware proof proves nothing, and the envelope therefore
        // stays pending and re-lands instead of acknowledging lost bytes.
        let reconstructed = ComposerDraftStore(fileURL: url)
        #expect(reconstructed.unsettledHandoffReceipts.isEmpty)
        #expect(!reconstructed.handoffReceiptOnDisk(receipt))
    }

    @Test("A cancel during the reconciled hold defers: no publish, no ack, durable state stays honest")
    func reconcileCancellationDefersWithoutPublishing() async throws {
        let url = syncTempDraftURL("reconcile-cancel")
        let barrier = ImportDraftBarrier(label: "app.floe.test.reconcile-cancel-barrier")
        let store = ComposerDraftStore(fileURL: url, writeQueue: barrier.queue)
        let conversationID = UUID()
        let human = syncAttachment("human.bin")
        let baseRevision = try #require(
            store.save(text: "human base", attachments: [human], conversationID: conversationID)
        )
        let owner = FakeLiveComposer(
            conversationID: conversationID, store: store,
            text: "human base", attachments: [human]
        )
        let imported = syncAttachment("incoming.bin")
        let receipt = syncReceipt(for: conversationID, claimToken: "claim-reconcile-cancel")
        var outcome: ComposerDraftStore.ImportedDraftLandingResult?
        barrier.park()
        defer {
            barrier.release()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let landing = Task {
            outcome = await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "arrived on cancel",
                incomingAttachments: [imported],
                receipt: receipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)
        let rebased = store.liveRebasedDraft(
            text: "human base typed during io", attachments: [human],
            conversationID: conversationID, knownRevision: baseRevision
        )
        _ = store.save(
            text: rebased.text, attachments: rebased.attachments,
            conversationID: conversationID
        )
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        barrier.queue.async { gate.wait() }
        barrier.release()
        try await waitForReconciledPlacement(
            store, conversationID: conversationID, maskContains: "typed during io"
        )
        // The apply flow is cancelled while the reconciled write is held:
        // the call defers and must NOT publish or acknowledge.
        landing.cancel()
        gate.signal()
        _ = await landing.value
        let result = try #require(outcome)
        #expect(result == .deferredBusy)
        #expect(store.latestImportedDraftLanding == nil)
        #expect(owner.acceptedLandings.isEmpty)
        #expect(!store.isImportedDraftCommitInFlight(for: conversationID))
        // The envelope stays pending and recoverable. The reconciled bytes
        // themselves landed (the serial write was already queued), so the
        // next pass settles them against the content-aware disk proof
        // WITHOUT appending the delta a second time; reconstruction proves
        // human content + imported delta exactly once + the receipt.
        let reconstructed = ComposerDraftStore(fileURL: url)
        let entry = try #require(reconstructed.entry(for: conversationID))
        #expect(entry.text.contains("human base typed during io"))
        #expect(occurrences(of: "arrived on cancel", in: entry.text) == 1)
        #expect(entry.attachments.map(\.id) == [human.id, imported.id])
        #expect(reconstructed.unsettledHandoffReceipts.contains(receipt))
        #expect(reconstructed.handoffReceiptOnDisk(receipt))
        reconstructed.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken)
    }

    @Test("Two in-flight landings serialize: the second defers as busy")
    func secondLandingDefersWhileFirstInFlight() async throws {
        let url = syncTempDraftURL("barrier-serialize")
        let barrier = ImportDraftBarrier(label: "app.floe.test.import-draft-serialize")
        let store = ComposerDraftStore(fileURL: url, writeQueue: barrier.queue)
        let conversationID = UUID()
        let otherID = UUID()
        _ = store.save(text: "a", attachments: [], conversationID: conversationID)
        _ = store.save(text: "b", attachments: [], conversationID: otherID)
        let firstReceipt = syncReceipt(for: conversationID, claimToken: "claim-first-barrier")
        let secondReceipt = syncReceipt(for: otherID, claimToken: "claim-second-barrier")
        barrier.park()
        defer {
            barrier.release()
            store.settleHandoff(entryID: firstReceipt.entryID, claimToken: firstReceipt.claimToken)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let first = Task {
            await store.acceptImportedDraft(
                conversationID: conversationID,
                incomingText: "first",
                incomingAttachments: [syncAttachment("first.bin")],
                receipt: firstReceipt
            )
        }
        try await waitForInFlightImport(store, conversationID: conversationID)
        let second = await store.acceptImportedDraft(
            conversationID: otherID,
            incomingText: "second",
            incomingAttachments: [],
            receipt: secondReceipt
        )
        #expect(second == .deferredBusy)
        #expect(store.latestImportedDraftLanding == nil)
        barrier.release()
        guard case .landed = await first.value else {
            Issue.record("expected the first landing to succeed")
            return
        }
        #expect(store.entry(for: otherID)?.text == "b")
    }


    // MARK: - Real view model wiring (already-open ThreadDetailViewModel)

    @Test("An open ThreadDetailViewModel absorbs the landing and the next save keeps it")
    func openViewModelAbsorbsLanding() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = ConversationCenter(environment: environment)
        let conversationID = UUID()
        let shared = ComposerDraftStore.shared
        defer { shared.clear(conversationID: conversationID) }
        let pdf = syncAttachment("vm-import.pdf")
        let baseRevision = try #require(shared.save(
            text: "typed while open", attachments: [], conversationID: conversationID
        ))
        // The canonical already-open editor: it only initialized from the
        // store, exactly like a live ThreadDetailView.
        let viewModel = ThreadDetailViewModel(conversationID: conversationID, center: center)
        #expect(viewModel.draft == "typed while open")
        #expect(shared.hasLiveDraftOwner(for: conversationID))

        let receipt = syncReceipt(for: conversationID, claimToken: "claim-vm")
        let landed = await shared.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: "imported into the open task",
            incomingAttachments: [pdf],
            receipt: receipt
        )
        defer { shared.settleHandoff(entryID: receipt.entryID, claimToken: receipt.claimToken) }
        guard case .landed = landed else {
            Issue.record("expected .landed, got \(landed)")
            return
        }
        // Immediate: the open composer shows the landed refs.
        #expect(viewModel.draft.contains("typed while open"))
        #expect(viewModel.draft.contains("imported into the open task"))
        #expect(viewModel.attachments.map(\.id) == [pdf.id])
        // Survives the next edit: the composer's guarded save is in the
        // landing-safe shape, so a keystroke rebase keeps the landed ref.
        let typed = "typed while open more"
        let saved = shared.liveRebasedDraft(
            text: typed, attachments: [pdf],
            conversationID: conversationID, knownRevision: baseRevision
        )
        let revision = try #require(shared.save(
            text: saved.text, attachments: saved.attachments, conversationID: conversationID
        ))
        #expect(revision > baseRevision)
        let entry = try #require(shared.entry(for: conversationID))
        #expect(entry.attachments.map(\.id) == [pdf.id])
        #expect(occurrences(of: "imported into the open task", in: entry.text) <= 1)
    }

    @Test("refreshDraftFromDurableStore adopts a newer slot without clobbering newer live text")
    func refreshAdoptsOnlyNewerDurableSlot() throws {
        let environment = AppEnvironment.preview()
        let center = ConversationCenter(environment: environment)
        let conversationID = UUID()
        let shared = ComposerDraftStore.shared
        defer { shared.clear(conversationID: conversationID) }
        let firstRevision = try #require(shared.save(
            text: "route target draft", attachments: [], conversationID: conversationID
        ))
        let viewModel = ThreadDetailViewModel(conversationID: conversationID, center: center)
        #expect(viewModel.draft == "route target draft")
        // A landing already inside this editor's adopted revision is a no-op.
        viewModel.refreshDraftFromDurableStore()
        #expect(viewModel.draft == "route target draft")
        // The durable slot moved (import landed while the route to the SAME
        // conversation did not reconstruct the view): an explicit refresh
        // adopts it, and only it.
        let doc = syncAttachment("route-import.doc")
        _ = try #require(shared.save(
            text: "route target draft\n\nimported while rerouted",
            attachments: [doc],
            conversationID: conversationID,
            expectedRevision: firstRevision
        ))
        viewModel.refreshDraftFromDurableStore()
        #expect(viewModel.draft.contains("imported while rerouted"))
        #expect(viewModel.attachments.map(\.id) == [doc.id])
        // Idempotent: a second refresh with nothing newer durable changes
        // nothing (the ordinary multiwindow text policy stays untouched).
        viewModel.draft = "local edit after adoption"
        viewModel.refreshDraftFromDurableStore()
        #expect(viewModel.draft == "local edit after adoption")
    }

    @Test("A released view model stops being the live owner")
    func releasedOwnerDropsOut() throws {
        let environment = AppEnvironment.preview()
        let center = ConversationCenter(environment: environment)
        let conversationID = UUID()
        let shared = ComposerDraftStore.shared
        defer { shared.clear(conversationID: conversationID) }
        #expect(!shared.hasLiveDraftOwner(for: conversationID))
        var viewModel: ThreadDetailViewModel? = ThreadDetailViewModel(
            conversationID: conversationID, center: center
        )
        #expect(shared.hasLiveDraftOwner(for: conversationID))
        // The weak registry means a replaced/closed view can never be
        // addressed by a later landing, and it stops reporting live.
        viewModel = nil
        #expect(!shared.hasLiveDraftOwner(for: conversationID))
    }
}
#endif
