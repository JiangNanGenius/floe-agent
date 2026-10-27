// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the typed, model-facing vocabulary
// of `document.office.edit` on Android.
//
// This file is deliberately FREE of any host/transport/native detail: it is the
// contract shared by the tool, the durable job adapter and the Core-side host
// bridge. FloeAndroidCore depends on FloeAndroidJobTools (never the reverse),
// so the port lives here and the concrete implementation lives in
// FloeAndroidCore/OfficeAI — the same inversion the delivered
// `JobShellSettlementGate` seam uses.
//
// Authority rules baked into these types (Main contract 2026-10-26/27):
//  * A model NEVER supplies a document path, a session token, a native mount
//    generation, an engine target handle, a raw UNO/wire/key/body string, a
//    paragraph offset or an arbitrary PPT object identity. The edited document
//    is ALWAYS the App-owned currently open operation resolved through the
//    real `OfficePreviewController.ownedOperationSnapshot` fence for the
//    submitting conversation.
//  * Content effects are never "done" at native acknowledgement. A content
//    apply REQUIRES a real native flush/export plus owned OOXML semantic
//    verification plus run-output publication before the tool may succeed.
//  * Opaque workspace CAS revisions and content digests stay separate fields;
//    a digest is never laundered into a revision.

import Foundation
import FloeCore

/// The document families the pinned native engine actually mounts editable.
public enum OfficeEditDocumentFamily: String, Sendable, Codable, Equatable, CaseIterable {
    case docx
    case xlsx
    case pptx

    /// Pinned producer export format token (`OfficeRequestPolicy.EXPORT_FORMATS`).
    public var exportFormatToken: String { rawValue }

    /// OOXML MIME identity used for the published run output.
    public var mimeType: String {
        switch self {
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pptx: return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        }
    }

    /// Resolves a family from a file extension; never guesses from content.
    public static func fromExtension(_ fileExtension: String) -> OfficeEditDocumentFamily? {
        OfficeEditDocumentFamily(rawValue: fileExtension.lowercased())
    }
}

/// Read-only producer queries the tool exposes (each maps 1:1 onto one typed
/// precision action; no raw wire command is ever model-visible).
public enum OfficeEditReadCommand: String, Sendable, Codable, Equatable, CaseIterable {
    /// Real producer `status:` facts (type/parts/selectedPart/readOnly/modified).
    case documentContext
    /// The producer's own current text-selection content.
    case textSelection
    /// Calc cursor/range POSITION (never content).
    case cellCursor
    /// Impress slide-inventory facts.
    case presentationInfo
}

/// Effects the tool exposes. `selectSlide`/`selectAllText` are preparatory
/// (no document bytes, no publication); `applyText`/`setCellContent` are
/// CONTENT effects and require the full verified-export chain.
public enum OfficeEditApplyCommand: String, Sendable, Codable, Equatable, CaseIterable {
    case selectSlide
    case selectAllText
    case applyText
    case setCellContent

    /// True when the effect changes document content and therefore must end in
    /// a verified saved snapshot before the tool may report success.
    public var isContentEffect: Bool {
        self == .applyText || self == .setCellContent
    }
}

/// Typed intent for cell content. The caller MUST state the intent so the
/// saved cell is verified against what was actually requested (Main fixed
/// contract `OFFICE_AI_SEMANTIC_V2`, additive amendment/2):
///  * `literal` — an EXACT string (including `00123`, leading `=` and
///    apostrophes). The trusted App host applies a leading `=` literal through
///    its safe apostrophe encoding, so the shared surface no longer refuses it;
///    verification is the saved cell's string type + raw expected content.
///  * `number` — an explicit finite numeric intent. The shared side validates
///    the canonical decimal grammar/finite value here; the App host verifies
///    `f` absent + `t` absent/n + numeric equivalence of the actually stored
///    XML value, refusing precision loss honestly.
///  * `formula` — a native FORMULA; the leading `=` is mandatory. Verification
///    is the ACTUAL saved `<f>` source under conservative normalization; a
///    cached result type (`n`/`str`/`b`/`e`) alongside the formula is VALID.
public enum OfficeEditContentKind: String, Sendable, Codable, Equatable {
    case literal
    case number
    case formula
}

/// Terminal classification of one host-executed operation. Mirrors the engine's
/// own honesty ladder — `nativeCompleted` is NOT tool success for a content
/// effect (see `OfficeEditApplyCommand.isContentEffect`).
public enum OfficeEditResultState: String, Sendable, Codable, Equatable {
    /// A real producer answer frame was observed for a read command.
    case queryObserved
    /// Producer completion evidence arrived and every mandatory positional
    /// readback agreed, but the content postcondition is not yet confirmed.
    case nativeCompleted
    /// Completion plus a real producer readback that matched exactly, or the
    /// producer's own navigation/selection postcondition echo.
    case mutationVerified
    /// Refused before any effect.
    case rejected
    /// The producer refused/failed, or a mandatory readback disagreed.
    case failed
    /// No proof within the bounded window; effects stay uncertain and are
    /// retained — never auto-replayed, never auto-undone.
    case unknown
}

