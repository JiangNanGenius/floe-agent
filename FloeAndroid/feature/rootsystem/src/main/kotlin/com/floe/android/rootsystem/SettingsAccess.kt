// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

/**
 * Typed models for the closed settings tools. Values are stored strings from
 * the real Settings provider: `null` means the key is ABSENT (never
 * fabricated). `system` receipts name the exact current user; the three
 * `global` animation scales are explicitly device-wide.
 */
enum class SettingsChangeAction { PUT, DELETE }

/** One validated change request (values already normalized by the policy). */
data class SettingsChange(
    val namespace: String,
    val key: String,
    val action: SettingsChangeAction,
    val value: String?,
)

/** Stored result of one typed settings read. */
data class SettingReadResult(
    val namespace: String,
    val key: String,
    val value: String?,
    val userId: Int,
    val deviceWide: Boolean,
)

/**
 * Definitive outcome of ONE settings change attempt. [succeeded] is decided
 * by the real post-operation read-back, never by a bare child success string:
 *  - PUT ok        : exit 0 and the stored value equals the requested value.
 *  - PUT mismatch  : exit 0 but the OEM stored a different value (reported,
 *                    not silently accepted).
 *  - DELETE ok     : exit 0 and the key is absent afterwards.
 * [oldValue] retains the exact stored value before the attempt, including
 * absence (null), so the UI/tool can restore it or delete an originally
 * absent key. [effectiveValue] is the stored read-back after the attempt.
 */
data class SettingItemReceipt(
    val namespace: String,
    val key: String,
    val action: SettingsChangeAction,
    val oldValue: String?,
    val requestedValue: String?,
    val effectiveValue: String?,
    val userId: Int,
    val deviceWide: Boolean,
    val succeeded: Boolean,
    val detailCode: String,
    val failureDetail: String? = null,
)

/**
 * Bounded batch outcome. Cancellation stops the remaining items and preserves
 * the completed receipts; [exitStatus] is the truthful process-style status
 * the host publishes with the batch (0 all ok, 1 some/all failed,
 * 130 cancelled with everything else ok, 131 cancelled with failures).
 */
data class SettingsBatchReceipt(
    val requested: Int,
    val ok: Int,
    val failed: Int,
    val skipped: Int,
    val cancelled: Boolean,
    val items: List<SettingItemReceipt>,
) {
    fun exitStatus(): Int = when {
        cancelled && failed > 0 -> 131
        cancelled -> 130
        failed > 0 || ok == 0 -> 1
        else -> 0
    }
}
