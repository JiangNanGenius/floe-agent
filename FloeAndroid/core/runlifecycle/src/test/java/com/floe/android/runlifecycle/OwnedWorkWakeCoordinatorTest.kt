// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The real-work wake contract: ONE actual process-owned PARTIAL wake,
 * bound to the live owned-operation set — acquired only over confirmed
 * foreground, kept across service-instance handoff while work is real
 * (across DISTINCT per-instance handle objects, which is the production
 * shape Main's round-3 review found broken: same-handle tests could not
 * see stranding or stacking), released only when the settled set empties
 * even if every service instance is already destroyed, and never on
 * cancellation, flag flicker, a stale instance token or time.
 */
class OwnedWorkWakeCoordinatorTest {

    private class FakeWakeHandle : CpuWakeHandle {
        var held = false
        var acquires = 0
        var releases = 0
        override fun acquireWake() {
            if (!held) { held = true; acquires += 1 }
        }
        override fun releaseWake() {
            if (held) { held = false; releases += 1 }
        }
        override fun isWakeHeld() = held
    }

    private class FakeSettleWatch : SettleWatch {
        var schedules = 0
        var cancels = 0
        override fun scheduleSettledCheck() { schedules += 1 }
        override fun cancelSettledCheck() { cancels += 1 }
    }

    @Before
    fun reset() = OwnedWorkWakeCoordinator.resetForTesting()

