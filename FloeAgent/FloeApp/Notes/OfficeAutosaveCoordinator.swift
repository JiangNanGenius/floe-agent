// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Combine
import UIKit
import FloeCore
import FloeNotes

/// The truthful result classes of one Office save transaction. Each is a
/// distinct outcome; the transaction never collapses a refusal, a cancellation
/// or a missing proof into a fabricated success.
enum OfficeSaveOutcome: String, Sendable {
    /// A verified engine flush committed the draft and the Notes owner
    /// promotion created a real new revision/resource with a read-back hash.
    case saved
    /// Nothing was pending: the verified draft bytes are provably identical to
    /// the current immutable Notes resource under the current revision.
    /// Reports the existing revision/resource and the real package hash, and
    /// never claims a new revision or that unsaved ink was just flushed.
    case alreadySaved
    /// The transaction did not start: no owner, a stale session fence, or the
    /// session cannot act on this document.
    case refused
    /// A real save attempt was intentionally postponed: an active pen contact
    /// or another session operation owns the editor right now. Dirty state is
    /// retained and a recheck is scheduled.
    case deferred
    /// The owner, the mounted generation or the session was torn down while
    /// the transaction ran. Nothing past the last completed fence is claimed.
    case cancelled
    /// A step ran but its required proof is missing or mismatched (draft
    /// digest, promoted resource digest, current Notes resource/revision).
    /// Never treated as success.
    case failedVerification
    /// The engine flush or the Notes promotion genuinely failed. The original
    /// resource and the retained draft/recovery evidence stay untouched.
    case failed
}

/// The stable commit/saved-proof published by every autosave transaction and
/// by the assistant/toolbar/manual routes that go through the coordinator.
/// All fields describe THIS transaction; `nativeFlushOccurred` says whether
/// this transaction dispatched the verified engine save (a flush performed by
/// an enclosing explicit close path is separately recorded on the stage
/// trace). `dirtyAfterTransaction` is the fail-safe current-dirty probe taken
/// after the last await: newer edits are retained for a subsequent drain.
struct OfficeSavedProof: Sendable {
    let outcome: OfficeSaveOutcome
    /// Stable machine-readable reason code (for example `autosave.penActive`).
    let reason: String?
    let documentID: UUID?
    let sessionGeneration: Int?
    let sessionCorrelationID: String?
    /// Notes revision/resource the proof vouches for AFTER this transaction.
    let revision: Int?
    let resourceID: UUID?
    /// Real package SHA-256 of the verified draft/promoted resource. nil only
    /// when the outcome is not a success — a success without a hash is
    /// `failedVerification`, never `saved`.
    let packageSHA256: String?
    let nativeFlushOccurred: Bool
    let changesPromoted: Bool
    let dirtyAfterTransaction: Bool?
    let retryScheduled: Bool
    let error: String?

    var isCommittedState: Bool { outcome == .saved || outcome == .alreadySaved }

    static func terminal(outcome: OfficeSaveOutcome, reason: String?,
                         binding: OfficeAutosaveCoordinator.Binding?,
                         documentID: UUID? = nil) -> OfficeSavedProof {
        OfficeSavedProof(outcome: outcome, reason: reason,
                         documentID: documentID ?? binding?.documentIDHint,
                         sessionGeneration: binding?.generation,
                         sessionCorrelationID: binding?.sessionCorrelationID,
                         revision: nil, resourceID: nil, packageSHA256: nil,
                         nativeFlushOccurred: false, changesPromoted: false,
                         dirtyAfterTransaction: nil, retryScheduled: false,
                         error: nil)
    }
}

/// Result of the Notes owner's promotion step. The promotion only reports
/// success with a real revision/resource and a read-back package digest;
/// `alreadySaved` is the strict clean no-op proof, never a new revision.
enum OfficeNotesPromotionOutcome: Sendable {
    case promoted(revision: Int, resourceID: UUID, packageSHA256: String)
    case alreadySaved(revision: Int, resourceID: UUID, packageSHA256: String)
    case conflict(message: String?)
    case verificationFailed(reason: String, message: String?)
    case failed(reason: String, message: String?)
}

