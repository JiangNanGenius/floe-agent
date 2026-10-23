// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — app-owned system document-open intake (S5 P3).
//
// Lifecycle:
// * `submit` is called from the scene's `.onOpenURL` (or the App entry route
//   adapter). It starts materialization immediately, while the provider's
//   security-scoped access is valid, and persists the durable queue entry.
// * Automatic import waits for `markStoresReady()` (called after the existing
//   App bootstrap reaches a usable persistence state). A cold input therefore
//   queues before any store exists instead of being dropped.
// * Import runs one entry at a time. Every commit carries an exact
//   pre-allocated destination UUID (Notes document id / Canvas canvas id); a
//   restart proves the commit by that identity instead of importing again.
//   A canvas restore that died after its payload commit but before its
//   registry write is closed by removing only that attempt's owned partial
//   payload and re-queuing the same planned identity — no duplicate import
//   and no clobber of foreign work is possible.
// * Nothing here writes an editor, starts an agent run or changes another
//   window's selection. Navigation is published only after a real commit,
//   is claimed by the originating scene once, and is additionally fenced by
//   the routing eligibility the root registers: when the user navigated away
//   from the origin selection during a long import, the result is retained as
//   an explicit Open offer instead of stealing the current task or editor.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine
import SwiftUI
import UIKit
import FloeCore
import FloeNotes

@MainActor
final class DocumentIntakeCenter: ObservableObject {
    // MARK: Published surface

    @Published private(set) var queueSnapshot = DocumentIntakeQueueSnapshot(records: [], corruptCount: 0)
    @Published private(set) var activity: DocumentIntakeActivity?
    @Published private(set) var notice: DocumentIntakeNotice?
    @Published private(set) var presentation: DocumentIntakePresentation?
    @Published private(set) var noteOpenRequest: DocumentIntakeNoteOpenRequest?
    @Published private(set) var openOffer: DocumentIntakeOpenOffer?
    @Published private(set) var lastReceipt: DocumentIntakeReceipt?
    @Published private(set) var isReady = false
    @Published private(set) var isWorking = false

    // MARK: Dependencies

    let queue: DocumentIntakeQueue?
    private let stagingRoot: URL?
    private let limits: DocumentIntakeLimits
    private let notes: any NotesDocumentImporting
    private let canvas: any CanvasDocumentImporting
    private let now: @Sendable () -> Date
    private let availabilityError: DocumentIntakeFailure?

    private var didStart = false
    private var foregroundObserver: NSObjectProtocol?
    private var maintenanceTask: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var currentClaimID: UUID?
    private var stagingTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledEvents: Set<UUID> = []
    private var recentSubmissions: [String: (id: UUID, at: Date)] = [:]
    private var requestOrder: [UUID: UInt64] = [:]
    private var latestRequestSequence: UInt64 = 0
    private var noticeClearTask: Task<Void, Never>?
    /// Root-supplied per-request routing fence for AUTOMATIC completion
    /// presentation. Returning false means the user navigated away from the
    /// origin selection while the import ran. An explicit user Open never
    /// consults this closure.
    private var routingEligibility: (@MainActor (DocumentIntakePresentation) -> Bool)?

    /// Optional auto-drain gate for ambiguous external arrivals. Returning
    /// false keeps a pending record durable and UNCLAIMED until the import
    /// destination chooser records the user's explicit selection; un-gated
    /// builds (focused tests, other producers) import exactly as before.
    private var destinationGate: (@Sendable (DocumentIntakeRecord) -> Bool)?

    init(
        root: URL?,
        limits: DocumentIntakeLimits = .production,
        notes: any NotesDocumentImporting = LiveNotesDocumentImporter.live,
        canvas: any CanvasDocumentImporting = LiveCanvasDocumentImporter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limits = limits
        self.notes = notes
        self.canvas = canvas
        self.now = now
        if let root, let queue = try? DocumentIntakeQueue(root: root, limits: limits, now: now) {
            self.queue = queue
            self.stagingRoot = root.standardizedFileURL
            self.availabilityError = nil
        } else {
            self.queue = nil
            self.stagingRoot = nil
            self.availabilityError = .queueUnavailable
        }
    }

