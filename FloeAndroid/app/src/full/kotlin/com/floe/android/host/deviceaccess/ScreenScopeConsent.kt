// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessScreenScopeUi
import com.floe.android.phonecontrol.PhoneControlBlocker
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlStatus

/**
 * RAM-only screen-share consent for `device.screenshot` (canonical
 * device-namespace name; the tool was previously published as
 * `phone.screenshot` and legacy persisted records keep that spelling).
 *
 * "This task" is an explicit user grant for ONE live task/run owner in ONE
 * native root epoch. It never applies to a different live task, a finished
 * run, a restarted process or a new epoch, and it is never written to
 * preferences.
 *
 * "Until stopped" is the distinct broader session mode offered by the same
 * control: it survives task transitions, but an actual Stop/Takeover, an epoch
 * change or phone-service teardown revokes it. It is RAM-only as well.
 *
 * This type owns only that ceiling. The phone backend keeps its own owner /
 * stop / lock / page fences, and whole-screen display capture still needs the
 * separate explicit whole-screen consent checked by the tool handler.
 */
internal data class ScreenScopeBinding(
    val mode: DeviceAccessScreenScopeUi,
    /** Exact live owner for CURRENT_TASK; null for the broader UNTIL_STOPPED. */
    val owner: PhoneControlOwner?,
    val epoch: Long,
)

internal sealed interface ScreenScopeSelection {
    data class Active(val binding: ScreenScopeBinding) : ScreenScopeSelection

    data object Cleared : ScreenScopeSelection

    data class Refused(val code: String) : ScreenScopeSelection
}

/**
 * Immutable identity of the consent that allowed ONE screenshot dispatch.
 * The revision makes a revoke+regrant distinguishable from the original
 * grant: an old async capture can never validate against the new binding even
 * when mode/owner/epoch happen to match again.
 */
internal data class ScreenScopeTicket(
    val revision: Long,
    val owner: PhoneControlOwner,
    val epoch: Long,
)

/**
 * True only when the Accessibility/driver service itself is gone. A
 * STOPPED/TAKEN_OVER blocker belongs to the explicit Stop/Takeover/arm flow
 * (which clears or replaces the grant itself); treating it as a teardown here
 * would erase a This-task choice made for the task being armed immediately
 * after a takeover.
 */
internal fun phoneServiceTornDown(status: PhoneControlStatus): Boolean =
    !status.connected ||
        !status.enabled ||
        status.blocker == PhoneControlBlocker.SERVICE_REVOKED ||
        status.blocker == PhoneControlBlocker.SERVICE_DISCONNECTED

/**
 * One small RAM state machine, not an owner registry: the host already has the
 * exact candidate lifetime from the conversation holder. Binding and revision
 * live in one immutable snapshot so a concurrent reconcile/drop cannot pair an
 * old revision with a new binding.
 */
internal class ScreenScopeConsent {

    private data class State(
        val binding: ScreenScopeBinding?,
        val revision: Long,
    )

    private val lock = Any()

    @Volatile
    private var state = State(binding = null, revision = 0)

    val binding: ScreenScopeBinding?
        get() = state.binding

    /** Monotonic RAM revision; every actual consent transition advances it. */
    val revision: Long
        get() = state.revision

    /**
     * Apply an explicit user selection. [candidateOwner] is the CURRENT live
     * run the screen-scope control is about; [sessionOwner] may also be an
     * existing exact arm so the broader Until-stopped mode can be chosen from
     * its retained card. "This task" never accepts anything but a live
     * candidate.
     */
    fun select(
        requested: DeviceAccessScreenScopeUi,
        candidateOwner: PhoneControlOwner?,
        sessionOwner: PhoneControlOwner?,
        epoch: Long?,
    ): ScreenScopeSelection {
        if (requested == DeviceAccessScreenScopeUi.OFF) {
            replace(null)
            return ScreenScopeSelection.Cleared
        }
        if (epoch == null || epoch <= 0) {
            return ScreenScopeSelection.Refused(CODE_RUNTIME_NOT_READY)
        }
        return when (requested) {
            DeviceAccessScreenScopeUi.CURRENT_TASK -> {
                val owner = candidateOwner
                    ?: return ScreenScopeSelection.Refused(CODE_NO_LIVE_TASK)
                val active = ScreenScopeBinding(requested, owner, epoch)
                replace(active)
                ScreenScopeSelection.Active(active)
            }
            DeviceAccessScreenScopeUi.UNTIL_STOPPED -> {
                if (sessionOwner == null) {
                    return ScreenScopeSelection.Refused(CODE_NO_LIVE_TASK)
                }
                val active = ScreenScopeBinding(requested, null, epoch)
                replace(active)
                ScreenScopeSelection.Active(active)
            }
            DeviceAccessScreenScopeUi.OFF -> ScreenScopeSelection.Cleared
        }
    }

    /**
     * Re-evaluate the binding against the actual live epoch and (for the exact
     * task mode) the bound run's liveness. A stale binding is dropped without
     * overwriting a newer selection that won the race.
     */
    fun reconcile(epoch: Long?, ownerRunLive: (PhoneControlOwner) -> Boolean) {
        val snapshot = state
        val current = snapshot.binding ?: return
        val exactTaskLive = current.mode != DeviceAccessScreenScopeUi.CURRENT_TASK ||
            (current.owner != null && ownerRunLive(current.owner))
        val keep = current.mode != DeviceAccessScreenScopeUi.OFF &&
            epoch != null && epoch > 0 && current.epoch == epoch &&
            exactTaskLive
        if (!keep) replaceIfRevision(snapshot.revision, null)
    }

