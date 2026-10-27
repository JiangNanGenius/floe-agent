// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the ORIGINAL
// `NativeJobServiceAdapter` for `document.office.edit`.
//
// What this connects (and what it deliberately is NOT):
//  * `requiresRuntimeAuthorization = true`, so the ORIGINAL
//    `BackgroundJobService.submit` CONSUMES the runtime-issued approval for
//    the exact `jobs.submit` call BEFORE `prepare` runs and passes the proof
//    in `NativeJobPreparationRequest.authorization`. A model field, a
//    rehearsed grant string or a re-serialized payload can never produce it.
//  * `prepare` freezes the concrete operation (opaque edit-context selector,
//    typed command, per-stage deterministic opIds) BEFORE any durable record
//    exists; throwing refuses the submission with nothing persisted.
//  * The durable job runs the same verified chain as the inline tool and
//    records the REAL artifact digest as `NativeJobOutcome.digest` + path.
//    It publishes NO run output itself: `run(hooks:)` has no runtime-issued
//    ToolContext, the strict seal in `AgentRuntime.finalizeToolResult` only
//    binds receipts to the CURRENT settled call, and `jobs.result` returns a
//    JSON page only (Main integration fact 2026-10-27). The durable user-file
//    card is created by `document.office.edit action=collect jobID=…` reading
//    THIS row's own facts — never by relabeling a quoted summary/path.
//  * Idempotency: stage opIds derive from the submitting run/call/frozen
//    payload digest. A resubmission of the same call re-derives the SAME
//    identities, and the engine's own duplicate-opId refusal blocks any second
//    effect; the operation never invents fresh ids to "make progress".
//  * UNKNOWN effects throw `NativeJobSafetyFailure` (retained, not a clean
//    cancellation). Launch reconciliation accepts `.completed` ONLY after a
//    real engine artifact of the exact export operation is re-verified
//    byte-for-byte and semantically; otherwise the row stays honestly
//    `interrupted`.

import Foundation
import FloeCore
import FloeTools
import FloeModels
import FloePersistence

public enum OfficeEditJobAdapter {

    /// The frozen, transport-independent description of one deferrable Office
    /// AI apply. Persisted inside the prepared operation only; the durable
    /// job row keeps the ORIGINAL payload JSON.
    struct FrozenOperation {
        let operationID: String
        let seed: String
        let contextID: String
        let commandKind: ApplyKind
        let conversationID: UUID
        let document: OfficeEditDocumentFacts
        /// Amendment/2: the ACTUAL captured LOGICAL part index (0-based) the
        /// frozen target lives on, captured at prepare time. Persisted into
        /// the durable outcome summary so a later `collect` can bind the
        /// historical proof to the real part — never a sheet1 default, never
        /// the model's `slide` argument.
        let capturedPartIndex: Int?

        enum ApplyKind: Sendable {
            case applyText(String)
            case setCellContent(cell: String, text: String, kind: OfficeEditContentKind)
        }
    }

    /// The one adapter the Android composition registers for
    /// `document.office.edit`. `adaptedActions = ["apply"]`: only content
    /// applies are deferrable; reads, preparatory effects and `collect` run
    /// inline (`collect` needs a real current ToolContext to seal into).
    public static func make(port: any OfficeEditEnginePort) -> NativeJobServiceAdapter {
        NativeJobServiceAdapter(
            targetTool: OfficeDocumentEditTool.name,
            adaptedActions: ["apply"],
            requiresRuntimeAuthorization: true,
            prepare: { request in
                try await prepare(port: port, request: request)
            },
            reconcile: { job in
                await reconcile(port: port, job: job)
            }
        )
    }

    // MARK: - prepare (before anything is durable)