/// Typed facts answered by a read command or echoed by an effect. Every field
/// is an OBSERVED producer fact; an absent fact stays absent, never defaulted.
public struct OfficeEditQueryFacts: Sendable, Equatable {
    public var docType: String?
    public var partsCount: Int?
    public var selectedPart: String?
    public var viewID: Int?
    public var readOnly: Bool?
    /// Corroborating only: the last observed `.uno:ModifiedStatus`.
    public var documentModified: Bool?
    /// Selection content for `textSelection` (bounded; see `selectionTruncated`).
    public var selectionText: String?
    public var selectionByteCount: Int?
    /// True when the selection exceeded the tool's own bound and was NOT
    /// returned in full — an honest limit, never a silent truncation.
    public var selectionTruncated: Bool?
    /// Calc cursor position (0-based column/row); `cellEmpty` mirrors EMPTY.
    public var cellColumn: Int?
    public var cellRow: Int?
    public var cellEmpty: Bool?
    /// Impress slide inventory.
    public var slideCount: Int?
    /// Navigation postcondition: the part the producer actually shows.
    public var shownPart: String?
    /// Selection postcondition: bytes of the non-empty selection readback.
    public var selectedTextBytes: Int?
    /// The ACTUAL captured LOGICAL sheet/slide index (0-based) behind this
    /// context (amendment/2 `partIndex`): the engine resolves the workbook /
    /// presentation XML ordered relationships, so this is the logical index,
    /// never a filename ordinal. The verifier must target THIS part — a silent
    /// default to sheet1 is a refusal-grade defect after reorder/delete.
    public var partIndex: Int?
    /// CAPTURE_BASELINE addendum (Main 2026-10-27): the ACTUAL current native
    /// flushed working-copy digest at capture time (the engine's own
    /// TargetCaptured value for the SAME returned target/session/generation).
    /// This is the authoritative CURRENT capture baseline — never the App
    /// initial-stage staged hash. Absent or unprovable ⇒ the context refuses
    /// honestly instead of falling back to the initial-stage snapshot.
    public var captureWorkingCopySha256: String?
    /// Byte length paired with `captureWorkingCopySha256` (positive, bounded
    /// by `OfficeEditLimits.maximumCaptureWorkingCopyBytes`); never invented.
    public var captureWorkingCopyBytes: Int?

    public init(docType: String? = nil, partsCount: Int? = nil, selectedPart: String? = nil,
                 viewID: Int? = nil, readOnly: Bool? = nil, documentModified: Bool? = nil,
                 selectionText: String? = nil, selectionByteCount: Int? = nil,
                 selectionTruncated: Bool? = nil, cellColumn: Int? = nil, cellRow: Int? = nil,
                 cellEmpty: Bool? = nil, slideCount: Int? = nil, shownPart: String? = nil,
                 selectedTextBytes: Int? = nil, partIndex: Int? = nil,
                 captureWorkingCopySha256: String? = nil, captureWorkingCopyBytes: Int? = nil) {
        self.docType = docType
        self.partsCount = partsCount
        self.selectedPart = selectedPart
        self.viewID = viewID
        self.readOnly = readOnly
        self.documentModified = documentModified
        self.selectionText = selectionText
        self.selectionByteCount = selectionByteCount
        self.selectionTruncated = selectionTruncated
        self.cellColumn = cellColumn
        self.cellRow = cellRow
        self.cellEmpty = cellEmpty
        self.slideCount = slideCount
        self.shownPart = shownPart
        self.selectedTextBytes = selectedTextBytes
        self.partIndex = partIndex
        self.captureWorkingCopySha256 = captureWorkingCopySha256
        self.captureWorkingCopyBytes = captureWorkingCopyBytes
    }

    /// True when no fact at all was observed (an honest empty answer).
    public var isEmpty: Bool {
        docType == nil && partsCount == nil && selectedPart == nil && viewID == nil
            && readOnly == nil && documentModified == nil && selectionText == nil
            && selectionByteCount == nil && cellColumn == nil && cellRow == nil
            && cellEmpty == nil && slideCount == nil && shownPart == nil
            && selectedTextBytes == nil && partIndex == nil
            && captureWorkingCopySha256 == nil && captureWorkingCopyBytes == nil
    }
}

/// One host-executed operation result. `failureCode`/`detail` are path-free and
/// content-free so they stay localizable and log-safe.
public struct OfficeEditCommandResult: Sendable, Equatable {
    public var state: OfficeEditResultState
    public var failureCode: String?
    public var detail: String?
    /// Producer evidence lineage (frame/step names only).
    public var attestation: String
    /// Engine-issued single-use target handle answered by a capture.
    public var targetHandle: String?
    public var facts: OfficeEditQueryFacts
    /// How far content verification got: matched | mismatched |
    /// formulaNotComparable | unavailable | notAttempted.
    public var contentReadback: String?
    /// The operation identity this result belongs to (stable across retries).
    public var operationIdentity: String

    public init(state: OfficeEditResultState, failureCode: String? = nil, detail: String? = nil,
                attestation: String = "", targetHandle: String? = nil,
                facts: OfficeEditQueryFacts = OfficeEditQueryFacts(),
                contentReadback: String? = nil, operationIdentity: String = "") {
        self.state = state
        self.failureCode = failureCode
        self.detail = detail
        self.attestation = attestation
        self.targetHandle = targetHandle
        self.facts = facts
        self.contentReadback = contentReadback
        self.operationIdentity = operationIdentity
    }

