package com.floe.android.schedule

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class TaskScheduleConditionPolicyTest {
    @Test fun debounceUsesUptimeAndDoesNotSuppressTheFirstPostBootEdge() {
        assertFalse(TaskScheduleConditionPolicy.risingEdge(false, true, 40_000, 20_000, true))
        assertTrue(TaskScheduleConditionPolicy.risingEdge(false, true, 50_000, 20_000, true))
        assertTrue(TaskScheduleConditionPolicy.risingEdge(false, true, 40_000, 20_000, false))
        assertTrue(TaskScheduleConditionPolicy.risingEdge(false, true, 1000, 20_000, true))
        assertTrue(TaskScheduleConditionPolicy.risingEdge(false, true, 1000, null, true))
        assertFalse(TaskScheduleConditionPolicy.risingEdge(true, true, 100_000, null, false))
    }

    @Test fun fullQueueMakesRoomWithoutLosingOriginalOrNewEvents() = runBlocking {
        val queue = mutableListOf("original-a", "original-b")
        val sent = mutableListOf<String>()
        var newestPersisted = false
        val done = TaskScheduleConditionPolicy.drain(
            observe = {
                if (queue.size >= 2) ConditionObservation.QUEUE_FULL
                else {
                    if (!newestPersisted) { queue += "new-edge"; newestPersisted = true }
                    ConditionObservation.DURABLE
                }
            },
            peek = { queue.firstOrNull() },
            acknowledge = { queue.remove(it) },
            submit = { sent += it; true },
        )
        assertTrue(done)
        assertEquals(listOf("original-a", "original-b", "new-edge"), sent)
        assertTrue(queue.isEmpty())
    }

    @Test fun uncertainNativeReplyKeepsTheSamePendingIdentity() = runBlocking {
        val queue = mutableListOf("stable-event-id")
        assertFalse(TaskScheduleConditionPolicy.drain(
            observe = { ConditionObservation.DURABLE }, peek = { queue.firstOrNull() },
            acknowledge = { queue.remove(it) }, submit = { false },
        ))
        assertEquals(listOf("stable-event-id"), queue)
    }

    @Test fun failedPersistenceCannotStartOrAcknowledgeAnEvent() = runBlocking {
        var submitted = false
        var acknowledged = false
        assertFalse(TaskScheduleConditionPolicy.drain(
            observe = { ConditionObservation.STORAGE_UNAVAILABLE }, peek = { "event" },
            acknowledge = { acknowledged = true; true }, submit = { submitted = true; true },
        ))
        assertFalse(submitted); assertFalse(acknowledged)
    }

    @Test fun onlyAProvenFutureTimestampRejectionCanBeRetired() {
        assertTrue(TaskScheduleConditionPolicy.clockRejected("cadenceInvalid", 200_000, 100_000))
        assertFalse(TaskScheduleConditionPolicy.clockRejected("timeout", 200_000, 100_000))
        assertFalse(TaskScheduleConditionPolicy.clockRejected("storeUnavailable", 200_000, 100_000))
        assertFalse(TaskScheduleConditionPolicy.clockRejected("cadenceInvalid", 150_000, 100_000))
    }
}
