// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.FloeContinuationPresentation
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reproduces native user-Stop status followed by an unrelated carrier failure. */
class ConversationContinuationCauseProjectionTest {
    private val task = "40000000-0000-0000-0000-000000000001"
    private val run = "40000000-0000-0000-0000-000000000002"
    private val other = "40000000-0000-0000-0000-000000000003"
    private val stopped = "runtime.agent_runtime.the_task_was_stopped_by_you"

    private fun snapshot(
        state: String, reason: String? = null, sequence: Long = 446, runID: String = run,
    ): ConversationWire.SnapshotPage {
        val values = linkedMapOf(
            "runID" to JsonPrimitive(runID),
            "durableState" to JsonPrimitive(state),
            "durableWatermark" to JsonPrimitive(sequence),
            "revision" to JsonObject(mapOf(
                "resourceID" to JsonPrimitive("run.$runID"),
                "version" to JsonPrimitive(state),
            )),
        )
        if (reason != null) values["checkpointReason"] = JsonPrimitive(reason)
        return ConversationWire.decodeSnapshotPage(JsonObject(values))!!
    }

    private fun status(state: String, reason: String?, sequence: Long = 445): HostRunEventFrame {
        val values = linkedMapOf("state" to JsonPrimitive(state))
        if (reason != null) values["reason"] = JsonPrimitive(reason)
        return HostRunEventFrame(run, sequence, "status", JsonObject(values), 256)
    }

    private fun builder() = ThreadProjectionBuilder(task).apply { selectedRunId = run }

    @Test
    fun userStopIsNotReplacedByFrameBudgetFailure() {
        val builder = builder()
        builder.applyRunEvent(status("checkpointed", stopped))
        builder.eventStreamFailure(run, "frameBudgetExceeded")
        val state = builder.build()
        assertTrue(state.canContinue)
        assertFalse(state.isRunning)
        assertEquals(stopped, state.continuationReasonRaw)
        assertEquals("state_stopped", FloeContinuationPresentation.titleKey(state.liveStateName, state.continuationReasonRaw))
        assertEquals("the actual read failure stays available", "frameBudgetExceeded", state.continuationDetail)
    }

    @Test
    fun coldJournalRestoresCauseAndRetiredSnapshotCannotEraseIt() {
        val builder = builder()
        builder.applySnapshot(snapshot("checkpointed"))
        builder.applyRecordedEvents(run, listOf(status("checkpointed", stopped)), false)
        builder.applySnapshot(snapshot("checkpointed", sequence = 537))
        assertEquals(stopped, builder.build().continuationReasonRaw)
    }

    @Test
    fun snapshotReadsOriginalCheckpointReasonWithoutInventingTransportCause() {
        val builder = builder()
        builder.applySnapshot(snapshot("checkpointed", stopped))
        assertEquals(stopped, builder.build().continuationReasonRaw)
        assertNull(builder.build().continuationDetail)
    }

    @Test
    fun olderJournalAndSnapshotCannotOverwriteNewCause() {
        val builder = builder()
        val cause = "awaiting.finite.job:owned-job"
        builder.applyRunEvent(status("checkpointed", cause, 536))
        builder.applyRecordedEvents(run, listOf(status("checkpointed", stopped, 335)), true)
        builder.applySnapshot(snapshot("checkpointed", stopped, 446))
        assertEquals(cause, builder.build().continuationReasonRaw)
        assertEquals("state_waiting_background_work", FloeContinuationPresentation.titleKey("checkpointed", cause))
        assertTrue(builder.build().selectedRunWaitingForJobs)
        assertFalse("native dependency waits reject manual retry", builder.build().canContinue)
    }

    @Test
    fun anotherRunsReadFailureDoesNotBecomeSelectedRunsReasonOrError() {
        val builder = builder()
        builder.applySnapshot(snapshot("checkpointed", stopped))
        builder.eventStreamFailure(other, "frameBudgetExceeded")
        assertEquals(stopped, builder.build().continuationReasonRaw)
        assertNull(builder.build().continuationDetail)
        builder.applySnapshot(snapshot("failed", runID = other))
        builder.selectedRunId = other
        assertNull(builder.build().continuationReasonRaw)
        assertEquals("frameBudgetExceeded", builder.build().continuationDetail)
    }

    @Test
    fun resumedRunDoesNotReusePriorStopCauseForItsNextCheckpoint() {
        val builder = builder()
        builder.applyRunEvent(status("checkpointed", stopped))
        builder.applyRunEvent(status("preparing", null, 447))
        assertFalse(builder.build().canContinue)
        assertNull(builder.build().continuationReasonRaw)
        builder.applyRunEvent(status("checkpointed", "awaiting.finite.job:next", 480))
        assertEquals("awaiting.finite.job:next", builder.build().continuationReasonRaw)
    }

    @Test
    fun realBudgetFailureAndUnknownReasonStayFailuresWithOriginalEvidence() {
        val builder = builder()
        builder.applyRunEvent(status("failed", "frameBudgetExceeded"))
        builder.eventStreamFailure(run, "frameBudgetExceeded")
        val state = builder.build()
        assertEquals("frameBudgetExceeded", state.continuationReasonRaw)
        assertEquals("frameBudgetExceeded", state.continuationDetail)
        assertEquals("state_failed", FloeContinuationPresentation.titleKey(state.liveStateName, state.continuationReasonRaw))
        assertEquals("state_failed", FloeContinuationPresentation.titleKey("failed", stopped))
    }

    @Test
    fun readRecoveryOnlyClearsItsExactFailureAndPreservesTaskCause() {
        val builder = builder()
        builder.applySnapshot(snapshot("checkpointed", stopped))
        builder.eventStreamFailure(run, "frameBudgetExceeded")
        builder.eventStreamRecovered(run, "eventWindowUnavailable")
        assertEquals("frameBudgetExceeded", builder.build().continuationDetail)
        builder.selectedRunId = other
        builder.eventStreamRecovered(run, "frameBudgetExceeded")
        builder.selectedRunId = run
        assertNull(builder.build().continuationDetail)
        assertEquals(stopped, builder.build().continuationReasonRaw)
    }

    @Test
    fun acceptedRetryRetainsOriginalStopCauseButDoesNotReuseOldReadFailure() {
        val builder = builder()
        builder.applySnapshot(snapshot("checkpointed", stopped))
        builder.eventStreamFailure(run, "frameBudgetExceeded")
        assertTrue(builder.rearmLiveTailForRetry(run))
        assertNull(builder.build().continuationDetail)
        assertEquals(stopped, builder.build().continuationReasonRaw)
        // The acceptance itself is not a fabricated completed/running state.
        assertEquals("checkpointed", builder.build().liveStateName)
    }
}