    /// True only for the two states that prove the producer really acted.
    public var isEffectProven: Bool { state == .mutationVerified || state == .nativeCompleted }
}

/// The trusted identity/revision facts of the App-owned open document. Two
/// identity families are kept strictly apart:
///  * ORIGINAL source: `sourceID` / opaque `sourceRevision` / `sourceLogicalPath`
///    / `originalSnapshotSha256` (the immutable staged snapshot digest);
///  * CURRENT working copy: `workingCopySha256` / `workingCopyBytes` (the last
///    FLUSHED bytes — an unflushed native edit is not in this file) plus the
///    engine's own `nativeGeneration`.
public struct OfficeEditDocumentFacts: Sendable, Equatable {
    public var sessionToken: String
    /// Read from the ENGINE for this exact session token — the App-side
    /// hostGeneration/nativeEpoch are App facts and are NOT equivalent.
    public var nativeGeneration: Int64
    public var viewerIncarnation: Int64
    public var hostGeneration: String?
    public var nativeEpoch: String?
    public var ownerTaskID: UUID
    /// Honest nil for the run-output route; a run output is not a workspace
    /// document and its digest is never laundered into a CAS revision.
    public var workspaceID: UUID?
    public var sourceLogicalPath: String?
    public var sourceID: String?
    /// Opaque workspace CAS token only; never derived from a digest.
    public var sourceRevision: String?
    public var family: OfficeEditDocumentFamily
    public var editable: Bool
    public var originalSnapshotSha256: String?
    public var originalSnapshotBytes: Int64
    public var workingCopySha256: String?
    public var workingCopyBytes: Int64
    /// Bounded display name derived from the trusted source identity.
    public var displayName: String
    /// Which trusted realm the App operation resolved from (never a guess).
    public var route: Route

    public enum Route: String, Sendable, Equatable {
        /// Opened from this conversation's workspace (real CAS identity).
        case workspace
        /// Opened from a sealed run output of this conversation (copy-only).
        case runOutput
    }

    public init(sessionToken: String, nativeGeneration: Int64, viewerIncarnation: Int64,
                hostGeneration: String?, nativeEpoch: String?, ownerTaskID: UUID,
                workspaceID: UUID?, sourceLogicalPath: String?, sourceID: String?,
                sourceRevision: String?, family: OfficeEditDocumentFamily, editable: Bool,
                originalSnapshotSha256: String?, originalSnapshotBytes: Int64,
                workingCopySha256: String?, workingCopyBytes: Int64, displayName: String,
                route: Route) {
        self.sessionToken = sessionToken
        self.nativeGeneration = nativeGeneration
        self.viewerIncarnation = viewerIncarnation
        self.hostGeneration = hostGeneration
        self.nativeEpoch = nativeEpoch
        self.ownerTaskID = ownerTaskID
        self.workspaceID = workspaceID
        self.sourceLogicalPath = sourceLogicalPath
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.family = family
        self.editable = editable
        self.originalSnapshotSha256 = originalSnapshotSha256
        self.originalSnapshotBytes = originalSnapshotBytes
        self.workingCopySha256 = workingCopySha256
        self.workingCopyBytes = workingCopyBytes
        self.displayName = displayName
        self.route = route
    }

    /// True when an original-save is even addressable: a real workspace realm
    /// with a logical path. A run-output original stays immutable and copy-only.
    public var supportsOriginalSave: Bool {
        route == .workspace && workspaceID != nil
            && !(sourceLogicalPath ?? "").isEmpty
    }
}

// The concrete command surfaces live in `OfficeEditEnginePort.swift`:
// `OfficeEditPreparatoryCommand` and `OfficeEditContentCommand`, because
// preparatory and content effects need different terminal chains. Every
// stage's engine opId derives from the STABLE per-call seed (see
// `OfficeEditOperationIdentity`), so a retried or re-acknowledged submission
// can never re-apply an effect under a fresh identity.

/// A real, host-verified saved snapshot: the ONLY thing that may be published
/// as a run output or committed over an original. `path` is a trusted
/// host-owned absolute path (never model-supplied, never logged).
public struct OfficeEditSavedSnapshot: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// In-place working-copy flush (native re-read + digested the file).
        case workingCopyFlush
        /// Synchronous JNI saveAs into a module-owned private output, fully
        /// verified (regular file, size, whole-file digest, format magic).
        case stagedExport
    }

    public var kind: Kind
    public var path: String
    public var sha256: String
    public var byteCount: Int64
    public var format: OfficeEditDocumentFamily
    public var displayName: String
    public var attestation: String
    public var sessionToken: String
    public var nativeGeneration: Int64

    public init(kind: Kind, path: String, sha256: String, byteCount: Int64,
                format: OfficeEditDocumentFamily, displayName: String, attestation: String,
                sessionToken: String, nativeGeneration: Int64) {
        self.kind = kind
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
        self.format = format
        self.displayName = displayName
        self.attestation = attestation
        self.sessionToken = sessionToken
        self.nativeGeneration = nativeGeneration
    }
}

