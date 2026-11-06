// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

internal enum class ConditionObservation { DURABLE, QUEUE_FULL, STORAGE_UNAVAILABLE }

/** Transport policy only; the native occurrence ledger still admits every run. */
internal object TaskScheduleConditionPolicy {
    fun risingEdge(wasActive: Boolean, active: Boolean, elapsed: Long,
                   lastElapsed: Long?, sameBoot: Boolean): Boolean =
        active && !wasActive && (!sameBoot || lastElapsed == null || lastElapsed < 0 ||
            elapsed < lastElapsed || elapsed - lastElapsed >= 30_000)

    fun clockRejected(code: String, observedAt: Long, now: Long): Boolean =
        code == "cadenceInvalid" && observedAt > now && observedAt - now > 60_000

    /** A full queue must be drained before the current edge can be recorded.
     * Failed durable writes or an uncertain native reply never acknowledge it. */
    suspend fun <T : Any> drain(
        observe: () -> ConditionObservation,
        peek: () -> T?,
        acknowledge: (T) -> Boolean,
        submit: suspend (T) -> Boolean,
    ): Boolean {
        var observation = observe()
        if (observation == ConditionObservation.STORAGE_UNAVAILABLE) return false
        while (true) {
            val event = peek() ?: return observation == ConditionObservation.DURABLE
            if (!submit(event) || !acknowledge(event)) return false
            if (observation == ConditionObservation.QUEUE_FULL) {
                observation = observe()
                if (observation == ConditionObservation.STORAGE_UNAVAILABLE) return false
            }
        }
    }
}
