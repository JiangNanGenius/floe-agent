// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

class ShellStopReasonTest {
    @Test fun timeoutRemainsFirstWhenWatcherRepeatsUserStop() {
        val latch = ShellStopReasonLatch()
        assertNull(latch.reason)
        assertEquals(ShellStopReason.TIMEOUT, latch.capture(ShellStopReason.TIMEOUT))
        assertEquals(ShellStopReason.TIMEOUT, latch.capture(ShellStopReason.USER_STOP))
    }

    @Test fun humanStopRemainsFirstWhenADeadlineArrivesLater() {
        val latch = ShellStopReasonLatch()
        assertEquals(ShellStopReason.USER_STOP, latch.capture(ShellStopReason.USER_STOP))
        assertEquals(ShellStopReason.USER_STOP, latch.capture(ShellStopReason.TIMEOUT))
    }

    @Test fun parserAcceptsOnlyTheClosedWireReasons() {
        assertEquals(ShellStopReason.TIMEOUT, ShellStopReason.fromWire("timeout"))
        assertEquals(ShellStopReason.USER_STOP, ShellStopReason.fromWire("user-stop"))
        for (bad in listOf(null, "", "TIMEOUT", "cancelled", " timeout", "all", "start-binding-failed")) {
            assertNull(ShellStopReason.fromWire(bad))
        }
    }

    @Test fun runtimeBindingFailureSurvivesLaterCleanupRequests() {
        val latch = ShellStopReasonLatch()
        assertEquals(ShellStopReason.START_BINDING_FAILED, latch.capture(ShellStopReason.START_BINDING_FAILED))
        assertEquals(ShellStopReason.START_BINDING_FAILED, latch.capture(ShellStopReason.USER_STOP))
        assertEquals(ShellStopReason.START_BINDING_FAILED, latch.capture(ShellStopReason.TIMEOUT))
    }

    @Test fun concurrentRequestsAllObserveTheSameFirstCause() {
        val latch = ShellStopReasonLatch()
        val start = CountDownLatch(1)
        val observed = ConcurrentLinkedQueue<ShellStopReason>()
        val callers = (0 until 16).map { index ->
            thread(start = true) {
                start.await()
                observed.add(latch.capture(
                    if (index % 2 == 0) ShellStopReason.TIMEOUT else ShellStopReason.USER_STOP))
            }
        }
        start.countDown()
        callers.forEach { it.join() }
        assertEquals(16, observed.size)
        assertEquals(setOf(latch.reason), observed.toSet())
    }
}
