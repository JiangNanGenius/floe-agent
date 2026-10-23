// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — inbound destination chooser (导入手记 / 导入任务 / 导入画布).
//
// Ambiguous external entries (Share-extension envelopes and common-file
// "Open In") no longer default to whichever page happens to be open. This
// center stages/queues them and presents ONE compact destination choice over
// the current context (it never navigates by itself), then executes the
// explicit choice through the existing durable pipelines:
//
// * share envelope + Notes: claim the envelope (digest-verified), import
//   every item through the existing Notes importer using exact
//   pre-allocated document ids persisted in the decision ledger, then ack.
//   A restart proves each commit by planned identity — no duplicate Notes,
//   and the envelope is never acknowledged before every copy is durable.
// * share envelope + Task: navigational continuation only — the reviewed
//   Home card pipeline keeps deciding per apply (receipt + ack unchanged).
// * + Canvas: the confirmed picker target is persisted BEFORE any copy;
//   bytes enter the existing content-hash-idempotent material boundary via
//   `CanvasDestinationCommitting`; only after every item's asset is proven
//   durable does the source leave the namespace. Per-canvas insertion and
//   new-canvas creation are Canvas-owned (see the private handoff seam);
//   this lane never commits an empty canvas and never touches editor state.
// * document event + Notes: the ledger releases the queue's fail-closed
//   auto-drain gate and the existing DocumentIntake import (staged bytes,
//   planned id, routing fence) runs unchanged.
// * document event + Task: stage the queue payload into a NEW ShareInbox
//   envelope (its id is persisted before the envelope commit), and only
//   then discard the queue record. Interrupted hand-offs are completed by
//   recovery; a committed envelope can never be staged twice.
//
// The requirement to ask lives in the staged record
// (`destinationChoiceRequired`, written atomically at intake) — never in a
// side journal — so a missing or corrupt ledger entry can only HOLD an
// entry, never permit a silent default. Availability failures fail CLOSED.
// Presentation is peek/confirm: a chooser that could not actually appear
// (voice modal, Settings, another document modal) is never marked consumed.
// Cancellation creates no task/note/canvas and leaves the source unchanged:
// a document event uses the existing queue cancellation (banner retry
// re-arms exactly one fresh choice); an envelope stays pending for the Home
// share card, which offers all three destinations. Legacy queue entries
// without the flag keep the pre-feature default instead of being stranded.

#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeNotes
import FloePersistence

// MARK: - Explicit-choice outcomes

/// Result of running a whole reviewed share envelope into a durable
/// destination (Notes documents or Canvas material assets). `settled` means
/// a previous pass already committed the planned copies and this pass only
/// acknowledged the source.
enum ShareNotesImportResult: Equatable, Sendable {
    case imported(envelopeID: UUID, documentCount: Int)
    case settled(envelopeID: UUID)
    case deferredBusy(envelopeID: UUID)
    case failed(envelopeID: UUID, message: String?)
    case unavailable
}

extension ShareNotesImportResult {
    /// Which envelope this status describes; nil means a global
    /// unavailability that applies to no specific share.
    var envelopeIdentity: UUID? {
        switch self {
        case .imported(let id, _), .settled(let id), .deferredBusy(let id), .failed(let id, _):
            return id
        case .unavailable:
            return nil
        }
    }
}

/// Card status line data: which durable destination an explicit action ran
/// and with which result.
struct ShareDestinationOutcome: Equatable, Sendable {
    let destination: ImportDestination
    let result: ShareNotesImportResult
}

/// Injected into `ShareIntakeCenter` so the Home share card can offer the
/// durable destinations without owning any import logic.
@MainActor
protocol ShareEnvelopeDestinationImporting: AnyObject {
    func importEnvelopeToNotes(_ envelope: ShareEnvelope) async -> ShareNotesImportResult
    func importEnvelopeToCanvas(
        _ envelope: ShareEnvelope,
        target: CanvasDestinationTarget
    ) async -> ShareNotesImportResult
    /// Canvas picker snapshot for the card's compact menu. Falls back to an
    /// empty list (New Canvas only) when the list cannot be loaded; the
    /// full chooser sheet offers search, paging and an explicit retry.
    func canvasImportTargets() -> [CanvasImportTarget]
}

// MARK: - Canvas destination seam (stable operation identity)

struct CanvasImportTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// One unit of a Canvas import with its pre-persisted node identity.
/// `payloadURL` always points at proven durable bytes (the envelope item
/// or the staged queue payload), never at a provider URL.
struct CanvasImportUnitPlan: Sendable, Equatable {
    let key: String
    let displayName: String
    let payloadURL: URL
    let plannedNodeID: UUID
}

/// One origin's Canvas operation, persisted BEFORE any copy. The
/// Canvas-owned committer MUST:
/// * ingest bytes through the existing material boundary,
/// * create a new canvas ONLY under `plannedNewCanvasID` — or prove that
///   exact canvas already exists,
/// * insert nodes ONLY under the given `plannedNodeID`s — or prove those
///   exact nodes already exist,
/// * serialize through the existing CanvasProjectFileWriter CAS while
///   preserving any open editor state,
/// * be idempotent for the same `operationID`: a retry after a failed CAS
///   (before the ledger ack) can never create a second canvas or duplicate
///   nodes,
/// * return `.committed` only when EVERY planned node is proven inside the
///   resolved canvas. Until then the chooser keeps the source pending and
///   never acknowledges it.
struct CanvasImportOperation: Sendable, Equatable {
    let operationID: UUID
    /// Envelope id (share origin) or queue event id (document origin).
    let originID: UUID
    let target: CanvasDestinationTarget
    /// Set only for `.newCanvas`: the exact planned canvas UUID.
    let plannedNewCanvasID: UUID?
    let units: [CanvasImportUnitPlan]
}

enum CanvasCommitResult: Equatable, Sendable {
    /// Every planned node is proven durable inside `canvasID`. Only this
    /// result may release the source.
    case committed(canvasID: UUID, nodeIDs: [UUID])
    /// Nothing is proven committed (including CAS/live-editor deferral).
    /// The source stays pending and the SAME operation may be retried.
    case failed(message: String?)
}

@MainActor
protocol CanvasDestinationCommitting: AnyObject {
    /// ALL existing canvases offered in the compact picker (read-only).
    /// The picker pages the visible window; nothing is clipped here.
    func canvasImportTargets() throws -> [CanvasImportTarget]
    func commitImport(_ operation: CanvasImportOperation) async -> CanvasCommitResult
}

// MARK: - Task destination seam

enum ImportTargetLoadError: Error, Equatable {
    case unavailable
}

struct TaskImportTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

/// Read-only queries over the EXISTING conversation store. No list mutation,
/// no draft write, no navigation. Temporary/notes purposes and archived rows
/// are never offered as persisted task targets. `taskImportTargets` returns
/// ALL eligible tasks (newest first) — the picker, not the provider, pages
/// the visible window — and THROWS on a real store failure so the UI can
/// distinguish "load failed, retry" from "no tasks".
protocol TaskDestinationProviding: AnyObject, Sendable {
    func taskImportTargets() async throws -> [TaskImportTarget]
    func isTaskTargetAvailable(_ conversationID: UUID) async -> Bool
}

final class ConversationStoreTaskDestinationProvider: TaskDestinationProviding, @unchecked Sendable {
    private let store: any ConversationStore

    init(store: any ConversationStore) {
        self.store = store
    }

