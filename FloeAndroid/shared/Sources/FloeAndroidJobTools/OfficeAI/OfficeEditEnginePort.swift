// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI — the port the `document.office.edit` tool and its durable
// job adapter execute against. FloeAndroidJobTools owns this protocol;
// FloeAndroidCore/OfficeAI supplies the ONE production implementation over the
// epoch-fenced App host mailbox. Tests inject a scripted port.
//
// Why a port and not a direct mailbox call: FloeAndroidCore DEPENDS ON
// FloeAndroidJobTools, so the tool can never import the mailbox. This is the
// same dependency inversion the delivered `JobShellSettlementGate` seam uses,
// and it needs no Package.swift change.
//
// Capture / model-think / apply invariant (Main clarification 2026-10-27):
//  * A `read` OPENS a trusted owned EDIT CONTEXT: the Core implementation runs
//    the real P-A CAPTURE_TARGET on the resolved document and binds the actual
//    engine-issued target handle + captured identity/epochs to an OPAQUE
//    contextID that is bound to the real run/conversation and the current
//    native capture. The raw handle NEVER leaves Core, never reaches the model
//    and is never forwarded from model-supplied text.
//  * A later `apply` must carry that contextID as a LOOKUP SELECTOR ONLY. The
//    implementation revalidates the SAME captured target; a missing, expired,
//    consumed, manual-retargeted or generation-drifted context is a typed
//    refusal BEFORE any dispatch. Silently capturing a fresh target only when
//    apply arrives is FORBIDDEN: the model could then act on bytes it never
//    saw, or retarget an arbitrary current selection after thinking about
//    another one.
//  * Legitimate explicit selection/navigation effects DO move the target, so
//    the workflow honestly recaptures and revalidates within the same
//    authorized operation and answers a NEW contextID.
//  * Content effects consume their context exactly once (the engine handle is
//    single-use for CONTENT), then flush + staged export + owned verification
//    decide the terminal truth. A native acknowledgement alone is never
//    success, and `unknown` retains the possible effect without replay.
//
// Honesty contract every implementation MUST keep:
//  * Context/document resolution answers ONLY from the real App-owned current
//    operation fenced by the exact submitting conversation, plus the ENGINE's
//    own mount generation read from the engine. Never a first-open-document
//    fallback, never another chat's document, never a model-supplied identity.
//  * `saveOriginal` writes ONLY through the acquired G04WorkspaceAccessLease
//    service and its `replaceBinaryFile` CAS authority (Normal18 contract),
//    never a gate-free committer or a raw overwrite, and the provider push
//    runs ONLY the existing journal ladder. The source export file remains
//    recoverable after any commit. Local workspace commit and provider push
//    outcomes are reported SEPARATELY — never an all-or-nothing success.

import Foundation
import FloeCore
import FloeModels
import FloeTools

// MARK: - Owned edit context

/// One trusted owned edit context opened by a read (or refreshed by an
/// explicit selection/navigation effect). `contextID` is an OPAQUE selector:
/// it carries no authority by itself, and the implementation re-derives the
/// real engine target + document facts from ITS OWN store.
public struct OfficeEditContext: Sendable, Equatable {
    /// Opaque selector (UUID string) bound to the real run/conversation and
    /// the exact native capture; a model-echoed value is only a lookup key.
    public var contextID: String
    /// The App-owned document this context was opened against.
    public var document: OfficeEditDocumentFacts
    /// True only when the engine really minted the captured target for this
    /// context (never implied by a lookup hit).
    public var captureAttested: Bool
    /// Producer context facts at capture (document context query answer), for
    /// the model's honest reasoning surface.
    public var capturedContext: OfficeEditQueryFacts
    /// Bounded opaque capture ordering token from the host clock (elapsed ms);
    /// identity/diagnostic only, never authority.
    public var capturedAtElapsedMillis: Int64

    public init(contextID: String, document: OfficeEditDocumentFacts, captureAttested: Bool,
                capturedContext: OfficeEditQueryFacts = OfficeEditQueryFacts(),
                capturedAtElapsedMillis: Int64 = 0) {
        self.contextID = contextID
        self.document = document
        self.captureAttested = captureAttested
        self.capturedContext = capturedContext
        self.capturedAtElapsedMillis = capturedAtElapsedMillis
    }
}

// MARK: - Typed commands (split by required outcome chain)

/// Preparatory effects: selection/navigation only. No document bytes change
/// per the pinned producer semantics, but the CURRENT target moves, so the
/// implementation must honestly recapture for the follow-up apply.
public enum OfficeEditPreparatoryCommand: Sendable, Equatable {
    /// Switch the shown slide/sheet; `partID` is 0-based.
    case selectSlide(partID: Int)
    case selectAllText
}

