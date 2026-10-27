// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Regression coverage for the REAL host lifetime coordinator
 * ([OfficePdfRenderHostLifetime]) exactly as [OfficePdfRenderHost] wires it
 * (`submitDrainTask = worker::execute` on the single renderer worker, the
 * posted main runnable deciding through [OfficePdfRenderHostLifetime.mayDeliver]
 * when it RUNS, and [OfficePdfRenderHost.release] joining an optional
 * immutable-snapshot lease behind the drained worker). No mirror class: these
 * ARE the production objects (lane 17 repair of the accepted lane-14 host —
 * the delivered shape fenced only BEFORE `main.post`, so a release landing
 * between the post and delivery could still call a dead UI and drop an
 * unrecycled bitmap, and snapshot owners had no quiescent point to unlink
 * behind).
 */
class OfficePdfRenderHostLifecycleTest {

    private fun newWorker(name: String) =
        Executors.newSingleThreadExecutor { r -> Thread(r, name).apply { isDaemon = true } }

    /**
     * The fence decision itself: beginRelease flips mayDeliver atomically and
     * EXACTLY ONCE — the first releaser wins; every later release attempt is
     * ignored, so callbacks posted before the flip stop being deliverable
     * the moment the flag flips, and never flip back.
     */
    @Test
    fun firstReleaseWinsAndFlipsTheDeliveryFenceForever() {
        val submitted = AtomicReference<Runnable?>(null)
        val lifetime = OfficePdfRenderHostLifetime { submitted.set(it) }
        assertFalse(lifetime.isReleased())
        assertTrue(lifetime.mayDeliver())
        assertTrue("first release attempt takes the fence", lifetime.beginRelease())
        assertFalse("second release is ignored", lifetime.beginRelease())
        assertFalse(lifetime.mayDeliver())
        assertTrue(lifetime.isReleased())
        // A late "posted" result consulting the real decision must NOT be
        // delivered to a retired owner.
        assertFalse(lifetime.mayDeliver())
        assertNull("no drain scheduled unless release asked for one", submitted.get())
    }