/// The document-bound owner transaction installed by the mounted Notes
/// surface. Every closure re-validates the view/session identity itself; the
/// coordinator owns scheduling and serialization, the owner owns what "dirty",
/// "flush" and "promote" actually mean for this document and session.
struct OfficeAutosaveOwner {
    let documentID: UUID
    /// Synchronous view/session fence: this exact document is still mounted,
    /// selected and has a staged draft plus a usable store.
    let isCurrent: @MainActor () -> Bool
    /// True when a validated draft already awaits promotion (an earlier save
    /// or a failed promotion). Retained across failures until proven promoted.
    let hasPendingPromotion: @MainActor () -> Bool
    /// Called only AFTER a verified engine flush in this transaction, before
    /// promotion; the owner must keep the marker until promotion proves out.
    let markPendingPromotion: @MainActor () -> Void
    /// The actual accepted/completed engine stroke/content-change truth:
    /// working-copy difference plus the engine's own ModifiedStatus latch.
    /// Must fail safe (unknown = dirty).
    let isContentDirty: @MainActor () async -> Bool
    /// Pen-contact probe; unknown must fail closed (true = do not save).
    let hasActivePen: @MainActor () async -> Bool
    /// The editor's own production flush: engine save -> verified working-copy
    /// commit to the draft. Returns false ONLY for a real failure/refusal.
    let flushEngine: @MainActor () async -> Bool
    /// Promotion of the verified draft into a new Notes revision with a real
    /// resource/revision/package-hash read-back (or the strict alreadySaved
    /// no-op proof). Never fabricates success.
    let promote: @MainActor () async -> OfficeNotesPromotionOutcome
    /// Optional surface for scheduled (user-invisible) outcomes so the owner
    /// can reuse its existing error affordances. Explicit callers receive
    /// their proof directly and do not need this.
    let publishScheduledOutcome: (@MainActor (OfficeSavedProof) -> Void)?
}

/// The session-side probes the coordinator needs. `sessionState` distinguishes
/// "busy right now" (defer) from "cannot act on this generation" (refuse).
enum OfficeAutosaveSessionState: Sendable { case ready, busy, notReady, closed }

struct OfficeAutosaveSignals {
    let sessionState: @MainActor () -> OfficeAutosaveSessionState
    /// Exact mounted-generation fence: same open generation, same controller
    /// instance, same working copy, and neither released nor teardown-requested.
    let fenceCurrent: @MainActor () -> Bool
    /// The session's durable stage trace (content-free by construction).
    let recordStage: @MainActor (String, [String: String]) -> Void
    /// The engine session's last visible save error, for truthful proofs.
    let lastFlushError: @MainActor () -> String?
}

/// One exact document/controller/session/generation-bound autosave owner
/// coordinator. The mounted Office session creates it for every editable
/// activation and invalidates it on teardown, so it outlives transient SwiftUI
/// task churn and dies with its generation. Raw engine persistence hints
/// (`onWorkingCopySaved`) and the engine's own modified edges only schedule a
/// debounced RECHECK; a pen-up is not itself dirty or save proof, and unknown
/// pen/dirty/session state always fails safe. Multiple strokes/keyboard edits
/// inside the idle window coalesce into exactly one serialized transaction:
/// verified engine flush -> draft commit -> async Notes owner CAS promotion.
/// Dirty generated during a save or before promotion is retained for a
/// subsequent drain; an old receipt never clears newer edits.
@MainActor
final class OfficeAutosaveCoordinator {
    struct Binding: Sendable {
        let generation: Int
        let controllerID: ObjectIdentifier
        let workingCopyPath: String
        let sessionCorrelationID: String
        /// Document identity once an owner is installed (nil until then).
        var documentIDHint: UUID? = nil
    }