/// Content effects: real document mutations. Each REQUIRES the full
/// capture-revalidation → apply → flush → staged export → owned semantic
/// verification chain before any success claim.
public enum OfficeEditContentCommand: Sendable, Equatable {
    case applyText(String)
    case setCellContent(cell: String, text: String, kind: OfficeEditContentKind)
}

// MARK: - Stage results

/// Terminal outcome of one preparatory effect plus the honestly recaptured
/// context the follow-up apply MUST use.
public struct OfficeEditPreparatoryOutcome: Sendable, Equatable {
    public var result: OfficeEditCommandResult
    /// Fresh attested recapture after the effect. Nil ONLY when the effect was
    /// refused/failed/unknown before any dispatch decision could settle —
    /// then there is no valid successor context and any stale one is refused.
    public var refreshedContext: OfficeEditContext?

    public init(result: OfficeEditCommandResult, refreshedContext: OfficeEditContext?) {
        self.result = result
        self.refreshedContext = refreshedContext
    }
}

/// Terminal outcome of one full content workflow. Every stage keeps its own
/// honest receipt; the caller composes success ONLY from the proven fields.
public struct OfficeEditContentOutcome: Sendable, Equatable {
    /// The engine's typed apply result (capture revalidation + effect).
    public var result: OfficeEditCommandResult
    /// The working-copy flush terminal (the content reached the saved file).
    public var flush: OfficeEditFlushReceipt
    /// The verified staged export (the authoritative saved snapshot).
    public var snapshot: OfficeEditSavedSnapshot?
    /// Owned OOXML semantic facts of that snapshot (nil only when the chain
    /// stopped before a verified snapshot existed).
    public var semantic: OfficeEditSemanticFacts?
    /// True when the context was consumed exactly once by this dispatch, even
    /// if later stages failed (never re-offered for replay).
    public var contextConsumed: Bool
    /// The document facts the effect ran against (from the revalidated
    /// context), so the caller can request an original save without a second
    /// resolution race.
    public var document: OfficeEditDocumentFacts?

    public init(result: OfficeEditCommandResult, flush: OfficeEditFlushReceipt,
                snapshot: OfficeEditSavedSnapshot? = nil,
                semantic: OfficeEditSemanticFacts? = nil, contextConsumed: Bool = false,
                document: OfficeEditDocumentFacts? = nil) {
        self.result = result
        self.flush = flush
        self.snapshot = snapshot
        self.semantic = semantic
        self.contextConsumed = contextConsumed
        self.document = document
    }

    /// Proven terminal decision for the apply stage itself.
    public var effectProven: Bool { result.isEffectProven }
}

// MARK: - Port

/// The one execution surface the Office AI tool/adapter uses.
public protocol OfficeEditEnginePort: Sendable {
    /// Synchronous readiness for the registry's real executable-surface gate:
    /// true only while the App host lane is bound to the LIVE native root
    /// generation. A false answer makes the tool unregistered-equivalent for
    /// discovery, execution and `jobs.submit` admission alike.
    func isHostLaneLive() -> Bool

    /// Resolve-or-OPEN the App-owned document for this exact conversation and
    /// run the real CAPTURE_TARGET on it, opening one owned edit context.
    ///
    /// Chat→document entry (Main acceptance 2026-10-27): when NO owned viewer
    /// operation is currently open AND `workspaceRelativePath` supplies an
    /// explicit task-workspace document reference (already confined to the
    /// submitting call's own workspace root by the caller), the implementation
    /// opens it through the EXISTING owner-safe `OfficePreviewController
    /// .openWorkspace` staging + the existing FloeShell viewer launch effect,
    /// then awaits the REAL owned operation + engine edit readiness with a
    /// bounded window. It never invents a headless engine or a second
    /// controller, never launches another conversation's document, never
    /// silently picks the "first open document", and a readiness timeout is an
    /// honest typed failure with the actual retained viewer state — never a
    /// success or a forced close. When an owned operation IS already open, it
    /// is REUSED only if it is the requested (or, with no explicit path, any)
    /// document of THIS conversation; a different explicit path against a
    /// different open document is a typed refusal, not a switch.
    ///
    /// Throws `noOwnedDocument` when nothing is open and no path was supplied,
    /// and `notEditable` when the mount is not editable-ready. Every
    /// read/apply workflow starts here (directly or via `read`).
    func openEditContext(runID: UUID, conversationID: UUID, workspaceRelativePath: String?,
                         cancellation: CancellationToken) async throws -> OfficeEditContext

