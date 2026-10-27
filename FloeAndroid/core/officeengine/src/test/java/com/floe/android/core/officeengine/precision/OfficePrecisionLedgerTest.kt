// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM regression for the correlation ledger — the safety core of the
 * precision surface (late acks, quarantine/poison, interleaved queries,
 * proven-readback completion, target CAS incl. precision-effect epochs,
 * oversize refusal, UNKNOWN honesty).
 *
 * These tests pin the Main review invariants (2026-10-27):
 *  - a late/duplicate/forged frame can never complete a NEW operation;
 *  - a timed-out barrier poisons barrier re-arming for the incarnation and
 *    a later stale barrier reply can never clear quarantine;
 *  - genuinely-earlier same-kind completions arriving around the barrier
 *    (barrier phase OR awaiting-dispatch window) are discarded;
 *  - callback-emitted frames (setpart:/textselection:) are corroboration
 *    only: a matching frame plus elapsed time NEVER settles an operation —
 *    navigation/selection verify through pinned-ordering-proven synchronous
 *    readbacks (status: selectedpart / gettextselection content);
 *  - EVERY dispatched effect (selection/navigation included, UNKNOWN and
 *    FAILED included) advances the precision effect epoch, so captures from
 *    before it can never apply to another sheet/slide/selection, while a
 *    fresh capture stays usable and pure queries never invalidate;
 *  - UNKNOWN never auto-undoes and retains data;
 *  - position readback proves ONLY position: exact content match verifies,
 *    explicit comparable conflict is UNKNOWN, unavailable evidence is
 *    NATIVE_COMPLETED; selection stays partial NATIVE_COMPLETED.
 */
class OfficePrecisionLedgerTest {

    private var nowMs = 1_000L
    private fun ledger() = OfficePrecisionLedger(clock = { nowMs })

    private val token = "session-token"
    private val gen = 7L

    private fun request(
        opId: String,
        action: OfficePrecisionAction,
        text: String? = null,
        contentKind: OfficePrecisionContentKind? = null,
        cellAddress: String? = null,
        partId: String? = null,
        targetHandle: String? = null,
    ) = OfficePrecisionRequest(
        opId = opId,
        sessionToken = token,
        generation = gen,
        action = action,
        text = text,
        contentKind = contentKind,
        cellAddress = cellAddress,
        partId = partId,
        targetHandle = targetHandle,
    )

    // Frame builders (fields mirror what the engine extracts from triage).
    private fun statusFrame(json: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.STATUS,
        prefix = "status",
        payload = json,
        payloadBytes = json.length,
    )

    private fun statusUpdateFrame(json: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.STATUS,
        prefix = "statusupdate",
        payload = json,
        payloadBytes = json.length,
    )

    private fun commandValuesFrame(name: String, values: String? = null) =
        OfficePrecisionLedger.ObservedFrame(
            kind = OfficePrecisionLedger.FrameKind.COMMAND_VALUE,
            prefix = "commandvalues",
            payload = "present",
            payloadBytes = 16,
            commandName = name,
            commandValues = values,
        )

    private fun selectionContentFrame(content: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.TEXT_SELECTION_CONTENT,
        prefix = "textselectioncontent",
        payload = "textselectioncontent: $content",
        payloadBytes = content.length + 22,
    )

    private fun pasteFrame(verdict: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.PASTE_RESULT,
        prefix = "pasteresult",
        payloadBytes = 20,
        pasteVerdict = verdict,
    )

    private fun partEchoFrame(part: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.PART_SET,
        prefix = "setpart",
        payloadBytes = 12,
        partEcho = part,
    )

    private fun textSelectionFrame(payload: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.TEXT_SELECTION,
        prefix = "textselection",
        payload = payload,
        payloadBytes = payload.length,
    )

    private fun errorFrame(cmd: String, kind: String) = OfficePrecisionLedger.ObservedFrame(
        kind = OfficePrecisionLedger.FrameKind.ERROR,
        prefix = "error",
        payloadBytes = 30,
        errorCmd = cmd,
        errorKind = kind,
    )

    private val statusJson =
        "{\"type\":\"spreadsheet\",\"partscount\":2,\"selectedpart\":\"0\"," +
            "\"width\":100,\"height\":100,\"viewid\":0}"

    private fun claimArmed(
        ledger: OfficePrecisionLedger,
        req: OfficePrecisionRequest,
    ): OfficePrecisionLedger.OpRun {
        assertEquals(true, ledger.submit(req) is OfficePrecisionLedger.SubmitOutcome.Accepted)
        val run = ledger.claimNext()
        assertNotNull(run)
        return run!!
    }

