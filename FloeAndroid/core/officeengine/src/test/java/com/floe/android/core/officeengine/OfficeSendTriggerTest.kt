// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract of the coalesced `window.socket.doSend()` poll trigger.
 *
 * The pinned mobile socket polls ONLY when this host asks it to (dist/global.js
 * `class T extends ProxySocket` deletes `_setPollInterval`), so the trigger has
 * to satisfy two opposite requirements at once: one engine burst must not turn
 * into hundreds of script evaluations — every wasted `doSend()` at the page's
 * in-flight cap walks its throttle ladder one step, and reaching the 500 ms cap
 * is what enables the fatal `> 30 s` no-response branch — while the tail of a
 * burst must still get a poll, or queued messages would wait for the next
 * native message.
 */
class OfficeSendTriggerTest {

    @Test
    fun claimIsExclusiveUntilReleased() {
        val trigger = OfficeSendTrigger()
        assertFalse(trigger.isPending)
        assertTrue(trigger.claim())
        assertTrue(trigger.isPending)
        // A burst inside the same pending window is coalesced into that poll.
        repeat(50) { assertFalse(trigger.claim()) }
        trigger.release()
        assertFalse(trigger.isPending)
        assertTrue(trigger.claim())
    }

    @Test
    fun burstTailRearmsAfterThePollIsIssued() {
        val trigger = OfficeSendTrigger()
        assertTrue(trigger.claim())
        repeat(20) { assertFalse(trigger.claim()) }
        // The host releases immediately BEFORE issuing doSend(), so the first
        // message enqueued after that point arms the next poll: no queued
        // message can be left without one.
        trigger.release()
        assertTrue(trigger.claim())
    }

    @Test
    fun releaseIsIdempotentAndNeverArmsAPollByItself() {
        val trigger = OfficeSendTrigger()
        // A release on a failed schedule path must not corrupt the state.
        trigger.release()
        assertFalse(trigger.isPending)
        assertTrue(trigger.claim())
        trigger.release()
        trigger.release()
        assertFalse(trigger.isPending)
        assertTrue(trigger.claim())
    }

    @Test
    fun concurrentBurstArmsExactlyOnePoll() {
        val trigger = OfficeSendTrigger()
        val threads = 16
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val winners = AtomicInteger(0)
        val pool = Executors.newFixedThreadPool(threads)
        try {
            repeat(threads) {
                pool.execute {
                    try {
                        start.await()
                        if (trigger.claim()) winners.incrementAndGet()
                    } catch (e: InterruptedException) {
                        Thread.currentThread().interrupt()
                    } finally {
                        done.countDown()
                    }
                }
            }
            start.countDown()
            assertTrue("claims did not settle", done.await(10, TimeUnit.SECONDS))
        } finally {
            pool.shutdownNow()
        }
        assertEquals(1, winners.get())
        assertTrue(trigger.isPending)
    }
}