    func taskImportTargets() async throws -> [TaskImportTarget] {
        let records = try await store.conversations(includeArchived: false)
        return records
            .filter { $0.purpose == .ordinary }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { TaskImportTarget(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    func isTaskTargetAvailable(_ conversationID: UUID) async -> Bool {
        let record = try? await store.conversation(id: conversationID)
        return record?.purpose == .ordinary && record?.archivedAt == nil
    }
}

/// Durable background destination for one confirmed persisted task. It
/// runs the ONE unified `ComposerDraftStore.acceptImportedDraft` landing
/// entrypoint (owned by the draft-synchronization job): the merge reuses
/// the existing `ShareDraftMerger` rules, the durable CAS + envelope-bound
/// receipt commit, and — when the task's composer is open — the same-turn
/// synchronous fold into every live owner. Render-before-ack holds: only
/// `.landed` (receipt verified on disk and folded) may acknowledge the
/// source; `.deferredBusy` mid-send and `.rejectedTarget` for a temporary
/// chat never copy or ack, and a failed durable write leaves the envelope
/// pending with the receipt rolled back inside the store.
@MainActor
final class ConversationDraftDestination: ShareIntakeDestination {
    private let conversationID: UUID
    private let draftStore: ComposerDraftStore

    init(conversationID: UUID, draftStore: ComposerDraftStore = .shared) {
        self.conversationID = conversationID
        self.draftStore = draftStore
    }

    var shareIntakeDestinationID: String {
        conversationID.uuidString.lowercased()
    }

    func shareIntakeSnapshot() -> ShareDraftSnapshot {
        let stored = draftStore.entry(for: conversationID)
        // Only a real mid-send/handoff busy state defers here; live owners
        // are handled uniformly by the landing fold, not by deferral.
        let sendBusy = draftStore.sendHandoffUpdate.map {
            $0.conversationID == conversationID && $0.phase == .began
        } ?? false
        return ShareDraftSnapshot(
            text: stored?.text ?? "",
            attachmentIDs: stored?.attachments.map(\.id) ?? [],
            storedRevision: stored?.revision,
            isBusy: sendBusy || draftStore.isImportedDraftCommitInFlight(for: conversationID)
        )
    }

    func shareIntakeAppliedClaimToken(envelopeID: UUID) -> String? {
        draftStore.unsettledHandoffReceipts.first { receipt in
            receipt.entryID == envelopeID
                && receipt.destinationID == shareIntakeDestinationID
                && draftStore.handoffReceiptOnDisk(receipt)
        }?.claimToken
    }

    func shareIntakeSettle(envelopeID: UUID, claimToken: String) {
        draftStore.settleHandoff(entryID: envelopeID, claimToken: claimToken)
    }

    func shareIntakeApply(_ application: ShareDraftApplication) async -> ShareDraftApplyResult {
        let landing = await draftStore.acceptImportedDraft(
            conversationID: conversationID,
            incomingText: application.incomingText,
            incomingAttachments: application.stagedAttachments,
            receipt: application.receipt
        )
        switch landing {
        case .landed:
            // Final disk-receipt verification, same contract as Home.
            guard draftStore.handoffReceiptOnDisk(application.receipt) else {
                return .failed
            }
            return .applied
        case .deferredBusy:
            return .busy
        case .rejectedTarget:
            return .unavailable
        case .failed:
            return .failed
        }
    }
}

// MARK: - Center

@MainActor
final class ImportDestinationCenter: ObservableObject {
    /// The next ambiguous entry awaiting an explicit destination, or nil.
    @Published private(set) var destinationRequest: ImportDestinationRequest?
    /// A choice action is running; the sheet disables its buttons.
    @Published private(set) var isResolving = false
    /// Concise follow-up for the OPEN sheet only (busy/failed). Success
    /// dismisses the sheet; feedback lives on the destination surfaces.
    @Published private(set) var lastActionMessage: String?
    /// Advances ONLY after a durable New Task decision marker exists (fresh
    /// share choice, event conversion, or recovery completion). Home observes
    /// this beside its existing `.task` so an already-visible canonical Home
    /// consumes the confirmed envelope immediately even when navigation
    /// never changes route identity. Repeated signals are idempotent: the
    /// consume path is gated by the pending list, the exclusive claim and
    /// the settled receipt ledger.
    @Published private(set) var confirmedNewTaskRevision = 0

    let isLedgerAvailable: Bool

    private let inbox: ShareInbox?
    private let notes: any NotesDocumentImporting
    private let store: ImportDestinationDecisionStore?
    private let canvas: (any CanvasDestinationCommitting)?
    private let taskProvider: (any TaskDestinationProviding)?
    private let now: @Sendable () -> Date

    private weak var shareCenter: ShareIntakeCenter?
    private weak var documentCenter: DocumentIntakeCenter?

    private var pendingRequests: [ImportDestinationRequest] = []
    /// One presentation per source state time; a queue retry that advances
    /// `updatedAt` re-arms exactly one fresh choice (no nagging otherwise).
    private var presentationTokens: [ImportDestinationOrigin: Date] = [:]
    private var settledOrigins: Set<ImportDestinationOrigin> = []
    /// Idempotence for the sheet's Cancel button plus its `onDismiss`
    /// follow-up: one visible cancellation runs exactly once.
    private var handledCancellations: Set<UUID> = []
    private var didStart = false
    private var shareCancellable: AnyCancellable?
    private var documentCancellable: AnyCancellable?

    private static let textUnitKey = "text"
    private static let eventFileUnitKey = "file"

    init(
        inbox: ShareInbox?,
        notes: any NotesDocumentImporting = LiveNotesDocumentImporter.live,
        store: ImportDestinationDecisionStore? = ImportDestinationDecisionStore.production(),
        canvas: (any CanvasDestinationCommitting)? = nil,
        taskProvider: (any TaskDestinationProviding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
        self.notes = notes
        self.store = store?.isAvailable == true ? store : nil
        self.isLedgerAvailable = self.store != nil
        self.canvas = canvas
        self.taskProvider = taskProvider
        self.now = now
    }

    // MARK: Wiring / lifecycle

    /// Idempotent app-lifecycle entry. Installs the fail-closed gate on the
    /// document queue's automatic drain, injects the destination
    /// collaborator into the share card center, resumes any half-finished
    /// durable decision and starts observing arrivals. Must run BEFORE
    /// `DocumentIntakeCenter.markStoresReady()` in production wiring.
    func start(shareCenter: ShareIntakeCenter, documentCenter: DocumentIntakeCenter) {
        guard !didStart else { return }
        didStart = true
        self.shareCenter = shareCenter
        self.documentCenter = documentCenter

        let store = self.store
        documentCenter.configureDestinationGate { record in
            // Fail closed: the requirement lives in the record; a ledger
            // that cannot answer never means "allowed".
            guard record.destinationChoiceRequired == true else { return true }
            guard let store else { return false }
            return store.autoImportIsCleared(for: record)
        }
        shareCenter.configureDestinationHandler(self)

        shareCancellable = shareCenter.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.observeArrivals() }
            }
        documentCancellable = documentCenter.$queueSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.observeArrivals() }
            }

        Task { await recoveryPass() }
        Task { await observeArrivals() }
    }

    /// Canvas picker data (read-only, complete list). The picker still
    /// offers New Canvas on load failure/retry; nothing is clipped here.
    func loadCanvasImportTargets() throws -> [CanvasImportTarget] {
        guard let canvas else { throw ImportTargetLoadError.unavailable }
        return try canvas.canvasImportTargets()
    }

    /// Task picker data (read-only, complete list, newest first). A store
    /// failure throws instead of masquerading as an empty task list.
    func loadTaskImportTargets() async throws -> [TaskImportTarget] {
        guard let taskProvider else { throw ImportTargetLoadError.unavailable }
        return try await taskProvider.taskImportTargets()
    }

    /// Card-menu snapshot (never throws; see protocol doc).
    func canvasImportTargets() -> [CanvasImportTarget] {
        (try? canvas?.canvasImportTargets()) ?? []
    }

    // MARK: Presentation (peek / confirm — never consumed unseen)

