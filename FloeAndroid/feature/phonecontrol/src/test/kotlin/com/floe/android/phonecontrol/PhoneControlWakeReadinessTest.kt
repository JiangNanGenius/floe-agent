// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.PriorityQueue
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/**
 * Authored-only regression for the proven case-H source defect: the old
 * observeWake advanced to the reveal as soon as its first observation window
 * elapsed, even though every poll had read the display as not actually
 * interactive. Here the ONE reveal may only dispatch behind genuinely observed
 * readiness, and this fake models the real observation channels: independent
 * power-interactive, display STATE_ON and trusted SystemUI window flags that
 * change only through the fake's own scheduled callbacks — exactly like real
 * power/window events — plus the closed wake-outcome stage the transaction
 * records so a run proves which branch executed. A deadline alone can never
 * produce a gesture, a credential input or a reveal-side lease renewal.
 */
class PhoneControlWakeReadinessTest {
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
        // The three modeled platform observation channels. Each flips only
        // through a queued callback scheduled by the test, mirroring a real
        // power/display/window event landing on the service looper.
        override var interactive = true
        var displayOn = true
        var systemUiWindow = true
        // The poll channel (credentialVisible) and the readiness channel are
        // independent, so the readiness CREDENTIAL_VISIBLE branch is reachable
        // exactly like the real two-scan race.
        var pollCredentialVisible = false
        var readyCredentialVisible = false
        var inputCalls = 0
        var revealCalls = 0
        var lockCalls = 0
        var readinessChecks = 0
        var wakeReleases = 0
        var gestureDelay = 700L
        var unlockDelay = 100L
        private var nextWake = 0L
        var heldWake = NO_WAKE_LEASE
        val wakeStages = mutableListOf<String>()
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
        override fun credentialVisible() = pollCredentialVisible
        override fun revealReadiness(): PhoneRevealReadiness {
            readinessChecks++
            return when {
                !interactive || !displayOn -> PhoneRevealReadiness.DISPLAY_IDLE
                readyCredentialVisible -> PhoneRevealReadiness.CREDENTIAL_VISIBLE
                systemUiWindow -> PhoneRevealReadiness.REVEAL_READY
                else -> PhoneRevealReadiness.SYSTEM_UI_PENDING
            }
        }
        override fun traceWakeStage(stage: String) { wakeStages += stage }
        override fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean {
            revealCalls++
            after(gestureDelay) {
                // A completed swipe legitimately resolves the credential
                // surface on both observation channels — never an acceptance
                // alone, and never before the gesture callback lands.
                pollCredentialVisible = true
                readyCredentialVisible = true
                onGestureResult(true)
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

    @Test fun awakePanelAtFirstDeadlineRevealsOnceWithInitialStage() {
        // The healthy path keeps its exact timing: reveal is consulted only
        // when the first window elapsed un-resolved, and proceeds because the
        // observation says genuinely ready — not because the deadline passed.
        val d = Driver(); val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(350)
        assertEquals(0, d.revealCalls)
        assertEquals(0, d.readinessChecks) // the pre-deadline polls never assume readiness
        assertTrue(d.wakeStages.isEmpty())
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(listOf(WAKE_READY_INITIAL), d.wakeStages)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
    }

    @Test fun neverAwakePanelTimesOutInsideBoundedWindowWithZeroRevealZeroInput() {
        // The explicit never-awake regression: with the power flag false for
        // the whole attempt the old code would already have swiped at 400.
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(1_500)
        assertEquals(0, d.revealCalls) // the exact case-H premature-gesture boundary
        assertEquals(0, d.inputCalls)
        assertTrue(d.readinessChecks > 0) // actual readiness really was observed
        assertTrue(d.wakeStages.isEmpty()) // no decision yet: the window is still open
        d.advance(3_300)
        assertTrue(results.isEmpty())
        d.advance(3_500) // the overall bounded window (400 + 3000) ends here
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(listOf(WAKE_TIMEOUT), d.wakeStages)
        assertEquals(0, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(1, d.wakeReleases) // the owned lease ends with the attempt
        assertEquals(NO_WAKE_LEASE, d.heldWake)
        assertTrue(secret.all { it == '\u0000' })
        d.advance(8_000)
        assertEquals(0, d.lockCalls) // the keyguard is still actually locked
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun lateWakePowerCallbackInsideBoundedWindowRevealsExactlyOnce() {
        // Case-H shape repaired: Dozing at the first deadline, the panel truly
        // wakes later; the single reveal then dispatches once, behind the real
        // power callback, and the transaction still completes with exactly one
        // credential input.
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.after(1_000) { d.interactive = true }
        d.advance(900)
        assertEquals(0, d.revealCalls)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(listOf(WAKE_READY_LATE), d.wakeStages)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
        assertEquals(0, d.wakeReleases) // observed success carries the owned lease on
    }

    @Test fun displayStatePendingAfterInteractiveStillDefersTheOneReveal() {
        // The two power channels are observed independently: isInteractive
        // alone must not qualify the reveal while the panel state is pending.
        val d = Driver().apply { displayOn = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.after(2_000) { d.displayOn = true }
        d.advance(1_900)
        assertEquals(0, d.revealCalls)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(listOf(WAKE_READY_LATE), d.wakeStages)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
    }

    @Test fun trustedSystemUiWindowAppearingLateRevealsExactlyOnce() {
        // Awake panel, but no trusted live SystemUI window reported yet: the
        // reveal waits for the real window event inside the bounded window.
        val d = Driver().apply { systemUiWindow = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.after(900) { d.systemUiWindow = true }
        d.advance(800)
        assertEquals(0, d.revealCalls)
        assertTrue(d.readinessChecks > 0)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(listOf(WAKE_READY_LATE), d.wakeStages)
        assertEquals(1, d.revealCalls)
        assertEquals(1, d.inputCalls)
    }

    @Test fun windowNeverTrustedInsideBoundedWindowTimesOutWithoutGesture() {
        val d = Driver().apply { systemUiWindow = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.USER_REQUIRED), results)
        assertEquals(listOf(WAKE_TIMEOUT), d.wakeStages)
        assertEquals(0, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(1, d.wakeReleases)
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(PhoneRelockResult.ALREADY_LOCKED, x.lastRelockReceipt?.result)
    }

    @Test fun credentialSurfaceAtReadinessEntersWithoutAnySwipe() {
        // A resolved credential surface seen through the readiness channel is
        // entered directly; the reveal swipe is never dispatched over it.
        val d = Driver().apply { readyCredentialVisible = true }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.UNLOCKED), results)
        assertEquals(0, d.revealCalls)
        assertEquals(1, d.inputCalls)
        assertEquals(listOf(WAKE_READY_INITIAL), d.wakeStages)
        assertEquals(0, d.wakeReleases)
    }

    @Test fun cancelDuringReadinessWaitNeverGesturesOrTypes() {
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(600) // inside the bounded readiness wait, before any decision
        x.cancel("call")
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.revealCalls)
        assertEquals(0, d.inputCalls)
        assertEquals(1, d.wakeReleases)
        assertTrue(d.wakeStages.isEmpty())
        assertTrue(secret.all { it == '\u0000' })
        d.advance(8_000)
        assertEquals(1, results.size) // the late readiness polls stayed fenced
        assertEquals(0, d.lockCalls)
    }

    @Test fun revokedAuthorityDuringReadinessWaitIsFinal() {
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        var current = true
        x.unlock(owner, "call", secret, { current }, results::add)
        d.advance(600)
        current = false
        d.advance(8_000)
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(0, d.revealCalls) // a revoked task never earns a later reveal
        assertEquals(0, d.inputCalls)
        assertTrue(d.wakeStages.isEmpty())
        assertTrue(secret.all { it == '\u0000' })
        assertEquals(1, d.wakeReleases)
    }

    @Test fun takeoverDuringReadinessWaitEndsAttemptWithoutGesture() {
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>()
        x.unlock(owner, "call", dummyCredential(), { true }, results::add)
        d.advance(600)
        x.userInteraction()
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
        assertEquals(0, d.revealCalls)
        assertEquals(1, d.wakeReleases)
        d.advance(8_000)
        assertEquals(0, d.lockCalls) // never fights the takeover
    }

    @Test fun screenOffSignalDuringReadinessWaitEndsAttemptAndReleasesLease() {
        // The manual screen-off fence keeps its conservative behavior even in
        // the new wait: an actually idle display makes the end signal real.
        val d = Driver().apply { interactive = false }; val x = PhoneControlUnlocker(d)
        val results = mutableListOf<PhoneUnlockResult>(); val secret = dummyCredential()
        x.unlock(owner, "call", secret, { true }, results::add)
        d.advance(600)
        x.onScreenOff()
        assertEquals(listOf(PhoneUnlockResult.CANCELLED), results)
        assertEquals(PhoneRelockResult.USER_TAKEN_OVER, x.lastRelockReceipt?.result)
        assertEquals(0, d.revealCalls)
        assertEquals(1, d.wakeReleases)
        assertTrue(secret.all { it == '\u0000' })
        d.advance(8_000)
        assertEquals(0, d.lockCalls)
        assertEquals(0, d.inputCalls)
    }
}
