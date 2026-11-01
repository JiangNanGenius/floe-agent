// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

/**
 * Bounded admission for the process export registry.
 *
 * `live` counts every accepted export whose actual worker has not stopped
 * (queued, running, verifying, or terminal-but-still-draining). The two
 * encoder permits are not an admission bound: without this, a caller could
 * queue any number of accepted jobs and retain every listener/status record.
 *
 * A reservation is taken before the native pin/snapshot/read work; it becomes
 * a live job only after the job is actually inserted, and is cancelled on a
 * failed acceptance. A job releases its live slot exactly once when its
 * worker/queued terminal path is actually drained.
 */
internal class ExportAdmission(
    private val maxLive: Int = ExportRuntimeLimits.MAX_LIVE_JOBS,
    private val maxRetainedTerminal: Int = ExportRuntimeLimits.MAX_RETAINED_TERMINAL_JOBS,
) {
    private var live = 0
    private var reserved = 0

    @Synchronized
    fun reserve(): Boolean {
        if (live + reserved >= maxLive) return false
        reserved += 1
        return true
    }

    @Synchronized
    fun commitReservation() {
        if (reserved <= 0) return
        reserved -= 1
        live += 1
    }

    @Synchronized
    fun cancelReservation() {
        if (reserved > 0) reserved -= 1
    }

    @Synchronized
    fun releaseLive() {
        if (live > 0) live -= 1
    }

    @Synchronized
    fun liveCount(): Int = live

    @Synchronized
    fun reservedCount(): Int = reserved

    /** Number of oldest terminal+drained entries to prune beyond the retention cap. */
    fun terminalExcess(terminalDrainedCount: Int): Int =
        (terminalDrainedCount - maxRetainedTerminal).coerceAtLeast(0)

    val liveLimit: Int get() = maxLive
}

internal object ExportRuntimeLimits {
    /** Accepted jobs that have not actually drained; two of them run at once. */
    const val MAX_LIVE_JOBS = 8

    /** Terminal jobs retained in memory for immediate status/observe. */
    const val MAX_RETAINED_TERMINAL_JOBS = 16
}
