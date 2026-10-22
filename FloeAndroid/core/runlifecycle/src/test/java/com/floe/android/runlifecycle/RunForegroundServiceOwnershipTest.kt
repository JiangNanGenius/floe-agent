// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Round-4 REAL-STATE ownership regressions (Main review): every check
 * runs against the single process truth [RunForegroundState] — the very
 * object the production service fences through, so this is NOT a parallel
 * copy of the decision. Service instances are represented by their
 * identity objects exactly as production passes `this`; notification
 * stamps are plain longs. The matrix: the CURRENT instance's real end
 * and destroy end protection truthfully; a REPLACED instance's late
 * destroy / start-denial / denial / confirm / idle-stop callbacks clear
 * NOTHING the newer live instance owns (truth flag, applied stamp,
 * listener, denial slot, stop lambda). The wake decision itself — the
 * canonical process handle — is OwnedWorkWakeCoordinatorTest's domain
 * and is deliberately not duplicated; only the state→wake INPUT seam is
 * pinned here. Android framework surfaces (real startForeground, the
 * instance-kill handoff, notifications) remain Main's App/device gate.
 */
class RunForegroundServiceOwnershipTest {

    private class RecordingListener {
        var calls = 0
        val onChange: () -> Unit = { calls += 1 }
    }

    @Before
    fun resetState() {
        RunForegroundState.resetForTesting()
    }

    /** The pre-fix shape ended protection unconditionally in onDestroy
     *  AFTER an identity-fenced listener unbind; the fence now covers
     *  the whole shared-truth mutation, atomically. */
    @Test
    fun currentInstanceRealEndAndDestroyEndProtectionTruthfully() {
        val instance = Any()
        val listener = RecordingListener()
        RunForegroundState.bindServiceListener(instance, listener.onChange)
        assertTrue(RunForegroundState.isCurrentService(instance))
        // The actual startForeground success of the live instance
        // confirms truth AND applies the rendered stamp together.
        assertTrue(RunForegroundState.confirmForeground(instance, 7L))
        assertTrue(RunForegroundState.foreground.value)
        assertEquals(7L, RunForegroundState.appliedStamp)
        // A real end/failure path (blocked promotion) of the CURRENT
        // instance ends protection truthfully — never an invented "true".
        assertTrue(RunForegroundState.endForeground(instance))
        assertFalse(RunForegroundState.foreground.value)
        assertEquals(-1L, RunForegroundState.appliedStamp)
        // The live listener still belongs to the current instance:
        RunForegroundState.notifyOwnedSetChanged()
        assertEquals(1, listener.calls)
        // Then the current instance's REAL destroy: listener, ownership,
        // stamp and truth retire in ONE atomic fenced step.
        assertTrue(RunForegroundState.confirmForeground(instance, 8L))
        assertTrue(RunForegroundState.retireService(instance))
        assertFalse(RunForegroundState.foreground.value)
        assertEquals(-1L, RunForegroundState.appliedStamp)
        assertFalse(RunForegroundState.isCurrentService(instance))
        // The retired instance's callback can never fire again.
        RunForegroundState.notifyOwnedSetChanged()
        assertEquals(1, listener.calls)
    }

    @Test
    fun staleDestroyAfterReplacementKeepsNewerProtectionIntact() {
        val oldInstance = Any()
        val newerInstance = Any()
        val oldListener = RecordingListener()
        val newerListener = RecordingListener()
        RunForegroundState.bindServiceListener(oldInstance, oldListener.onChange)
        assertTrue(RunForegroundState.confirmForeground(oldInstance, 1L))
        // Android replaces the service: the NEWER instance binds (its
        // onCreate), confirms, and ONLY THEN the old instance's late
        // onDestroy runs — the exact regression the round-4 finding
        // flagged ("unconditional markForegroundEnded after identity-
        // fenced unbind" cleared the newer live protection).
        RunForegroundState.bindServiceListener(newerInstance, newerListener.onChange)
        assertTrue(RunForegroundState.confirmForeground(newerInstance, 2L))
        // The owned-set notify now reaches the NEWER listener only.
        RunForegroundState.notifyOwnedSetChanged()
        assertEquals(1, newerListener.calls)
        assertEquals(0, oldListener.calls)
        // The replaced instance's late destroy mutates NOTHING:
        assertFalse(RunForegroundState.retireService(oldInstance))
        assertTrue("a stale destroy can never clear a newer live foreground",
            RunForegroundState.foreground.value)
        assertEquals(2L, RunForegroundState.appliedStamp)
        assertTrue(RunForegroundState.isCurrentService(newerInstance))
        assertFalse(RunForegroundState.isCurrentService(oldInstance))
        // The newer listener stays installed across the stale retire:
        RunForegroundState.notifyOwnedSetChanged()
        assertEquals(2, newerListener.calls)
        assertEquals(0, oldListener.calls)
        // And the newer instance's OWN real destroy still ends
        // protection truthfully (no invented survival, no stuck flag):
        assertTrue(RunForegroundState.retireService(newerInstance))
        assertFalse(RunForegroundState.foreground.value)
        assertEquals(-1L, RunForegroundState.appliedStamp)
    }

