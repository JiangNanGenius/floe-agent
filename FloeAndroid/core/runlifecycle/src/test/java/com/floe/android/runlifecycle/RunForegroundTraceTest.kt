// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.ObjectInputStream
import java.io.ObjectOutputStream
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class RunForegroundTraceTest {
    @Before fun begin() { RunForegroundTrace.resetForTesting() }
    @After fun end() { RunForegroundTrace.resetForTesting() }

    private fun attempt(origin: RunForegroundTrace.Origin = RunForegroundTrace.Origin.ORDINARY_OPERATION) =
        RunForegroundTrace.begin(origin, OperationKind.AGENT_RUN)

    @Test fun earlierFailureNoticeKeepsItsOwnAttemptAfterAnotherAcquireBegins() {
        val first = attempt(RunForegroundTrace.Origin.AGENT_LAUNCH_PROVISIONAL)
        val failure = RunForegroundFailure.StartDenied("private reason must not enter the trace")
        assertSame(failure, RunForegroundTrace.failed(first, RunForegroundTrace.Stage.SERVICE_START_REFUSED, failure))
        val second = attempt(RunForegroundTrace.Origin.AGENT_RUN_AUTHORITATIVE)
        RunForegroundTrace.mark(second, RunForegroundTrace.Stage.SERVICE_CONFIRMED)
        val posted = RunForegroundTrace.notice(failure, true)
        RunForegroundTrace.noticeBoundToUi(posted)
        assertEquals(first, posted.attempt)
        assertEquals(first, RunForegroundTrace.recent().last().attempt)
        assertEquals(second, RunForegroundTrace.lastOutcome()?.attempt)
    }

    @Test fun suppressedNoticeDoesNotReplaceTheCapturedOriginalAttribution() {
        val original = attempt()
        val failure = RunForegroundTrace.failed(original, RunForegroundTrace.Stage.CONFIRM_TIMEOUT,
            RunForegroundFailure.Unavailable("private timeout"))
        val shown = RunForegroundTrace.notice(failure, true)
        val later = attempt()
        RunForegroundTrace.notice(RunForegroundTrace.failed(later, RunForegroundTrace.Stage.OWNER_CONFLICT,
            RunForegroundFailure.OwnerConflict("private-owner", OperationKind.LOCAL_EXECUTION, OperationKind.AGENT_RUN)), false)
        RunForegroundTrace.noticeBoundToUi(shown)
        assertEquals(original, RunForegroundTrace.recent().last().attempt)
        assertEquals(RunForegroundTrace.FailureKind.UNAVAILABLE, RunForegroundTrace.recent().last().failure)
    }

    @Test fun untracedFailureIsUnknownInsteadOfBorrowingTheLastAcquire() {
        attempt()
        val posted = RunForegroundTrace.notice(RunForegroundFailure.Unavailable("not acquired here"), true)
        assertNull(posted.attempt)
        assertNull(RunForegroundTrace.recent().last().attempt)
    }

    @Test fun ownerAndReasonNeverEnterEmittedLinesOrClosedSnapshots() {
        val lines = mutableListOf<String>()
        RunForegroundTrace.logSinkForTesting = { lines += it }
        val owner = "private-owner-and-path"
        val failure = RunForegroundFailure.OwnerConflict(owner, OperationKind.LOCAL_EXECUTION, OperationKind.AGENT_RUN)
        RunForegroundTrace.notice(RunForegroundTrace.failed(attempt(), RunForegroundTrace.Stage.OWNER_CONFLICT, failure), true)
        assertTrue(lines.any { "OWNER_CONFLICT" in it })
        assertFalse(lines.joinToString().contains(owner))
        assertFalse(RunForegroundTrace.recent().joinToString().contains(owner))
        assertTrue(failure.message.orEmpty().contains(owner)) // Original exception semantics stay intact.
    }

    @Test fun optionalLogFailureCannotChangeOutcomeOrLoseTheFailureAssociation() {
        RunForegroundTrace.logSinkForTesting = { error("log transport unavailable") }
        val id = attempt()
        val original = RunForegroundFailure.NotificationsBlocked("private channel")
        val failure = RunForegroundTrace.failed(id, RunForegroundTrace.Stage.DENIAL_TYPED, original)
        assertSame(original, failure)
        assertEquals(id, RunForegroundTrace.notice(failure, true).attempt)
        assertEquals(RunForegroundTrace.FailureKind.NOTIFICATIONS_BLOCKED, RunForegroundTrace.lastOutcome()?.failure)
    }

    @Test fun historyIsBoundedAndSnapshotsAreDetached() {
        attempt()
        val snapshot = RunForegroundTrace.recent()
        repeat(100) { attempt() }
        assertEquals(RunForegroundTrace.HISTORY_CAPACITY, RunForegroundTrace.recent().size)
        assertEquals(1, snapshot.size)
        assertTrue(RunForegroundTrace.recent().zipWithNext().all { (a, b) -> a.attempt!!.sequence < b.attempt!!.sequence })
    }

    @Test fun concurrentAcquisitionsKeepUniqueSequenceAndBoundedStorage() {
        val pool = Executors.newFixedThreadPool(4)
        try {
            val ids = pool.invokeAll((1..100).map { Callable { attempt().sequence } }).map { it.get() }
            assertEquals(100, ids.toSet().size)
            assertEquals((1L..100L).toSet(), ids.toSet())
            assertEquals(RunForegroundTrace.HISTORY_CAPACITY, RunForegroundTrace.recent().size)
        } finally { pool.shutdownNow() }
    }

    @Test fun deliveredServiceDenialKeepsItsClosedCauseAndGainsTheExactWaiter() {
        val failure = RunForegroundTrace.serviceFailure(RunForegroundTrace.Stage.SERVICE_PROMOTION_REFUSED,
            RunForegroundTrace.Cause.PROMOTION_SECURITY_EXCEPTION, RunForegroundFailure.StartDenied("private detail"))
        assertNull(RunForegroundTrace.recent().last().attempt)
        val waiter = attempt()
        RunForegroundTrace.failed(waiter, RunForegroundTrace.Stage.DENIAL_TYPED, failure)
        val attribution = RunForegroundTrace.notice(failure, true)
        assertEquals(waiter, attribution.attempt)
        assertEquals(RunForegroundTrace.Cause.PROMOTION_SECURITY_EXCEPTION, attribution.cause)
    }

    @Test fun diagnosticAssociationIsNotPersistedWithTheOriginalException() {
        val failure = RunForegroundTrace.failed(attempt(), RunForegroundTrace.Stage.CONFIRM_TIMEOUT,
            RunForegroundFailure.Unavailable("unchanged"))
        val bytes = ByteArrayOutputStream().also { out -> ObjectOutputStream(out).use { it.writeObject(failure) } }.toByteArray()
        val restored = ObjectInputStream(ByteArrayInputStream(bytes)).use { it.readObject() as RunForegroundFailure }
        assertEquals(failure.message, restored.message)
        assertNull(RunForegroundTrace.notice(restored, true).attempt)
    }
}
