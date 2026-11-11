// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Closed settings table for the two typed settings tools (system.settings.read
 * and system.settings.write). This is the ONLY settings surface: no secure
 * namespace, no credential/accessibility/ADB/installation keys, no accounts,
 * no factory reset, no arbitrary namespace/key/raw shell escape. Every key is
 * a practical, user-visible device setting with a strict value grammar.
 *
 * Semantics (frozen authority contract):
 *  - `system` keys are read and written for the EXACT current user; receipts
 *    carry that user id.
 *  - the three `global` animation scales are DEVICE-WIDE; receipts mark them
 *    deviceWide and never attach a package/profile target. Package selection
 *    cannot prove authority over global settings.
 *  - unsupported or missing values are REPORTED (present=false / typed
 *    failure codes), never fabricated. A stored read-back is a stored setting
 *    result, not proof a manufacturer immediately honored an effect.
 *
 * The table, the value grammar and the batch checks are pure so the App host,
 * the privileged service and the JVM tests all decide identically.
 */
object SettingsKeyPolicy {

    const val NAMESPACE_SYSTEM = "system"
    const val NAMESPACE_GLOBAL = "global"

    /** Typed bounded batch: at most eight changes per write call. */
    const val MAX_BATCH_CHANGES = 8

    const val MAX_VALUE_LENGTH = 16

    val SUPPORTED_NAMESPACES: Set<String> = setOf(NAMESPACE_SYSTEM, NAMESPACE_GLOBAL)

    enum class ValueKind {
        /** Non-negative integer setting (brightness, timeout, 0/1 toggles...). */
        INT,

        /** Finite decimal animation scale 0..10 (up to three fraction digits). */
        SCALE,
    }

    data class KeySpec(
        val namespace: String,
        val key: String,
        val kind: ValueKind,
        val minInclusive: Long,
        val maxInclusive: Long,
    ) {
        /** Global settings apply device-wide, never per user/profile. */
        val deviceWide: Boolean get() = namespace == NAMESPACE_GLOBAL
    }

    /**
     * The closed practical key table. Order is stable: receipts and UI rows
     * derive their display order from it.
     */
    val ALL_SPECS: List<KeySpec> = listOf(
        KeySpec(NAMESPACE_SYSTEM, "screen_brightness", ValueKind.INT, 0, 255),
        KeySpec(NAMESPACE_SYSTEM, "screen_brightness_mode", ValueKind.INT, 0, 1),
        KeySpec(NAMESPACE_SYSTEM, "accelerometer_rotation", ValueKind.INT, 0, 1),
        KeySpec(NAMESPACE_SYSTEM, "user_rotation", ValueKind.INT, 0, 3),
        KeySpec(NAMESPACE_SYSTEM, "screen_off_timeout", ValueKind.INT, 15_000, 1_800_000),
        KeySpec(NAMESPACE_SYSTEM, "sound_effects_enabled", ValueKind.INT, 0, 1),
        KeySpec(NAMESPACE_SYSTEM, "haptic_feedback_enabled", ValueKind.INT, 0, 1),
        KeySpec(NAMESPACE_GLOBAL, "window_animation_scale", ValueKind.SCALE, 0, 10),
        KeySpec(NAMESPACE_GLOBAL, "transition_animation_scale", ValueKind.SCALE, 0, 10),
        KeySpec(NAMESPACE_GLOBAL, "animator_duration_scale", ValueKind.SCALE, 0, 10),
    )

    fun specFor(namespace: String, key: String): KeySpec? =
        ALL_SPECS.firstOrNull { it.namespace == namespace && it.key == key }

    sealed interface ValueCheck {
        /** [normalized] is the canonical decimal form sent to the OS. */
        data class Ok(val normalized: String) : ValueCheck
        data class Rejected(val code: String) : ValueCheck
    }

