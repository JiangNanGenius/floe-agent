// FloeApp — Per-conversation composer draft store.
//
// SPDX-License-Identifier: MPL-2.0
//
// The shared composer's draft lives in the view model while a page is open,
// but switching tasks, backgrounding or quitting the app must not lose an
// unsent prompt. This store is the app-owned persistence seam behind that
// guarantee:
//
// - One entry per conversation (plus one stable entry for the Home
//   launchpad draft), holding the full text, staged attachments, the last
//   selection and a monotonically increasing revision.
// - Every mutation runs on the main actor and stamps the next revision;
//   callers that captured an older revision (voice-merge, editor commit)
//   pass it back as `expectedRevision` and a stale write is rejected
//   instead of overwriting newer text. `clear` keeps a revision floor per
//   conversation so a stale writer can never match a restarted sequence.
// - Disk writes are debounced per keystroke. Serialization and the atomic
//   write run on a serial background queue against a snapshot captured on
//   the main actor (a 100k-character, many-conversation store must not
//   block a keystroke); snapshots carry a monotonic revision and a
//   superseded snapshot is skipped. Lifecycle transitions flush the newest
//   snapshot with a bounded wait, and a failed or corrupt write is
//   reported (`lastWriteState`) instead of being swallowed.
// - An EXTERNAL import into an already-open task composer lands through the
//   bounded live/durable synchronization contract (`ImportedDraftLanding`):
//   the proven-landing delta (stable receipt + item ids, never a content
//   match) is published and synchronously absorbed by every live owner of
//   exactly that conversation, and a live save whose revision was superseded
//   rebases onto the durable entry instead of blind-overwriting it, so the
//   next keystroke can never drop landed refs. A failed durable commit
//   publishes nothing, so no source is ever acknowledged for bytes the disk
//   does not hold. `.landed` requires the NEWEST reconciled snapshot to be
//   verified on the serial writer: if a human edit interleaves during a
//   placement's disk wait, the proven delta is re-applied onto the newer
//   slot and THAT write is awaited and verified too (bounded attempts) —
//   a mere `flush()` of the reconciliation is never accepted as proof, so
//   the source can never be acknowledged ahead of the durable result. The
//   durable snapshot also carries an `ImportedDraftProof` of the landed
//   delta, which makes the disk receipt check content-aware: an earlier
//   placement's receipt can no longer prove an ack after a later persisted
//   human snapshot dropped the imported bytes (the source then re-lands).
// - A Shortcuts inbox handoff is proven by an exact `ShortcutHandoffReceipt`
//   (destination + entry id + claim token) serialized in the SAME snapshot
//   as the placed text. The claim is acknowledged only against a receipt the
//   write pipeline verified on disk — never inferred from text content,
//   never from in-memory state. Ordinary edits, clears and sends preserve
//   unsettled receipts until the source acknowledges them; a failed durable
//   write rolls back its own unverified placement (without touching newer
//   human content) so the slot stays retryable and no receipt ever proves
//   something the disk does not hold.
//
// Storage is a single JSON document in Application Support. An unreadable
// document is preserved beside the live file, never deleted. A future
// consolidation into FloePersistence would move the file, not the contract.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit
import FloeCore
import FloeModels

@MainActor
final class ComposerDraftStore: ObservableObject {

    struct Entry: Codable, Equatable {
        var text: String
        var attachments: [AttachmentRef]
        var revision: Int
        var updatedAt: Date
        var selectionLocation: Int?
        var selectionLength: Int?

        /// Stored caret/selection, nil when nothing was captured yet.
        var selection: NSRange? {
            guard let selectionLocation else { return nil }
            return NSRange(location: selectionLocation, length: selectionLength ?? 0)
        }
    }

    /// Identity of the draft text at the moment a send consumed it.
    ///
    /// String equality is not identity: while a send is awaiting its run the
    /// user can edit A → B → A, and the stored text compares equal to the
    /// sent one again even though it is a brand-new draft. A token captured
    /// with `sendCommitToken(for:)` pins the exact text generation, and a
    /// commit may clear the stored text only while that generation is
    /// unchanged. Attachment-only and selection-only updates never advance
    /// the text generation, so staging a file during a send never keeps the
    /// sent prompt alive.
    struct SendCommitToken: Equatable, Sendable {
        fileprivate let conversationID: UUID
        fileprivate let textGeneration: Int
    }

    struct SendHandoffUpdate {
        enum Phase { case began, accepted, failed }
        var conversationID: UUID
        var phase: Phase
        var entry: Entry?
    }
    @Published private(set) var sendHandoffUpdate: SendHandoffUpdate?
    private struct PendingSend {
        var conversationID: UUID
        var token: SendCommitToken
        var text: String
        var attachments: [AttachmentRef]
    }
    /// A projection over the SAME durable draft, not another draft store.
    /// While launch is pending the underlying bytes remain recoverable after
    /// process death, but reconstructed editors cannot present sent content.
    private var pendingSends: [UUID: PendingSend] = [:]

    private func pendingSend(for id: UUID) -> PendingSend? {
        pendingSends.values.first { pending in
            pending.conversationID == id && pending.token.textGeneration == (textGenerations[id] ?? 0)
        }
    }

    func beginSendHandoff(id: UUID, conversationID: UUID, text: String, attachments: [AttachmentRef]) {
        if pendingSends[id] != nil { return }
        // Called before the first await, while the live editor is authoritative.
        // Flush a final keystroke whose SwiftUI onChange has not run yet.
        // Read the proven slot state: an import placement that is still
        // awaiting disk verification must not be pulled into this send's
        // content (the launch itself never carries it — the live field has
        // not absorbed an unproven landing).
        let current = provenStoredEntry(for: conversationID)
        let sentIDs = Set(attachments.map(\.id))
        if current?.text != text || !sentIDs.isSubset(of: Set(current?.attachments.map(\.id) ?? [])) {
            let existing = current?.attachments ?? []
            let merged = existing + attachments.filter { value in !existing.contains(where: { $0.id == value.id }) }
            save(text: text, attachments: merged, conversationID: conversationID)
        }
        pendingSends[id] = PendingSend(conversationID: conversationID,
                                      token: sendCommitToken(for: conversationID), text: text, attachments: attachments)
        sendHandoffUpdate = .init(conversationID: conversationID, phase: .began, entry: entry(for: conversationID))
    }

    @discardableResult
    func acceptSendHandoff(id: UUID) -> Bool {
        guard let pending = pendingSends.removeValue(forKey: id) else { return false }
        clearAfterSend(conversationID: pending.conversationID, sentText: pending.text,
                       sentAttachments: pending.attachments, sendToken: pending.token)
        sendHandoffUpdate = .init(conversationID: pending.conversationID, phase: .accepted, entry: entry(for: pending.conversationID))
        return true
    }

    @discardableResult
    func failSendHandoff(id: UUID, allowTextRecovery: Bool) -> Bool {
        guard let pending = pendingSends.removeValue(forKey: id) else { return false }
        let matches = pending.token.textGeneration == (textGenerations[pending.conversationID] ?? 0)
        if !allowTextRecovery && matches {
            clearAfterSend(conversationID: pending.conversationID, sentText: pending.text,
                           sentAttachments: pending.attachments, sendToken: pending.token)
        }
        sendHandoffUpdate = .init(conversationID: pending.conversationID, phase: .failed, entry: entry(for: pending.conversationID))
        return matches && allowTextRecovery
    }

    /// Durable proof that ONE exact Shortcuts inbox entry was placed into
    /// ONE destination composer slot.
    ///
    /// A receipt is serialized inside the same snapshot as the placed text,
    /// so a snapshot that reaches disk carries the text and its receipt
    /// atomically. A claim may be acknowledged only while this exact receipt
    /// is verified ON DISK — never inferred from text content (unrelated
    /// human prose can contain the same phrase; distinct queue entries can
    /// carry identical payloads) and never from in-memory state alone (a
    /// failed write proves nothing). The claim token is part of the
    /// identity: releasing a claim rotates it in the source store, so a
    /// receipt from an abandoned delivery can never settle a newer handoff.
    /// OWNERSHIP INVARIANT: a receipt may only be staged in the SAME
    /// main-actor turn in which the destination composer synchronously
    /// accepted the text (render-before-persist). A landed receipt therefore
    /// always proves a placement that actually reached the visible composer;
    /// there is no durable state for "placed but unrendered", and a crash
    /// before a later ack can only settle a real acceptance.
    struct ShortcutHandoffReceipt: Codable, Equatable, Hashable {
        let destinationID: String
        let entryID: UUID
        let claimToken: String

