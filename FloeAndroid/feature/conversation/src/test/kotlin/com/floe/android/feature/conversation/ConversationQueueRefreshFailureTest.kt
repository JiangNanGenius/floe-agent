// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationQueueRefreshFailureTest {
    private class RefreshHost(val ordinary: RecordingHost = RecordingHost()) :
        ConversationUiCallbacks by ordinary {
        var accepted = true
        val reads = mutableListOf<Pair<ConversationSessionToken, String>>()

        override fun refreshQueuedInputProjection(
            session: ConversationSessionToken,
            expectedFailureToken: String,
        ): Boolean {
            reads += session to expectedFailureToken
            return accepted
        }
    }

    @Test
    fun completedRunRetainsIndependentFailureAndDispatchesReadOnlyRefresh() {
        val host = RefreshHost()
        val holder = ConversationFlowHolder(host, "queue-conversation")
        holder.applyHostSnapshot(threadState(holder.session, canContinue = false,
            runStateName = "completed", selectedRunId = "finished-run"))
        holder.noteHostActionError("Unrelated action failed")
        holder.noteQueueRefreshFailure("failure-1")

        assertFalse(holder.snapshot.value!!.canContinue)
        assertEquals("failure-1", holder.queueRefreshFailureToken)
        assertTrue(holder.retryQueueRefresh())
        assertEquals(listOf(holder.session to "failure-1"), host.reads)
        // Successful dispatch is not an authoritative read success.
        assertEquals("failure-1", holder.queueRefreshFailureToken)
        assertEquals("Unrelated action failed", holder.actionError)
        assertEquals(0, host.ordinary.count("retryRun"))
        assertEquals(0, host.ordinary.count("startRun"))
        assertEquals(0, host.ordinary.count("cancelRun"))
        holder.dismissActionError()
        assertNull(holder.actionError)
        assertEquals("failure-1", holder.queueRefreshFailureToken)
    }

    @Test
    fun failedReadRetryPersistsAndOldSuccessCannotClearNewFailure() {
        val host = RefreshHost().apply { accepted = false }
        val holder = ConversationFlowHolder(host, "queue-conversation")
        holder.noteHostActionError("Keep this unrelated error")
        holder.noteQueueRefreshFailure("old-read")
        assertFalse(holder.retryQueueRefresh())
        assertEquals("old-read", holder.queueRefreshFailureToken)
        holder.noteQueueRefreshFailure("new-read")
        assertFalse(holder.clearQueueRefreshFailure("old-read"))
        assertEquals("new-read", holder.queueRefreshFailureToken)
        assertTrue(holder.clearQueueRefreshFailure("new-read"))
        assertNull(holder.queueRefreshFailureToken)
        assertEquals("Keep this unrelated error", holder.actionError)
    }

    @Test
    fun viewDetachKeepsFailureButRebindAndRetirementFenceItsLifetime() {
        val host = RefreshHost()
        val holder = ConversationFlowHolder(host, "first-conversation")
        holder.noteQueueRefreshFailure("first-read")
        holder.detach()
        assertEquals("first-read", holder.queueRefreshFailureToken)
        holder.rebind("second-conversation")
        assertNull(holder.queueRefreshFailureToken)
        holder.noteQueueRefreshFailure("second-read")
        holder.retireForNavigation()
        assertNull(holder.queueRefreshFailureToken)
        holder.noteQueueRefreshFailure("late-read")
        assertNull(holder.queueRefreshFailureToken)
        assertFalse(holder.retryQueueRefresh())
        assertFalse(holder.clearQueueRefreshFailure("late-read"))
        assertTrue(host.reads.isEmpty())
    }

    @Test
    fun existingHostWithoutRefreshImplementationRefusesAndKeepsFailure() {
        val holder = ConversationFlowHolder(RecordingHost(), "legacy-host")
        holder.noteQueueRefreshFailure("unavailable-read")
        assertFalse(holder.retryQueueRefresh())
        assertEquals("unavailable-read", holder.queueRefreshFailureToken)
    }

    @Test
    fun internalQueueNoticeIsInvisibleWhileOrdinaryNoticesRemainEligible() {
        val internal = RunEventUi("internal", "run-1", 10, RunEventKindUi.NOTICE,
            "", statusReason = "queueSettled")
        val ordinary = internal.copy(id = "ordinary", sequence = 11,
            statusReason = "connectionRestored", message = "Connection restored")
        val withMessage = internal.copy(id = "message", sequence = 12,
            message = "A real user-visible notice")
        val status = internal.copy(id = "terminal-state", sequence = 13,
            kind = RunEventKindUi.STATUS, stateName = "checkpointed")
        val displayed = listOf(internal, internal.copy(id = "blank", message = " "),
            ordinary, withMessage, status).filterNot(::isInternalQueueRefreshNotice)
        assertEquals(listOf("ordinary", "message", "terminal-state"), displayed.map { it.id })
    }
}
