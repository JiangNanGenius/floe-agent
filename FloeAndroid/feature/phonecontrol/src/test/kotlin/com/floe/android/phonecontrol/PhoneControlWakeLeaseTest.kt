// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.PriorityQueue
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/**
 * Deterministic ownership/resource tests for the task-owned bounded wake lease
 * (wake-lease74). The fake mirrors the real driver's generation fence: renew
 * and release accept exactly the held generation and record stale calls, so a
 * lost or late callback can be proven unable to touch a replacement lease.
 * All event kinds are recorded as (kind, generation, timeoutMs).
 */
class PhoneControlWakeLeaseTest {
    private val owner = PhoneControlOwner(UUID(1, 1), UUID(2, 2))
    private val other = PhoneControlOwner(UUID(3, 3), UUID(4, 4))
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
        var unlockDelay = 100L
        var gestureDelay = 700L
        var gestureCompletes = true
        var credentialShown = false
        val events = mutableListOf<Triple<String, Long, Long>>()
        private var nextWake = 0L
        var heldWake = NO_WAKE_LEASE
        private var cancelWakeExpiry: (() -> Unit)? = null

        private fun armWakeExpiry(generation: Long, timeoutMs: Long) {
            cancelWakeExpiry?.invoke()
            cancelWakeExpiry = after(timeoutMs) {
                if (heldWake == generation) {
                    events += Triple("expire", generation, timeoutMs)
                    heldWake = NO_WAKE_LEASE
                }
            }
        }

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
        fun kindCount(kind: String) = events.count { it.first == kind }
        fun lastReleaseIndex() = events.indexOfLast { it.first == "release" }
        fun acceptedCallsAfter(kind: String, afterIndex: Int) =
            events.withIndex().count { (index, event) -> index > afterIndex && event.first == kind }
        override fun suppressInput(until: Long) = Unit
        override fun acquireWake(timeoutMs: Long): Long {
            if (timeoutMs <= 0) return NO_WAKE_LEASE
            nextWake += 1
            heldWake = nextWake
            events += Triple("acquire", heldWake, timeoutMs)
            armWakeExpiry(heldWake, timeoutMs)
            return heldWake
        }
        override fun renewWake(generation: Long, timeoutMs: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake || timeoutMs <= 0) {
                events += Triple("renew-stale", generation, timeoutMs)
                return
            }
            events += Triple("renew", generation, timeoutMs)
            armWakeExpiry(generation, timeoutMs)
        }
        override fun releaseWake(generation: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake) {
                events += Triple("release-stale", generation, 0)
                return
            }
            events += Triple("release", generation, 0)
            heldWake = NO_WAKE_LEASE
            cancelWakeExpiry?.invoke(); cancelWakeExpiry = null
        }
        override fun credentialVisible() = credentialShown
        override fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean {
            revealCalls++
            after(gestureDelay) {
                if (gestureCompletes) credentialShown = true
                onGestureResult(gestureCompletes)
            }
            return true
        }
        override fun enterCredential(secret: CharArray): Boolean {
            inputCalls++
            if (unlockDelay >= 0) after(unlockDelay) { locked = false }
            return true
        }
        override fun requestLock(): Boolean {
            lockCalls++
            after(50) { locked = true }
            return true
        }
    }

    @Test fun wakeLeaseIsHeldAcrossTheWholePendingAttempt() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(500)
        assertEquals(1, d.kindCount("acquire"))
        assertEquals(0, d.kindCount("release"))
        assertEquals(1L, d.heldWake)
        // The reveal leg re-armed the same generation instead of a transient poke.
        assertEquals(1, d.kindCount("renew"))
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        // Success: the same owned lease is carried into the task-owned UI phase.
        assertEquals(0, d.kindCount("release"))
        assertEquals(1L, d.heldWake)
        assertEquals(3, d.kindCount("renew")) // reveal, submit and task lifetime transfer
        assertTrue(d.events.filter { it.first == "acquire" || it.first == "renew" }
            .all { it.third in 1..45_000L }) // every arm is bounded
        x.finish(owner)
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        d.advance(2_400)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun alreadyUnlockedPhoneTakesNoWakeLease() {
        val d = Driver().apply { locked = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        assertEquals(listOf(PhoneUnlockResult.ALREADY_UNLOCKED), results)
        assertEquals(0, d.kindCount("acquire"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
    }

    @Test fun successfulUnlockKeepsLeaseUntilFirstTaskRenewal() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        // Android expires an unrenewed 4s attempt lease before the 30s task tick.
        d.advance(30_000)
        assertEquals(1L, d.heldWake)
        assertEquals(0, d.kindCount("expire"))
        d.advance(31_300)
        assertEquals(1L, d.heldWake)
        assertEquals(0, d.kindCount("renew-stale"))
        x.finish(owner)
        assertEquals(NO_WAKE_LEASE, d.heldWake)
    }

    @Test fun failedAttemptReleasesTheLeaseWithoutWaitingForSettlement() {
        val d = Driver().apply { gestureCompletes = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_200) // gesture cancelled at 700 -> USER_REQUIRED settled by 1_100
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.kindCount("release")) // prompt, not deferred to settlement
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        d.advance(5_000)
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
        assertEquals(0, d.kindCount("renew-stale"))
        assertEquals(0, d.kindCount("release-stale"))
    }

    @Test fun cancelDuringPendingAttemptReleasesTheExactGeneration() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        x.cancel("call")
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        d.advance(6_000)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.kindCount("renew-stale"))
        assertEquals(0, d.kindCount("release-stale"))
    }

    @Test fun taskLeaseRenewsOnlyWhileTheOwnedSessionIsLiveAndScreenIsActuallyOn() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        var live = true
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { live }, results::add)
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(0, d.kindCount("release"))
        d.advance(31_300) // task-phase renewal tick lands just after now+30_000
        assertEquals(2, d.events.count { it.first == "renew" && it.second == 1L && it.third == 45_000L })
        live = false
        d.advance(61_300) // next tick re-checks ownership: released, renewal chain ends
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        val cut = d.lastReleaseIndex()
        d.advance(200_000)
        assertEquals(0, d.acceptedCallsAfter("renew", cut)) // never an idle poller
        // Existing ownership settlement is untouched by the lease drop.
        x.finish(owner); d.advance(202_400)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun staleCallsCannotTouchAReplacementGeneration() {
        val d = Driver().apply { gestureCompletes = false }; val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(5_000) // first attempt failed, released, settlement ended
        assertEquals(1, d.kindCount("release"))
        d.gestureCompletes = true
        x.unlock(other, "second", dummyCredential(), { true }) { }
        d.advance(5_800) // second attempt is mid-reveal on a fresh generation
        assertEquals(2, d.kindCount("acquire"))
        assertEquals(2L, d.heldWake)
        val cut = d.events.lastIndex
        // A lost callback from the discarded first generation can do nothing.
        d.renewWake(1L, 45_000L); d.releaseWake(1L)
        assertEquals(1, d.acceptedCallsAfter("renew-stale", cut))
        assertEquals(1, d.acceptedCallsAfter("release-stale", cut))
        assertEquals(2L, d.heldWake)
        d.advance(6_400) // second transaction succeeds and carries its own lease
        assertEquals(1, d.kindCount("release")) // still only the first generation ever released
    }

    @Test fun manualScreenOffEndsPendingAttemptAsTakeoverAndReleasesLease() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(600)
        d.interactive = false // the user actually pressed power
        x.onScreenOff()
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
        assertEquals(1, d.kindCount("release"))
        assertTrue(secret.all { it == '\u0000' })
        d.advance(6_000)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls) // never re-lock or re-wake a manually slept device
        assertEquals(1, d.kindCount("acquire")) // no wake without a new authorized transaction
    }

    @Test fun staleScreenOffWhileDisplayIsActuallyInteractiveKeepsTheAttempt() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        x.onScreenOff() // queued broadcast raced our own bounded wake; display is on
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(1, d.kindCount("acquire"))
        assertEquals(0, d.kindCount("release"))
        x.finish(owner)
        assertEquals(1, d.kindCount("release"))
    }

    @Test fun screenOffDuringTaskPhaseReleasesLeaseWithoutFurtherInputOrRenewals() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        d.interactive = false
        x.onScreenOff()
        assertEquals(1, d.kindCount("release"))
        val cut = d.lastReleaseIndex()
        d.advance(120_000)
        assertEquals(0, d.acceptedCallsAfter("renew", cut)) // never fights the screen-off
        assertEquals(0, d.acceptedCallsAfter("acquire", cut))
        // Task ownership semantics stay exactly as before: finish relocks on observation.
        x.finish(owner); d.advance(122_400)
        assertEquals(1, d.lockCalls)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun userTakeoverAfterUnlockReleasesTheCarriedLease() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(1_200)
        assertEquals(0, d.kindCount("release"))
        x.userInteraction()
        assertEquals(1, d.kindCount("release"))
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
        val cut = d.lastReleaseIndex()
        d.advance(200_000)
        assertEquals(0, d.acceptedCallsAfter("renew", cut)) // renewal timer was cancelled
        assertFalse(x.isSettling)
        assertEquals(0, d.lockCalls) // the takeover rule is preserved with a lease held
    }

    @Test fun clientServiceCloseReleasesTheTaskLeaseAndEndsRenewals() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(1_200)
        x.close()
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        assertFalse(x.isSettling)
        assertEquals(PhoneRelockResult.USER_REQUIRED, x.lastRelockReceipt?.result)
        val cut = d.lastReleaseIndex()
        d.advance(200_000)
        assertEquals(0, d.acceptedCallsAfter("renew", cut))
        assertEquals(0, d.lockCalls)
    }

    @Test fun replacementOwnerCannotTakeTheLeaseWhileTaskUnlockOwnershipHolds() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val first = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, first::add)
        d.advance(1_200)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), first)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(other, "steal", secret, { true }, results::add)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(1, d.kindCount("acquire")) // no second lease, no adoption
        assertEquals(1L, d.heldWake)
        assertTrue(secret.all { it == '\u0000' })
    }

    @Test fun safetyStopHookReleasesLeaseWithoutTouchingOwnership() {
        // Mirrors PhoneControlSession.stop(): the wake resource ends now, but
        // STOPPED is not a takeover, so the existing relock ownership path is
        // unchanged and finish still relocks on observation.
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(1_200)
        x.releaseTaskWake()
        assertEquals(1, d.kindCount("release"))
        val cut = d.lastReleaseIndex()
        d.advance(120_000)
        assertEquals(0, d.acceptedCallsAfter("renew", cut))
        x.finish(owner); d.advance(122_400)
        assertEquals(1, d.lockCalls)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun releaseTaskWakeIsExactOwnerGuarded() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(1_200)
        x.releaseTaskWake(other) // a foreign owner cannot drop this owner's resource
        assertEquals(0, d.kindCount("release"))
        assertEquals(1L, d.heldWake)
        x.releaseTaskWake(owner) // the exact owner's task-level end path can
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
    }

    @Test fun everyWakeArmIsBoundedAndNoLeaseOutlivesOwnerEnd() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_200)
        x.finish(owner)
        d.advance(130_000)
        assertEquals(1, d.kindCount("acquire"))
        assertTrue(d.events.all { it.first != "acquire" || it.third in 1..45_000L })
        assertTrue(d.events.all { it.first != "renew" || it.third in 1..45_000L })
        assertEquals(1, d.kindCount("release"))
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        assertEquals(0, d.kindCount("renew-stale"))
        assertEquals(0, d.kindCount("release-stale"))
    }
}