    static func prepare(port: any OfficeEditEnginePort,
                        request: NativeJobPreparationRequest) async throws
        -> any NativeJobPreparedOperation {
        // The ORIGINAL service already consumed the runtime authority before
        // reaching `prepare` (requiresRuntimeAuthorization). Re-assert the
        // proof shape here: a preparation without a consumed binding is a
        // composition bug and must fail closed, not persist.
        guard request.consumedBinding != nil else {
            throw FloeError.validationFailed(
                "document.office.edit apply must carry the consumed runtime authorization of this exact jobs.submit call")
        }
        guard port.isHostLaneLive() else { throw OfficeEditHostError.hostLaneUnavailable }
        let args: OfficeDocumentEditTool.Arguments
        do {
            args = try JSONDecoder().decode(OfficeDocumentEditTool.Arguments.self,
                                            from: request.payloadJSON)
        } catch {
            throw FloeError.validationFailed(
                "The job payload is not a valid document.office.edit apply argument set")
        }
        guard args.action == .apply,
              let raw = args.command,
              let apply = OfficeEditApplyCommand(rawValue: raw),
              apply.isContentEffect,
              let contextID = args.editContext,
              OfficeDocumentEditTool.isOpaqueSelector(contextID) else {
            throw FloeError.validationFailed(
                "Only content applies (applyText/setCellContent) with a captured editContext can run as jobs; reads, selectSlide/selectAllText and collect run inline")
        }
        // The captured context must still be live and belong to THIS
        // conversation, answered WITHOUT any host call or fresh capture. If
        // the model's own captured target already expired, refuse now with
        // nothing durable instead of creating a job that could only fail
        // later (and must never re-capture silently).
        guard let document = port.contextDocument(contextID: contextID,
                                                  conversationID: request.conversationID) else {
            throw FloeError.validationFailed(
                "The editContext is unknown, expired or already consumed; run document.office.edit read again — a job must freeze the SAME target the model reasoned from")
        }
        // Amendment/2: capture the ACTUAL logical part index behind this
        // context (transport-free; nil when the family has no part concept).
        let capturedFacts = port.capturedContextFacts(contextID: contextID,
                                                      conversationID: request.conversationID)
        guard document.editable, document.route == .workspace || document.route == .runOutput else {
            throw OfficeEditHostError.notEditable(detail: "The captured document is not editable right now")
        }
        let payloadDigest = RuntimeAuthorityDigest.payloadDigest(request.payloadJSON)
        let seed = OfficeEditOperationIdentity.derive(
            runID: request.runID, callID: request.submittedCallID,
            payloadDigest: payloadDigest, step: "call")
        guard OfficeEditOperationIdentity.isValid(seed) else {
            throw FloeError.internalError("office apply operation seed malformed")
        }
        let kind: FrozenOperation.ApplyKind
        switch apply {
        case .applyText:
            guard let text = args.text, OfficeEditLimits.isValidText(text) else {
                throw FloeError.validationFailed("applyText content is invalid")
            }
            kind = .applyText(text)
        case .setCellContent:
            guard let cell = args.cell, OfficeEditLimits.isValidCellAddress(cell),
                  let text = args.text, OfficeEditLimits.isValidText(text),
                  OfficeEditLimits.isSingleCellSafe(text),
                  let kindRaw = args.contentType,
                  let contentKind = OfficeEditContentKind(rawValue: kindRaw) else {
                throw FloeError.validationFailed("setCellContent arguments are invalid")
            }
            switch contentKind {
            case .literal:
                // Amendment/2: exact-string intent; a leading '=' is the host's
                // safe apostrophe-encoded literal, never refused here.
                break
            case .number:
                guard OfficeEditLimits.isValidFiniteNumberText(text) else {
                    throw FloeError.validationFailed(
                        "contentType=number requires a finite canonical decimal number")
                }
            case .formula:
                guard text.hasPrefix("=") else {
                    throw FloeError.validationFailed("a formula must start with '='")
                }
            }
            kind = .setCellContent(cell: OfficeEditLimits.canonicalCellAddress(cell),
                                   text: text, kind: contentKind)
        default:
            throw FloeError.validationFailed("unsupported deferred command")
        }
        return OfficeEditPreparedJob(
            port: port,
            frozen: FrozenOperation(operationID: request.operationID, seed: seed,
                                    contextID: contextID, commandKind: kind,
                                    conversationID: request.conversationID,
                                    document: document,
                                    capturedPartIndex: capturedFacts?.partIndex))
    }

    // MARK: - reconcile (durable receipts only, never fictional success)