    /// One read-only producer query against a LIVE context (revalidating its
    /// document first). `contextID` is the OPAQUE selector only, and the
    /// context MUST belong to `conversationID` (defense-in-depth beyond the
    /// unguessable id itself). The
    /// implementation re-derives the real document + capture from its own
    /// store and refuses unknown/expired/foreign contexts BEFORE any host
    /// dispatch. The capture behind the context remains valid for follow-up
    /// apply unless a dispatch/flush/manual change moved it, in which case the
    /// engine's own CAS refuses apply and the caller must re-read.
    func read(_ command: OfficeEditReadCommand, contextID: String, conversationID: UUID,
              seed: String, cancellation: CancellationToken) async throws
        -> OfficeEditCommandResult

    /// One explicit selection/navigation effect against a LIVE context
    /// (selected by the opaque `contextID` only), then the HONEST recapture
    /// and revalidation for the follow-up apply.
    func executePreparatory(_ command: OfficeEditPreparatoryCommand, contextID: String,
                            conversationID: UUID, seed: String,
                            cancellation: CancellationToken) async throws
        -> OfficeEditPreparatoryOutcome

    /// The full content workflow against the SAME captured target the model
    /// reasoned from: capture revalidation (engine CAS; stale/manual-retarget
    /// refuses BEFORE dispatch) → apply → flush → staged export → the
    /// implementation's OWN byte/hash/magic/package verification plus the
    /// host's owned OOXML semantic inspection. The context is consumed exactly
    /// once by any actually-dispatched effect. Publication stays the caller's
    /// step (it needs the real submitting ToolContext).
    func executeContent(_ command: OfficeEditContentCommand, contextID: String,
                        conversationID: UUID, seed: String,
                        cancellation: CancellationToken) async throws
        -> OfficeEditContentOutcome

    /// Re-verifies an ALREADY produced trusted artifact (the durable result of
    /// an authorized job) with exactly the independent checks a fresh export
    /// receives — plain regular file, exact size, own streamed SHA-256, OOXML
    /// magic and the bounded package-structure scan — and adopts it as a
    /// publishable snapshot. Used by the `collect` action only: it never
    /// re-applies a native mutation and never trusts a model-quoted path.
    /// `expectedBytes` nil means the durable row carried no size: the measured
    /// size is then bound only by the recorded digest + magic + structure.
    func adoptVerifiedFile(path: String, expectedSha256: String, expectedBytes: Int64?,
                           format: OfficeEditDocumentFamily, displayName: String) throws
        -> OfficeEditSavedSnapshot

    /// Owned OOXML semantic inspection of any ADOPTED snapshot (the collect
    /// path re-derives expectations from the job's own frozen payload and runs
    /// this fresh; it never trusts a stored semantic claim).
    func inspectSavedPackage(_ snapshot: OfficeEditSavedSnapshot,
                             expectations: OfficeEditExpectations,
                             cancellation: CancellationToken) async throws
        -> OfficeEditSemanticFacts

    /// Publishes the verified snapshot as a run output bound to the REAL
    /// submitting call (`producerTool` = the producing tool's catalog name,
    /// `producerCallID` read from `context.toolCallID` by the store) and
    /// returns the receipt the runtime will strict-seal.
    func publishVerifiedOutput(_ snapshot: OfficeEditSavedSnapshot,
                               semantic: OfficeEditSemanticFacts,
                               slot: String,
                               context: ToolContext) throws -> RunOutputFile

    /// Synchronous, transport-free lookup used BEFORE a durable job record is
    /// created: answers the document facts of a LIVE, unexpired,
    /// unconsumed context owned by this conversation, or nil. It grants
    /// nothing (no host call, no lease extension, no fresh capture) and lets
    /// `BackgroundJobService.prepare` refuse with nothing persisted when the
    /// model's captured context is already gone — instead of creating a job
    /// that can only fail later.
    func contextDocument(contextID: String, conversationID: UUID) -> OfficeEditDocumentFacts?

    /// Amendment/2 additive seam: the CAPTURED producer facts behind a live
    /// context (the actual LOGICAL part index the target was captured on).
    /// Used only at job `prepare` time to persist bounded owned v2 target
    /// metadata into the durable outcome summary; grants nothing. A context
    /// without captured part facts (e.g. DOCX) answers nil for the index.
    func capturedContextFacts(contextID: String, conversationID: UUID) -> OfficeEditQueryFacts?

