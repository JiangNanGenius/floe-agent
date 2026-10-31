// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the Active phone task ownership mapping. No Android,
// Compose, service or device state is constructed here.
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the real Batch47 failure boundaries:
 *  - a stop/takeover of the OLD owner never hides a DIFFERENT fresh live run;
 *  - the STOPPED branch is reachable and is never shown as ARMED;
 *  - a host arm left over after a user-touch/service fence is not ARMED;
 *  - only the owner that is both host-armed and the service's actual fence
 *    owner may render ARMED, and a different current run still gets its
 *    explicit Allow entry;
 *  - a dead recent owner is not resurrected; a cancelled/stopping run is
 *    never re-armed by the UI, and a retained stopped task cannot receive a
 *    fresh grant (Continue creates a new live run, which is armed instead).
 */
class PhoneTaskPresentationTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    private fun candidate(
        owner: PhoneControlOwner,
        phase: DeviceAccessTaskPhaseUi = DeviceAccessTaskPhaseUi.RUNNING,
        title: String = "Run the G08 QA fixture flow now.",
    ) = PhoneTaskLiveCandidate(owner, title, phase)

    // ------------------------------------------------------------- display

    @Test
    fun freshRunAfterTakeoverIsStillShownAndOffersArm() {
        val old = owner(1, 1)
        val fresh = owner(2, 2)
        val display = PhoneTaskPresentation.ownership(
            candidate = candidate(fresh),
            armedOwner = null,
            actualOwner = null,
            stoppedOwner = old,
            userStopped = true,
        )
        assertEquals(fresh, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.OFF, display?.control)
        assertEquals(DeviceAccessTaskPhaseUi.RUNNING, display?.phase)
        assertEquals(PhoneTaskTitleSource.CANDIDATE, display?.titleSource)

        val decision = PhoneTaskPresentation.armTarget(
            candidate = candidate(fresh),
            userStopped = true,
            stoppedOwner = old,
            stoppedOwnerSettled = false,
        )
        assertTrue(decision is PhoneTaskArmDecision.Arm)
        assertEquals(fresh, (decision as PhoneTaskArmDecision.Arm).candidate.owner)
    }

    @Test
    fun userTouchFencedHostArmIsNeverArmedAndFreshRunGetsItsEntry() {
        val old = owner(1, 1)
        val fresh = owner(2, 2)
        // The service fenced after a user touch: activeOwner is null even
        // though the host still remembers its previous arm.
        val display = PhoneTaskPresentation.ownership(
            candidate = candidate(fresh),
            armedOwner = old,
            actualOwner = null,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(fresh, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.OFF, display?.control)
        assertNotEquals(DeviceAccessTaskControlUi.ARMED, display?.control)
    }

    @Test
    fun armedRequiresBothHostGrantAndActualServiceOwner() {
        val run = owner(1, 1)
        val other = owner(2, 2)

        val armed = PhoneTaskPresentation.ownership(
            candidate = candidate(run),
            armedOwner = run,
            actualOwner = run,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(DeviceAccessTaskControlUi.ARMED, armed?.control)
        assertEquals(DeviceAccessTaskPhaseUi.RUNNING, armed?.phase)

        val hostOnly = PhoneTaskPresentation.ownership(
            candidate = candidate(run),
            armedOwner = run,
            actualOwner = null,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(DeviceAccessTaskControlUi.OFF, hostOnly?.control)

        val crossed = PhoneTaskPresentation.ownership(
            candidate = candidate(run),
            armedOwner = run,
            actualOwner = other,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(DeviceAccessTaskControlUi.OFF, crossed?.control)
    }

    @Test
    fun staleArmForAnotherOwnerDoesNotHideCurrentRunEntry() {
        val old = owner(1, 1)
        val fresh = owner(2, 2)
        val display = PhoneTaskPresentation.ownership(
            candidate = candidate(fresh),
            armedOwner = old,
            actualOwner = old,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(fresh, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.OFF, display?.control)
        // The explicit user arm on the current run is what transfers the
        // single owner; the old owner never authorizes this task.
        val decision = PhoneTaskPresentation.armTarget(
            candidate = candidate(fresh),
            userStopped = false,
            stoppedOwner = null,
            stoppedOwnerSettled = true,
        ) as PhoneTaskArmDecision.Arm
        assertEquals(fresh, decision.candidate.owner)
        assertNotEquals(old, decision.candidate.owner)
    }

    @Test
    fun armedOwnerWithoutLiveCandidateRemainsVisibleAndStoppable() {
        val run = owner(1, 1)
        val display = PhoneTaskPresentation.ownership(
            candidate = null,
            armedOwner = run,
            actualOwner = run,
            stoppedOwner = null,
            userStopped = false,
        )
        assertEquals(run, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.ARMED, display?.control)
        assertEquals(PhoneTaskTitleSource.RETAINED, display?.titleSource)
    }

    @Test
    fun retainedStoppedOwnerIsStoppedTakenOverAndNotArmed() {
        val stopped = owner(1, 1)
        val display = PhoneTaskPresentation.ownership(
            candidate = null,
            armedOwner = null,
            actualOwner = null,
            stoppedOwner = stopped,
            userStopped = true,
        )
        assertEquals(stopped, display?.owner)
        assertEquals(DeviceAccessTaskControlUi.STOPPED, display?.control)
        assertEquals(DeviceAccessTaskPhaseUi.TAKEN_OVER, display?.phase)
        assertEquals(PhoneTaskTitleSource.RETAINED, display?.titleSource)
    }

    @Test
    fun deadRecentOwnerIsNotResurrected() {
        assertNull(
            PhoneTaskPresentation.ownership(
                candidate = null,
                armedOwner = null,
                actualOwner = null,
                stoppedOwner = null,
                userStopped = false,
            ),
        )
        assertTrue(
            PhoneTaskPresentation.ownership(
                candidate = null,
                armedOwner = null,
                actualOwner = null,
                stoppedOwner = owner(1, 1),
                userStopped = false,
            ) == null,
        )
    }

    // --------------------------------------------------------------- arm gate

    @Test
    fun stoppingRunIsShownStoppedAndRefusedWhileSettling() {
        val stopped = owner(1, 1)
        val display = PhoneTaskPresentation.ownership(
            candidate = candidate(stopped),
            armedOwner = null,
            actualOwner = null,
            stoppedOwner = stopped,
            userStopped = true,
        )
        assertEquals(DeviceAccessTaskControlUi.STOPPED, display?.control)
        assertEquals(DeviceAccessTaskPhaseUi.TAKEN_OVER, display?.phase)

        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_STOP_SETTLING),
            PhoneTaskPresentation.armTarget(
                candidate = candidate(stopped),
                userStopped = true,
                stoppedOwner = stopped,
                stoppedOwnerSettled = false,
            ),
        )
    }

    @Test
    fun resumedRunWithTheSameOwnerCanBeArmedOnlyAfterTheStopSettled() {
        val stopped = owner(1, 1)
        // Continue/run.retry re-opens the SAME durable run id as a new live
        // incarnation. After the stop was observed settled, that live
        // candidate may receive a fresh user grant; before it settled, the
        // original cancellation still wins.
        val resumed = PhoneTaskPresentation.armTarget(
            candidate = candidate(stopped),
            userStopped = true,
            stoppedOwner = stopped,
            stoppedOwnerSettled = true,
        ) as PhoneTaskArmDecision.Arm
        assertEquals(stopped, resumed.candidate.owner)
        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_STOP_SETTLING),
            PhoneTaskPresentation.armTarget(
                candidate = candidate(stopped),
                userStopped = true,
                stoppedOwner = stopped,
                stoppedOwnerSettled = false,
            ),
        )
    }

    @Test
    fun cancelledOwnerNeverReceivesAFreshGrant() {
        val stopped = owner(1, 1)
        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_NO_LIVE_TASK),
            PhoneTaskPresentation.armTarget(
                candidate = null,
                userStopped = true,
                stoppedOwner = stopped,
                stoppedOwnerSettled = true,
            ),
        )
        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_NO_LIVE_TASK),
            PhoneTaskPresentation.armTarget(
                candidate = null,
                userStopped = false,
                stoppedOwner = stopped,
                stoppedOwnerSettled = true,
            ),
        )
        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_NO_LIVE_TASK),
            PhoneTaskPresentation.armTarget(
                candidate = null,
                userStopped = true,
                stoppedOwner = null,
                stoppedOwnerSettled = false,
            ),
        )
    }

    @Test
    fun armTargetRequiresALiveCandidateOtherwise() {
        val fresh = owner(3, 3)
        assertEquals(
            PhoneTaskArmDecision.Refuse(PhoneTaskPresentation.CODE_NO_LIVE_TASK),
            PhoneTaskPresentation.armTarget(
                candidate = null,
                userStopped = false,
                stoppedOwner = null,
                stoppedOwnerSettled = true,
            ),
        )
        val decision = PhoneTaskPresentation.armTarget(
            candidate = candidate(fresh, DeviceAccessTaskPhaseUi.WAITING_FOR_USER),
            userStopped = false,
            stoppedOwner = null,
            stoppedOwnerSettled = true,
        ) as PhoneTaskArmDecision.Arm
        assertEquals(fresh, decision.candidate.owner)
        assertEquals(DeviceAccessTaskPhaseUi.WAITING_FOR_USER, decision.candidate.phase)
    }

    @Test
    fun multipleConcurrentLiveCandidatesAreAmbiguousAndNeverGuessed() {
        val a = candidate(owner(1, 1))
        val b = candidate(owner(2, 2))
        assertNull(PhoneTaskPresentation.uniqueLiveCandidate(emptyList()))
        assertEquals(a, PhoneTaskPresentation.uniqueLiveCandidate(listOf(a)))
        // The same owner resolved twice is still one candidate.
        assertEquals(a, PhoneTaskPresentation.uniqueLiveCandidate(listOf(a, a)))
        // Two different live tasks: no arbitrary first/newest/recency pick.
        assertNull(PhoneTaskPresentation.uniqueLiveCandidate(listOf(a, b)))
        assertNull(PhoneTaskPresentation.uniqueLiveCandidate(listOf(b, a)))
    }
}
