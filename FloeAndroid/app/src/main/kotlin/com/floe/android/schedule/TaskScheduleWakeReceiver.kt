// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Transport-only broadcast entry. It starts NO foreground service and NO
 * Agent run directly: an exact alarm or a boot/time change only enqueues the
 * bounded WorkManager job that performs the real dispatch/rearm when the
 * runtime is ready.
 */
class TaskScheduleWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        when (intent.action) {
            ACTION_DISPATCH -> {
                val scheduleID = intent.getStringExtra(EXTRA_SCHEDULE_ID) ?: return
                val trigger = intent.getStringExtra(EXTRA_TRIGGER)
                    ?: TaskScheduleDispatchWorker.TRIGGER_EXACT
                TaskScheduleDispatchWorker.enqueue(appContext, scheduleID, trigger)
            }
            ACTION_USE_FLEXIBLE -> {
                val scheduleID = intent.getStringExtra(EXTRA_SCHEDULE_ID) ?: return
                TaskScheduleChoiceStore(appContext).setFlexibleChosen(scheduleID, true)
                TaskScheduleNotifications.cancel(appContext, scheduleID)
                TaskScheduleRearmWorker.enqueue(appContext)
            }
            ACTION_REARM,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            ACTION_EXACT_ALARM_PERMISSION_CHANGED -> {
                // Re-arm from the durable native planner. A re-granted exact
                // permission also clears the waiting notice after the plans
                // are applied.
                TaskScheduleRearmWorker.enqueue(appContext)
            }
        }
    }

    companion object {
        const val ACTION_DISPATCH = "com.floe.android.schedule.DISPATCH"
        const val ACTION_REARM = "com.floe.android.schedule.REARM"
        const val ACTION_USE_FLEXIBLE = "com.floe.android.schedule.USE_FLEXIBLE"
        const val ACTION_EXACT_ALARM_PERMISSION_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
        const val EXTRA_SCHEDULE_ID = "floe.schedule.extra.scheduleID"
        const val EXTRA_TRIGGER = "floe.schedule.extra.trigger"
    }
}
