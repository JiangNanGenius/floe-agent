// SPDX-License-Identifier: MPL-2.0
//
// C07 beginRestore source-lifetime regressions.
//
// Real kotlinx.coroutines Jobs, no Android/provider/App state. The controller
// uses C07RestoreSourceSettlement.settle() on every synchronous refusal and
// attach(job) on the one real job that owns the review; these tests exercise
// the two cases a body-only `finally` misses: a scope cancelled before the
// body runs and a cleanup failure thrown from the body's `finally`.
// AUTHORED, NOT RUN by this lane.
package com.floe.android.host.dataexchange

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C07RestoreSourceSettlementTest {
    @Test
    fun synchronousRefusalSettlesExactlyOnce() {
        val calls = AtomicInteger()
        val settlement = C07RestoreSourceSettlement {
            calls.incrementAndGet()
        }
        settlement.settle()
        settlement.settle()
        assertEquals(1, calls.get())
    }

    @Test
    fun callbackFailureIsContainedAndNotRetried() {
        val calls = AtomicInteger()
        val settlement = C07RestoreSourceSettlement {
            calls.incrementAndGet()
            throw IllegalStateException("release failed")
        }
        settlement.settle()
        settlement.settle()
        assertEquals(1, calls.get())
    }

    @Test
    fun cancelledScopeSettlesExactlyOnceWhenBodyNeverStarts() = runBlocking {
        val calls = AtomicInteger()
        val released = CountDownLatch(1)
        val settlement = C07RestoreSourceSettlement {
            calls.incrementAndGet()
            released.countDown()
        }
        val parent = Job()
        val scope = CoroutineScope(parent)
        parent.cancel()
        var bodyStarted = false
        val job = scope.launch { bodyStarted = true }
        settlement.attach(job)
        assertTrue(released.await(5, TimeUnit.SECONDS))
        job.join()
        assertFalse(bodyStarted)
        assertEquals(1, calls.get())
        settlement.settle()
        assertEquals(1, calls.get())
    }

    @Test
    fun cleanupFailureSettlesExactlyOnceAtJobCompletion() = runBlocking {
        val calls = AtomicInteger()
        val released = CountDownLatch(1)
        val settlement = C07RestoreSourceSettlement {
            calls.incrementAndGet()
            released.countDown()
        }
        val parent = Job()
        val scope = CoroutineScope(
            parent + CoroutineExceptionHandler { _, _ -> })
        val started = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val job = scope.launch(Dispatchers.Default) {
            started.countDown()
            try {
                finish.await()
                throw IllegalStateException("body failure")
            } finally {
                throw IllegalStateException("cleanup failure")
            }
        }
        assertTrue(started.await(5, TimeUnit.SECONDS))
        settlement.attach(job)
        finish.countDown()
        assertTrue(released.await(5, TimeUnit.SECONDS))
        job.join()
        assertTrue(job.isCompleted)
        assertEquals(1, calls.get())
        settlement.settle()
        assertEquals(1, calls.get())
        parent.cancel()
    }

    @Test
    fun alreadyCompletedJobSettlesImmediatelyOnAttach() = runBlocking {
        val calls = AtomicInteger()
        val settlement = C07RestoreSourceSettlement {
            calls.incrementAndGet()
        }
        val parent = Job()
        val scope = CoroutineScope(parent)
        val job = scope.launch { }
        job.join()
        assertTrue(job.isCompleted)
        settlement.attach(job)
        assertEquals(1, calls.get())
        parent.cancel()
    }
}
