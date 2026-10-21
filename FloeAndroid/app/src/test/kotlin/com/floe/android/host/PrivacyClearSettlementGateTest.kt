// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivacyClearSettlementGateTest {
    @Test
    fun terminalPublicationKeepsOwnershipUntilEveryMutationFinishes() {
        val gate = PrivacyClearSettlementGate()
        val first = requireNotNull(gate.acquire())
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val threadFailure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        val thread = Thread {
            try {
                gate.finish(first) {
                    entered.countDown()
                    check(release.await(3, TimeUnit.SECONDS))
                }
            } catch (failure: Throwable) {
                threadFailure.set(failure)
            } finally {
                finished.countDown()
            }
        }
        thread.start()
        try {
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            assertNull(gate.acquire())
            assertFalse(gate.finish(first) { error("duplicate publication") })
        } finally {
            release.countDown()
        }
        assertTrue(finished.await(3, TimeUnit.SECONDS))
        thread.join(3000)
        assertFalse(thread.isAlive)
        assertNull(threadFailure.get())
        assertNotNull(gate.acquire())
    }

    @Test
    fun staleTerminalCannotReleaseOrPublishIntoNewerRequest() {
        val gate = PrivacyClearSettlementGate()
        val first = requireNotNull(gate.acquire())
        var report = "first"
        assertTrue(gate.finish(first) { report = "first done" })
        val second = requireNotNull(gate.acquire())
        assertFalse(gate.finish(first) { report = "stale" })
        assertNull(gate.acquire())
        assertEquals("first done", report)
        assertTrue(gate.finish(second) { report = "second done" })
        assertEquals("second done", report)
    }

    @Test
    fun terminalExceptionReleasesOnlyItsOwnRequest() {
        val gate = PrivacyClearSettlementGate()
        val first = requireNotNull(gate.acquire())
        var failed = false
        try {
            gate.finish(first) { throw IllegalStateException("injected") }
        } catch (_: IllegalStateException) {
            failed = true
        }
        assertTrue(failed)
        val second = requireNotNull(gate.acquire())
        assertFalse(gate.finish(first) { error("stale") })
        assertTrue(gate.finish(second) {})
    }

    @Test
    fun terminalCannotStartAnotherClearInsidePublication() {
        val gate = PrivacyClearSettlementGate()
        val first = requireNotNull(gate.acquire())
        assertTrue(gate.finish(first) { assertNull(gate.acquire()) })
        assertNotNull(gate.acquire())
    }
}
