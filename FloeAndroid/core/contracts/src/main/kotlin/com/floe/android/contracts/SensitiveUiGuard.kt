// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

/** Metadata only. The host must durably save this before dispatching secret text. */
data class SensitiveUiGuardTicket(
    val taskId: String,
    val runId: String,
    val epoch: Long,
    val grantId: String,
    val observationId: String,
    val nodeRef: String,
    val packageName: String,
    val windowId: Int,
    val displayId: Int,
    val path: List<Int>,
    val className: String,
    val viewId: String?,
) {
    fun isWellFormed(): Boolean =
        listOf(taskId, runId, grantId, observationId, nodeRef, packageName, className)
            .all { it.isNotBlank() && it.length <= 255 } && epoch > 0 &&
            windowId >= 0 && displayId >= 0 && path.size <= 32 &&
            path.all { it in 0..4096 } && (viewId == null || viewId.length <= 255)
}

/** Entire atomically persisted host state, including an install-scoped epoch. */
data class SensitiveUiGuardSnapshot(
    val epoch: String,
    val revision: Long,
    val tickets: List<SensitiveUiGuardTicket>,
    val labelKey: SensitiveUiLabelKey? = null,
    val labelBaselines: List<SensitiveUiLabelBaseline> = emptyList(),
)

/** Deliberately independent of app/service lifecycles: absence of sync is unsafe. */
object SensitiveUiGuardPolicy {
    const val MAX_TICKETS = 16
    const val MAX_LABEL_BASELINES = 128

    fun validSession(expected: String, supplied: String?): Boolean =
        expected.isNotBlank() && supplied == expected

    fun valid(tickets: List<SensitiveUiGuardTicket>): Boolean =
        tickets.size <= MAX_TICKETS && tickets.all { it.isWellFormed() } &&
            tickets.distinct().size == tickets.size

    fun valid(snapshot: SensitiveUiGuardSnapshot): Boolean =
        snapshot.epoch.isNotBlank() && snapshot.epoch.length <= 128 &&
            snapshot.revision > 0 && valid(snapshot.tickets) &&
            snapshot.labelBaselines.size <= MAX_LABEL_BASELINES &&
            snapshot.labelBaselines.all { it.isWellFormed() } &&
            snapshot.labelBaselines.map { it.identity }.distinct().size == snapshot.labelBaselines.size &&
            (snapshot.labelBaselines.isEmpty() || snapshot.labelKey != null)

    /** Shell-side ordering within one service instance; null means not synced. */
    fun syncDenial(current: SensitiveUiGuardSnapshot?, next: SensitiveUiGuardSnapshot): String? {
        if (!valid(next)) return "ui_guard_invalid"
        if (current == null) return null
        if (current.epoch != next.epoch) return "ui_guard_epoch"
        if (next.revision < current.revision) return "ui_guard_stale"
        if (next.revision == current.revision && next != current) return "ui_guard_conflict"
        if (current.tickets.isNotEmpty() && next.tickets.isNotEmpty() &&
            (current.labelKey != next.labelKey || !current.labelBaselines.containsAll(next.labelBaselines))
        ) return "ui_guard_baseline_changed"
        return null
    }

    fun canReadSensitiveFields(synchronized: Boolean, tickets: List<SensitiveUiGuardTicket>): Boolean =
        synchronized && tickets.isEmpty()

    fun canCapture(synchronized: Boolean, tickets: List<SensitiveUiGuardTicket>): Boolean =
        synchronized && tickets.isEmpty()

    /** Decide before invoking any text/description/hint getter. */
    fun canReadNodeText(
        guarded: Boolean, platformSensitive: Boolean, editable: Boolean,
        clickable: Boolean, advertisesSetText: Boolean, knownButton: Boolean,
        safeButtonChild: Boolean = false,
    ): Boolean = !platformSensitive && (!guarded ||
        (!editable && (clickable || safeButtonChild) && !advertisesSetText && knownButton))
}