    @Test
    fun pureDecideMatrix() {
        // No wake without a confirmed real service.
        assertEquals(WakeAction.IDLE, OwnedWorkWakeCoordinator.decide(false, false, false))
        assertEquals(WakeAction.ACQUIRE, OwnedWorkWakeCoordinator.decide(false, true, false))
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.decide(true, true, false))
        // Real work survives a transient foreground flag loss: KEEP, never release.
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.decide(true, false, false))
        // Settled owned set ends everything, whatever the flag says.
        assertEquals(WakeAction.RELEASE, OwnedWorkWakeCoordinator.decide(true, true, true))
        assertEquals(WakeAction.RELEASE, OwnedWorkWakeCoordinator.decide(true, false, true))
        assertEquals(WakeAction.IDLE, OwnedWorkWakeCoordinator.decide(false, true, true))
        assertEquals(WakeAction.IDLE, OwnedWorkWakeCoordinator.decide(false, false, true))
    }

    @Test
    fun acquireHappensExactlyOncePerOwnedEpisode() {
        val handle = FakeWakeHandle()
        assertEquals(WakeAction.ACQUIRE, OwnedWorkWakeCoordinator.sync(this, handle,
            foregroundConfirmed = true, ownedEmpty = false))
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.sync(this, handle,
            foregroundConfirmed = true, ownedEmpty = false))
        assertEquals(1, handle.acquires)
        assertTrue(handle.held)
    }

    @Test
    fun releaseFollowsSettledWorkNotFlagFlicker() {
        val handle = FakeWakeHandle()
        OwnedWorkWakeCoordinator.sync(this, handle, foregroundConfirmed = true, ownedEmpty = false)
        // Foreground flag flicker (promotion re-render, instance swap):
        OwnedWorkWakeCoordinator.sync(this, handle, foregroundConfirmed = false, ownedEmpty = false)
        assertTrue("wake must stay while real work is still owned", handle.held)
        assertEquals(WakeAction.RELEASE, OwnedWorkWakeCoordinator.sync(this, handle,
            foregroundConfirmed = true, ownedEmpty = true))
        assertFalse(handle.held)
        assertEquals(1, handle.releases)
    }

    /** The round-3 regression: production creates a NEW handle object per
     *  service instance (application-context-backed candidate), so the old
     *  same-handle adoption test could not see the stranding/stacking
     *  defect. With two DISTINCT handles the contract is: exactly one
     *  acquire on the real held object, the newer candidate is never
     *  touched, and the settle release lands on the handle that actually
     *  holds the wake. */
    @Test
    fun newerInstanceAdoptsExistingWakeWithoutStacking() {
        val firstHandle = FakeWakeHandle()   // installed by instance A
        val secondHandle = FakeWakeHandle()  // created fresh by recreated instance B
        val oldOwner = Any()
        val newOwner = Any()
        assertEquals(WakeAction.ACQUIRE, OwnedWorkWakeCoordinator.sync(oldOwner, firstHandle,
            foregroundConfirmed = true, ownedEmpty = false))
        // Old instance destroyed while work is still owned: wake keeps, no release.
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.sync(oldOwner, firstHandle,
            foregroundConfirmed = false, ownedEmpty = false))
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.sync(newOwner, secondHandle,
            foregroundConfirmed = true, ownedEmpty = false))
        assertEquals("adoption must never acquire the newer handle", 0, secondHandle.acquires)
        assertEquals(1, firstHandle.acquires)
        assertFalse(secondHandle.held)
        assertTrue("the real wake stays on the process-canonical handle", firstHandle.held)
        assertSame(firstHandle, OwnedWorkWakeCoordinator.wakeHandleForProcess())
        assertTrue(OwnedWorkWakeCoordinator.isCpuWakeHeld())
        // Real settlement: the release lands on the object that HOLDS it.
        assertEquals(WakeAction.RELEASE, OwnedWorkWakeCoordinator.sync(newOwner, secondHandle,
            foregroundConfirmed = true, ownedEmpty = true))
        assertEquals(1, firstHandle.releases)
        assertEquals(0, secondHandle.releases)
        assertFalse(firstHandle.held)
        assertFalse(OwnedWorkWakeCoordinator.isCpuWakeHeld())
    }

    @Test
    fun staleInstanceTokenCannotUndoNewerForegroundOwnership() {
        val handle = FakeWakeHandle()
        val staleCandidate = FakeWakeHandle()
        val liveOwner = Any()
        val staleOwner = Any()
        OwnedWorkWakeCoordinator.sync(staleOwner, handle, foregroundConfirmed = true, ownedEmpty = false)
        OwnedWorkWakeCoordinator.sync(liveOwner, FakeWakeHandle(),
            foregroundConfirmed = true, ownedEmpty = false)
        // The old instance's late onDestroy path (its flag already ended)
        // while newer ownership is live and work is still owned: KEEP on
        // the process-canonical object; the stale instance's fresh
        // candidate handle must not acquire, strand or release anything.
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.sync(staleOwner, staleCandidate,
            foregroundConfirmed = false, ownedEmpty = false))
        assertTrue(handle.held)
        assertEquals(0, staleCandidate.acquires)
        assertEquals(0, handle.releases)
        assertTrue(OwnedWorkWakeCoordinator.isCpuWakeHeld())
    }

    /** The wake's end must NOT depend on a service instance still being
     *  alive: after the last instance tears down with work still owned,
     *  the process settle watch observes the REAL settlement and releases
     *  exactly once, then cancels itself. */
    @Test
    fun realSettlementReleasesEvenAfterEveryInstanceIsGone() {
        val watch = FakeSettleWatch()
        OwnedWorkWakeCoordinator.installSettleWatch(watch)
        val handle = FakeWakeHandle()
        val owner = Any()
        assertEquals(WakeAction.ACQUIRE, OwnedWorkWakeCoordinator.sync(owner, handle,
            foregroundConfirmed = true, ownedEmpty = false))
        assertEquals(1, watch.schedules)
        // Last instance destroyed while real work is still owned: KEEP
        // re-arms the process watch (per-instance listener is gone).
        assertEquals(WakeAction.KEEP, OwnedWorkWakeCoordinator.sync(owner, handle,
            foregroundConfirmed = false, ownedEmpty = false))
        assertEquals(2, watch.schedules)
        // The work settles later with NO live instance: the process watch
        // recheck is the only observer and it must release for real.
        assertEquals(WakeAction.RELEASE, OwnedWorkWakeCoordinator.syncFromProcessWatch(
            foregroundConfirmed = false, ownedEmpty = true))
        assertFalse(handle.held)
        assertEquals(1, handle.releases)
        assertEquals(1, watch.cancels)
        assertFalse(OwnedWorkWakeCoordinator.isCpuWakeHeld())
    }

    @Test
    fun settleWatchChainStopsWhenNothingIsHeld() {
        val watch = FakeSettleWatch()
        OwnedWorkWakeCoordinator.installSettleWatch(watch)
        val handle = FakeWakeHandle()
        // Idle process: no acquire, no recheck chain, watch cancelled (idempotent).
        assertEquals(WakeAction.IDLE, OwnedWorkWakeCoordinator.sync(this, handle,
            foregroundConfirmed = true, ownedEmpty = true))
        assertEquals(0, watch.schedules)
        assertEquals(1, watch.cancels)
        // No handle was ever acquired: the process watch path stays honest
        // and never invents a wake end for a wake that never existed.
        assertEquals(WakeAction.IDLE, OwnedWorkWakeCoordinator.syncFromProcessWatch(
            foregroundConfirmed = false, ownedEmpty = true))
        assertFalse(handle.held)
        assertEquals(0, handle.releases)
    }

    @Test
    fun heldObservationReadsRealHandleState() {
        val handle = FakeWakeHandle()
        assertFalse(OwnedWorkWakeCoordinator.isCpuWakeHeld())
        OwnedWorkWakeCoordinator.sync(this, handle, foregroundConfirmed = true, ownedEmpty = false)
        assertTrue(OwnedWorkWakeCoordinator.isCpuWakeHeld())
        handle.held = false // simulate external loss (process-level)
        assertFalse(OwnedWorkWakeCoordinator.isCpuWakeHeld())
    }

    @Test
    fun canonicalHandleIsChosenOncePerProcessEpisode() {
        val first = FakeWakeHandle()
        val second = FakeWakeHandle()
        OwnedWorkWakeCoordinator.sync(Any(), second, foregroundConfirmed = false, ownedEmpty = false)
        assertSame(second, OwnedWorkWakeCoordinator.wakeHandleForProcess())
        OwnedWorkWakeCoordinator.sync(Any(), first, foregroundConfirmed = true, ownedEmpty = false)
        assertSame("a later handle never re-points the process wake object",
            second, OwnedWorkWakeCoordinator.wakeHandleForProcess())
        assertEquals(1, second.acquires)
        assertEquals(0, first.acquires)
        OwnedWorkWakeCoordinator.resetForTesting()
        OwnedWorkWakeCoordinator.sync(Any(), first, foregroundConfirmed = true, ownedEmpty = false)
        assertSame(first, OwnedWorkWakeCoordinator.wakeHandleForProcess())
        assertEquals(1, first.acquires)
    }
}
