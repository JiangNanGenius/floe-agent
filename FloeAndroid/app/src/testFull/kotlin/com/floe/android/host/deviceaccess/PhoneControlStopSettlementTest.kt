// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the exact-generation stop settlement projection.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlStopSettlementTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    @Test
    fun olderStopGenerationCannotMarkOrClearANewerStop() {
        val settlements = PhoneControlStopSettlements()
        val a = owner(1, 11)
        settlements.begin(a, token = 7, epoch = 3, approvalKey = "run/call")
        assertTrue(settlements.mark(a, 7, DeviceStopUiPhase.FAILED, "run_cancel_refused"))
        assertEquals(DeviceStopUiPhase.FAILED, settlements.phase(a))

        // A newer Stop for the same owner starts its own generation.
        settlements.begin(a, token = 9, epoch = 3, approvalKey = "run/call2")
        assertEquals(DeviceStopUiPhase.STOPPING, settlements.phase(a))
        assertFalse("old failure cannot overwrite the new stop", settlements.mark(a, 7, DeviceStopUiPhase.FAILED))
        assertFalse("old cleanup cannot clear the new stop", settlements.clear(a, 7))
        assertEquals(DeviceStopUiPhase.STOPPING, settlements.phase(a))
        assertTrue(settlements.clear(a, 9))
        assertNull(settlements.phase(a))
    }

    @Test
    fun stopsAreIndependentAcrossOwnersAndBoundToTheirApprovalKey() {
        val settlements = PhoneControlStopSettlements()
        val a = owner(1, 11)
        val b = owner(2, 22)
        settlements.begin(a, token = 1, epoch = 3, approvalKey = "runA/callA")
        settlements.begin(b, token = 2, epoch = 3, approvalKey = "runB/callB")

        assertEquals("runA/callA", settlements.entry(a)?.approvalKey)
        assertEquals("runB/callB", settlements.entry(b)?.approvalKey)
        assertTrue(settlements.clear(a, 1))
        assertEquals(DeviceStopUiPhase.STOPPING, settlements.phase(b))
    }

    @Test
    fun explicitRetryRequiresExactFailedStopOwnerEpochAndToken() {
        val fence = PhoneControlStopFence()
        val settlements = PhoneControlStopSettlements()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val old = fence.markStopped(a, 3)
        settlements.begin(a, old.token, 3, approvalKey = "runA/callA")
        assertFalse(mayRetryDeviceStopReadback(a, 3, old, settlements.entry(a)))
        assertTrue(settlements.mark(a, old.token, DeviceStopUiPhase.FAILED))
        val failed = settlements.entry(a)
        assertTrue(mayRetryDeviceStopReadback(a, 3, old, failed))
        assertFalse(mayRetryDeviceStopReadback(b, 3, old, failed))
        assertFalse(mayRetryDeviceStopReadback(a, 4, old, failed))

        // A newer stop supersedes the old failed receipt, even for the same
        // owner and epoch. The new retry retains the exact card identity.
        val newer = fence.markStopped(a, 3)
        assertFalse(mayRetryDeviceStopReadback(a, 3, newer, failed))
        settlements.begin(a, newer.token, 3, approvalKey = failed?.approvalKey)
        assertFalse(settlements.mark(a, old.token, DeviceStopUiPhase.FAILED))
        assertEquals("runA/callA", settlements.entry(a)?.approvalKey)
        assertEquals(DeviceStopUiPhase.STOPPING, settlements.phase(a))
    }

    @Test
    fun settlementIsBounded() {
        val settlements = PhoneControlStopSettlements()
        repeat(PhoneControlStopSettlements.MAX_TRACKED_STOPS + 16) { index ->
            settlements.begin(owner(index, index), token = index.toLong() + 1, epoch = 3)
        }
        assertEquals(PhoneControlStopSettlements.MAX_TRACKED_STOPS, settlements.size())
        settlements.clearAll()
        assertEquals(0, settlements.size())
    }
}
