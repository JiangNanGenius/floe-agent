// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.Locale
import java.util.UUID

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
 *    Callers must therefore pass the CANDIDATE's own stopped state, never a
 *    host-wide boolean or another owner's retained stop.
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

    /** A running Agent task alone does not mean it still controls the screen.
     * Keep a deliberate pause resumable, but retire controls after the actual
     * session ends; a later fresh arm can present them again. UI-only. */
    fun automationControlsVisible(
        owner: PhoneControlOwner,
        ownerLive: Boolean,
        actualOwner: PhoneControlOwner?,
        armingOwner: PhoneControlOwner?,
        paused: Boolean,
    ): Boolean = ownerLive &&
        (actualOwner == owner || armingOwner == owner || paused)

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
     * grant to a cancelled/dead owner. The host passes this candidate's own
     * stopped owner/settled state, so another owner's stop cannot refuse it.
     * After a user stop the retained task
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

    /**
     * Bounded, de-duplicated conversation ids this host may resolve through
     * the exact holder API. Only canonical dashed UUID text is accepted, and
     * duplicates/blank or malformed values never widen the scan. The order is
     * the caller's order (live projection first, then the bounded active
     * history page), so a stale projection cannot hide a real holder.
     */
    fun boundedCandidateIds(ids: Collection<String>, maxScan: Int): List<String> {
        if (maxScan <= 0) return emptyList()
        val out = ArrayList<String>(minOf(ids.size, maxScan))
        val seen = HashSet<String>(minOf(ids.size, maxScan))
        for (raw in ids) {
            val id = raw.trim()
            // The conversation host keys holders by the canonical dashed UUID
            // text. Anything else cannot name a real stored task.
            if (!id.isCanonicalUuidText()) continue
            if (!seen.add(id)) continue
            out += id
            if (out.size >= maxScan) break
        }
        return out
    }

    /**
     * The ONLY holder-map keys that may name the same conversation as
     * [taskID].
     *
     * Native run identities are emitted as canonical uppercase UUID text
     * (`UUID.uuidString`), while JVM-side identities (`UUID.toString()`) are
     * canonical lowercase. The conversation host keys holders by the exact
     * string it opened, so the native spelling is tried first and the JVM
     * spelling second. Both keys are derived from THIS UUID only: no map scan,
     * no case-insensitive search and no other owner's key.
     */
    fun holderLookupKeys(taskID: UUID): List<String> {
        val javaLower = taskID.toString()
        val nativeUpper = javaLower.uppercase(Locale.ROOT)
        return if (nativeUpper == javaLower) listOf(javaLower) else listOf(nativeUpper, javaLower)
    }

    /**
     * True only when [selectedRunID] is the SAME canonical UUID as [runID].
     *
     * The native-uppercase / JVM-lowercase spelling difference is the only
     * tolerated variation. Short/legacy UUID forms (`1-1-1-1-1`), undashed
     * 32-char hex, braces and surrounding text are refused, so a malformed
     * selected run can never be read as this owner.
     */
    fun selectedRunMatches(selectedRunID: String?, runID: UUID): Boolean {
        val selected = selectedRunID ?: return false
        if (!selected.isCanonicalUuidText()) return false
        return selected.equals(runID.toString(), ignoreCase = true)
    }

    /**
     * The exact live-owner predicate the host applies to the REAL holder: the
     * holder must still report running AND its selected run must be this
     * owner's run. A terminal/other/malformed selected run is never live.
     */
    fun liveOwnerRun(
        isRunning: Boolean,
        selectedRunID: String?,
        runID: UUID,
    ): Boolean = isRunning && selectedRunMatches(selectedRunID, runID)

    const val CODE_STOP_SETTLING = "device_stop_settling"
    const val CODE_NO_LIVE_TASK = "no_live_task"
}

private const val CANONICAL_UUID_CHARS = 36

private fun Char.isAsciiHexDigit(): Boolean =
    this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

/** Canonical dashed UUID text; the only conversation/holder identity form. */
private fun String.isCanonicalUuidText(): Boolean {
    if (length != CANONICAL_UUID_CHARS) return false
    for (index in indices) {
        val isDash = index == 8 || index == 13 || index == 18 || index == 23
        if (isDash) {
            if (this[index] != '-') return false
        } else if (!this[index].isAsciiHexDigit()) {
            return false
        }
    }
    return true
}
