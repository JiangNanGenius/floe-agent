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

    private class Driver : PhoneUnlockDriver {
        private class Work(val at: Long, val order: Long, val action: () -> Unit) {
            var cancelled = false
        }
        private val queue = PriorityQueue<Work>(compareBy<Work> { it.at }.thenBy { it.order })
        private var order = 0L
        override var locked = true
        override var now = 0L
        var inputCalls = 0
        var lockCalls = 0
        var unlockDelay = 100L
        var acceptLock = true
        var completeLock = true
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
        override fun wake() = Unit
        override fun showCredential() = true
        override fun enterCredential(secret: CharArray): Boolean {
            inputCalls++
            after(unlockDelay) { locked = false }
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
}
