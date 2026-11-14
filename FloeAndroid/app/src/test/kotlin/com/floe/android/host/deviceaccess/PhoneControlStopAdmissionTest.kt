// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for exact-owner admission/presentation after a stop.
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host now feeds PhoneTaskPresentation per candidate owner instead of a
 * host-wide `userStopped` flag. This pins the resulting decisions:
 *  - a stopped A cannot block arming a different live B;
 *  - A itself is refused while its cancellation is settling;
 *  - after A's exact run is settled, the explicit Continue/Allow gesture is
 *    admitted and only then clears A's fence;
 *  - A's retained row stays STOPPED until that explicit gesture.
 */
class PhoneControlStopAdmissionTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    private fun candidate(owner: PhoneControlOwner) =
        PhoneTaskLiveCandidate(owner, "live task", DeviceAccessTaskPhaseUi.RUNNING)

    private fun armTargetFor(
        fence: PhoneControlStopFence,
        target: PhoneControlOwner,
    ): PhoneTaskArmDecision {
        val entry = fence.entry(target)
        return PhoneTaskPresentation.armTarget(
            candidate = candidate(target),
            userStopped = entry != null,
            stoppedOwner = target.takeIf { entry != null },
            stoppedOwnerSettled = entry?.settled == true,
        )
    }

    @Test
    fun stoppedTaskDoesNotBlockADifferentLiveCandidate() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        val b = owner(2, 22)
        fence.markStopped(a, epoch = 7)

        val decision = armTargetFor(fence, b)

        assertTrue(decision is PhoneTaskArmDecision.Arm)
        assertEquals(b, (decision as PhoneTaskArmDecision.Arm).candidate.owner)
    }

    @Test
    fun stoppedCandidateIsRefusedOnlyWhileItsRunIsSettling() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        fence.markStopped(a, epoch = 7)

        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_STOP_SETTLING),
            armTargetFor(fence, a),
        )

        fence.settleIfNotLive { false }
        assertTrue("settled only permits the explicit user gesture",
            armTargetFor(fence, a) is PhoneTaskArmDecision.Arm)
    }

    @Test
    fun stoppedOwnerRowIsStoppedAndDisappearsOnlyOnExplicitClear() {
        val fence = PhoneControlStopFence()
        val a = owner(1, 11)
        fence.markStopped(a, epoch = 7)

        val display = PhoneTaskPresentation.ownership(
            candidate = null,
            armedOwner = null,
            actualOwner = null,
            stoppedOwner = fence.lastStoppedOwner(),
            userStopped = fence.size() > 0,
        )
        assertEquals(a, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.STOPPED, display?.control)
        assertEquals(DeviceAccessTaskPhaseUi.TAKEN_OVER, display?.phase)

        fence.clear(a)
        assertNull(
            PhoneTaskPresentation.ownership(
                candidate = null,
                armedOwner = null,
                actualOwner = null,
                stoppedOwner = fence.lastStoppedOwner(),
                userStopped = fence.size() > 0,
            ),
        )
    }
}
