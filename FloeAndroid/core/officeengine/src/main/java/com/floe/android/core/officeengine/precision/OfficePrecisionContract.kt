// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import com.floe.android.core.officeengine.OfficeDocumentFormat
import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy

/**
 * Public typed contract for the fenced Office precision surface (G05-R2
 * P-A). This is the ONLY caller-visible shape: structured allowlisted
 * operations with typed parameters. Raw wire commands, UNO names, key/mouse
 * events, body strings and file paths are NEVER accepted from callers,
 * model output or document content — the internal translation lives in
 * [OfficePrecisionProtocol] and only the engine builds wire messages.
 *
 * Completion semantics (Main contract 2026-10-26 + Main early API review
 * 2026-10-27): an answering frame alone is NOT a successful mutation, and a
 * position readback proves ONLY position. Terminal states distinguish
 * exactly:
 *  - [OfficePrecisionState.ADMITTED]        — synchronous acknowledgement
 *    only ("accepted for processing"); NEVER a result.
 *  - [OfficePrecisionState.QUERY_OBSERVED]  — a real producer answer frame
 *    was observed for this exact armed operation (typed read result).
 *  - [OfficePrecisionState.NATIVE_COMPLETED] — the producer's OWN completion
 *    evidence arrived (e.g. `pasteresult: success`) and every mandatory
 *    positional readback agreed, but the desired CONTENT postcondition is
 *    not (yet) confirmed by a real producer readback. Downstream tool
 *    success MUST wait for the later owned flush/export byte verification
 *    (the existing WORKING_COPY_FLUSH/STAGED_EXPORT receipts) — this state
 *    alone never means "cell/text/formula content verified".
 *  - [OfficePrecisionState.MUTATION_VERIFIED] — NATIVE_COMPLETED plus a real
 *    producer content readback that MATCHED the intended text exactly
 *    ([OfficePrecisionContentReadback.MATCHED]), or, for selection/
 *    navigation effects, the producer's own postcondition echo (setpart /
 *    selection effect frame). Never derived from a void call, an ADMITTED
 *    ack, ModifiedStatus alone, or an arbitrary success string.
 *  - [OfficePrecisionState.REJECTED]        — refused before any effect
 *    (fence/gate/target/size/unsupported/content-safety).
 *  - [OfficePrecisionState.FAILED]          — the producer answered a
 *    failure/refusal for this operation, or a mandatory readback disagreed
 *    (effect did not happen or hit the wrong target).
 *  - [OfficePrecisionState.UNKNOWN]         — no proof arrived (timeout,
 *    mount end, stale-answer quarantine). Effects may have happened; data
 *    is retained, nothing is auto-undone, and no new conflicting mutation
 *    is admitted for the quarantined frame kind until a barrier re-arms it.
 *
 * Content identity honesty (Main early API review 2026-10-27): re-hashing
 * the working-copy FILE alone misses unsaved in-memory native edits — the
 * file changes only on flush. [OfficePrecisionTarget] therefore keeps the
 * ORIGINAL-SOURCE base (sourceId/sourceRevision, for future workspace CAS)
 * separate from the CURRENT working identity: flushed-file digest + manual
 * input epoch + precision edit epoch + observed ModifiedStatus. Coherent
 * byte identity of the CURRENT native content exists only after the owned
 * flush (FLUSHED receipt re-reads the file) or a staged export; captures
 * never claim it.
 */

/** Effect class of one action — drives lease, in-flight and CAS rules. */
enum class OfficePrecisionEffect {
    /** Read-only producer query; still serialized (kit replies lack request ids). */
    QUERY,

    /** Changes the current selection only (no document bytes). */
    SELECTION,

    /** Changes which part/slide/sheet is shown (no document bytes). */
    NAVIGATION,

    /** Changes document content (target handle CAS required). */
    CONTENT,
}

/**
 * Typed intent for cell content (Main early API review 2026-10-27): the
 * producer parses pasted text exactly as if typed, so the caller MUST state
 * whether the text is a literal value or a formula — a leading `=` in a
 * LITERAL is refused (it would silently become a formula) and a FORMULA
 * without a leading `=` is refused.
 */
enum class OfficePrecisionContentKind {
    LITERAL,
    FORMULA,
}

/** Outcome of the optional real producer content readback after a mutation. */
enum class OfficePrecisionContentReadback {
    /** No readback stage in this plan (e.g. formula intent — see below). */
    NOT_ATTEMPTED,

