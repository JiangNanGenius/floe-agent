// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Pure text sanitation/redaction used by the Android node snapshotter and by
 * unit tests. Nothing here reads credentials: callers decide not to read a
 * password node's text at all, and this object additionally withholds text
 * whose view-id or framework flag marks it sensitive.
 */
internal object PhoneControlText {
    private val DIRECT_SENSITIVE_TOKENS = listOf(
        "password", "passwd", "passcode", "secret", "credential", "otp", "verification",
    )
    private val PIN_BOUNDARY = Regex("(^|[^a-z])pin([^a-z]|$)")

    /**
     * `spinner` must stay non-sensitive: matching raw substrings would turn
     * every spinner into a redacted field. `editTextPin` and `/pin` remain
     * sensitive through the suffix/path checks.
     */
    fun isSensitiveViewId(viewId: String?): Boolean {
        if (viewId.isNullOrBlank()) return false
        val id = viewId.lowercase()
        if (DIRECT_SENSITIVE_TOKENS.any { token -> id.contains(token) }) return true
        return id.endsWith("pin") || PIN_BOUNDARY.containsMatchIn(id)
    }

    /** Drops non-printing controls except tab/newline and trims the edges. */
    fun clean(value: String?): String? {
        if (value == null) return null
        val filtered = buildString(value.length) {
            for (ch in value) {
                when {
                    ch == '\n' || ch == '\t' -> append(ch)
                    ch.code < 0x20 || ch.code == 0x7f -> Unit
                    else -> append(ch)
                }
            }
        }
        return filtered.trim().ifEmpty { null }
    }

    fun bound(value: String?, maxChars: Int): Bound {
        if (value == null) return Bound(null, false)
        if (maxChars <= 0) return Bound(null, true)
        if (value.length <= maxChars) return Bound(value, false)
        var cut = maxChars
        if (cut > 0 && Character.isHighSurrogate(value[cut - 1])) cut -= 1
        return Bound(value.substring(0, cut.coerceAtLeast(0)), true)
    }

    data class Bound(val text: String?, val truncated: Boolean)
}

/**
 * Per-observation character budget. Once exhausted, every later non-empty
 * field is withheld; nodes are still returned so callers can navigate
 * structurally. This is bounded output, not a security boundary.
 */
internal class PhoneControlTextBudget(private var remaining: Int) {
    var truncated: Boolean = false
        private set
    var spent: Int = 0
        private set

    fun take(
        value: String?,
        fieldMax: Int = PhoneControlLimits.MAX_FIELD_CHARS,
    ): PhoneControlText.Bound {
        if (value == null) return PhoneControlText.Bound(null, false)
        if (remaining <= 0) {
            truncated = true
            return PhoneControlText.Bound(null, true)
        }
        val maxInput = (fieldMax * 4).coerceAtLeast(64)
        val inputTruncated = value.length > maxInput
        val raw = if (inputTruncated) value.substring(0, maxInput) else value
        val cleaned = PhoneControlText.clean(raw) ?: return PhoneControlText.Bound(null, inputTruncated)
        val bounded = PhoneControlText.bound(cleaned, minOf(fieldMax, remaining))
        if (inputTruncated || bounded.truncated) truncated = true
        val text = bounded.text ?: return PhoneControlText.Bound(null, true)
        remaining -= text.length
        spent += text.length
        return PhoneControlText.Bound(text, inputTruncated || bounded.truncated)
    }
}