/// Which owned proof class one semantic inspection belongs to
/// (amendment/2 `verificationMode`). The host binds its reply facts to the
/// SAME class — a `liveEffect` proof is never silently downgraded into a
/// historical reuse and vice versa.
public enum OfficeEditVerificationMode: String, Sendable, Codable, Equatable {
    /// A fresh capture → apply → flush → export chain verified live against
    /// the owned native effect record (session/generation/targetHandle bound).
    case liveEffect
    /// A COMPLETED authorized job's durable artifact, re-verified under the
    /// collecting call from the row's own digest (never a model summary/path).
    case completedJob
    /// An interrupted job's exact-export-opId artifact recovered at launch
    /// reconciliation; nil stays honest `interrupted` when no proof exists.
    case reconcile
}

/// What the owned semantic verification must confirm in the ACTUAL saved OOXML
/// part. Carries the intent, never a raw wire command.
public struct OfficeEditExpectations: Sendable, Equatable {
    public var command: OfficeEditApplyCommand
    public var family: OfficeEditDocumentFamily
    /// The text that was applied (bounded; travels as staged bytes for EVERY
    /// content kind — amendment/2: the raw expected text is staged for
    /// literal, number AND formula; the v1 prose that said "empty for
    /// formula" was wrong about the already-delivered bridge).
    public var text: String?
    public var cell: String?
    public var contentKind: OfficeEditContentKind?
    /// 0-based LOGICAL part index the effect targeted (slide/sheet), when
    /// applicable — the actual captured index (amendment/2), never a default.
    public var partIndex: Int?
    /// The selection that was current when the effect was applied, when the
    /// tool observed one — used for honest replacement-scope reporting.
    public var priorSelectionText: String?
    /// For a LIVE semantic delta this binds the CURRENT native capture's
    /// FLUSHED working-copy SHA (the pre-edit baseline for THIS effect) —
    /// amendment/2: NOT the initial immutable source snapshot. The original
    /// source base/CAS identity stays a separate field of the document facts.
    /// Nil when no trustworthy baseline exists (collect of an old row whose
    /// captured baseline was never persisted, reconcile without the preimage):
    /// the verifier then simply cannot claim a semantic delta.
    public var preEditSnapshotSha256: String?
    /// The owned verification identity (amendment/2 `verifyDescriptorAdditions`).
    /// `liveEffect` REQUIRES the session/generation/targetHandle binding
    /// (supplied by the bridge from the captured context, never the model);
    /// `completedJob`/`reconcile` carry the deterministically RECOMPUTED
    /// ORIGINAL stage opIds (effectOpId/exportOpId) — never the collect or
    /// reconcile call's own identity.
    public var verificationMode: OfficeEditVerificationMode?
    public var effectOpId: String?
    public var exportOpId: String?
    /// Core-owned captured native handle for a live effect; travels only on
    /// the trusted host verify ticket, never toward any model surface.
    public var targetHandle: String?
    /// The OWNING task this proof binds to, from the actual Core owner only
    /// (amendment/2 `taskID`): the captured context's conversation for a live
    /// effect, the durable row's validated conversation for completedJob /
    /// reconcile — never a model-supplied identity.
    public var ownerTaskID: UUID?

    public init(command: OfficeEditApplyCommand, family: OfficeEditDocumentFamily,
                text: String? = nil, cell: String? = nil,
                contentKind: OfficeEditContentKind? = nil, partIndex: Int? = nil,
                priorSelectionText: String? = nil, preEditSnapshotSha256: String? = nil,
                verificationMode: OfficeEditVerificationMode? = nil,
                effectOpId: String? = nil, exportOpId: String? = nil,
                targetHandle: String? = nil, ownerTaskID: UUID? = nil) {
        self.command = command
        self.family = family
        self.text = text
        self.cell = cell
        self.contentKind = contentKind
        self.partIndex = partIndex
        self.priorSelectionText = priorSelectionText
        self.preEditSnapshotSha256 = preEditSnapshotSha256
        self.verificationMode = verificationMode
        self.effectOpId = effectOpId
        self.exportOpId = exportOpId
        self.targetHandle = targetHandle
        self.ownerTaskID = ownerTaskID
    }
}