    /// Peeks the oldest request WITHOUT consuming it. A scene that cannot
    /// present right now (voice modal, Settings, another document modal)
    /// simply does not take it: nothing is marked presented and the entry
    /// stays reachable. Consumption happens only in `confirmPresentation`,
    /// after the chooser actually appeared.
    func peekDestinationRequest() -> ImportDestinationRequest? {
        pendingRequests.first
    }

    /// The scene that owns the peeked request will present it now.
    func beginPresentation() {
        lastActionMessage = nil
    }

    /// Called from the chooser's `onAppear`: only now is the entry's
    /// current source state considered presented for this process.
    func confirmPresentation(_ request: ImportDestinationRequest) {
        presentationTokens[request.origin] = request.sourceUpdated
        dequeue(request.origin)
    }

    /// The user closed the chooser without choosing. Nothing was created.
    /// For a document event this uses the EXISTING queue cancellation so
    /// the entry is visible in the document banner (retry / discard) and a
    /// retry re-arms exactly one fresh choice; the staged input and the
    /// original file stay untouched. Envelopes stay pending for the Home
    /// share card, which offers all three destinations.
    func cancelPresentation(_ request: ImportDestinationRequest) {
        // A completed choice (or its sheet dismissal afterwards) must never
        // cancel the source the destination now owns.
        guard !settledOrigins.contains(request.origin) else { return }
        guard !handledCancellations.contains(request.id) else { return }
        handledCancellations.insert(request.id)
        dequeue(request.origin)
        // The presented source state is now consumed for THIS process; a
        // queue retry advances `updatedAt` and re-arms exactly one fresh
        // choice.
        presentationTokens[request.origin] = request.sourceUpdated
        lastActionMessage = nil
        switch request.origin {
        case .shareEnvelope:
            // Explicitly deferred by the user: no re-presentation this
            // process, but the Home share card stays the durable surface.
            settledOrigins.insert(request.origin)
        case .documentEvent(let eventID):
            if store?.load(.documentEvent(eventID))?.status == .canvas {
                // A retained Canvas operation may already have side effects
                // in the target. Cancelling the view must never cancel or
                // delete the source out from under it; both stay pending
                // until the same operation settles.
                break
            }
            // Use the EXISTING queue cancellation. The entry becomes a
            // banner-visible cancelled record; its Retry action advances
            // `updatedAt`, which re-arms exactly one fresh choice. Do NOT
            // settle the origin, or the retry path would be unreachable.
            settledOrigins.remove(request.origin)
            presentationTokens.removeValue(forKey: request.origin)
            let center = documentCenter
            Task { [weak center] in
                await center?.cancel(eventID)
            }
        }
    }

    /// A choice completed durably; a later dismissal must not cancel.
    func presentationResolved(_ request: ImportDestinationRequest) {
        dequeue(request.origin)
        settledOrigins.insert(request.origin)
    }

    private func dequeue(_ origin: ImportDestinationOrigin) {
        guard let index = pendingRequests.firstIndex(where: { $0.origin == origin }) else { return }
        pendingRequests.remove(at: index)
        publishHead()
    }

    private func publishHead() {
        destinationRequest = pendingRequests.first
    }

    private func enqueue(_ request: ImportDestinationRequest, front: Bool = false) {
        guard !settledOrigins.contains(request.origin),
              presentationTokens[request.origin] != request.sourceUpdated,
              !pendingRequests.contains(where: { $0.origin == request.origin }) else { return }
        if front {
            pendingRequests.insert(request, at: 0)
        } else {
            pendingRequests.append(request)
        }
        publishHead()
    }

    /// Deep-link arrival focuses its own envelope first.
    func observeShareArrival(focusedEnvelopeID: UUID?) async {
        await observeArrivals()
        if let focusedEnvelopeID {
            let origin = ImportDestinationOrigin.shareEnvelope(focusedEnvelopeID)
            if let index = pendingRequests.firstIndex(where: { $0.origin == origin }), index > 0 {
                let request = pendingRequests.remove(at: index)
                pendingRequests.insert(request, at: 0)
                publishHead()
            }
        }
    }

    private func observeArrivals() async {
        await cleanupDecisions()
        let envelopes = try? pendingEnvelopesOrThrow()
        if let envelopes {
            for envelope in envelopes {
                let origin = ImportDestinationOrigin.shareEnvelope(envelope.id)
                // A durable Notes/Task decision replaces the offer. A
                // retained Canvas decision (failed side-effect-safe retry)
                // may still be offered so the user can retry or explicitly
                // re-choose; the per-state presentation token stops nagging.
                if let decision = store?.load(origin), decision.status != .canvas { continue }
                let summary = ShareIntakeCenter.summary(for: envelope)
                enqueue(ImportDestinationRequest(
                    id: UUID(),
                    origin: origin,
                    itemCount: envelope.items.count,
                    fileNames: summary.fileNames,
                    includesText: !envelope.textItems.isEmpty,
                    sourceUpdated: envelope.createdAt
                ))
            }
        }
        let records = documentCenter?.queueSnapshot.records ?? []
        for record in records where record.state == .pending
            && record.destinationChoiceRequired == true {
            let origin = ImportDestinationOrigin.documentEvent(record.id)
            if let decision = store?.load(origin), decision.status != .canvas { continue }
            enqueue(ImportDestinationRequest(
                id: UUID(),
                origin: origin,
                itemCount: 1,
                fileNames: [record.displayName],
                includesText: false,
                sourceUpdated: record.updatedAt
            ))
        }
    }

    /// Prunes ONLY after an authoritative absence check. An inbox read
    /// failure or an unloaded/failed queue never means "the source is gone":
    /// decisions, planned canvas/node identities and staged sources all
    /// survive until a real settlement or proven absence.
    private func cleanupDecisions() async {
        guard let store else { return }
        let envelopeSet: Set<UUID>?
        if let list = try? pendingEnvelopesOrThrow() {
            envelopeSet = Set(list.map(\.id))
        } else {
            envelopeSet = nil
        }
        let queue = documentCenter?.queue
        for decision in store.all() {
            switch decision.origin {
            case .shareEnvelope(let id):
                guard let envelopeSet else { continue }
                if !envelopeSet.contains(id) {
                    store.remove(decision.origin)
                    presentationTokens.removeValue(forKey: decision.origin)
                    settledOrigins.remove(decision.origin)
                }
            case .documentEvent(let id):
                guard let queue else { continue }
                let record: DocumentIntakeRecord?
                do {
                    record = try await queue.record(id: id)
                } catch {
                    continue
                }
                if record == nil || record?.state == .committed {
                    // A Task conversion still waiting on its confirmed
                    // existing-task apply keeps its decision while the
                    // envelope exists (or the existence read failed).
                    if decision.status == .task,
                       decision.taskTarget?.conversationID != nil,
                       let envelopeID = decision.envelopeID,
                       envelopeSet.map({ $0.contains(envelopeID) }) ?? true {
                        continue
                    }
                    store.remove(decision.origin)
                }
            }
        }
    }

    // MARK: Recovery

