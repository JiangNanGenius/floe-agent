// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Task Center single-row action failure surface (regression for the silent
 * dialog-close).
 *
 * Authored NOTRUN — source-authored only; Main runs the focused module JVM
 * filter named in SOURCE_READY.json.
 *
 * Before the repair a synchronous host refusal (`host.deleteConversation`
 * returning false: the runtime/conversation domain is not admitted) closed
 * the confirmation dialog and published NOTHING: no failure, no success —
 * the exact user-visible silent no-op. The host now shows only what really
 * happened, through the existing typed `holder.actionError` channel that the
 * destination renders as the localized failure banner. Async settlements
 * (rejected/failed/staleRevision) already publish through the same holder
 * state via the host controller; these cases pin the synchronous half and
 * the no-false-alarm success half.
 */
class ConversationHistoryDeleteSurfaceTest {

    /** Records and REFUSES every single-row lifecycle mutation, modelling
     *  `conversationAdmitted() == false` on the host side. */
    private class RefusingHost : ConversationUiCallbacks by RecordingHost() {
        override fun deleteConversation(conversationId: String): Boolean = false
        override fun archiveConversation(conversationId: String): Boolean = false
        override fun restoreConversation(conversationId: String): Boolean = false
    }

    @Test
    fun refusedSingleDeletionPublishesTheTypedFailureInsteadOfSilence() {
        val h = ConversationHistoryHolder(RefusingHost())
        h.requestSingleDeletion("conv-3")

        val result = h.confirmSingleDeletion()

        assertTrue(
            "host refusal maps to the existing rejected result",
            result is ConversationFlowResult.Rejected &&
                (result as ConversationFlowResult.Rejected).reason ==
                ConversationRejectedReason.HOST_UNAVAILABLE,
        )
        // The dialog identity is still cleared (no replay), but the failure
        // is now VISIBLE through the one typed channel the banner renders.
        assertNull(h.pendingDeletionId.value)
        assertEquals("runtime_unavailable", h.actionError)
    }

    @Test
    fun refusedArchiveAndRestorePublishTheSameTypedFailure() {
        val h = ConversationHistoryHolder(RefusingHost())

        assertTrue(h.archiveConversation("conv-1") is ConversationFlowResult.Rejected)
        assertEquals("runtime_unavailable", h.actionError)

        h.dismissActionError()
        assertNull(h.actionError)

        assertTrue(h.restoreConversation("conv-2") is ConversationFlowResult.Rejected)
        assertEquals("runtime_unavailable", h.actionError)
    }

    @Test
    fun admittedDeletionStaysSilentUntilARealSettlement() {
        // RecordingHost accepts the dispatch (returns true): the holder must
        // NOT invent any failure line — success truth belongs to the async
        // settlement lane only.
        val h = ConversationHistoryHolder(RecordingHost())
        h.requestSingleDeletion("conv-3")

        val result = h.confirmSingleDeletion()

        assertTrue(result is ConversationFlowResult.Accepted)
        assertNull(h.actionError)
        assertNull(h.pendingDeletionId.value)
    }
}