    /** Actual Stop/Takeover or service teardown: both modes end. */
    fun clear() {
        replace(null)
    }

    /**
     * Moving the one phone-control grant away from [endedOwner] ends only that
     * exact "This task" consent. A fresh This-task choice for the NEW task and
     * the explicit broader mode both survive by design.
     */
    fun clearExactTask(endedOwner: PhoneControlOwner) {
        synchronized(lock) {
            val snapshot = state
            val current = snapshot.binding
            if (current?.mode == DeviceAccessScreenScopeUi.CURRENT_TASK &&
                current.owner == endedOwner
            ) {
                state = State(binding = null, revision = snapshot.revision + 1)
            }
        }
    }

    /** The exact ceiling for one phone call's owner and epoch. */
    fun allows(owner: PhoneControlOwner, epoch: Long, ownerRunLive: Boolean): Boolean =
        allows(state.binding, owner, epoch, ownerRunLive)

    /**
     * Immutable ticket for ONE screenshot dispatch. Null when the exact owner
     * is not covered right now. The revision makes a later revoke+regrant a
     * different consent, even for the same owner/epoch/mode.
     */
    fun ticket(
        owner: PhoneControlOwner,
        epoch: Long,
        ownerRunLive: Boolean,
    ): ScreenScopeTicket? {
        val snapshot = state
        if (!allows(snapshot.binding, owner, epoch, ownerRunLive)) return null
        return ScreenScopeTicket(snapshot.revision, owner, epoch)
    }

    /**
     * Revalidate a pending capture BEFORE any artifact is written: the exact
     * owner/epoch/run and the ORIGINAL consent revision must still be current,
     * and an original display-capture request still needs whole-screen consent.
     * A window capture never needs the whole-screen switch.
     */
    fun ticketStillValid(
        ticket: ScreenScopeTicket?,
        owner: PhoneControlOwner,
        epoch: Long,
        ownerRunLive: Boolean,
        displayCapture: Boolean,
        wholeScreenConsent: Boolean,
        wholeScreenUnchanged: Boolean = true,
    ): Boolean {
        if (ticket == null) return false
        if (displayCapture && (!wholeScreenConsent || !wholeScreenUnchanged)) return false
        val snapshot = state
        if (ticket.revision != snapshot.revision) return false
        if (ticket.owner != owner || ticket.epoch != epoch) return false
        return allows(snapshot.binding, owner, epoch, ownerRunLive)
    }

    /**
     * The scope the settings page may show for its displayed owner. A stale
     * global selection is never projected: "This task" shows only while the
     * exact bound run is the live candidate; "Until stopped" survives the
     * task transition but only while a task is actually displayed.
     */
    fun presented(
        activeOwner: PhoneControlOwner?,
        liveCandidateOwner: PhoneControlOwner?,
        epoch: Long?,
    ): DeviceAccessScreenScopeUi {
        val current = state.binding ?: return DeviceAccessScreenScopeUi.OFF
        if (activeOwner == null || epoch == null || current.epoch != epoch) {
            return DeviceAccessScreenScopeUi.OFF
        }
        return when (current.mode) {
            DeviceAccessScreenScopeUi.OFF -> DeviceAccessScreenScopeUi.OFF
            DeviceAccessScreenScopeUi.UNTIL_STOPPED -> DeviceAccessScreenScopeUi.UNTIL_STOPPED
            DeviceAccessScreenScopeUi.CURRENT_TASK ->
                if (current.owner == activeOwner && liveCandidateOwner == current.owner) {
                    DeviceAccessScreenScopeUi.CURRENT_TASK
                } else {
                    DeviceAccessScreenScopeUi.OFF
                }
        }
    }

    private fun allows(
        binding: ScreenScopeBinding?,
        owner: PhoneControlOwner,
        epoch: Long,
        ownerRunLive: Boolean,
    ): Boolean {
        if (binding == null) return false
        if (binding.epoch <= 0 || binding.epoch != epoch) return false
        return when (binding.mode) {
            DeviceAccessScreenScopeUi.OFF -> false
            DeviceAccessScreenScopeUi.CURRENT_TASK ->
                binding.owner == owner && ownerRunLive
            // The broader mode is not owner-exact, but a screenshot call must
            // still come from a CURRENTLY LIVE run: A's consent may outlive
            // A's terminal for the next explicit arm, never for a dead A.
            DeviceAccessScreenScopeUi.UNTIL_STOPPED -> ownerRunLive
        }
    }

    private fun replace(next: ScreenScopeBinding?) {
        synchronized(lock) {
            state = State(binding = next, revision = state.revision + 1)
        }
    }

    private fun replaceIfRevision(expected: Long, next: ScreenScopeBinding?) {
        synchronized(lock) {
            val snapshot = state
            if (snapshot.revision == expected) {
                state = State(binding = next, revision = snapshot.revision + 1)
            }
        }
    }

    companion object {
        const val CODE_NO_LIVE_TASK = "no_live_task"
        const val CODE_RUNTIME_NOT_READY = "runtime_not_ready"
    }
}