    private func recoveryPass() async {
        guard let store else {
            documentCenter?.resumeDraining()
            await observeArrivals()
            return
        }
        let envelopes: [ShareEnvelope]
        do {
            envelopes = try pendingEnvelopesOrThrow()
        } catch {
            // Untrusted read: touch no decisions, identities or sources.
            documentCenter?.resumeDraining()
            await observeArrivals()
            return
        }
        for decision in store.all() {
            switch (decision.origin, decision.status) {
            case (.shareEnvelope(let id), .notes):
                guard envelopes.contains(where: { $0.id == id }) else { continue }
                _ = await executeNotesImport(envelopeID: id)
            case (.shareEnvelope(let id), .canvas):
                guard envelopes.contains(where: { $0.id == id }) else { continue }
                _ = await runCanvasCommit(
                    envelopeID: id,
                    decision: decision,
                    envelopeHint: nil
                )
            case (.shareEnvelope(let id), .task):
                guard let conversationID = decision.taskTarget?.conversationID,
                      let envelope = envelopes.first(where: { $0.id == id }) else { continue }
                _ = await applyEnvelopeToTaskDestination(
                    envelope: envelope,
                    conversationID: conversationID
                )
            case (.documentEvent(let id), .task):
                await continueEventTaskHandoff(eventID: id, decision: decision, envelopes: envelopes)
            case (.documentEvent(let id), .canvas):
                _ = await runEventCanvasCommit(eventID: id, decision: decision)
            case (.documentEvent, .notes):
                break // released to the queue's own drain below
            }
        }
        documentCenter?.resumeDraining()
        await observeArrivals()
    }

    /// A crash between the envelope commit and the queue-record removal
    /// leaves both durable; the envelope already owns the bytes, so only
    /// the source removal is repeated. Never re-stages. When the decision
    /// also carries a confirmed existing-task follow-up, the apply runs
    /// before the decision settles.
    private func continueEventTaskHandoff(
        eventID: UUID,
        decision: ImportDestinationDecision,
        envelopes: [ShareEnvelope]
    ) async {
        guard let store, let queue = documentCenter?.queue else { return }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        guard let envelopeID = decision.envelopeID else {
            // The decision predates staging (crash right after the choice).
            // Re-run the same confirmed conversion; staging is a fresh
            // envelope and the source record is still pending and untouched.
            _ = await convertEventToTask(
                eventID: eventID,
                target: decision.taskTarget ?? .newTask
            )
            return
        }
        if envelopes.contains(where: { $0.id == envelopeID }) {
            _ = await finishEventTaskHandoff(
                envelopeID: envelopeID,
                eventID: eventID,
                decision: decision
            )
            return
        }
        // The named envelope never reached the active namespace.
        if let target = decision.taskTarget, target.conversationID != nil {
            var retry = decision
            retry.envelopeID = nil
            _ = try? store.save(retry)
            _ = await convertEventToTask(eventID: eventID, target: target)
        } else {
            store.remove(origin)
        }
    }

    private func finishEventTaskHandoff(
        envelopeID: UUID,
        eventID: UUID,
        decision: ImportDestinationDecision
    ) async -> ImportDestinationResult {
        guard let inbox, let store, let queue = documentCenter?.queue else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        _ = try? await queue.discard(id: eventID)
        await documentCenter?.refreshSnapshot()
        if let conversationID = decision.taskTarget?.conversationID {
            let envelopes: [ShareEnvelope]
            do {
                envelopes = try pendingEnvelopesOrThrow()
            } catch {
                return .deferred
            }
            guard let envelope = envelopes.first(where: { $0.id == envelopeID }) else {
                return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
            }
            let result = await applyEnvelopeToTaskDestination(
                envelope: envelope,
                conversationID: conversationID
            )
            switch result {
            case .taskReady:
                store.remove(origin)
            default:
                break // decision held; the next recovery/observation pass retries
            }
            return result
        }
        // New Task completion of a converted event: the share marker may have
        // been lost in the crash window. Re-persist it (idempotent) so Home
        // consumes exactly once, then signal.
        if store.load(.shareEnvelope(envelopeID)) == nil {
            _ = try? store.save(ImportDestinationDecision(
                origin: .shareEnvelope(envelopeID),
                status: .task,
                chosenAt: decision.chosenAt ?? now(),
                taskTarget: .newTask,
                updatedAt: now()
            ))
        }
        store.remove(origin)
        confirmedNewTaskRevision += 1
        return .taskReady(target: decision.taskTarget ?? .newTask)
    }

    /// One Task destination action for an envelope against a confirmed
    /// existing persisted task, through the SAME reviewed apply pipeline
    /// (claim → staging → CAS commitDurable + receipt → ack). No navigation,
    /// no send, no other conversation touched.
    private func applyEnvelopeToTaskDestination(
        envelope: ShareEnvelope,
        conversationID: UUID
    ) async -> ImportDestinationResult {
        guard let shareCenter, let taskProvider else {
            return .failed(message: ledgerMessage)
        }
        guard await taskProvider.isTaskTargetAvailable(conversationID) else {
            return .failed(message: FloeL10n.l("app.entry.task_unavailable"))
        }
        let destination = ConversationDraftDestination(conversationID: conversationID)
        let outcome = await shareCenter.apply(envelope, to: destination)
        switch outcome {
        case .applied, .alreadyApplied:
            return .taskReady(target: .existing(conversationID: conversationID))
        case .deferred(_, let reason):
            switch reason {
            case .unavailable:
                return .failed(message: FloeL10n.l("app.entry.task_unavailable"))
            default:
                return .deferred
            }
        case .failed(let id, let message):
            _ = id
            return .failed(message: message)
        case .discarded, .empty:
            return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
        }
    }

    // MARK: Explicit choice

    /// Runs the chosen destination for one request. `.taskReady` /
    /// `.canvasReady` mean the scene MAY now act (navigate); arrival alone
    /// never reaches that. `canvasTarget` is required for `.canvas` (the
    /// compact picker confirms it before any copy).
    func perform(
        _ destination: ImportDestination,
        for request: ImportDestinationRequest,
        canvasTarget: CanvasDestinationTarget? = nil,
        taskTarget: TaskDestinationTarget? = nil
    ) async -> ImportDestinationResult {
        guard !isResolving else {
            lastActionMessage = FloeL10n.l("share.intake.deferred_busy")
            return .deferred
        }
        isResolving = true
        lastActionMessage = nil
        let result: ImportDestinationResult
        switch (destination, request.origin) {
        case (.task, .shareEnvelope(let envelopeID)):
            result = await importEnvelopeToTask(
                envelopeID: envelopeID,
                target: taskTarget ?? .newTask
            )
        case (.task, .documentEvent(let eventID)):
            result = await convertEventToTask(
                eventID: eventID,
                target: taskTarget ?? .newTask
            )
        case (.notes, .shareEnvelope(let envelopeID)):
            switch await executeNotesImport(envelopeID: envelopeID) {
            case .imported(_, let count): result = .notesImported(documentCount: count)
            case .settled: result = .notesImported(documentCount: 0)
            case .deferredBusy: result = .deferred
            case .unavailable: result = .failed(message: FloeL10n.l("app.entry.share_unavailable"))
            case .failed(_, let message):
                result = .failed(message: message ?? FloeL10n.l("share.intake.failed"))
            case nil: result = .failed(message: ledgerMessage)
            }
        case (.notes, .documentEvent(let eventID)):
            result = resolveEventToNotes(eventID: eventID)
        case (.canvas, .shareEnvelope(let envelopeID)):
            result = mapCanvasRun(await executeEnvelopeCanvasChoice(
                envelopeID: envelopeID,
                target: canvasTarget
            ))
        case (.canvas, .documentEvent(let eventID)):
            result = await executeEventCanvasChoice(eventID: eventID, target: canvasTarget)
        }
        switch result {
        case .deferred:
            lastActionMessage = FloeL10n.l("share.intake.deferred_busy")
        case .failed(let message):
            lastActionMessage = message
        default:
            lastActionMessage = nil
            presentationResolved(request)
        }
        isResolving = false
        Task {
            await self.documentCenter?.refreshSnapshot()
            await self.observeArrivals()
        }
        return result
    }

    private func mapCanvasRun(_ outcome: CanvasRunOutcome) -> ImportDestinationResult {
        switch outcome {
        case .committed(let count): return .canvasReady(itemCount: count)
        case .settled: return .canvasReady(itemCount: 0)
        case .deferred: return .deferred
        case .failed(let message): return .failed(message: message)
        }
    }

