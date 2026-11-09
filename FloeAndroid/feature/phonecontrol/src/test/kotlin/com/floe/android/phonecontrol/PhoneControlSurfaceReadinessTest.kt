// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.PriorityQueue
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/**
 * Authored-only unlock transaction scenarios for the real failure boundary
 * observed on the Samsung device (case G): the reveal gesture completed but no
 * credential surface was ever observed, so the transaction must end exactly
 * once as USER_REQUIRED without any credential input — and conversely, a
 * surface that becomes ready late inside the bounded observation must dispatch
 * at most once. The driver fake below models the new surface contract:
 * readiness may only appear through an actually observed surface flip, never
 * through gesture acceptance alone.
 */
class PhoneControlSurfaceReadinessTest {
    private val owner = PhoneControlOwner(UUID(1, 1), UUID(2, 2))
    private fun dummyCredential() = charArrayOf('0', '0')

    private class Driver : PhoneUnlockDriver {
        private class Work(val at: Long, val order: Long, val action: () -> Unit) {
            var cancelled = false
        }
        private val queue = PriorityQueue<Work>(compareBy<Work> { it.at }.thenBy { it.order })
        private var order = 0L
        override var locked = true
        override var now = 0L
        override var interactive = true
        var inputCalls = 0
        var revealCalls = 0
        var lockCalls = 0
        var wakeReleases = 0
        var gestureDelay = 700L
        var unlockDelay = 100L
        // Models a surface that stays unobserved for the whole bounded attempt
        // (missing/foreign/stale/ambiguous all collapse to false here).
        var credentialShown = false
        // Models the dispatch-time re-resolve: false means the freshly resolved
        // surface lost its trust at the moment of the single hand-off.
        var enterResult = true
        private var nextWake = 0L
        var heldWake = NO_WAKE_LEASE
        override fun after(delay: Long, action: () -> Unit): () -> Unit {
            val value = Work(now + delay, ++order, action)
            queue.add(value)
            return { value.cancelled = true }
        }
        fun advance(to: Long) {
            require(to >= now)
            while (queue.peek()?.at?.let { it <= to } == true) {
                val next = queue.remove(); now = next.at
                if (!next.cancelled) next.action()
            }
            now = to
        }
        override fun suppressInput(until: Long) = Unit
        override fun acquireWake(timeoutMs: Long): Long {
            if (timeoutMs <= 0) return NO_WAKE_LEASE
            nextWake += 1
            heldWake = nextWake
            return heldWake
        }
        override fun renewWake(generation: Long, timeoutMs: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake || timeoutMs <= 0) return
        }
        override fun releaseWake(generation: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake) return
            heldWake = NO_WAKE_LEASE
            wakeReleases += 1
        }
        override fun credentialVisible() = credentialShown
        override fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean {
            revealCalls++
            // The callback only reports the actual gesture result. Unlike the
            // older fixtures it never fabricates surface readiness: readiness
            // must arrive through an actually observed credentialShown flip.
            after(gestureDelay) { onGestureResult(true) }
            return true
        }
        override fun enterCredential(secret: CharArray): Boolean {
            inputCalls++
            if (enterResult && unlockDelay >= 0) after(unlockDelay) { locked = false }
            return enterResult
        }
        override fun requestLock(): Boolean {
            lockCalls++
            after(50) { locked = true }
            return true
        }
    }

    @Test fun neverReadySurfaceEndsUserRequiredWithoutAnyCredentialInput() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(1, d.wakeReleases)
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        assertTrue(secret.all { it == '\u0000' })
        // Still actually locked: settlement confirms the existing keyguard and
        // never dispatches a redundant lock request.
        assertEquals(0, d.lockCalls)
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun lateSurfaceReadyInsideSettleWindowDispatchesExactlyOnce() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        // Readiness genuinely appears later: after the reveal callback landed
        // (700) but inside the 1500ms settle window (deadline ~2200).
        d.after(1_800) { d.credentialShown = true }
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
        // The observed success carries the same owned lease; no release yet.
        assertEquals(0, d.wakeReleases)
        x.finish(owner); d.advance(d.now + 2_500)
        assertEquals(1, d.lockCalls)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun surfaceLostBetweenObservationAndDispatchNeverRetriesInput() {
        val d = Driver().apply { credentialShown = true; enterResult = false }
        val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(8_000)
        // One pre-displayed visibility observation, one dispatch attempt that
        // the fresh re-resolve refused, and then the final user prompt: never
        // another credential entry attempt.
        assertEquals(1, d.inputCalls)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(0, d.revealCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(1, d.wakeReleases)
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun cancelDuringSurfaceObservationIgnoresLateReadiness() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(1_500) // reveal callback already landed; settle observation is open
        x.cancel("call")
        d.after(300) { d.credentialShown = true }
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(1, d.wakeReleases)
    }

    @Test fun unresponsiveAttemptStillEndsEveryOwnedWakeBeforeCallbackDeadline() {
        // A lost gesture callback with no observed surface must not leave a
        // wake lease behind once the bounded deadline reports the outcome.
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(100) // cancel before the reveal can even be dispatched at 400
        x.cancel("call")
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(1, d.wakeReleases)
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        assertEquals(0, d.inputCalls)
    }
}
