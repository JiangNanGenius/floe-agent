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

    // Producer-pinned presentation identifiers (Collabora Mobile
    // 26.04.4.2/937 @2333344185931274f9c49d6c12a408cefcef6844):
    // kit/KitHelper.hpp documentStatus emits `selectedpart` as the core
    // getPart() string, and for a presentation that is the page GUID in
    // braced form; fetchPartsData concatenates one core getPartInfo object
    // per page and the pinned Impress frontend reads exactly
    // `parts[i].part` for its own setclientpart. A presentation `status:`
    // NEVER carries a decimal selectedpart.
    private val pageGuidA = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5A0}"
    private val pageGuidB = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1}"
    private val pageGuidC = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5C2}"

    /** Pinned-shape presentation status JSON (payload only, no frame prefix). */
    private fun presentationStatusJson(
        selectedPart: String,
        parts: List<String> = listOf(pageGuidA, pageGuidB, pageGuidC),
    ): String =
        "{\"type\":\"presentation\",\"partscount\":${parts.size}," +
            "\"selectedpart\":\"$selectedPart\",\"width\":10,\"height\":10,\"viewid\":0," +
            "\"parts\":[" + parts.joinToString(",") {
            "{\"part\":\"$it\",\"width\":10,\"height\":10,\"mode\":0}"
        } + "]}"

    private fun claimArmed(
        ledger: OfficePrecisionLedger,
        req: OfficePrecisionRequest,
    ): OfficePrecisionLedger.OpRun {
        assertEquals(true, ledger.submit(req) is OfficePrecisionLedger.SubmitOutcome.Accepted)
        val run = ledger.claimNext()
        assertNotNull(run)
        if (req.action.effect == OfficePrecisionEffect.CONTENT) {
            // Mirrors the engine's consumed capture, not a prior-selection
            // injection. Actual text still has to arrive through the plan's
            // own status + selection frames below.
            run!!.contentTarget = OfficePrecisionTarget(
                handleId = req.targetHandle.orEmpty(), generation = req.generation,
                sourceId = null, sourceRevision = null, sourceLogicalPath = null,
                workspaceId = null, ownerTaskId = null,
                workingCopySha256 = "sha-a", workingCopyBytes = 10L,
                inputEpoch = ledger.inputEpoch(), editEpoch = ledger.editEpoch(),
                documentModified = false, docType = null, partsCount = null,
                selectedPart = "0", capturedAtElapsedMs = nowMs,
                expiresAtElapsedMs = Long.MAX_VALUE / 4,
            )
        }
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

    private fun acquirePreEffect(
        ledger: OfficePrecisionLedger,
        run: OfficePrecisionLedger.OpRun,
        statusStep: Int,
        selectionStep: Int,
        prior: String,
    ) {
        armDispatched(ledger, run, statusStep)
        assertTrue(ledger.onFrame(statusFrame(statusJson)) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(ledger, run, selectionStep)
        assertTrue(
            ledger.onFrame(selectionContentFrame(prior)) is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
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
        armDispatched(l, run, 0) // part-index-resolve `status` pull
        assertTrue(
            l.onFrame(statusFrame(statusJson)) is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        ) // spreadsheet keeps the documented decimal identifier
        assertEquals("setclientpart part=9", l.wireForDispatch(run, 1))
        armDispatched(l, run, 1) // select-part fire-and-forget
        assertTrue(l.markDispatched(run, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run, 2) // part-readback armed
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
    fun preDispatchRefusalKeepsItsProvenNoEffectLineage() {
        // office-background-repair118, the exact C17 first-failure shape:
        // refused BEFORE any plan wire -> the no-effect token survives and the
        // effect epoch does NOT move (nothing was dispatched).
        val l = ledger()
        val epochBefore = l.editEpoch()
        val run = claimArmed(l, request("ref-pre", OfficePrecisionAction.SELECT_ALL_TEXT))
        val refused = l.rejectRun(
            run,
            OfficePrecisionFailure.TRANSPORT,
            "edit-preparation:page-edit-hook-unavailable",
        )
        assertNotNull(refused)
        assertEquals(OfficePrecisionState.REJECTED, refused!!.state)
        assertEquals(OfficePrecisionFailure.TRANSPORT, refused.failure)
        assertEquals(OfficePrecisionAttestation.REFUSED_BEFORE_DISPATCH, refused.attestation)
        assertEquals(epochBefore, l.editEpoch())
    }

    @Test
    fun postDispatchRefusalCanNeverClaimPreDispatchLineage() {
        // office-background-repair118: a fence re-check at a LATER step (the
        // engine's `mount-ended-before-step`) refuses an ARMED run whose step-0
        // effect wire was REALLY posted: the maybe-effect epoch advanced and the
        // lineage can NEVER say "refused-before-dispatch", or the upper layer
        // would wrongly claim no effect happened.
        val l = ledger()
        val epochBefore = l.editEpoch()
        val run = claimArmed(l, request("ref-post", OfficePrecisionAction.SELECT_ALL_TEXT))
        armDispatched(l, run, 0) // step-0 effect wire REALLY posted
        val refused = l.rejectRun(
            run,
            OfficePrecisionFailure.SESSION_ENDING,
            "mount-ended-before-step",
        )
        assertNotNull(refused)
        assertEquals(OfficePrecisionState.REJECTED, refused!!.state)
        assertEquals(epochBefore + 1, l.editEpoch())
        assertEquals(
            OfficePrecisionAttestation.REFUSED_AFTER_EFFECT_DISPATCH,
            refused.attestation,
        )
        assertFalse(refused.attestation.contains(OfficePrecisionAttestation.REFUSED_BEFORE_DISPATCH))
    }

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
        val selected = ok.result.answer as OfficePrecisionAnswer.TextSelection
        assertEquals("selected text".length, selected.byteCount)
        assertEquals("selected text", selected.text)
        assertFalse(selected.multiFormatJson)
    }

    @Test
    fun selectAllWithoutAvailableContentKeepsOnlyTheRealByteCount() {
        val l = ledger()
        val run = claimArmed(l, request("s3", OfficePrecisionAction.SELECT_ALL_TEXT))
        armDispatched(l, run, 0)
        l.markDispatched(run, 0)
        armDispatched(l, run, 1)
        val result = l.onFrame(
            OfficePrecisionLedger.ObservedFrame(
                kind = OfficePrecisionLedger.FrameKind.COMPLEX_SELECTION,
                prefix = "complexselection",
                payloadBytes = 1_048_576,
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, result.result.state)
        val selected = result.result.answer as OfficePrecisionAnswer.TextSelected
        assertEquals(1_048_576, selected.effectPayloadBytes)
        // No fabricated empty string can become a cursor/whole-body proof.
    }

    @Test
    fun selectSlideVerifiesThroughStatusReadbackNotCallbackEcho() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l, run, 0)
        // The callback-emitted setpart echo can never settle the mandatory
        // synchronous resolve pull either, whatever part it names.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(partEchoFrame(pageGuidC)),
        )
        // Resolve: the producer's OWN status names page 3 by its braced GUID
        // at parts index 2. The dispatched navigation wire must carry THAT
        // identifier — never the decimal request (the C15 defect: the pinned
        // Impress boundary resolves only the page GUID, so `part=2` named
        // no page, silently selected nothing, and the honest readback could
        // never match it).
        val resolved = l.onFrame(statusFrame(presentationStatusJson(pageGuidA)))
        assertTrue(resolved is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        assertEquals("setclientpart part=$pageGuidC", l.wireForDispatch(run, 1))
        armDispatched(l, run, 1)
        assertTrue(l.markDispatched(run, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run, 2)
        // The callback-emitted setpart echo is corroboration only: it can
        // never settle the operation, even when it names the exact target.
        assertEquals(
            OfficePrecisionLedger.LedgerEvent.Ignored,
            l.onFrame(partEchoFrame(pageGuidC)),
        )
        // A status readback showing a DIFFERENT selected part (still the
        // first page's GUID) fails honestly with the original C15 tokens.
        val mismatch = l.onFrame(statusFrame(presentationStatusJson(pageGuidA)))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, mismatch.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, mismatch.result.failure)
        assertEquals("part-readback-mismatch", mismatch.result.detail)

        // Fresh run: the proven readback echoing the producer's resolved
        // page GUID is the FULL navigation postcondition -> MUTATION_VERIFIED.
        val run2 = claimArmed(l, request("n2", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l, run2, 0)
        assertTrue(
            l.onFrame(statusFrame(presentationStatusJson(pageGuidA)))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l, run2, 1)
        assertTrue(l.markDispatched(run2, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run2, 2)
        val ok = l.onFrame(statusFrame(presentationStatusJson(pageGuidC)))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, ok.result.state)
        val selectedAnswer = ok.result.answer as OfficePrecisionAnswer.SlideSelected
        assertEquals(pageGuidC, selectedAnswer.shownPart)
        // This same readback answer's ordered witness places page C at
        // logical ordinal 2 — the lineage the capture/host/Parcel path must
        // carry separately from the byte-exact GUID identity.
        assertEquals(2, selectedAnswer.shownPartIndex)
    }

    @Test
    fun selectSlideResolvesBracedPageGuidForTheRealC15TwoSlideFailure() {
        // Deterministic replay of the C15 first failure as a passing
        // regression: real two-slide preview, scripted request "slide 2"
        // (decimal partId "1"), producer status identifying each page by
        // its GUID. Pre-repair this chain was REFUSED with detail
        // "part-readback-mismatch" / attestation
        // "part-readback-readback-disagreed" and the view stayed on page 1.
        val l = ledger()
        val run = claimArmed(l, request("c15", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        val firstPull = l.onFrame(
            statusFrame(presentationStatusJson(pageGuidA, parts = listOf(pageGuidA, pageGuidB))),
        )
        assertTrue(firstPull is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        assertEquals("setclientpart part=$pageGuidB", l.wireForDispatch(run, 1))
        armDispatched(l, run, 1)
        assertTrue(l.markDispatched(run, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run, 2)
        val terminal = l.onFrame(
            statusFrame(presentationStatusJson(pageGuidB, parts = listOf(pageGuidA, pageGuidB))),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, terminal.result.state)
        assertNull(terminal.result.failure)
        val selected = terminal.result.answer as OfficePrecisionAnswer.SlideSelected
        assertEquals(pageGuidB, selected.shownPart)
        // The concrete downstream lineage: slide 2 was requested by decimal,
        // the producer dispatched and proved the page GUID, and the SAME
        // proven readback witnesses logical ordinal 1 — the value the
        // capture/Parcel/host saved-verification path needs to choose the
        // SECOND ordered OOXML slide (pre-84 this was null at the host).
        assertEquals(1, selected.shownPartIndex)
        assertTrue(terminal.result.attestation.contains("part-index-resolve:part-index-resolved"))
        assertTrue(terminal.result.attestation.contains("select-part:sent"))
        assertTrue(terminal.result.attestation.contains("part-readback:part-readback-matched"))
    }

    @Test
    fun selectSlideRefusesBeforeAnyNavigationWireWhenIndexNamesNoPart() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        val terminal = l.onFrame(
            statusFrame(presentationStatusJson(pageGuidA, parts = listOf(pageGuidA))),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, terminal.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, terminal.result.failure)
        assertEquals("part-index-out-of-range", terminal.result.detail)
        // No navigation command can even be materialized: fail closed BEFORE
        // any effect instead of dispatching a decimal that names no page.
        assertNull(l.wireForDispatch(run, 1))
    }

    @Test
    fun selectSlideRefusesEntryIdentifierThatIsNotABracedGuid() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        // Witnessed entry identifier that is NOT the pinned braced GUID
        // grammar (here a bare decimal) is refused, never forwarded or
        // normalized to a "wrong index".
        val weird = "{\"type\":\"presentation\",\"partscount\":2,\"selectedpart\":\"$pageGuidA\"," +
            "\"width\":10,\"height\":10,\"viewid\":0," +
            "\"parts\":[{\"part\":\"$pageGuidA\",\"width\":10,\"height\":10,\"mode\":0}," +
            "{\"part\":\"1\",\"width\":10,\"height\":10,\"mode\":0}]}"
        val terminal = l.onFrame(statusFrame(weird)) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, terminal.result.state)
        assertEquals("part-id-unresolved", terminal.result.detail)
        assertNull(l.wireForDispatch(run, 1))
    }

    @Test
    fun selectSlideRefusesMissingPartWitnessWithoutShiftingLaterPages() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        // parts[1] carries no `part` witness at all. The null placeholder
        // must keep its position: index 1 refuses, and parts[2]'s GUID can
        // never slide into it.
        val missing = "{\"type\":\"presentation\",\"partscount\":3,\"selectedpart\":\"$pageGuidA\"," +
            "\"width\":10,\"height\":10,\"viewid\":0," +
            "\"parts\":[{\"part\":\"$pageGuidA\",\"width\":10,\"height\":10,\"mode\":0}," +
            "{\"width\":10,\"height\":10,\"mode\":0}," +
            "{\"part\":\"$pageGuidC\",\"width\":10,\"height\":10,\"mode\":0}]}"
        val terminal = l.onFrame(statusFrame(missing)) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, terminal.result.state)
        assertEquals("part-id-unresolved", terminal.result.detail)
        assertNull(l.wireForDispatch(run, 1))
    }

    @Test
    fun selectSlideRefusesStatusWithoutAnyPartsWitnessForPresentation() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        // Absent parts array: the producer names no pages in THIS answer,
        // so nothing may be dispatched on the decimal alone.
        val noParts = "{\"type\":\"presentation\",\"partscount\":2,\"selectedpart\":\"$pageGuidA\"," +
            "\"width\":10,\"height\":10,\"viewid\":0}"
        val terminal = l.onFrame(statusFrame(noParts)) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, terminal.result.state)
        assertEquals("part-index-out-of-range", terminal.result.detail)
        assertNull(l.wireForDispatch(run, 1))
    }

    @Test
    fun selectSlideKeepsDecimalIdentifierForSpreadsheetAndTextFamilies() {
        // The documented spreadsheet identifier IS the decimal sheet index
        // (kit/KitHelper.hpp @2333344), so its wire and readback stay
        // byte-identical to the proven pre-repair behaviour.
        val l = ledger()
        val run = claimArmed(l, request("x1", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l, run, 0)
        val resolve = "{\"type\":\"spreadsheet\",\"partscount\":3,\"selectedpart\":\"0\"," +
            "\"width\":10,\"height\":10,\"viewid\":0}"
        assertTrue(
            l.onFrame(statusFrame(resolve)) is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        assertEquals("setclientpart part=2", l.wireForDispatch(run, 1))
        armDispatched(l, run, 1)
        assertTrue(l.markDispatched(run, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run, 2)
        val ok = l.onFrame(
            statusFrame(
                "{\"type\":\"spreadsheet\",\"partscount\":3,\"selectedpart\":\"2\"," +
                    "\"width\":10,\"height\":10,\"viewid\":0}",
            ),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, ok.result.state)
        val decimalSelected = ok.result.answer as OfficePrecisionAnswer.SlideSelected
        assertEquals("2", decimalSelected.shownPart)
        // The documented decimal identifier IS the legitimate ordinal for
        // this family (byte-identical to the proven pre-repair behaviour).
        assertEquals(2, decimalSelected.shownPartIndex)
    }

    @Test
    fun selectSlideRefusesUnknownDocumentFamilyWithoutGuessing() {
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "0"))
        armDispatched(l, run, 0)
        // documentTypeToString emits "other-<n>" for unknown cores; the
        // resolve step must refuse instead of guessing a grammar.
        val weirdType = "{\"type\":\"other-42\",\"partscount\":1,\"selectedpart\":\"0\"," +
            "\"width\":10,\"height\":10,\"viewid\":0}"
        val terminal = l.onFrame(statusFrame(weirdType)) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, terminal.result.state)
        assertEquals("part-family-unsupported", terminal.result.detail)
        assertNull(l.wireForDispatch(run, 1))
    }

    @Test
    fun selectSlideResolveQuarantineStaysWithinBoundedWindowLikeOtherStatusPulls() {
        // A missed resolve answer is the same pinned-synchronous `status`
        // kind: the run terminates UNKNOWN (no effect dispatched beyond the
        // resolve pull itself) and the kind quarantines — never an implicit
        // retry or replay of the selection.
        val l = ledger()
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        val unknown = l.onStepTimeout("n1", 0)!!
        assertEquals(OfficePrecisionState.UNKNOWN, unknown.state)
        assertEquals(OfficePrecisionFailure.TIMEOUT, unknown.failure)
        assertEquals("step=part-index-resolve", unknown.detail)
        assertTrue(l.quarantineActive())
    }

    // ------------------------------------------------------------------
    // Witnessed logical ordinal lineage (part-ordinal84): the GUID stays
    // byte-exact identity while the ordinal is carried SEPARATELY from the
    // SAME validated status answer's ordered parts witness — capture,
    // context and readback — fail-closed on anything the answer does not
    // itself witness. Never the caller's desired index, never a decimal
    // re-parse of a GUID at the host boundary (the gap that would refuse
    // the saved PPTX verification after a successful 81 select).
    // ------------------------------------------------------------------

    @Test
    fun capturedTargetBindsOrdinalFromItsOwnStatusWitnessNotFromTheGuid() {
        val l = ledger()
        val target = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)
        // Mirrors the engine: the handle exists before this capture's own
        // status pull settles; the bind below completes it.
        l.pendingCaptureTarget = target
        val run = claimArmed(l, request("cap-o", OfficePrecisionAction.CAPTURE_TARGET))
        armDispatched(l, run, 0)
        val terminal = l.onFrame(
            statusFrame(presentationStatusJson(pageGuidB, parts = listOf(pageGuidA, pageGuidB))),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, terminal.result.state)
        val captured = (terminal.result.answer as OfficePrecisionAnswer.TargetCaptured).target
        // Identity byte-exact, ordinal separately witnessed as the SECOND
        // page (index 1 of this answer's own parts witness).
        assertEquals(pageGuidB, captured.selectedPart)
        assertEquals(1, captured.selectedPartIndex)
        assertEquals(2, captured.partsCount)
        // One immutable value: the stored record a later content run consumes
        // carries the SAME ordinal as the advertised answer.
        val check = l.validateTarget(captured.handleId, gen, "sha-a", consume = false)
        assertTrue(check is OfficePrecisionLedger.TargetCheck.Ok)
        val stored = (check as OfficePrecisionLedger.TargetCheck.Ok).target
        assertEquals(captured.selectedPartIndex, stored.selectedPartIndex)
        assertEquals(pageGuidB, stored.selectedPart)
    }

    @Test
    fun contextAndCaptureKeepOrdinalNullWhenThisAnswerWitnessesNoMapping() {
        // Honest absence at the QUERY boundary: a presentation answer whose
        // parts witness is missing, or whose list contradicts its own
        // partscount, NEVER yields a guessed ordinal; the downstream host
        // fence (not the engine) refuses anything built on it.
        val l = ledger()
        val run = claimArmed(l, request("q-o", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        armDispatched(l, run, 0)
        val noParts = "{\"type\":\"presentation\",\"partscount\":2,\"selectedpart\":\"$pageGuidB\"," +
            "\"width\":10,\"height\":10,\"viewid\":0}"
        val terminal = l.onFrame(statusFrame(noParts)) as OfficePrecisionLedger.LedgerEvent.Terminal
        val answer = terminal.result.answer as OfficePrecisionAnswer.DocumentContext
        assertEquals(pageGuidB, answer.selectedPart) // identity kept byte-exact
        assertNull(answer.selectedPartIndex) // no witness in THIS answer
        // The documented decimal family keeps its legitimate ordinal here
        // (the ordinary spreadsheet status above).
        val run2 = claimArmed(l, request("q-d", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        armDispatched(l, run2, 0)
        val decimal = (l.onFrame(statusFrame(statusJson)) as OfficePrecisionLedger.LedgerEvent.Terminal)
            .result.answer as OfficePrecisionAnswer.DocumentContext
        assertEquals("0", decimal.selectedPart)
        assertEquals(0, decimal.selectedPartIndex)
    }

    @Test
    fun selectSlideRefusesUnwitnessedOrDriftedOrdinalAtTheProvenReadback() {
        // (a) Identity matches but the proven readback answer itself carries
        // no parts witness: the ordinal is NOT taken from the earlier cached
        // resolve status — the operation refuses honestly.
        val l = ledger()
        val run = claimArmed(l, request("d1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        assertTrue(
            l.onFrame(statusFrame(presentationStatusJson(pageGuidA, parts = listOf(pageGuidA, pageGuidB))))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l, run, 1)
        assertTrue(l.markDispatched(run, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run, 2)
        val unwitnessed = l.onFrame(statusFrame(
            "{\"type\":\"presentation\",\"partscount\":2,\"selectedpart\":\"$pageGuidB\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, unwitnessed.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, unwitnessed.result.failure)
        assertEquals("part-ordinal-unresolved", unwitnessed.result.detail)
        assertNull(unwitnessed.result.answer)

        // (b) Duplicate ambiguity: the shown GUID appears at two positions
        // of the SAME answer — no unique ordinal, refuse.
        val l2 = ledger()
        val run2 = claimArmed(l2, request("d2", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l2, run2, 0)
        assertTrue(
            l2.onFrame(statusFrame(presentationStatusJson(pageGuidA, parts = listOf(pageGuidA, pageGuidB))))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l2, run2, 1)
        assertTrue(l2.markDispatched(run2, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l2, run2, 2)
        val ambiguous = l2.onFrame(
            statusFrame(presentationStatusJson(pageGuidB, parts = listOf(pageGuidB, pageGuidB))),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals("part-ordinal-unresolved", ambiguous.result.detail)

        // (c) Drift: the readback witness places the proven GUID at a
        // DIFFERENT logical position than the resolve answer did (the part
        // list moved) — refuse instead of carrying either index blindly.
        val l3 = ledger()
        val run3 = claimArmed(l3, request("d3", OfficePrecisionAction.SELECT_SLIDE, partId = "2"))
        armDispatched(l3, run3, 0)
        assertTrue(
            l3.onFrame(statusFrame(presentationStatusJson(pageGuidA))) // [A,B,C] -> C
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        assertEquals("setclientpart part=$pageGuidC", l3.wireForDispatch(run3, 1))
        armDispatched(l3, run3, 1)
        assertTrue(l3.markDispatched(run3, 1) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l3, run3, 2)
        val drifted = l3.onFrame(
            statusFrame(presentationStatusJson(pageGuidC, parts = listOf(pageGuidA, pageGuidC))),
        ) as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.FAILED, drifted.result.state)
        assertEquals("part-ordinal-drift", drifted.result.detail)
    }

    // ------------------------------------------------------------------
    // Precision-effect epoch: dispatched effects invalidate earlier captures
    // ------------------------------------------------------------------

    @Test
    fun dispatchedSelectionOrNavigationInvalidatesEarlierCapturesIncludingUnknown() {
        val l = ledger()
        val target = l.issueTarget(gen, "sha-a", 10, false, null, null, null, null, null)

        // A SELECT_SLIDE whose resolve pull never answers: the first plan
        // wire was really posted, and the pre-repair navigation dispatch
        // (or a maybe-effect of any later step) still makes the part
        // context uncertain — the op is UNKNOWN and the earlier capture
        // is invalidated regardless.
        val run = claimArmed(l, request("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        armDispatched(l, run, 0)
        val unknown = l.onStepTimeout("n1", 0)!!
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
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
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
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
        // Producer completion evidence alone is NOT verified content.
        val afterPaste = l.onFrame(pasteFrame("success"))
        assertTrue(afterPaste is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        // Soft readback with EXACT match upgrades to MUTATION_VERIFIED.
        armDispatched(l, run, 3)
        val verified = l.onFrame(selectionContentFrame("hello"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, verified.result.state)
        val applied = verified.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.MATCHED, applied.contentReadback)
        assertEquals(5, applied.pastedBytes)
        assertEquals("before", applied.preEffectEvidence?.selectionText)
        assertEquals("m1", applied.preEffectEvidence?.opId)
        assertEquals("0", applied.preEffectEvidence?.partId)
    }

    @Test
    fun applyTextOldSelectionReadbackIsNotBodyContentConflict() {
        val l = ledger()
        val expected = "Floe LOCAL QA marker applied via scripted fixture (no cloud model)."
        val oldSelection = "手记 § Baseline 🧪Floe G01 synthetic paragraph with bold and italic runs." +
            "مرحبا שלום mixed RTLalpha list onebeta list twoγ § 3 list three"
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = expected, targetHandle = handle),
        )
        acquirePreEffect(l, run, 0, 1, oldSelection)
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
        // C11 failure-class fixture: paste landed, then the readback names only
        // the OLD view selection. That selection-scoped answer cannot disprove
        // the document-body effect; only the later saved OOXML proof can do so.
        val event = l.onFrame(selectionContentFrame(oldSelection))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, event.result.state)
        assertNull(event.result.failure)
        assertEquals("pending-flush-or-export-verification", event.result.detail)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.UNAVAILABLE, applied.contentReadback)
        assertTrue(event.result.attestation.contains("content-readback:readback-selection-not-comparable"))
    }

    @Test
    fun applyTextCollapsedSelectionReadbackIsNotBodyContentConflict() {
        val l = ledger()
        val run = claimArmed(
            l,
            request("m1", OfficePrecisionAction.APPLY_TEXT, text = "replacement", targetHandle = handle),
        )
        acquirePreEffect(l, run, 0, 1, "")
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
        // A collapsed post-paste selection is empty even when the document
        // contains the replacement. Empty selection ≠ empty document body.
        val event = l.onFrame(selectionContentFrame(""))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, event.result.state)
        assertNull(event.result.failure)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.UNAVAILABLE, applied.contentReadback)
        assertTrue(event.result.attestation.contains("content-readback:readback-selection-not-comparable"))
    }

    @Test
    fun setCellContentExplicitReadbackMismatchIsUnknownEffectNotNativeCompleted() {
        val l = ledger()
        val run = claimArmed(
            l,
            request(
                "m1",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "1.50",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = handle,
            ),
        )
        armDispatched(l, run, 0)
        l.markDispatched(run, 0)
        armDispatched(l, run, 1)
        l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
        acquirePreEffect(l, run, 2, 3, "1.50")
        armDispatched(l, run, 4)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 5)
        l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
        armDispatched(l, run, 6)
        // A Calc single-cell readback IS scoped to the mutation target. Its
        // explicit disagreement remains positive conflict evidence: UNKNOWN,
        // never NATIVE_COMPLETED, never an automatic replay.
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
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
        val timeout = l.onStepTimeout("m1", 3)!!
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
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
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
        acquirePreEffect(l, run2, 2, 3, "before")
        armDispatched(l, run2, 4)
        assertTrue(l.onFrame(pasteFrame("success")) is OfficePrecisionLedger.LedgerEvent.DispatchStep)
        armDispatched(l, run2, 5)
        assertTrue(
            l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(l, run2, 6)
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
        // Formula plan has mandatory BEFORE evidence but NO soft post-paste
        // display/formula comparison: six steps only.
        assertEquals(6, run.plan.size)
        armDispatched(l, run, 0)
        l.markDispatched(run, 0)
        armDispatched(l, run, 1)
        l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 0, 10, 10, 1, 2"))
        acquirePreEffect(l, run, 2, 3, "7")
        armDispatched(l, run, 4)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 5)
        val event = l.onFrame(commandValuesFrame(".uno:CellCursor", "0, 0, 10, 10, 1, 2"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        // Producer completion + position confirmation, but display text is
        // the COMPUTED value — honestly not comparable to the formula source.
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, event.result.state)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE, applied.contentReadback)
        assertEquals("7", applied.preEffectEvidence?.selectionText)
        assertEquals("f1", applied.preEffectEvidence?.opId)
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
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
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

    // ------------------------------------------------------------------
    // Calc literal INPUT codec vs semantic expectation (C14 root cause,
    // Main ruling 2026-10-28): the outbound paste wire carries exactly one
    // leading apostrophe (OfficeAiWire.encodeNativeLiteral); the pinned
    // producer consumes it as the quoted-text input marker, so the NATIVE
    // selection projection is the RAW wanted value. Actual C14 witness:
    // wire '00123 -> readback exactly "00123" (5 bytes) and saved OOXML
    // sharedString "00123" (device/diag-read72). The comparator expectation
    // must decode the request side ONLY.
    // ------------------------------------------------------------------

    /** Drives the SET_CELL_CONTENT ladder to just before the soft stage 6. */
    private fun runCalcLiteralLadder(
        ledger: OfficePrecisionLedger,
        opId: String,
        wireText: String,
        prior: String = "10",
    ): OfficePrecisionLedger.OpRun {
        val run = claimArmed(
            ledger,
            request(
                opId,
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = wireText,
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = handle,
            ),
        )
        armDispatched(ledger, run, 0)
        ledger.markDispatched(run, 0)
        armDispatched(ledger, run, 1)
        assertTrue(
            ledger.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        acquirePreEffect(ledger, run, 2, 3, prior)
        armDispatched(ledger, run, 4)
        assertTrue(
            ledger.onFrame(pasteFrame("success"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(ledger, run, 5)
        assertTrue(
            ledger.onFrame(commandValuesFrame(".uno:CellCursor", "0, 380, 1219, 256, 1, 1"))
                is OfficePrecisionLedger.LedgerEvent.DispatchStep,
        )
        armDispatched(ledger, run, 6)
        return run
    }

    private fun settleSelection(
        ledger: OfficePrecisionLedger,
        content: String,
    ): OfficePrecisionLedger.LedgerEvent.Terminal =
        ledger.onFrame(selectionContentFrame(content)) as OfficePrecisionLedger.LedgerEvent.Terminal

    @Test
    fun setCellContentEncodedLiteralMatchesNativeProjectedRawValue() {
        // The real C14 witness pair: wire '00123, native answer 00123.
        val l = ledger()
        runCalcLiteralLadder(l, "codec1", "'00123")
        val event = settleSelection(l, "00123")
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, event.result.state)
        assertNull(event.result.failure)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.MATCHED, applied.contentReadback)
        assertTrue(event.result.attestation.contains("content-readback:readback-matched"))
    }

    @Test
    fun setCellContentQuotedNativeProjectionRemainsComparableConflict() {
        // The OBSERVED text is never stripped: an answer that still carries
        // a quote is a genuine projection disagreement against the decoded
        // raw expectation "00123" -> UNKNOWN, retained, never replayed.
        val l = ledger()
        runCalcLiteralLadder(l, "codec2", "'00123")
        val event = settleSelection(l, "'00123")
        assertEquals(OfficePrecisionState.UNKNOWN, event.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, event.result.failure)
        assertEquals("content-readback-conflict-effect-uncertain", event.result.detail)
        assertTrue(event.result.attestation.contains("content-readback:readback-mismatch"))
    }

    @Test
    fun setCellContentMultiCellOrAppendedNewlineProjectionRemainsConflict() {
        // The pinned committed single-cell Doc2Text provably answers WITHOUT
        // any line terminator ("Do not append a line feed for one single
        // cell", impex.cxx @2333344), so an observed LF/TSV-shaped answer is
        // NOT silently trimmed — it stays an explicit comparable conflict.
        val l = ledger()
        runCalcLiteralLadder(l, "codec3a", "'00123")
        val withTab = settleSelection(l, "00123\t9")
        assertEquals(OfficePrecisionState.UNKNOWN, withTab.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, withTab.result.failure)

        runCalcLiteralLadder(l, "codec3b", "'00123")
        val withLf = settleSelection(l, "00123\n")
        assertEquals(OfficePrecisionState.UNKNOWN, withLf.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, withLf.result.failure)
    }

    @Test
    fun setCellContentLeadingEqualsLiteralMatchesDecodedExpectation() {
        // A literal "=SUM(A1:A2)" is wire-encoded "'=SUM(A1:A2)" so the
        // producer stores a TEXT cell; its projection "=SUM(A1:A2)" must
        // match the decoded semantic expectation.
        val l = ledger()
        runCalcLiteralLadder(l, "codec4", "'=SUM(A1:A2)")
        val event = settleSelection(l, "=SUM(A1:A2)")
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, event.result.state)
        val applied = event.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.MATCHED, applied.contentReadback)
    }

    @Test
    fun setCellContentUserLiteralLeadingApostropheDecodesExactlyOnce() {
        // Wanted raw value "'00123" carries its OWN apostrophe; the host
        // codec prefixes one MORE ("''00123"). The producer commits the raw
        // "'00123". Exactly one prefix is undone — never a blanket strip.
        val l = ledger()
        runCalcLiteralLadder(l, "codec5a", "''00123")
        val matched = settleSelection(l, "'00123")
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, matched.result.state)

        // A projection over-stripped to "00123" is a real disagreement.
        runCalcLiteralLadder(l, "codec5b", "''00123")
        val conflict = settleSelection(l, "00123")
        assertEquals(OfficePrecisionState.UNKNOWN, conflict.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, conflict.result.failure)
    }

    @Test
    fun setCellContentNumericUnescapedLiteralPassesThroughUndecoded() {
        // The NUMBER branch rides the same LITERAL kind WITHOUT the escape:
        // canonical numeric text has no leading apostrophe, so the decode is
        // an exact no-op and numeric comparison behaviour is unchanged.
        val l = ledger()
        runCalcLiteralLadder(l, "codec6a", "123")
        val matched = settleSelection(l, "123")
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, matched.result.state)

        runCalcLiteralLadder(l, "codec6b", "123")
        val conflict = settleSelection(l, "124")
        assertEquals(OfficePrecisionState.UNKNOWN, conflict.result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, conflict.result.failure)
    }

    @Test
    fun applyTextLeadingApostropheExpectationIsNeverDecoded() {
        // Writer APPLY_TEXT has no Calc INPUT codec: the leading apostrophe
        // in request.text is part of the wanted text. It must stay intact —
        // an exact "'kept" answer matches, and a stripped "kept" answer is
        // NOT accepted as a decoded match (it falls to the existing
        // selection-not-body UNAVAILABLE classification instead).
        val l = ledger()
        val run = claimArmed(
            l,
            request("codec7a", OfficePrecisionAction.APPLY_TEXT, text = "'kept", targetHandle = handle),
        )
        acquirePreEffect(l, run, 0, 1, "before")
        armDispatched(l, run, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run, 3)
        val matched = l.onFrame(selectionContentFrame("'kept"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, matched.result.state)

        val run2 = claimArmed(
            l,
            request("codec7b", OfficePrecisionAction.APPLY_TEXT, text = "'kept", targetHandle = handle),
        )
        acquirePreEffect(l, run2, 0, 1, "before")
        armDispatched(l, run2, 2)
        l.onFrame(pasteFrame("success"))
        armDispatched(l, run2, 3)
        val stripped = l.onFrame(selectionContentFrame("kept"))
            as OfficePrecisionLedger.LedgerEvent.Terminal
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, stripped.result.state)
        val applied = stripped.result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.UNAVAILABLE, applied.contentReadback)
        assertTrue(
            stripped.result.attestation.contains("content-readback:readback-selection-not-comparable"),
        )
    }
}
