// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * G03-R3 first-start admission repair — AUTHORED NOT RUN regressions
 * (Main's grouped JVM batch executes; runtimeapp test source set keeps
 * org.json and Android deliberately absent, the same constraint the
 * existing [RuntimeWorkspacePreflightGuardTest] documents).
 *
 * These tests drive the ACTUAL [RuntimeStoppingFence] state machine
 * through the real lifecycle event ORDER observed on the candidate08
 * device failure (NEW_TASK_WORKSPACE_FAILURE_08.json closed stages:
 * PUMP_STOP_SESSION -> OPS_PUMP_ENDED -> OPS_FINISH_RETURNED ->
 * PUMP_FINISHED, then the brand-new task's KERNEL_START_ENTER ->
 * PUMP_ADMISSION_REFUSED with grant READY, no child, zero wake locks) —
 * not a truth table mirroring the production expression. Every ORIGINAL
 * refusal semantics must stay pinned: a fresh queued stop keeps refusing,
 * a stop converging on live ownership keeps refusing, and only a real
 * drained/released completion settles the fence.
 */
class RuntimeStoppingFenceTest {

    /** The candidate08 leak order, replayed as actual state transitions:
     *  the stop lands while the session is still draining on the pump
     *  thread; the requestStop tail and the stop-executor finally BOTH
     *  evaluate the live predicate while the lease is still held; the
     *  REAL release lands later on the pump thread. The fence must stay
     *  raised through every premature evaluation (strict refusal) and
     *  must converge on the actual completion note (the repair). */
    @Test fun leakedFenceFromPumpThreadReleaseConvergesOnRealCompletion() {
        val leaseHeld = AtomicBoolean(true) // operations.heldLease != null
        val fence = RuntimeStoppingFence { leaseHeld.get() }

        assertTrue("first raiser claims the single queue slot", fence.beginStop())
        assertTrue(fence.isStopping)
        fence.settleAfterRaise() // requestStop tail: work still owned
        assertTrue("tail must NOT clear while the lease is held", fence.isStopping)
        fence.stopDrained() // stop-executor finally: pump still draining
        assertTrue("drain finally must NOT clear while the lease is held", fence.isStopping)

        // The pump thread finishes the REAL release (finish() success):
        leaseHeld.set(false)
        fence.settleAfterOwnedWorkReleased()
        assertFalse("proven-drained fence must fall at its real completion event",
            fence.isStopping)
    }

    /** A FRESH stop is never unwound by a release note: while a stop is
     *  queued/converging the release-note settle refuses even with empty
     *  ownership, and the queued stop's OWN drain settles the fence.
     *  Then a newer raise stands independently (monitor ordering). */
    @Test fun freshQueuedStopIsNotUnwoundByReleaseNotes() {
        val leaseHeld = AtomicBoolean(true)
        val fence = RuntimeStoppingFence { leaseHeld.get() }

        assertTrue(fence.beginStop())
        leaseHeld.set(false) // first session's real release...
        fence.stopDrained() // ...converged by its own drain
        assertFalse(fence.isStopping)

        // Newer stop generation raises while new work is owned:
        leaseHeld.set(true)
        assertTrue(fence.beginStop())
        leaseHeld.set(false)
        // A late/duplicate release note while the stop is still queued:
        fence.settleAfterOwnedWorkReleased()
        assertTrue("queued stop keeps refusing until its own drain completes",
            fence.isStopping)
        // Only the queued stop's own finally may settle it:
        fence.stopDrained()
        assertFalse(fence.isStopping)
    }

    /** ORIGINAL requestStop tail semantics preserved: a stop with nothing
     *  to stop never fences future admission, even while its drain task
     *  is still queued; and the single queue claim is preserved (exactly
     *  one stopOwnedWork task at a time). */
    @Test fun stopWithNoOwnedWorkNeverFencesAdmission() {
        val fence = RuntimeStoppingFence { false }
        assertTrue(fence.beginStop())
        fence.settleAfterRaise()
        assertFalse("stop with nothing owned must not fence the next start",
            fence.isStopping)
        // Second raise while the first drain is still queued: no second claim.
        assertFalse(fence.beginStop())
        assertTrue("the newer raise still re-raises the fence", fence.isStopping)
        fence.settleAfterRaise()
        assertFalse(fence.isStopping)
        fence.stopDrained() // first drain completes; slot releases
        // Queue slot is reusable afterwards:
        assertTrue(fence.beginStop())
        fence.stopDrained()
        assertFalse(fence.isStopping)
    }

    /** ORIGINAL queued-request executor finally rule: the fence settles
     *  only on the live predicate after this request's own count dropped. */
    @Test fun requestDrainSettlesOnlyWhenEngineOwnsNothing() {
        val owned = AtomicBoolean(true)
        val fence = RuntimeStoppingFence { owned.get() }
        fence.beginStop()
        fence.settleAfterRequestDrained()
        assertTrue(fence.isStopping)
        owned.set(false)
        fence.settleAfterRequestDrained()
        assertFalse(fence.isStopping)
    }

    /** Real threads: concurrent raisers, drainers and release notes over a
     *  flipping ownership predicate must (a) never deadlock, (b) never
     *  throw, and (c) always quiesce to a SETTLED fence once ownership is
     *  empty and one final stop cycle runs — the ordering property the
     *  repair claims, exercised through the actual monitor rather than a
     *  mirrored truth table. */
    @Test fun concurrentStopsAndReleasesAlwaysQuiesceSettled() {
        val owned = AtomicBoolean(false)
        val fence = RuntimeStoppingFence { owned.get() }
        val failures = AtomicInteger()
        val rounds = 500
        val start = CountDownLatch(1)
        val threads = (0 until 4).map { index ->
            Thread {
                try {
                    start.await(5, TimeUnit.SECONDS)
                    repeat(rounds) { round ->
                        when (index) {
                            0 -> { owned.set(true); fence.beginStop() }
                            1 -> { fence.stopDrained(); fence.settleAfterRaise() }
                            2 -> { owned.set(false); fence.settleAfterOwnedWorkReleased() }
                            else -> { fence.settleAfterRequestDrained(); if (round % 7 == 0) fence.beginStop() }
                        }
                    }
                } catch (_: Throwable) {
                    failures.incrementAndGet()
                }
            }.also { it.isDaemon = true; it.start() }
        }
        start.countDown()
        threads.forEach { it.join(TimeUnit.SECONDS.toMillis(20)) }
        threads.forEach { assertFalse("fence threads must not deadlock", it.isAlive) }
        assertEquals(0, failures.get())
        // Deterministic quiescence: with nothing owned, one final stop cycle
        // (raise + its own tail/drain) must leave the fence settled.
        owned.set(false)
        fence.beginStop()
        fence.settleAfterRaise()
        fence.stopDrained()
        fence.settleAfterOwnedWorkReleased()
        assertFalse("fence must quiesce settled once ownership is empty", fence.isStopping)
    }
}
