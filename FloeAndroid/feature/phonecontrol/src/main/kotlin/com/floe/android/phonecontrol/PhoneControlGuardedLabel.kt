// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** A single proven-unchanged, non-editable button label. Never logs content. */
internal object PhoneControlGuardedLabel {
    fun canBaseline(node: PhoneControlNodeRecord, records: Collection<PhoneControlNodeRecord>): Boolean {
        if (!node.visible || node.editable || node.password || node.redacted || node.semanticOwnIncomplete ||
            PhoneControlNodeAction.SET_TEXT in node.actions || node.semanticIdentity == null) return false
        fun actionable(record: PhoneControlNodeRecord) =
            record.clickable || PhoneControlNodeAction.CLICK in record.actions
        return actionable(node) || records.any { parent ->
            parent.visible && !parent.editable && !parent.password && !parent.redacted && actionable(parent) &&
                !parent.semanticFlagsUnavailable && parent.semanticIdentity != null &&
                parent.packageName == node.packageName && parent.path.size + 1 == node.path.size &&
                node.path.take(parent.path.size) == parent.path
        }
    }

    data class Label(val text: String?, val description: String?) {
        override fun toString(): String = "Label(redacted)"
    }

    fun read(
        guarded: Boolean, platformSensitive: Boolean, editable: Boolean?, password: Boolean?,
        actionsKnown: Boolean, setText: Boolean, clickable: Boolean,
        safeAncestry: Boolean = true,
        key: com.floe.android.contracts.SensitiveUiLabelKey?, expectedDigest: String?,
        text: () -> String?, description: () -> String?,
    ): Label? {
        if (!guarded || platformSensitive || editable != false || password != false ||
            !actionsKnown || setText || !clickable || !safeAncestry || key == null || expectedDigest == null) return null
        val value = Label(text(), description())
        val current = com.floe.android.contracts.SensitiveUiLabelFingerprint.hmac(key, value.text, value.description)
        return value.takeIf { current != null && java.security.MessageDigest.isEqual(
            current.toByteArray(Charsets.US_ASCII), expectedDigest.toByteArray(Charsets.US_ASCII),
        ) }
    }
}
