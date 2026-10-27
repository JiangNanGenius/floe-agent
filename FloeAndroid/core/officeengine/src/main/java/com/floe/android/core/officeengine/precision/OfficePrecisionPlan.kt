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
 *    completion evidence arrived; it can UPGRADE the terminal state to
 *    MUTATION_VERIFIED (exact content match) but can never fail the
 *    operation — a mismatch/absence honestly leaves it NATIVE_COMPLETED
 *    (pending the owned flush/export byte verification).
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
         * The `status:` readback's `selectedpart` must equal the requested
         * part — the pinned-ordering-proven navigation postcondition (the
         * kit processes the earlier `setclientpart` before answering this
         * synchronous pull, so the reported part is the real post-command
         * state; the `setpart:` callback echo is corroboration only).
         */
        data class StatusSelectedPartMatches(val partId: String) : StepCheck()

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
         * SOFT content postcondition: the readback selection text is
         * compared with the request's applied text. Exact match upgrades to
         * MUTATION_VERIFIED; anything else downgrades to NATIVE_COMPLETED —
         * it NEVER fails the completed mutation.
         */
        object AppliedTextReadback : StepCheck()
    }

    data class Step(
        /** Identity-safe attestation token (path-free, content-free). */
        val name: String,
        /** Exact wire message (built from validated typed parameters only). */
        val wire: String,
        /** Expected producer evidence; null = completes on successful send. */
        val expect: Expectation?,
        val check: StepCheck,
        val timeoutMs: Long,
        /**
         * Soft stages run only after producer completion evidence; their
         * failure/timeout downgrades verification instead of failing the op.
         */
        val soft: Boolean = false,
    )

    /** Query pull window (local kit answers promptly; bounded and honest). */
    const val QUERY_TIMEOUT_MS = 15_000L

    /** Mutation step window (mirrors the proven save-ack bound). */
    const val MUTATION_TIMEOUT_MS = 30_000L

    /** Soft readback window (short: the answer is local and prompt or absent). */
    const val SOFT_READBACK_TIMEOUT_MS = 10_000L

    /**
     * Builds the ordered plan for one validated request. Returns null when
     * the typed parameters cannot be translated into a pinned wire command
     * (honest refusal; never a partial/guessed command).
     */
    fun forRequest(request: OfficePrecisionRequest): List<Step>? = when (request.action) {
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
            val wire = OfficePrecisionProtocol.setClientPart(request.partId ?: return null)
                ?: return null
            listOf(
                // Fire-and-forget: the pinned producer answers setclientpart
                // only through the callback-emitted `setpart:` echo, which
                // carries no ordering proof — so the dispatch is followed by
                // a synchronous `status:` pull whose `selectedpart` is the
                // PROVEN postcondition (kit input is processed serially:
                // getStatus runs after setClientPart).
                Step(
                    name = "select-part",
                    wire = wire,
                    expect = null,
                    check = StepCheck.Accept,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
                Step(
                    name = "part-readback",
                    wire = OfficePrecisionProtocol.CMD_STATUS,
                    expect = Expectation.StatusAnswer,
                    check = StepCheck.StatusSelectedPartMatches(request.partId),
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
                Step(
                    name = "paste-text",
                    wire = wire,
                    expect = Expectation.PasteResult,
                    check = StepCheck.PasteSuccess,
                    timeoutMs = MUTATION_TIMEOUT_MS,
                ),
                // SOFT content postcondition: after a producer-confirmed
                // paste the core normally leaves the pasted text selected,
                // so the same pinned readback can confirm the exact bytes.
                // Any other outcome stays NATIVE_COMPLETED — never FAILED.
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
            val steps = ArrayList<Step>(5)
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
