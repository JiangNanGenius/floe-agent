// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.*
import org.junit.Test

class ConversationExportAdmissionTest {
    private fun holder(host: RecordingHost) = ConversationFlowHolder(host, "export-fixture").also {
        it.applyHostSnapshot(threadState(it.session))
    }

    @Test fun aRefusedExportHasFeedbackAndCanBeExplicitlyTriedAgain() {
        val host = RecordingHost().apply { exportAccepted = false }
        val holder = holder(host)
        val message = "Reopen this task and try again."

        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE),
            holder.exportStructured(message))
        assertEquals(message, holder.actionError)
        assertFalse(holder.exportInFlight)
        assertEquals(1, host.count("exportStructuredConversation"))

        host.exportAccepted = true
        assertEquals(ConversationFlowResult.Accepted, holder.exportStructured(message))
        assertTrue(holder.exportInFlight)
        assertNull(holder.actionError)
        assertEquals(2, host.count("exportStructuredConversation"))
    }

    @Test fun anInFlightExportCannotDispatchTwiceOrLoseItsFailureDuringCleanup() {
        val host = RecordingHost()
        val holder = holder(host)
        assertEquals(ConversationFlowResult.Accepted, holder.exportStructured("Unavailable"))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT),
            holder.exportStructured("Unavailable"))
        assertEquals(1, host.count("exportStructuredConversation"))
        assertNull(holder.actionError)

        holder.applyExportSettled("Export failed")
        holder.applyExportSettled(null)
        assertFalse(holder.exportInFlight)
        assertEquals("Export failed", holder.actionError)
    }
}