    static func applicationSupportRoot() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("DocumentIntake", isDirectory: true)
    }

    // MARK: Derived state

    var pendingCount: Int {
        queueSnapshot.records.filter { $0.state == .pending || $0.state == .importing }.count
    }

    var attentionRecords: [DocumentIntakeRecord] {
        queueSnapshot.records.filter {
            $0.state == .failed || $0.state == .needsReview || $0.state == .cancelled
        }
    }

    var queueIssueCount: Int { queueSnapshot.corruptCount }

    // MARK: Lifecycle

    /// Idempotent app-lifecycle entry. It performs only queue maintenance and
    /// foreground refresh; imports wait for `markStoresReady`.
    func start() {
        guard !didStart else { return }
        didStart = true
        guard queue != nil else {
            showNotice(DocumentIntakeNotice(
                kind: .failure,
                message: availabilityError?.message ?? DocumentIntakeFailure.queueUnavailable.message
            ))
            return
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.foreground()
            }
        }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            await self.runMaintenance()
            await self.refresh()
        }
    }

    /// Called once after the existing App bootstrap is ready to use durable
    /// stores. Pending cold-start inputs are then imported in FIFO order.
    func markStoresReady() {
        start()
        guard queue != nil else { return }
        isReady = true
        Task { [weak self] in
            guard let self else { return }
            await self.recoverInterrupted()
            await self.refresh()
            self.drainIfPossible()
        }
    }

    // MARK: Submit

    /// Starts materialization synchronously from the open-URL callback and
    /// returns the stable intake event id. Duplicate callbacks for the same
    /// URL within the short coalescing window share one event.
    @discardableResult
    /// - Parameter destinationChoiceRequired: true only for ambiguous
    ///   external entries (system "Open In" of common file formats). The
    ///   requirement is written into the entry atomically before publish,
    ///   so the automatic drain fails CLOSED: without a durable ledger
    ///   decision the staged input simply stays recoverable. Explicit
    ///   in-product importers keep the default (bypasses the chooser).
    func submit(
        _ url: URL,
        sceneID: String?,
        destinationChoiceRequired: Bool = false
    ) -> UUID? {
        guard queue != nil, let stagingRoot else {
            showNotice(DocumentIntakeNotice(
                kind: .failure,
                message: availabilityError?.message ?? DocumentIntakeFailure.queueUnavailable.message
            ))
            return nil
        }
        guard url.isFileURL else {
            showNotice(DocumentIntakeNotice(kind: .failure, message: DocumentIntakeFailure.unsupported.message))
            return nil
        }

        let timestamp = now()
        pruneRecentSubmissions(timestamp)
        let key = url.absoluteString
        if let recent = recentSubmissions[key],
           timestamp.timeIntervalSince(recent.at) < 2 {
            return recent.id
        }

        latestRequestSequence &+= 1
        let sequence = latestRequestSequence
        let eventID = UUID()
        let plannedRootDocumentID = UUID()
        recentSubmissions[key] = (eventID, timestamp)
        requestOrder[eventID] = sequence
        pruneRequestOrder()
        activity = DocumentIntakeActivity(
            id: eventID,
            phase: .staging,
            displayName: DocumentIntakeKind.displayName(from: url),
            kind: nil
        )

        let request = DocumentIntakeStagingRequest(
            eventID: eventID,
            plannedRootDocumentID: plannedRootDocumentID,
            sceneID: sceneID,
            requestSequence: sequence,
            receivedAt: timestamp,
            destinationChoiceRequired: destinationChoiceRequired
        )
        let stagingLimits = limits
        // Acquire the provider scope in the open-URL callback, not later in a
        // detached task. The lease is idempotent and released exactly once.
        let lease = DocumentIntakeProviderLease(url: url)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.stagingTasks[eventID] = nil }
            if Task.isCancelled {
                lease.release()
                self.activity = nil
                return
            }
            do {
                let staged = try await DocumentIntakeStager.stage(
                    url,
                    root: stagingRoot,
                    limits: stagingLimits,
                    request: request,
                    lease: lease
                )
                // A cancel during staging still preserves the copied input as
                // a recoverable cancelled entry; it never fakes success.
                if Task.isCancelled {
                    _ = try? await self.enqueue(staged)
                    _ = try? await self.queue?.cancel(id: eventID)
                    self.activity = nil
                    await self.refresh()
                    return
                }
                _ = try await self.enqueue(staged)
                self.activity = nil
                await self.refresh()
                if Task.isCancelled {
                    // The user cancelled while the entry was being published;
                    // keep it recoverable but do not start an import.
                    _ = try? await self.queue?.cancel(id: eventID)
                    return
                }
                self.drainIfPossible()
            } catch is CancellationError {
                self.activity = nil
            } catch {
                self.activity = nil
                let failure = DocumentIntakeFailureNotice.map(error)
                self.showNotice(DocumentIntakeNotice(
                    kind: .failure,
                    message: failure.message,
                    eventID: eventID
                ))
                await self.refresh()
            }
        }
        stagingTasks[eventID] = task
        return eventID
    }

    private func enqueue(_ staged: DocumentIntakeStagedInput) async throws -> DocumentIntakeRecord {
        guard let queue else { throw DocumentIntakeError.queueUnavailable }
        return try await queue.enqueue(staged)
    }

    // MARK: Processing

    private func drainIfPossible() {
        guard isReady, queue != nil, processing == nil else { return }
        processing = Task { [weak self] in
            guard let self else { return }
            await self.processPending()
        }
    }

    private func processPending() async {
        guard let queue else {
            processing = nil
            return
        }
        while !Task.isCancelled {
            let claim: DocumentIntakeClaim?
            do {
                claim = try await queue.claimNext(where: destinationGate)
            } catch {
                break
            }
            guard let claim else { break }
            currentClaimID = claim.record.id
            isWorking = true
            activity = DocumentIntakeActivity(
                id: claim.record.id,
                phase: .importing,
                displayName: claim.record.displayName,
                kind: claim.record.kind
            )
            await importClaim(claim)
            activity = nil
            isWorking = false
            currentClaimID = nil
            await refresh()
            if cancelledEvents.contains(claim.record.id) {
                cancelledEvents.remove(claim.record.id)
                break
            }
        }
        processing = nil
        await refresh()
    }

    private func importClaim(_ claim: DocumentIntakeClaim) async {
        guard let queue else { return }
        let record = claim.record
        do {
            try Task.checkCancellation()

            // Exact crash recovery: the pre-allocated destination identity is
            // the only proof used. A title or content match is never enough.
            if record.kind.importsIntoNotes {
                var existing: NoteDocument?
                do {
                    existing = try await notes.existingDocument(id: record.plannedRootDocumentID)
                } catch {
                    throw DocumentIntakeError.notesUnavailable
                }
                if let existing {
                    let ids = (try? await notes.documentIDs(inBundle: existing.id)) ?? [existing.id]
                    let commit = DocumentIntakeCommit(
                        rootDocumentID: existing.id,
                        documentIDs: ids,
                        canvasID: nil,
                        title: existing.title,
                        committedAt: now()
                    )
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                    return
                }
            } else if record.kind == .floeCanvas {
                // A recovery claim can meet a restore that already finalized
                // (the durable registry project exists). Record the real
                // receipt instead of importing a second canvas.
                if await canvas.canvasExists(id: record.plannedRootDocumentID) {
                    let commit = DocumentIntakeCommit(
                        rootDocumentID: nil,
                        documentIDs: [],
                        canvasID: record.plannedRootDocumentID,
                        title: nil,
                        committedAt: now()
                    )
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                    return
                }
            }

            let payloadURL = claim.payloadURL
            let digest = record.sha256
            let byteCount = record.byteCount
            let intact: Bool
            do {
                intact = try await Task.detached(priority: .utility) {
                    try DocumentIntakeStorage.verifySHA256(
                        at: payloadURL,
                        expectedDigest: digest,
                        expectedByteCount: byteCount
                    )
                }.value
            } catch {
                throw DocumentIntakeError.damaged
            }
            guard intact else { throw DocumentIntakeError.damaged }

            // Cancellation before the commit is safe to observe. Once an
            // importer returns success, the receipt is recorded even if the
            // worker was cancelled; cancel never claims to undo a commit.
            try Task.checkCancellation()

            let commit: DocumentIntakeCommit
            if record.kind == .floeCanvas {
                let outcome = try await canvas.importCanvas(
                    from: claim.payloadURL,
                    plannedCanvasID: record.plannedRootDocumentID
                )
                commit = DocumentIntakeCommit(
                    rootDocumentID: nil,
                    documentIDs: [],
                    canvasID: outcome.canvasID,
                    title: outcome.name,
                    committedAt: now()
                )
            } else {
                let outcome = try await notes.importNotes(
                    from: claim.payloadURL,
                    kind: record.kind,
                    plannedRootID: record.plannedRootDocumentID,
                    displayName: record.displayName
                )
                commit = DocumentIntakeCommit(
                    rootDocumentID: outcome.rootDocumentID,
                    documentIDs: outcome.documentIDs,
                    canvasID: nil,
                    title: outcome.title,
                    committedAt: now()
                )
            }
            do {
                try await queue.markCommitted(claim, commit: commit)
            } catch {
                // The import is keyed by the exact planned identity: a retry
                // proves the committed project via `canvasExists` and only
                // records the receipt, so a requeue cannot create a second
                // canvas. Reserve the ambiguous review state for a requeue
                // that also fails to persist.
                if record.kind == .floeCanvas {
                    do {
                        try await queue.requeue(claim)
                        showNotice(DocumentIntakeNotice(
                            kind: .info,
                            message: successMessage(for: .floeCanvas),
                            eventID: record.id
                        ))
                    } catch {
                        do {
                            try await queue.markNeedsReview(claim, code: .interrupted, detail: nil)
                            showNeedsReviewNotice(eventID: record.id)
                        } catch {
                            showQueueSaveFailureNotice(eventID: record.id)
                        }
                    }
                    return
                }
                throw error
            }
            await didCommit(record: record, commit: commit)
        } catch is CancellationError {
            await finishCancellation(claim)
        } catch {
            await finishFailure(claim, error: error)
        }
    }

    private func finishCancellation(_ claim: DocumentIntakeClaim) async {
        guard let queue else { return }
        let record = claim.record
        // Cancellation after a real commit returns the actual receipt; it
        // never claims to undo it.
        if record.kind.importsIntoNotes {
            do {
                if let existing = try await notes.existingDocument(id: record.plannedRootDocumentID) {
                    let ids = (try? await notes.documentIDs(inBundle: existing.id)) ?? [existing.id]
                    let commit = DocumentIntakeCommit(
                        rootDocumentID: existing.id,
                        documentIDs: ids,
                        canvasID: nil,
                        title: existing.title,
                        committedAt: now()
                    )
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                    return
                }
            } catch {
                do {
                    try await queue.markNeedsReview(claim, code: .interrupted, detail: nil)
                    showNeedsReviewNotice(eventID: record.id)
                } catch {
                    showQueueSaveFailureNotice(eventID: record.id)
                }
                return
            }
        } else if record.kind == .floeCanvas {
            if await canvas.canvasExists(id: record.plannedRootDocumentID) {
                let commit = DocumentIntakeCommit(
                    rootDocumentID: nil,
                    documentIDs: [],
                    canvasID: record.plannedRootDocumentID,
                    title: nil,
                    committedAt: now()
                )
                do {
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                } catch {
                    do {
                        try await queue.requeue(claim)
                    } catch {
                        showQueueSaveFailureNotice(eventID: record.id)
                    }
                }
                return
            }
        }
        if cancelledEvents.contains(record.id) {
            do {
                try await queue.markCancelled(claim)
                showNotice(DocumentIntakeNotice(
                    kind: .info,
                    message: DocumentIntakeFailure.cancelled.message,
                    eventID: record.id
                ))
            } catch {
                // A cancelled entry whose state write failed stays recoverable
                // as an interrupted claim; the durable input is preserved.
                showQueueSaveFailureNotice(eventID: record.id)
            }
        } else {
            do {
                try await queue.requeue(claim)
            } catch {
                showQueueSaveFailureNotice(eventID: record.id)
            }
        }
    }

    private func finishFailure(_ claim: DocumentIntakeClaim, error: Error) async {
        guard let queue else { return }
        let record = claim.record
        // A failure after the real commit still recovers the exact committed
        // identity; the durable input is never the thing that is lost.
        if record.kind.importsIntoNotes {
            do {
                if let existing = try await notes.existingDocument(id: record.plannedRootDocumentID) {
                    let ids = (try? await notes.documentIDs(inBundle: existing.id)) ?? [existing.id]
                    let commit = DocumentIntakeCommit(
                        rootDocumentID: existing.id,
                        documentIDs: ids,
                        canvasID: nil,
                        title: existing.title,
                        committedAt: now()
                    )
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                    return
                }
            } catch {
                do {
                    try await queue.markNeedsReview(claim, code: .interrupted, detail: nil)
                    showNeedsReviewNotice(eventID: record.id)
                } catch {
                    showQueueSaveFailureNotice(eventID: record.id)
                }
                return
            }
        } else if record.kind == .floeCanvas {
            if await canvas.canvasExists(id: record.plannedRootDocumentID) {
                let commit = DocumentIntakeCommit(
                    rootDocumentID: nil,
                    documentIDs: [],
                    canvasID: record.plannedRootDocumentID,
                    title: nil,
                    committedAt: now()
                )
                do {
                    try await queue.markCommitted(claim, commit: commit)
                    await didCommit(record: record, commit: commit)
                } catch {
                    do {
                        try await queue.requeue(claim)
                    } catch {
                        showQueueSaveFailureNotice(eventID: record.id)
                    }
                }
                return
            }
        }
        let failure = DocumentIntakeFailureNotice.map(error)
        do {
            try await queue.markFailed(claim, code: failure.code, detail: failure.detail)
            showNotice(DocumentIntakeNotice(
                kind: .failure,
                message: failure.message,
                eventID: record.id,
                canRetry: true,
                canDiscard: true
            ))
        } catch {
            // A failed state write preserves the durable input as an
            // interrupted claim; say the save failure instead of the cause.
            showQueueSaveFailureNotice(eventID: record.id)
        }
    }

    private func didCommit(record: DocumentIntakeRecord, commit: DocumentIntakeCommit) async {
        let receipt = DocumentIntakeReceipt(
            id: record.id,
            kind: record.kind,
            documentID: commit.rootDocumentID,
            canvasID: commit.canvasID,
            title: commit.title ?? record.displayName,
            originalName: record.displayName,
            committedAt: commit.committedAt
        )
        lastReceipt = receipt
        let sequence = requestOrder.removeValue(forKey: record.id)
        let isLatest = sequence != nil && sequence == latestRequestSequence
        if isLatest {
            let candidate = DocumentIntakePresentation(
                id: record.id,
                kind: record.kind,
                documentID: commit.rootDocumentID,
                canvasID: commit.canvasID,
                title: receipt.title,
                sceneID: record.sceneID
            )
            // Automatic presentation is fenced by the root's routing
            // eligibility: when the user navigated away from the origin
            // selection during a long import, the result is retained as an
            // explicit Open offer instead of stealing the current surface.
            if routingEligibility?(candidate) ?? true {
                presentation = candidate
                showNotice(
                    DocumentIntakeNotice(
                        kind: .success,
                        message: successMessage(for: record.kind),
                        eventID: record.id
                    ),
                    autoClear: 4
                )
            } else {
                retainOpenOffer(
                    eventID: record.id,
                    kind: record.kind,
                    documentID: commit.rootDocumentID,
                    canvasID: commit.canvasID,
                    title: receipt.title,
                    sceneID: record.sceneID,
                    reason: .userNavigated
                )
            }
        } else {
            showNotice(
                DocumentIntakeNotice(
                    kind: .success,
                    message: successMessage(for: record.kind),
                    eventID: record.id
                ),
                autoClear: 4
            )
        }
        await refresh()
    }

    /// Registers the root's routing eligibility check for automatic
    /// completion presentation. The root captures the origin selection when
    /// the open URL arrives and compares it here when the import completes.
    func setRoutingEligibility(
        _ body: @escaping @MainActor (DocumentIntakePresentation) -> Bool
    ) {
        routingEligibility = body
    }

    /// Registers the import-destination gate for ambiguous external
    /// arrivals. Installed once during App bootstrap, BEFORE
    /// `markStoresReady()`, so a cold ambiguous entry can never be claimed
    /// by the automatic drain before its durable decision exists.
    func configureDestinationGate(
        _ gate: @escaping @Sendable (DocumentIntakeRecord) -> Bool
    ) {
        destinationGate = gate
    }

    /// Re-arms the bounded drain after a destination decision changes (the
    /// gate released an entry, or a hand-off removed one). Idempotent:
    /// `drainIfPossible` never runs a second worker while one is active.
    func resumeDraining() {
        drainIfPossible()
    }

    /// Re-reads the durable queue state for the chooser's observation pass.
    func refreshSnapshot() async {
        await refresh()
    }

    private func retainOpenOffer(
        eventID: UUID,
        kind: DocumentIntakeKind,
        documentID: UUID?,
        canvasID: UUID?,
        title: String,
        sceneID: String?,
        reason: DocumentIntakeOpenOffer.Reason
    ) {
        openOffer = DocumentIntakeOpenOffer(
            id: UUID(),
            eventID: eventID,
            kind: kind,
            documentID: documentID,
            canvasID: canvasID,
            title: title,
            sceneID: sceneID,
            reason: reason
        )
        // The offer stays until the user opens or dismisses it; auto-clear
        // would silently drop a result the user deliberately waited for.
        showNotice(DocumentIntakeNotice(
            kind: .success,
            message: successMessage(for: kind),
            eventID: eventID,
            canOpen: true
        ))
    }

    /// Explicit user Open for a retained committed result. This bypasses the
    /// routing fence (the user asked for it) and re-arms the once-only
    /// presentation for the scene where the user pressed Open to claim.
    func openCommittedResult(sceneID: String? = nil) {
        guard let offer = openOffer else { return }
        openOffer = nil
        if notice?.eventID == offer.eventID {
            noticeClearTask?.cancel()
            notice = nil
        }
        presentation = DocumentIntakePresentation(
            id: offer.eventID,
            kind: offer.kind,
            documentID: offer.documentID,
            canvasID: offer.canvasID,
            title: offer.title,
            sceneID: sceneID ?? offer.sceneID
        )
    }

    // MARK: Recovery / maintenance

    private func foreground() async {
        guard didStart else { return }
        await runMaintenance()
        if isReady {
            await recoverInterrupted()
            await refresh()
            drainIfPossible()
        }
    }

    private func runMaintenance() async {
        guard let queue else { return }
        do {
            _ = try await queue.maintain(now: now())
        } catch {
            // Maintenance is required for recovery and expiry; a storage
            // failure here means durable inputs were NOT processed.
            showNotice(DocumentIntakeNotice(
                kind: .failure,
                message: DocumentIntakeFailure.ioFailure.message
            ))
        }
        await refresh()
    }

    private func recoverInterrupted() async {
        guard let queue else { return }
        let records: [DocumentIntakeRecord]
        do { records = try await queue.interrupted() }
        catch { return }
        for record in records {
            let claim: DocumentIntakeClaim?
            do {
                claim = try await queue.takeRecoveryClaim(id: record.id)
            } catch {
                // The interrupted entry stays recoverable and is re-examined
                // on the next foreground; say that the save failed.
                showQueueSaveFailureNotice(eventID: record.id)
                continue
            }
            guard let claim else { continue }
            if record.kind.importsIntoNotes {
                do {
                    if let existing = try await notes.existingDocument(id: record.plannedRootDocumentID) {
                        let ids = (try? await notes.documentIDs(inBundle: existing.id)) ?? [existing.id]
                        let commit = DocumentIntakeCommit(
                            rootDocumentID: existing.id,
                            documentIDs: ids,
                            canvasID: nil,
                            title: existing.title,
                            committedAt: now()
                        )
                        try await queue.markCommitted(claim, commit: commit)
                        await didCommit(record: record, commit: commit)
                        continue
                    }
                    try await queue.requeue(claim)
                } catch {
                    do {
                        try await queue.markNeedsReview(claim, code: .interrupted, detail: nil)
                        showNeedsReviewNotice(eventID: record.id)
                    } catch {
                        showQueueSaveFailureNotice(eventID: record.id)
                    }
                }
            } else {
                // Exact identity recovery: a finalized restore wrote the
                // durable registry project under the planned canvas id, so the
                // real receipt is recorded without importing again.
                if await canvas.canvasExists(id: record.plannedRootDocumentID) {
                    let commit = DocumentIntakeCommit(
                        rootDocumentID: nil,
                        documentIDs: [],
                        canvasID: record.plannedRootDocumentID,
                        title: nil,
                        committedAt: now()
                    )
                    do {
                        try await queue.markCommitted(claim, commit: commit)
                        await didCommit(record: record, commit: commit)
                    } catch {
                        showQueueSaveFailureNotice(eventID: record.id)
                    }
                    continue
                }
                // The restore committed payload bytes but died before the
                // registry write. Remove only this attempt's owned partial
                // payload (native CAD folder, unapplied CAD drafts) and put
                // the entry back: the retry reuses the same planned identity,
                // and the staged verifier's content addressing plus stable
                // derived child identities make the re-commit reuse identical
                // paths. A duplicate import or a clobber of foreign work is
                // impossible either way.
                _ = await canvas.removePartialRestoreArtifacts(canvasID: record.plannedRootDocumentID)
                do {
                    try await queue.requeue(claim)
                } catch {
                    showQueueSaveFailureNotice(eventID: record.id)
                }
            }
        }
        await refresh()
    }

    private func refresh() async {
        guard let queue else { return }
        do {
            queueSnapshot = try await queue.snapshot()
        } catch {
            queueSnapshot = DocumentIntakeQueueSnapshot(
                records: queueSnapshot.records,
                corruptCount: queueSnapshot.corruptCount
            )
        }
    }

    // MARK: Presentation / user actions

    /// Claims the one pending presentation for the originating scene. A second
    /// window receives nil, so a committed import cannot steal focus twice.
    func takePresentation(sceneID: String?) -> DocumentIntakePresentation? {
        guard let presentation else { return nil }
        if let origin = presentation.sceneID {
            guard let sceneID, origin == sceneID else { return nil }
        }
        self.presentation = nil
        return presentation
    }

    /// Called after the root navigated to Notes. NotesRootView consumes the
    /// request and adopts the exact imported identity without discarding an
    /// unsaved current note.
    func presentNotes(_ presentation: DocumentIntakePresentation) {
        guard let documentID = presentation.documentID else { return }
        noteOpenRequest = DocumentIntakeNoteOpenRequest(
            id: UUID(),
            eventID: presentation.id,
            documentID: documentID,
            title: presentation.title,
            sceneID: presentation.sceneID
        )
    }

    /// Synchronous one-shot claim: only the first Notes view (in the
    /// originating scene) can adopt this request. A second window observes
    /// nil and leaves its own selected note untouched.
    @discardableResult
    func claimNoteOpen(_ request: DocumentIntakeNoteOpenRequest) -> Bool {
        guard noteOpenRequest?.id == request.id else { return false }
        noteOpenRequest = nil
        return true
    }

    func completeNoteOpen(_ request: DocumentIntakeNoteOpenRequest, opened: Bool) {
        if opened {
            showNotice(
                DocumentIntakeNotice(
                    kind: .success,
                    message: successMessage(for: .floeNote)
                ),
                autoClear: 4
            )
        } else {
            showNotice(DocumentIntakeNotice(
                kind: .info,
                message: FloeL10n.l("document.intake.busy_switch"),
                eventID: request.eventID
            ))
        }
    }

    /// The target surface is busy (another canvas is open). The import is
    /// committed; the user can open the exact result without losing the
    /// current editor. The notice carries a real Open action.
    func deferPresentation(_ presentation: DocumentIntakePresentation) {
        retainOpenOffer(
            eventID: presentation.id,
            kind: presentation.kind,
            documentID: presentation.documentID,
            canvasID: presentation.canvasID,
            title: presentation.title,
            sceneID: presentation.sceneID,
            reason: .targetBusy
        )
    }

    @discardableResult
    func cancel(_ eventID: UUID) async -> DocumentIntakeCancelOutcome {
        guard let queue else { return .notFound }
        if let staging = stagingTasks[eventID] {
            staging.cancel()
            await staging.value
        }
        // The entry can move pending → importing between the read and the
        // cancel call. Two passes close that small race without inventing a
        // second cancellation authority.
        for _ in 0..<2 {
            if currentClaimID == eventID {
                cancelledEvents.insert(eventID)
                if let task = processing {
                    task.cancel()
                    await task.value
                }
                if let record = try? await queue.record(id: eventID) {
                    if record.state == .committed, let receipt = record.receipt {
                        lastReceipt = receipt
                        return .alreadyCommitted(receipt)
                    }
                    if record.state == .cancelled {
                        showNotice(DocumentIntakeNotice(
                            kind: .info,
                            message: DocumentIntakeFailure.cancelled.message,
                            eventID: eventID
                        ))
                        return .cancelled
                    }
                }
                drainIfPossible()
                return .cancelling
            }
            do {
                let outcome = try await queue.cancel(id: eventID)
                switch outcome {
                case .cancelled:
                    showNotice(DocumentIntakeNotice(
                        kind: .info,
                        message: DocumentIntakeFailure.cancelled.message,
                        eventID: eventID
                    ))
                    await refresh()
                    return .cancelled
                case .alreadyCommitted(let receipt):
                    lastReceipt = receipt
                    await refresh()
                    return .alreadyCommitted(receipt)
                case .busy:
                    continue
                case .notFound:
                    await refresh()
                    return .notFound
                case .cancelling:
                    await refresh()
                    return .cancelling
                }
            } catch {
                showNotice(DocumentIntakeNotice(
                    kind: .failure,
                    message: DocumentIntakeFailure.importFailed.message,
                    eventID: eventID
                ))
                return .busy
            }
        }
        return .busy
    }

    func retry(_ eventID: UUID) async {
        guard let queue else { return }
        do {
            guard try await queue.retry(id: eventID) else { return }
        } catch {
            showQueueSaveFailureNotice(eventID: eventID)
            return
        }
        if notice?.eventID == eventID { notice = nil }
        await refresh()
        drainIfPossible()
    }

    func discard(_ eventID: UUID) async {
        guard let queue else { return }
        do {
            guard try await queue.discard(id: eventID) else { return }
        } catch {
            showQueueSaveFailureNotice(eventID: eventID)
            return
        }
        if notice?.eventID == eventID { notice = nil }
        if openOffer?.eventID == eventID { openOffer = nil }
        await refresh()
    }

    func dismissNotice() {
        noticeClearTask?.cancel()
        notice = nil
        // Dismissing the retained-result notice drops the offer with it; the
        // committed document stays reachable from Notes/Canvas as before.
        openOffer = nil
    }

    // MARK: Helpers

    private func successMessage(for kind: DocumentIntakeKind) -> String {
        kind == .floeCanvas
            ? FloeL10n.l("document.intake.saved_in_canvas")
            : FloeL10n.l("document.intake.saved_in_notes")
    }

    private func showNeedsReviewNotice(eventID: UUID) {
        showNotice(DocumentIntakeNotice(
            kind: .info,
            message: DocumentIntakeFailure.interrupted.message,
            eventID: eventID,
            canRetry: true,
            canDiscard: true
        ))
    }

    /// A required durable state transition failed to persist. The staged
    /// input is preserved (the entry stays recoverable) and the user can
    /// still retry or discard explicitly.
    private func showQueueSaveFailureNotice(eventID: UUID) {
        showNotice(DocumentIntakeNotice(
            kind: .failure,
            message: DocumentIntakeFailure.ioFailure.message,
            eventID: eventID,
            canRetry: true,
            canDiscard: true
        ))
    }

    private func showNotice(_ value: DocumentIntakeNotice, autoClear: TimeInterval? = nil) {
        noticeClearTask?.cancel()
        notice = value
        guard let autoClear else { return }
        let id = value.id
        let milliseconds = max(0, Int(autoClear * 1_000))
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            if self?.notice?.id == id { self?.notice = nil }
        }
    }

    private func pruneRecentSubmissions(_ date: Date) {
        recentSubmissions = recentSubmissions.filter { date.timeIntervalSince($0.value.at) < 30 }
    }

    private func pruneRequestOrder() {
        guard requestOrder.count > 100 else { return }
        let cutoff = latestRequestSequence > 100 ? latestRequestSequence - 100 : 0
        requestOrder = requestOrder.filter { $0.value >= cutoff }
    }
}
#endif
