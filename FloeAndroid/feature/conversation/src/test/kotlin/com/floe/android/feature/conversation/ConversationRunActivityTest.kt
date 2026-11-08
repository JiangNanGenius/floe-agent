// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.*
import org.junit.Test

class ConversationRunActivityTest {
    @Test
    fun backgroundOwnerIsNotifiedFromCanonicalStateWithoutAViewOrHistoryRefresh() {
        lateinit var holder: ConversationFlowHolder
        val seen = mutableListOf<Pair<Boolean, String?>>()
        holder = ConversationFlowHolder(RecordingHost(), "background", onRunActivityChanged = {
            seen += holder.snapshot.value!!.let { it.isRunning to it.selectedRunId }
        })
        holder.applyHostSnapshot(threadState(holder.session, isRunning = true))
        holder.applyHostSnapshot(threadState(holder.session, isRunning = true, liveAssistantText = "streaming"))
        assertEquals(listOf(true to "run-1"), seen)

        holder.applyHostSnapshot(threadState(holder.session, isRunning = false, selectedRunId = "run-1"))
        assertEquals(listOf(true to "run-1", false to "run-1"), seen)
    }

    @Test
    fun foreignOrStaleSnapshotsCannotSignalThatTheCurrentRunEnded() {
        var calls = 0
        val holder = ConversationFlowHolder(RecordingHost(), "current", onRunActivityChanged = { calls++ })
        holder.applyHostSnapshot(threadState(holder.session, isRunning = true))
        holder.applyHostSnapshot(threadState(ConversationSessionToken("foreign", holder.session.sessionEpoch)))
        holder.applyHostSnapshot(threadState(ConversationSessionToken("current", holder.session.sessionEpoch + 1)))
        assertEquals(1, calls)
        assertTrue(holder.snapshot.value!!.isRunning)

        holder.applyHostSnapshot(threadState(holder.session, isRunning = true, selectedRunId = "run-2"))
        assertEquals(2, calls)
        assertEquals("run-2", holder.snapshot.value!!.selectedRunId)
    }

    @Test
    fun retiringTheHolderSignalsItsDiscardAndNeverAcceptsLateOldRunState() {
        var calls = 0
        val holder = ConversationFlowHolder(RecordingHost(), "retire", onRunActivityChanged = { calls++ })
        val old = holder.session
        holder.applyHostSnapshot(threadState(old, isRunning = true))
        holder.retireForNavigation()
        assertEquals(2, calls)
        assertNull(holder.snapshot.value)
        holder.applyHostSnapshot(threadState(old, isRunning = true))
        assertEquals(2, calls)
        assertNull(holder.snapshot.value)
    }
}
