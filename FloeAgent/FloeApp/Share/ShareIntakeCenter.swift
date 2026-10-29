// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — reviewed inbound-share consumer (S5 P1).
//
// The Share extension only stages bytes. This center is the app-owned half:
// it refreshes the durable FIFO queue, exposes a compact review surface and
// applies ONE explicitly chosen envelope to the existing Home composer. It
// never sends a message, starts a task or opens a deep link; incoming content
// is data, not authority.
//
// Ownership and recovery:
// * `ShareInbox` holds an exclusive OS file lock for the whole claim.
//   Cooperating windows share one center (AppEnvironment) and serialize
//   through `isWorking`, but the file lock is the authority across processes.
// * Attachments are copied into the existing FilesCenter staging area with
//   their original bytes (`compressImage: false`), then the merged text and
//   attachments are committed through `ComposerDraftStore.commitDurable`
//   with an envelope-bound handoff receipt. The source envelope is
//   acknowledged ONLY after that receipt is verified on disk.
// * If the process dies after the draft commit but before the ack, the next
//   pass sees the persisted receipt and settles the source without appending
//   the content a second time.
// * A failed/busy destination releases the claim and keeps the envelope
//   pending and recoverable. Its staged copies are discarded ONLY while the
//   destination proves nothing durable for this envelope; if a landing of
//   THIS envelope already reached disk (its receipt is proven on disk and
//   the durable draft still carries the landed delta), deleting the staged
//   bytes would leave the durable draft pointing at removed files, so they
//   are retained until a later apply settles the proven receipt or the user
//   explicitly discards the envelope.

#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import UIKit
import FloeCore
import FloeModels

// MARK: - Draft merge

/// Shared, pure merge rules so every destination (Home and focused tests)
/// preserves existing human work identically.
enum ShareDraftMerger {
    static func mergedText(existing: String, incoming: String) -> String {
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingTrimmed.isEmpty else { return existing }
        guard existing.contains(where: { !$0.isWhitespace }) else { return incoming }
        if existing.hasSuffix("\n\n") { return existing + incoming }
        if existing.hasSuffix("\n") { return existing + "\n" + incoming }
        return existing + "\n\n" + incoming
    }

    static func mergedAttachments(
        existing: [AttachmentRef],
        incoming: [AttachmentRef]
    ) -> [AttachmentRef] {
        var result = existing
        var identities = Set(existing.map(\.id))
        for attachment in incoming where !identities.contains(attachment.id) {
            result.append(attachment)
            identities.insert(attachment.id)
        }
        return result
    }
}

// MARK: - Destination contract

struct ShareDraftSnapshot: Equatable, Sendable {
    var text: String
    var attachmentIDs: [UUID]
    var storedRevision: Int?
    var isBusy: Bool

    var hasText: Bool {
        text.contains(where: { !$0.isWhitespace })
    }

    var hasContent: Bool {
        hasText || !attachmentIDs.isEmpty
    }
}

struct ShareDraftApplication {
    let envelopeID: UUID
    /// Text/URL items joined in their original order.
    let incomingText: String
    let stagedAttachments: [AttachmentRef]
    let receipt: ComposerDraftStore.ShortcutHandoffReceipt
}

enum ShareDraftApplyResult: Equatable {
    /// The merged draft AND the envelope-bound receipt are verified durable.
    /// Only this result permits acknowledging the source envelope.
    case applied
    case busy
    case unavailable
    case failed
}

/// The live composer surface that can accept a reviewed share. The Home
/// adapter owns the real ComposerDraftStore CAS; the center never writes the
/// draft directly.
@MainActor
protocol ShareIntakeDestination: AnyObject {
    var shareIntakeDestinationID: String { get }
    func shareIntakeSnapshot() -> ShareDraftSnapshot
    /// Envelope id whose receipt is PROVEN durable on disk (crash recovery).
    func shareIntakeAppliedClaimToken(envelopeID: UUID) -> String?
    func shareIntakeSettle(envelopeID: UUID, claimToken: String)
    func shareIntakeApply(_ application: ShareDraftApplication) async -> ShareDraftApplyResult
}

