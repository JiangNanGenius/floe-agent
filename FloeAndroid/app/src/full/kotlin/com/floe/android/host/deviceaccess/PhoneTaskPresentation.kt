// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.phonecontrol.PhoneControlOwner

/**
 * Pure ownership mapping for the one "Active phone task" card.
 *
 * The host feeds four independent facts:
 *  - the current live run candidate (task/run UUID from the actual holder),
 *  - the host's explicit arm owner,
 *  - the phone service's ACTUAL fence owner (`PhoneControlStatus.activeOwner`,
 *    null while stopped/taken over/user-touched/locked/disconnected),
 *  - the exact retained user-stopped owner.
 *
 * Invariants:
 *  - ARMED requires BOTH the host arm and the service's actual fence owner to
 *    be the same owner. A host-only arm left over after a user-touch, lock,
 *    takeover or service loss is never displayed as authorized.
 *  - A live run is the current task. A stale arm for a different owner must
 *    not hide the live run's explicit user-allowed entry.
 *  - A user stop does not suppress a DIFFERENT fresh run; it only marks the
 *    exact stopped owner as STOPPED. That retained stopped row is display
 *    only: it never receives a fresh grant (Continue creates a new live run).
 *  - No live run and no retained stopped/armed owner means no card. A recent
 *    owner whose run already ended is never resurrected as a live task.
 *
 * This object owns no authority and performs no action.
 */
internal data class PhoneTaskLiveCandidate(
    val owner: PhoneControlOwner,
    val title: String,
    val phase: DeviceAccessTaskPhaseUi,
)

internal enum class PhoneTaskTitleSource { CANDIDATE, RETAINED }

internal data class PhoneTaskOwnershipUi(
    val owner: PhoneControlOwner,
    val phase: DeviceAccessTaskPhaseUi,
    val control: DeviceAccessTaskControlUi,
    val titleSource: PhoneTaskTitleSource,
)

internal sealed interface PhoneTaskArmDecision {
    /** The exact live run candidate the user explicitly allows. */
    data class Arm(val candidate: PhoneTaskLiveCandidate) : PhoneTaskArmDecision
    data class Refuse(val code: String) : PhoneTaskArmDecision
}

internal object PhoneTaskPresentation {

    fun ownership(
        candidate: PhoneTaskLiveCandidate?,
        armedOwner: PhoneControlOwner?,
        actualOwner: PhoneControlOwner?,
        stoppedOwner: PhoneControlOwner?,
        userStopped: Boolean,
    ): PhoneTaskOwnershipUi? {
        // A stop fence or a service-side fence (user touch/lock/takeover/
        // revocation) means the host's arm is no longer live authorization.
        val actualArm = armedOwner?.takeIf { !userStopped && it == actualOwner }

        if (candidate != null) {
            if (actualArm == candidate.owner) {
                return PhoneTaskOwnershipUi(
                    owner = candidate.owner,
                    phase = DeviceAccessTaskPhaseUi.RUNNING,
                    control = DeviceAccessTaskControlUi.ARMED,
                    titleSource = PhoneTaskTitleSource.CANDIDATE,
                )
            }
            val stoppedHere = userStopped && stoppedOwner == candidate.owner
            return PhoneTaskOwnershipUi(
                owner = candidate.owner,
                phase = if (stoppedHere) {
                    DeviceAccessTaskPhaseUi.TAKEN_OVER
                } else {
                    candidate.phase
                },
                control = if (stoppedHere) {
                    DeviceAccessTaskControlUi.STOPPED
                } else {
                    DeviceAccessTaskControlUi.OFF
                },
                titleSource = PhoneTaskTitleSource.CANDIDATE,
            )
        }

        if (actualArm != null) {
            return PhoneTaskOwnershipUi(
                owner = actualArm,
                phase = DeviceAccessTaskPhaseUi.RUNNING,
                control = DeviceAccessTaskControlUi.ARMED,
                titleSource = PhoneTaskTitleSource.RETAINED,
            )
        }

        if (userStopped && stoppedOwner != null) {
            return PhoneTaskOwnershipUi(
                owner = stoppedOwner,
                phase = DeviceAccessTaskPhaseUi.TAKEN_OVER,
                control = DeviceAccessTaskControlUi.STOPPED,
                titleSource = PhoneTaskTitleSource.RETAINED,
            )
        }

        return null
    }

    /**
     * Resolve the only owner an explicit user arm may target.
     *
     * An arm is a grant for a CURRENTLY LIVE run, never a way to restore a
     * grant to a cancelled/dead owner. After a user stop the retained task
     * only DISPLAYS its stopped state; the user must Continue, which resumes
     * the run as a new live incarnation, and then arm that live candidate.
     *
     * The exact stopped owner is refused while its cancellation is still
     * settling (`stoppedOwnerSettled == false` and it is live). Once a
     * post-stop observation proved it no longer live, a later live run with
     * the same owner is an explicit Continue/retry incarnation, not the
     * original stop, and may be armed. A stale/recent/dead owner with no
     * live candidate is always refused, so an old owner can never authorize
     * a new task.
     */
    fun armTarget(
        candidate: PhoneTaskLiveCandidate?,
        userStopped: Boolean,
        stoppedOwner: PhoneControlOwner?,
        stoppedOwnerSettled: Boolean,
    ): PhoneTaskArmDecision {
        if (candidate == null) {
            return PhoneTaskArmDecision.Refuse(CODE_NO_LIVE_TASK)
        }
        if (userStopped && stoppedOwner == candidate.owner && !stoppedOwnerSettled) {
            return PhoneTaskArmDecision.Refuse(CODE_STOP_SETTLING)
        }
        return PhoneTaskArmDecision.Arm(candidate)
    }

    /**
     * A history/surface fallback is only acceptable when exactly ONE live
     * candidate resolves. Never pick one of several concurrently running
     * tasks by list order or recency: that could grant phone control to a
     * task the user is not looking at. Ambiguity means no candidate at all
     * (the UI then asks the user to select/start a task).
     */
    fun uniqueLiveCandidate(
        candidates: List<PhoneTaskLiveCandidate>,
    ): PhoneTaskLiveCandidate? = candidates.distinctBy { it.owner }.singleOrNull()

    const val CODE_STOP_SETTLING = "phone_stop_settling"
    const val CODE_NO_LIVE_TASK = "no_live_task"
}
