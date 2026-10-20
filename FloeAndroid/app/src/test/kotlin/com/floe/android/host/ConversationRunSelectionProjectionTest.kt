// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cold-selection projection regression (App producer fix).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json.
 *
 * Source proof: the native conversation snapshot orders runs NEWEST-FIRST
 * (`SELECT ... ORDER BY started_at DESC, id`, RuntimeFacadeConversations.swift
 * ~L2074-2078, E3-hash-matched). The pre-fix `applySession` selected
 * `reply.runs.lastOrNull()` — the OLDEST run — so a force-stop/reopen after a
 * checkpointed round rendered the stale completed round with no Continue,
 * even though the persisted newest run was retryable. These tests pin the
 * corrected selection semantics against the REAL decoder and builder.
 */
class ConversationRunSelectionProjectionTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val newestRunId = "33333333-3333-4333-8333-333333333333"
    private val oldestRunId = "22222222-2222-4222-8222-222222222222"
    private val vanishedRunId = "99999999-9999-4999-8999-999999999999"

    /**
     * Core-shaped reply: two runs in `started_at DESC` wire order — the
     * checkpointed NEWEST round first, the older completed round last.
     */
    private fun twoRunReply(): String =
        """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-9"},""" +
            """"runs":[""" +
            """{"runID":"$newestRunId","state":"checkpointed",""" +
            """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-20T02:00:00.000Z"},""" +
            """{"runID":"$oldestRunId","state":"completed",""" +
            """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-20T01:00:00.000Z"}],""" +
            """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

    private fun singleRunReply(runID: String, state: String): String =
        """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-9"},""" +
            """"runs":[{"runID":"$runID","state":"$state",""" +
            """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-20T02:00:00.000Z"}],""" +
            """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

    private fun decode(json: String) =
        ConversationWire.decodeSessionReply(
            Json.parseToJsonElement(json).jsonObject)!!

    /** Cold open on a checkpointed tail must select the NEWEST run. */
    @Test
    fun coldSnapshotSelectsTheNewestRunAndOffersContinue() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(twoRunReply()))
        // Newest-first wire order: the FIRST row is the latest run; the
        // pre-fix lastOrNull() pinned the OLDEST row here.
        assertEquals(newestRunId, builder.selectedRunId)
        val state = builder.build()
        assertEquals("checkpointed", state.liveStateName)
        assertFalse("a checkpointed row is not live work", state.isRunning)
        // Honest persisted state: the retryable tail offers Continue. No
        // fabricated paused flag, no auto-resume — the durable row owns both.
        assertTrue(state.canContinue)
        assertEquals("Continue", state.continuationTitle)
    }

    /** A refresh never jumps away from a still-valid explicit selection. */
    @Test
    fun refreshKeepsAnExistingValidSelection() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(twoRunReply()))
        assertEquals(newestRunId, builder.selectedRunId)
        // The user explicitly selected the older round (⇄ iOS selection).
        builder.selectedRunId = oldestRunId
        builder.applySession(decode(twoRunReply()))
        assertEquals(oldestRunId, builder.selectedRunId)
    }

    /** Selection only falls back when the selected run vanished from the page. */
    @Test
    fun refreshReplacesSelectionOnlyWhenRunAbsentFromPage() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(twoRunReply()))
        builder.selectedRunId = vanishedRunId
        builder.applySession(decode(twoRunReply()))
        assertEquals(newestRunId, builder.selectedRunId)
    }

    /**
     * A launch-prepared selection (the newest run) survives the action-time
     * conversation.get refresh while that run exists in the page — the
     * second-send fresh read must not jump back to an older row.
     */
    @Test
    fun preparedSelectionSurvivesRefreshWhileRunPresent() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(twoRunReply()))
        val prepared = ConversationWire.preparedFromEffect(
            mapOf(
                "conversationID" to conversationId,
                "runID" to newestRunId,
                "resourceID" to "run.${newestRunId.uppercase()}",
                "version" to "preparing",
            ),
        )!!
        builder.applyPrepared(prepared)
        assertEquals(newestRunId, builder.selectedRunId)
        // The second-send action-time read carries both durable rows.
        builder.applySession(decode(twoRunReply()))
        assertEquals(newestRunId, builder.selectedRunId)
    }

    /** Empty page keeps an empty selection; a lone row is selected as-is. */
    @Test
    fun emptyPageKeepsSelectionAndSingleRunSelectsIt() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(twoRunReply()))
        builder.applySession(
            decode(
                """{"conversationID":"$conversationId","title":"Task",""" +
                    """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
                    """"version":"digest-10"},"runs":[],"pendingInputs":[]}""",
            ),
        )
        // No rows: the previous selection is not clobbered with null.
        assertEquals(newestRunId, builder.selectedRunId)

        val fresh = ThreadProjectionBuilder(conversationId)
        fresh.applySession(decode(singleRunReply(newestRunId, "completed")))
        assertEquals(newestRunId, fresh.selectedRunId)
    }
}
