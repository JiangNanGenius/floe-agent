// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.PriorityQueue
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class PhoneControlUnlockerTest {
    private val owner = PhoneControlOwner(UUID(1, 1), UUID(2, 2))
    private val other = PhoneControlOwner(UUID(3, 3), UUID(4, 4))
    private fun dummyCredential() = charArrayOf('0', '0')

    /**
     * Deterministic clock plus an Android-like async reveal: the gesture
     * callback lands on the queue and cannot be recalled, so fences, deadlines
     * and observed-state decisions are exercised exactly like the service host.
     * Readiness is an actually modeled state, never an assumption:
     * [revealReadiness] derives from the modeled power flag and the modeled
     * trusted SystemUI window flag, exactly like the real driver's two-layer
     * gate. These fixtures model a device that IS genuinely ready (the old
     * reveal-on-timeout flows all ran on actually awake panels), so their
     * original timings and assertions are preserved; the never-awake boundary
     * is exercised in PhoneControlWakeReadinessTest.
     */
    private class Driver : PhoneUnlockDriver {
        private class Work(val at: Long, val order: Long, val action: () -> Unit) {
            var cancelled = false
        }
        private val queue = PriorityQueue<Work>(compareBy<Work> { it.at }.thenBy { it.order })
        private var order = 0L
        override var locked = true
        override var now = 0L
        override var interactive = true
        var systemUiWindow = true
        val wakeStages = mutableListOf<String>()
        var inputCalls = 0
        var revealCalls = 0
        var lockCalls = 0
        var unlockDelay = 100L
        var gestureDelay = 700L
        var acceptLock = true
        var completeLock = true
        var gestureCallback = true
        var gestureCompletes = true
        var acceptReveal = true
        var credentialShown = false
        var wakeUnlockDelay = -1L
        // Generation-fenced lease mirror of the real driver contract.
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
            if (wakeUnlockDelay >= 0) after(wakeUnlockDelay) { locked = false }
            return heldWake
        }
        override fun renewWake(generation: Long, timeoutMs: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake || timeoutMs <= 0) return
        }
        override fun releaseWake(generation: Long) {
            if (generation == NO_WAKE_LEASE || generation != heldWake) return
            heldWake = NO_WAKE_LEASE
        }
        override fun credentialVisible() = credentialShown
        override fun revealReadiness(): PhoneRevealReadiness = when {
            !interactive -> PhoneRevealReadiness.DISPLAY_IDLE
            credentialShown -> PhoneRevealReadiness.CREDENTIAL_VISIBLE
            systemUiWindow -> PhoneRevealReadiness.REVEAL_READY
            else -> PhoneRevealReadiness.SYSTEM_UI_PENDING
        }
        override fun traceWakeStage(stage: String) { wakeStages += stage }
        override fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean {
            revealCalls++
            if (!acceptReveal) return false
            after(gestureDelay) {
                if (!gestureCallback) return@after
                if (gestureCompletes) credentialShown = true
                onGestureResult(gestureCompletes)
            }
            return true
        }
        override fun enterCredential(secret: CharArray): Boolean {
            inputCalls++
            // unlockDelay < 0 models a dispatch the system never completes.
            if (unlockDelay >= 0) after(unlockDelay) { locked = false }
            return true
        }
        override fun requestLock(): Boolean {
            lockCalls++
            if (acceptLock && completeLock) after(50) { locked = true }
            return acceptLock
        }
    }

    @Test fun taskEndReleasesOnlyAfterActualLockWasObserved() {
        val d = Driver(); val x = PhoneControlUnlocker(d); val results = mutableListOf<PhoneUnlockResult>()
        val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(2_300)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertTrue(secret.all { it == '\u0000' })
        x.finish(owner)
        assertTrue(x.isSettling)
        assertNull(x.lastRelockReceipt)
        d.advance(2_400)
        assertTrue(d.locked)
        assertEquals(PhoneRelockReceipt(owner, PhoneRelockResult.LOCKED), x.lastRelockReceipt)
        assertFalse(x.isSettling)
        x.finish(owner)
        assertEquals(1, d.lockCalls)
    }

    @Test fun cancellationAfterInputSettlesALateSystemUnlockWithoutRetyping() {
        val d = Driver().apply { unlockDelay = 500 }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(1_100)
        x.cancel("call")
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertTrue(secret.all { it == '\u0000' })
        d.advance(4_000)
        assertTrue(d.locked)
        assertEquals(1, d.inputCalls)
        assertEquals(1, d.lockCalls)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
        assertEquals(1, results.size)
    }

    @Test fun userTakeoverStopsPendingCleanupAndNeverRelocksTheirPhone() {
        val d = Driver().apply { unlockDelay = 500 }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_100)
        x.cancel("call")
        x.userInteraction()
        d.advance(4_000)
        x.finish(owner)
        assertFalse(d.locked)
        assertEquals(0, d.lockCalls)
        assertFalse(x.isSettling)
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
    }

    @Test fun alreadyUnlockedPhoneNeverAcquiresTaskRelockOwnership() {
        val d = Driver().apply { locked = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        x.finish(owner); d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.ALREADY_UNLOCKED), results)
        assertEquals(0, d.lockCalls)
        assertNull(x.lastRelockReceipt)
    }

    @Test fun anotherTaskCannotFinishThisOwnersUnlock() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(2_300); x.finish(other); d.advance(2_500)
        assertEquals(0, d.lockCalls)
        x.finish(owner); d.advance(2_700)
        assertEquals(1, d.lockCalls)
        assertEquals(owner, x.lastRelockReceipt?.owner)
    }

    @Test fun deniedLockRequestRequiresUserAndIsNotRetried() {
        val d = Driver().apply { acceptLock = false }; val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(2_300); x.finish(owner); d.advance(5_000)
        assertEquals(PhoneRelockResult.USER_REQUIRED, x.lastRelockReceipt?.result)
        assertEquals(1, d.lockCalls)
        assertFalse(d.locked)
    }

    @Test fun acceptedDispatchWithoutActualLockNeverReportsLocked() {
        val d = Driver().apply { completeLock = false }; val x = PhoneControlUnlocker(d)
        x.unlock(owner, "call", dummyCredential(), { true }) { }
        d.advance(2_300); x.finish(owner); d.advance(5_000)
        assertEquals(PhoneRelockResult.USER_REQUIRED, x.lastRelockReceipt?.result)
        assertEquals(1, d.lockCalls)
        assertFalse(x.isSettling)
    }

    @Test fun finishBeforeCredentialInputStopsAllRemainingInput() {
        val d = Driver(); val x = PhoneControlUnlocker(d); val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(100); x.finish(owner); d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun stoppedOwnerCannotRepeatCredentialAttempt() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        x.unlock(owner, "first", dummyCredential(), { true }) { }
        d.advance(100); x.cancel("first"); d.advance(4_000)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "second", secret, { true }, results::add)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(0, d.inputCalls)
    }

    @Test fun serviceLossCannotLeaveOldInputOrRelockAReplacementSession() {
        val d = Driver().apply { unlockDelay = 500 }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(1_100)
        x.close()
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(1, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertFalse(x.isSettling)
        assertEquals(PhoneRelockResult.USER_REQUIRED, x.lastRelockReceipt?.result)
    }

    // ------------------------------------------------------------------
    // Async reveal/readiness boundaries (driver74).
    // ------------------------------------------------------------------

    @Test fun cancelledRevealGestureNeverEntersCredential() {
        val d = Driver().apply { gestureCompletes = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun lostGestureCallbackWithoutObservedSurfaceRequiresUserOnce() {
        val d = Driver().apply { gestureCallback = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(6_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun deadlineRecoveryUsesObservedSurfaceWhenCallbackIsLost() {
        val d = Driver().apply { gestureCallback = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        // The window is actually observed before the callback deadline fires.
        d.credentialShown = true
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
    }

    @Test fun inputDispatchWithoutObservedUnlockNeverReportsUnlocked() {
        val d = Driver().apply { unlockDelay = -1L }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.inputCalls)
        assertEquals(1, d.revealCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun revealDispatchRefusalEndsImmediatelyWithoutCallbackWaiting() {
        val d = Driver().apply { acceptReveal = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(400)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(1, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertTrue(secret.all { it == '\u0000' })
        d.advance(4_000)
        assertEquals(0, d.lockCalls)
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun wakeCompletedUnlockNeedsNoRevealOrInput() {
        val d = Driver().apply { wakeUnlockDelay = 200 }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(400)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(0, d.revealCalls)
        assertEquals(0, d.inputCalls)
        x.finish(owner); d.advance(1_500)
        assertEquals(1, d.lockCalls)
        assertEquals(PhoneRelockResult.LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun preDisplayedCredentialSurfaceSkipsReveal() {
        val d = Driver().apply { credentialShown = true }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(400)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(0, d.revealCalls)
        assertEquals(1, d.inputCalls)
    }

    @Test fun cancelDuringPendingGestureIgnoresLateCallbackWithoutInput() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(600)
        x.cancel("call")
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun revokedAuthorityBeforeGestureCallbackNeverEntersCredential() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        var current = true
        x.unlock(owner, "call", secret, { current }, results::add)
        d.advance(600)
        current = false
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(secret.all { it == '\u0000' })
    }

    @Test fun takeoverDuringPendingGestureNeverTypesOrLocks() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        x.userInteraction()
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertTrue(d.locked)
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
    }

    @Test fun closeDuringPendingGestureStopsLateCallbackFromNewState() {
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        x.close()
        d.advance(4_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.inputCalls)
        assertEquals(0, d.lockCalls)
        assertFalse(x.isSettling)
        assertEquals(PhoneRelockResult.USER_REQUIRED, x.lastRelockReceipt?.result)
    }
}
