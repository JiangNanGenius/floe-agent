// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

/**
 * Pure operation plans: the internal translation of one typed allowlisted
 * [OfficePrecisionAction] into the ordered pinned-producer wire steps and
 * their honest completion expectations. Nothing here is caller-visible;
 * callers can never inject wire commands, UNO names, key/mouse events or
 * message bodies (Main contract 2026-10-26: structured allowlisted
 * operations translate internally).
 *
 * Completion evidence per step is the producer's OWN answering frame —
 * never a void call, a ModifiedStatus flag, an arbitrary success string or
 * the mere absence of an error. Steps whose pinned producer command has no
 * ack frame (`.uno:GoToCell`, `.uno:SelectAll` — neither is in the
 * unocommandresult notify list, ChildSession.cpp unoCommand :3481-3494) are
 * completed by a real SEMANTIC READBACK step (the `.uno:CellCursor` pull /
 * the TEXT_SELECTION effect frame), and a missing readback within the
 * bounded window stays UNKNOWN.
 *
 * Step classes (Main early API review 2026-10-27):
 *  - MANDATORY steps gate the effect and its positional truth: a failure or
 *    timeout there is a real FAILED/UNKNOWN.
 *  - The SOFT content-readback stage runs only AFTER the producer's own
 *    completion evidence arrived. Exact match upgrades MUTATION_VERIFIED;
 *    an explicit comparable mismatch is positive conflicting evidence and
 *    terminates UNKNOWN (maybe-effect, retained, never replayed). Missing,
 *    oversize, multiformat or otherwise unavailable readback remains
 *    inconclusive NATIVE_COMPLETED pending owned flush/export verification.
 */
internal object OfficePrecisionPlan {

    /**
     * What native evidence a step waits for (null = fire-and-forget step).
     *
     * [barrierProven] marks whether the producer's reply for this kind is
     * emitted SYNCHRONOUSLY inside the command's own kit input handler
     * (pinned proof: single KitPoll thread → session->handleMessage,
     * kit/Kit.cpp:2626; ChildSession::_handleInput answers inline via
     * sendTextFrame — getCommandValues :1396/:1413/:1418, getTextSelection
     * :1882/:1901/:1912, paste :2154-2157, getStatus, getPresentationInfo
     * :4565). Only such kinds may be re-armed by the ordered `.uno:ReadOnly`
     * barrier after a missed answer. Kinds emitted from core CALLBACKS
     * (`setpart:` SET_PART :5075-5085, `textselection:` TEXT_SELECTION
     * :4998-5000) have no byte-level callback-ordering proof from the
     * pinned wsd/kit sources alone: their quarantine is permanent for the
     * mount incarnation (Main early review 2026-10-27).
     */
    sealed class Expectation {
        /** Key used for stale-answer quarantine bookkeeping. */
        abstract val key: String

        /** True when the ordered barrier may re-arm this kind (see KDoc). */
        abstract val barrierProven: Boolean

        /** `status: {json}` (exact prefix — NOT statusupdate/partstatus). */
        object StatusAnswer : Expectation() {
            override val key = "status"
            override val barrierProven = true
        }

        /** `commandvalues:` whose parsed commandName equals [commandName]. */
        data class CommandValues(val commandName: String) : Expectation() {
            override val key: String get() = "commandvalues:$commandName"
            override val barrierProven = true
        }

        /** `textselectioncontent:` (either pinned framing) / `complexselection:`. */
        object TextSelectionContent : Expectation() {
            override val key = "textselectioncontent"
            override val barrierProven = true
        }

        /** `presentationinfo: {json}`. */
        object PresentationInfoAnswer : Expectation() {
            override val key = "presentationinfo"
            override val barrierProven = true
        }

        /** `pasteresult: success|fallback`. */
        object PasteResult : Expectation() {
            override val key = "pasteresult"
            override val barrierProven = true
        }

        /** The ordered `.uno:ReadOnly` barrier reply (drains stale frames). */
        object BarrierReply : Expectation() {
            override val key = "barrier"
            override val barrierProven = true
        }

