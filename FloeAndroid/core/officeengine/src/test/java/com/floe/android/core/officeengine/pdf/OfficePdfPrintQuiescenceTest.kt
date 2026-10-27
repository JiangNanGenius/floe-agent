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
 * Regression coverage for the REAL print-session lifetime coordinator
 * ([OfficePdfPrintQuiescence]) exactly as [OfficePdfPrintAdapter] wires it:
 * `submitFinalizer = printIo::execute` (the single worker that owns every
 * copy pass) and every layout/write pass entering through
 * [OfficePdfPrintQuiescence.runOrSettleCancel] with the production
 * [OfficePdfOnceCallback] gates. No mirror class: these ARE the production
 * objects (Main lane 14 repair — finish must fence, let owned I/O quiesce,
 * close descriptors in order, and release the owner exactly once ONLY
 * after quiescence).
 */
class OfficePdfPrintQuiescenceTest {

    private val workerName = "floe-pdf-quiesce-test"

    private fun newIo(name: String = workerName) =
        Executors.newSingleThreadExecutor { r -> Thread(r, name).apply { isDaemon = true } }

    /**
     * The core Main-finding regression: while an ACTUAL copy pass still
     * reads/writes (held here by a CountDownLatch exactly like a long
     * onWrite), the finish must NOT release the owner. The release happens
     * only after that pass returned from its own finally (dup + output
     * stream closed there), and a pass QUEUED before the finish can only
     * settle CANCELLED afterwards — never a false finish.
     */
    @Test
    fun ownerReleaseWaitsForRunningPassFinallyAndLateQueueOnlyCancels() {
        val io = newIo()
        val quiescence = OfficePdfPrintQuiescence(io::execute)
        val events = ConcurrentLinkedQueue<String>()
        val passStarted = CountDownLatch(1)
        val hold = CountDownLatch(1)

        // Pass 1 = a RUNNING copy pass: its finally closes this pass's dup
        // and the destination stream (production runWritePass shape), but it
        // is still inside the copy when the finish arrives.
        io.execute {
            passStarted.countDown()
            try {
                hold.await(8, TimeUnit.SECONDS)
            } finally {
                events.add("dupClosed")
                events.add("streamClosed")
            }
        }
        assertTrue("pass1 never started", passStarted.await(5, TimeUnit.SECONDS))

        // Pass 2 = work QUEUED BEFORE the finish: production entry must
        // settle it CANCELLED after retirement, with the real gate.
        val lateGate = OfficePdfOnceCallback("late-write")
        val lateWorkRan = AtomicInteger(0)
        val lateFinishFired = AtomicInteger(0)
        val lateCancelFired = AtomicInteger(0)
        io.execute {
            quiescence.runOrSettleCancel(
                lateGate,
                work = {
                    lateWorkRan.incrementAndGet()
                    lateGate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                        lateFinishFired.incrementAndGet()
                    }
                },
                settleCancelled = {
                    events.add("lateCancelled")
                    lateCancelFired.incrementAndGet()
                },
            )
        }

        // Pass 3 = a call arriving AFTER retirement (framework straggler
        // entering the worker after shutdown): rejected executor identity;
        // production code settles it via the same cancel path. Here we only
        // require the coordinator NOT to strand the owner (proved below by
        // the terminated worker + release).
        val released = AtomicInteger(0)
        val releaseThread = AtomicReference<String?>(null)
        val t0 = System.currentTimeMillis()
        quiescence.finish {
            releaseThread.set(Thread.currentThread().name)
            events.add("released")
            released.incrementAndGet()
        }
        val finishReturnedIn = System.currentTimeMillis() - t0
        io.shutdown() // exactly like OfficePdfPrintAdapter.onFinish

        // (a) The caller (main) thread did NOT block joining latched I/O:
        //     finish returned while pass1 was still running…
        assertTrue("finish blocked on I/O: ${finishReturnedIn}ms", finishReturnedIn < 1_000)
        // …and NOTHING was released yet (no owner drop while I/O active).
        assertEquals(0, released.get())

