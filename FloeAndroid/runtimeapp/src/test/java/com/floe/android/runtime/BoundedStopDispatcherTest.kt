// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * AUTHORED NOT RUN regressions for the bounded stop lane used by
 * [RuntimeKernel]. The ORIGINAL single-slot stop executor claimed once and
 * silently dropped every additional DISTINCT target while the first drain was
 * queued; the two-TTY lifecycle requires every accepted target stop to run.
 *
 * These tests drive the production [BoundedStopDispatcher], not a copy of its
 * queue logic: one worker stays strictly serialized, a full queue makes the
 * submitting thread wait for bounded space instead of rejecting, and no
 * accepted task is ever lost.
 */
class BoundedStopDispatcherTest {

    @Test(timeout = 20_000)
    fun distinctTargetStopsAreNeverDroppedAndNeverOverlap() {
        val dispatcher = BoundedStopDispatcher(capacity = 1, threadName = "test-stop-lane")
        val ran = Collections.synchronizedList(mutableListOf<String>())
        val active = AtomicInteger()
        val maxActive = AtomicInteger()
        val blockerStarted = CountDownLatch(1)
        val releaseBlocker = CountDownLatch(1)

        fun task(name: String) = Runnable {
            val now = active.incrementAndGet()
            maxActive.updateAndGet { maxOf(it, now) }
            ran.add(name)
            if (name == "blocker") {
                blockerStarted.countDown()
                releaseBlocker.await(10, TimeUnit.SECONDS)
            }
            active.decrementAndGet()
        }

        dispatcher.dispatch(task("blocker"))
        assertTrue("blocker must own the single stop worker", blockerStarted.await(10, TimeUnit.SECONDS))
        // Capacity is 1: A fills it; B must NOT be dropped and must wait for
        // the worker to take A before it can enter the bounded queue.
        dispatcher.dispatch(task("A"))
        val submitStarted = CountDownLatch(1)
        val submitDone = CountDownLatch(1)
        val submitter = Thread {
            submitStarted.countDown()
            dispatcher.dispatch(task("B"))
            submitDone.countDown()
        }
        submitter.start()
        assertTrue(submitStarted.await(10, TimeUnit.SECONDS))
        assertFalse("a full bounded stop queue must wait, never drop the target",
            submitDone.await(250, TimeUnit.MILLISECONDS))

        releaseBlocker.countDown()
        assertTrue("the waiting distinct target must be accepted", submitDone.await(10, TimeUnit.SECONDS))
        submitter.join(10_000)
        assertFalse(submitter.isAlive)

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (ran.size < 3 && System.nanoTime() < deadline) Thread.sleep(10)
        assertEquals(listOf("blocker", "A", "B"), ran)
        assertEquals("the stop lane must stay strictly serialized", 1, maxActive.get())
    }

    @Test(timeout = 20_000)
    fun ordinaryBurstOfDistinctStopsRunsEveryTaskExactlyOnce() {
        val dispatcher = BoundedStopDispatcher(capacity = 4, threadName = "test-stop-burst")
        val ran = Collections.synchronizedList(mutableListOf<Int>())
        for (index in 0 until 20) dispatcher.dispatch { ran.add(index) }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (ran.size < 20 && System.nanoTime() < deadline) Thread.sleep(10)
        assertEquals((0 until 20).toList(), ran)
        assertEquals("every accepted distinct stop ran exactly once", 20, ran.size)
    }

    /**
     * The previous `dispatch` catch ran the task INLINE on an interrupted
     * handoff, i.e. a second stop could execute concurrently with the single
     * worker's in-flight stop. The handoff must instead remember the
     * interrupt, keep waiting for bounded queue space, restore the interrupt
     * status only after acceptance, and never lose the target.
     */
    @Test(timeout = 20_000)
    fun interruptedFullQueueHandoffNeverRunsInlineAndStillDelivers() {
        val dispatcher = BoundedStopDispatcher(capacity = 1, threadName = "test-stop-interrupt")
        val ran = Collections.synchronizedList(mutableListOf<String>())
        val active = AtomicInteger()
        val maxActive = AtomicInteger()
        val blockerStarted = CountDownLatch(1)
        val releaseBlocker = CountDownLatch(1)
        fun task(name: String) = Runnable {
            val now = active.incrementAndGet()
            maxActive.updateAndGet { maxOf(it, now) }
            ran.add(name)
            if (name == "blocker") {
                blockerStarted.countDown()
                releaseBlocker.await(10, TimeUnit.SECONDS)
            }
            active.decrementAndGet()
        }

        dispatcher.dispatch(task("blocker"))
        assertTrue(blockerStarted.await(10, TimeUnit.SECONDS))
        dispatcher.dispatch(task("A")) // fills the bounded queue
        val started = CountDownLatch(1)
        val done = CountDownLatch(1)
        val interruptRestored = AtomicBoolean(false)
        val submitter = Thread {
            started.countDown()
            dispatcher.dispatch(task("B"))
            interruptRestored.set(Thread.currentThread().isInterrupted)
            done.countDown()
        }
        submitter.start()
        assertTrue(started.await(10, TimeUnit.SECONDS))
        Thread.sleep(250) // the submitter is blocked handing B off to the full queue
        submitter.interrupt()

        // Old behavior would catch the rejection and run B on the submitter
        // while the lane's worker is still inside "blocker": two stops at once.
        assertFalse("interrupted handoff must never execute the stop inline",
            done.await(300, TimeUnit.MILLISECONDS))
        assertFalse("B must not have run while the worker is blocked", ran.contains("B"))

        releaseBlocker.countDown()
        assertTrue("the interrupted distinct target must still be accepted",
            done.await(10, TimeUnit.SECONDS))
        submitter.join(10_000)
        assertFalse(submitter.isAlive)
        assertTrue("interrupt status must be restored after the bounded handoff",
            interruptRestored.get())

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (ran.size < 3 && System.nanoTime() < deadline) Thread.sleep(10)
        assertEquals(listOf("blocker", "A", "B"), ran)
        assertEquals("two stop actions must never overlap", 1, maxActive.get())
    }
}