        init(destinationID: String, entryID: UUID, claimToken: String) {
            self.destinationID = destinationID
            self.entryID = entryID
            self.claimToken = claimToken
        }
    }

    /// Outcome of the durable write pipeline. The composer surfaces
    /// `.failed` so a save problem is visible; nothing is silently dropped.
    enum WriteState: Equatable {
        case idle
        case pending
        case failed(message: String)

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    // MARK: - External import live/durable synchronization

    /// One PROVEN-durable external import landing for one conversation slot.
    ///
    /// `incomingText` and `addedAttachments` are the exact delta the intake
    /// pipeline appended (stable receipt/item ids — never a text-containment
    /// guess), so a live editor can fold the import into whatever the human
    /// typed meanwhile without duplicating it or losing either side.
    /// `landedRevision` is the durable revision the landing wrote: a live
    /// owner compares its own adopted revision instead of guessing whether
    /// its field already contains the import, and a reconstructed editor
    /// (which read the durable entry at init) fences the same landing out.
    /// A landing is published ONLY after `commitDurable` verified the bytes
    /// on disk — a failed commit publishes nothing and the source is never
    /// acknowledged. `landingID` is stable per receipt AND claim token, so a
    /// retry after a disk failure is a fresh landing while an already
    /// settled receipt can never fold twice.
    struct ImportedDraftLanding: Equatable {
        let landingID: String
        let conversationID: UUID
        /// Durable revision the landing replaced (nil: the slot was empty).
        let baseRevision: Int?
        /// Durable revision immediately after the verified commit.
        let landedRevision: Int
        /// Full merged text as committed durably.
        let landedText: String
        /// Full merged attachment list as committed durably.
        let landedAttachments: [AttachmentRef]
        /// Raw external text delta (may be empty for a files-only share).
        let incomingText: String
        /// Incoming refs that were NOT already durable at `baseRevision`.
        let addedAttachments: [AttachmentRef]
        let receipt: ShortcutHandoffReceipt
    }

    /// The exact landed delta of one external import, serialized in the
    /// SAME snapshot as the placement it proves.
    ///
    /// `handoffReceiptOnDisk` is deliberately content-aware for a receipt
    /// that has a proof: the receipt alone may only acknowledge an import
    /// while the most recent snapshot that actually reached disk still
    /// carries the incoming text and every incoming item id. A later
    /// persisted human snapshot that dropped the imported bytes therefore
    /// cannot acknowledge on an earlier placement's receipt — the intake
    /// re-lands the envelope instead. Ordinary (non-import) handoff receipts
    /// have no proof and keep their existing pure ledger semantics.
    struct ImportedDraftProof: Codable, Equatable, Hashable {
        let landingID: String
        let conversationID: UUID
        let receipt: ShortcutHandoffReceipt
        let incomingText: String
        let incomingAttachmentIDs: [UUID]
    }

    /// Outcome of `acceptImportedDraft`. `.landed` is the ONLY result that
    /// may acknowledge the source envelope, and it is returned only after
    /// the NEWEST reconciled snapshot — interleaved human content plus the
    /// proven imported delta plus the receipt — is verified on the serial
    /// writer (see `acceptImportedDraft`). `.deferredBusy` is a normal busy
    /// deferral (never a user error): the slot is mid-send or a send
    /// handoff is in flight, the source stays pending and recoverable.
    /// `.rejectedTarget` refuses a non-durable destination (a temporary
    /// chat); a failed durable write returns `.failed` with THIS attempt's
    /// unverified placement rolled back (nothing of it staged as proven),
    /// so the placement stays retryable. When the failure follows an
    /// EARLIER verified placement in the same loop, that earlier landing
    /// stays honestly proven: the intake must then retain the staged files
    /// its durable snapshot references (ShareIntakeCenter's durable-proof
    /// rule) instead of creating dangling refs.
    enum ImportedDraftLandingResult: Equatable {
        case landed(revision: Int)
        case deferredBusy
        case rejectedTarget
        case failed
    }

    /// A live composer that can synchronously absorb an import landing in
    /// the landing's own main-actor turn (render-before-ack). Implemented by
    /// `ThreadDetailViewModel`; the weak owner registry below is also the
    /// exact `hasLiveOwner` answer the import destination seam needs, so a
    /// replaced view can neither be addressed nor clobber a landed import.
    @MainActor
    protocol ImportedDraftLiveAccepting: AnyObject {
        func acceptImportedDraftLanding(_ landing: ComposerDraftStore.ImportedDraftLanding)
    }

    /// Stable identity of one landing: the destination slot plus the exact
    /// envelope receipt. Two different envelopes never collapse, and a
    /// re-claimed envelope after a failed commit carries a new claim token.
    static func importedDraftLandingID(
        conversationID: UUID, receipt: ShortcutHandoffReceipt
    ) -> String {
        "slot=\(conversationID.uuidString.lowercased())"
            + "/dest=\(receipt.destinationID)"
            + "/entry=\(receipt.entryID.uuidString)"
            + "/token=\(receipt.claimToken)"
    }

    /// The most recent proven import landing across all slots. Published on
    /// the main actor; readers MUST fence by `conversationID` (and by their
    /// own adopted revision) so a landing for another task — or one a
    /// reconstructed editor already restored from disk — is never folded.
    @Published private(set) var latestImportedDraftLanding: ImportedDraftLanding?

    @MainActor
    private final class WeakLiveDraftOwner {
        weak var owner: (any ImportedDraftLiveAccepting)?
        init(_ owner: any ImportedDraftLiveAccepting) { self.owner = owner }
    }

    /// Weak registry of the composers currently open per conversation. A
    /// released view model disappears without any explicit teardown, so a
    /// replaced view cannot be addressed, and `hasLiveDraftOwner` stays
    /// honest for the import destination's deferral decision.
    private var liveDraftOwners: [UUID: [WeakLiveDraftOwner]] = [:]
    /// Landing ids already folded into a live editor or a rebased live save.
    /// Bounded FIFO: it only ever guards the small window between a durable
    /// landing and the live fold that consumes it.
    private var absorbedImportLandingIDs: Set<String> = []
    private var absorbedImportLandingOrder: [String] = []
    private static let absorbedImportLandingLimit = 64

    /// Registers the composer currently open for a conversation. Ordinary
    /// durable slots only; a temporary chat is never an import destination.
    func registerLiveDraftOwner(
        _ owner: any ImportedDraftLiveAccepting, for conversationID: UUID
    ) {
        guard !temporaryExcludedIDs.contains(conversationID) else { return }
        var boxes = liveDraftOwners[conversationID] ?? []
        boxes.removeAll { $0.owner == nil }
        guard !boxes.contains(where: { $0.owner === owner }) else { return }
        boxes.append(WeakLiveDraftOwner(owner))
        liveDraftOwners[conversationID] = boxes
    }

    /// True while at least one live composer owns this conversation's draft.
    func hasLiveDraftOwner(for conversationID: UUID) -> Bool {
        guard var boxes = liveDraftOwners[conversationID] else { return false }
        boxes.removeAll { $0.owner == nil }
        liveDraftOwners[conversationID] = boxes.isEmpty ? nil : boxes
        return !boxes.isEmpty
    }

