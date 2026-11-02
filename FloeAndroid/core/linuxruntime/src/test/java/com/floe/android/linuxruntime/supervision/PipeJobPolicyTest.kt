// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AUTHORED NOT RUN — bounds for the C01 no-PTY stdio workload.
 *
 * The stdout ring must be able to hold one MAXIMUM protocol line (2 MiB) plus
 * headroom, otherwise a conforming client could lose a complete line and the
 * hard desynchronization rule would fire on valid traffic. stderr is smaller
 * by design (diagnostics). Admission gains the two managed-service slots on
 * top of the historical two interactive + one shared execution slot.
 */
class PipeJobPolicyTest {

    @Test
    fun `stdout ring holds one maximum protocol line plus headroom`() {
        val policy = PipeJobPolicy()
        val maximumLine = 2 * 1024 * 1024
        assertTrue(policy.maxRetainedStdoutBytes > maximumLine)
        assertTrue(policy.maxRetainedStdoutBytes <= BoundedOutputRing.MAX_CAPACITY)
        assertTrue(policy.maxRetainedStderrBytes <= policy.maxRetainedStdoutBytes)
        assertTrue(policy.maxReadWaitMs <= 1_000)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a stdout ring above the engine maximum is refused`() {
        PipeJobPolicy(maxRetainedStdoutBytes = BoundedOutputRing.MAX_CAPACITY + 1)
    }

    @Test
    fun `the concurrent pool includes both service slots`() {
        val admission = WorkloadAdmission.concurrent
        assertEquals(5, admission.maxConcurrent)
        assertEquals(2, WorkloadRole.SERVICE.maximumConcurrent)
        assertEquals(3, WorkloadRole.entries
            .filter { it != WorkloadRole.SERVICE }
            .sumOf { it.maximumConcurrent } - 1) // Agent + Run share one slot
        assertTrue(admission.enforceStraySweep.not())
    }

    @Test
    fun `independent page cursors are per stream`() {
        val stdout = BoundedOutputRing(1024).apply { append("out".toByteArray()) }
        val stderr = BoundedOutputRing(1024).apply { append("err".toByteArray()) }
        val stdoutPage = stdout.read(0, 16)
        val stderrPage = stderr.read(0, 16)
        assertEquals("out", String(stdoutPage.bytes))
        assertEquals("err", String(stderrPage.bytes))
        assertEquals(3L, stdoutPage.nextCursor)
        assertEquals(3L, stderrPage.nextCursor)
        assertEquals(0L, stdoutPage.gapBytes)
        assertEquals(0L, stderrPage.gapBytes)
    }
}
