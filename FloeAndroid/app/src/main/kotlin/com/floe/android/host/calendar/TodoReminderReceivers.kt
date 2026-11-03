// SPDX-License-Identifier: MPL-2.0
//
// Broadcast-only reminder transport. The alarm/boot receiver starts NO
// foreground service and NO Agent run. It enqueues one bounded WorkManager
// job; the job asks the real accepted runtime for the exact todo occurrence
// and updates notification state only through the original store.

package com.floe.android.host.calendar

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class TodoReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REMIND) return
        val todoID = intent.getStringExtra(EXTRA_TODO_ID) ?: return
        val occurrence = intent.getStringExtra(EXTRA_OCCURRENCE) ?: return
        TodoReminderDeliverWorker.enqueue(context.applicationContext, todoID, occurrence)
    }

    companion object {
        const val ACTION_REMIND = "com.floe.android.calendar.TODO_REMIND"
        const val EXTRA_TODO_ID = "floe.todo.extra.todoID"
        const val EXTRA_OCCURRENCE = "floe.todo.extra.occurrence"
        const val EXTRA_DUE_AT = "floe.todo.extra.dueAt"
        const val EXTRA_ALL_DAY = "floe.todo.extra.allDay"
        const val EXTRA_TIME_ZONE = "floe.todo.extra.timeZone"
    }
}

/**
 * Re-arm after boot, package replacement and clock/timezone changes. No todo
 * body, title or note is written to a boot-safe store: the worker asks the
 * live original store for bounded future plans after the credential-protected
 * database is available.
 */
class TodoReminderWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_REARM,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            ACTION_EXACT_ALARM_PERMISSION_CHANGED -> {
                TodoReminderRearmWorker.enqueue(context.applicationContext)
            }
        }
    }

    companion object {
        const val ACTION_REARM = "com.floe.android.calendar.REARM_TODO_REMINDERS"
        const val ACTION_EXACT_ALARM_PERMISSION_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
    }
}