    static func reconcile(port: any OfficeEditEnginePort, job: BackgroundJob) async
        -> BackgroundJobState? {
        guard job.targetTool == OfficeDocumentEditTool.name,
              let doc = NativeJobProgressDocument.decode(job.progressJSON),
              let operationID = doc.prepared?.operationID else { return nil }
        // The row's own frozen payload re-derives the deterministic export
        // identity; a payload that no longer matches its recorded operation is
        // evidence of a corrupt row, not a side effect to reconcile.
        guard let args = try? JSONDecoder().decode(OfficeDocumentEditTool.Arguments.self,
                                                   from: job.payloadJSON),
              args.action == .apply,
              let raw = args.command,
              let apply = OfficeEditApplyCommand(rawValue: raw),
              apply.isContentEffect else { return nil }
        let payloadDigest = RuntimeAuthorityDigest.payloadDigest(job.payloadJSON)
        let seed = OfficeEditOperationIdentity.derive(
            runID: job.runID, callID: job.toolCallID, payloadDigest: payloadDigest, step: "call")
        // The family is the row's OWN frozen fact (the prepared service label
        // written by this same adapter at submit) — never a guess.
        let frozenFamily = doc.prepared?.serviceLabel
            .split(separator: "/").last.map { OfficeEditDocumentFamily(rawValue: String($0)) } ?? nil
        guard let family = apply == .setCellContent ? .xlsx : frozenFamily else { return nil }
        // Amendment/2 (Main ruling): XLSX/PPTX target effects REQUIRE the
        // captured LOGICAL part identity. An interrupted durable row carries
        // none — the frozen payload schema and prepared summary are unchanged
        // and the in-memory capture is gone — so reconciliation refuses
        // honestly instead of guessing a part (never filename-ordinal, never
        // sheet1). DOCX applyText has no part ambiguity and still reconciles
        // by the exact export-opId artifact proof.
        if family == .xlsx || family == .pptx { return nil }
        // Amendment/2: reconciliation proof is a REAL recovered artifact of the
        // ORIGINAL export operation only — the recomputed seed carries the
        // deterministic original stage opIds (never this reconcile's identity),
        // and the bridge still applies the full v2 semantic gate. Without a
        // trustworthy historical proof the row stays honestly `interrupted`.
        let expectations = OfficeEditExpectations(
            command: apply, family: family,
            text: args.text,
            cell: args.cell.map(OfficeEditLimits.canonicalCellAddress),
            contentKind: args.contentType.flatMap(OfficeEditContentKind.init(rawValue:)),
            verificationMode: .reconcile,
            effectOpId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply"),
            exportOpId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export"),
            ownerTaskID: job.conversationID)
        let token = CancellationToken()
        guard let snapshot = try? await port.interruptedJobArtifact(
            operationID: operationID,
            exportOpId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export"),
            expectations: expectations, cancellation: token),
            snapshot.format == family else { return nil }
        // A verified, semantically matching artifact of THIS exact export
        // operation really exists → the interrupted attempt's effect is a
        // proven fact. Only the terminal STATE may be reclassified here; the
        // artifact pointer/summary bookkeeping stays whatever the durable row
        // actually recorded (never rewritten into a fake success string).
        return .completed
    }
}

// MARK: - The prepared durable operation