// MARK: - Attachment staging

@MainActor
protocol ShareAttachmentStaging: AnyObject {
    func stageShareAttachment(
        from url: URL,
        displayName: String,
        typeIdentifier: String,
        kind: ShareInboxItemKind,
        envelopeID: UUID
    ) async throws -> AttachmentRef
    func discardShareAttachment(_ attachment: AttachmentRef) async
}

/// Production adapter over the existing FilesCenter attachment pipeline.
/// `compressImage: false` preserves the original bytes and extension; the
/// FilesCenter creates its own collision-safe storage name.
@MainActor
final class FilesCenterShareAttachmentStaging: ShareAttachmentStaging {
    private weak var filesCenter: FilesCenter?

    init(filesCenter: FilesCenter) {
        self.filesCenter = filesCenter
    }

    func stageShareAttachment(
        from url: URL,
        displayName: String,
        typeIdentifier: String,
        kind: ShareInboxItemKind,
        envelopeID: UUID
    ) async throws -> AttachmentRef {
        guard let filesCenter else {
            throw FloeError.notFound("Files center")
        }
        return try await filesCenter.registerPickedDocument(
            url: url,
            displayName: displayName,
            compressImage: false
        )
    }

    func discardShareAttachment(_ attachment: AttachmentRef) async {
        filesCenter?.discardSharedIntakeAttachment(attachment)
    }
}

@MainActor
extension FilesCenter {
    /// Removes only an app-owned staged copy created by this intake. The
    /// original provider/share-envelope bytes are owned by ShareInbox and
    /// are never touched here.
    func discardSharedIntakeAttachment(_ attachment: AttachmentRef) {
        guard attachment.storage == .applicationSupport else { return }
        if let url = try? resolveURL(for: attachment) {
            try? FileManager.default.removeItem(at: url)
        }
        recentFiles.removeAll { $0.id == attachment.id }
    }
}

// MARK: - Outcomes

enum ShareIntakeDeferral: Equatable, Sendable {
    case composerBusy
    case anotherShareInProgress
    case cancelled
    case unavailable
}

enum ShareIntakeOutcome: Equatable, Sendable {
    case applied(envelopeID: UUID)
    case alreadyApplied(envelopeID: UUID)
    case discarded(envelopeID: UUID)
    case deferred(envelopeID: UUID, reason: ShareIntakeDeferral)
    case failed(envelopeID: UUID, message: String)
    case empty
}

struct ShareIntakeSummary: Equatable, Sendable {
    var itemCount: Int
    var attachmentCount: Int
    var textPreview: String?
    var fileNames: [String]
}

// MARK: - Center

@MainActor
final class ShareIntakeCenter: ObservableObject {
    @Published private(set) var pending: [ShareEnvelope] = []
    @Published private(set) var diagnostics: [ShareInboxDiagnostic] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastOutcome: ShareIntakeOutcome?
    /// Concise, user-facing follow-up (never a path or protocol detail).
    @Published private(set) var lastErrorMessage: String?
    /// Last result of an explicit durable destination card action (Notes or
    /// Canvas), so the card can show exactly the status of THIS envelope
    /// (nil until tapped).
    @Published private(set) var lastDestinationOutcome: ShareDestinationOutcome?

    let inbox: ShareInbox?
    private let staging: any ShareAttachmentStaging
    private let now: @Sendable () -> Date
    private let availabilityError: ShareInboxError?
    private var didStart = false
    private var foregroundObserver: NSObjectProtocol?
    private var storageSuspended = false
    private var activeApplication: Task<ShareIntakeOutcome, Never>?
    /// Injected once during App bootstrap. The card's durable destination
    /// actions only forward here; the ledger-backed executors live in
    /// `ImportDestinationCenter` (shared ledger, planned identities, ack).
    private var destinationHandler: (any ShareEnvelopeDestinationImporting)?