    private var ledgerMessage: String {
        FloeL10n.l("import.destination.storage_unavailable")
    }

    private func resolveEventToNotes(eventID: UUID) -> ImportDestinationResult {
        guard let store else { return .failed(message: ledgerMessage) }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        var decision = store.load(origin)
        if decision == nil {
            decision = ImportDestinationDecision(
                origin: origin, status: .notes, chosenAt: now(), updatedAt: now()
            )
        } else {
            decision?.status = .notes
            decision?.chosenAt = now()
        }
        do {
            _ = try store.save(decision!)
        } catch {
            // A choice that cannot be persisted durably must not start an
            // import: the record stays gated and recoverable.
            return .failed(message: ledgerMessage)
        }
        documentCenter?.resumeDraining()
        return .notesQueued
    }

    /// Home-owned consumption point: applies EVERY envelope whose explicit
    /// destination choice was New Task, through the existing reviewed
    /// durable pipeline (claim → staging → commitDurable + envelope-bound
    /// receipt → ack), preserving the current Home draft and never sending
    /// or running. The primary wires this as ONE added line in
    /// HomeLaunchpadView's existing intake `.task` (see handoff
    /// INTEGRATION.md); the ShareIntakeCard then remains only the fallback
    /// for a momentarily busy composer. Returns nil when no confirmed
    /// envelope exists; the last real outcome is returned otherwise.
    @discardableResult
    func applyConfirmedNewTaskEnvelopes(to destination: any ShareIntakeDestination) async -> ShareIntakeOutcome? {
        guard let shareCenter, let store else { return nil }
        var last: ShareIntakeOutcome?
        for envelope in shareCenter.pending {
            guard let decision = store.load(.shareEnvelope(envelope.id)),
                  decision.status == .task,
                  decision.taskTarget == .newTask else { continue }
            let outcome = await shareCenter.apply(envelope, to: destination)
            last = outcome
            switch outcome {
            case .applied, .alreadyApplied, .discarded:
                continue
            case .deferred(_, let reason):
                switch reason {
                case .composerBusy, .anotherShareInProgress:
                    return last   // retry on the next Home appearance or via the card
                case .cancelled, .unavailable:
                    return last
                }
            case .failed:
                return last
            case .empty:
                break
            }
        }
        return last
    }

    // MARK: share envelope → Notes (durable planned identities)

    /// Card action entry: identical executor to the sheet choice, so the
    /// per-item planned-document proof is shared, never duplicated logic.
    func importEnvelopeToNotes(_ envelope: ShareEnvelope) async -> ShareNotesImportResult {
        guard let result = await executeNotesImport(envelopeID: envelope.id) else {
            return .unavailable
        }
        shareCenter?.destinationImportFinished(destination: .notes, result: result)
        return result
    }

    func importEnvelopeToCanvas(
        _ envelope: ShareEnvelope,
        target: CanvasDestinationTarget
    ) async -> ShareNotesImportResult {
        guard inbox != nil, store != nil, canvas != nil else { return .unavailable }
        let outcome = await executeEnvelopeCanvasChoice(
            envelopeID: envelope.id,
            target: target,
            envelopeHint: envelope
        )
        let result: ShareNotesImportResult
        switch outcome {
        case .committed(let count):
            result = .imported(envelopeID: envelope.id, documentCount: count)
        case .settled:
            result = .settled(envelopeID: envelope.id)
        case .deferred:
            result = .deferredBusy(envelopeID: envelope.id)
        case .failed(let message):
            result = .failed(envelopeID: envelope.id, message: message)
        }
        shareCenter?.destinationImportFinished(destination: .canvas, result: result)
        return result
    }

    /// nil return means the App Group inbox or the durable ledger is
    /// unavailable.
    private func executeNotesImport(envelopeID: UUID) async -> ShareNotesImportResult? {
        guard let inbox, let store else { return nil }
        let origin = ImportDestinationOrigin.shareEnvelope(envelopeID)

        var decision = store.load(origin)
        if decision?.status == .canvas || decision?.status == .task {
            // Explicit "Import to Notes" re-choice after a retained Canvas
            // attempt or any Task marker: the user action starts a fresh
            // Notes plan. Canvas side effects (if any were created) are
            // user-owned content; this path never implies them and never
            // acks the canvas operation. A concurrent apply/commit is
            // excluded by the exclusive envelope claim.
            decision = nil
        }
        if decision == nil {
            guard let envelope = (try? inbox.pending(now: now()))?
                .first(where: { $0.id == envelopeID }) else {
                return .failed(envelopeID: envelopeID, message: FloeL10n.l("app.entry.share_unavailable"))
            }
            guard let units = planNotesUnits(for: envelope), !units.isEmpty else {
                return .failed(envelopeID: envelopeID, message: FloeL10n.l("share.intake.failed"))
            }
            let planned = ImportDestinationDecision(
                origin: origin,
                status: .notes,
                chosenAt: now(),
                units: units,
                updatedAt: now()
            )
            do {
                decision = try store.save(planned)
            } catch {
                // Without the durable plan the import must not start: a lost
                // plan would make a retry duplicate Notes.
                return .failed(envelopeID: envelopeID, message: ledgerMessage)
            }
        }
        guard let decision, decision.status == .notes else {
            return .deferredBusy(envelopeID: envelopeID)
        }

        // Exclusive claim verifies digests; that I/O stays off the main actor.
        let claimTime = now()
        let claim: ShareInboxClaim
        do {
            claim = try await Task.detached(priority: .userInitiated) {
                try inbox.claim(id: envelopeID, now: claimTime)
            }.value
        } catch ShareInboxError.claimBusy {
            return .deferredBusy(envelopeID: envelopeID)
        } catch ShareInboxError.envelopeNotFound {
            store.remove(origin)
            return .settled(envelopeID: envelopeID)
        } catch {
            return .failed(envelopeID: envelopeID, message: FloeL10n.l("share.intake.failed"))
        }

        var current = decision
        do {
            for index in current.units.indices where current.units[index].committedAt == nil {
                try await importUnit(
                    current.units[index],
                    claim: claim,
                    markCommitted: { date in
                        current.units[index].committedAt = date
                        // Persisting the proof is best-effort here: the
                        // planned id itself is already durable, and a later
                        // pass proves the commit via `existingDocument`.
                        _ = try? store.save(current)
                    }
                )
            }
        } catch let failure as NotesImportUnitError {
            try? inbox.release(claim)
            return .failed(envelopeID: envelopeID, message: failure.message ?? FloeL10n.l("share.intake.failed"))
        } catch {
            try? inbox.release(claim)
            return .failed(envelopeID: envelopeID, message: FloeL10n.l("share.intake.failed"))
        }

        // Every Notes commit is proven durable. Only now the source leaves
        // the active namespace.
        return await settleClaimedEnvelope(
            claim: claim,
            origin: origin,
            inbox: inbox,
            store: store,
            envelopeID: envelopeID,
            unitCount: current.units.count
        )
    }

    /// Acknowledges a fully-committed envelope and settles the ledger; a
    /// failed ack keeps the durable decision so a later pass settles from
    /// the planned identities without re-importing.
    private func settleClaimedEnvelope(
        claim: ShareInboxClaim,
        origin: ImportDestinationOrigin,
        inbox: ShareInbox,
        store: ImportDestinationDecisionStore,
        envelopeID: UUID,
        unitCount: Int
    ) async -> ShareNotesImportResult {
        var cleanupPending = false
        do {
            try inbox.ack(claim)
        } catch {
            try? inbox.release(claim)
            cleanupPending = true
            FloeLogger(category: .app).error(
                "importDestinationAckPending envelope=\(envelopeID.uuidString.prefix(8))"
            )
        }
        if !cleanupPending {
            store.remove(origin)
        }
        await shareCenter?.refresh()
        return .imported(envelopeID: envelopeID, documentCount: unitCount)
    }

