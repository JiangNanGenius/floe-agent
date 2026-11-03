// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

import com.floe.android.core.officeengine.OfficeDocumentFormat
import java.util.LinkedHashMap

/**
 * Mount-scoped observer for the engine's real `statechanged:` review facts.
 *
 * The tracker is deliberately a *record*, not an optimistic state machine:
 *
 *  - a dispatched command becomes `pendingAction` immediately, but it is
 *    NEVER written into [recording]/[showingChanges]/availability fields;
 *  - those fields change only from a real engine `statechanged:` frame;
 *  - the action is marked acknowledged only by a command-specific state
 *    frame, and a missing acknowledgement expires into an explicit
 *    `noAcknowledgement` failure rather than a fabricated success.
 *
 * One instance belongs to one native Session; a remount creates a new
 * generation and therefore a new tracker with no inherited state.
 */
class OfficeRevisionTracker {
    private data class Pending(val action: OfficeRevisionAction, val sinceElapsedMs: Long)

    private val states = LinkedHashMap<String, String>()

    @Volatile private var pending: Pending? = null
    @Volatile private var lastDispatched: OfficeRevisionAction? = null
    @Volatile private var lastAcknowledged: OfficeRevisionAction? = null
    @Volatile private var lastFailure: String? = null
    @Volatile private var mutationEpoch: Long = 0L
    @Volatile private var lastObservedAtElapsedMs: Long = 0L

    /**
     * Consumes one engine state fact. Returns true when this frame is a
     * review-related fact the caller should publish to the viewer.
     */
    @Synchronized
    fun onStateChanged(commandName: String, rawState: String?, nowElapsedMs: Long): Boolean {
        if (commandName !in OfficeRevisionContract.observedCommands) return false
        lastObservedAtElapsedMs = nowElapsedMs
        if (rawState != null) {
            states.remove(commandName)
            states[commandName] = rawState
            while (states.size > MAX_OBSERVED_STATES) {
                states.remove(states.keys.iterator().next())
            }
        }
        val dispatched = lastDispatched
        if (dispatched != null && OfficeRevisionContract.acknowledges(dispatched, commandName)) {
            lastAcknowledged = dispatched
            lastDispatched = null
            lastFailure = null
            val current = pending
            if (current != null && current.action == dispatched) pending = null
        }
        return true
    }

    /**
     * Registers a really-dispatched command. The caller must already have
     * proved the exact mount and successfully written the wire frame.
     */
    @Synchronized
    fun onDispatched(action: OfficeRevisionAction, nowElapsedMs: Long) {
        lastDispatched = action
        lastAcknowledged = null
        lastFailure = null
        if (action.mutatesDocument) mutationEpoch++
        if (action.expectsStateChange) pending = Pending(action, nowElapsedMs)
    }

    /**
     * A text command that already reached the page (its own Review menu uses
     * the same UNO actions) is counted as a real revision mutation attempt.
     * This keeps the keep-revisions PDF proof honest even when the user
     * operated the engine's built-in menu instead of the Floe review sheet.
     */
    @Synchronized
    fun notePageMutation(commandName: String?) {
        if (OfficeRevisionContract.isMutationCommand(commandName)) mutationEpoch++
    }

    /** Dispatch could not be written to the native transport: no state change. */
    @Synchronized
    fun onDispatchFailed(action: OfficeRevisionAction, code: String) {
        lastDispatched = null
        pending = null
        lastFailure = code
    }

    /**
     * Bounded acknowledgement window elapsed. A late state frame can still
     * set [lastAcknowledged] later; this only stops blocking the next action.
     */
    @Synchronized
    fun expirePending(action: OfficeRevisionAction? = null): Boolean {
        val current = pending ?: return false
        if (action != null && current.action != action) return false
        pending = null
        lastFailure = "noAcknowledgement"
        return true
    }

    @Synchronized
    fun hasPending(): Boolean = pending != null

    @Synchronized
    fun pendingAction(): OfficeRevisionAction? = pending?.action

    @Synchronized
    fun mutationEpoch(): Long = mutationEpoch

    @Synchronized
    fun snapshot(
        sessionToken: String,
        generation: Long,
        format: OfficeDocumentFormat,
        manageRedlines: Boolean,
        liveEditableMount: Boolean,
        editPermissionEstablished: Boolean,
        pageEditMode: Boolean,
        nativeLeaseBusy: Boolean,
        nowElapsedMs: Long,
    ): OfficeRevisionState {
        val pendingValue = pending
        val timedOut = pendingValue != null && nowElapsedMs - pendingValue.sinceElapsedMs > ACK_WINDOW_MS
        val support = when {
            !liveEditableMount || !editPermissionEstablished -> OfficeRevisionSupport.NO_LIVE_EDIT_SESSION
            !OfficeRevisionContract.supports(format) -> OfficeRevisionSupport.WRITER_ONLY
            !manageRedlines -> OfficeRevisionSupport.REVIEW_NOT_AUTHORIZED
            !pageEditMode -> OfficeRevisionSupport.EDIT_MODE_REQUIRED
            nativeLeaseBusy -> OfficeRevisionSupport.NATIVE_LEASE_BUSY
            pendingValue != null && !timedOut -> OfficeRevisionSupport.ACTION_PENDING
            else -> OfficeRevisionSupport.SUPPORTED
        }
        fun value(name: String): Boolean? = OfficeRevisionContract.enabled(states[name])
        return OfficeRevisionState(
            sessionToken = sessionToken,
            generation = generation,
            support = support,
            manageRedlines = manageRedlines,
            pageEditMode = pageEditMode,
            recording = value(".uno:TrackChanges"),
            showingChanges = value(".uno:ShowTrackedChanges"),
            acceptCurrentAvailable = value(".uno:AcceptTrackedChange"),
            rejectCurrentAvailable = value(".uno:RejectTrackedChange"),
            acceptAllAvailable = value(".uno:AcceptAllTrackedChanges")
                ?: value(".uno:AcceptTrackedChanges"),
            rejectAllAvailable = value(".uno:RejectAllTrackedChanges")
                ?: value(".uno:RejectTrackedChanges"),
            previousAvailable = value(".uno:PreviousTrackedChange"),
            nextAvailable = value(".uno:NextTrackedChange"),
            pendingAction = pendingValue?.action,
            pendingTimedOut = timedOut,
            lastAcknowledged = lastAcknowledged,
            lastFailure = lastFailure,
            mutationEpoch = mutationEpoch,
            observedAtElapsedMs = lastObservedAtElapsedMs,
        )
    }

    companion object {
        /** Short and bounded: the engine answers a review command over the
         *  already-open mobile socket, normally within a few frames. */
        const val ACK_WINDOW_MS = 3_500L

        /** The review UI only consumes a dozen command states. */
        private const val MAX_OBSERVED_STATES = 32
    }
}