        // NOTE (Main final target-safety review 2026-10-27): the callback-
        // emitted frames `setpart:` (SET_PART) and `textselection:`
        // (TEXT_SELECTION) are deliberately NOT expectations. A matching
        // frame plus elapsed time is never accepted as operation proof —
        // their emission ordering vs. the barrier is not byte-provable from
        // the pinned wsd/kit sources. Navigation/selection effects are
        // verified through the proven synchronous readbacks below instead
        // (`status:` selectedpart / `gettextselection` content); the
        // callback frames remain observed-and-counted corroboration only.
        // The ledger's unproven-kind quarantine machinery stays for any
        // future callback-emitted expectation (barrierProven = false),
        // where a missed answer is permanent for the mount incarnation.
    }

    /** Pure per-step completion rule applied to the matched answer frame. */
    sealed class StepCheck {
        /** The matching frame itself is the answer (queries). */
        object Accept : StepCheck()

        /** `pasteresult: success` required; `fallback` fails honestly. */
        object PasteSuccess : StepCheck()

        /** The `.uno:CellCursor` readback must show exactly this cell (POSITION only). */
        data class CursorAt(val column: Int, val row: Int) : StepCheck()

        /**
         * Resolves — BEFORE any navigation wire is dispatched — the
         * producer's OWN part identifier for the requested 0-based logical
         * part index, from this run's synchronous `status:` answer.
         *
         * Pinned facts (revision 2333344185931274f9c49d6c12a408cefcef6844):
         * presentation/drawing page identifiers are the braced page GUID
         * carried as each `parts` entry's `part` (kit/KitHelper.hpp
         * documentStatus emits the core `getPart()` string as
         * `selectedpart`; browser/src/layer/tile/ImpressTileLayer.js names
         * the same rule), and the Impress boundary resolves ONLY that GUID —
         * a decimal index names no page, so the C15 decimal `setclientpart`
         * silently selected nothing and the honest `status:` readback could
         * never match it (the real first failure). Spreadsheet and text
         * documents keep the documented decimal-index identifier, so their
         * wire and readback stay byte-identical to the proven pre-repair
         * behaviour. Nothing is normalised or invented: whatever this
         * status does not itself carry at that index is a fail-closed
         * refusal BEFORE any effect is dispatched.
         */
        data class StatusResolvePartIndex(val partIndex: Int) : StepCheck()

        /**
         * The `status:` readback's `selectedpart` must equal the identifier
         * THIS run resolved through [StatusResolvePartIndex] — the
         * pinned-ordering-proven navigation postcondition (the kit
         * processes the earlier `setclientpart` before answering this
         * synchronous pull, so the reported part is the real post-command
         * state; the `setpart:` callback echo is corroboration only).
         */
        object StatusSelectedPartMatchesResolved : StepCheck()

        /**
         * Dispatch-only marker for the fire-and-forget
         * `setclientpart part=<resolved>` step: the ledger materializes the
         * wire from THIS run's producer-resolved identifier
         * ([OfficePrecisionLedger.wireForDispatch]) and never from a
         * caller-supplied or stale value; an unresolved run dispatches no
         * wire at all. This check never settles on a frame (the step has
         * [Expectation] null).
         */
        object SendResolvedPartWire : StepCheck()

        /**
         * BEFORE content: the current native part must still equal the
         * consumed capture's part BYTE-EXACTLY (identity) and, for
         * presentation/drawing, the SAME GUID must still sit at the
         * captured witnessed logical ordinal in this fresh synchronous
         * status answer's own complete, closed, count-consistent ordered
         * parts witness — a reordered deck refuses BEFORE the selection
         * pull and before any paste/commit wire (pre-ordinal84 this gate
         * was identity-only, so a same-GUID reorder could pass here and
         * only surface as an avoidable saved-verification failure after
         * the effect). This is a fresh synchronous read, not a cached
         * fact; the documented decimal families' identifier IS their
         * ordinal, so the identity comparison already proves position
         * there and their behaviour stays byte-identical.
         */
        object PreEffectTargetStatus : StepCheck()

        /** BEFORE content: retain this op's real current selection. Empty is
         * valid insertion evidence. Calc accepts only unambiguous single-cell
         * plain text; TSV/newline/multi-MIME evidence refuses before paste. */
        data class PreEffectSelectionContent(val singleCellPlainText: Boolean) : StepCheck()