    /** Mirrors the engine: arm, note the real wire post, then feed frames. */
    private fun armDispatched(
        ledger: OfficePrecisionLedger,
        run: OfficePrecisionLedger.OpRun,
        stepIndex: Int,
    ): OfficePrecisionLedger.ArmDecision {
        val decision = ledger.armStep(run, stepIndex)
        if (decision == OfficePrecisionLedger.ArmDecision.DispatchNow) {
            ledger.noteWireDispatched(run, stepIndex)
        }
        return decision
    }

    // ------------------------------------------------------------------
    // Basic query correlation
    // ------------------------------------------------------------------

    @Test
    fun querySettlesOnlyOnItsOwnAnswerFrame() {
        val l = ledger()
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertEquals(OfficePrecisionLedger.ArmDecision.DispatchNow, armDispatched(l, run, 0))
        // Unrelated frames never settle.
        assertEquals(OfficePrecisionLedger.LedgerEvent.Ignored, l.onFrame(pasteFrame("success")))
        // statusupdate/partstatus prefixes never settle a `status` pull.
        assertEquals(OfficePrecisionLedger.LedgerEvent.Ignored, l.onFrame(statusUpdateFrame(statusJson)))
        val event = l.onFrame(statusFrame(statusJson))
        assertTrue(event is OfficePrecisionLedger.LedgerEvent.Terminal)
        val result = (event as OfficePrecisionLedger.LedgerEvent.Terminal).result
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, result.state)
        val answer = result.answer as OfficePrecisionAnswer.DocumentContext
        assertEquals("spreadsheet", answer.docType)
        assertEquals(2, answer.partsCount)
        // Consumed exactly once.
        assertEquals(result.opId, l.takeResult("q1")?.opId)
        assertNull(l.takeResult("q1"))
    }

    @Test
    fun framesBeforeArmOrAfterTerminalNeverCompleteAnything() {
        val l = ledger()
        // No armed op: frames are counted only.
        assertEquals(OfficePrecisionLedger.LedgerEvent.Ignored, l.onFrame(statusFrame(statusJson)))
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        // Queued-but-not-armed (stepIndex -1): still cannot settle.
        assertEquals(OfficePrecisionLedger.LedgerEvent.Ignored, l.onFrame(statusFrame(statusJson)))
        armDispatched(l, run, 0)
        val terminal = l.onFrame(statusFrame(statusJson)) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, terminal.result.state)
        // A duplicate late answer after terminal cannot re-settle or corrupt.
        assertEquals(OfficePrecisionLedger.LedgerEvent.Ignored, l.onFrame(statusFrame(statusJson)))
    }

    @Test
    fun pureQueriesNeverInvalidateCapturedTargets() {
        val l = ledger()
        val target = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        armDispatched(l, run, 0)
        l.onFrame(statusFrame(statusJson))
        // A completed query dispatched no effect: the capture stays usable
        // (no gratuitous invalidation).
        assertTrue(
            l.validateTarget(target.handleId, gen, "sha-a", consume = false)
                is OfficePrecisionLedger.TargetCheck.Ok,
        )
    }

    // ------------------------------------------------------------------
    // Serialization: concurrent same-kind queries cannot cross-complete
    // ------------------------------------------------------------------

    @Test
    fun sameKindQueriesSerializeAndNeverCrossComplete() {
        val l = ledger()
        val sel = { id: String -> request(id, OfficePrecisionAction.QUERY_TEXT_SELECTION) }
        assertTrue(l.submit(sel("a")) is OfficePrecisionLedger.SubmitOutcome.Accepted)
        assertTrue(l.submit(sel("b")) is OfficePrecisionLedger.SubmitOutcome.Accepted)
        // Only ONE armed at a time: claim returns "a"; "b" stays queued.
        val runA = l.claimNext()!!
        assertEquals("a", runA.request.opId)
        assertNull(l.claimNext()) // single in-flight even though "b" is queued
        armDispatched(l, runA, 0)
        val termA = l.onFrame(selectionContentFrame("answer-a"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals("a", termA.result.opId)
        assertEquals("answer-a", (termA.result.answer as OfficePrecisionAnswer.TextSelection).text)
        // "b" only settles on its OWN answer after being claimed and armed.
        val runB = l.claimNext()!!
        assertEquals("b", runB.request.opId)
        // A stale duplicate of a's answer BEFORE b is armed cannot settle b.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(selectionContentFrame("answer-a")),
        )
        armDispatched(l, runB, 0)
        val termB = l.onFrame(selectionContentFrame("answer-b"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals("b", termB.result.opId)
        assertEquals("answer-b", (termB.result.answer as OfficePrecisionAnswer.TextSelection).text)
    }

    @Test
    fun pendingQueueIsBoundedAndOverflowIsRefused() {
        val l = OfficePrecisionLedger(maxPending = 2, clock = { nowMs })
        assertTrue(l.submit(request("a", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
            is OfficePrecisionLedger.SubmitOutcome.Accepted)
        assertTrue(l.submit(request("b", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
            is OfficePrecisionLedger.SubmitOutcome.Accepted)
        val overflow = l.submit(request("c", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertTrue(overflow is OfficePrecisionLedger.SubmitOutcome.Rejected)
        assertEquals(
            OfficePrecisionFailure.QUEUE_FULL,
            (overflow as OfficePrecisionLedger.SubmitOutcome.Rejected).failure,
        )
    }

    @Test
    fun duplicateOpIdIsRefused() {
        val l = ledger()
        assertTrue(l.submit(request("dup", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
            is OfficePrecisionLedger.SubmitOutcome.Accepted)
        val second = l.submit(request("dup", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertTrue(second is OfficePrecisionLedger.SubmitOutcome.Rejected)
        assertEquals(
            OfficePrecisionFailure.INVALID_REQUEST,
            (second as OfficePrecisionLedger.SubmitOutcome.Rejected).failure,
        )
    }

    // ------------------------------------------------------------------
    // Late acks, quarantine and the ordered barrier
    // ------------------------------------------------------------------

    @Test
    fun timeoutIsUnknownThenLateAckCannotCompleteNextOpWithoutBarrier() {
        val l = ledger()
        val runA = claimArmed(l, request("a", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        armDispatched(l, runA, 0)
        val timeout = l.onStepTimeout("a", 0)
        assertNotNull(timeout)
        assertEquals(OfficePrecisionState.UNKNOWN, timeout!!.state)
        assertEquals(OfficePrecisionFailure.TIMEOUT, timeout.failure)
        assertTrue(l.quarantineActive())
        // The late ack for "a" arrives AFTER its terminal: never re-settles.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(selectionContentFrame("late-a")),
        )
        // Next same-kind op MUST barrier-fence: the stale frame is still loose.
        val runB = claimArmed(l, request("b", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertEquals(OfficePrecisionLedger.ArmDecision.BarrierFirst, l.armStep(runB, 0))
        // A genuinely-earlier same-kind completion arriving AROUND the
        // barrier is discarded (it precedes the barrier reply in the serial
        // producer stream), never completing "b".
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(selectionContentFrame("stale-a")),
        )
        // The barrier reply re-emits the dispatch and lifts proven quarantine.
        val dispatched = l.onFrame(commandValuesFrame(".uno:ReadOnly"))
        assertTrue(dispatched is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        assertFalse((dispatched as OfficePrecisionLedger.LedgerEvent.DispatchStep).barrierFirst)
        assertFalse(l.quarantineActive())
        // Awaiting-dispatch window: even a same-kind frame right after the
        // barrier reply (before the engine re-armed/posted) is discarded.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(selectionContentFrame("around-barrier")),
        )
        assertEquals(OfficePrecisionLedger.ArmDecision.DispatchNow, armDispatched(l, runB, 0))
        val termB = l.onFrame(selectionContentFrame("fresh-b"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, termB.result.state)
        assertEquals("fresh-b", (termB.result.answer as OfficePrecisionAnswer.TextSelection).text)
    }

    @Test
    fun timedOutBarrierPoisonsIncarnationAndStaleBarrierReplyNeverClears() {
        val l = ledger()
        // 1) A query misses its answer -> proven-kind quarantine.
        val runA = claimArmed(l, request("a", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        armDispatched(l, runA, 0)
        assertNotNull(l.onStepTimeout("a", 0))
        assertTrue(l.quarantineActive())
        // 2) The next op arms a barrier... and the barrier reply ALSO goes
        //    missing -> UNKNOWN + poisoned barrier.
        val runB = claimArmed(l, request("b", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertEquals(OfficePrecisionLedger.ArmDecision.BarrierFirst, l.armStep(runB, 0))
        val timeoutB = l.onStepTimeout("b", 0)
        assertEquals(OfficePrecisionState.UNKNOWN, timeoutB!!.state)
        assertTrue(l.barrierPoisoned())
        assertTrue(l.quarantineActive())
        // 3) A LATE stale barrier reply (from b's own lost barrier, or any
        //    earlier one) must NOT clear the quarantine now.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(commandValuesFrame(".uno:ReadOnly")),
        )
        assertTrue("stale barrier reply must not clear quarantine", l.quarantineActive())
        // 4) Subsequent same-kind operations are refused for the rest of
        //    this incarnation (only a NEW native incarnation reconciles).
        val rejected = l.submit(request("c", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertTrue(rejected is OfficePrecisionLedger.SubmitOutcome.Rejected)
        assertEquals(
            OfficePrecisionFailure.STALE_ANSWER_QUARANTINE,
            (rejected as OfficePrecisionLedger.SubmitOutcome.Rejected).failure,
        )
        // 5) A DIFFERENT answer kind would still work absent the page-query
        //    flag; WITH the preventive flag set, poisoning refuses it too —
        //    an uncorrelated barrier can never fence anything again.
        l.notePageQueryForwarded()
        val refusedByPoison = l.submit(request("d", OfficePrecisionAction.QUERY_PRESENTATION_INFO))
        assertTrue(refusedByPoison is OfficePrecisionLedger.SubmitOutcome.Rejected)
    }

    @Test
    fun unknownRetainsDataAndNeverAutoUndoes() {
        val l = ledger()
        val run = claimArmed(
            l,
            request(
                "m1",
                OfficePrecisionAction.APPLY_TEXT,
                text = "payload",
                targetHandle = "0123456789abcdef0123456789abcdef",
            ),
        )
        armDispatched(l, run, 0)
        val unknown = l.onStepTimeout("m1", 0)!!
        assertEquals(OfficePrecisionState.UNKNOWN, unknown.state)
        assertEquals(OfficePrecisionFailure.TIMEOUT, unknown.failure)
        // No completion, no verification claim, and the ledger emitted no
        // compensating command of any kind (it is pure: it never sends).
        assertNull(unknown.answer)
        // The stored result keeps every identity-safe fact for recovery.
        val stored = l.peekResult("m1")
        assertNotNull(stored)
        assertEquals(OfficePrecisionState.UNKNOWN, stored!!.state)
        assertTrue(stored.attestation.isNotEmpty())
    }

    // ------------------------------------------------------------------
    // Producer refusals / failure paths
    // ------------------------------------------------------------------

    @Test
    fun producerErrorFrameSettlesTheArmedOpOnly() {
        val l = ledger()
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        armDispatched(l, run, 0)
        // An error for a DIFFERENT command does not settle.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(errorFrame("save", "savefailed")),
        )
        val consumed = l.onFrame(errorFrame("gettextselection", "syntax"))
        assertTrue(consumed is OfficePrecisionLedger.LedgerEvent.ConsumedError)
        val result = (consumed as OfficePrecisionLedger.LedgerEvent.ConsumedError).result
        assertEquals(OfficePrecisionState.FAILED, result.state)
        assertEquals(OfficePrecisionFailure.PRODUCER_REJECTED, result.failure)
    }

    @Test
    fun errorForAnyDispatchedCommandIsConsumed() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "9"))
        armDispatched(l, run, 0) // select-part fire-and-forget
        l.markDispatched(run, 0)
        armDispatched(l, run, 1) // part-readback armed
        // The producer refuses the EARLIER setclientpart while the readback
        // is armed (e.g. an out-of-range part): still THIS op's refusal.
        val consumed = l.onFrame(errorFrame("setclientpart", "invalid"))
        assertTrue(consumed is OfficePrecisionLedger.LedgerEvent.ConsumedError)
        val result = (consumed as OfficePrecisionLedger.LedgerEvent.ConsumedError).result
        assertEquals(OfficePrecisionState.FAILED, result.state)
        assertEquals(OfficePrecisionFailure.PRODUCER_REJECTED, result.failure)
    }

    @Test
    fun complexSelectionIsHonestUnavailabilityForContentQueries() {
        val l = ledger()
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        armDispatched(l, run, 0)
        val event = l.onFrame(
            OfficePrecisionLedger.ObservedFrame(
                kind = OfficePrecisionLedger.FrameKind.COMPLEX_SELECTION,
                prefix = "complexselection",
                payloadBytes = 18,
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, event.result.state)
        assertEquals(OfficePrecisionFailure.COMPLEX_SELECTION_UNAVAILABLE, event.result.failure)
    }

    @Test
    fun oversizeAnswersAreRefusedWithByteCountNeverTruncated() {
        val l = ledger()
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        armDispatched(l, run, 0)
        val event = l.onFrame(
            OfficePrecisionLedger.ObservedFrame(
                kind = OfficePrecisionLedger.FrameKind.TEXT_SELECTION_CONTENT,
                prefix = "textselectioncontent",
                payload = null, // engine refuses to extract oversize content
                payloadBytes = OfficePrecisionProtocol.MAX_ANSWER_BYTES + 1,
                oversize = true,
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, event.result.state)
        assertEquals(OfficePrecisionFailure.ANSWER_TOO_LARGE, event.result.failure)
        assertTrue(event.result.detail!!.contains("answer-bytes="))
        assertNull("oversize content must never be carried", event.result.answer)
    }

    // ------------------------------------------------------------------
    // Selection / navigation: proven readbacks only, callback frames never
    // ------------------------------------------------------------------

    @Test
    fun selectAllTextVerifiesOnlyThroughProvenReadback() {
        val l = ledger()
        val run = claimArmed(l, request("s1", OfficePrecisionAction.SELECT_ALL_TEXT))
        armDispatched(l, run, 0)
        l.markDispatched(run, 0) // select-all posted; readback step next
        val dispatched = l.claimNext() // no-op sanity: run still armed
        assertNull(dispatched)
        armDispatched(l, run, 1)
        // A callback-emitted TEXT_SELECTION frame — even a perfectly
        // matching non-EMPTY one — NEVER settles the operation (no pinned
        // ordering proof; frame+sleep is not operation proof).
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(textSelectionFrame("0, 0, 100, 100")),
        )
        // The proven synchronous readback with an EMPTY answer cannot
        // confirm the effect: honest failure.
        val empty = l.onFrame(selectionContentFrame("")) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, empty.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, empty.result.failure)

        // Fresh run: non-empty proven readback -> partial postcondition ->
        // NATIVE_COMPLETED (never a "verified select-all" claim).
        val run2 = claimArmed(l, request("s2", OfficePrecisionAction.SELECT_ALL_TEXT))
        armDispatched(l, run2, 0)
        l.markDispatched(run2, 0)
        armDispatched(l, run2, 1)
        val ok = l.onFrame(selectionContentFrame("selected text"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, ok.result.state)
        assertEquals(
            "selection-postcondition-partial-readback",
            ok.result.detail,
        )
        assertEquals(
            "selected text".length,
            (ok.result.answer as OfficePrecisionAnswer.TextSelected).effectPayloadBytes,
        )
    }

    @Test
    fun selectSlideVerifiesThroughStatusReadbackNotCallbackEcho() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l, run, 0)
        l.markDispatched(run, 0) // setclientpart posted
        armDispatched(l, run, 1)
        // The callback-emitted setpart echo is corroboration only: it can
        // never settle the operation, whatever part it names.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(partEchoFrame("2")),
        )
        // A status readback showing a DIFFERENT selected part fails honestly.
        val mismatch = l.onFrame(
            statusFrame(
                "{\"type\":\"presentation\",\"partscount\":3,\"selectedpart\":\"0\"," +
                    "\"width\":10,\"height\":10,\"viewid\":0}",
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, mismatch.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, mismatch.result.failure)

        // Fresh run: the proven readback echoing the requested part is the
        // FULL navigation postcondition -> MUTATION_VERIFIED.
        val run2 = claimArmed(l, request("n2", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l, run2, 0)
        l.markDispatched(run2, 0)
        armDispatched(l, run2, 1)
        val ok = l.onFrame(
            statusFrame(
                "{\"type\":\"presentation\",\"partscount\":3,\"selectedpart\":\"2\"," +
                    "\"width\":10,\"height\":10,\"viewid\":0}",
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, ok.result.state)
        assertEquals("2", (ok.result.answer as OfficePrecisionAnswer.SlideSelected).shownPart)
    }

    // ------------------------------------------------------------------
    // Precision-effect epoch: dispatched effects invalidate earlier captures
    // ------------------------------------------------------------------

    @Test
    fun dispatchedSelectionOrNavigationInvalidatesEarlierCapturesIncludingUnknown() {
        val l = ledger()
        val target = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)

        // A SELECT_SLIDE whose readback never arrives: the setclientpart was
        // really dispatched, so the part context MAY have moved — the op is
        // UNKNOWN and the earlier capture is invalidated regardless.
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        l.markDispatched(run, 0)
        armDispatched(l, run, 1)
        val unknown = l.onStepTimeout("n1", 1)!!
        assertEquals(OfficePrecisionState.UNKNOWN, unknown.state)
        val stale = l.validateTarget(target.handleId, gen, "sha-a", consume = true)
        assertEquals(
            "precision-effect-since-capture",
            (stale as OfficePrecisionLedger.TargetCheck.Refused).detail,
        )

        // A FAILED (but dispatched) select-all invalidates too.
        val target2 = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        val run2 = claimArmed(l, request("s1", OfficePrecisionAction.SELECT_ALL_TEXT))
        armDispatched(l, run2, 0)
        l.markDispatched(run2, 0)
        armDispatched(l, run2, 1)
        val failed = l.onFrame(selectionContentFrame(""))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, failed.result.state)
        val stale2 = l.validateTarget(target2.handleId, gen, "sha-a", consume = true)
        assertEquals(
            OfficePrecisionFailure.APPLY_CONFLICT,
            (stale2 as OfficePrecisionLedger.TargetCheck.Refused).failure,
        )

        // A FRESH capture taken after the effect stays usable, and a pure
        // query invalidates nothing (no gratuitous epoch movement).
        val target3 = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        val runQ = claimArmed(l, request("q", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        armDispatched(l, runQ, 0)
        l.onFrame(statusFrame(statusJson))
        assertTrue(
            l.validateTarget(target3.handleId, gen, "sha-a", consume = false)
                is OfficePrecisionLedger.TargetCheck.Ok,
        )
    }

    // ------------------------------------------------------------------
    // Content mutations: native completion vs verified content
    // ------------------------------------------------------------------

    private val handle = "0123456789abcdef0123456789abcdef"

    @Test
    fun applyTextPasteFallbackIsHonestFailure() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "hello", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        val event = l.onFrame(pasteFrame("fallback")) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, event.result.state)
        assertEquals(OfficePrecisionFailure.PRODUCER_REJECTED, event.result.failure)
    }

    @Test
    fun applyTextVerifiedOnlyOnExactContentReadback() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "hello", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        // Producer completion evidence alone is NOT verified content.
        val afterPaste = l.onFrame(pasteFrame("success"))
        assertTrue(afterPaste is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        // Soft readback with EXACT match upgrades to MUTATION_VERIFIED.
        armDispatched(l, run, 1)
        val verified = l.onFrame(selectionContentFrame("hello"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, verified.result.state)
        val applied = verified.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.MATCHED, applied.contentReadback)
        assertEquals(5, applied.pastedBytes)
    }

    @Test
    fun applyTextExplicitReadbackMismatchIsUnknownEffectNotNativeCompleted() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "1.50", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 1)
        // Exact C07 class: pasteresult=success followed by a REAL comparable
        // answer that contradicts the requested text. ACK + conflict is not
        // completion; the possible effect is retained and never replayed.
        val event = l.onFrame(selectionContentFrame("1.5"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.UNKNOWN, event.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, event.result.failure)
        assertEquals("content-readback-conflict-effect-uncertain", event.result.detail)
        assertNull(event.result.answer)
        assertTrue(event.result.attestation.contains("content-readback:readback-mismatch"))
    }

    @Test
    fun applyTextSoftReadbackTimeoutKeepsNativeCompletion() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 1)
        val timeout = l.onStepTimeout("m1", 1)!!
        // Soft stage: the completed mutation is NOT downgraded to UNKNOWN.
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, timeout.state)
        val applied = timeout.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.UNAVAILABLE, applied.contentReadback)
    }

    @Test
    fun oversizeSoftReadbackKeepsTheSmallMutationReceipt() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 1)
        // An effect that already occurred keeps its small state/receipt even
        // when the verification readback is too large to carry (count only).
        val event = l.onFrame(
            OfficePrecisionLedger.ObservedFrame(
                kind = OfficePrecisionLedger.FrameKind.TEXT_SELECTION_CONTENT,
                prefix = "textselectioncontent",
                payload = null,
                payloadBytes = OfficePrecisionProtocol.MAX_ANSWER_BYTES + 1,
                oversize = true,
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, event.result.state)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.UNAVAILABLE, applied.contentReadback)
        assertEquals(handle, applied.consumedTargetHandle)
    }

    @Test
    fun setCellContentLiteralWalksFullSemanticLadder() {
        val l = ledger()
        val run = claimArmed(
            l,
            request(
                "c1",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "hello",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = handle,
            ),
        )
        // Step 0: goto-cell (fire-and-forget; completes on send).
        assertEquals(OfficePrecisionLedger.ArmDecision.DispatchNow, armDispatched(l, run, 0))
        val toStep1 = l.markDispatched(run, 0)
        assertTrue(toStep1 is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        assertEquals(1, (toStep1 as OfficePrecisionLedger.LedgerEvent.DispatchStep).stepIndex)
        // Step 1: POSITION readback must show exactly B2 (col 1, row 1).
        armDispatched(l, run, 1)
        val wrongCell = l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 0, 10, 10, 4, 4"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        // Wrong target: FAILED BEFORE any content effect (but the goto WAS
        // dispatched — the effect epoch advanced, invalidating old captures).
        assertEquals(OfficePrecisionState.FAILED, wrongCell.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, wrongCell.result.failure)

        // Fresh run: correct ladder to verified content.
        val run2 = claimArmed(
            l,
            request(
                "c2",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "hello",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = handle,
            ),
        )
        armDispatched(l, run2, 0)
        l.markDispatched(run2, 0)
        armDispatched(l, run2, 1)
        assertTrue(
            l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l, run2, 2)
        assertTrue(l.onFrame(pasteFrame("success")) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run2, 3)
        assertTrue(
            l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l, run2, 4)
        val verified = l.onFrame(selectionContentFrame("hello"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, verified.result.state)
        assertEquals(
            OfficePrecisionContentReadback.MATCHED,
            (verified.result.answer as OfficePrecisionAnswer.MutationApplied).contentReadback,
        )
    }

    @Test
    fun setCellContentFormulaNeverStringComparesDisplayText() {
        val l = ledger()
        val run = claimArmed(
            l,
            request(
                "f1",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "=SUM(A1:A2)",
                contentKind = OfficePrecisionContentKind.FORMULA,
                cellAddress = "B3",
                targetHandle = handle,
            ),
        )
        // Formula plan has NO soft readback stage: 4 steps only.
        assertEquals(4, run.plan.size)
        armDispatched(l, run, 0)
        l.markDispatched(run, 0)
        armDispatched(l, run, 1)
        l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 0, 10, 10, 1, 2"))
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
        val event = l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 0, 10, 10, 1, 2"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        // Producer completion + position confirmation, but display text is
        // the COMPUTED value — honestly not comparable to the formula source.
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, event.result.state)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE, applied.contentReadback)
        assertEquals("pending-flush-or-export-verification", event.result.detail)
    }

    // ------------------------------------------------------------------
    // Target handles: dual revision + epoch CAS
    // ------------------------------------------------------------------

    @Test
    fun manualInputSinceCaptureConflictsEvenWhenNothingElseChanged() {
        val l = ledger()
        val target = l.issueTarget(
            generation = gen,
            workingCopySha256 = "sha-a",
            workingCopyBytes = 10,
            documentModified = true, // stays true before AND after: no signal
            sourceId = "src", sourceRevision = "rev", sourceLogicalPath = null,
            workspaceId = null, ownerTaskId = null,
        )
        // A manual page retarget/write advances the input epoch — the apply
        // MUST conflict even though ModifiedStatus merely stayed true and
        // the flushed file digest did not move.
        l.notePageInput()
        val check = l.validateTarget(target.handleId, gen, "sha-a", consume = true)
        assertTrue(check is OfficePrecisionLedger.TargetCheck.Refused)
        val refused = check as OfficePrecisionLedger.TargetCheck.Refused
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, refused.failure)
        assertEquals("manual-input-since-capture", refused.detail)
    }

    @Test
    fun flushRemountAndMutationAllInvalidateCapturedTargets() {
        val l = ledger()
        val target = l.issueTarget(
            gen, "sha-a", 10, false, null, null, null, null, null,
        )
        // Working-copy file changed (a flush wrote new bytes).
        val flushed = l.validateTarget(target.handleId, gen, "sha-b", consume = true)
        assertEquals(
            "working-copy-changed",
            (flushed as OfficePrecisionLedger.TargetCheck.Refused).detail,
        )

        // Remount: a different generation never matches.
        val t2 = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        val remounted = l.validateTarget(t2.handleId, gen + 1, "sha-a", consume = true)
        assertEquals(
            "generation-advanced",
            (remounted as OfficePrecisionLedger.TargetCheck.Refused).detail,
        )

        // A dispatched AI content mutation advances the effect epoch: older
        // captures are stale even though file+input epoch did not move.
        val epochBefore = l.editEpoch()
        val t3 = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = handle),
        )
        armDispatched(l, run, 0)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 1)
        l.onFrame(selectionContentFrame("x")) // MUTATION_VERIFIED
        assertEquals(epochBefore + 1, l.editEpoch())
        val stale = l.validateTarget(t3.handleId, gen, "sha-a", consume = true)
        assertEquals(
            "precision-effect-since-capture",
            (stale as OfficePrecisionLedger.TargetCheck.Refused).detail,
        )
    }

    @Test
    fun handlesAreSingleUseBoundedAndExpire() {
        val l = ledger()
        val target = l.issueTarget(gen, "sha", 1, false, null, null, null, null, null)
        assertTrue(l.validateTarget(target.handleId, gen, "sha", consume = true)
            is OfficePrecisionLedger.TargetCheck.Ok)
        // Single-use: a consumed handle is gone (never reusable).
        val reused = l.validateTarget(target.handleId, gen, "sha", consume = true)
        assertEquals(
            OfficePrecisionFailure.TARGET_UNKNOWN,
            (reused as OfficePrecisionLedger.TargetCheck.Refused).failure,
        )
        // Forgery: a well-formed but never-issued handle is unknown.
        val forged = l.validateTarget("a".repeat(32), gen, "sha", consume = true)
        assertEquals(
            OfficePrecisionFailure.TARGET_UNKNOWN,
            (forged as OfficePrecisionLedger.TargetCheck.Refused).failure,
        )
        // Expiry: TTL bound is enforced against the injected clock.
        val t2 = l.issueTarget(gen, "sha", 1, false, null, null, null, null, null)
        nowMs += OfficePrecisionLedger.HANDLE_TTL_MS + 1
        val expired = l.validateTarget(t2.handleId, gen, "sha", consume = true)
        assertEquals(
            "handle-expired",
            (expired as OfficePrecisionLedger.TargetCheck.Refused).detail,
        )
        // Registry is bounded: issuing beyond the cap evicts oldest.
        nowMs = 1_000L
        val small = OfficePrecisionLedger(maxHandles = 2, clock = { nowMs })
        val h1 = small.issueTarget(gen, "sha", 1, false, null, null, null, null, null)
        small.issueTarget(gen, "sha", 1, false, null, null, null, null, null)
        small.issueTarget(gen, "sha", 1, false, null, null, null, null, null)
        val evicted = small.validateTarget(h1.handleId, gen, "sha", consume = false)
        assertEquals(
            OfficePrecisionFailure.TARGET_UNKNOWN,
            (evicted as OfficePrecisionLedger.TargetCheck.Refused).failure,
        )
    }

    @Test
    fun queryPageForwardingForcesPreventiveBarrier() {
        val l = ledger()
        // The page ran its own clipboard/query pull while idle: its late
        // reply could complete a fresh op, so the next answer-expecting
        // step must barrier-fence.
        l.notePageQueryForwarded()
        val run = claimArmed(l, request("q1", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertEquals(OfficePrecisionLedger.ArmDecision.BarrierFirst, l.armStep(run, 0))
        // The stale page reply itself cannot settle the armed op.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(selectionContentFrame("page-copy")),
        )
        l.onFrame(commandValuesFrame(".uno:ReadOnly"))
        assertEquals(OfficePrecisionLedger.ArmDecision.DispatchNow, armDispatched(l, run, 0))
        val ok = l.onFrame(selectionContentFrame("mine"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals("mine", (ok.result.answer as OfficePrecisionAnswer.TextSelection).text)
    }

    // ------------------------------------------------------------------
    // Mount end
    // ------------------------------------------------------------------

    @Test
    fun mountTerminalSettlesArmedUnknownAndQueuedRejected() {
        val l = ledger()
        val runA = claimArmed(l, request("a", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        armDispatched(l, runA, 0)
        assertTrue(l.submit(request("b", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
            is OfficePrecisionLedger.SubmitOutcome.Accepted)
        val results = l.onMountTerminal()
        assertEquals(2, results.size)
        val byOp = results.associateBy { it.opId }
        assertEquals(OfficePrecisionState.UNKNOWN, byOp["a"]!!.state)
        assertEquals(OfficePrecisionState.REJECTED, byOp["b"]!!.state)
        assertEquals(OfficePrecisionFailure.SESSION_ENDING, byOp["b"]!!.failure)
        assertFalse(l.hasArmedWork())
        assertEquals(0, l.pendingCount())
    }
}