    init(
        inbox: ShareInbox?,
        staging: any ShareAttachmentStaging,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
        self.staging = staging
        self.now = now
        self.availabilityError = inbox == nil ? .appGroupUnavailable : nil
    }

    var hasPending: Bool { !pending.isEmpty }

    var queueIssueMessage: String? {
        guard !diagnostics.isEmpty else { return nil }
        return FloeL10n.l("share.intake.corrupt_pending")
    }

    /// Idempotent app-lifecycle entry. Foreground refresh is the only trigger
    /// needed because a share extension cannot activate Floe; the user opens
    /// the app explicitly.
    func start() {
        guard !didStart else { return }
        didStart = true
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let inbox else {
            pending = []
            diagnostics = []
            lastErrorMessage = availabilityError?.localizedDescription
            lastDestinationOutcome = nil
            return
        }
        let report = inbox.maintain(now: now())
        diagnostics = report.diagnostics
        do {
            pending = try inbox.pending(now: now())
        } catch {
            pending = []
            diagnostics.append(ShareInboxDiagnostic(
                kind: .rootUnavailable,
                detail: "pending"
            ))
            FloeLogger(category: .app).error("shareIntakePendingReadFailed")
        }
        // A Notes status about an envelope that already left the inbox
        // (acknowledged, discarded or expired) must not describe the next
        // share; success feedback lives on the destination surfaces.
        if let identity = lastDestinationOutcome?.result.envelopeIdentity,
           !pending.contains(where: { $0.id == identity }) {
            lastDestinationOutcome = nil
        }
    }

    static func summary(for envelope: ShareEnvelope) -> ShareIntakeSummary {
        let textPreview = envelope.textItems.first?.text.map { text in
            let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(collapsed.prefix(160))
        }
        let names = envelope.attachmentItems.compactMap(\.fileName)
        return ShareIntakeSummary(
            itemCount: envelope.items.count,
            attachmentCount: envelope.attachmentItems.count,
            textPreview: textPreview,
            fileNames: names
        )
    }

    // MARK: Explicit durable destinations (forwarded)

    func configureDestinationHandler(_ handler: any ShareEnvelopeDestinationImporting) {
        destinationHandler = handler
    }

    /// The card's "Import to Notes" action. This center deliberately owns no
    /// import logic: the chooser's ledger-backed executor claims, imports by
    /// planned identity, and acknowledges. The card just forwards and
    /// reflects the outcome for this envelope.
    @discardableResult
    func importEnvelopeToNotes(_ envelope: ShareEnvelope) async -> ShareNotesImportResult {
        guard let destinationHandler else { return .unavailable }
        let result = await destinationHandler.importEnvelopeToNotes(envelope)
        lastDestinationOutcome = ShareDestinationOutcome(destination: .notes, result: result)
        return result
    }

    /// The card's "Import to Canvas" action through the same ledger-backed
    /// chooser; `target` comes from the card's compact canvas menu.
    @discardableResult
    func importEnvelopeToCanvas(
        _ envelope: ShareEnvelope,
        target: CanvasDestinationTarget
    ) async -> ShareNotesImportResult {
        guard let destinationHandler else { return .unavailable }
        let result = await destinationHandler.importEnvelopeToCanvas(envelope, target: target)
        lastDestinationOutcome = ShareDestinationOutcome(destination: .canvas, result: result)
        return result
    }

    /// Lets `ImportDestinationCenter` (deep-link / sheet / recovery paths)
    /// publish its outcome on the card status line when the same center
    /// observes the envelope afterwards.
    func destinationImportFinished(
        destination: ImportDestination,
        result: ShareNotesImportResult
    ) {
        lastDestinationOutcome = ShareDestinationOutcome(destination: destination, result: result)
    }

    func clearDestinationOutcome() {
        lastDestinationOutcome = nil
    }

    /// Canvas picker data for the card's compact menu.
    func canvasImportTargets() -> [CanvasImportTarget] {
        destinationHandler?.canvasImportTargets() ?? []
    }

    // MARK: Explicit apply