        /**
         * The post-SelectAll `gettextselection` readback must answer with a
         * NON-EMPTY selection (the real byte count alone suffices; content
         * is only carried within the answer budget). Proves a selection
         * exists after the dispatched command — a PARTIAL postcondition, so
         * the operation terminates honestly at NATIVE_COMPLETED, never
         * MUTATION_VERIFIED and never from a delayed callback frame.
         */
        object NonEmptySelectionContent : StepCheck()

        /**
         * SOFT content postcondition: exact match upgrades MUTATION_VERIFIED;
         * an explicit comparable mismatch terminates UNKNOWN with the effect
         * uncertain. Unavailable/unsupported readback stays NATIVE_COMPLETED.
         */
        object AppliedTextReadback : StepCheck()
    }

    data class Step(
        /** Identity-safe attestation token (path-free, content-free). */
        val name: String,
        /**
         * Exact wire message (built from validated typed parameters only),
         * or for [StepCheck.SendResolvedPartWire] just the pinned command
         * head: the engine materializes the full frame at dispatch time via
         * [OfficePrecisionLedger.wireForDispatch] from THIS run's
         * producer-resolved identifier (never from a caller value).
         */
        val wire: String,
        /** Expected producer evidence; null = completes on successful send. */
        val expect: Expectation?,
        val check: StepCheck,
        val timeoutMs: Long,
        /**
         * Soft stages run after producer completion evidence. Explicit
         * conflicting content is UNKNOWN; unavailable evidence only limits
         * verification and does not fabricate a mismatch.
         */
        val soft: Boolean = false,
    )

    /** Query pull window (local kit answers promptly; bounded and honest). */
    const val QUERY_TIMEOUT_MS = 15_000L

    /** Mutation step window (mirrors the proven save-ack bound). */
    const val MUTATION_TIMEOUT_MS = 30_000L

    /** Mandatory BEFORE-evidence pulls are synchronous local kit reads too,
     * but use a short window so the expanded Calc ladder stays inside the
     * existing 90 s client / 110 s host / 120 s mailbox outer budgets. */
    const val PRE_EFFECT_QUERY_TIMEOUT_MS = 5_000L

    /** Soft readback window (short: the answer is local and prompt or absent). */
    const val SOFT_READBACK_TIMEOUT_MS = 10_000L