    /// Launch reconciliation for one INTERRUPTED authorized apply: re-derive
    /// the deterministic export opId from the durable row's own run/call/frozen
    /// payload, look for a real engine output artifact of that exact operation
    /// in the module-owned outputs root, and accept it ONLY after the same
    /// independent byte/hash/magic/package verification a fresh snapshot gets
    /// plus a fresh owned semantic inspection against the frozen expectations.
    /// Returns nil when no such proof exists — the caller must then keep the
    /// honest `interrupted` outcome; a stored summary string is never proof.
    func interruptedJobArtifact(operationID: String, exportOpId: String,
                                expectations: OfficeEditExpectations,
                                cancellation: CancellationToken) async throws
        -> OfficeEditSavedSnapshot?

    /// Saves the verified bytes back over the ORIGINAL workspace source. The
    /// implementation MUST use ONLY the acquired G04WorkspaceAccessLease's own
    /// `WorkspaceFileService.replaceBinaryFile` CAS (real service
    /// lock/path/freeze guards + injected mutation guard) for the local
    /// workspace commit, then — only when a durable provider binding exists —
    /// the existing journal ladder for the provider push (backup-verify →
    /// prepare → fresh-observe → one-time claim/permit → readback → settle, or
    /// retain/conflict). It never deletes the recoverable export, never
    /// retries a native edit for a journal failure, and reports local and
    /// provider outcomes SEPARATELY.
    func saveOriginal(_ snapshot: OfficeEditSavedSnapshot,
                      document: OfficeEditDocumentFacts,
                      cancellation: CancellationToken) async throws
        -> OfficeEditOriginalSaveOutcome
}

public extension OfficeEditEnginePort {
    /// Amendment/2 additive default: conformers that predate the captured-
    /// facts seam (or scripted ports that do not model it) honestly answer
    /// nil — the durable path then refuses historical part reuse rather than
    /// guessing a part.
    func capturedContextFacts(contextID: String, conversationID: UUID) -> OfficeEditQueryFacts? {
        nil
    }
}

/// The real terminal receipt of one working-copy flush. `state` mirrors the
/// engine's typed save states; only `flushed` proves new bytes on disk.
public struct OfficeEditFlushReceipt: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Native ack success AND the working copy was re-read/digested.
        case flushed
        /// Native answered "unmodified": nothing was written. After a real
        /// content apply this is a contradiction the caller must treat as a
        /// verification failure, never as success.
        case unmodified
        case failed
        case rejected
        case cancelled
        /// Dispatched, no ack inside the bounded window / before mount end.
        case unknown
    }

    public var state: State
    public var failureCode: String?
    public var workingCopySha256: String?
    public var workingCopyBytes: Int64
    public var attestation: String
    public var sessionToken: String
    public var nativeGeneration: Int64

    public init(state: State, failureCode: String? = nil, workingCopySha256: String? = nil,
                workingCopyBytes: Int64 = 0, attestation: String = "", sessionToken: String = "",
                nativeGeneration: Int64 = 0) {
        self.state = state
        self.failureCode = failureCode
        self.workingCopySha256 = workingCopySha256
        self.workingCopyBytes = workingCopyBytes
        self.attestation = attestation
        self.sessionToken = sessionToken
        self.nativeGeneration = nativeGeneration
    }
}

/// The stable per-call seed every Office AI stage's engine opId derives from.
/// Derived ONLY from the real runtime call identity and the approved payload
/// digest, so a retried submission, a lost acknowledgement or a replayed job
/// reuses ONE identity per stage and the engine's own duplicate-opId refusal
/// prevents a second effect. A fresh identity for the same effect is exactly
/// what must not happen.
public enum OfficeEditOperationIdentity {
    /// Bounded grammar the engine accepts (`^[A-Za-z0-9_-]{1,64}$`).
    public static func derive(runID: UUID, callID: String?, payloadDigest: String,
                              step: String) -> String {
        let material = "officeai|\(runID.uuidString)|\(callID ?? "-")|\(payloadDigest)|\(step)"
        let digest = FloeDigest.sha256Hex(Data(material.utf8))
        let tag = step.filter { $0.isLetter || $0.isNumber }.prefix(8)
        return "oa-\(tag)-\(digest.prefix(20))"
    }

    /// The per-stage opId the engine sees. Stable per (seed, stage); a retry
    /// with the same seed hits the engine's duplicate refusal instead of
    /// re-applying an effect under a fresh identity.
    public static func stageOpId(seed: String, stage: String) -> String {
        let digest = FloeDigest.sha256Hex(Data("\(seed)|\(stage)".utf8))
        let tag = stage.filter { $0.isLetter || $0.isNumber }.prefix(8)
        return "oa-\(tag)-\(digest.prefix(20))"
    }

    /// True when an identity still satisfies the engine's opId grammar.
    public static func isValid(_ identity: String) -> Bool {
        guard !identity.isEmpty, identity.count <= 64 else { return false }
        return identity.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