    /// A durable import placement whose bytes are NOT yet verified on disk.
    ///
    /// `commitDurable` must write the merged text into the shared slot before
    /// awaiting the serial write queue, because the receipt and its placed
    /// text have to reach disk as ONE atomic snapshot. That creates a real
    /// window in which the placement exists in memory but proves nothing yet,
    /// so every external READ path treats the slot as its proven pre-placement
    /// state while the commit is in flight: a live rebased save (which unions
    /// durable refs), a reconstructed editor, `refreshDraftFromDurableStore`
    /// and the destination snapshot can never absorb or union an unproven
    /// imported ref — otherwise a failed write plus the source's staged-file
    /// discard would leave the draft pointing at deleted bytes. The fence is
    /// armed per placement attempt: once one snapshot's bytes are verified
    /// the fence drops for it, and if a human edit during the suspension had
    /// already replaced the slot, `acceptImportedDraft` re-applies the PROVEN
    /// delta onto that newer content as a NEW placement — fenced and
    /// disk-verified again — before it may report `.landed`.
    private struct PendingImportedCommit {
        let conversationID: UUID
        /// The proven slot state before this placement (what readers see).
        let baseEntry: Entry?
        /// Revision the placement wrote; set synchronously by `commitDurable`.
        var placementRevision: Int?
        let incomingText: String
        let incomingAttachments: [AttachmentRef]
    }

    private var pendingImportedCommit: PendingImportedCommit?

    /// True while a durable import placement for this slot is still awaiting
    /// disk verification. This is real in-flight import ownership (the answer
    /// an import destination must treat as busy), NOT mere live-editor
    /// presence: an open composer alone never blocks an import landing.
    func isImportedDraftCommitInFlight(for conversationID: UUID) -> Bool {
        guard let pending = pendingImportedCommit else { return false }
        guard pending.conversationID == conversationID else { return false }
        // Only the placement's own revision is unproven content; once any
        // later writer moved the slot the fence no longer describes it.
        return bucket(for: conversationID)[conversationID]?.revision == pending.placementRevision
    }

    /// Bounded reconciliation attempts. Every attempt is a full fenced,
    /// disk-verified placement; exhaustion means the human writer keeps
    /// moving the slot faster than the serial queue lands snapshots — a
    /// normal busy deferral, never a false `.landed`.
    private static let importLandingAttemptLimit = 4

    /// The bounded live/durable landing entrypoint for ONE confirmed external
    /// import into an existing durable task draft. It reuses the exact
    /// `ShareDraftMerger` rules and the `commitDurable` receipt/CAS pipeline,
    /// then — only on verified disk success — publishes the landing and
    /// synchronously folds it into EVERY live owner of exactly this
    /// conversation in the same main-actor turn (render-before-ack: the
    /// source may be acknowledged only once the visible composer accepted
    /// the placement). A human edit made while bytes staged or the durable
    /// write ran is preserved: the merge base is the durable entry the live
    /// editor itself last saved, and a landing the view has not absorbed is
    /// re-applied by `liveRebasedDraft` on that editor's next save rather
    /// than being silently overwritten.
    ///
    /// The ack guarantee: a verified placement whose slot was replaced by a
    /// newer interleaved human write is NOT acked on its earlier receipt.
    /// The proven delta is re-applied onto the newer slot content as a new
    /// placement and THAT snapshot is awaited and disk-verified too, so
    /// `.landed` means the most recent durable snapshot carries the human
    /// content, the imported delta exactly once, and the receipt — a store
    /// reconstructed from disk at that instant proves all of it. Ownership
    /// while unresolved: every awaited placement suspends this call on the
    /// serial writer's ACTUAL verdict — there is no wall-clock timeout that
    /// could return a failure while the submitted write can still publish
    /// imported refs to disk. Until that verdict arrives nothing is
    /// published, no result reaches the intake, and therefore no source ack
    /// or staged-file discard can race an in-flight placement; only the
    /// bounded attempt loop can extend the deferral, and it never reports a
    /// false `.landed`. It suspends instead of parking the main actor.
    func acceptImportedDraft(
        conversationID: UUID,
        incomingText: String,
        incomingAttachments: [AttachmentRef],
        receipt: ShortcutHandoffReceipt
    ) async -> ImportedDraftLandingResult {
        // Imports are durable task drafts only: the ephemeral RAM bucket is
        // never a durable destination, and a mid-send slot is owned by that
        // send until its outcome is known (a normal busy deferral).
        guard !temporaryExcludedIDs.contains(conversationID) else { return .rejectedTarget }
        if let handoff = sendHandoffUpdate, handoff.conversationID == conversationID,
           handoff.phase == .began {
            return .deferredBusy
        }
        // One unverified placement per process: a second concurrent apply for
        // any slot must wait for the first verdict (normal busy deferral).
        guard pendingImportedCommit == nil else { return .deferredBusy }
        guard !Task.isCancelled else { return .deferredBusy }
        let base = bucket(for: conversationID)[conversationID]
        let durableIDs = Set(base?.attachments.map(\.id) ?? [])
        let landingID = Self.importedDraftLandingID(conversationID: conversationID, receipt: receipt)
        let proof = ImportedDraftProof(
            landingID: landingID,
            conversationID: conversationID,
            receipt: receipt,
            incomingText: incomingText,
            incomingAttachmentIDs: incomingAttachments.map(\.id)
        )
        var previous = base
        for _ in 0..<Self.importLandingAttemptLimit {
            if Task.isCancelled {
                pendingImportedCommit = nil
                return .deferredBusy
            }
            let mergedText = ShareDraftMerger.mergedText(
                existing: previous?.text ?? "", incoming: incomingText
            )
            let mergedAttachments = ShareDraftMerger.mergedAttachments(
                existing: previous?.attachments ?? [], incoming: incomingAttachments
            )
            pendingImportedCommit = PendingImportedCommit(
                conversationID: conversationID,
                baseEntry: previous,
                placementRevision: nil,
                incomingText: incomingText,
                incomingAttachments: incomingAttachments
            )
            let committed = await commitDurable(
                text: mergedText,
                attachments: mergedAttachments,
                conversationID: conversationID,
                expectedRevision: previous?.revision,
                handoff: receipt,
                landingProof: proof,
                onPlacement: { [weak self] revision in
                    guard let self, self.pendingImportedCommit?.conversationID == conversationID else { return }
                    self.pendingImportedCommit?.placementRevision = revision
                }
            )
            let placementRevision = pendingImportedCommit?.placementRevision
            pendingImportedCommit = nil
            let slot = bucket(for: conversationID)[conversationID]
            guard committed else {
                // No bytes verified for this attempt: nothing published,
                // nothing acked, and `commitDurable` rolled back this
                // attempt's unverified placement, receipt AND proof. The
                // unproven placement was never visible to a live rebased
                // save, a reconstructed editor or a refresh (see
                // `PendingImportedCommit`), so no draft can be holding a ref
                // whose staged file the intake may now discard — unless an
                // EARLIER attempt in this loop verified a placement that the
                // disk still carries, which keeps the receipt proven and
                // forces the intake side to retain the staged copies.
                return .failed
            }
            if Task.isCancelled, slot?.revision == placementRevision {
                // A cancel after the bytes landed but before the fold must
                // not publish or ack: the envelope stays pending, and the
                // next pass settles it against the proven, content-satisfied
                // receipt (or re-lands it when the disk moved on).
                return .deferredBusy
            }
            if let slot, slot.revision == placementRevision {
                // Verified AND still authoritative: this snapshot is the
                // newest durable state, so an immediate reconstruction from
                // disk proves human content + imported delta + receipt.
                let landing = ImportedDraftLanding(
                    landingID: landingID,
                    conversationID: conversationID,
                    baseRevision: base?.revision,
                    landedRevision: slot.revision,
                    landedText: slot.text,
                    landedAttachments: slot.attachments,
                    incomingText: incomingText,
                    addedAttachments: incomingAttachments.filter { !durableIDs.contains($0.id) },
                    receipt: receipt
                )
                latestImportedDraftLanding = landing
                let owners = (liveDraftOwners[conversationID] ?? []).compactMap { $0.owner }
                for owner in owners {
                    owner.acceptImportedDraftLanding(landing)
                }
                return .landed(revision: landing.landedRevision)
            }
            // Verified, but a newer human write (or a clear) replaced the
            // slot during the disk wait. The human content is never rolled
            // back; the proven delta is re-applied onto it as a fresh
            // fenced placement that must itself reach disk before any ack.
            previous = slot
        }
        // The human writer kept racing the serial queue through every
        // bounded attempt: nothing published, nothing acked. The envelope
        // stays pending and recoverable; a later retry merges onto the
        // (now quiesced) slot exactly once through the same pipeline.
        return .deferredBusy
    }