    /**
     * Strict ASCII decimal grammar: 1..16 chars, digits with at most one '.'
     * and 1..3 fraction digits, must start with a digit, finite, inside the
     * spec range. INT values must be whole. Normalization strips redundant
     * trailing zeros ("1.500" -> "1.5", "00084" -> "84") so requested and
     * read-back strings compare exactly.
     */
    fun checkValue(spec: KeySpec, raw: String): ValueCheck {
        if (raw.isEmpty()) return ValueCheck.Rejected("value_missing")
        if (raw.length > MAX_VALUE_LENGTH) return ValueCheck.Rejected("value")
        if (!raw.all { it in '0'..'9' || it == '.' }) return ValueCheck.Rejected("value")
        if (!raw.first().isDigit()) return ValueCheck.Rejected("value")
        val dot = raw.indexOf('.')
        if (dot != -1) {
            if (dot != raw.lastIndexOf('.')) return ValueCheck.Rejected("value")
            val fraction = raw.length - dot - 1
            if (fraction == 0 || fraction > 3) return ValueCheck.Rejected("value")
        }
        val numeric = raw.toDoubleOrNull() ?: return ValueCheck.Rejected("value")
        if (!numeric.isFinite()) return ValueCheck.Rejected("value")
        if (numeric < spec.minInclusive || numeric > spec.maxInclusive) {
            return ValueCheck.Rejected("value_range")
        }
        return when (spec.kind) {
            ValueKind.INT -> {
                if (numeric % 1.0 != 0.0) return ValueCheck.Rejected("value")
                ValueCheck.Ok(numeric.toLong().toString())
            }
            ValueKind.SCALE -> ValueCheck.Ok(normalizeDecimal(raw))
        }
    }

    private fun normalizeDecimal(raw: String): String {
        if ('.' !in raw) return raw.trimStart('0').ifEmpty { "0" }
        var whole = raw.substringBefore('.')
        val fraction = raw.substringAfter('.').trimEnd('0')
        whole = whole.trimStart('0').ifEmpty { "0" }
        return if (fraction.isEmpty()) whole else "$whole.$fraction"
    }

    enum class ChangeAction {
        /** Store [value] (normalized) at the key. */
        PUT,

        /** Delete the key; only restores an originally-absent value. */
        DELETE,
    }

    data class ChangeRequest(
        val namespace: String,
        val key: String,
        val action: ChangeAction,
        /** Required for PUT (raw model/host text); ignored for DELETE. */
        val value: String?,
    )

    sealed interface BatchCheck {
        data class Ok(val changes: List<ChangeRequest>) : BatchCheck
        data class Rejected(val code: String) : BatchCheck
    }

    /**
     * Validate one bounded batch strictly: size, duplicate (namespace, key),
     * closed namespace/key table and per-item value grammar. The returned Ok
     * list carries NORMALIZED values ready for the wire and the OS. A delete
     * never needs a value; a put without one is refused.
     */
    fun checkBatch(raw: List<ChangeRequest>): BatchCheck {
        if (raw.isEmpty()) return BatchCheck.Rejected("changes_empty")
        if (raw.size > MAX_BATCH_CHANGES) return BatchCheck.Rejected("changes_too_many")
        val seen = HashSet<Pair<String, String>>(raw.size)
        val out = ArrayList<ChangeRequest>(raw.size)
        for (item in raw) {
            if (item.namespace !in SUPPORTED_NAMESPACES) {
                return BatchCheck.Rejected("setting_namespace")
            }
            if (!seen.add(item.namespace to item.key)) return BatchCheck.Rejected("changes_duplicate")
            val spec = specFor(item.namespace, item.key)
                ?: return BatchCheck.Rejected("setting_key")
            when (item.action) {
                ChangeAction.PUT -> {
                    val checked = checkValue(spec, item.value ?: "")
                    when (checked) {
                        is ValueCheck.Ok -> out.add(item.copy(value = checked.normalized))
                        is ValueCheck.Rejected -> return BatchCheck.Rejected(checked.code)
                    }
                }
                ChangeAction.DELETE -> out.add(item.copy(value = null))
            }
        }
        return BatchCheck.Ok(out)
    }
}
