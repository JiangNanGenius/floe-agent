// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regressions for the real API 33/37 NsdManager late-callback crash:
 * ServiceHandler kept a listener executor and called execute() after the LAN
 * session had shut it down, crashing ConnectivityThread with
 * RejectedExecutionException.
 */
class LanDiscoveryCallbackLifecycleTest {
    @Test
    fun dispatchAfterCloseNeverThrowsAndDoesNotRunLateCallback() {
        val executor = NsdCallbackExecutor(queueCapacity = 4)
        executor.close()

        val ran = AtomicBoolean(false)
        executor.execute { ran.set(true) }

        assertTrue(executor.isClosed)
        assertFalse(ran.get())
        assertEquals(0, executor.queuedTaskCount)
        assertEquals(0L, executor.droppedCallbackCount)
    }

    @Test
    fun closeDropsQueuedLateCallbackAndReleasesItsWorker() {
        val executor = NsdCallbackExecutor(queueCapacity = 8)
        val state = LanDiscoveryTypeState()
        state.started()
        val workerEntered = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        val queuedCallbackRan = AtomicBoolean(false)

        executor.execute {
            workerEntered.countDown()
            try {
                releaseWorker.await(5, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        assertTrue(workerEntered.await(5, TimeUnit.SECONDS))
        executor.execute {
            state.startedFailure(3, "nsdAlreadyActive")
            queuedCallbackRan.set(true)
        }

        executor.close()

        assertTrue(executor.isClosed)
        assertEquals(0, executor.queuedTaskCount)
        assertFalse(queuedCallbackRan.get())
        assertEquals("started", state.snapshot().state)

        // The platform ServiceHandler may still invoke execute() after close.
        executor.execute {
            state.startedFailure(4, "late")
            queuedCallbackRan.set(true)
        }
        assertFalse(queuedCallbackRan.get())
        assertEquals("started", state.snapshot().state)
        releaseWorker.countDown()
    }

    @Test
    fun boundedQueueDropsNewestCallbacksWithoutBlockingDispatch() {
        val executor = NsdCallbackExecutor(queueCapacity = 2)
        val workerEntered = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        val queuedCallbacksRan = AtomicInteger(0)

        executor.execute {
            workerEntered.countDown()
            try {
                releaseWorker.await(5, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        assertTrue(workerEntered.await(5, TimeUnit.SECONDS))
        repeat(20) {
            executor.execute { queuedCallbacksRan.incrementAndGet() }
        }
        assertEquals(2, executor.queuedTaskCount)
        assertEquals(18L, executor.droppedCallbackCount)

        executor.close()

        assertEquals(0, executor.queuedTaskCount)
        releaseWorker.countDown()
        assertEquals(0, queuedCallbacksRan.get())
    }

    @Test
    fun concurrentDispatchDuringCloseNeverThrows() {
        repeat(20) {
            val executor = NsdCallbackExecutor(queueCapacity = 8)
            val start = CountDownLatch(1)
            val failures = ConcurrentLinkedQueue<Throwable>()
            val producers = (0 until 4).map {
                Thread {
                    try {
                        start.await()
                        repeat(100) {
                            executor.execute { }
                        }
                    } catch (failure: Throwable) {
                        failures += failure
                    }
                }
            }
            producers.forEach { producer -> producer.start() }
            start.countDown()
            executor.close()
            producers.forEach { producer -> producer.join(2_000) }

            assertTrue("late dispatch threw: $failures", failures.isEmpty())
            assertTrue(executor.isClosed)
        }
    }

    @Test
    fun closeIsIdempotentAndSafeFromItsOwnWorkerCallback() {
        val executor = NsdCallbackExecutor(queueCapacity = 2)
        val closed = CountDownLatch(1)
        val lateCallbackRan = AtomicBoolean(false)

        executor.execute {
            executor.close()
            executor.close()
            closed.countDown()
        }
        assertTrue(closed.await(5, TimeUnit.SECONDS))
        assertTrue(executor.isClosed)

        executor.execute { lateCallbackRan.set(true) }
        assertFalse(lateCallbackRan.get())
    }

    @Test
    fun saturatedCallbackQueueIsReportedAsPartialNotComplete() {
        val request = LanDiscoveryRequest(
            serviceTypes = listOf("_http._tcp"),
            discoveryDurationMs = 4_000,
            timeoutMs = 5_000,
        )
        val summary = LanMdnsSummary(
            requestedServiceTypes = listOf("_http._tcp"),
            scope = "capturedNetwork",
            networkScoped = true,
            discoveryDurationMs = 4_000,
            elapsedMs = 4_000,
            services = emptyList(),
            perType = listOf(LanTypeRecord("_http._tcp", "started")),
            filteredForeignNetwork = 0,
            truncated = true,
            noReplies = false,
            multicastLockHeld = null,
            stoppedReason = "callbackOverflow",
        )

        val result = LanDiscoveryResult.build(request, summary, null, networkChanged = false)

        assertEquals(ObservationStatus.PARTIAL, result.status)
        assertEquals(
            "callbackOverflow",
            result.observations.getJSONObject("mdns").getString("stoppedReason"),
        )
        assertTrue(result.limitations.any { it.contains("callback delivery queue") })
    }

    @Test
    fun startFailureIsTerminalAndLateStartOrStopCannotOverwriteIt() {
        val state = LanDiscoveryTypeState()
        state.started()
        state.startedFailure(3, "nsdAlreadyActive")
        state.started()
        state.stopped()

        val snapshot = state.snapshot()
        assertEquals("startFailed", snapshot.state)
        assertEquals(3, snapshot.errorCode)
        assertEquals("nsdAlreadyActive", snapshot.errorText)
    }

    @Test
    fun stoppedTypeCannotBeResurrectedByLateStartAcknowledgement() {
        val state = LanDiscoveryTypeState()
        state.started()
        state.stopped()
        state.started()

        assertEquals("stopped", state.snapshot().state)
    }

    @Test
    fun stopFailureKeepsItsTerminalErrorAgainstLateStopAcknowledgement() {
        val state = LanDiscoveryTypeState()
        state.started()
        state.stopFailure(4, "nsdMaxLimit")
        state.stopped()

        val snapshot = state.snapshot()
        assertEquals("stopFailed", snapshot.state)
        assertEquals(4, snapshot.errorCode)
        assertEquals("nsdMaxLimit", snapshot.errorText)
    }

    @Test
    fun synchronousStartFailureIsTerminalWithoutInventingAnErrorCode() {
        val state = LanDiscoveryTypeState()
        assertEquals("startPending", state.snapshot().state)

        state.startedFailure(null, "IllegalArgumentException")
        state.started()

        val snapshot = state.snapshot()
        assertEquals("startFailed", snapshot.state)
        assertNull(snapshot.errorCode)
        assertEquals("IllegalArgumentException", snapshot.errorText)
    }
}