    /// True once a landing was folded into a live editor or a rebased live
    /// save: the exact-delta fold must run at most once per landing, and
    /// every later writer keeps whatever the durable entry already holds.
    func isImportLandingAbsorbed(_ landingID: String) -> Bool {
        absorbedImportLandingIDs.contains(landingID)
    }

    /// Called by the live owner after it absorbed the landing (or by a
    /// rebased save that folded it), so no second writer appends the same
    /// imported delta again.
    func markImportLandingAbsorbed(_ landingID: String) {
        guard absorbedImportLandingIDs.insert(landingID).inserted else { return }
        absorbedImportLandingOrder.append(landingID)
        while absorbedImportLandingOrder.count > Self.absorbedImportLandingLimit {
            let retired = absorbedImportLandingOrder.removeFirst()
            absorbedImportLandingIDs.remove(retired)
        }
    }

    /// Rebase a live editor's save after its CAS was rejected — an external
    /// landing (or another writer) advanced the durable entry while this
    /// keystroke was in flight. The field stays the human truth for its own
    /// text, but durable refs are unioned by stable id, so a landed import
    /// can never be dropped by a stale live list, and the newest proven
    /// landing THIS slot has not absorbed yet is folded in exactly once.
    /// Ordinary multiwindow text last-writer behavior is deliberately
    /// unchanged: only imported deltas get the fold fence.
    func liveRebasedDraft(
        text: String,
        attachments: [AttachmentRef],
        conversationID: UUID,
        knownRevision: Int?
    ) -> (text: String, attachments: [AttachmentRef]) {
        // Read the PROVEN durable state: an import placement still awaiting
        // disk verification is not unioned in (see `PendingImportedCommit`),
        // so a failed write plus the source's staged-file discard can never
        // leave a newer human revision pointing at deleted bytes.
        let durable = entry(for: conversationID)
        var mergedText = text
        var mergedAttachments = ShareDraftMerger.mergedAttachments(
            existing: durable?.attachments ?? [], incoming: attachments
        )
        if let landing = latestImportedDraftLanding,
           landing.conversationID == conversationID,
           (knownRevision ?? 0) < landing.landedRevision,
           !isImportLandingAbsorbed(landing.landingID) {
            mergedText = ShareDraftMerger.mergedText(
                existing: mergedText, incoming: landing.incomingText
            )
            mergedAttachments = ShareDraftMerger.mergedAttachments(
                existing: mergedAttachments, incoming: landing.addedAttachments
            )
            markImportLandingAbsorbed(landing.landingID)
        }
        return (mergedText, mergedAttachments)
    }

    /// Stable identity for the Home launchpad draft. Independent of the
    /// per-launch draft conversation UUID that Home rotates after each send.
    nonisolated static var homeDraftID: UUID {
        if isHomeComposerUITestEnabled {
            return UUID(uuidString: "B8C9FB32-82EC-4D16-BEA3-29DA33B18302")!
        }
        return UUID(uuidString: "8F4D0A6E-3B1C-4E2A-9D55-2C8F1A77E010")!
    }

    /// A separate DEBUG-only draft identity protects the reused simulator's
    /// unsent Home draft; no qualification text can overwrite that slot.
    nonisolated static var isHomeComposerUITestEnabled: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-ui-testing") && args.contains("--ui-test-home-composer")
        #else
        return false
        #endif
    }

    static let shared = ComposerDraftStore()

    /// Debounce window for persisting typing bursts.
    static let writeDebounce: DispatchTimeInterval = .milliseconds(300)

    /// Visible result of the most recent save attempt.
    @Published private(set) var lastWriteState: WriteState = .idle