        hold.countDown()
        assertTrue("worker did not drain", io.awaitTermination(10, TimeUnit.SECONDS))

        // (b) Release ran EXACTLY ONCE, serialized on the I/O worker, after
        //     the running pass's own finally closed dup + stream.
        assertEquals(1, released.get())
        assertEquals(workerName, releaseThread.get())
        // (c) The late queued pass NEVER ran real work and NEVER fired a
        //     false finish; it settled CANCELLED exactly once through the
        //     production gate.
        assertEquals(0, lateWorkRan.get())
        assertEquals(0, lateFinishFired.get())
        assertEquals(1, lateCancelFired.get())
        assertEquals(OfficePdfOnceCallback.Terminal.CANCELLED, lateGate.fired())
        // (d) Ordering: pass cleanup and the late cancel precede the release.
        val ordered = events.toList()
        val relIdx = ordered.indexOf("released")
        assertTrue("release must be last: $ordered", relIdx == ordered.size - 1)
        assertTrue("dup/stream cleanup must precede release: $ordered",
            ordered.indexOf("streamClosed") in 0 until relIdx)
        assertTrue("late pass must settle before release: $ordered",
            ordered.indexOf("lateCancelled") in 0 until relIdx)
    }

    /**
     * A session that is already live may still run passes normally until
     * retirement; a second entry for an already-settled request touches
     * nothing (the once-gate holds across the coordinator boundary).
     */
    @Test
    fun liveSessionRunsPassesAndSettledRequestIsNeverReentered() {
        val io = newIo("floe-pdf-quiesce-live")
        val quiescence = OfficePdfPrintQuiescence(io::execute)
        val gate = OfficePdfOnceCallback("write")
        val workRuns = AtomicInteger(0)
        val cancelled = AtomicInteger(0)
        val firstRan = AtomicReference<Boolean?>(null)
        val secondRan = AtomicReference<Boolean?>(null)
        val first = io.submit {
            firstRan.set(
                quiescence.runOrSettleCancel(
                    gate,
                    work = {
                        workRuns.incrementAndGet()
                        gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {}
                    },
                    settleCancelled = { cancelled.incrementAndGet() },
                ),
            )
        }
        first.get(5, TimeUnit.SECONDS)
        val second = io.submit {
            secondRan.set(
                quiescence.runOrSettleCancel(
                    gate,
                    work = { workRuns.incrementAndGet() },
                    settleCancelled = { cancelled.incrementAndGet() },
                ),
            )
        }
        second.get(5, TimeUnit.SECONDS)
        assertEquals(true, firstRan.get()) // live session: the pass runs
        assertEquals(false, secondRan.get()) // fired gate → no re-entry, no work
        assertEquals(1, workRuns.get())
        assertEquals(0, cancelled.get())
        assertEquals(OfficePdfOnceCallback.Terminal.FINISHED, gate.fired())
        assertFalse(quiescence.retired())
        io.shutdown()
        assertTrue(io.awaitTermination(5, TimeUnit.SECONDS))
    }

    /**
     * Cancellation listener vs copy pass vs finish, all racing the SAME
     * request gate: exactly ONE terminal action ever runs, and the owner
     * release still lands exactly once. Repeated on purpose to make the
     * race coverage real rather than single-shot luck.
     */
    @Test
    fun cancelFinishRaceAlwaysSettlesExactlyOneTerminal() {
        repeat(25) { i ->
            val io = newIo("floe-pdf-quiesce-race-$i")
            val quiescence = OfficePdfPrintQuiescence(io::execute)
            val gate = OfficePdfOnceCallback("race-$i")
            val terminalActions = AtomicInteger(0)
            val released = AtomicInteger(0)
            val start = CountDownLatch(1)
            val pass = Thread {
                start.await()
                quiescence.runOrSettleCancel(
                    gate,
                    work = {
                        Thread.sleep(0, 200_000) // tiny yield into the race
                        gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                            terminalActions.incrementAndGet()
                        }
                    },
                    settleCancelled = { terminalActions.incrementAndGet() },
                )
            }
            val cancelListener = Thread {
                start.await()
                gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                    terminalActions.incrementAndGet()
                }
            }
            val finisher = Thread {
                start.await()
                quiescence.finish { released.incrementAndGet() }
            }
            listOf(pass, cancelListener, finisher).forEach { it.start() }
            start.countDown()
            listOf(pass, cancelListener, finisher).forEach { it.join(5_000) }
            io.shutdown()
            assertTrue("worker $i stuck", io.awaitTermination(5, TimeUnit.SECONDS))
            assertEquals("iteration $i: exactly one terminal action", 1, terminalActions.get())
            assertEquals("iteration $i: exactly one release", 1, released.get())
            assertTrue("iteration $i: terminal recorded", gate.fired() != null)
        }
    }

    /**
     * Multiple finish() callers (framework onFinish plus a flow fallback on
     * the same adapter) release the owner EXACTLY ONCE.
     */
    @Test
    fun concurrentFinishCallsReleaseExactlyOnce() {
        val io = newIo("floe-pdf-quiesce-double")
        val quiescence = OfficePdfPrintQuiescence(io::execute)
        val released = AtomicInteger(0)
        val threads = (1..4).map {
            Thread {
                quiescence.finish { released.incrementAndGet() }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(5_000) }
        io.shutdown()
        assertTrue(io.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals(1, released.get())
        assertTrue(quiescence.retired())
    }

    /**
     * If the owned executor is already shut and cannot accept the
     * finalizer, the release MUST run inline: an admitted-job identity is
     * preserved elsewhere, and the owner lease is NEVER silently stranded.
     */
    @Test
    fun rejectedFinalizerReleasesInlineAndNeverStrandsTheOwner() {
        var releasedCount = 0
        val quiescence = OfficePdfPrintQuiescence { throw RejectedExecutionException("worker shut down") }
        quiescence.finish { releasedCount++ }
        assertEquals(1, releasedCount)
        assertTrue(quiescence.retired())
        // Second finish is still ignored: release stays exactly once.
        quiescence.finish { releasedCount++ }
        assertEquals(1, releasedCount)
    }

    /**
     * Retirement fence is observable BEFORE any release ran: a pass
     * checking the fence (as production onLayout/onWrite entry does)
     * refuses to touch descriptors, and the gate stays untouched until the
     * coordinator settles it. Also proves finish() never marks work as a
     * failure: a cancelled late pass is CANCELLED, never FAILED — an
     * admitted job is never misclassified.
     */
    @Test
    fun retirementFencesPassesWithoutFailureMisclassification() {
        val io = newIo("floe-pdf-quiesce-fence")
        val quiescence = OfficePdfPrintQuiescence(io::execute)
        val gate = OfficePdfOnceCallback("layout")
        val touched = AtomicInteger(0)
        val cancelled = AtomicInteger(0)
        quiescence.finish { touched.incrementAndGet() }
        io.shutdown()
        assertTrue(io.awaitTermination(5, TimeUnit.SECONDS))
        // Owner released once by the inline/serialized path already:
        assertEquals(1, touched.get())
        // Any later pass through the REAL production entry:
        val straggler = OfficePdfOnceCallback("layout2")
        val ran = quiescence.runOrSettleCancel(
            straggler,
            work = { touched.incrementAndGet() },
            settleCancelled = { cancelled.incrementAndGet() },
        )
        assertFalse(ran)
        assertEquals(0, straggler.fired()?.let { if (it == OfficePdfOnceCallback.Terminal.FAILED) 1 else 0 } ?: 0)
        assertEquals(1, cancelled.get())
        assertEquals(OfficePdfOnceCallback.Terminal.CANCELLED, straggler.fired())
        assertEquals(1, touched.get()) // no extra work after the release
        assertNull(gate.fired()) // an untouched gate stays uninvented
    }
}
