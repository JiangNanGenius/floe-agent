// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * History row Pin/Unpin holder wiring (schema v50).
 *
 * Authored NOTRUN — source-authored only; Main runs the focused module JVM
 * filter.
 *
 * The holder must NOT toggle a local flag: it dispatches the exact
 * conversation id + desired durable state to the host, which owns the CAS,
 * persistence and the native reloaded (pinned-first) order. A synchronous
 * host refusal surfaces the same honest action-error banner the other
 * single-row lifecycle actions use.
 */
class ConversationHistoryPinHolderTest {

    private class RefusingPinHost : ConversationUiCallbacks by RecordingHost() {
        override fun setConversationPinned(conversationId: String, pinned: Boolean): Boolean = false
    }

    @Test
    fun pinAndUnpinDispatchTheExactIdentityAndDesiredState() {
        val host = RecordingHost()
        val holder = ConversationHistoryHolder(host)

        assertTrue(holder.setPinned("conv-pin", true) is ConversationFlowResult.Accepted)
        assertTrue(holder.setPinned("conv-pin", false) is ConversationFlowResult.Accepted)

        assertEquals(2, host.count("setConversationPinned"))
        assertEquals(listOf<Any?>("conv-pin", true),
            host.effects.first { it.name == "setConversationPinned" }.args)
        assertEquals(listOf<Any?>("conv-pin", false),
            host.effects.last { it.name == "setConversationPinned" }.args)
        assertNull("no local error for an accepted dispatch", holder.actionError)
    }

    @Test
    fun hostRefusalPublishesTheTypedFailureInsteadOfFlippingALocalFlag() {
        val holder = ConversationHistoryHolder(RefusingPinHost())

        val result = holder.setPinned("conv-refused", true)

        assertTrue(result is ConversationFlowResult.Rejected)
        assertEquals("runtime_unavailable", holder.actionError)
    }

    @Test
    fun itemPinStateDefaultsUnpinnedAndSurvivesCopies() {
        val item = ConversationListItemUi(
            id = "conv-1",
            title = "Task",
            updatedAtLabel = "now",
            projectedStateName = null,
            isArchived = false,
            archivedAtLabel = null,
        )
        assertFalse(item.isPinned)

        val pinned = item.copy(isPinned = true)
        assertTrue(pinned.isPinned)
        assertEquals(item.id, pinned.id)
    }
}