    /**
     * The lane-17 MAIN-DELIVERY race: the worker computed a result and the
     * post was ENQUEUED while the host was still live; the release lands
     * BEFORE the main runnable executes. Driving the production decision the
     * posted runnable makes when it runs, the delivery branch must be the
     * recycle branch (dead-UI callback never invoked).
     */
    @Test
    fun postThenReleaseBeforeDeliveryRetiresCallbackAndRecycles() {
        val worker = newWorker("floe-pdf-host-test-race")
        val mainQueue = newWorker("floe-pdf-host-test-main")
        val lifetime = OfficePdfRenderHostLifetime(worker::execute)
        val delivered = AtomicInteger(0)
        val recycled = AtomicInteger(0)
        val hold = CountDownLatch(1)
        val posted = CountDownLatch(1)
        val releaseLanded = CountDownLatch(1)

        // A "transaction" finishes, passes the pre-post fence and posts.
        worker.execute {
            hold.countDown()
            // (production shape: if (lifetime.isReleased()) recycle+return)
            if (lifetime.mayDeliver()) {
                mainQueue.execute {
                    // Deterministic lane-17 window: the delivery decision is
                    // taken only AFTER the release has actually landed
                    // (exactly the post→release→delivery order under test;
                    // without this barrier the enqueued runnable could win
                    // the race against beginRelease and observe a live host).
                    releaseLanded.await()
                    // THE ACTUAL PRODUCTION DECISION, taken at delivery time:
                    if (lifetime.mayDeliver()) delivered.incrementAndGet()
                    else recycled.incrementAndGet() // late bitmap recycle branch
                }
                // `posted` now proves the ENQUEUE completed, so the main
                // thread's shutdown can never reject the still-submittng task.
                posted.countDown()
            }
        }
        assertTrue(hold.await(5, TimeUnit.SECONDS))
        assertTrue(posted.await(5, TimeUnit.SECONDS))
        // Release lands after the post was enqueued, before main runs it —
        // exactly the window the delivered shape leaked.
        assertTrue(lifetime.beginRelease())
        releaseLanded.countDown()
        mainQueue.shutdown()
        assertTrue(mainQueue.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals("retired callback never fires", 0, delivered.get())
        assertEquals("undelivered result takes the recycle branch", 1, recycled.get())
        worker.shutdown()
        assertTrue(worker.awaitTermination(5, TimeUnit.SECONDS))
    }

    /**
     * The lease-join core: while a REAL renderer transaction is still running
     * (its finally closes this request's descriptor, exactly like
     * withFd in production) and another job is QUEUED behind it, the release
     * must NOT run the snapshot owner's unlink. The quiescent callback fires
     * EXACTLY ONCE, serialized on the same worker, after every already-
     * submitted job returned — and the releasing (main) thread never blocks.
     */
    @Test
    fun quiescentReleaseSerializesBehindRunningAndQueuedTransactions() {
        val workerName = "floe-pdf-host-test-drain"
        val worker = newWorker(workerName)
        val lifetime = OfficePdfRenderHostLifetime(worker::execute)
        val events = ConcurrentLinkedQueue<String>()
        val running = CountDownLatch(1)
        val hold = CountDownLatch(1)

        // Job 1 = RUNNING transaction: closes its own FD in finally.
        worker.execute {
            running.countDown()
            try {
                hold.await(8, TimeUnit.SECONDS)
            } finally {
                events.add("transactionFdClosed")
            }
        }
        assertTrue("job1 never started", running.await(5, TimeUnit.SECONDS))
        // Job 2 = queued behind it (submitted before the release).
        worker.execute { events.add("queuedJobRan") }

        val quiesced = AtomicInteger(0)
        val quiesceThread = AtomicReference<String?>(null)
        val t0 = System.currentTimeMillis()
        assertTrue(lifetime.beginRelease())
        lifetime.scheduleQuiescentRelease {
            quiesceThread.set(Thread.currentThread().name)
            events.add("quiescent")
            quiesced.incrementAndGet()
        }
        val returnedIn = System.currentTimeMillis() - t0
        worker.shutdown() // exactly like OfficePdfRenderHost.release

        // (a) the releasing thread did NOT block joining latched I/O…
        assertTrue("release blocked on the worker: ${returnedIn}ms", returnedIn < 1_000)
        // …and NOTHING was released while the transaction was active.
        assertEquals(0, quiesced.get())

        hold.countDown()
        assertTrue("worker did not drain", worker.awaitTermination(10, TimeUnit.SECONDS))

        // (b) exactly once, on the owned worker, after both jobs settled.
        assertEquals(1, quiesced.get())
        assertEquals(workerName, quiesceThread.get())
        val ordered = events.toList()
        val q = ordered.indexOf("quiescent")
        assertTrue("quiescent must be last: $ordered", q == ordered.size - 1)
        assertTrue("running FD close precedes: $ordered",
            ordered.indexOf("transactionFdClosed") in 0 until q)
        assertTrue("queued job settled before the unlink point: $ordered",
            ordered.indexOf("queuedJobRan") in 0 until q)
    }

    /**
     * An executor that cannot accept the finalizer must settle the lease
     * INLINE — a durable owner (the run-output snapshot) may never be
     * stranded by a rejected drain, and a double schedule stays exactly one
     * execution (production releases through the beginRelease fence, but the
     * gate itself must not double-fire if callers misuse it).
     */
    @Test
    fun rejectedDrainSettlesInlineAndScheduleIsExactlyOnce() {
        var runs = 0
        val lifetime = OfficePdfRenderHostLifetime { throw RejectedExecutionException("worker shut") }
        assertTrue(lifetime.beginRelease())
        lifetime.scheduleQuiescentRelease { runs++ }
        assertEquals(1, runs)
        lifetime.scheduleQuiescentRelease { runs++ }
        assertEquals("exactly once even across repeated schedules", 1, runs)
    }

    /**
     * Concurrent releasers: only the beginRelease winner may schedule the
     * join, and even a racing double schedule (misuse) drains EXACTLY ONCE.
     * Repeated to make the race coverage real rather than single-shot luck.
     */
    @Test
    fun concurrentReleaseRacesDrainExactlyOnce() {
        repeat(25) { i ->
            val worker = newWorker("floe-pdf-host-test-race-$i")
            val lifetime = OfficePdfRenderHostLifetime(worker::execute)
            val quiesced = AtomicInteger(0)
            val start = CountDownLatch(1)
            val threads = (1..4).map {
                Thread {
                    start.await()
                    if (lifetime.beginRelease()) {
                        lifetime.scheduleQuiescentRelease { quiesced.incrementAndGet() }
                    }
                    // Misuse branch: schedule even without winning the fence.
                    lifetime.scheduleQuiescentRelease { quiesced.incrementAndGet() }
                }
            }
            threads.forEach { it.start() }
            start.countDown()
            threads.forEach { it.join(5_000) }
            worker.shutdown()
            assertTrue("worker $i stuck", worker.awaitTermination(5, TimeUnit.SECONDS))
            assertEquals("iteration $i: exactly one quiescent drain", 1, quiesced.get())
            assertTrue("iteration $i: fenced", lifetime.isReleased())
        }
    }

    /**
     * The throwing-callback rule shared with the module's once-gates: a
     * quiescent owner that throws is still EXACTLY once (never re-run, never
     * a stranded second attempt), and the worker keeps settling.
     */
    @Test
    fun throwingQuiescentOwnerIsCountedOnceAndNeverRetried() {
        val worker = newWorker("floe-pdf-host-test-throw")
        val lifetime = OfficePdfRenderHostLifetime(worker::execute)
        var attempts = 0
        assertTrue(lifetime.beginRelease())
        lifetime.scheduleQuiescentRelease {
            attempts++
            throw IllegalStateException("owner unlink raced")
        }
        worker.shutdown()
        assertTrue(worker.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals(1, attempts)
        // A later schedule cannot resurrect the fired gate.
        lifetime.scheduleQuiescentRelease { attempts++ }
        assertEquals(1, attempts)
    }
}