/// Owned OOXML semantic facts read from the ACTUAL saved package. These are the
/// difference between "the native engine accepted my paste" and "the user's
/// file really contains the intended typed value".
public struct OfficeEditSemanticFacts: Sendable, Equatable {
    /// True only when the host really opened the saved package and produced
    /// specific part-level facts (never inferred from a receipt).
    public var inspectedSavedPackage: Bool
    /// The part actually inspected, e.g. `word/document.xml`.
    public var partName: String?
    public var expectedTextFound: Bool?
    public var occurrenceCount: Int?
    /// Honest replacement scope: `selectionReplaced` | `insertedAtCursor` |
    /// `wholeBodyReplaced` | `indeterminate`.
    public var replacementScope: String?
    /// Persisted cell type attribute (`s`/`str`/`n`/`inlineStr`/`b`/`e`) or the
    /// empty string when the cell carries no `t` (numeric default).
    public var cellTypeAttribute: String?
    public var cellHasFormula: Bool?
    /// Bounded persisted value (`<v>`, or the resolved shared/inline string).
    public var cellPersistedValue: String?
    /// True when the persisted type matches the caller's declared intent:
    ///  * literal — no `<f>` and the saved cell is string-typed with the exact
    ///    intended raw value (`00123` did NOT silently become a number);
    ///  * number — no `<f>` and `t` absent/`n` (numeric default);
    ///  * formula — a REAL `<f>` is present; a cached result type
    ///    (`n`/`str`/`b`/`e`) alongside it is VALID, never by itself a mismatch
    ///    (amendment/2 repairs the v1 refusal of every non-empty `t`+`f`).
    public var cellTypeMatchesIntent: Bool?
    /// True when the ACTUAL saved bytes differ from the bound pre-edit
    /// baseline (measured digest equality, never an acknowledgement-derived
    /// claim). A `nil` baseline honestly yields nil here.
    public var changedFromOriginal: Bool?
    // MARK: Amendment/2 owned proof additions (verifyReplyAdditions).
    /// TRUE when the ACTUAL saved part/cell content equals the INTENDED value
    /// or formula source: exact string for literal, numeric equivalence of the
    /// stored XML for number, conservative-normalized `<f>` equality for
    /// formula. Global text presence elsewhere in the part is NOT a match.
    public var expectedContentMatches: Bool?
    /// TRUE only when a real P-A mutation was verified at the SAME captured
    /// target with the owned native effect record — never a bare
    /// `nativeCompleted`/ack, never a model flag.
    public var targetEffectVerified: Bool?
    /// TRUE when the trusted pre-edit baseline → saved part proves the
    /// requested selection replacement / insertion at a compatible target;
    /// a changed byte hash or global text presence alone is NOT a delta proof.
    public var semanticDeltaVerified: Bool?
    /// TRUE when this is a historical strong proof of an EXACT owned COMPLETED
    /// v2 native job whose actual artifact digest the Core validated from its
    /// own store (owner/target/service version/digest) — for `reconcile` the
    /// ONLY real proof record; without it the outcome stays unknown/nil.
    public var proofReused: Bool?
    /// The semantic-proof schema generation this inspection answers
    /// (amendment/2 = 2). Facts lacking the v2 owned-proof fields must never
    /// be presented as v2 proof; the gate treats absent proof as a refusal.
    public var proofVersion: Int
    /// Known honest limits (e.g. 0.01 mm PPT position loss, shared/array
    /// formulas unresolvable, precision loss refused, rich objects preserved
    /// but not re-verified).
    public var limitations: [String]

    public init(inspectedSavedPackage: Bool, partName: String? = nil,
                 expectedTextFound: Bool? = nil, occurrenceCount: Int? = nil,
                 replacementScope: String? = nil, cellTypeAttribute: String? = nil,
                 cellHasFormula: Bool? = nil, cellPersistedValue: String? = nil,
                 cellTypeMatchesIntent: Bool? = nil, changedFromOriginal: Bool? = nil,
                 expectedContentMatches: Bool? = nil, targetEffectVerified: Bool? = nil,
                 semanticDeltaVerified: Bool? = nil, proofReused: Bool? = nil,
                 proofVersion: Int = 2, limitations: [String] = []) {
        self.inspectedSavedPackage = inspectedSavedPackage
        self.partName = partName
        self.expectedTextFound = expectedTextFound
        self.occurrenceCount = occurrenceCount
        self.replacementScope = replacementScope
        self.cellTypeAttribute = cellTypeAttribute
        self.cellHasFormula = cellHasFormula
        self.cellPersistedValue = cellPersistedValue
        self.cellTypeMatchesIntent = cellTypeMatchesIntent
        self.changedFromOriginal = changedFromOriginal
        self.expectedContentMatches = expectedContentMatches
        self.targetEffectVerified = targetEffectVerified
        self.semanticDeltaVerified = semanticDeltaVerified
        self.proofReused = proofReused
        self.proofVersion = proofVersion
        self.limitations = limitations
    }

    /// Facts that prove nothing: the tool must not report success on these.
    public var isUnproven: Bool { !inspectedSavedPackage }
}

/// Explicit original-save request. Every field comes from a TRUSTED source:
/// the resolved document facts and the runtime's own epoch — never the model.
public struct OfficeEditOriginalSaveRequest: Sendable, Equatable {
    public var workspaceID: UUID
    public var logicalPath: String
    /// The digest the workspace file must still have for the CAS replace.
    public var expectedOriginalSha256: String
    public var expectedOriginalBytes: Int64
    public var nativeEpoch: UInt64

    public init(workspaceID: UUID, logicalPath: String, expectedOriginalSha256: String,
                expectedOriginalBytes: Int64, nativeEpoch: UInt64) {
        self.workspaceID = workspaceID
        self.logicalPath = logicalPath
        self.expectedOriginalSha256 = expectedOriginalSha256
        self.expectedOriginalBytes = expectedOriginalBytes
        self.nativeEpoch = nativeEpoch
    }
}

