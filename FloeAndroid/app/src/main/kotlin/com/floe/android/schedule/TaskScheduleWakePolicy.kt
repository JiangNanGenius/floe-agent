// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

/**
 * Pure OS-wake decision. The schedule's next fire time comes from the native
 * planner; this policy only maps it to the platform mechanism:
 *
 *  * exact wall-clock time is the DEFAULT when the user granted
 *    `SCHEDULE_EXACT_ALARM`;
 *  * if the grant is missing, NOTHING is armed and the UI shows a visible
 *    waiting-permission state;
 *  * only an explicit per-schedule user choice switches that schedule to a
 *    flexible WorkManager wake (which may run late).
 *
 * There is deliberately no silent fallback, no USE_EXACT_ALARM and no
 * polling keepalive.
 */
internal enum class TaskScheduleWakeMode { EXACT, FLEXIBLE }

internal sealed interface TaskScheduleWakeDecision {
    data class Arm(val mode: TaskScheduleWakeMode, val triggerAtMillis: Long) :
        TaskScheduleWakeDecision
    data object WaitingPermission : TaskScheduleWakeDecision
    data object Cancel : TaskScheduleWakeDecision
}

internal object TaskScheduleWakePolicy {
    fun decide(
        enabled: Boolean,
        nextFireAtMillis: Long?,
        exactAlarmAllowed: Boolean,
        flexibleChosen: Boolean,
        nowMillis: Long = System.currentTimeMillis(),
    ): TaskScheduleWakeDecision {
        if (!enabled || nextFireAtMillis == null) return TaskScheduleWakeDecision.Cancel
        val trigger = if (nextFireAtMillis <= nowMillis) nowMillis else nextFireAtMillis
        if (exactAlarmAllowed) {
            return TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.EXACT, trigger)
        }
        if (flexibleChosen) {
            return TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.FLEXIBLE, trigger)
        }
        return TaskScheduleWakeDecision.WaitingPermission
    }
}

/** Bounded platform fact set used by the worker and the UI. */
data class TaskScheduleWakeFacts(
    val exactAlarmAllowed: Boolean,
    val notificationsUsable: Boolean,
    val flexibleChosen: (String) -> Boolean,
)
