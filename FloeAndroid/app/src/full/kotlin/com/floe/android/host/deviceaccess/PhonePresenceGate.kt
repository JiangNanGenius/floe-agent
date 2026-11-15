// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneInteractionStamp
import com.floe.android.phonecontrol.PhoneUserInteractionSource

/**
 * Pure decision for the "the user is holding the device" presence question.
 *
 * The earlier host gate used the session's initial `lastUserInteraction`
 * values, which were stamped at session construction. A service reconnect, a
 * fresh client or a runtime restart therefore looked like a user touch that
 * happened AFTER the previous human approval, and `device.observe` asked a
 * screen-presence question with no actual user input. Session construction is
 * not presence: a null or zero stamp means "no observed human signal".
 *
 * The rule stays conservative:
 *  - a signal must have been OBSERVED by this session (non-zero elapsed and
 *    wall stamps);
 *  - it must be younger than the bounded active window;
 *  - its wall time must be strictly newer than the human approval timestamp.
 *
 * This function never grants device control and never decides ownership; the
 * live arm/grant/tool fences remain authoritative. Android-free for JVM tests.
 */
internal object PhonePresenceGate {
    /**
     * Kept equal to the historical `userIsActive()` window. The behavior of a
     * genuine recent touch is unchanged; only the fabricated session-start
     * signal is removed.
     */
    const val RECENT_INTERACTION_WINDOW_MILLIS = 15_000L

    fun requiresHumanApproval(
        nowElapsedRealtimeMillis: Long,
        interaction: PhoneInteractionStamp?,
        presenceApprovedAtMillis: Long,
    ): Boolean {
        if (interaction == null) return false
        if (interaction.elapsedRealtimeMillis <= 0L) return false
        if (interaction.wallMillis <= 0L) return false
        if (interaction.source == PhoneUserInteractionSource.NONE) return false
        val age = nowElapsedRealtimeMillis - interaction.elapsedRealtimeMillis
        // A future elapsed stamp is not a valid observation; treat it as
        // recent only because the wall check still requires a real stamp.
        if (age >= RECENT_INTERACTION_WINDOW_MILLIS) return false
        return presenceApprovedAtMillis < interaction.wallMillis
    }
}