    private func importUnit(
        _ unit: ImportDestinationDecision.Unit,
        claim: ShareInboxClaim,
        markCommitted: @MainActor (Date) -> Void
    ) async throws {
        // The planned identity is the only proof used.
        guard let plannedDocumentID = unit.plannedDocumentID else {
            throw NotesImportUnitError(message: FloeL10n.l("share.intake.failed"))
        }
        do {
            if let existing = try await notes.existingDocument(id: plannedDocumentID) {
                _ = existing
                markCommitted(now())
                return
            }
        } catch {
            throw NotesImportUnitError(message: FloeL10n.l("share.intake.unavailable"))
        }

        let envelope = claim.envelope
        if unit.key == Self.textUnitKey {
            guard let staged = try await stageTextUnit(of: envelope) else {
                throw NotesImportUnitError(message: FloeL10n.l("share.intake.failed"))
            }
            defer { try? FileManager.default.removeItem(at: staged.directory) }
            let outcome = try await notes.importNotes(
                from: staged.fileURL,
                kind: .text,
                plannedRootID: plannedDocumentID,
                displayName: staged.title
            )
            guard outcome.rootDocumentID == plannedDocumentID else {
                throw NotesImportUnitError(message: FloeL10n.l("share.intake.failed"))
            }
            markCommitted(now())
            return
        }

        guard let item = envelope.items.first(where: { $0.storageName == unit.key }),
              let kind = Self.notesKind(for: item),
              kind.requiresDestinationChoice || kind == .floeNote,
              let url = try? inbox?.payloadURL(for: item, in: envelope) else {
            throw NotesImportUnitError(message: FloeL10n.l("share.intake.failed"))
        }
        let outcome = try await notes.importNotes(
            from: url,
            kind: kind,
            plannedRootID: plannedDocumentID,
            displayName: item.fileName ?? ""
        )
        guard outcome.rootDocumentID == plannedDocumentID else {
            throw NotesImportUnitError(message: FloeL10n.l("share.intake.failed"))
        }
        markCommitted(now())
    }

    private func planNotesUnits(for envelope: ShareEnvelope) -> [ImportDestinationDecision.Unit]? {
        var units: [ImportDestinationDecision.Unit] = []
        for item in envelope.attachmentItems {
            guard let storageName = item.storageName,
                  let kind = Self.notesKind(for: item),
                  // Own-format canvas restores do not belong to the Notes
                  // importer; treating one as a plain document would corrupt
                  // its meaning. Share + canvas + Notes is an explicit stop.
                  kind != .floeCanvas else { return nil }
            units.append(.init(key: storageName, plannedDocumentID: UUID()))
        }
        if joinedText(of: envelope) != nil {
            units.append(.init(key: Self.textUnitKey, plannedDocumentID: UUID()))
        }
        return units.isEmpty ? nil : units
    }