    @discardableResult
    func applyNext(to destination: any ShareIntakeDestination) async -> ShareIntakeOutcome {
        guard let envelope = pending.first else {
            lastOutcome = .empty
            return .empty
        }
        return await apply(envelope, to: destination)
    }

    /// Applies exactly one reviewed envelope. `destination` is passed by the
    /// calling Home window so a second window can never apply into another
    /// window's live composer.
    @discardableResult
    func apply(
        _ envelope: ShareEnvelope,
        to destination: any ShareIntakeDestination
    ) async -> ShareIntakeOutcome {
        guard !storageSuspended else { return .deferred(envelopeID: envelope.id, reason: .cancelled) }
        guard activeApplication == nil else {
            return .deferred(envelopeID: envelope.id, reason: .anotherShareInProgress)
        }
        let task = Task { @MainActor [self] in
            do {
                let budget = try await StorageOperationBudget.begin()
                defer { budget.finish() }
                try budget.check()
                return await applyClaimedEnvelope(envelope, to: destination)
            } catch {
                return ShareIntakeOutcome.deferred(envelopeID: envelope.id, reason: .cancelled)
            }
        }
        activeApplication = task
        defer { activeApplication = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func applyClaimedEnvelope(
        _ envelope: ShareEnvelope,
        to destination: any ShareIntakeDestination
    ) async -> ShareIntakeOutcome {
        guard !storageSuspended, !Task.isCancelled else {
            return .deferred(envelopeID: envelope.id, reason: .cancelled)
        }
        guard let inbox else {
            let message = availabilityError?.localizedDescription
                ?? FloeL10n.l("share.error.app_group_unavailable")
            lastErrorMessage = message
            let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
            lastOutcome = outcome
            return outcome
        }
        guard !isWorking else {
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .anotherShareInProgress
            )
            lastOutcome = outcome
            return outcome
        }

        isWorking = true
        defer { isWorking = false }
        lastErrorMessage = nil

        var claim: ShareInboxClaim?
        var staged: [AttachmentRef] = []
        var keepStagedAttachments = false

        func discardOwnedState(releaseClaim: Bool) async {
            if !keepStagedAttachments {
                for attachment in staged {
                    await staging.discardShareAttachment(attachment)
                }
                staged.removeAll()
            }
            if releaseClaim, let claim {
                try? inbox.release(claim)
            }
        }

        /// The durable destination may still reference THIS attempt's staged
        /// bytes even when the apply did not end in an acknowledged landing:
        /// a verified placement can be followed by a failed, cancelled or
        /// busy reconciliation, and the store only reports a receipt as
        /// disk-proven while the most recent landed snapshot actually
        /// carries the landed delta. Deleting the staged copies in that
        /// state would leave the durable draft pointing at removed files
        /// while the envelope is still pending. Retention is bounded: the
        /// next pass either settles the proven receipt with an ack or
        /// re-lands the envelope against fresh copies.
        func retainStagedIfDurableProofExists() {
            if destination.shareIntakeAppliedClaimToken(envelopeID: envelope.id) != nil {
                keepStagedAttachments = true
            }
        }

        guard !destination.shareIntakeDestinationID.isEmpty else {
            await refresh()
            let outcome = ShareIntakeOutcome.failed(
                envelopeID: envelope.id,
                message: FloeL10n.l("share.intake.failed")
            )
            lastOutcome = outcome
            return outcome
        }

        do {
            let requestedID = envelope.id
            let claimTime = now()
            // Digest verification can read a full envelope. Keep the
            // exclusive lease, but perform that I/O away from the UI actor.
            claim = try await Task.detached(priority: .userInitiated) {
                try inbox.claim(id: requestedID, now: claimTime)
            }.value
        } catch ShareInboxError.claimBusy {
            await refresh()
            lastErrorMessage = FloeL10n.l("share.intake.deferred_busy")
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .anotherShareInProgress
            )
            lastOutcome = outcome
            return outcome
        } catch {
            await refresh()
            let message = (error as? ShareInboxError)?.localizedDescription
                ?? FloeL10n.l("share.intake.failed")
            lastErrorMessage = message
            let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
            lastOutcome = outcome
            return outcome
        }
        guard let claim else {
            await refresh()
            let outcome = ShareIntakeOutcome.failed(
                envelopeID: envelope.id,
                message: FloeL10n.l("share.intake.failed")
            )
            lastOutcome = outcome
            return outcome
        }

        if Task.isCancelled {
            await discardOwnedState(releaseClaim: true)
            await refresh()
            let outcome = ShareIntakeOutcome.deferred(envelopeID: envelope.id, reason: .cancelled)
            lastOutcome = outcome
            return outcome
        }

        // Crash-after-commit-before-ack recovery: the receipt proves the
        // draft already accepted this exact envelope. Settle the source
        // without touching the draft again.
        if let previousToken = destination.shareIntakeAppliedClaimToken(envelopeID: envelope.id) {
            do {
                try inbox.ack(claim)
                destination.shareIntakeSettle(envelopeID: envelope.id, claimToken: previousToken)
                lastErrorMessage = nil
            } catch {
                // The draft proof is intact; only cleanup is pending. Release
                // this attempt's claim so a later pass can retry the ack.
                try? inbox.release(claim)
                lastErrorMessage = FloeL10n.l("share.intake.cleanup_pending")
            }
            await refresh()
            let outcome = ShareIntakeOutcome.alreadyApplied(envelopeID: envelope.id)
            lastOutcome = outcome
            return outcome
        }

        let snapshot = destination.shareIntakeSnapshot()
        guard !snapshot.isBusy else {
            await discardOwnedState(releaseClaim: true)
            await refresh()
            lastErrorMessage = FloeL10n.l("share.intake.deferred_busy")
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .composerBusy
            )
            lastOutcome = outcome
            return outcome
        }

