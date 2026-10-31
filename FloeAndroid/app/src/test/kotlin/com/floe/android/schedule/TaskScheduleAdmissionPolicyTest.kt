// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused lifecycle regressions for the dispatch worker's provisional
 * foreground lease:
 *
 *  * a cancellation/Stop BEFORE queue acceptance is a definite no-launch and
 *    releases the lease;
 *  * a cancellation AFTER acceptance is an unknown receipt and must be
 *    reconciled from the real terminal/occurrence ledger, never blindly
 *    released;
 *  * a real launched run is transferred to the authoritative lease;
 *  * the durable occurrence states decide adoption vs release.
 */
class TaskScheduleAdmissionPolicyTest {

    private fun dispatch(
        state: String,
        runID: String? = null,
        conversationID: String? = null,
    ) = TaskScheduleDispatch(
        state = state,
        scheduleID = "s1",
        occurrenceID = "o1",
        runID = runID,
        conversationID = conversationID,
        nextFireAtMillis = null,
        code = null,
        reason = null,
    )

    private fun occurrence(
        state: String,
        runID: String? = null,
        conversationID: String? = null,
    ) = TaskScheduleOccurrence(
        id = "o1",
        state = state,
        scheduledForMillis = 1_000L,
        startedAtMillis = null,
        finishedAtMillis = null,
        runID = runID,
        conversationID = conversationID,
        summary = null,
        errorText = null,
    )

    @Test
    fun aPreAdmissionStopOrCancellationIsADefiniteRelease() {
        val stopped = TaskScheduleAdmissionGuard()
        stopped.onStopRequested()
        assertTrue(stopped.stopRequested())
        assertFalse(stopped.wasSubmitted())
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            stopped.cancellationDecision(),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            stopped.effectiveDecision(
                TaskScheduleResult.Failure("superseded")),
        )

        val cancelled = TaskScheduleAdmissionGuard()
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            cancelled.cancellationDecision(),
        )
        // An unaccepted envelope can never launch, even when the mapped
        // failure would otherwise look uncertain.
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            cancelled.effectiveDecision(
                TaskScheduleResult.Failure("timeout")),
        )
    }

    @Test
    fun anAcceptedReceiptThatWasNotObservedIsReconciledNotReleased() {
        val guard = TaskScheduleAdmissionGuard()
        guard.onAccepted()
        assertTrue(guard.wasSubmitted())
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            guard.cancellationDecision(),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            guard.effectiveDecision(TaskScheduleResult.Failure("timeout")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            guard.effectiveDecision(TaskScheduleResult.Failure("cancelled")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            guard.effectiveDecision(TaskScheduleResult.Failure("malformed")),
        )
    }

    @Test
    fun aRealLaunchedTerminalTransfersCoverage() {
        assertEquals(
            TaskScheduleAdmissionDecision.ADMIT,
            TaskScheduleAdmissionPolicy.decision(
                TaskScheduleResult.Ok(dispatch("launched", "r1", "c1"))),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            TaskScheduleAdmissionPolicy.decision(
                TaskScheduleResult.Ok(dispatch("waiting"))),
        )
        // A definite native refusal before any launch is not an uncertain
        // receipt.
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            TaskScheduleAdmissionPolicy.decision(
                TaskScheduleResult.Failure("occurrenceInFlight")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            TaskScheduleAdmissionPolicy.decision(null),
        )
    }

    @Test
    fun theDurableOccurrenceLedgerDecidesAdoption() {
        assertEquals(
            TaskScheduleAdmissionDecision.ADMIT,
            TaskScheduleAdmissionPolicy.decisionForOccurrence(
                occurrence("running", "r1", "c1")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            TaskScheduleAdmissionPolicy.decisionForOccurrence(
                occurrence("claimed")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RECONCILE,
            TaskScheduleAdmissionPolicy.decisionForOccurrence(null),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            TaskScheduleAdmissionPolicy.decisionForOccurrence(
                occurrence("completed", "r1", "c1")),
        )
        assertEquals(
            TaskScheduleAdmissionDecision.RELEASE,
            TaskScheduleAdmissionPolicy.decisionForOccurrence(
                occurrence("pending")),
        )
    }

    @Test
    fun aCallerTimeoutDoesNotConsumeTheRealLateTerminal() = runBlocking {
        val sink = TaskScheduleTerminalSink<TaskScheduleDispatch>()
        // The caller's short observation window expires first: this is NOT a
        // terminal and must leave the sink unsettled.
        val observed = withTimeoutOrNull(50L) { sink.settled.await() }
        assertNull(observed)
        assertFalse(sink.settled.isCompleted)

        // The host effect pump settles the SAME command later.
        val real = TaskScheduleResult.Ok(dispatch("launched", "r1", "c1"))
        assertTrue(sink.deliver(real))
        assertEquals(real, sink.settled.await())
        // A duplicate/late terminal cannot rewrite the first one.
        assertFalse(sink.deliver(TaskScheduleResult.Failure("superseded")))
    }

    @Test
    fun theRealTerminalIsDeliveredToTheLateResolverExactlyOnce() = runBlocking {
        val guard = TaskScheduleAdmissionGuard()
        val first = TaskScheduleResult.Ok(dispatch("launched", "r1", "c1"))
        val second = TaskScheduleResult.Failure("superseded")
        guard.recordSettled(first)
        guard.recordSettled(second)
        assertEquals(first, guard.settled.await())
    }
}