    /**
     * Builds the ordered plan for one validated request. Returns null when
     * the typed parameters cannot be translated into a pinned wire command
     * (honest refusal; never a partial/guessed command).
     */
    fun forRequest(request: OfficePrecisionRequest): List<Step>? {
        return when (request.action) {
        OfficePrecisionAction.CAPTURE_TARGET,
        OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT,
        -> listOf(
            Step(
                name = "status-pull",
                wire = OfficePrecisionProtocol.CMD_STATUS,
                expect = Expectation.StatusAnswer,
                check = StepCheck.Accept,
                timeoutMs = QUERY_TIMEOUT_MS,
            ),
        )

        OfficePrecisionAction.QUERY_TEXT_SELECTION -> listOf(
            Step(
                name = "text-selection-pull",
                wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                expect = Expectation.TextSelectionContent,
                check = StepCheck.Accept,
                timeoutMs = QUERY_TIMEOUT_MS,
            ),
        )

        OfficePrecisionAction.QUERY_CELL_CURSOR -> listOf(
            Step(
                name = "cell-cursor-pull",
                wire = OfficePrecisionProtocol.CMD_CELL_CURSOR_VALUES,
                expect = Expectation.CommandValues(OfficePrecisionProtocol.CELL_CURSOR_COMMAND_NAME),
                check = StepCheck.Accept,
                timeoutMs = QUERY_TIMEOUT_MS,
            ),
        )

        OfficePrecisionAction.QUERY_PRESENTATION_INFO -> listOf(
            Step(
                name = "presentation-info-pull",
                wire = OfficePrecisionProtocol.CMD_PRESENTATION_INFO,
                expect = Expectation.PresentationInfoAnswer,
                check = StepCheck.Accept,
                timeoutMs = QUERY_TIMEOUT_MS,
            ),
        )

        OfficePrecisionAction.SELECT_SLIDE -> {
            val requested = request.partId ?: return null
            if (!OfficePrecisionProtocol.isValidPartId(requested)) return null
            val partIndex = requested.toIntOrNull() ?: return null
            listOf(
                // Resolve the producer's OWN part identifier for the
                // requested logical index BEFORE any effect is dispatched:
                // presentation/drawing pages are named by their braced GUID
                // carried in the synchronous `status:` witness's `parts`
                // entries, and the Impress boundary resolves only that GUID
                // — the C15 decimal wire named no page, silently selected
                // nothing, and the honest readback could never match it.
                // Other families keep their documented decimal identifier,
                // byte-identical to the proven pre-repair wire.
                Step(
                    name = "part-index-resolve",
                    wire = OfficePrecisionProtocol.CMD_STATUS,
                    expect = Expectation.StatusAnswer,
                    check = StepCheck.StatusResolvePartIndex(partIndex),
                    timeoutMs = QUERY_TIMEOUT_MS,
                ),
                // Fire-and-forget: the pinned producer answers setclientpart
                // only through the callback-emitted `setpart:` echo, which
                // carries no ordering proof — so the dispatch is followed by
                // a synchronous `status:` pull whose `selectedpart` is the
                // PROVEN postcondition (kit input is processed serially:
                // getStatus runs after setClientPart). The full frame is
                // built at dispatch time from the identifier THIS run
                // resolved (OfficePrecisionLedger.wireForDispatch); only the
                // command head is carried here for error correlation.
                Step(
                    name = "select-part",
                    wire = "setclientpart part=",
                    expect = null,
                    check = StepCheck.SendResolvedPartWire,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
                Step(
                    name = "part-readback",
                    wire = OfficePrecisionProtocol.CMD_STATUS,
                    expect = Expectation.StatusAnswer,
                    check = StepCheck.StatusSelectedPartMatchesResolved,
                    timeoutMs = QUERY_TIMEOUT_MS,
                ),
            )
        }

        OfficePrecisionAction.SELECT_ALL_TEXT -> listOf(
            // `.uno:SelectAll` has no ack frame (not in the pinned notify
            // list) and its TEXT_SELECTION callback is not ordering-proven,
            // so completion evidence is the synchronous gettextselection
            // readback processed AFTER the select-all (serial kit input):
            // a non-empty answer proves a selection exists — a PARTIAL
            // postcondition that terminates at NATIVE_COMPLETED, never a
            // "verified select-all" claim.
            Step(
                name = "select-all",
                wire = OfficePrecisionProtocol.CMD_SELECT_ALL,
                expect = null,
                check = StepCheck.Accept,
                timeoutMs = MUTATION_TIMEOUT_MS,
            ),
            Step(
                name = "selection-readback",
                wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                expect = Expectation.TextSelectionContent,
                check = StepCheck.NonEmptySelectionContent,
                timeoutMs = QUERY_TIMEOUT_MS,
            ),
        )

        OfficePrecisionAction.APPLY_TEXT -> {
            val wire = OfficePrecisionProtocol.pasteText(request.text ?: return null)
                ?: return null
            listOf(
                // The ordinary selectSlide/selectAll flows do not themselves
                // prove a fresh pre-effect selection to the host. Acquire the
                // actual current part + selection INSIDE this fenced apply,
                // immediately before content dispatch, for every family.
                Step(
                    name = "pre-effect-part-readback",
                    wire = OfficePrecisionProtocol.CMD_STATUS,
                    expect = Expectation.StatusAnswer,
                    check = StepCheck.PreEffectTargetStatus,
                    timeoutMs = PRE_EFFECT_QUERY_TIMEOUT_MS,
                ),
                Step(
                    name = "pre-effect-selection-readback",
                    wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                    expect = Expectation.TextSelectionContent,
                    check = StepCheck.PreEffectSelectionContent(singleCellPlainText = false),
                    timeoutMs = PRE_EFFECT_QUERY_TIMEOUT_MS,
                ),
                Step(
                    name = "paste-text",
                    wire = wire,
                    expect = Expectation.PasteResult,
                    check = StepCheck.PasteSuccess,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
                // SOFT content postcondition: exact match verifies; an
                // explicit comparable conflict is UNKNOWN (maybe-effect),
                // while no-answer/unsupported evidence stays inconclusive.
                Step(
                    name = "content-readback",
                    wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                    expect = Expectation.TextSelectionContent,
                    check = StepCheck.AppliedTextReadback,
                    timeoutMs = SOFT_READBACK_TIMEOUT_MS,
                    soft = true,
                ),
            )
        }

        OfficePrecisionAction.SET_CELL_CONTENT -> {
            val address = request.cellAddress ?: return null
            val column = OfficePrecisionProtocol.cellAddressToColumn(address) ?: return null
            val row = OfficePrecisionProtocol.cellAddressToRow(address) ?: return null
            val goWire = OfficePrecisionProtocol.goToCell(address) ?: return null
            val pasteWire = OfficePrecisionProtocol.pasteText(request.text ?: return null)
                ?: return null
            val steps = ArrayList<Step>(7)
            // Navigation has NO ack frame in the pinned producer; the
            // semantic POSITION readback below is the real arrival evidence
            // and runs BEFORE any content effect (target validated first).
            steps.add(
                Step(
                    name = "goto-cell",
                    wire = goWire,
                    expect = null,
                    check = StepCheck.Accept,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
            )
            steps.add(
                Step(
                    name = "cursor-readback",
                    wire = OfficePrecisionProtocol.CMD_CELL_CURSOR_VALUES,
                    expect = Expectation.CommandValues(OfficePrecisionProtocol.CELL_CURSOR_COMMAND_NAME),
                    check = StepCheck.CursorAt(column, row),
                    timeoutMs = QUERY_TIMEOUT_MS,
                ),
            )
            // Only AFTER GoToCell and the exact cursor proof may the prior
            // value be acquired: an older A1/ambient selection can never be
            // attributed to the requested B2/B3/B4 target. The raw reply is
            // accepted only as unambiguous single-cell plain text (no guessed
            // TSV terminator/quote decoding); unsupported shapes stop here.
            steps.add(
                Step(
                    name = "pre-effect-part-readback",
                    wire = OfficePrecisionProtocol.CMD_STATUS,
                    expect = Expectation.StatusAnswer,
                    check = StepCheck.PreEffectTargetStatus,
                    timeoutMs = PRE_EFFECT_QUERY_TIMEOUT_MS,
                ),
            )
            steps.add(
                Step(
                    name = "pre-effect-selection-readback",
                    wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                    expect = Expectation.TextSelectionContent,
                    check = StepCheck.PreEffectSelectionContent(singleCellPlainText = true),
                    timeoutMs = PRE_EFFECT_QUERY_TIMEOUT_MS,
                ),
            )
            steps.add(
                Step(
                    name = "paste-cell",
                    wire = pasteWire,
                    expect = Expectation.PasteResult,
                    check = StepCheck.PasteSuccess,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
            )
            steps.add(
                Step(
                    name = "cursor-confirm",
                    wire = OfficePrecisionProtocol.CMD_CELL_CURSOR_VALUES,
                    expect = Expectation.CommandValues(OfficePrecisionProtocol.CELL_CURSOR_COMMAND_NAME),
                    check = StepCheck.CursorAt(column, row),
                    timeoutMs = QUERY_TIMEOUT_MS,
                ),
            )
            // Formula intent: the producer answers selection readbacks with
            // DISPLAY text (the computed value), never the formula source —
            // byte equality is not a meaningful check, so no readback stage
            // is dispatched and the op honestly terminates
            // NATIVE_COMPLETED / FORMULA_NOT_COMPARABLE.
            if (request.contentKind == OfficePrecisionContentKind.LITERAL) {
                steps.add(
                    Step(
                        name = "content-readback",
                        wire = OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                        expect = Expectation.TextSelectionContent,
                        check = StepCheck.AppliedTextReadback,
                        timeoutMs = SOFT_READBACK_TIMEOUT_MS,
                        soft = true,
                    ),
                )
            }
            steps
        }
        }
    }
}
