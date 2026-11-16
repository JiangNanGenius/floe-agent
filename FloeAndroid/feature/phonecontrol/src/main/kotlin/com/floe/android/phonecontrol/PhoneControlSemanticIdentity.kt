// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.security.MessageDigest

/**
 * Bounded, RAM-only identity of a visible, non-editable node's own labels.
 * It never replaces live owner, foreground, path, bounds or grant checks.
 * Password, redacted and editable fields are ineligible: their readers are
 * never invoked, even when the service cannot determine a live field flag.
 */
internal class PhoneControlSemanticIdentity private constructor(
    private val digest: ByteArray,
) {
    override fun toString(): String = "PhoneControlSemanticIdentity(redacted)"
    override fun equals(other: Any?): Boolean =
        other is PhoneControlSemanticIdentity && MessageDigest.isEqual(digest, other.digest)
    override fun hashCode(): Int = digest.contentHashCode()

    companion object {
        // The model sees at most MAX_FIELD_CHARS per field. Bound before
        // sanitation or hashing, including when a platform text is huge.
        private const val MAX_LABEL_CHARS = PhoneControlLimits.MAX_FIELD_CHARS

        fun capture(
            visible: Boolean,
            editable: Boolean,
            password: Boolean,
            redacted: Boolean,
            text: () -> CharSequence?,
            description: () -> CharSequence?,
        ): PhoneControlSemanticIdentity? {
            if (!visible || editable || password || redacted) return null
            val md = MessageDigest.getInstance("SHA-256")
            addField(md, text())
            addField(md, description())
            return PhoneControlSemanticIdentity(md.digest())
        }

        /** Only the target's own and descendant evidence determine click availability. */
        fun clickEvidenceDenial(
            flagsUnavailable: Boolean,
            hasIdentity: Boolean,
            ownIncomplete: Boolean,
            childrenIncomplete: Boolean,
            childrenTextIncomplete: Boolean = false,
        ): PhoneControlDenial? = if (
            flagsUnavailable || (hasIdentity && (ownIncomplete || childrenIncomplete ||
                childrenTextIncomplete))
        ) PhoneControlDenial.NODE_UNAVAILABLE else null

        /** A changed label is never permission to dispatch the old ref. */
        fun validate(
            expected: PhoneControlSemanticIdentity?,
            visible: Boolean,
            editable: Boolean,
            password: Boolean,
            redacted: Boolean,
            sensitiveInput: Boolean,
            text: () -> CharSequence?,
            description: () -> CharSequence?,
        ): PhoneControlDenial? {
            if (expected == null) return null
            if (sensitiveInput) return PhoneControlDenial.STALE_OBSERVATION
            val current = capture(visible, editable, password, redacted, text, description)
            return if (current == expected) null else PhoneControlDenial.STALE_OBSERVATION
        }

        private fun addField(md: MessageDigest, value: CharSequence?) {
            if (value == null) {
                md.update(0)
                return
            }
            md.update(1)
            var end = minOf(value.length, MAX_LABEL_CHARS)
            if (end > 0 && end < value.length && Character.isHighSurrogate(value[end - 1])) end--
            val bounded = value.subSequence(0, end).toString()
            val clean = PhoneControlText.clean(bounded).orEmpty().toByteArray(Charsets.UTF_8)
            // Separate fields even when byte sequences contain equal prefixes.
            md.update((clean.size ushr 24).toByte())
            md.update((clean.size ushr 16).toByte())
            md.update((clean.size ushr 8).toByte())
            md.update(clean.size.toByte())
            md.update(clean)
            // Changes in suffix length still invalidate a truncated label.
            val length = minOf(value.length, MAX_LABEL_CHARS * 4 + 1)
            md.update((length ushr 24).toByte())
            md.update((length ushr 16).toByte())
            md.update((length ushr 8).toByte())
            md.update(length.toByte())
        }
    }
}