        // Stage attachments with their original bytes before touching the
        // draft. Any failure discards only these copies and releases the
        // claim; the source envelope stays recoverable.
        for item in envelope.attachmentItems {
            if Task.isCancelled {
                await discardOwnedState(releaseClaim: true)
                await refresh()
                let outcome = ShareIntakeOutcome.deferred(
                    envelopeID: envelope.id,
                    reason: .cancelled
                )
                lastOutcome = outcome
                return outcome
            }
            do {
                let url = try inbox.payloadURL(for: item, in: envelope)
                let attachment = try await staging.stageShareAttachment(
                    from: url,
                    displayName: item.fileName ?? "",
                    typeIdentifier: item.typeIdentifier ?? "public.data",
                    kind: item.kind,
                    envelopeID: envelope.id
                )
                staged.append(attachment)
            } catch {
                FloeLogger(category: .app).error(
                    "shareIntakeStageFailed envelope=\(envelope.id.uuidString.prefix(8))"
                )
                await discardOwnedState(releaseClaim: true)
                await refresh()
                let message = FloeL10n.l("share.intake.failed")
                lastErrorMessage = message
                let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
                lastOutcome = outcome
                return outcome
            }
        }

        if Task.isCancelled {
            await discardOwnedState(releaseClaim: true)
            await refresh()
            let outcome = ShareIntakeOutcome.deferred(envelopeID: envelope.id, reason: .cancelled)
            lastOutcome = outcome
            return outcome
        }
        let incomingText = envelope.textItems.compactMap(\.text).joined(separator: "\n")
        let receipt = ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: destination.shareIntakeDestinationID,
            entryID: envelope.id,
            claimToken: claim.token
        )
        let application = ShareDraftApplication(
            envelopeID: envelope.id,
            incomingText: incomingText,
            stagedAttachments: staged,
            receipt: receipt
        )
        let result = await destination.shareIntakeApply(application)

        switch result {
        case .applied:
            // The destination verified the merged draft and the receipt on
            // disk. These attachments are now part of the draft.
            keepStagedAttachments = true
            do {
                try inbox.ack(claim)
                destination.shareIntakeSettle(envelopeID: envelope.id, claimToken: claim.token)
                lastErrorMessage = nil
            } catch {
                // Draft is durable and visible; only source cleanup is
                // pending. Release the claim so a later refresh can ack
                // against the persisted receipt.
                try? inbox.release(claim)
                lastErrorMessage = FloeL10n.l("share.intake.cleanup_pending")
                FloeLogger(category: .app).error(
                    "shareIntakeAckPending envelope=\(envelope.id.uuidString.prefix(8))"
                )
            }
            await refresh()
            let outcome = ShareIntakeOutcome.applied(envelopeID: envelope.id)
            lastOutcome = outcome
            return outcome

        case .busy:
            retainStagedIfDurableProofExists()
            await discardOwnedState(releaseClaim: true)
            await refresh()
            lastErrorMessage = FloeL10n.l("share.intake.deferred_busy")
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .composerBusy
            )
            lastOutcome = outcome
            return outcome

        case .unavailable:
            retainStagedIfDurableProofExists()
            await discardOwnedState(releaseClaim: true)
            await refresh()
            lastErrorMessage = FloeL10n.l("share.intake.unavailable")
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .unavailable
            )
            lastOutcome = outcome
            return outcome

        case .failed:
            retainStagedIfDurableProofExists()
            await discardOwnedState(releaseClaim: true)
            await refresh()
            let message = FloeL10n.l("share.intake.failed")
            lastErrorMessage = message
            let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
            lastOutcome = outcome
            return outcome
        }
    }

    /// Explicit discard: the user reviewed the share and chose not to add
    /// it. This is the only path that deletes the source without a draft.
    @discardableResult
    func discard(_ envelope: ShareEnvelope) async -> ShareIntakeOutcome {
        guard !storageSuspended else { return .deferred(envelopeID: envelope.id, reason: .cancelled) }
        let budget: StorageOperationLease
        do { budget = try await StorageOperationBudget.begin() }
        catch { return .deferred(envelopeID: envelope.id, reason: .cancelled) }
        defer { budget.finish() }
        guard !storageSuspended else { return .deferred(envelopeID: envelope.id, reason: .cancelled) }
        guard let inbox else {
            let message = availabilityError?.localizedDescription
                ?? FloeL10n.l("share.error.app_group_unavailable")
            lastErrorMessage = message
            let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
            lastOutcome = outcome
            return outcome
        }
        guard !isWorking else {
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .anotherShareInProgress
            )
            lastOutcome = outcome
            return outcome
        }
        isWorking = true
        defer { isWorking = false }
        lastErrorMessage = nil
        do {
            // Discard is an explicit user decision about the source bytes;
            // it must also work when the payload no longer matches its
            // digest, otherwise a corrupt share could never leave the card.
            let claim = try inbox.claim(
                id: envelope.id,
                now: now(),
                verifyDigests: false
            )
            try inbox.ack(claim)
            await refresh()
            let outcome = ShareIntakeOutcome.discarded(envelopeID: envelope.id)
            lastOutcome = outcome
            return outcome
        } catch ShareInboxError.claimBusy {
            await refresh()
            lastErrorMessage = FloeL10n.l("share.intake.deferred_busy")
            let outcome = ShareIntakeOutcome.deferred(
                envelopeID: envelope.id,
                reason: .anotherShareInProgress
            )
            lastOutcome = outcome
            return outcome
        } catch {
            await refresh()
            let message = FloeL10n.l("share.intake.discard_failed")
            lastErrorMessage = message
            let outcome = ShareIntakeOutcome.failed(envelopeID: envelope.id, message: message)
            lastOutcome = outcome
            return outcome
        }
    }

    func suspendForBackground() async {
        beginStorageSuspension()
        let task = activeApplication
        await task?.value
    }

    func beginStorageSuspension() {
        storageSuspended = true
        activeApplication?.cancel()
    }

    func resumeAfterSuspension() async {
        storageSuspended = false
        await refresh()
    }
}
#endif