    @Test
    fun lateStartDenialsAndConfirmsFromAStaleInstanceChangeNothing() {
        val stale = Any()
        val current = Any()
        RunForegroundState.bindServiceListener(stale, RecordingListener().onChange)
        assertTrue(RunForegroundState.confirmForeground(stale, 3L))
        RunForegroundState.bindServiceListener(current, RecordingListener().onChange)
        assertTrue(RunForegroundState.confirmForeground(current, 4L))
        // Late START-DENIAL arming from the stale service (its
        // onStartCommand/promote failure arriving after replacement):
        // the shared denial slot — an acquirer's honest answer source —
        // stays clean.
        assertFalse(RunForegroundState.reportServiceDenial(stale,
            RunForegroundFailure.StartDenied("stale-late-denial")))
        assertNull(RunForegroundState.takeDenial())
        // Late end from the stale instance: refused, truth stays.
        assertFalse(RunForegroundState.endForeground(stale))
        assertTrue(RunForegroundState.foreground.value)
        // A stale "success" can neither claim nor re-stamp the truth.
        assertFalse(RunForegroundState.confirmForeground(stale, 99L))
        assertEquals(4L, RunForegroundState.appliedStamp)
        // A stale idle-stop callback may not run its stopSelf lambda nor
        // clear the newer protection.
        var staleStopRan = false
        assertFalse(RunForegroundState.stopWhenIdle(stale) { staleStopRan = true })
        assertFalse(staleStopRan)
        assertTrue(RunForegroundState.foreground.value)
        // The CURRENT instance keeps honest control end-to-end: its
        // denial arms and drains, and its real idle-stop ends protection
        // AND actually runs the stop.
        assertTrue(RunForegroundState.reportServiceDenial(current,
            RunForegroundFailure.NotificationsBlocked("channel-blocked")))
        assertEquals("foreground_notifications_blocked:channel-blocked",
            RunForegroundState.takeDenial()?.message)
        var currentStopRan = false
        assertTrue(RunForegroundState.stopWhenIdle(current) { currentStopRan = true })
        assertTrue(currentStopRan)
        assertFalse(RunForegroundState.foreground.value)
        assertEquals(-1L, RunForegroundState.appliedStamp)
    }

    /** State→wake INPUT seam: every wake sync — including a STALE
     *  instance's late onDestroy `syncWake()` — reads
     *  `foreground.value` and `!hasHeldWork()`. The round-4 defect made
     *  the stale retire fabricate foreground=false for that later sync;
     *  after the fence, the flags a late sync observes are exactly the
     *  newer truth. The canonical wake decisions themselves live in
     *  OwnedWorkWakeCoordinatorTest and are NOT duplicated here. */
    @Test
    fun fencedTruthIsExactlyWhatLateWakeSyncsRead() {
        val stale = Any()
        val current = Any()
        RunForegroundState.bindServiceListener(stale, RecordingListener().onChange)
        assertTrue(RunForegroundState.confirmForeground(stale, 1L))
        RunForegroundState.bindServiceListener(current, RecordingListener().onChange)
        assertTrue(RunForegroundState.confirmForeground(current, 2L))
        assertFalse(RunForegroundState.retireService(stale))
        // The exact inputs the service's syncWake passes on ANY instance:
        val foregroundFlag = RunForegroundState.foreground.value
        val ownedEmptyFlag = !RunForegroundState.hasHeldWork()
        assertTrue("newer confirmation survives the stale retire: a late sync " +
            "sees the REAL foreground, never a stale self-clear", foregroundFlag)
        // The owned-set flag remains the registry's real answer (nothing
        // registered in this JVM scenario), so a late sync still feeds
        // only REAL settle state into the canonical wake decision.
        assertTrue(ownedEmptyFlag)
        // A current-instance REAL end flips the flag back honestly (the
        // wake's later real-settlement sync then also sees truth=false):
        assertTrue(RunForegroundState.endForeground(current))
        assertFalse(RunForegroundState.foreground.value)
    }
}
