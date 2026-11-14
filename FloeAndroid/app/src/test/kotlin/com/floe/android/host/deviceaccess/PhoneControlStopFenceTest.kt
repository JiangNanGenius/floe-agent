// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the exact-owner stop fence. No Android, Compose,
// service or device state is constructed here.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Full12 cross-task stop leak:
 *  - stopping task A never denies task B;
 *  - the retained stopped row still names the exact stopped owner;
 *  - settling and explicit re-allow are per-owner;
 *  - a same-run retry stays fenced until that owner is explicitly re-allowed;
 *  - an old stop generation cannot clear a newer stop for the same owner.
 */
class PhoneControlStopFenceTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    @Test
    fun stoppingOneTaskNeverFencesADifferentLiveTask() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val b = owner(2, 22)

        fence.markStopped(a, epoch = 7)

        assertTrue(fence.isStopped(a))
        assertFalse("a fresh live task must not inherit A's stop", fence.isStopped(b))
        assertEquals(a, fence.lastStoppedOwner())
    }

    @Test
    fun fenceIdentityIsExactTaskAndRun() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val sameTaskNewRun = owner(1, 12)
        val sameRunOtherTask = owner(2, 11)

        fence.markStopped(a, epoch = 7)

        assertFalse("a new run of the same task is a different owner",
            fence.isStopped(sameTaskNewRun))
        assertFalse("another task can never reuse the stopped run id",
            fence.isStopped(sameRunOtherTask))
    }

    @Test
    fun settlingIsPerOwnerAndOnlyWhenThatRunIsNotLive() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val b = owner(2, 22)
        fence.markStopped(a, epoch = 7)
        fence.markStopped(b, epoch = 7)

        val changed = fence.settleIfNotLive { candidate -> candidate == a }

        assertEquals(1, changed)
        assertFalse("A is still live, so its stop keeps settling", fence.isSettled(a))
        assertTrue("B's exact run is no longer live", fence.isSettled(b))
        assertTrue(fence.isStopped(b))
    }

    @Test
    fun sameRunRetryStaysStoppedUntilExplicitOwnerClear() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        fence.markStopped(a, epoch = 7)
        fence.settleIfNotLive { false }

        assertTrue("settled only permits an explicit user gesture", fence.isSettled(a))
        assertTrue("settled is not an automatic re-allow", fence.isStopped(a))
        assertTrue(fence.clear(a))
        assertFalse(fence.isStopped(a))
        assertNull(fence.lastStoppedOwner())
    }

    @Test
    fun aNewStopForTheSameOwnerResetsSettled() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        fence.markStopped(a, epoch = 7)
        fence.settleIfNotLive { false }
        assertTrue(fence.isSettled(a))

        fence.markStopped(a, epoch = 8)

        assertFalse("a real new stop is not an old settled cancellation", fence.isSettled(a))
        assertTrue(fence.isStopped(a))
    }

    @Test
    fun oldStopGenerationCannotClearANewerStop() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val first = fence.markStopped(a, epoch = 7)
        val second = fence.markStopped(a, epoch = 7)

        assertFalse("old cleanup must not lift the new stop", fence.clear(a, first.token))
        assertTrue(fence.isStopped(a))
        assertEquals(second.token, fence.entry(a)?.token)
        assertTrue(fence.clear(a, second.token))
        assertFalse(fence.isStopped(a))
    }

    @Test
    fun retainedStopCardIsTheMostRecentOwnerOnly() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val b = owner(2, 22)
        fence.markStopped(a, epoch = 7)
        fence.markStopped(b, epoch = 7)
        assertEquals(b, fence.lastStoppedOwner())

        fence.clear(b)
        assertEquals(a, fence.lastStoppedOwner())
        fence.clearAll()
        assertNull(fence.lastStoppedOwner())
        assertEquals(0, fence.size())
    }

    @Test
    fun stateIsBoundedAndEvictsASettledEntryFirst() {
        val fence = PhoneControlStopFence()
        val settled = owner(0, 0)
        fence.markStopped(settled, epoch = 7)
        fence.settleIfNotLive { false }
        repeat(PhoneControlStopFence.MAX_TRACKED_STOPS - 1) { index ->
            fence.markStopped(owner(index + 1, 1), epoch = 7)
        }
        assertEquals(PhoneControlStopFence.MAX_TRACKED_STOPS, fence.size())

        fence.markStopped(owner(999, 1), epoch = 7)

        assertEquals(PhoneControlStopFence.MAX_TRACKED_STOPS, fence.size())
        assertFalse("the only settled entry is the safe eviction candidate",
            fence.isStopped(settled))
    }
}