/// Typed original-save outcome. Local workspace commit and provider journal
/// push are reported SEPARATELY — an all-or-nothing success is never claimed
/// when only one half landed, and a conflict PRESERVES the recoverable copies
/// (the journal's backup/recovery row and the verified export file both stay;
/// nothing on this path deletes them and no native edit is retried).
public struct OfficeEditOriginalSaveOutcome: Sendable, Equatable {
    /// The task-workspace file replace through the acquired lease's OWN
    /// `WorkspaceFileService.replaceBinaryFile` CAS authority.
    public enum LocalState: String, Sendable, Equatable {
        /// Staged verified replace committed; `committedSHA256`/`committedBytes`
        /// are the measured post-commit facts.
        case committed
        /// CAS drift / freeze refusal / path guard refusal: nothing was
        /// overwritten.
        case conflict
        /// Rejected before any commit attempt (not writable, identity fence).
        case refused
        /// The realm has no workspace-original authority (run-output copy-only
        /// route or absent workspace identity).
        case unsupported
        /// The replace outcome is unknown (transport/timeout while a commit
        /// may be in flight): retained, never relabeled.
        case unknown
    }

    /// The provider original push through the EXISTING CAS journal ladder.
    public enum ProviderState: String, Sendable, Equatable {
        /// Journal settle really observed the replacement bytes at the
        /// provider (`committed`).
        case committed
        /// The journal refused/retained with a recoverable row (backup kept,
        /// original untouched): drift at claim, read-back mismatch, revoke…
        case retainedRecoverable
        /// Rejected before the ladder started (no provider binding row, grant
        /// revoked/read-only, lane fence).
        case refused
        /// No provider binding exists for this logical path: the workspace
        /// file IS the original; the journal is honestly not applicable.
        case notApplicable
        /// Settle outcome unknown; the journaled row stays honestly pending.
        case unknown
    }

    public var local: LocalState
    public var provider: ProviderState
    /// Measured digest/size of the workspace file AFTER a committed replace
    /// (nil unless local == .committed).
    public var committedSHA256: String?
    public var committedBytes: Int64
    /// Bounded machine token from the CAS service or the journal (path-free).
    public var localToken: String?
    public var providerToken: String?
    /// The durable journal recovery row when one exists.
    public var recoveryID: String?
    /// Path-free actionable note (recovery guidance references the recoveryID,
    /// never a private path).
    public var detail: String?

    public init(local: LocalState, provider: ProviderState, committedSHA256: String? = nil,
                committedBytes: Int64 = 0, localToken: String? = nil, providerToken: String? = nil,
                recoveryID: String? = nil, detail: String? = nil) {
        self.local = local
        self.provider = provider
        self.committedSHA256 = committedSHA256
        self.committedBytes = committedBytes
        self.localToken = localToken
        self.providerToken = providerToken
        self.recoveryID = recoveryID
        self.detail = detail
    }

    /// True ONLY when both requested halves are fully proven.
    public var isFullSuccess: Bool {
        local == .committed && (provider == .committed || provider == .notApplicable)
    }

    /// The workspace original landed but the provider push did not: report the
    /// actual partial outcome, keep every recoverable copy, never retry the
    /// native edit for it.
    public var isPartial: Bool {
        local == .committed && provider != .committed && provider != .notApplicable
    }

    /// Any retained recoverable state (conflict/pending/unknown halves).
    public var hasRecoverableState: Bool {
        local != .committed || provider == .retainedRecoverable || provider == .unknown
            || local == .unknown || recoveryID != nil
    }
}

/// The durable job facts the `collect` action may consume. Read from the
/// ORIGINAL job store only — never from a model-quoted summary or path.
public struct OfficeEditJobArtifact: Sendable, Equatable {
    public var jobID: UUID
    public var operationID: String
    public var path: String
    public var recordedSha256: String
    public var byteCount: Int64
    public var format: OfficeEditDocumentFamily
    public var displayName: String
    /// The job's own frozen payload, so `collect` re-derives the SAME
    /// expectations and re-verifies instead of trusting a stored claim.
    public var payloadJSON: Data

    public init(jobID: UUID, operationID: String, path: String, recordedSha256: String,
                byteCount: Int64, format: OfficeEditDocumentFamily, displayName: String,
                payloadJSON: Data) {
        self.jobID = jobID
        self.operationID = operationID
        self.path = path
        self.recordedSha256 = recordedSha256
        self.byteCount = byteCount
        self.format = format
        self.displayName = displayName
        self.payloadJSON = payloadJSON
    }
}

