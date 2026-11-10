// SPDX-License-Identifier: MPL-2.0
// JVM regressions for observation readiness and terminal ordering.
package com.floe.android.phonecontrol

import java.util.PriorityQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the demonstrated public78/code104 Samsung
 * first-observe failure: an admitted task's first phone.observe performed the
 * in-call automatic unlock successfully (HOST_UNLOCK_RESULT_UNLOCKED), the
 * keyguard already read unlocked at the failure second, accessibility stayed
 * bound — and the single-shot capture still mapped the not-yet-re-published
 * active window to OBSERVATION_FAILED, so the model stopped and Calculator
 * never launched. These tests pin the repaired boundary:
 *  - a capture that is genuinely unavailable only during the transition is
 *    retried inside the EXISTING bounded settle window (same deadline and
 *    cadence family as the post-action settle loop) and completes exactly
 *    once, with success requiring a real observed capture — never an elapsed
 *    deadline alone;
 *  - the first poll is immediate: an already-published window completes with
 *    zero added latency and no scheduled polling;
 *  - fence arrival (stop/takeover/user-touch/service) and keyguard relock
 *    terminate with the typed denial and dominate a capture that would have
 *    succeeded on the same tick — nothing is published across a fence or a
 *    lock;
 *  - lost ownership mid-wait (caller cancellation / run release / any session
 *    abort path) completes NOTHING and stops polling: the existing abort
 *    machinery owns that terminal result, so a stray poll can never
 *    double-complete, hold a phone lease or relock a user's active phone;
 *  - exhaustion returns the same typed OBSERVATION_FAILED with a closed,
 *    actionable detail string — no secret, node text or raw exception data.
 */
class PhoneControlObservationReadinessTest {
    private val canary = PhoneControlCapture(
        observation = testObservation(),
        records = emptyMap(),
        fingerprint = 42L,
        protectedWindow = false,
        hasSensitiveField = false,
    )

    private class Driver : PhoneObservationReadinessDriver {
        private class Work(val at: Long, val order: Long, val action: () -> Unit) {
            var cancelled = false
        }
        private val queue = PriorityQueue<Work>(compareBy<Work> { it.at }.thenBy { it.order })
        private var order = 0L
        override var now = 0L
        var current = true
        var blocker: PhoneControlBlocker? = null
        var locked = false
        var scheduledPolls = 0
        var cancelledPolls = 0
        var duringCapture: (() -> Unit)? = null
        private val captures = ArrayDeque<PhoneControlCapture?>()
        var captureCalls = 0
            private set

        fun enqueueCaptures(vararg results: PhoneControlCapture?) {
            results.forEach(captures::addLast)
        }
        override fun after(delayMs: Long, action: () -> Unit): () -> Unit {
            scheduledPolls += 1
            val value = Work(now + delayMs, ++order, action)
            queue.add(value)
            return {
                if (!value.cancelled) cancelledPolls += 1
                value.cancelled = true
            }
        }
        fun advance(to: Long) {
            require(to >= now)
            while (queue.peek()?.at?.let { it <= to } == true) {
                val next = queue.remove(); now = next.at
                if (!next.cancelled) next.action()
            }
            now = to
        }
        fun pending() = queue.count { !it.cancelled }
        override fun stillCurrent() = current
        override fun blocker() = blocker
        override fun keyguardLocked() = locked
        override fun capture(): PhoneControlCapture? {
            captureCalls += 1
            duringCapture?.invoke()
            return captures.removeFirstOrNull()
        }
    }

    private fun gate(driver: Driver) = PhoneControlObservationReadiness(driver)

    @Test fun fenceArrivingDuringCapturePreventsPublication() {
        val driver = Driver()
        driver.enqueueCaptures(canary)
        driver.duringCapture = { driver.blocker = PhoneControlBlocker.STOPPED }
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        val result = outcomes.single()
        assertTrue(result is PhoneControlResult.Denied)
        assertEquals(PhoneControlDenial.STOPPED, (result as PhoneControlResult.Denied).reason)
        assertEquals(1, driver.captureCalls)
        assertEquals(0, driver.pending())
    }

    @Test fun relockDuringCapturePreventsPublication() {
        val driver = Driver()
        driver.enqueueCaptures(canary)
        driver.duringCapture = { driver.locked = true }
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        val result = outcomes.single()
        assertTrue(result is PhoneControlResult.Denied)
        assertEquals(PhoneControlDenial.DEVICE_LOCKED, (result as PhoneControlResult.Denied).reason)
        assertEquals(1, driver.captureCalls)
        assertEquals(0, driver.pending())
    }

    @Test fun ownershipLostDuringCaptureDoesNotCompleteAgain() {
        val driver = Driver()
        driver.enqueueCaptures(canary)
        driver.duringCapture = { driver.current = false }
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        assertTrue(outcomes.isEmpty())
        assertEquals(1, driver.captureCalls)
        assertEquals(0, driver.pending())
    }

