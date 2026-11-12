// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.UiDispatchOutcome

/**
 * One framework node-action attempt.
 *
 * [REJECTED] is the platform's own boolean `false`: the action was not
 * performed, so a bounded coordinate fallback is still allowed exactly once.
 * [THREW] is an exception and can never prove that nothing was sent.
 */
internal enum class UiActionAttempt { ACCEPTED, REJECTED, THREW }

internal data class UiActionDecision(
    val dispatch: UiDispatchOutcome,
    val fallbackAllowed: Boolean,
)

/**
 * One injected input event (motion or key).
 *
 * [REJECTED] is `UiAutomation.injectInputEvent` returning `false` (not sent).
 * [THREW] is an exception after which the caller cannot prove the event was
 * not accepted. Only a first-event REJECTED proves the gesture never started.
 */
internal enum class UiInputSend { ACCEPTED, REJECTED, THREW }

internal data class UiInputDecision(
    val dispatch: UiDispatchOutcome,
    /** True when an owned UP/release must be attempted before returning. */
    val releaseRequired: Boolean,
    /** True when at least one event may already have reached the device. */
    val partial: Boolean,
)

/**
 * Truthful dispatch-state policy shared by the real Android bridge.
 *
 * ACCEPTED is framework acceptance, never semantic success. A partial,
 * thrown or unknown dispatch is UNKNOWN, requires a real readback and must
 * never trigger a second method or backend replay.
 */
internal object UiDispatchPolicy {

    fun action(attempt: UiActionAttempt): UiActionDecision = when (attempt) {
        UiActionAttempt.ACCEPTED -> UiActionDecision(UiDispatchOutcome.ACCEPTED, false)
        UiActionAttempt.REJECTED -> UiActionDecision(UiDispatchOutcome.NOT_DISPATCHED, true)
        UiActionAttempt.THREW -> UiActionDecision(UiDispatchOutcome.UNKNOWN, false)
    }

    /**
     * @param sends the events actually attempted, in order
     * @param cancelledBeforeCompletion true when the sequence stopped after an
     *   accepted event because the live owner cancelled; the remaining UP/
     *   MOVE events were never sent
     */
    fun input(
        sends: List<UiInputSend>,
        cancelledBeforeCompletion: Boolean = false,
    ): UiInputDecision {
        if (sends.isEmpty()) {
            return UiInputDecision(UiDispatchOutcome.NOT_DISPATCHED, false, false)
        }
        when (sends.first()) {
            UiInputSend.REJECTED ->
                return UiInputDecision(UiDispatchOutcome.NOT_DISPATCHED, false, false)
            UiInputSend.THREW ->
                return UiInputDecision(UiDispatchOutcome.UNKNOWN, true, true)
            UiInputSend.ACCEPTED -> Unit
        }
        val laterRejected = sends.drop(1).any { it != UiInputSend.ACCEPTED }
        return if (cancelledBeforeCompletion || laterRejected) {
            UiInputDecision(UiDispatchOutcome.UNKNOWN, true, true)
        } else {
            UiInputDecision(UiDispatchOutcome.ACCEPTED, false, false)
        }
    }
}

/**
 * Ownership fence for releasing a held input. The legacy requestId-only
 * cancel matches the exact operation request; a claim-bound cancel must also
 * match the full task/run/epoch/grant token. A successor's gesture can never
 * be released by an older task.
 */
internal object UiInputLeasePolicy {

    /** An attempted or queued UP does not settle ownership of a held input. */
    fun release(
        stillOwned: () -> Boolean,
        attempt: () -> String,
        clearOwnership: () -> Unit,
    ): String {
        if (!stillOwned()) return "release=superseded"
        val state = try {
            attempt()
        } catch (_: Throwable) {
            "release=unconfirmed"
        }
        if (state == "release=confirmed" && stillOwned()) clearOwnership()
        return state
    }

    fun matches(
        activeToken: String,
        activeRequestId: String,
        requestId: String,
        ownerToken: String?,
    ): Boolean {
        if (activeRequestId != requestId) return false
        return ownerToken == null || activeToken == ownerToken
    }
}
