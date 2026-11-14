// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

/**
 * Pure, bounded status model for the optional floating control.
 *
 * It is presentation only. The host supplies an already-looked-up localized
 * action label and a fixed state; this object never receives node text,
 * typed values, credentials or raw model arguments, so no such content can
 * be rendered or persisted by the overlay. Only the latest operation is
 * retained by [PhoneAutomationControls]; there is no event list.
 */
internal enum class PhoneAutomationOperationState {
    RUNNING,
    DONE,
    WAITING,
    FAILED,
    UNKNOWN,
    CANCELLED,
}

internal data class PhoneAutomationOperation(
    val label: String,
    val state: PhoneAutomationOperationState,
    val note: String? = null,
)

internal object PhoneAutomationStatusText {
    const val MAX_LABEL = 32
    const val MAX_NOTE = 48

    /** Background task progress or a retained result must not leave a
     * resident bubble. A fresh real screen operation can show it again. */
    fun showsOverlay(paused: Boolean, waitingForUser: Boolean,
                     state: PhoneAutomationOperationState?): Boolean =
        paused || waitingForUser || state == PhoneAutomationOperationState.RUNNING ||
            state == PhoneAutomationOperationState.WAITING

    /**
     * One inert single-line display value. Control characters (including
     * CR/LF) are removed instead of allowing a multi-line/spoofed status, and
     * the length is hard-bounded. This is not an authorization or logging
     * path; hostile node text is never an input here.
     */
    fun bounded(value: String, max: Int): String {
        val clean = value.filter { it.code >= 32 && it.code != 127 }.trim()
        return clean.take(max.coerceAtLeast(0))
    }

    fun operation(
        label: String,
        state: PhoneAutomationOperationState,
        note: String? = null,
    ): PhoneAutomationOperation = PhoneAutomationOperation(
        label = bounded(label, MAX_LABEL),
        state = state,
        note = note?.let { bounded(it, MAX_NOTE) }?.takeIf { it.isNotEmpty() },
    )
}