    @Test fun alreadyPublishedWindowCompletesOnTheImmediateFirstPollWithoutPolling() {
        val driver = Driver()
        driver.enqueueCaptures(canary)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        // Zero added latency, no scheduled poll, exactly one completion.
        assertEquals(1, outcomes.size)
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Ok)
        assertSame(canary, (outcome as PhoneControlResult.Ok<PhoneControlCapture>).value)
        assertEquals(0, driver.scheduledPolls)
        assertEquals(0, driver.pending())
    }

    @Test fun lateWindowPublicationInsideTheBoundedWindowCompletesExactlyOnce() {
        val driver = Driver()
        // The demonstrated shape: the first captures keep finding no published
        // active window right after the unlock completed; publication lands
        // well inside the existing settle bound.
        driver.enqueueCaptures(null, null, canary)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        assertTrue(outcomes.isEmpty())
        driver.advance(60)
        assertTrue("no completion before a genuine capture", outcomes.isEmpty())
        driver.advance(120)
        assertEquals(1, outcomes.size)
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Ok)
        assertSame(canary, (outcome as PhoneControlResult.Ok<PhoneControlCapture>).value)
        // Exactly one capture attempt per poll; completion stops the loop, so
        // the remaining scheduled poll is abandoned without further captures.
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS * 2)
        assertEquals(1, outcomes.size)
        assertEquals(3, driver.captureCalls)
    }

    @Test fun unpublishedWindowThroughTheDeadlineYieldsOneTypedFailure() {
        val driver = Driver()
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS - 1)
        assertTrue("one tick before the existing settle bound still retries", outcomes.isEmpty())
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS)
        assertEquals(1, outcomes.size)
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Failed)
        val failed = outcome as PhoneControlResult.Failed
        assertEquals(PhoneControlFailure.OBSERVATION_FAILED, failed.reason)
        assertTrue(failed.detail.orEmpty().contains("bounded"))
        // Closed metadata only: no exception class, no node content.
        assertFalse(failed.detail.orEmpty().contains("Exception"))
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS * 4)
        assertEquals("exactly one completion; polling stopped", 1, outcomes.size)
    }

    @Test fun fenceArrivalMidWaitCompletesDeniedAndNeverPublishesALateCapture() {
        val driver = Driver()
        driver.enqueueCaptures(null)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        driver.advance(60)
        assertTrue(outcomes.isEmpty())
        // A user takeover lands while the window is still unpublished; the
        // next poll must terminate with the typed denial even though a capture
        // would have succeeded on that same tick.
        driver.blocker = PhoneControlBlocker.TAKEN_OVER
        driver.enqueueCaptures(canary)
        driver.advance(120)
        assertEquals(1, outcomes.size)
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Denied)
        assertEquals(
            PhoneControlDenial.TAKEN_OVER,
            (outcome as PhoneControlResult.Denied).reason,
        )
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS * 4)
        assertEquals(1, outcomes.size)
    }

    @Test fun keyguardRelockMidWaitCompletesDeviceLockedAndStops() {
        val driver = Driver()
        driver.enqueueCaptures(null)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        driver.advance(60)
        driver.locked = true
        driver.enqueueCaptures(canary)
        driver.advance(120)
        assertEquals(1, outcomes.size)
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Denied)
        assertEquals(
            PhoneControlDenial.DEVICE_LOCKED,
            (outcome as PhoneControlResult.Denied).reason,
        )
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS * 4)
        assertEquals(1, outcomes.size)
    }

    @Test fun lostOwnershipMidWaitCompletesNothingAndStopsPolling() {
        val driver = Driver()
        driver.enqueueCaptures(null)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        driver.advance(60)
        // Caller cancellation / run release / any session abort flips ownership
        // without the transaction inventing its own terminal result.
        driver.current = false
        val callsBefore = driver.captureCalls
        driver.enqueueCaptures(canary, canary, canary)
        driver.advance(PhoneControlLimits.SETTLE_TIMEOUT_MS * 4)
        assertTrue(outcomes.isEmpty())
        assertEquals(callsBefore, driver.captureCalls)
    }

    @Test fun fenceDominatesACaptureAvailableOnTheSameTick() {
        val driver = Driver()
        driver.enqueueCaptures(canary)
        driver.blocker = PhoneControlBlocker.STOPPED
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        gate(driver).start { outcomes += it }
        val outcome = outcomes.single()
        assertTrue(outcome is PhoneControlResult.Denied)
        assertEquals(PhoneControlDenial.STOPPED, (outcome as PhoneControlResult.Denied).reason)
        assertEquals(0, driver.captureCalls)
    }

    @Test fun waitStaysInsideTheExistingSettleBoundNotAnArbitraryWindow() {
        // The repair reuses the post-action settle lifecycle constants: no
        // new timeout exists to tune or regress.
        assertEquals(1_500L, PhoneControlLimits.SETTLE_TIMEOUT_MS)
        val driver = Driver()
        driver.enqueueCaptures(null)
        val outcomes = mutableListOf<PhoneControlResult<PhoneControlCapture>>()
        PhoneControlObservationReadiness(driver).start { outcomes += it }
        driver.advance(1_499)
        assertTrue(outcomes.isEmpty())
        driver.advance(1_500)
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.single() is PhoneControlResult.Failed)
    }
}
