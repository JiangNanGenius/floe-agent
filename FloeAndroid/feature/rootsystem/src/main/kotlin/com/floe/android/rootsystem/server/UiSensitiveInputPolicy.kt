// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

/**
 * SET_TEXT admission over one already-resolved live node.
 *
 * The explicit `sensitiveText` intent is the only key that may fill a
 * protected field. Ordinary text stays refused there. Because the live node
 * is re-read before dispatch, a field whose protection changed after the
 * observation is stale and is refused instead of being guessed. Identity
 * (package/class/view id/bounds/actions/editable) was already checked; this
 * policy only decides the text-sensitivity question. No value is read back.
 */
internal object UiSensitiveInputPolicy {

    fun denial(
        hasText: Boolean,
        sensitiveIntent: Boolean,
        storedPassword: Boolean,
        storedRedacted: Boolean,
        livePassword: Boolean,
        liveRedacted: Boolean,
        liveEditable: Boolean,
        advertisesSetText: Boolean,
    ): String? {
        if (!hasText) return "text_required"
        if (storedPassword != livePassword || storedRedacted != liveRedacted) {
            return "sensitive_field_changed"
        }
        if ((storedPassword || storedRedacted || livePassword || liveRedacted) &&
            !sensitiveIntent
        ) {
            return "sensitive_field"
        }
        if (!liveEditable && !advertisesSetText) return "not_editable"
        return null
    }
}