    /// Idle window between the last dirty-edge signal and the recheck. Long
    /// enough to coalesce a writing burst, short enough to feel automatic.
    static let defaultIdleDebounceNanoseconds: UInt64 = 2_000_000_000
    /// Consecutive failed scheduled transactions after which the coordinator
    /// stops auto-retrying and waits for a fresh edge signal, an explicit
    /// request, or a lifecycle drain instead. The draft stays retained; the
    /// existing actionable failure/retry affordance owns the user-facing step.
    static let maximumAutoRetriesPerDirtySet = 2

    private(set) var binding: Binding
    private let signals: OfficeAutosaveSignals
    private let idleDebounceNanoseconds: UInt64

    private var owner: OfficeAutosaveOwner?
    private var debounceTask: Task<Void, Never>?
    private var pass: Task<OfficeSavedProof, Never>?
    private var followUpRequested = false
    private var autoRetriesUsed = 0
    private var invalidated = false
    private var lifecycleObservations: [AnyCancellable] = []

    init(binding: Binding, signals: OfficeAutosaveSignals,
         idleDebounceNanoseconds: UInt64 = OfficeAutosaveCoordinator.defaultIdleDebounceNanoseconds) {
        self.binding = binding
        self.signals = signals
        self.idleDebounceNanoseconds = idleDebounceNanoseconds
        // Foreground inactive / background / exit each request a bounded
        // drain through this same serialized coordinator. No platform
        // background-time or exact-scheduling promise is made: the attempt is
        // a single bounded pass that defers an active pen and never tears the
        // engine down underneath an in-progress transaction.
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            lifecycleObservations.append(
                NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.drainForLifecycle()
                        }
                    })
        }
    }

    var hasOwner: Bool { owner != nil && !invalidated }

    func installOwner(_ newOwner: OfficeAutosaveOwner?) {
        guard !invalidated else { return }
        owner = newOwner
        if let newOwner {
            var updated = binding
            updated.documentIDHint = newOwner.documentID
            binding = updated
            // A draft that already owed promotion at install time (for example
            // a failed promotion before the owner re-registered) gets drained
            // through the normal debounced pass; nothing is saved mid-stroke.
            recheck(reason: "ownerInstalled")
        }
    }

    /// A raw signal that *something may be pending*: schedules/re-arms the
    /// debounced recheck. It is never treated as dirty proof or save proof.
    /// Coalescing: each edge cancels the previous timer, so a burst inside
    /// the idle window drains once after the window elapses.
    func recheck(reason: String, debounceNanoseconds: UInt64? = nil) {
        guard !invalidated, owner != nil else { return }
        debounceTask?.cancel()
        let delay = debounceNanoseconds ?? idleDebounceNanoseconds
        guard delay > 0 else {
            startScheduledPass(reason: reason)
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.onDebounceElapsed(reason: reason)
        }
    }

    /// Bounded drain requested by lifecycle exits (also the test/owner entry).
    func drainForLifecycle() {
        guard !invalidated, owner != nil else { return }
        recheck(reason: "lifecycleDrain", debounceNanoseconds: 1)
    }

    /// The single serialized transaction entry for explicit triggers (engine
    /// Save button/Command-S, assistant commitLiveEdits, manual retry, back).
    /// A caller that arrives while a transaction runs joins its settlement and
    /// then claims a fresh pass, so every explicit trigger receives a proof of
    /// the CURRENT state without ever overlapping another native save.
    func requestTransaction(reason: String) async -> OfficeSavedProof {
        guard !invalidated else {
            return .terminal(outcome: .cancelled, reason: "autosave.invalidated", binding: binding)
        }
        guard owner != nil else {
            return .terminal(outcome: .refused, reason: "autosave.ownerMissing", binding: binding)
        }
        debounceTask?.cancel()
        while let running = pass {
            _ = await running.value
            guard !invalidated, owner != nil else {
                return .terminal(outcome: .cancelled, reason: "autosave.invalidated", binding: binding)
            }
        }
        // No suspension between the loop exit and the claim, so exactly one
        // caller wins each pass slot on the MainActor.
        let task = Task { [weak self] in
            guard let self else {
                return OfficeSavedProof.terminal(outcome: .cancelled, reason: "autosave.invalidated", binding: nil)
            }
            return await self.executePass(reason: reason, explicit: true)
        }
        pass = task
        return await task.value
    }

    private func onDebounceElapsed(reason: String) {
        guard !invalidated, owner != nil else { return }
        guard pass == nil else {
            followUpRequested = true
            return
        }
        startScheduledPass(reason: reason)
    }

    private func startScheduledPass(reason: String) {
        guard !invalidated, owner != nil, pass == nil else {
            followUpRequested = true
            return
        }
        let task = Task { [weak self] in
            guard let self else {
                return OfficeSavedProof.terminal(outcome: .cancelled, reason: "autosave.invalidated", binding: nil)
            }
            return await self.executePass(reason: reason, explicit: false)
        }
        pass = task
    }

    // MARK: - The transaction

    private func executePass(reason: String, explicit: Bool) async -> OfficeSavedProof {
        defer {
            pass = nil
            if followUpRequested && !invalidated {
                followUpRequested = false
                // Demand that arrived while this pass ran: drain again after
                // the idle window so a writing burst still coalesces.
                recheck(reason: "\(reason).followUp")
            }
        }
        guard !invalidated, let owner else {
            return .terminal(outcome: .cancelled, reason: "autosave.invalidated", binding: binding,
                             documentID: binding.documentIDHint)
        }
        guard signals.fenceCurrent() else {
            signals.recordStage("autosave.refused", ["reason": "staleSessionFence", "trigger": reason])
            return .terminal(outcome: .refused, reason: "autosave.staleSessionFence",
                             binding: binding, documentID: owner.documentID)
        }
        guard owner.isCurrent() else {
            signals.recordStage("autosave.refused", ["reason": "staleDocument", "trigger": reason])
            return .terminal(outcome: .refused, reason: "autosave.staleDocument",
                             binding: binding, documentID: owner.documentID)
        }
        switch signals.sessionState() {
        case .busy:
            signals.recordStage("autosave.deferred", ["reason": "sessionBusy", "trigger": reason])
            recheck(reason: "sessionBusy")
            return proof(outcome: .deferred, reason: "autosave.sessionBusy", owner: owner,
                         flush: false, promoted: false, dirty: nil, retry: true, error: nil)
        case .notReady:
            signals.recordStage("autosave.refused", ["reason": "sessionNotReady", "trigger": reason])
            return .terminal(outcome: .refused, reason: "autosave.sessionNotReady",
                             binding: binding, documentID: owner.documentID)
        case .closed:
            signals.recordStage("autosave.refused", ["reason": "sessionClosed", "trigger": reason])
            return .terminal(outcome: .refused, reason: "autosave.sessionClosed",
                             binding: binding, documentID: owner.documentID)
        case .ready:
            break
        }

        // An active OR UNKNOWN pen contact defers EVERY route, including the
        // nominal clean/no-op claim: a just-started stroke can still read
        // clean, so an alreadySaved/current-saved proof must never be issued
        // while ink could be in flight. (Review item 2.)
        if await owner.hasActivePen() {
            signals.recordStage("autosave.deferred", ["reason": "penActive", "trigger": reason])
            recheck(reason: "penActive")
            return proof(outcome: .deferred, reason: "autosave.penActive", owner: owner,
                         flush: false, promoted: false, dirty: nil, retry: true, error: nil)
        }
        guard !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() else {
            return .terminal(outcome: .cancelled, reason: "autosave.staleAfterPenProbe",
                             binding: binding, documentID: owner.documentID)
        }

        // Truthful dirty detection: the engine's accepted completed
        // stroke/content change evidence, never the raw persistence hint
        // alone. Unknown already fails safe to dirty in the owner probe. The
        // owner's probe folds in its own pending-promotion marker, so a
        // retained verified draft is always treated as demanded work.
        let contentDirty = await owner.isContentDirty()
        guard !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() else {
            return .terminal(outcome: .cancelled, reason: "autosave.staleAfterProbe",
                             binding: binding, documentID: owner.documentID)
        }

        var didFlush = false
        if contentDirty {
            // Re-probe right before dispatching the native save: a contact
            // may have landed while the dirty state was being read.
            if await owner.hasActivePen() {
                signals.recordStage("autosave.deferred", ["reason": "penActive", "trigger": reason])
                // Never save underneath a stroke; the retained dirty state is
                // drained through the idle window after the pen settles.
                recheck(reason: "penActive")
                return proof(outcome: .deferred, reason: "autosave.penActive", owner: owner,
                             flush: false, promoted: false, dirty: true, retry: true, error: nil)
            }
            guard signals.sessionState() == .ready, signals.fenceCurrent(), owner.isCurrent() else {
                signals.recordStage("autosave.deferred", ["reason": "busyBeforeFlush", "trigger": reason])
                recheck(reason: "busyBeforeFlush")
                return proof(outcome: .deferred, reason: "autosave.sessionBusyBeforeFlush", owner: owner,
                             flush: false, promoted: false, dirty: true, retry: true, error: nil)
            }
            signals.recordStage("autosave.flush", ["trigger": reason])
            let flushed = await owner.flushEngine()
            guard !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() else {
                return .terminal(outcome: .cancelled, reason: "autosave.staleAfterFlush",
                                 binding: binding, documentID: owner.documentID)
            }
            if !flushed {
                let errorText = signals.lastFlushError()
                signals.recordStage("autosave.failed", ["reason": "flushFailed", "trigger": reason])
                autoRetriesUsed += 1
                let canRetry = autoRetriesUsed < Self.maximumAutoRetriesPerDirtySet
                if canRetry {
                    recheck(reason: "flushFailed.retry")
                } else {
                    // Same failed dirty set at the auto-retry cap: the draft
                    // and pending state stay retained and the actionable
                    // failure surfaces through the owner's existing affordance;
                    // only fresh demand (a new content edge, an explicit save,
                    // a lifecycle drain) schedules another attempt.
                    signals.recordStage("autosave.retryHeld", ["reason": "flushFailed", "trigger": reason])
                }
                let failedProof = proof(outcome: .failed, reason: "autosave.flushFailed", owner: owner,
                                        flush: false, promoted: false, dirty: true,
                                        retry: canRetry, error: errorText)
                owner.publishScheduledOutcome?(failedProof)
                return failedProof
            }
            didFlush = true
            // The draft is verified from this point; it owes promotion until
            // proven otherwise. A later failure keeps this marker.
            owner.markPendingPromotion()
        }

        guard !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() else {
            return .terminal(outcome: .cancelled, reason: "autosave.staleBeforePromotion",
                             binding: binding, documentID: owner.documentID)
        }
        signals.recordStage("autosave.promote", ["trigger": reason, "flushed": didFlush ? "true" : "false"])
        let promotion = await owner.promote()
        // The promote step fences the store CAS itself and reads the promoted
        // digest back; its receipt is real evidence even if the mounted
        // surface disappears during the closing probes below. A failure
        // result stays a failure; a verified success is never downgraded into
        // a fabricated "nothing happened".

        // Re-probe AFTER the promotion, and re-fence AFTER those awaits
        // (review item 3): dirty generated during the save or before
        // promotion must be retained for a subsequent drain — an old receipt
        // never clears newer edits. `dirtyAfterTransaction` is nil when the
        // closing state could not be freshly proven.
        var dirtyAfter: Bool? = nil
        if !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() {
            let contentDirtyNow = await owner.isContentDirty()
            let penNow = await owner.hasActivePen()
            if !Task.isCancelled, !invalidated, signals.fenceCurrent(), owner.isCurrent() {
                dirtyAfter = contentDirtyNow || penNow
            }
        }

        let promotionSucceeded: Bool
        switch promotion {
        case .promoted, .alreadySaved: promotionSucceeded = true
        case .conflict, .verificationFailed, .failed: promotionSucceeded = false
        }
        var retryScheduled = false
        if promotionSucceeded {
            autoRetriesUsed = 0
            if dirtyAfter == true {
                // Newer content after a real success is fresh demand: drain
                // it through the idle window.
                recheck(reason: "dirtyAfterTransaction")
            }
        } else {
            autoRetriesUsed += 1
            // Retained demand: freshly proven dirty content OR the still
            // pending promotion marker. A verified draft whose promotion
            // failed reads engine-clean after the flush; it must still be
            // retried (within the auto-retry cap) instead of silently
            // stranding the save the user already made.
            let retainedDemand = dirtyAfter == true || owner.hasPendingPromotion()
            if retainedDemand {
                if autoRetriesUsed < Self.maximumAutoRetriesPerDirtySet {
                    retryScheduled = true
                    recheck(reason: "dirtyAfterTransaction.retry")
                } else {
                    signals.recordStage("autosave.retryHeld", ["reason": "promotionFailed", "trigger": reason])
                }
            }
        }

        switch promotion {
        case .promoted(let revision, let resourceID, let packageSHA256):
            signals.recordStage("autosave.saved", ["trigger": reason, "revision": String(revision),
                                                   "flushed": didFlush ? "true" : "false"])
            return proof(outcome: .saved, reason: nil, owner: owner, flush: didFlush,
                         promoted: true, revision: revision, resourceID: resourceID,
                         sha: packageSHA256, dirty: dirtyAfter, retry: retryScheduled, error: nil)
        case .alreadySaved(let revision, let resourceID, let packageSHA256):
            signals.recordStage("autosave.alreadySaved", ["trigger": reason, "revision": String(revision)])
            return proof(outcome: .alreadySaved, reason: nil, owner: owner, flush: false,
                         promoted: false, revision: revision, resourceID: resourceID,
                         sha: packageSHA256, dirty: dirtyAfter, retry: retryScheduled, error: nil)
        case .conflict(let message):
            signals.recordStage("autosave.failed", ["reason": "notesResourceConflict", "trigger": reason])
            let failedProof = proof(outcome: .failed, reason: "autosave.notesResourceConflict", owner: owner,
                                    flush: didFlush, promoted: false, dirty: dirtyAfter,
                                    retry: retryScheduled, error: message)
            owner.publishScheduledOutcome?(failedProof)
            return failedProof
        case .verificationFailed(let code, let message):
            signals.recordStage("autosave.failedVerification", ["reason": code, "trigger": reason])
            let failedProof = proof(outcome: .failedVerification, reason: code, owner: owner,
                                    flush: didFlush, promoted: false, dirty: dirtyAfter,
                                    retry: retryScheduled, error: message)
            owner.publishScheduledOutcome?(failedProof)
            return failedProof
        case .failed(let code, let message):
            signals.recordStage("autosave.failed", ["reason": code, "trigger": reason])
            let failedProof = proof(outcome: .failed, reason: code, owner: owner,
                                    flush: didFlush, promoted: false, dirty: dirtyAfter,
                                    retry: retryScheduled, error: message)
            owner.publishScheduledOutcome?(failedProof)
            return failedProof
        }
    }

    private func proof(outcome: OfficeSaveOutcome, reason: String?, owner: OfficeAutosaveOwner,
                       flush: Bool, promoted: Bool,
                       revision: Int? = nil, resourceID: UUID? = nil, sha: String? = nil,
                       dirty: Bool?, retry: Bool, error: String?) -> OfficeSavedProof {
        OfficeSavedProof(outcome: outcome, reason: reason, documentID: owner.documentID,
                         sessionGeneration: binding.generation,
                         sessionCorrelationID: binding.sessionCorrelationID,
                         revision: revision, resourceID: resourceID, packageSHA256: sha,
                         nativeFlushOccurred: flush, changesPromoted: promoted,
                         dirtyAfterTransaction: dirty, retryScheduled: retry, error: error)
    }

    // MARK: - Teardown

    /// Generation teardown: the mounted controller closed, the session was
    /// released, or the owner unregistered. Cancels the pending debounce and
    /// the in-flight pass; an explicit caller awaiting the pass receives a
    /// truthful `cancelled` proof, and no callback can touch a reopened or
    /// different document afterwards.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        lifecycleObservations.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        owner = nil
        if let running = pass {
            running.cancel()
        }
    }
}