    private func joinedText(of envelope: ShareEnvelope) -> String? {
        let text = envelope.textItems.compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private struct StagedTextUnit {
        let directory: URL
        let fileURL: URL
        let title: String
    }

    private func stageTextUnit(of envelope: ShareEnvelope) async throws -> StagedTextUnit? {
        guard let text = joinedText(of: envelope) else { return nil }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-text-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("shared-text.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return StagedTextUnit(
            directory: tempRoot,
            fileURL: fileURL,
            title: String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        )
    }

    static func notesKind(for item: ShareInboxItem) -> DocumentIntakeKind? {
        let fileExtension = (item.fileName as NSString?)?.pathExtension ?? ""
        let contentType = item.typeIdentifier.flatMap { UTType($0) }
        return DocumentIntakeKind.classify(fileExtension: fileExtension, contentType: contentType)
    }

    // MARK: → Canvas (durable operation identity; retain on failure)

    /// Authoritative envelope listing. A read FAILURE must never be read as
    /// "all sources disappeared": callers either act on the real list or
    /// keep decisions, identities and staged sources exactly as they are.
    private func pendingEnvelopesOrThrow() throws -> [ShareEnvelope] {
        guard let inbox else { throw ShareInboxError.appGroupUnavailable }
        return try inbox.pending(now: now())
    }

    private enum CanvasRunOutcome: Equatable {
        case committed(itemCount: Int)
        case settled
        case deferred
        case failed(message: String)
    }

    private func runCanvasCommit(
        envelopeID: UUID,
        decision: ImportDestinationDecision,
        envelopeHint: ShareEnvelope?
    ) async -> CanvasRunOutcome {
        guard let inbox, let store, let canvas else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.shareEnvelope(envelopeID)
        let claimTime = now()
        let claim: ShareInboxClaim
        do {
            claim = try await Task.detached(priority: .userInitiated) {
                try inbox.claim(id: envelopeID, now: claimTime)
            }.value
        } catch ShareInboxError.claimBusy {
            return .deferred
        } catch ShareInboxError.envelopeNotFound {
            // Authoritative absence: the envelope already left the active
            // namespace (ack raced a restart). The ledger record goes with it.
            store.remove(origin)
            return .settled
        } catch {
            return .failed(message: FloeL10n.l("share.intake.failed"))
        }

        let plans: [CanvasImportUnitPlan]
        var tempDirectories: [URL] = []
        defer {
            // Registered at function scope so the staged text file outlives
            // commitImport and is cleaned exactly once per attempt.
            for directory in tempDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do {
            let built = try await canvasUnitPlans(for: claim.envelope, decision: decision)
            plans = built.plans
            tempDirectories = built.tempDirectories
        } catch {
            try? inbox.release(claim)
            // Keep the decision: planned identities already persisted must
            // survive any recoverable failure for the SAME retry operation.
            return .failed(message: FloeL10n.l("share.intake.failed"))
        }
        if plans.isEmpty {
            // Every unit is already proven committed (crash between the
            // proof save and the ack): settle without touching Canvas again.
            let settle = await settleClaimedEnvelope(
                claim: claim,
                origin: origin,
                inbox: inbox,
                store: store,
                envelopeID: envelopeID,
                unitCount: decision.units.count
            )
            switch settle {
            case .imported(_, let count): return .committed(itemCount: count)
            case .settled: return .settled
            case .deferredBusy: return .deferred
            case .failed(_, let message): return .failed(message: message ?? FloeL10n.l("share.intake.failed"))
            case .unavailable: return .failed(message: ledgerMessage)
            }
        }
        let operation = CanvasImportOperation(
            operationID: decision.canvasOperationID ?? UUID(),
            originID: envelopeID,
            target: decision.canvasTarget ?? .newCanvas,
            plannedNewCanvasID: decision.plannedCanvasID,
            units: plans
        )
        switch await canvas.commitImport(operation) {
        case .committed(let canvasID, let nodeIDs):
            let plannedNodeIDs = Set(plans.map(\.plannedNodeID))
            guard plannedNodeIDs.isSubset(of: Set(nodeIDs)) else {
                // Contract violation: proven coverage is missing. Do NOT ack;
                // identities stay intact for the next same-operation attempt.
                try? inbox.release(claim)
                return .failed(message: FloeL10n.l("share.intake.failed"))
            }
            var proven = decision
            proven.canvasTarget = operation.target
            proven.plannedCanvasID = proven.plannedCanvasID ?? (operation.target.canvasID == nil ? canvasID : nil)
            proven.canvasOperationID = operation.operationID
            proven.units = proven.units.map { unit in
                var updated = unit
                if let nodeID = unit.plannedNodeID, nodeIDs.contains(nodeID) {
                    updated.committedAt = now()
                }
                return updated
            }
            _ = try? store.save(proven)
            _ = canvasID // resolved canvas is the committer's receipt scope
            let settle = await settleClaimedEnvelope(
                claim: claim,
                origin: origin,
                inbox: inbox,
                store: store,
                envelopeID: envelopeID,
                unitCount: plans.count
            )
            switch settle {
            case .imported(_, let count): return .committed(itemCount: count)
            case .settled: return .settled
            case .deferredBusy: return .deferred
            case .failed(_, let message): return .failed(message: message ?? FloeL10n.l("share.intake.failed"))
            case .unavailable: return .failed(message: ledgerMessage)
            }
        case .failed(let message):
            // Recoverable failure — including "nodes CAS-committed then
            // bookkeeping failed": we release the claim, KEEP the decision
            // and every planned canvas/node identity, and only ever retry
            // the SAME operation. An explicit destination re-choice is a
            // separate user action, never inferred from this error.
            try? inbox.release(claim)
            return .failed(message: message ?? FloeL10n.l("share.intake.failed"))
        }
    }

    /// Builds the copy plan from the PERSISTED ledger units: node ids are
    /// the already-durable planned identities, never regenerated here.
    /// Returns the plans plus any temp directories this call created (the
    /// joined text unit), so the caller can clean exactly those.
    private func canvasUnitPlans(
        for envelope: ShareEnvelope,
        decision: ImportDestinationDecision
    ) async throws -> (plans: [CanvasImportUnitPlan], tempDirectories: [URL]) {
        guard let inbox else { throw ShareInboxError.appGroupUnavailable }
        var plans: [CanvasImportUnitPlan] = []
        var tempDirectories: [URL] = []
        for unit in decision.units {
            guard unit.committedAt == nil else { continue }
            guard let plannedNodeID = unit.plannedNodeID else {
                throw ShareInboxError.invalidEnvelope(reason: "canvasPlan")
            }
            if unit.key == Self.textUnitKey {
                guard let staged = try await stageTextUnit(of: envelope) else {
                    throw ShareInboxError.emptyEnvelope
                }
                tempDirectories.append(staged.directory)
                plans.append(.init(
                    key: unit.key,
                    displayName: staged.title,
                    payloadURL: staged.fileURL,
                    plannedNodeID: plannedNodeID
                ))
                continue
            }
            guard let item = envelope.items.first(where: { $0.storageName == unit.key }),
                  let url = try? inbox.payloadURL(for: item, in: envelope) else {
                throw ShareInboxError.invalidEnvelope(reason: "canvasPlan")
            }
            plans.append(.init(
                key: unit.key,
                displayName: item.fileName ?? unit.key,
                payloadURL: url,
                plannedNodeID: plannedNodeID
            ))
        }
        // A settled decision (all units committed, ack still pending) reruns
        // with no open units; the caller treats empty plans as "prove &
        // settle" rather than an error.
        return (plans, tempDirectories)
    }

    private func planCanvasUnits(
        for envelope: ShareEnvelope
    ) -> [ImportDestinationDecision.Unit]? {
        var units: [ImportDestinationDecision.Unit] = []
        for item in envelope.attachmentItems {
            guard let storageName = item.storageName else { return nil }
            units.append(.init(key: storageName, plannedNodeID: UUID()))
        }
        if joinedText(of: envelope) != nil {
            units.append(.init(key: Self.textUnitKey, plannedNodeID: UUID()))
        }
        return units.isEmpty ? nil : units
    }

    /// Envelope choice: the operation identity (operationID, planned node
    /// ids, planned new-canvas id) is persisted BEFORE any copy; a proven
    /// full commit is the only result that acknowledges the source.
    private func executeEnvelopeCanvasChoice(
        envelopeID: UUID,
        target: CanvasDestinationTarget?,
        envelopeHint: ShareEnvelope? = nil
    ) async -> CanvasRunOutcome {
        guard let store, canvas != nil, inbox != nil else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.shareEnvelope(envelopeID)
        var decision = store.load(origin)
        if decision?.status != .canvas {
            if let decision, decision.status == .notes {
                // A Notes resume owns the plan; do not overwrite mid-import.
                return .deferred
            }
            let envelope: ShareEnvelope
            do {
                if let envelopeHint {
                    envelope = envelopeHint
                } else {
                    guard let found = try pendingEnvelopesOrThrow()
                        .first(where: { $0.id == envelopeID }) else {
                        return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
                    }
                    envelope = found
                }
            } catch {
                return .deferred // read failure: keep everything as it was
            }
            guard let units = planCanvasUnits(for: envelope) else {
                return .failed(message: FloeL10n.l("share.intake.failed"))
            }
            let chosenTarget = target ?? .newCanvas
            let planned = ImportDestinationDecision(
                origin: origin,
                status: .canvas,
                chosenAt: now(),
                units: units,
                canvasTarget: chosenTarget,
                canvasOperationID: UUID(),
                plannedCanvasID: chosenTarget.canvasID == nil ? UUID() : nil,
                updatedAt: now()
            )
            do {
                decision = try store.save(planned)
            } catch {
                // The choice cannot be recorded durably: NO copy may start.
                return .failed(message: ledgerMessage)
            }
        }
        guard let decision, decision.status == .canvas else {
            return .failed(message: ledgerMessage)
        }
        // Retained decisions keep THEIR persisted target: an explicit
        // retry re-runs the same operation; a different target requires a
        // fresh choice flow (a new decision after settlement/removal).
        return await runCanvasCommit(
            envelopeID: envelopeID,
            decision: decision,
            envelopeHint: envelopeHint
        )
    }

    private func executeEventCanvasChoice(
        eventID: UUID,
        target: CanvasDestinationTarget?
    ) async -> ImportDestinationResult {
        guard let store, canvas != nil, let queue = documentCenter?.queue else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        var decision = store.load(origin)
        if let decision, decision.status == .task { return .deferred }
        if decision?.status != .canvas {
            let staged: (record: DocumentIntakeRecord, payloadURL: URL)?
            do { staged = try await queue.pendingPayload(id: eventID) } catch { staged = nil }
            guard let record = staged?.record, record.state == .pending,
                  record.destinationChoiceRequired == true else {
                return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
            }
            let chosenTarget = target ?? .newCanvas
            let planned = ImportDestinationDecision(
                origin: origin,
                status: .canvas,
                chosenAt: now(),
                units: [.init(key: Self.eventFileUnitKey, plannedNodeID: UUID())],
                canvasTarget: chosenTarget,
                canvasOperationID: UUID(),
                plannedCanvasID: chosenTarget.canvasID == nil ? UUID() : nil,
                updatedAt: now()
            )
            do {
                decision = try store.save(planned)
            } catch {
                return .failed(message: ledgerMessage)
            }
        }
        guard let decision, decision.status == .canvas else {
            return .failed(message: ledgerMessage)
        }
        switch await runEventCanvasCommit(eventID: eventID, decision: decision) {
        case .committed(let count): return .canvasReady(itemCount: count)
        case .settled: return .canvasReady(itemCount: 0)
        case .deferred: return .deferred
        case .failed(let message): return .failed(message: message)
        }
    }

    /// Event → Canvas commit with the same retention rules as envelopes:
    /// only a proven full node commit may remove the source record.
    private func runEventCanvasCommit(
        eventID: UUID,
        decision: ImportDestinationDecision
    ) async -> CanvasRunOutcome {
        guard let canvas, let store, let queue = documentCenter?.queue else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        let staged: (record: DocumentIntakeRecord, payloadURL: URL)?
        do {
            staged = try await queue.pendingPayload(id: eventID)
        } catch {
            return .deferred // read failure: retain everything
        }
        guard let record = staged?.record, record.state == .pending,
              let payloadURL = staged?.payloadURL else {
            let authoritative: DocumentIntakeRecord?
            do { authoritative = try await queue.record(id: eventID) } catch { return .deferred }
            if authoritative == nil {
                // The record already left the queue while the decision was
                // retained (settled pass or expiry). Nothing else can act.
                store.remove(origin)
                return .settled
            }
            return .deferred
        }
        guard let plannedNodeID = decision.units.first?.plannedNodeID else {
            return .failed(message: FloeL10n.l("share.intake.failed"))
        }
        let operation = CanvasImportOperation(
            operationID: decision.canvasOperationID ?? UUID(),
            originID: eventID,
            target: decision.canvasTarget ?? .newCanvas,
            plannedNewCanvasID: decision.plannedCanvasID,
            units: [.init(
                key: Self.eventFileUnitKey,
                displayName: record.displayName,
                payloadURL: payloadURL,
                plannedNodeID: plannedNodeID
            )]
        )
        switch await canvas.commitImport(operation) {
        case .committed(let canvasID, let nodeIDs):
            guard nodeIDs.contains(plannedNodeID) else {
                return .failed(message: FloeL10n.l("share.intake.failed"))
            }
            var proven = decision
            proven.canvasOperationID = operation.operationID
            proven.plannedCanvasID = proven.plannedCanvasID
                ?? (operation.target.canvasID == nil ? canvasID : nil)
            proven.units = [.init(
                key: Self.eventFileUnitKey,
                plannedNodeID: plannedNodeID,
                committedAt: now()
            )]
            _ = try? store.save(proven)
            _ = try? await queue.discard(id: eventID)
            // If the removal above failed, the retained decision keeps the
            // gate closed and recovery repeats the idempotent operation.
            store.remove(origin)
            await documentCenter?.refreshSnapshot()
            return .committed(itemCount: 1)
        case .failed(let message):
            // Keep the decision and every planned identity. The source
            // record stays pending and recoverable; only real target
            // receipts release it.
            return .failed(message: message ?? FloeL10n.l("share.intake.failed"))
        }
    }

    // MARK: share envelope → Task (confirmed target persisted before copy)

    private func importEnvelopeToTask(
        envelopeID: UUID,
        target: TaskDestinationTarget
    ) async -> ImportDestinationResult {
        guard let store else { return .failed(message: ledgerMessage) }
        let origin = ImportDestinationOrigin.shareEnvelope(envelopeID)
        switch target {
        case .newTask:
            if store.load(origin) == nil {
                // The explicit New Task choice is persisted before
                // returning; Home then AUTO-APPLIES this envelope once
                // through the existing durable commit/receipt pipeline
                // (the reviewed card stays only as the fallback when the
                // draft is momentarily busy). No conversation row is
                // created here and nothing is sent or run.
                let marker = ImportDestinationDecision(
                    origin: origin,
                    status: .task,
                    chosenAt: now(),
                    taskTarget: .newTask,
                    updatedAt: now()
                )
                do {
                    _ = try store.save(marker)
                } catch {
                    return .failed(message: ledgerMessage)
                }
            }
            confirmedNewTaskRevision += 1
            return .taskReady(target: .newTask)
        case .existing(let conversationID):
            guard inbox != nil else { return .failed(message: ledgerMessage) }
            let envelope: ShareEnvelope
            do {
                guard let found = try pendingEnvelopesOrThrow()
                    .first(where: { $0.id == envelopeID }) else {
                    return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
                }
                envelope = found
            } catch {
                return .deferred // untrusted read: keep everything as it was
            }
            if store.load(origin) == nil {
                do {
                    _ = try store.save(ImportDestinationDecision(
                        origin: origin,
                        status: .task,
                        chosenAt: now(),
                        taskTarget: target,
                        updatedAt: now()
                    ))
                } catch {
                    return .failed(message: ledgerMessage)
                }
            }
            return await applyEnvelopeToTaskDestination(
                envelope: envelope,
                conversationID: conversationID
            )
        }
    }

    // MARK: document event → Task (envelope hand-off, never double-staged)

    private func convertEventToTask(
        eventID: UUID,
        target: TaskDestinationTarget
    ) async -> ImportDestinationResult {
        guard let inbox, let queue = documentCenter?.queue, let store else {
            return .failed(message: ledgerMessage)
        }
        let origin = ImportDestinationOrigin.documentEvent(eventID)
        let existing = store.load(origin)

        // A prior pass already committed the envelope: finish the hand-off
        // (and its confirmed existing-task follow-up) instead of staging a
        // second copy.
        if let existing, existing.status == .task, let envelopeID = existing.envelopeID {
            let envelopes: [ShareEnvelope]
            do {
                envelopes = try pendingEnvelopesOrThrow()
            } catch {
                return .deferred // untrusted read: never re-stage blindly
            }
            if envelopes.contains(where: { $0.id == envelopeID }) {
                return await finishEventTaskHandoff(
                    envelopeID: envelopeID,
                    eventID: eventID,
                    decision: existing
                )
            }
            // The named envelope never reached the active namespace.
            store.remove(origin)
        }

        guard let staged = try? await queue.pendingPayload(id: eventID),
              staged.record.state == .pending,
              staged.record.destinationChoiceRequired == true,
              staged.record.kind.requiresDestinationChoice else {
            return .failed(message: FloeL10n.l("app.entry.share_unavailable"))
        }

        let record = staged.record
        let payloadURL = staged.payloadURL
        let session: ShareInbox.StagingSession
        do {
            session = try inbox.beginStaging(producer: "Floe")
        } catch {
            return .failed(message: FloeL10n.l("share.intake.failed"))
        }

        let stagedDecision = ImportDestinationDecision(
            origin: origin,
            status: .task,
            chosenAt: now(),
            envelopeID: session.envelopeID,
            taskTarget: target,
            updatedAt: now()
        )
        do {
            _ = try store.save(stagedDecision)
        } catch {
            session.cancel()
            return .failed(message: ledgerMessage)
        }

        let envelope: ShareEnvelope
        do {
            try session.append(ShareInboxInput(
                kind: record.kind == .image ? .image : .file,
                payload: .file(payloadURL),
                displayName: record.displayName,
                typeIdentifier: record.contentTypeIdentifier ?? "public.data"
            ))
            envelope = try session.commit()
        } catch {
            session.cancel()
            // The choice was genuinely made, but its staging failed (an
            // over-capacity envelope item is the real case). Drop the
            // decision so the entry stays recoverable and can be chosen
            // again; the source record is untouched.
            store.remove(origin)
            presentationTokens.removeValue(forKey: origin)
            settledOrigins.remove(origin)
            let message = (error as? ShareInboxError)?.localizedDescription
                ?? FloeL10n.l("share.intake.failed")
            return .failed(message: message)
        }
        // The Task destination now owns a durable copy. Only the source
        // queue record may be removed after that point.
        _ = try? await queue.discard(id: eventID)
        await documentCenter?.refreshSnapshot()
        switch target {
        case .newTask:
            // Carry the confirmed choice over to the converted envelope so
            // Home's auto-apply path consumes it without a second confirm.
            _ = try? store.save(ImportDestinationDecision(
                origin: .shareEnvelope(envelope.id),
                status: .task,
                chosenAt: now(),
                taskTarget: .newTask,
                updatedAt: now()
            ))
            store.remove(origin)
            confirmedNewTaskRevision += 1
            return .taskReady(target: .newTask)
        case .existing(let conversationID):
            // Keep the decision until the existing-task apply is proven;
            // recovery completes it without ever re-staging.
            let result = await applyEnvelopeToTaskDestination(
                envelope: envelope,
                conversationID: conversationID
            )
            if case .taskReady = result {
                store.remove(origin)
            }
            return result
        }
    }
}

private struct NotesImportUnitError: Error {
    let message: String?
}

extension ImportDestinationCenter: ShareEnvelopeDestinationImporting {}
#endif