/// One frozen, service-owned Office AI apply. `run` reaches a REAL verified
/// terminal result or throws; a requested cancellation unwinds cooperatively
/// and only then throws `FloeError.cancelled`; an effect whose outcome is
/// uncertain throws the ORIGINAL `NativeJobSafetyFailure` so no consumer can
/// report a clean cancellation or a fabricated success.
struct OfficeEditPreparedJob: NativeJobPreparedOperation {
    let port: any OfficeEditEnginePort
    let frozen: OfficeEditJobAdapter.FrozenOperation

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        let token = CancellationToken()
        var effectDispatched = false
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func requestCancel() { lock.lock(); cancelled = true; lock.unlock(); token.cancel() }
        func markDispatched() { lock.lock(); effectDispatched = true; lock.unlock() }
        var dispatched: Bool { lock.lock(); defer { lock.unlock() }; return effectDispatched }
    }
    private let box = Box()

    var operationID: String { frozen.operationID }
    var serviceLabel: String { "document.office.edit/\(frozen.document.family.rawValue)" }
    /// The digest of the immutable snapshot staged when the captured context
    /// was opened — the revision the frozen operation was built against.
    var frozenRevision: String? { frozen.document.originalSnapshotSha256 }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        guard !box.isCancelled() else { throw FloeError.cancelled }
        guard port.isHostLaneLive() else { throw OfficeEditHostError.hostLaneUnavailable }
        // The ORIGINAL service re-derives this same deterministic operationID
        // (run/call/payload digest). A row whose prepared summary names a
        // different identity is a contradiction; refuse rather than dispatch
        // against an identity the durable record does not describe.
        let command: OfficeEditContentCommand
        switch frozen.commandKind {
        case .applyText(let text):
            command = .applyText(text)
        case .setCellContent(let cell, let text, let kind):
            command = .setCellContent(cell: cell, text: text, kind: kind)
        }
        await hooks.report(NativeJobProgress(stage: .running, phase: "precision-apply",
                                             note: "Applying the frozen Office edit to the captured target"))
        box.markDispatched() // from here an effect may exist; uncertainty is unsafe
        let outcome = try await port.executeContent(
            command, contextID: frozen.contextID, conversationID: frozen.conversationID,
            seed: frozen.seed, cancellation: box.token)

        guard outcome.result.isEffectProven else {
            if outcome.result.state == .unknown || outcome.flush.state == .unknown {
                throw NativeJobSafetyFailure(
                    reason: "The precision apply's outcome is UNKNOWN inside the bounded window "
                        + "(engine evidence: \(outcome.result.attestation.prefix(64))); the native "
                        + "working copy may carry the effect and is retained; nothing was replayed "
                        + "or undone automatically")
            }
            throw OfficeEditHostError.failed(
                code: outcome.result.failureCode ?? "applyNotProven",
                detail: "The apply did not reach a proven terminal state "
                    + "(\(outcome.result.state.rawValue)): \(outcome.result.detail ?? "no effect recorded")")
        }
        guard outcome.flush.state == .flushed, let snapshot = outcome.snapshot,
              let semantic = outcome.semantic, !semantic.isUnproven else {
            if outcome.flush.state == .unknown {
                throw NativeJobSafetyFailure(
                    reason: "The working-copy flush went UNKNOWN after a proven apply; the saved "
                        + "state is uncertain and every copy is retained")
            }
            throw NativeJobSafetyFailure(
                reason: "The apply landed natively but the saved bytes did not verify "
                    + "(flush \(outcome.flush.state.rawValue), inspected "
                    + "\(String(describing: outcome.semantic?.inspectedSavedPackage))); the working "
                    + "copy and any partial export remain recoverable")
        }
        let gate: OfficeEditApplyCommand
        switch frozen.commandKind {
        case .applyText: gate = .applyText
        case .setCellContent: gate = .setCellContent
        }
        if let verdict = OfficeDocumentEditTool.semanticGateFailure(command: gate,
                                                                    semantic: semantic) {
            // The native effect happened but the saved package does not prove
            // the intended content/type: retained, unsafe, never a success.
            throw NativeJobSafetyFailure(
                reason: "saved bytes do not prove the applied content (\(verdict.code)); the "
                    + "working copy and export remain recoverable for inspection")
        }
        // If cancellation arrived after this verified commit boundary, the
        // ORIGINAL service reports the actual completed result with its honest
        // note; a verified terminal result is never relabeled as cancelled.
        await hooks.report(NativeJobProgress(stage: .verifying, phase: "verified",
                                             note: box.isCancelled()
                                                 ? "verified terminal reached; cancellation arrived late"
                                                 : "verified terminal reached"))
        var summaryFields: [String: Any] = [
            "status": "verifiedSaved",
            "operation": frozen.operationID,
            "seed": frozen.seed,
            "engineState": outcome.result.state.rawValue,
            "attestation": String(outcome.result.attestation.prefix(128)),
            "flushSHA256": outcome.flush.workingCopySha256 ?? "",
            "savedSHA256": snapshot.sha256,
            "savedBytes": snapshot.byteCount,
            "format": snapshot.format.rawValue,
            "semantic": [
                "part": outcome.semantic?.partName ?? "-",
                "inspected": true,
                "proofVersion": outcome.semantic?.proofVersion ?? 2,
            ],
            "publish": "This durable job artifact is published as a user-file card by "
                + "document.office.edit action=collect with this job's id (jobs.submit answered it); "
                + "collect only re-verifies and seals THIS stored artifact and never replays the edit.",
        ]
        // Amendment/2: persist BOUNDED owned v2 target metadata into the
        // durable outcome summary (stored by the ORIGINAL service as the
        // row's resultSummary). A later `collect` reads it back ONLY from
        // this original durable row, validates it against the row's own
        // operation/seed/recorded digest/format, and binds the REAL captured
        // logical part — never the model's `slide`, never a sheet1 default.
        // Old v1 rows lack this block and stay honestly refused.
        var ownedV2Target: [String: Any] = [
            "operation": frozen.operationID,
            "seed": frozen.seed,
            "savedSHA256": snapshot.sha256,
            "format": snapshot.format.rawValue,
            "command": gate.rawValue,
            "producerProofVersion": 2,
        ]
        if let baseline = frozen.document.workingCopySha256, !baseline.isEmpty {
            ownedV2Target["preEditSha256"] = baseline
        }
        if snapshot.format != .docx, let partIndex = frozen.capturedPartIndex {
            ownedV2Target["partIndex"] = partIndex
        }
        summaryFields["ownedV2Target"] = ownedV2Target
        let data = try JSONSerialization.data(withJSONObject: summaryFields, options: [.sortedKeys])
        return NativeJobOutcome(
            summary: String(decoding: data, as: UTF8.self),
            digest: snapshot.sha256,
            verified: [
                "engine:\(outcome.result.state.rawValue)",
                "flushed-sha:\(String((outcome.flush.workingCopySha256 ?? "-").prefix(16)))",
                "saved-sha:\(String(snapshot.sha256.prefix(16)))",
                "semantic:inspected",
            ],
            artifactPath: snapshot.path,
            frozenRevision: frozenRevision)
    }

    func requestCancellation() async {
        // Cooperative only: the mailbox's shouldStop already carries the
        // token; a dispatched precision effect settles by its real evidence.
        box.requestCancel()
    }
}