/// The store-level Notes promotion transaction the live editor runs after a
/// verified Office save. Both `NotesOfficeView`'s production commit and the
/// focused module tests go through this single implementation: import the
/// exact verified draft as a new immutable resource, PROVE the imported
/// digest/size against the captured draft BEFORE any CAS, refuse unless the
/// document still carries the captured base resource, swap the Office
/// resource at the freshly read revision, and re-read the binding as the
/// final truth. Every required hash/URL/revision is obtained WITHOUT `try?`:
/// a missing digest, missing resource or missing current Notes
/// resource/revision proof is an explicit thrown failure, never a silent nil
/// success. A failed import verification discards its orphan resource and
/// cannot publish unverified bytes into the document.
@MainActor
enum OfficeNotesDraftPromotion {
    struct Receipt: Sendable {
        let revision: Int
        let resourceID: UUID
        let savedResourceURL: URL
        let draftSHA256: String
        let resourceSHA256: String
        let matchingPreviewResourceID: UUID?
    }

    enum Failure: LocalizedError {
        case noStore
        case documentMissing
        case resourceConflict
        case proofUnavailable(String)
        case draftDiverged
        /// The CAS genuinely created this revision (the imported bytes were
        /// verified BEFORE it) but the final re-read failed. The caller must
        /// advance its baseline to the real values and report the outcome as
        /// UNPROVEN — never a bare success, never a fabricated "nothing
        /// happened".
        case postCommitProofUnavailable(revision: Int, resourceID: UUID, detail: String)