/// The shared saved-package gate: which semantic facts MUST be proven before
/// a content command may report success. Used identically by the inline tool,
/// the durable job adapter and the Core bridge's reconciliation — a missing
/// required fact is always a failure, never a pass.
///
/// Amendment/2 (Main fixed contract `OFFICE_AI_SEMANTIC_V2`): success binds
/// to the INTENDED saved content at the INTENDED target, never to global
/// text presence, a persisted type alone, or a `nativeCompleted` ack.
public enum OfficeEditSemanticGate {
    public static func failure(command: OfficeEditApplyCommand,
                               semantic: OfficeEditSemanticFacts) -> OfficeEditHostError? {
        switch command {
        case .applyText:
            // `expectedTextFound` stays a required CORROBORATING fact (the
            // applied text is present in the saved part), but presence alone
            // can never pass: the text may have pre-existed elsewhere.
            guard semantic.expectedTextFound == true else {
                return OfficeEditHostError.verificationFailed(
                    code: "savedPackageMissingAppliedText",
                    detail: "The applied text was not found in the saved package part "
                        + "\(semantic.partName ?? "unknown"). The engine accepted the paste, but the "
                        + "saved file does not prove it; no output was published.")
            }
            guard semantic.expectedContentMatches == true else {
                return OfficeEditHostError.verificationFailed(
                    code: "savedContentMismatch",
                    detail: "The saved part/cell content does not equal the intended applied text "
                        + "(global presence or a pre-existing match elsewhere is not proof of THIS "
                        + "effect). No output was published.")
            }
            // Amendment/2 applyText gate: inspected + expectedContentMatches +
            // actual text present + (targetEffectVerified OR
            // semanticDeltaVerified OR a valid historical proofReused).
            // A `nativeCompleted` state with only global contains never passes,
            // and a native mutation claim still requires the actual saved
            // file content proof above.
            guard semantic.targetEffectVerified == true
                || semantic.semanticDeltaVerified == true
                || semantic.proofReused == true else {
                return OfficeEditHostError.verificationFailed(
                    code: "savedContentProofMissing",
                    detail: "The saved content matches, but no trusted target effect, semantic "
                        + "delta, or bound historical proof verifies THIS effect at the captured "
                        + "target. The working copy and export are retained; no output was published.")
            }
            return nil
        case .setCellContent:
            // The persisted type must match the DECLARED intent: formula → a
            // real `<f>` (a cached `n`/`str`/`b`/`e` result type is VALID,
            // repairing the v1 refusal of every non-empty `t` alongside `f`);
            // number → no `<f>` with `t` absent/`n`; literal → no `<f>` with
            // the exact string value.
            guard semantic.cellTypeMatchesIntent == true else {
                return OfficeEditHostError.verificationFailed(
                    code: "savedCellTypeMismatch",
                    detail: "The persisted cell type in the saved workbook does not match the declared "
                        + "literal/number/formula intent (t=\(semantic.cellTypeAttribute ?? "absent"), "
                        + "formula=\(semantic.cellHasFormula.map { $0 ? "yes" : "no" } ?? "unknown")). "
                        + "No output was published.")
            }
            guard semantic.expectedContentMatches == true else {
                return OfficeEditHostError.verificationFailed(
                    code: "savedCellContentMismatch",
                    detail: "The saved cell content does not equal the intended value or formula "
                        + "source at the addressed cell. No output was published.")
            }
            // A cell whose saved value already equaled the intent verifies as
            // content without claiming a mutation from a byte-hash difference.
            return nil
        case .selectSlide, .selectAllText:
            return nil
        }
    }
}

/// Typed host-lane failures. Path-free and content-free by construction; every
/// case carries a bounded machine token plus an optional user-actionable note.
public enum OfficeEditHostError: Error, Sendable, Equatable {
    /// The App host lane is not bound to the live native root generation.
    case hostLaneUnavailable
    /// No App-owned document operation belongs to this conversation.
    case noOwnedDocument(detail: String)
    /// The resolved document cannot be edited (read-only mount, not editable).
    case notEditable(detail: String)
    /// The requested command is not supported for this document family.
    case unsupported(detail: String)
    /// A typed refusal from the engine/host before any effect.
    case rejected(code: String, detail: String)
    /// The producer failed, or a mandatory readback disagreed.
    case failed(code: String, detail: String)
    /// Effects are uncertain: retained, never auto-replayed or auto-undone.
    case unknown(code: String, detail: String)
    /// The saved snapshot could not be verified (bytes, structure or semantics).
    case verificationFailed(code: String, detail: String)
    /// The original save hit a real CAS/journal conflict; a copy is retained.
    case conflict(code: String, detail: String)
    /// The host lane is saturated or the ticket budget expired.
    case transport(code: String)

    /// The bounded machine token used in tool output (never a path/content).
    public var code: String {
        switch self {
        case .hostLaneUnavailable: return "hostLaneUnavailable"
        case .noOwnedDocument: return "noOwnedDocument"
        case .notEditable: return "notEditable"
        case .unsupported: return "unsupported"
        case .rejected(let code, _): return code
        case .failed(let code, _): return code
        case .unknown(let code, _): return code
        case .verificationFailed(let code, _): return code
        case .conflict(let code, _): return code
        case .transport(let code): return code
        }
    }

    /// True when effects may already have happened (retain, never clean-cancel).
    public var effectsUncertain: Bool {
        if case .unknown = self { return true }
        return false
    }
}

extension OfficeEditHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostLaneUnavailable:
            return "The Office document host is not available in this session; no document edit was attempted."
        case .noOwnedDocument(let detail):
            return "No editable Office document owned by this task is currently open (\(detail)). Open the document in this task first; this tool never edits another task's or an unowned document."
        case .notEditable(let detail):
            return "The open Office document is not editable right now (\(detail))."
        case .unsupported(let detail):
            return "That Office operation is not supported here: \(detail)"
        case .rejected(_, let detail), .failed(_, let detail):
            return detail
        case .unknown(_, let detail):
            return detail
        case .verificationFailed(_, let detail):
            return detail
        case .conflict(_, let detail):
            return detail
        case .transport(let code):
            return "The Office document host could not be reached (\(code)); nothing was changed."
        }
    }
}