    /**
     * Formula intent: the producer answers with DISPLAY text (computed
     * value), never the formula source, so byte equality is not a
     * meaningful check — honestly not comparable, stays NATIVE_COMPLETED.
     */
    FORMULA_NOT_COMPARABLE,

    /** Readback text exactly equals the applied text. */
    MATCHED,

    /** Readback answered but differs (e.g. Calc display re-formatting). */
    MISMATCHED,

    /** Readback did not answer within its bounded soft window. */
    UNAVAILABLE,
}

/** The structured allowlisted operations the pinned producer really supports. */
enum class OfficePrecisionAction(
    val effect: OfficePrecisionEffect,
    /** Document families this action is available for (honest unavailability elsewhere). */
    val supportedFormats: Set<OfficeDocumentFormat>,
    /** True when a captured target handle must accompany the request (CAS). */
    val requiresTarget: Boolean,
) {
    /**
     * Captures the real current context and mints an engine-held target
     * handle: pulls the producer status (type/parts/selected part), re-reads
     * the CURRENT flushed working-copy file digest, and binds the session
     * generation + manual-input epoch + precision-effect epoch + observed
     * ModifiedStatus. The handle is opaque, engine-issued (unforgeable from
     * document/tool output), single-use for content mutations, bounded-lived,
     * and is invalidated by any manual page input, any flush, any remount
     * AND by any precision operation whose effect-bearing wire was actually
     * dispatched since the capture — including selection/navigation effects
     * and uncertain (UNKNOWN/maybe-effect) content attempts, whose context
     * moved even though the flushed file digest did not.
     */
    CAPTURE_TARGET(
        OfficePrecisionEffect.QUERY,
        setOf(OfficeDocumentFormat.DOCX, OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /** Typed document context readback (real `status:` answer frame). */
    QUERY_DOCUMENT_CONTEXT(
        OfficePrecisionEffect.QUERY,
        setOf(OfficeDocumentFormat.DOCX, OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /**
     * Reads the current text selection through the producer's own
     * `gettextselection` answer (`textselectioncontent:`). Works in all
     * three families (Writer text, Calc selected-cell display text, Impress
     * selected shape text). A selection ≥ 1 MiB is honestly
     * COMPLEX/unavailable, and an answer over
     * [OfficePrecisionProtocol.MAX_ANSWER_BYTES] is refused with its byte
     * count — never truncated.
     */
    QUERY_TEXT_SELECTION(
        OfficePrecisionEffect.QUERY,
        setOf(OfficeDocumentFormat.DOCX, OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /**
     * Calc cursor/range POSITION readback via the pinned `.uno:CellCursor`
     * pull. Proves position ONLY — never cell content.
     */
    QUERY_CELL_CURSOR(
        OfficePrecisionEffect.QUERY,
        setOf(OfficeDocumentFormat.XLSX),
        requiresTarget = false,
    ),

    /** Impress slide inventory via the pinned `getpresentationinfo` answer. */
    QUERY_PRESENTATION_INFO(
        OfficePrecisionEffect.QUERY,
        setOf(OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /**
     * Switches the shown slide/sheet (`setclientpart`). Completion is the
     * pinned-ordering-proven `status:` readback whose `selectedpart` equals
     * the requested part (the kit processes the earlier setclientpart before
     * answering the synchronous status pull); a gone/invalid part reads back
     * a different value and FAILS honestly. The callback-emitted `setpart:`
     * echo is corroboration only — a matching frame plus elapsed time is
     * never accepted as operation proof.
     */
    SELECT_SLIDE(
        OfficePrecisionEffect.NAVIGATION,
        setOf(OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /**
     * Selects all text (`.uno:SelectAll`). The pinned producer sends no
     * unocommandresult for it (not in the notify list) and its
     * TEXT_SELECTION callback carries no ordering proof, so the operation
     * verifies through the synchronous `gettextselection` readback that the
     * kit processes AFTER the select-all: a non-empty answer is a PARTIAL
     * postcondition (a selection exists; "all" is not separately provable
     * from the pinned surface) and terminates at NATIVE_COMPLETED — never
     * MUTATION_VERIFIED, and a missing readback within the bounded window
     * stays UNKNOWN.
     */
    SELECT_ALL_TEXT(
        OfficePrecisionEffect.SELECTION,
        setOf(OfficeDocumentFormat.DOCX, OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = false,
    ),

    /**
     * Inserts/replaces text through the pinned mobile paste protocol
     * (`paste mimetype=text/plain;charset=utf-8` + base64 payload): replaces
     * the current selection or inserts at the cursor. Producer completion
     * evidence is its own `pasteresult: success` frame; `fallback` is an
     * honest FAILED. A soft real readback (gettextselection) then attempts
     * to confirm the content postcondition: exact match upgrades to
     * MUTATION_VERIFIED, anything else stays NATIVE_COMPLETED (pending the
     * owned flush/export byte verification). Requires a captured target
     * handle (CAS against manual edits, flushes, remounts and prior
     * mutations since capture). On spreadsheets the text MUST be
     * single-cell-safe (no tab/CR/LF — a multi-cell TSV spread is refused,
     * never silently applied).
     */
    APPLY_TEXT(
        OfficePrecisionEffect.CONTENT,
        setOf(OfficeDocumentFormat.DOCX, OfficeDocumentFormat.XLSX, OfficeDocumentFormat.PPTX),
        requiresTarget = true,
    ),

    /**
     * Sets ONE Calc cell's content. Internal sequence: `.uno:GoToCell` (no
     * ack frame in the pinned producer) → mandatory semantic POSITION
     * readback via the `.uno:CellCursor` pull (cursor MUST be at the
     * requested cell before any effect, else FAILED) → paste
     * (`pasteresult:` producer completion) → confirming position readback →
     * soft CONTENT readback for LITERAL intent (exact match upgrades to
     * MUTATION_VERIFIED; Calc display re-formatting stays honestly
     * NATIVE_COMPLETED). FORMULA intent is never string-compared against
     * display text (FORMULA_NOT_COMPARABLE → NATIVE_COMPLETED; formula
     * bytes land in the working copy and are provable only through the
     * owned flush/export verification). Content MUST be single-cell-safe
     * (no tab/CR/LF). Requires a captured target handle.
     */
    SET_CELL_CONTENT(
        OfficePrecisionEffect.CONTENT,
        setOf(OfficeDocumentFormat.XLSX),
        requiresTarget = true,
    ),
}

/** Path-free failure/refusal codes (UI-localizable; no paths, no content). */
enum class OfficePrecisionFailure {
    /** Shape/validation problem in the typed request itself. */
    INVALID_REQUEST,

    /** Content is unsafe for the requested single-cell effect (tab/CR/LF or intent mismatch). */
    CONTENT_UNSAFE,

    /** Action not supported for this document family (honest unavailability). */
    UNSUPPORTED_ACTION,

    /** Owner context disagrees with the engine-owned mount identity. */
    OWNER_MISMATCH,

    /** Token/generation/mount fence did not match a live mount. */
    SESSION_MISMATCH,

    /** Mount is closing/closed or the process is in recovery. */
    SESSION_ENDING,

    /** Mutation requires READY_EDITABLE + full native edit witnesses. */
    NOT_EDITABLE,

    /** Another precision operation is in flight (one per native session). */
    MUTATION_IN_FLIGHT,

    /** A save flush/export holds the native session. */
    SAVE_IN_FLIGHT,

    /** The bounded pending queue is full (refused, never dropped silently). */
    QUEUE_FULL,

    /** Request exceeded [OfficePrecisionProtocol.MAX_REQUEST_BYTES]. */
    REQUEST_TOO_LARGE,

    /** Answer exceeded [OfficePrecisionProtocol.MAX_ANSWER_BYTES] (count kept). */
    ANSWER_TOO_LARGE,

    /** The captured target handle is unknown/expired/consumed to this engine. */
    TARGET_UNKNOWN,

    /**
     * The captured target no longer matches reality (manual page input,
     * working-copy flush, remount or a verified mutation since capture):
     * apply conflict, no effect was attempted.
     */
    APPLY_CONFLICT,

    /** The producer refused/failed this exact command (error:/fallback). */
    PRODUCER_REJECTED,

    /** A mandatory semantic readback disagreed with the requested target. */
    TARGET_UNVERIFIED,

    /** Selection too large/complex for a typed answer (complexselection:). */
    COMPLEX_SELECTION_UNAVAILABLE,

    /** The wire dispatch itself failed (nothing reached the kit). */
    TRANSPORT,

    /** No proof within the bounded window; effects stay uncertain. */
    TIMEOUT,

    /** A previous answer went missing; quarantine refused this operation. */
    STALE_ANSWER_QUARANTINE,

    /** Engine-internal fault (never fabricated success). */
    INTERNAL,
}

/** Terminal (and one synchronous acknowledgement) states of one operation. */
enum class OfficePrecisionState {
    /** Synchronous ack ONLY — accepted for processing; never a result. */
    ADMITTED,
    QUERY_OBSERVED,

    /**
     * Producer-side completion evidence arrived for a dispatched effect and
     * every mandatory positional readback agreed, but the FULL postcondition
     * is not (yet) confirmed by pinned-ordering-proven readback:
     *  - CONTENT mutations: the desired cell/text/formula content awaits the
     *    owned flush/export byte verification (or the soft content readback
     *    did not match exactly — e.g. Calc display re-formatting);
     *  - SELECTION effects: the non-empty selection readback is a PARTIAL
     *    postcondition only.
     * Downstream tool success MUST NOT be claimed from this state alone for
     * content effects — it requires the later owned flush/export receipts.
     */
    NATIVE_COMPLETED,
    MUTATION_VERIFIED,
    REJECTED,
    FAILED,
    UNKNOWN,
}

/**
 * One typed precision request. Constructed by the trusted App/runtime from
 * ITS OWN owned context (task/workspace identity, session token, mount
 * generation). Field rules:
 *  - [opId]: caller-minted, unique per operation, `^[A-Za-z0-9_-]{1,64}$`
 *    (same discipline as the save surface). A repeated opId is refused.
 *  - [sessionToken]/[generation]: the exact live mount identity (the App
 *    acquires the generation through the existing readGeneration seam).
 *  - [text]: content parameter for APPLY_TEXT / SET_CELL_CONTENT only.
 *  - [contentKind]: required for SET_CELL_CONTENT (literal vs formula
 *    intent); ignored elsewhere.
 *  - [cellAddress]: A1 reference for SET_CELL_CONTENT only (current sheet).
 *  - [partId]: decimal part id for SELECT_SLIDE only.
 *  - [targetHandle]: engine-issued handle from CAPTURE_TARGET; REQUIRED for
 *    content mutations, ignored elsewhere.
 *  - [ownerTaskId]/[workspaceId]: optional echoes of the mount's own owner
 *    context; when both sides carry a value they MUST agree (the engine
 *    never trusts the caller over its own mount record).
 */
data class OfficePrecisionRequest(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val action: OfficePrecisionAction,
    val text: String? = null,
    val contentKind: OfficePrecisionContentKind? = null,
    val cellAddress: String? = null,
    val partId: String? = null,
    val targetHandle: String? = null,
    val ownerTaskId: String? = null,
    val workspaceId: String? = null,
) {
    companion object {
        /**
         * Pure format-independent shape validation (fail-closed, path-free
         * reasons). Identity rules REUSE the module's existing handoff policy
         * (single source of truth). Wire translation happens ONLY inside the
         * engine after admission.
         */
        fun validate(request: OfficePrecisionRequest): OfficePrecisionFailure? {
            if (!OfficeHostSaveHandoffPolicy.validOpId(request.opId)) {
                return OfficePrecisionFailure.INVALID_REQUEST
            }
            if (request.generation < 1L) return OfficePrecisionFailure.INVALID_REQUEST
            if (!OfficeHostSaveHandoffPolicy.validToken(request.sessionToken)) {
                return OfficePrecisionFailure.INVALID_REQUEST
            }
            if (request.text != null) {
                if (request.text.isEmpty() || request.text.contains('\u0000')) {
                    return OfficePrecisionFailure.INVALID_REQUEST
                }
                if (request.text.toByteArray(Charsets.UTF_8).size > OfficePrecisionProtocol.MAX_TEXT_BYTES) {
                    return OfficePrecisionFailure.REQUEST_TOO_LARGE
                }
            }
            when (request.action) {
                OfficePrecisionAction.SET_CELL_CONTENT -> {
                    if (!OfficePrecisionProtocol.isValidCellAddress(request.cellAddress)) {
                        return OfficePrecisionFailure.INVALID_REQUEST
                    }
                    val text = request.text ?: return OfficePrecisionFailure.INVALID_REQUEST
                    val kind = request.contentKind
                        ?: return OfficePrecisionFailure.INVALID_REQUEST
                    // Single-cell safety: a tab/CR/LF would silently become a
                    // MULTI-CELL TSV paste — refused, never applied.
                    if (text.any { it == '\t' || it == '\n' || it == '\r' }) {
                        return OfficePrecisionFailure.CONTENT_UNSAFE
                    }
                    when (kind) {
                        // A literal starting with '=' would be parsed by the
                        // producer as a formula: intent mismatch, refused.
                        OfficePrecisionContentKind.LITERAL ->
                            if (text.startsWith("=")) return OfficePrecisionFailure.CONTENT_UNSAFE
                        OfficePrecisionContentKind.FORMULA ->
                            if (!text.startsWith("=")) return OfficePrecisionFailure.CONTENT_UNSAFE
                    }
                }
                OfficePrecisionAction.APPLY_TEXT ->
                    if (request.text == null) return OfficePrecisionFailure.INVALID_REQUEST
                OfficePrecisionAction.SELECT_SLIDE ->
                    if (!OfficePrecisionProtocol.isValidPartId(request.partId)) {
                        return OfficePrecisionFailure.INVALID_REQUEST
                    }
                else -> Unit
            }
            if (request.action.requiresTarget && request.targetHandle.isNullOrEmpty()) {
                return OfficePrecisionFailure.TARGET_UNKNOWN
            }
            if (request.targetHandle != null &&
                !request.targetHandle.matches(Regex("^[0-9a-f]{32}$"))
            ) {
                return OfficePrecisionFailure.INVALID_REQUEST
            }
            return null
        }

        /**
         * Family-specific validation with the mount's real format (the
         * engine supplies it from its OWN mount record, never from the
         * caller). Spreadsheet text effects must be single-cell-safe: the
         * pinned producer's paste is real clipboard semantics, so a
         * tab/newline spread across cells is refused instead of silently
         * applied.
         */
        fun validateForFormat(
            request: OfficePrecisionRequest,
            format: OfficeDocumentFormat,
        ): OfficePrecisionFailure? {
            if (format !in request.action.supportedFormats) {
                return OfficePrecisionFailure.UNSUPPORTED_ACTION
            }
            if (format == OfficeDocumentFormat.XLSX && request.text != null &&
                (request.action == OfficePrecisionAction.APPLY_TEXT ||
                    request.action == OfficePrecisionAction.SET_CELL_CONTENT) &&
                request.text.any { it == '\t' || it == '\n' || it == '\r' }
            ) {
                return OfficePrecisionFailure.CONTENT_UNSAFE
            }
            return null
        }
    }
}

/**
 * The engine-minted target context returned by CAPTURE_TARGET.
 *
 * Distinguishes the ORIGINAL-SOURCE identity ([sourceId]/[sourceRevision]/
 * [sourceLogicalPath], carried unchanged from the mount request — the base
 * for future workspace CAS) from the CURRENT WORKING identity. The current
 * identity is COHERENT, not a single hash: [workingCopySha256]/
 * [workingCopyBytes] are the real re-read digest of the mutable working-copy
 * FILE (its last flushed bytes — an unflushed file does not reflect
 * in-memory native edits), while [inputEpoch] (manual page input),
 * [editEpoch] (verified precision mutations) and [documentModified] (last
 * observed `.uno:ModifiedStatus`, corroborating only) track in-memory
 * divergence since. Byte-exact identity of the CURRENT native content
 * exists only after the owned flush (the existing FLUSHED receipt re-reads
 * the file) or a staged export — a capture never claims it.
 */
data class OfficePrecisionTarget(
    /** Opaque engine-issued handle id (the only value needed to apply). */
    val handleId: String,
    /** Native mount generation this capture belongs to. */
    val generation: Long,
    /** Original-source facts echoed from the mount request (null for local-only previews). */
    val sourceId: String?,
    val sourceRevision: String?,
    val sourceLogicalPath: String?,
    val workspaceId: String?,
    val ownerTaskId: String?,
    /** CURRENT flushed-file identity of the working copy (real re-read at capture). */
    val workingCopySha256: String?,
    val workingCopyBytes: Long,
    /** In-memory divergence counters bound at capture (see class KDoc). */
    val inputEpoch: Long,
    val editEpoch: Long,
    val documentModified: Boolean?,
    /** Producer-observed document context at capture time. */
    val docType: String?,
    val partsCount: Int?,
    val selectedPart: String?,
    /** Capture ordering facts (elapsedRealtime). */
    val capturedAtElapsedMs: Long,
    /** Handle lifetime bound (elapsedRealtime); expired handles are refused. */
    val expiresAtElapsedMs: Long,
)

/** Typed answer payload of one QUERY_OBSERVED / NATIVE_COMPLETED / MUTATION_VERIFIED result. */
sealed class OfficePrecisionAnswer {
    /** CAPTURE_TARGET: the minted target context (handle + dual revision). */
    data class TargetCaptured(val target: OfficePrecisionTarget) : OfficePrecisionAnswer()

    /** QUERY_DOCUMENT_CONTEXT: real `status:` facts. */
    data class DocumentContext(
        val docType: String?,
        val partsCount: Int?,
        val selectedPart: String?,
        val widthTwip: Int?,
        val heightTwip: Int?,
        val viewId: Int?,
        val readOnly: Boolean?,
        /** Corroborating observed fact: last seen `.uno:ModifiedStatus` (null until first frame). */
        val documentModified: Boolean?,
    ) : OfficePrecisionAnswer()

    /** QUERY_TEXT_SELECTION: the producer's own selection content answer. */
    data class TextSelection(
        val text: String,
        val byteCount: Int,
        val multiFormatJson: Boolean,
    ) : OfficePrecisionAnswer()

    /** QUERY_CELL_CURSOR: typed Calc cursor POSITION facts (null cursor = EMPTY). Position only — never content. */
    data class CellCursor(
        val column: Int?,
        val row: Int?,
        val xTwip: Int?,
        val yTwip: Int?,
        val widthTwip: Int?,
        val heightTwip: Int?,
        val empty: Boolean,
    ) : OfficePrecisionAnswer()

    /** QUERY_PRESENTATION_INFO: bounded slide-inventory facts. */
    data class PresentationInfo(
        val byteCount: Int,
        val slideCount: Int?,
    ) : OfficePrecisionAnswer()

    /** SELECT_SLIDE: navigation postcondition proven by the `status:` readback. */
    data class SlideSelected(val shownPart: String) : OfficePrecisionAnswer()

    /**
     * SELECT_ALL_TEXT: byte count of the non-empty selection readback
     * observed after the dispatched select-all (partial postcondition;
     * content itself is not carried by this answer).
     */
    data class TextSelected(val effectPayloadBytes: Int) : OfficePrecisionAnswer()

    /**
     * APPLY_TEXT / SET_CELL_CONTENT receipt. [contentReadback] states
     * exactly how far content verification got; NATIVE_COMPLETED results
     * carry anything other than MATCHED and REQUIRE the later owned
     * flush/export byte verification before any tool-success claim.
     */
    data class MutationApplied(
        /** Ordered step attestations (producer evidence, path-free, content-free). */
        val steps: List<String>,
        val pastedBytes: Int,
        val contentReadback: OfficePrecisionContentReadback,
        /** Flushed-file identity at apply time (in-memory edit; file changes on flush only). */
        val workingCopySha256: String?,
        /** The consumed target handle (single-use CAS). */
        val consumedTargetHandle: String?,
    ) : OfficePrecisionAnswer()
}

/**
 * Terminal (or synchronous ADMITTED) result of one operation. Content is
 * returned ONLY here, to the authorized same-UID owner through the fenced
 * binder — never written to logs/diagnostics (which carry operation/type/
 * state/byte-count/hash summaries only).
 */
data class OfficePrecisionResult(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val action: OfficePrecisionAction,
    val state: OfficePrecisionState,
    val failure: OfficePrecisionFailure?,
    /** Path-free, content-free detail token (failure codes stay UI-localizable). */
    val detail: String?,
    val answer: OfficePrecisionAnswer?,
    /** Evidence lineage: which producer frames/attestations settled this op. */
    val attestation: String,
    val submittedAtElapsedMs: Long,
    val completedAtElapsedMs: Long,
) {
    /** Bounded diagnostic line: identity-safe summary only (never content). */
    fun descriptorLine(): String =
        "precision op=$opId ${action.name} -> ${state.name}" +
            (failure?.let { " ($it)" } ?: "")
}