        var errorDescription: String? {
            switch self {
            case .noStore:
                "The note store is unavailable; nothing was promoted."
            case .documentMissing:
                "The note document no longer exists; nothing was promoted."
            case .resourceConflict:
                "The Notes document no longer carries the expected Office resource; the promotion was refused to protect the newer revision."
            case .proofUnavailable(let detail):
                "The saved proof is incomplete: \(detail)"
            case .draftDiverged:
                "The verified draft differs from the current Notes resource; a real promotion is required."
            case .postCommitProofUnavailable(_, _, let detail):
                "A new Notes revision was created from the pre-verified package but its final proof could not be re-read: \(detail) Re-read the document before writing again."
            }
        }
    }

    /// Test seam for deterministic digest-injection failures; production uses
    /// the real file digests. `SHA-256(ofFileAt:)` is content-addressed, so
    /// production behaviour is exactly this function.
    typealias PackageDigest = @Sendable (URL) throws -> String

    static func promote(documentID: UUID, draftURL: URL, expectedResourceID: UUID,
                        session: NotesSession,
                        packageDigest: PackageDigest = { try FloeDigest.sha256Hex(ofFileAt: $0) }) async throws -> Receipt {
        guard let store = session.store else { throw Failure.noStore }
        let draftSHA = try packageDigest(draftURL)
        let draftSize = try Self.fileSize(draftURL)
        // Re-import never overwrites the former immutable resource.
        let resource = try await store.importResource(from: draftURL, mediaType: "application/octet-stream")
        // BEFORE any CAS publishes anything: the imported immutable resource
        // must be the exact verified bytes. A corrupt import or a draft that
        // changed under the transaction can never replace the Notes resource;
        // the orphan import is discarded and the failure is explicit.
        let saved: URL
        let importedSHA: String
        let importedSize: Int
        do {
            saved = try await store.resourceURL(resource)
            importedSHA = try packageDigest(saved)
            importedSize = try Self.fileSize(saved)
        } catch {
            await Self.discardOrphan(resource, store: store)
            throw Failure.proofUnavailable("imported resource digest unreadable: \(error.localizedDescription)")
        }
        guard importedSHA == draftSHA, importedSize == draftSize else {
            await Self.discardOrphan(resource, store: store)
            throw Failure.proofUnavailable("imported resource digest/size does not match the verified draft")
        }
        // Re-fence the current Notes state immediately before the CAS.
        let current: NoteDocument
        do {
            current = try await store.document(documentID)
        } catch {
            await Self.discardOrphan(resource, store: store)
            if case NoteError.notFound = error { throw Failure.documentMissing }
            throw Failure.proofUnavailable("current document state unreadable: \(error.localizedDescription)")
        }
        guard current.deletedAt == nil else {
            await Self.discardOrphan(resource, store: store)
            throw Failure.documentMissing
        }
        guard current.officeResourceID == expectedResourceID else {
            await Self.discardOrphan(resource, store: store)
            throw Failure.resourceConflict
        }
        let updated: NoteDocument
        do {
            updated = try await session.commit([.replaceOfficeResource(resource)],
                                               documentID: documentID,
                                               expectedRevision: current.revision)
        } catch {
            // The CAS did not land: the verified-but-unbound import is an
            // orphan and is discarded; the document keeps its old resource.
            await Self.discardOrphan(resource, store: store)
            throw error
        }
        guard updated.officeResourceID == resource else {
            // The commit landed on a different binding than the verified
            // import: treat as unproven with the REAL landed values, so the
            // caller can never claim this transaction promoted the draft.
            throw Failure.proofUnavailable("the committed binding does not reference the pre-verified resource")
        }
        // Post-commit truth re-read. The pre-CAS check already proved the
        // bytes; only the re-read itself failing means "created but
        // unproven" — reported with the real revision/resource.
        do {
            let rebound = try await store.resourceURL(resource)
            let finalSHA = try packageDigest(rebound)
            guard finalSHA == draftSHA else {
                throw Failure.postCommitProofUnavailable(revision: updated.revision, resourceID: resource,
                                                         detail: "the re-read resource digest does not match the verified draft")
            }
            return Receipt(revision: updated.revision, resourceID: resource, savedResourceURL: rebound,
                           draftSHA256: draftSHA, resourceSHA256: finalSHA,
                           matchingPreviewResourceID: updated.matchingOfficePreviewResourceID)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.postCommitProofUnavailable(revision: updated.revision, resourceID: resource,
                                                     detail: error.localizedDescription)
        }
    }