    private var entries: [UUID: Entry]
    /// Unsettled handoff receipts keyed by inbox entry id, so distinct
    /// entries with identical payloads stay distinct. Serialized with every
    /// snapshot (never with drafts alone) and deliberately NOT bucketed:
    /// temporary-chat ids never receive inbox handoffs, and the receipt
    /// survives ordinary edits, clears and sends until its source settles.
    private var handoffs: [UUID: ShortcutHandoffReceipt] = [:]
    /// Landed external-import deltas keyed by stable landing id. Serialized
    /// with every snapshot (like the receipt ledger) so a placement's exact
    /// delta reaches disk ATOMICALLY with its receipt, and `settleHandoff`
    /// (after the source ack) retires both together.
    private var landingProofs: [String: ImportedDraftProof] = [:]
    /// Temporary-chat drafts live in a RAM-only bucket: `submitSnapshot`
    /// serializes `entries` alone (plus the durable receipt ledger), so
    /// lifecycle flushes can never persist an ephemeral draft, regardless
    /// of when the exclusion flag changes.
    private var ephemeralEntries: [UUID: Entry] = [:]
    /// Conversation ids whose drafts must stay in `ephemeralEntries`.
    private var temporaryExcludedIDs: Set<UUID> = []
    /// A load failure stays visible until one healthy snapshot is written, so
    /// the notice cannot disappear on the first flush before anything new was
    /// actually persisted.
    private var pendingLoadFailure: String?
    /// Highest revision ever issued per conversation. `clear` removes the
    /// entry but keeps this floor, so a stale async writer holding an older
    /// revision is still rejected after the sequence would have restarted.
    private var revisionFloor: [UUID: Int] = [:]
    /// Monotonic identity of each conversation's *text* alone: every real
    /// text change advances it (even one that returns to an earlier string),
    /// while attachment-only and selection-only updates do not. Send commits
    /// compare it instead of string equality. Deliberately in-memory: a token
    /// only has to outlive one in-flight send, and a relaunch starts a new
    /// draft epoch anyway.
    private var textGenerations: [UUID: Int] = [:]
    private let fileURL: URL
    private let writeQueue: DispatchQueue
    /// Monotonic revision of the in-memory snapshot, bumped by every
    /// mutation. Snapshots are submitted with it; an older snapshot that is
    /// still queued when a newer one arrives is skipped.
    private var snapshotVersion: UInt64 = 0
    private var submittedVersion: UInt64 = 0
    private let writer = DraftWriteTracker()
    private var pendingWrite: DispatchWorkItem?
    private var cancellables: [NSObjectProtocol] = []

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ComposerDrafts", isDirectory: true)
        self.init(fileURL: base.appendingPathComponent("drafts.json"))
    }

    init(fileURL: URL, writeQueue: DispatchQueue? = nil) {
        self.fileURL = fileURL
        // Deliberately no explicit QoS class: an item submitted from the main
        // actor runs at that thread's class. `flushAndWait` PARKS the main
        // thread while it waits for this queue, so a queue pinned to a lower
        // class inverts the dependency and the write attempt can miss the
        // deadline even though nothing is wrong on disk (canonical-iPad native
        // run: a blocked durable path plus a 1 s bounded flush left
        // `lastWriteState` `.pending` because the utility work item had not
        // run yet). Serialization still never runs on the main thread, so
        // keystrokes are not delayed; only the awaited durability work
        // inherits the class of the thread waiting for it.
        self.writeQueue = writeQueue ?? DispatchQueue(
            label: "app.floe.composer-drafts.write"
        )
        var loaded: [UUID: Entry] = [:]
        var loadedHandoffs: [UUID: ShortcutHandoffReceipt] = [:]
        var loadedLandingProofs: [String: ImportedDraftProof] = [:]
        var loadFailure: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let document = try Self.decodeDocument(Self.readData(from: fileURL))
                loaded = document.drafts
                loadedHandoffs = document.handoffs
                loadedLandingProofs = document.landingProofs
            } catch {
                // Never discard the user's unreadable input: keep a copy for
                // recovery, start from an empty map and report the failure.
                let preserved = Self.preserveCorruptFile(at: fileURL)
                let preservedName = preserved?.lastPathComponent ?? FloeL10n.l("chat.composer_draft_store.not_kept")
                loadFailure = FloeL10n.l("chat.composer_draft_store.the_draft_file_could_not_be", preservedName, error.localizedDescription)
                FloeLogger(category: .app).error(
                    "composerDraftStoreDecodeFailed preserved=\(preservedName) error=\(error.localizedDescription)"
                )
            }
        }
        self.entries = loaded
        self.handoffs = loadedHandoffs
        self.landingProofs = loadedLandingProofs
        // A successfully loaded document IS the disk state: its receipts are
        // proven on disk (this is the crash-between-durable-write-and-ack
        // recovery path), and its draft map is the baseline the content-aware
        // import proof reads. A missing file or a failed decode proves
        // nothing, so the verified set stays empty and no claim can be
        // acknowledged until a future write lands.
        if loadFailure == nil {
            writer.seedPersisted(receipts: Set(loadedHandoffs.values), drafts: loaded)
        }
        if let loadFailure {
            self.pendingLoadFailure = loadFailure
            self.lastWriteState = .failed(message: loadFailure)
        }
        // Flushing on lifecycle transitions keeps "switch task / background
        // / quit" lossless even when the debounce window has not elapsed.
        // Backgrounding and termination wait (bounded) for the newest
        // snapshot; resigning active is a quick non-blocking flush.
        let center = NotificationCenter.default
        cancellables = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.flushForLifecycle(timeout: 2) }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.flush() } },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.flushForLifecycle(timeout: 2) }
            },
        ]
    }

    // MARK: - Reads

    /// Slot state with any unverified in-flight import placement hidden, but
    /// WITHOUT the pending-send projection. Send bookkeeping must keep its
    /// own raw comparison semantics, yet it may never carry an unproven
    /// imported ref into a newer revision: if the write then fails, the source
    /// discards those staged bytes and the draft would point at deleted files.
    /// A later successful landing re-applies the proven delta onto whatever
    /// the send produced (see `acceptImportedDraft`).
    private func provenStoredEntry(for conversationID: UUID) -> Entry? {
        if let pending = pendingImportedCommit, pending.conversationID == conversationID,
           bucket(for: conversationID)[conversationID]?.revision == pending.placementRevision {
            return pending.baseEntry
        }
        return bucket(for: conversationID)[conversationID]
    }

    /// Public read surface. Live rebased saves, reconstructed editors,
    /// `ThreadDetailViewModel.refreshDraftFromDurableStore` and the import
    /// destination snapshot all read through here, so an unproven imported
    /// ref is never unioned into a newer human revision or rendered as if it
    /// were durable. The write pipeline itself uses `bucket(for:)`, so the
    /// receipt and its placed text still reach disk as ONE snapshot.
    func entry(for conversationID: UUID) -> Entry? {
        guard var value = provenStoredEntry(for: conversationID) else { return nil }
        if let pending = pendingSend(for: conversationID), value.text == pending.text {
            value.text = ""
            let sentIDs = Set(pending.attachments.map(\.id))
            value.attachments.removeAll { sentIDs.contains($0.id) }
            value.selectionLocation = nil; value.selectionLength = nil
        }
        return value
    }

    func text(for conversationID: UUID) -> String {
        entry(for: conversationID)?.text ?? ""
    }

    func attachments(for conversationID: UUID) -> [AttachmentRef] {
        entry(for: conversationID)?.attachments ?? []
    }

    private func bucket(for conversationID: UUID) -> [UUID: Entry] {
        temporaryExcludedIDs.contains(conversationID) ? ephemeralEntries : entries
    }

    private func setEntry(_ entry: Entry?, for conversationID: UUID) {
        if temporaryExcludedIDs.contains(conversationID) {
            ephemeralEntries[conversationID] = entry
        } else {
            entries[conversationID] = entry
        }
    }

    /// Installed by ConversationCenter when a conversation enters or leaves
    /// temporary mode. Excluded ids never touch the serialized bucket; the
    /// RAM copy is dropped on unexclude so no ephemeral text can flush late.
    func setTemporaryDraftExcluded(_ conversationID: UUID, _ excluded: Bool) {
        if excluded {
            temporaryExcludedIDs.insert(conversationID)
        } else {
            temporaryExcludedIDs.remove(conversationID)
            ephemeralEntries.removeValue(forKey: conversationID)
        }
    }

    /// Moves the RAM-only ephemeral draft into the durable bucket, keeping
    /// the text and staged attachments and preserving revision monotonicity
    /// (the entry continues above both the old ephemeral revision and the
    /// durable floor, so an async A→B→A merge can never resurrect a stale
    /// generation). Called by ConversationCenter ONLY on a successful
    /// Keep-as-saved promotion; End keeps dropping.
    @discardableResult
    func moveEphemeralEntryToDurable(for conversationID: UUID) -> Entry? {
        guard temporaryExcludedIDs.contains(conversationID),
              let ephemeral = ephemeralEntries[conversationID] else { return nil }
        var migrated = ephemeral
        migrated.revision = max(
            ephemeral.revision,
            entries[conversationID]?.revision ?? 0,
            revisionFloor[conversationID] ?? 0
        ) + 1
        migrated.updatedAt = Date()
        temporaryExcludedIDs.remove(conversationID)
        ephemeralEntries.removeValue(forKey: conversationID)
        entries[conversationID] = migrated
        markDirty()
        return migrated
    }

    /// Captures the identity of a conversation's text right now; pass the
    /// token to `clearAfterSend` so only that exact text can be committed
    /// away. A send that starts before any edit and commits after the user
    /// retyped the same string gets a mismatched token and keeps the draft.
    func sendCommitToken(for conversationID: UUID) -> SendCommitToken {
        SendCommitToken(
            conversationID: conversationID,
            textGeneration: textGenerations[conversationID] ?? 0
        )
    }

    // MARK: - Writes

    /// Stores the draft and returns the new revision. When `expectedRevision`
    /// is supplied it must match the stored one, otherwise the write is
    /// rejected as stale (returns nil) and newer text survives.
    @discardableResult
    func save(
        text: String,
        attachments: [AttachmentRef] = [],
        conversationID: UUID,
        selection: NSRange? = nil,
        expectedRevision: Int? = nil
    ) -> Int? {
        // Read the ROUTED bucket: for temporary ids the ephemeral entry holds
        // the current revision, so the guard below actually matches and the
        // fallback unguarded save stops running on every temp keystroke.
        let current = bucket(for: conversationID)[conversationID]
        if let expectedRevision, current?.revision != expectedRevision {
            return nil
        }
        let base = max(current?.revision ?? 0, revisionFloor[conversationID] ?? 0)
        let next = base + 1
        var entry = current ?? Entry(
            text: "", attachments: [], revision: 0,
            updatedAt: Date(), selectionLocation: nil, selectionLength: nil
        )
        // The text generation tracks the *text*: a real change always
        // advances it (A → B → A is two changes, never zero), while an
        // attachment-only update leaves it where it was.
        let pending = pendingSend(for: conversationID)
        let maskedEmpty = pending != nil && text.isEmpty && entry.text == pending?.text
        let storedText = maskedEmpty ? entry.text : text
        let textChanged = pending != nil ? (!maskedEmpty && !text.isEmpty) : storedText != entry.text
        if textChanged {
            textGenerations[conversationID, default: 0] += 1
        }
        entry.text = storedText
        if maskedEmpty, let pending {
            let sentIDs = Set(pending.attachments.map(\.id))
            let preserved = current?.attachments.filter { sentIDs.contains($0.id) } ?? []
            entry.attachments = preserved + attachments.filter { value in !preserved.contains(where: { $0.id == value.id }) }
        } else { entry.attachments = attachments }
        entry.revision = next
        entry.updatedAt = Date()
        if let selection {
            entry.selectionLocation = selection.location
            entry.selectionLength = selection.length
        }
        setEntry(entry, for: conversationID)
        markDirty()
        return next
    }

    /// Selection-only updates never bump the revision: caret moves are not
    /// draft edits and must not invalidate in-flight merge revisions.
    func updateSelection(_ selection: NSRange?, conversationID: UUID) {
        guard var entry = bucket(for: conversationID)[conversationID] else { return }
        entry.selectionLocation = selection?.location
        entry.selectionLength = selection?.length
        entry.updatedAt = Date()
        setEntry(entry, for: conversationID)
        markDirty()
    }

    /// Removes the draft after a successful send (or a deleted conversation).
    /// The revision floor stays behind, so a stale async writer holding an
    /// older revision is rejected instead of matching a fresh entry. The
    /// text generation advances too: text saved after a clear is a new draft,
    /// never the one a pre-clear send token captured.
    func clear(conversationID: UUID) {
        pendingSends = pendingSends.filter { $0.value.conversationID != conversationID }
        if sendHandoffUpdate?.conversationID == conversationID { sendHandoffUpdate = nil }
        // Always drop both buckets: exclusion state must never resurrect a
        // stale durable draft for a converted temporary id.
        var removed = entries.removeValue(forKey: conversationID)
        if let ephemeral = ephemeralEntries.removeValue(forKey: conversationID) {
            removed = removed ?? ephemeral
        }
        guard let removed else { return }
        revisionFloor[conversationID] = max(
            revisionFloor[conversationID] ?? 0, removed.revision
        )
        textGenerations[conversationID, default: 0] += 1
        markDirty()
    }

    /// Commits a successful send without erasing work started while the send
    /// was in flight:
    /// - the sent text is dropped only while the store still holds the exact
    ///   text generation the send started from (`sendToken`) and that text is
    ///   still the sent one (or the field was emptied as part of the send);
    ///   newer text — including a retyped A → B → A — survives,
    /// - only the attachment refs that were part of the send are dropped;
    ///   attachments staged during the send keep their own identity.
    /// A nil `sendToken` keeps the pre-identity text comparison for callers
    /// that do not capture a generation.
    /// Returns true when the entry existed and was reconciled.
    @discardableResult
    func clearAfterSend(
        conversationID: UUID,
        sentText: String,
        sentAttachments: [AttachmentRef] = [],
        sendToken: SendCommitToken? = nil
    ) -> Bool {
        guard let current = provenStoredEntry(for: conversationID) else { return false }
        let sentIDs = Set(sentAttachments.map(\.id))
        let remaining = current.attachments.filter { !sentIDs.contains($0.id) }
        let identityMatches = sendToken.map {
            $0.conversationID == conversationID
                && $0.textGeneration == (textGenerations[conversationID] ?? 0)
        } ?? true
        let consumedText = identityMatches
            && (current.text == sentText || current.text.isEmpty)
        if consumedText, remaining.isEmpty {
            clear(conversationID: conversationID)
            return true
        }
        var entry = current
        if consumedText { entry.text = "" }
        entry.attachments = remaining
        entry.revision = max(current.revision, revisionFloor[conversationID] ?? 0) + 1
        entry.updatedAt = Date()
        setEntry(entry, for: conversationID)
        markDirty()
        return true
    }

    // MARK: - Persistence

    /// Writes the latest in-memory state immediately, cancelling any
    /// debounced write. The snapshot is captured on the main actor; encoding
    /// and the atomic write happen on the serial background queue.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        submitSnapshot()
        syncWriteState()
    }

    /// Verified durable commit for ONE destination-checked handoff (the
    /// Shortcuts draft inbox). The debounced typing path acknowledges only an
    /// in-memory assignment; this primitive is the durable counterpart: it
    /// applies the exact write (rejected when `expectedRevision` no longer
    /// matches, so newer human content is never overwritten), stages the
    /// handoff receipt in the SAME snapshot as the placed text, cancels the
    /// pending debounce, submits immediately with a must-land guarantee (a
    /// placement snapshot is never skipped as "superseded" while its receipt
    /// would move on to a later snapshot — later snapshots may still carry
    /// the receipt, but the placed text itself is guaranteed to have reached
    /// disk), and suspends — without blocking the main thread — until the
    /// newest snapshot is on disk.
    ///
    /// Returns true ONLY when the bytes (text, receipt AND landing proof)
    /// are verified durable; callers may acknowledge their source record
    /// with that result and nothing less. The wait resolves exactly on the
    /// serial writer's ACTUAL completion of THIS snapshot — never a
    /// fire-and-forget flush presented as proof, and never a wall-clock
    /// timeout that could report failure while the submitted write can
    /// still land later and publish imported refs (the ownership invariant
    /// that makes the caller-side deferral safe: while this call is
    /// suspended nothing is published, no result reaches the intake, and no
    /// ack or staged-file discard can race an in-flight placement). It
    /// suspends instead of parking the main actor; boundedness comes from
    /// the serial pipeline itself (the must-land block runs exactly once)
    /// and from the caller's attempt loop. On a failed write the method
    /// rolls back exactly its own mutation: the shared slot is restored (so
    /// the handoff stays retryable and the failure does not leave an
    /// occupied slot that would block every later delivery) ONLY while the
    /// slot still holds this commit's content — a newer human edit, clear,
    /// or send during the suspension always wins and is never rolled back —
    /// and the unverified receipt and landing proof are removed (back to
    /// whatever a previous verified placement left), so a disk failure can
    /// never produce a receipt-backed ack of bytes the disk does not hold.
    func commitDurable(
        text: String,
        attachments: [AttachmentRef] = [],
        conversationID: UUID,
        expectedRevision: Int?,
        handoff: ShortcutHandoffReceipt? = nil,
        landingProof: ImportedDraftProof? = nil,
        onPlacement: (@MainActor (Int) -> Void)? = nil
    ) async -> Bool {
        let previous = bucket(for: conversationID)[conversationID]
        let previousReceipt = handoff.flatMap { handoffs[$0.entryID] }
        let previousProof = landingProof.flatMap { landingProofs[$0.landingID] }
        guard save(
            text: text, attachments: attachments,
            conversationID: conversationID, expectedRevision: expectedRevision
        ) != nil else { return false }
        let commitRevision = bucket(for: conversationID)[conversationID]?.revision
        if let commitRevision {
            // Synchronous placement report BEFORE the disk wait: the import
            // landing fence records exactly which revision is unproven, so no
            // reader or rebased live save can treat the placement as durable
            // while this call is suspended.
            onPlacement?(commitRevision)
        }
        if let handoff {
            // Same main-actor turn as the save above: the snapshot submitted
            // below serializes text, receipt and landing proof as ONE atomic
            // document version. Distinct entry ids never collapse.
            handoffs[handoff.entryID] = handoff
        }
        if let landingProof {
            landingProofs[landingProof.landingID] = landingProof
        }
        pendingWrite?.cancel()
        pendingWrite = nil
        let version = snapshotVersion
        submitSnapshot(requiringLanding: handoff != nil)
        let tracker = self.writer
        let placed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // The write queue is serial and the snapshot closure was enqueued
            // synchronously above: this closure runs directly after it, so
            // the bookkeeping it reads reflects exactly this snapshot's own
            // must-land attempt. There is deliberately NO timeout resume
            // here: resolving early while this write could still land would
            // hand the caller a failure verdict for bytes that may yet
            // publish imported refs — the intake would discard staged files
            // the disk then references. The await ends only on the writer's
            // actual completion.
            writeQueue.async {
                continuation.resume(
                    returning: tracker.persistedVersion >= version && tracker.lastFailure == nil
                )
            }
        }
        if placed { return true }
        // The bytes never reached disk. Undo this commit's own mutation so
        // the shared slot does not stay occupied while the VM field is empty
        // (that asymmetry is what made failed writes permanently retry-
        // blocking). Never roll back newer human content: restore only while
        // the slot still holds exactly what this commit wrote.
        let current = bucket(for: conversationID)[conversationID]
        if current?.revision == commitRevision, current?.text == text {
            setEntry(previous, for: conversationID)
            // The rollback is itself a text change: the generation advances
            // so a token captured against the failed placement can never be
            // mistaken for the restored draft.
            textGenerations[conversationID, default: 0] += 1
        }
        if let handoff, handoffs[handoff.entryID] == handoff {
            handoffs[handoff.entryID] = previousReceipt
        }
        if let landingProof, landingProofs[landingProof.landingID] == landingProof {
            landingProofs[landingProof.landingID] = previousProof
        }
        markDirty()
        return false
    }

    /// True only when the most recent write pipeline VERIFIED this exact
    /// receipt on disk: the same snapshot carried it, its bytes landed, and
    /// (for a fresh process) it came out of the readable draft document.
    /// In-memory staging and equality inference are NOT proof — a settle
    /// that acknowledges on anything less would credit an undelivered or
    /// unrelated entry. Callers must ALSO hold the ownership invariant that
    /// a receipt is only ever staged in the same main-actor turn in which
    /// the live composer synchronously accepted the text; disk proof then
    /// means a VISIBLE acceptance already happened.
    ///
    /// For an EXTERNAL import landing (one with an `ImportedDraftProof`)
    /// the check is deliberately content-aware: the most recent snapshot
    /// that actually reached disk must still carry the landed delta (the
    /// incoming text — a PRESENCE gate for an already-acked envelope, never
    /// a merge/idempotence guess — and every incoming item id). A later
    /// persisted human snapshot that dropped the imported bytes therefore
    /// can no longer acknowledge on the earlier placement's receipt; the
    /// intake re-lands instead, which is what closes the post-ack loss
    /// window. Ordinary handoff receipts (Shortcuts inbox placements without
    /// a landing proof) keep the pure ledger semantics.
    func handoffReceiptOnDisk(_ receipt: ShortcutHandoffReceipt) -> Bool {
        guard writer.persistedReceipts.contains(receipt) else { return false }
        guard let proof = landingProofs.values.first(where: { $0.receipt == receipt }) else {
            return true
        }
        let landed = writer.lastLandedDrafts[proof.conversationID]
        let trimmed = proof.incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, landed?.text.contains(proof.incomingText) != true {
            return false
        }
        let landedIDs = Set(landed?.attachments.map(\.id) ?? [])
        return proof.incomingAttachmentIDs.allSatisfy { landedIDs.contains($0) }
    }

    /// Receipts still awaiting their source ack, in memory. The ledger is
    /// the unsettled-evidence surface: a staged receipt means the composer
    /// already accepted that draft, and it survives ordinary edits, clears
    /// and sends until `settleHandoff` (after ack) retires it. There is
    /// deliberately NO withdrawal primitive: with render-before-persist, a
    /// failure to durable-verify rolls back inside `commitDurable` itself
    /// (never reaching disk), and a landed receipt always follows a real
    /// acceptance, so no "unrendered success" state exists to retract.
    var unsettledHandoffReceipts: [ShortcutHandoffReceipt] {
        handoffs.values.sorted { $0.entryID.uuidString < $1.entryID.uuidString }
    }

    /// Post-ack housekeeping: the source record is settled, so the receipt
    /// evidence retires. Ordinary debounced persistence follows; the ack
    /// itself is already durable in the source store either way. A receipt
    /// that lingers on disk after its row was acknowledged or tombstoned is
    /// INERT forever: `ack` requires the row to still be `claimed` with
    /// exactly this token, and an acknowledged row is gone (or a delivered
    /// tombstone that can never be re-claimed), so nothing can settle on the
    /// stale bytes a second time.
    func settleHandoff(entryID: UUID, claimToken: String) {
        guard let receipt = handoffs[entryID], receipt.claimToken == claimToken else { return }
        handoffs[entryID] = nil
        // Retire the import landing proof together with its receipt: once
        // the source is acknowledged, later human edits own the draft and
        // no recovery pass may still consult this landing's disk proof.
        if landingProofs.first(where: { $0.value.receipt == receipt }) != nil {
            landingProofs = landingProofs.filter { $0.value.receipt != receipt }
        }
        markDirty()
    }

    /// Bounded flush for lifecycle transitions: waits up to `timeout` for the
    /// newest snapshot to reach disk and returns whether it did. The main
    /// thread is only parked during a background/terminate transition.
    @discardableResult
    func flushAndWait(timeout: TimeInterval = 2) -> Bool {
        pendingWrite?.cancel()
        pendingWrite = nil
        let version = snapshotVersion
        submitSnapshot()
        // The signal is enqueued behind the submitted snapshot on the serial
        // queue, so a completed wait means exactly this attempt finished (and
        // a failed attempt already published its failure). The writer runs at
        // this parked thread's class (see init): if the deadline expires
        // before the attempt was scheduled, nothing has failed yet and
        // `syncWriteState` honestly stays `.pending`.
        let semaphore = DispatchSemaphore(value: 0)
        writeQueue.async { semaphore.signal() }
        let finished = semaphore.wait(timeout: .now() + timeout) == .success
        syncWriteState()
        return finished && writer.persistedVersion >= version && writer.lastFailure == nil
    }

    private func flushForLifecycle(timeout: TimeInterval) {
        if !flushAndWait(timeout: timeout) {
            FloeLogger(category: .app).error(
                "composerDraftFlushIncomplete timeout=\(timeout) failure=\(writer.lastFailure ?? "none")"
            )
        }
    }

    private func markDirty() {
        snapshotVersion += 1
        scheduleWrite()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    /// Submits the current snapshot for background serialization. A snapshot
    /// older than one already submitted is skipped; a pending debounce for
    /// the same version is not resubmitted. A `requiringLanding` snapshot (a
    /// handoff placement being durably verified) is NEVER skipped: its exact
    /// bytes must reach disk once, even when a newer human-edit snapshot is
    /// already queued behind it. That ordering guarantee is what makes a
    /// landed receipt mean "the accepted text was on disk" — a later snapshot
    /// may carry the receipt forward while a human edit extends or replaces
    /// the draft text after acceptance, but the accepted placement itself is
    /// proven by the snapshot that had to land.
    private func submitSnapshot(requiringLanding: Bool = false) {
        let version = snapshotVersion
        if version == submittedVersion,
           writer.persistedVersion >= version,
           writer.lastFailure == nil {
            return
        }
        submittedVersion = version
        let snapshot = entries
        let receiptSnapshot = handoffs
        let proofSnapshot = landingProofs
        let verifiedReceipts = Set(receiptSnapshot.values)
        let url = fileURL
        let writer = self.writer
        writer.begin(version: version, mustLand: requiringLanding)
        lastWriteState = .pending
        writeQueue.async { [weak self] in
            // A newer snapshot was requested while this one waited. Writing
            // this older state would only be overwritten — skip it, unless
            // this version is a handoff placement that must land.
            guard writer.latestRequested <= version || writer.requiresLanding(version) else {
                Task { @MainActor [weak self] in self?.syncWriteState() }
                return
            }
            var wrote = false
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try Self.encodeDocument(
                    drafts: snapshot,
                    handoffs: receiptSnapshot,
                    landingProofs: proofSnapshot
                )
                try data.write(to: url, options: .atomic)
                // The tracker remembers the FULLY landed document state:
                // drafts (for the content-aware disk proof of import
                // landings) and receipts. A failed write leaves it at the
                // last snapshot that really reached disk.
                writer.complete(
                    version: version,
                    receipts: verifiedReceipts,
                    drafts: snapshot
                )
                wrote = true
            } catch {
                writer.fail(version: version, message: error.localizedDescription)
            }
            let succeeded = wrote
            Task { @MainActor [weak self] in
                guard let self else { return }
                // One healthy snapshot clears a stale load failure.
                if succeeded, writer.persistedVersion >= version {
                    self.pendingLoadFailure = nil
                }
                self.syncWriteState()
                if let failure = writer.lastFailure {
                    FloeLogger(category: .app).error("composerDraftPersistFailed error=\(failure)")
                }
            }
        }
    }

    private func syncWriteState() {
        if let failure = writer.lastFailure ?? pendingLoadFailure {
            if lastWriteState != .failed(message: failure) {
                lastWriteState = .failed(message: failure)
            }
        } else if writer.persistedVersion >= submittedVersion {
            // Nothing to flush (or the newest snapshot is on disk): idle.
            if lastWriteState != .idle { lastWriteState = .idle }
        } else if lastWriteState != .pending {
            lastWriteState = .pending
        }
    }

    private nonisolated static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// The on-disk document. Version 2 wraps the draft map so a handoff
    /// receipt serializes atomically with the text it proves (and, for an
    /// external import landing, with the `ImportedDraftProof` delta that
    /// makes the disk receipt check content-aware). A version 1 document (a
    /// bare `[uuid: Entry]` JSON object — every file written before this
    /// protocol existed) still loads, so a failed or never-attempted v2
    /// write leaves the recoverable bytes readable: each entry survives a
    /// process restart and the missing receipt/proof ledgers simply prove
    /// nothing, which is exactly the honest default.
    private struct PersistedDocument: Codable {
        var drafts: [String: Entry]
        var handoffs: [String: ShortcutHandoffReceipt]
        /// Optional on decode: documents written before import proofs
        /// existed carry no field, which decodes as an empty ledger.
        var landingProofs: [String: ImportedDraftProof]?
    }

    private nonisolated static func decodeDocument(
        _ data: Data
    ) throws -> (
        drafts: [UUID: Entry],
        handoffs: [UUID: ShortcutHandoffReceipt],
        landingProofs: [String: ImportedDraftProof]
    ) {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(PersistedDocument.self, from: data) {
            return (
                try decodeDrafts(document.drafts),
                try decodeHandoffs(document.handoffs),
                try decodeLandingProofs(document.landingProofs ?? [:])
            )
        }
        // v1: the whole root object is the draft map; no ledgers existed.
        let raw = try decoder.decode([String: Entry].self, from: data)
        return (try decodeDrafts(raw), [:], [:])
    }

    private nonisolated static func decodeDrafts(
        _ raw: [String: Entry]
    ) throws -> [UUID: Entry] {
        var decoded: [UUID: Entry] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: FloeL10n.l("chat.composer_draft_store.the_draft_key_is_not_a", key)
                    )
                )
            }
            decoded[id] = value
        }
        return decoded
    }

    private nonisolated static func decodeHandoffs(
        _ raw: [String: ShortcutHandoffReceipt]
    ) throws -> [UUID: ShortcutHandoffReceipt] {
        var decoded: [UUID: ShortcutHandoffReceipt] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), value.entryID == id else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: FloeL10n.l("chat.composer_draft_store.the_draft_key_is_not_a", key)
                    )
                )
            }
            decoded[id] = value
        }
        return decoded
    }

    private nonisolated static func decodeLandingProofs(
        _ raw: [String: ImportedDraftProof]
    ) throws -> [String: ImportedDraftProof] {
        var decoded: [String: ImportedDraftProof] = [:]
        for (key, value) in raw where key == value.landingID {
            decoded[key] = value
        }
        guard decoded.count == raw.count else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: FloeL10n.l(
                        "chat.composer_draft_store.the_draft_key_is_not_a", "landing"
                    )
                )
            )
        }
        return decoded
    }

    private nonisolated static func encodeDocument(
        drafts: [UUID: Entry],
        handoffs: [UUID: ShortcutHandoffReceipt],
        landingProofs: [String: ImportedDraftProof] = [:]
    ) throws -> Data {
        var rawDrafts: [String: Entry] = [:]
        for (key, value) in drafts {
            rawDrafts[key.uuidString] = value
        }
        var rawHandoffs: [String: ShortcutHandoffReceipt] = [:]
        for (key, value) in handoffs {
            rawHandoffs[key.uuidString] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            PersistedDocument(
                drafts: rawDrafts,
                handoffs: rawHandoffs,
                landingProofs: landingProofs
            )
        )
    }

    /// Moves an unreadable draft document aside (copy as a fallback) so the
    /// corrupt input survives the next healthy write.
    private nonisolated static func preserveCorruptFile(at url: URL) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let preserved = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("json")
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: url, to: preserved)
            return preserved
        } catch {
            do {
                try fileManager.copyItem(at: url, to: preserved)
                return preserved
            } catch {
                FloeLogger(category: .app).error(
                    "composerDraftCorruptPreserveFailed error=\(error.localizedDescription)"
                )
                return nil
            }
        }
    }

    /// Lock-protected write bookkeeping shared between the main actor and the
    /// serial write queue. Also the single authority on what is PROVEN ON
    /// DISK: the receipt set AND the draft map of the most recent snapshot
    /// whose bytes actually landed (seeded from the loaded document at
    /// init), plus the must-land obligations that keep a handoff placement
    /// from being skipped as "superseded" before it ever reached disk. The
    /// landed draft map is what the content-aware import-receipt proof reads
    /// — in-memory staging never substitutes for it.
    private final class DraftWriteTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: UInt64 = 0
        private var persisted: UInt64 = 0
        private var failure: String?
        private var landingObligations: Set<UInt64> = []
        private var landedReceipts: Set<ComposerDraftStore.ShortcutHandoffReceipt> = []
        private var landedDrafts: [UUID: Entry] = [:]

        func begin(version: UInt64, mustLand: Bool = false) {
            lock.lock()
            requested = max(requested, version)
            if mustLand { landingObligations.insert(version) }
            lock.unlock()
        }

        var latestRequested: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        var persistedVersion: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return persisted
        }

        var lastFailure: String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func requiresLanding(_ version: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return landingObligations.contains(version)
        }

        var persistedReceipts: Set<ComposerDraftStore.ShortcutHandoffReceipt> {
            lock.lock()
            defer { lock.unlock() }
            return landedReceipts
        }

        /// The draft map of the most recent snapshot that ACTUALLY landed
        /// (or the document loaded at init — which IS disk state). The
        /// content-aware import proof reads exactly this map, so an in-
        /// memory newer-but-unlanded revision can never fake disk durability.
        var lastLandedDrafts: [UUID: Entry] {
            lock.lock()
            defer { lock.unlock() }
            return landedDrafts
        }

        /// A successfully loaded document IS disk state: seed the verified
        /// receipts AND the landed draft map from it (crash-after-write-
        /// before-ack recovery, and the import proof's disk baseline).
        func seedPersisted(
            receipts: Set<ComposerDraftStore.ShortcutHandoffReceipt>,
            drafts: [UUID: Entry]
        ) {
            lock.lock()
            landedReceipts = receipts
            landedDrafts = drafts
            lock.unlock()
        }

        func complete(
            version: UInt64,
            receipts: Set<ComposerDraftStore.ShortcutHandoffReceipt>,
            drafts: [UUID: Entry]
        ) {
            lock.lock()
            persisted = max(persisted, version)
            failure = nil
            landingObligations.remove(version)
            landedReceipts = receipts
            landedDrafts = drafts
            lock.unlock()
        }

        func fail(version: UInt64, message: String) {
            lock.lock()
            failure = message
            landingObligations.remove(version)
            // `landedReceipts` and `landedDrafts` deliberately stay at the
            // last snapshot that ACTUALLY landed: a failed write changes
            // nothing on disk, so receipts and drafts proven before the
            // failure remain proven and the receipt the failed commit had
            // staged proves nothing.
            lock.unlock()
        }
    }
}

/// Pure fold rules for a live editor absorbing one proven import landing.
/// Shared verbatim with the durable commit path (`ShareDraftMerger`), so the
/// visible field and the durable entry apply the identical non-destructive
/// merge. Returns nil when the landing is not newer than the content this
/// owner already adopted: applying it again could only duplicate the exact
/// imported delta, which is what the revision fence exists to refuse —
/// never a text-containment guess.
enum ImportedDraftLiveFold {
    struct Folded {
        let text: String
        let attachments: [AttachmentRef]
    }

    static func fold(
        _ landing: ComposerDraftStore.ImportedDraftLanding,
        intoText existingText: String,
        attachments existingAttachments: [AttachmentRef],
        adoptedRevision: Int?
    ) -> Folded? {
        guard (adoptedRevision ?? 0) < landing.landedRevision else { return nil }
        return Folded(
            text: ShareDraftMerger.mergedText(
                existing: existingText, incoming: landing.incomingText
            ),
            attachments: ShareDraftMerger.mergedAttachments(
                existing: existingAttachments, incoming: landing.addedAttachments
            )
        )
    }
}

#endif
