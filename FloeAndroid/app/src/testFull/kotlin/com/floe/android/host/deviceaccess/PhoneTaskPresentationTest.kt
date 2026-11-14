// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the Active phone task ownership mapping. No Android,
// Compose, service or device state is constructed here.
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.Locale
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun screenSessionEndsWhileBackgroundTaskKeepsRunning() {
        val run = owner(1, 1)
        fun visible(actual: PhoneControlOwner?, arming: PhoneControlOwner? = null) =
            PhoneTaskPresentation.automationControlsVisible(run, true, actual, arming, false)
        assertTrue(visible(run))
        // Release/lock/service loss ends the session while the Agent keeps
        // doing background work. Later task progress cannot revive a bubble.
        repeat(3) { assertFalse(visible(null)) }
        // A new real arm, rather than task liveness alone, restores controls.
        assertTrue(visible(null, run))
        assertTrue(visible(run))
    }

    @Test
    fun stoppedOwnerCannotReappearThroughLateScreenCallbacks() {
        val stopped = owner(1, 1)
        val fresh = owner(2, 2)
        assertFalse(PhoneTaskPresentation.automationControlsVisible(
            stopped, false, stopped, stopped, true))
        assertFalse(PhoneTaskPresentation.automationControlsVisible(
            stopped, true, fresh, fresh, false))
        assertTrue(PhoneTaskPresentation.automationControlsVisible(
            fresh, true, fresh, null, false))
    }

    @Test
    fun deliberatePauseStaysResumableOnlyUntilItsOwnerEnds() {
        val run = owner(1, 1)
        assertTrue(PhoneTaskPresentation.automationControlsVisible(
            run, true, null, null, true))
        assertFalse(PhoneTaskPresentation.automationControlsVisible(
            run, false, null, null, true))
    }

    @Test
    fun failedInitialArmDoesNotLeaveResidentControls() {
        val run = owner(1, 1)
        assertFalse(PhoneTaskPresentation.automationControlsVisible(
            run, true, null, null, false))
        assertTrue(PhoneTaskPresentation.automationControlsVisible(
            run, true, null, run, false))
        assertFalse(PhoneTaskPresentation.automationControlsVisible(
            run, true, null, null, false))
    }

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

    // ------------------------------------------------- native UUID identity

    private fun nativeText(uuid: UUID): String = uuid.toString().uppercase(Locale.ROOT)

    @Test
    fun holderLookupUsesNativeUppercaseThenJavaLowercaseOfTheSameUuid() {
        val task = UUID.fromString("7cf5e683-a02e-9614-8f32-036344d7b997")
        val keys = PhoneTaskPresentation.holderLookupKeys(task)

        assertEquals(2, keys.size)
        assertEquals("7CF5E683-A02E-9614-8F32-036344D7B997", keys[0])
        assertEquals("7cf5e683-a02e-9614-8f32-036344d7b997", keys[1])
        assertEquals(task, UUID.fromString(keys[0]))
        assertEquals(task, UUID.fromString(keys[1]))
    }

    @Test
    fun digitOnlyUuidHasOneDeduplicatedHolderKey() {
        val task = UUID.fromString("00000000-0000-0000-0000-000000000001")
        assertEquals(
            listOf("00000000-0000-0000-0000-000000000001"),
            PhoneTaskPresentation.holderLookupKeys(task),
        )
    }

    @Test
    fun nativeUppercaseAndExistingJavaLowercaseHoldersResolveTheSameOwnerOnly() {
        val live = owner(1, 1)
        val other = owner(2, 2)
        val keys = PhoneTaskPresentation.holderLookupKeys(live.taskID)
        val nativeHolders = mapOf(nativeText(live.taskID) to live)
        val javaHolders = mapOf(live.taskID.toString() to live)
        val otherOnlyHolders = mapOf(other.taskID.toString() to other)

        // New native holders are uppercase; existing JVM holders stay lowercase.
        assertEquals(live, keys.firstNotNullOfOrNull { nativeHolders[it] })
        assertEquals(live, keys.firstNotNullOfOrNull { javaHolders[it] })
        // No scan/fallback may resolve a different owner's holder.
        assertNull(keys.firstNotNullOfOrNull { otherOnlyHolders[it] })
        val otherKeys = PhoneTaskPresentation.holderLookupKeys(other.taskID)
        assertNull(otherKeys.firstNotNullOfOrNull { javaHolders[it] })
    }

    @Test
    fun nativeUppercaseSelectedRunIsLiveForTheSameOwner() {
        val runUUID = UUID.fromString("7cf5e683-a02e-9614-8f32-036344d7b997")
        assertTrue(
            PhoneTaskPresentation.liveOwnerRun(
                isRunning = true,
                selectedRunID = "7CF5E683-A02E-9614-8F32-036344D7B997",
                runID = runUUID,
            ),
        )
        assertTrue(PhoneTaskPresentation.liveOwnerRun(true, nativeText(runUUID), runUUID))
    }

    @Test
    fun javaLowercaseAndMixedCaseSelectedRunsAreLiveForTheSameOwner() {
        val runUUID = UUID.fromString("7cf5e683-a02e-9614-8f32-036344d7b997")
        assertTrue(PhoneTaskPresentation.liveOwnerRun(true, runUUID.toString(), runUUID))
        assertTrue(
            PhoneTaskPresentation.liveOwnerRun(
                true,
                "7Cf5E683-a02E-9614-8F32-036344d7B997",
                runUUID,
            ),
        )
    }

    @Test
    fun terminalOrOtherOwnerSelectedRunIsNeverLive() {
        val live = owner(1, 1)
        val other = owner(2, 2)
        assertFalse(
            PhoneTaskPresentation.liveOwnerRun(
                isRunning = false,
                selectedRunID = nativeText(live.runID),
                runID = live.runID,
            ),
        )
        assertFalse(
            PhoneTaskPresentation.liveOwnerRun(
                isRunning = true,
                selectedRunID = nativeText(other.runID),
                runID = live.runID,
            ),
        )
        assertFalse(
            PhoneTaskPresentation.liveOwnerRun(
                isRunning = true,
                selectedRunID = live.runID.toString(),
                runID = other.runID,
            ),
        )
        assertFalse(PhoneTaskPresentation.liveOwnerRun(true, null, live.runID))
    }

    @Test
    fun malformedOrShortSelectedRunIsRefusedNotLenientlyParsed() {
        // `UUID.fromString("1-1-1-1-1")` is the lenient legacy form of this
        // canonical UUID; string equality must refuse it.
        val runUUID = UUID.fromString("1-1-1-1-1")
        assertEquals("00000001-0001-0001-0001-000000000001", runUUID.toString())
        val refused = listOf(
            null,
            "",
            "1-1-1-1-1",
            runUUID.toString().replace("-", ""),
            "{$runUUID}",
            " $runUUID",
            "$runUUID ",
            runUUID.toString().dropLast(1) + "g",
            runUUID.toString() + "-",
        )
        refused.forEach { selected ->
            assertFalse(
                "selected=$selected",
                PhoneTaskPresentation.selectedRunMatches(selected, runUUID),
            )
        }
        assertFalse(PhoneTaskPresentation.liveOwnerRun(true, "1-1-1-1-1", runUUID))
        assertTrue(PhoneTaskPresentation.selectedRunMatches(runUUID.toString(), runUUID))
        assertTrue(PhoneTaskPresentation.selectedRunMatches(nativeText(runUUID), runUUID))
    }

    // ------------------------------------------------- candidate scan bounds

    @Test
    fun boundedCandidateIdsDeduplicatesAndKeepsTheCallerOrder() {
        val ids = listOf(
            "00000000-0000-0000-0000-000000000001",
            " 00000000-0000-0000-0000-000000000002 ",
            "00000000-0000-0000-0000-000000000001",
            "",
            "not a conversation id",
            "00000000-0000-0000-0000-000000000003",
        )
        assertEquals(
            listOf(
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
                "00000000-0000-0000-0000-000000000003",
            ),
            PhoneTaskPresentation.boundedCandidateIds(ids, 8),
        )
    }

    @Test
    fun boundedCandidateIdsNeverExceedTheScan() {
        val ids = (1..20).map {
            "00000000-0000-0000-0000-${it.toString().padStart(12, '0')}"
        }
        assertEquals(3, PhoneTaskPresentation.boundedCandidateIds(ids, 3).size)
        assertTrue(PhoneTaskPresentation.boundedCandidateIds(ids, 0).isEmpty())
    }

    @Test
    fun theRestoredLiveOwnerIsUniqueAcrossDifferentTitles() {
        val first = owner(1, 1)
        val second = owner(2, 2)
        val unique = PhoneTaskPresentation.uniqueLiveCandidate(
            listOf(candidate(first), candidate(first, title = "same owner")),
        )
        assertEquals(first, unique?.owner)
        assertNull(
            PhoneTaskPresentation.uniqueLiveCandidate(
                listOf(candidate(first), candidate(second)),
            ),
        )
        assertTrue(
            "blank-like ids are not candidates",
            PhoneTaskPresentation.boundedCandidateIds(listOf("", " "), 8).isEmpty(),
        )
    }
}