    /// The strict clean no-op proof: the current draft must still hash to the
    /// immutable resource named by the captured base under the captured
    /// revision. Any divergence throws `draftDiverged` (the caller owes a real
    /// promotion), any missing digest/URL/revision is an explicit failure.
    static func verifySavedNoop(documentID: UUID, draftURL: URL, resourceID: UUID,
                                expectedRevision: Int, session: NotesSession,
                                packageDigest: PackageDigest = { try FloeDigest.sha256Hex(ofFileAt: $0) }) async throws -> Receipt {
        guard let store = session.store else { throw Failure.noStore }
        let draftSHA = try packageDigest(draftURL)
        let draftSize = try Self.fileSize(draftURL)
        let current: NoteDocument
        do {
            current = try await store.document(documentID)
        } catch {
            if case NoteError.notFound = error { throw Failure.documentMissing }
            throw Failure.proofUnavailable("current document state unreadable: \(error.localizedDescription)")
        }
        guard current.deletedAt == nil else { throw Failure.documentMissing }
        guard current.officeResourceID == resourceID, current.revision == expectedRevision else {
            throw Failure.resourceConflict
        }
        let saved = try await store.resourceURL(resourceID)
        let resourceSHA = try packageDigest(saved)
        let resourceSize = try Self.fileSize(saved)
        guard resourceSHA == draftSHA, resourceSize == draftSize else { throw Failure.draftDiverged }
        return Receipt(revision: current.revision, resourceID: resourceID, savedResourceURL: saved,
                       draftSHA256: draftSHA, resourceSHA256: resourceSHA,
                       matchingPreviewResourceID: current.matchingOfficePreviewResourceID)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw Failure.proofUnavailable("file size unavailable for \(url.lastPathComponent)")
        }
        return size
    }

    /// Cleanup of an orphan import, never of a required proof. The store's
    /// deleted-resource reclamation is the safety net when this fails.
    private static func discardOrphan(_ resource: UUID, store: NotesStore) async {
        try? await store.discardUnreferencedResource(resource)
    }
}
#endif
