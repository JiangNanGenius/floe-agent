// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Approval-card retirement regression (R8 App projection repair).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs this class with the existing conversation-projection JVM cohort.
 *
 * Source proof (observed Alpha7 defect, r8-main-20261021 UI evidence): an
 * accepted tool run (`Approve` → MCP executed → final text
 * `FLOE_G02_FIXTURE_TOOL_DONE`) left the SAME actionable approval card on
 * screen and the group "waiting for confirmation" after the round ended.
 * Cause: `ThreadProjectionBuilder.applySnapshot` only ADDED
 * `page.pendingApproval` and never reconciled authoritative absence; the
 * live-owner snapshot omits the member exactly when the run has no pending
 * approval (native builder, RuntimeFacadeRunEvents — the member is never
 * budget-dropped for an owned run; only a no-owner page writes an explicit
 * null meaning "unknowable", never "none").
 *
 * These tests pin the corrected reconciliation against the REAL builder,
 * the REAL `run.snapshot` decoder and the ORIGINAL engine approval payload
 * vocabulary. No fake runtime host, no Android resources.
 */
class ConversationApprovalRetirementTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val runId = "33333333-3333-4333-8333-333333333333"
    private val siblingRunId = "44444444-4444-4444-8444-444444444444"
    private val callId = "call-9f8e7d"
    private val requestedAt1 = "2026-10-21T12:00:00.000Z"
    private val requestedAt2 = "2026-10-21T12:05:00.000Z"

    // ------------------------------------------------------------ fixtures

    /** REAL `run.snapshot` page through the actual decoder — no shortcuts. */
    private fun snapshotPage(
        runID: String = runId,
        state: String = "executingTool",
        watermark: Long,
        liveOwner: Boolean = true,
        terminal: Boolean = false,
        requestedAt: String? = null,
    ): ConversationWire.SnapshotPage {
        val approval = if (requestedAt == null) {
            "null"
        } else {
            """{"callID":"$callId","tool":"mcp.fs.read","reason":"Needs approval",""" +
                """"requestedAt":"$requestedAt"}"""
        }
        val approvalRevision = if (requestedAt == null) {
            "null"
        } else {
            """{"resourceID":"approval.$callId","version":"$requestedAt"}"""
        }
        val json =
            """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
                """"runID":"$runID","durableState":"$state",""" +
                """"revision":{"resourceID":"run.${runID.uppercase()}","version":"$state"},""" +
                """"isTerminal":$terminal,"conversationMode":"chat","goal":"hi",""" +
                """"liveOwner":$liveOwner,"pendingApproval":$approval,""" +
                """"approvalRevision":$approvalRevision,"pendingInputs":[],""" +
                """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
                """"version":"queue-digest-1"},"durableWatermark":$watermark}"""
        val page = ConversationWire.decodeSnapshotPage(Json.parseToJsonElement(json))
        assertNotNull("fixture page must decode through the real decoder", page)
        return page!!
    }

    private fun builderFor(runID: String): ThreadProjectionBuilder =
        ThreadProjectionBuilder(conversationId).apply { selectedRunId = runID }

    private fun approvalRequestFrame(runID: String, sequence: Long): HostRunEventFrame =
        HostRunEventFrame(
            runID = runID,
            sequence = sequence,
            kind = "approval",
            payload = Json.parseToJsonElement(
                """{"tool":"mcp.fs.read","callID":"$callId","scope":"workspace/notes.md",""" +
                    """"reason":"Needs approval","requestedAt":"$requestedAt1"}""",
            ).jsonObject,
            bytes = 0,
        )

    private fun approvalOutcomeFrame(runID: String, sequence: Long): HostRunEventFrame =
        HostRunEventFrame(
            runID = runID,
            sequence = sequence,
            kind = "approval",
            payload = Json.parseToJsonElement(
                """{"tool":"mcp.fs.read","callID":"$callId","outcome":"allowed"}""",
            ).jsonObject,
            bytes = 0,
        )

    // -------------------------------------------------------------- tests

    /**
     * The observed defect: after the human decision the next authoritative
     * live-owner snapshot carries NO `pendingApproval`; the projection must
     * retire the card AND its CAS version (the click/queue ack alone never
     * does — retirement requires the authoritative carrier).
     */
    @Test
    fun freshAuthoritativeAbsenceRetiresCardAndVersions() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        assertEquals(1, builder.build().pendingApprovals.size)
        assertEquals(requestedAt1, builder.approvalVersion(callId))

        builder.applySnapshot(snapshotPage(watermark = 6))
        assertTrue(
            "fresh live-owner absence must retire the card",
            builder.build().pendingApprovals.isEmpty(),
        )
        assertNull(
            "the retired request must drop its CAS version",
            builder.approvalVersion(callId),
        )
    }

    /**
     * Without a live owner the native page writes `pendingApproval: null`
     * meaning "unknowable", never "none": such an absence must NOT clear a
     * card the live owner projected.
     */
    @Test
    fun absenceWithoutLiveOwnerIsNotAuthoritative() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 6, liveOwner = false))
        assertEquals(1, builder.build().pendingApprovals.size)
        assertEquals(requestedAt1, builder.approvalVersion(callId))
    }

    /**
     * ABA — resurrection: a snapshot page fetched while the old request was
     * still pending (watermark BEFORE the retirement observation) arrives
     * late and must not bring the retired card back.
     */
    @Test
    fun latePreDecisionPageCannotResurrectRetiredCard() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 6))
        assertTrue(builder.build().pendingApprovals.isEmpty())

        builder.applySnapshot(snapshotPage(watermark = 5, requestedAt = requestedAt1))
        assertTrue(
            "an older page carrying the old request must not resurrect it",
            builder.build().pendingApprovals.isEmpty(),
        )
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        assertTrue(
            "a replayed same-generation page must not resurrect it either",
            builder.build().pendingApprovals.isEmpty(),
        )
    }

    /**
     * ABA — premature clear: a page fetched BEFORE the request landed
     * (lower watermark) reports absence; it must not clear the newer card.
     */
    @Test
    fun staleAbsenceDoesNotClearNewerRequest() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 6, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 4))
        assertEquals(1, builder.build().pendingApprovals.size)
        assertEquals(requestedAt1, builder.approvalVersion(callId))
    }

    /**
     * A genuinely NEW request for the SAME call id (new `requestedAt` ⇒ new
     * CAS version) on the SAME run replaces the card in place — exactly one
     * card, fresh request-bound fields, updated version.
     */
    @Test
    fun newRequestForSameCallIdWithNewVersionReplacesCard() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 6, requestedAt = requestedAt2))
        val approvals = builder.build().pendingApprovals
        assertEquals(1, approvals.size)
        assertEquals(requestedAt2, approvals.single().requestedAtLabel)
        assertEquals(requestedAt2, builder.approvalVersion(callId))
    }

    /**
     * Run-identity fence: retiring run A's card never touches run B's card,
     * and the shared call-id CAS version survives while B still projects it.
     */
    @Test
    fun siblingRunCardAndSharedVersionSurviveThisRunRetirement() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySnapshot(snapshotPage(runID = runId, watermark = 4, requestedAt = requestedAt1))
        builder.applySnapshot(
            snapshotPage(runID = siblingRunId, watermark = 4, requestedAt = requestedAt1),
        )
        builder.applySnapshot(snapshotPage(runID = runId, watermark = 6))
        // A retired…
        builder.selectedRunId = runId
        assertTrue(builder.build().pendingApprovals.isEmpty())
        // …B intact…
        builder.selectedRunId = siblingRunId
        assertEquals(1, builder.build().pendingApprovals.size)
        // …and the CAS version still bound to B's live card.
        assertEquals(requestedAt1, builder.approvalVersion(callId))
    }

    /**
     * Durable outcome record retires the card (existing vocabulary, now
     * fenced): a late pre-outcome snapshot page carrying the old request
     * must not resurrect it.
     */
    @Test
    fun durableOutcomeEventRetiresAndLateSnapshotCannotResurrect() {
        val builder = builderFor(runId)
        builder.applyRunEvent(approvalRequestFrame(runId, sequence = 10))
        assertEquals(1, builder.build().pendingApprovals.size)
        builder.applyRunEvent(approvalOutcomeFrame(runId, sequence = 11))
        assertTrue(builder.build().pendingApprovals.isEmpty())
        assertNull(builder.approvalVersion(callId))

        builder.applySnapshot(snapshotPage(watermark = 10, requestedAt = requestedAt1))
        assertTrue(
            "a pre-outcome page must not resurrect the retired card",
            builder.build().pendingApprovals.isEmpty(),
        )
    }

    /**
     * A durable REQUEST record projects the card and is fenced at its own
     * sequence: an older snapshot page (fetched before the request landed)
     * must not clear it.
     */
    @Test
    fun durableRequestEventIsNotClearedByPreRequestSnapshot() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4))
        builder.applyRunEvent(approvalRequestFrame(runId, sequence = 5))
        assertEquals(1, builder.build().pendingApprovals.size)
        builder.applySnapshot(snapshotPage(watermark = 4))
        assertEquals(1, builder.build().pendingApprovals.size)
    }

    @Test
    fun sameWatermarkSnapshotAndReplayedRequestCannotResurrect() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 10, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 10))
        builder.applySnapshot(snapshotPage(watermark = 10, requestedAt = requestedAt1))
        builder.applyRunEvent(approvalRequestFrame(runId, sequence = 10))
        assertTrue(builder.build().pendingApprovals.isEmpty())
        // An older captured approval with a later sampled durable watermark
        // still carries the retired native request version.
        builder.applySnapshot(snapshotPage(watermark = 11, requestedAt = requestedAt1))
        assertTrue(builder.build().pendingApprovals.isEmpty())
        builder.applySnapshot(snapshotPage(watermark = 12, requestedAt = requestedAt2))
        assertEquals(requestedAt2, builder.approvalVersion(callId))
        assertEquals(1, builder.build().pendingApprovals.size)
    }

    @Test
    fun terminalWithoutLiveOwnerRetiresActionsAndFencesOldPage() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 4, requestedAt = requestedAt1))
        builder.applySnapshot(snapshotPage(watermark = 6, state = "completed", terminal = true, liveOwner = false))
        assertTrue(builder.build().pendingApprovals.isEmpty())
        builder.applySnapshot(snapshotPage(watermark = 5, requestedAt = requestedAt1))
        assertTrue(builder.build().pendingApprovals.isEmpty())
    }

    @Test
    fun oldOutcomeCannotRetireNewRequestForSameCall() {
        val builder = builderFor(runId)
        builder.applySnapshot(snapshotPage(watermark = 20, requestedAt = requestedAt2))
        builder.applyRunEvent(approvalOutcomeFrame(runId, sequence = 10))
        assertEquals(1, builder.build().pendingApprovals.size)
        assertEquals(requestedAt2, builder.approvalVersion(callId))
    }
}