/// Bounded limits for this tool. Sizes mirror the engine's own pinned bounds so
/// a refusal happens here (typed, actionable) instead of deep in the transport.
public enum OfficeEditLimits {
    /// Engine `MAX_TEXT_BYTES`.
    public static let maximumTextBytes = 64 * 1024
    /// Tool-side bound on selection text returned to the model.
    public static let maximumReturnedSelectionBytes = 32 * 1024
    /// Engine `MAX_ANSWER_BYTES_UTF8`.
    public static let maximumAnswerBytes = 256 * 1024
    /// CAPTURE_BASELINE addendum (Main 2026-10-27): the ACTUAL captured
    /// working-copy byte ceiling mirrors the Office binary replacement
    /// budget; a larger claimed capture digest is unprovable and refuses.
    public static let maximumCaptureWorkingCopyBytes = 256 * 1024 * 1024
    public static let maximumCellAddressChars = 16
    public static let maximumDisplayNameBytes = 200
    /// Bounded semantic value echo (a persisted cell value, not a document).
    public static let maximumPersistedValueChars = 512
    /// Bounded limitations list.
    public static let maximumLimitations = 8

    /// True when the text is safe to hand to the engine (non-empty, no NUL,
    /// within the pinned byte bound).
    public static func isValidText(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("\u{0}") else { return false }
        return text.utf8.count <= maximumTextBytes
    }

    /// True when the text can never spread across cells (no tab/CR/LF).
    public static func isSingleCellSafe(_ text: String) -> Bool {
        !text.contains("\t") && !text.contains("\n") && !text.contains("\r")
    }

    /// Canonical finite decimal grammar for the explicit `number` intent
    /// (amendment/2): `[+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?`
    /// with at least one mantissa digit, and the parsed value finite. Hex,
    /// NaN, infinity and empty strings are NOT canonical cell numbers, so the
    /// producer must state `literal` for those. Precision-loss honesty (e.g.
    /// a 20-digit mantissa the engine cannot store exactly) is the App
    /// verifier's refusal, one layer down.
    public static func isValidFiniteNumberText(_ text: String) -> Bool {
        guard isSingleCellSafe(text), !text.isEmpty else { return false }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 0x30 && scalar.value <= 0x39
        }
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
            index += 1
        }
        var mantissaDigits = 0
        while index < scalars.count, isDigit(scalars[index]) {
            index += 1
            mantissaDigits += 1
        }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, isDigit(scalars[index]) {
                index += 1
                mantissaDigits += 1
            }
        }
        guard mantissaDigits >= 1, index == scalars.count
            || scalars[index] == "e" || scalars[index] == "E" else { return false }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                index += 1
            }
            var exponentDigits = 0
            while index < scalars.count, isDigit(scalars[index]) {
                index += 1
                exponentDigits += 1
            }
            guard exponentDigits >= 1 else { return false }
        }
        guard index == scalars.count, let value = Double(text) else { return false }
        return value.isFinite
    }

    /// A1 cell reference with optional `$` anchors, inside Calc's real bounds
    /// (col <= XFD, row <= 1048576). Mirrors the engine's own validator so the
    /// refusal is typed here instead of after a binder round trip.
    public static func isValidCellAddress(_ address: String) -> Bool {
        guard address.count <= maximumCellAddressChars else { return false }
        let stripped = address.replacingOccurrences(of: "$", with: "")
        guard !stripped.isEmpty else { return false }
        let letters = stripped.prefix(while: { $0.isLetter })
        let digits = stripped.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return false }
        guard letters.count <= 3 else { return false }
        var column = 0
        for character in letters.uppercased() {
            guard let scalar = character.unicodeScalars.first,
                  ("A"..."Z").contains(String(scalar)) else { return false }
            column = column * 26 + (Int(scalar.value) - 64)
            guard column <= 16_384 else { return false }
        }
        guard let row = Int(digits), row >= 1, row <= 1_048_576 else { return false }
        return true
    }

    /// Canonical uppercase, `$`-stripped A1 form (the engine's own canonical).
    public static func canonicalCellAddress(_ address: String) -> String {
        address.replacingOccurrences(of: "$", with: "").uppercased()
    }

    /// 0-based row of an A1 address (nil when invalid).
    public static func cellRow(_ address: String) -> Int? {
        guard isValidCellAddress(address) else { return nil }
        let digits = address.replacingOccurrences(of: "$", with: "")
            .reversed()
            .prefix(while: { $0.isNumber })
        guard let row = Int(String(digits.reversed())) else { return nil }
        return row - 1
    }

    /// 0-based column of an A1 address (nil when invalid).
    public static func cellColumn(_ address: String) -> Int? {
        guard isValidCellAddress(address) else { return nil }
        let letters = address.replacingOccurrences(of: "$", with: "").prefix(while: { $0.isLetter })
        var column = 0
        for character in letters.uppercased() {
            guard let scalar = character.unicodeScalars.first else { return nil }
            column = column * 26 + (Int(scalar.value) - 64)
        }
        return column - 1
    }
}
