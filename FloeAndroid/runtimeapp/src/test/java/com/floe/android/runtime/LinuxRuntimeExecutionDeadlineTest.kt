// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AUTHORED NOT RUN regressions for the engine half of the actual 2026-10-31
 * cold-start command timeout (job-e58fe0969b844445).
 *
 * The real device log reported `materialize=38087ms` followed by
 * `spawn=137ms bind=2ms run=151ms` and a real exit. The host tool nevertheless
 * reported `exit=124 ... effectiveTimeoutSeconds=10.0` because the CLIENT
 * deadline had been anchored before `shell.start`. On the engine side the
 * command deadline must begin at real execution admission (the accepted
 * spawn), so preparation can never be charged to the command.
 *
 * These tests drive the PURE clock-injected anchor only: no Android, no
 * runtime process, no PTY, no provider and no device.
 */
class LinuxRuntimeExecutionDeadlineTest {

    @Test
    fun commandDeadlineStartsAtAdmissionNotAtPreparation() {
        val preparedAt = 1_000_000L          // request/dispatch start
        val admittedAt = preparedAt + 38_087L // cold materialize completes
        val deadline = LinuxRuntimeOperations.executionDeadlineMillis(admittedAt, 10.0)
        assertEquals("the requested 10 s starts at admission", admittedAt + 10_000L, deadline)
        assertTrue("38 s of preparation must never consume the command budget",
            deadline >= admittedAt + 10_000L)
        assertTrue("preparation time is not part of the deadline",
            deadline - admittedAt == 10_000L)
    }

    @Test
    fun everyAcceptedTimeoutShapeUsesTheAdmissionAnchor() {
        for (seconds in listOf(0.05, 0.1, 1.0, 10.0, 120.0, 600.0)) {
            val admittedAt = 5_000_000L
            val expected = admittedAt + (seconds * 1000.0).toLong()
            assertEquals("timeout=$seconds", expected,
                LinuxRuntimeOperations.executionDeadlineMillis(admittedAt, seconds))
        }
    }

    @Test
    fun deadlineIsNeverAnchoredBeforeAdmission() {
        val admittedAt = 12_345_678L
        for (seconds in listOf(0.05, 1.0, 600.0)) {
            val deadline = LinuxRuntimeOperations.executionDeadlineMillis(admittedAt, seconds)
            assertTrue("timeout=$seconds may not retract before admission",
                deadline >= admittedAt)
        }
    }

    @Test
    fun zeroAndNegativeElapsedInputsStayMonotonicForTests() {
        // The production caller passes a real non-negative elapsedRealtime
        // reading; this pins that the helper adds (never subtracts) the
        // requested budget.
        assertEquals(10_000L,
            LinuxRuntimeOperations.executionDeadlineMillis(0L, 10.0))
        assertEquals(0L,
            LinuxRuntimeOperations.executionDeadlineMillis(0L, 0.0))
    }
}
