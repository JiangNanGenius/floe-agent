// SPDX-License-Identifier: MPL-2.0
//
// Owned local todo reminders. One todo owns exactly one PendingIntent and one
// notification id. The alarm carries only an opaque todo id and its occurrence
// key; the title/body are read from the live original store only when the
// reminder is actually due. Update/complete/delete cancels the same identity.
//
// Exact time uses setExactAndAllowWhileIdle only when the user granted the
// Alarms & reminders special access. Otherwise the reminder is armed through
// setAndAllowWhileIdle and the UI reports the honest "may be delayed" state.
// A missing POST_NOTIFICATIONS grant disables arming and is visible in the UI;
// the todo itself is still saved.

package com.floe.android.host.calendar

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import com.floe.android.MainActivity
import com.floe.android.feature.calendar.R
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal enum class TodoReminderWakeMode {
    EXACT,
    INEXACT,
    NOTIFICATIONS_BLOCKED,
    INVALID,
}

internal data class TodoReminderDecision(
    val mode: TodoReminderWakeMode,
    val triggerAtMillis: Long,
    val reason: String?,
)

internal object TodoReminderPolicy {
    fun decide(
        notificationsEnabled: Boolean,
        exactAlarmAllowed: Boolean,
        reminderAtMillis: Long,
        dueAtMillis: Long,
        nowMillis: Long,
    ): TodoReminderDecision {
        if (!notificationsEnabled) {
            return TodoReminderDecision(
                TodoReminderWakeMode.NOTIFICATIONS_BLOCKED, 0L, "notificationsDisabled",
            )
        }
        if (reminderAtMillis <= 0L || dueAtMillis <= 0L) {
            return TodoReminderDecision(TodoReminderWakeMode.INVALID, 0L, "invalidReminderPlan")
        }
        val trigger = maxOf(reminderAtMillis, nowMillis + 1_000L)
        return if (exactAlarmAllowed) {
            TodoReminderDecision(TodoReminderWakeMode.EXACT, trigger, null)
        } else {
            TodoReminderDecision(
                TodoReminderWakeMode.INEXACT,
                trigger,
                "exactAlarmPermissionMissing",
            )
        }
    }
}

internal data class TodoReminderPlanUi(
    val todoID: String,
    val reminderAtMillis: Long,
    val dueAtMillis: Long,
    val occurrenceKey: String,
    val allDay: Boolean,
    val timeZone: String,
)

internal class TodoReminderScheduler(private val context: Context) {
    private val appContext = context.applicationContext
    private val alarmManager = appContext.getSystemService(AlarmManager::class.java)
    private val preferences = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun notificationsUsable(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(appContext).areNotificationsEnabled()
    }

    fun exactAlarmAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return alarmManager?.canScheduleExactAlarms() == true
    }

    fun arm(
        todoID: String,
        reminderAtMillis: Long,
        dueAtMillis: Long,
        occurrenceKey: String,
        allDay: Boolean,
        timeZone: String,
    ): TodoReminderArmUi {
        if (todoID.isEmpty() || occurrenceKey.isEmpty()) {
            return TodoReminderArmUi(false, "armFailed", "invalidReminderPlan")
        }
        val decision = TodoReminderPolicy.decide(
            notificationsEnabled = notificationsUsable(),
            exactAlarmAllowed = exactAlarmAllowed(),
            reminderAtMillis = reminderAtMillis,
            dueAtMillis = dueAtMillis,
            nowMillis = System.currentTimeMillis(),
        )
        when (decision.mode) {
            TodoReminderWakeMode.NOTIFICATIONS_BLOCKED ->
                return TodoReminderArmUi(false, "notificationsBlocked", decision.reason)
            TodoReminderWakeMode.INVALID ->
                return TodoReminderArmUi(false, "armFailed", decision.reason)
            else -> Unit
        }
        val trigger = decision.triggerAtMillis
        NotificationManagerCompat.from(appContext).cancel(notificationID(todoID))
        val pending = pendingIntent(
            todoID = todoID,
            occurrenceKey = occurrenceKey,
            dueAtMillis = dueAtMillis,
            allDay = allDay,
            timeZone = timeZone,
        )
        val manager = alarmManager
            ?: return TodoReminderArmUi(false, "armFailed", "alarmServiceUnavailable")
        if (decision.mode == TodoReminderWakeMode.EXACT) {
            try {
                manager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    trigger,
                    pending,
                )
                return TodoReminderArmUi(true, "scheduled", null)
            } catch (_: SecurityException) {
                // The grant was revoked between the capability read and the
                // call. Do not claim exact; fall through to the honest
                // inexact path (still bounded by the same PendingIntent).
            }
        }
        return try {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending)
            TodoReminderArmUi(
                true,
                "inexact",
                decision.reason,
            )
        } catch (_: SecurityException) {
            manager.cancel(pending)
            TodoReminderArmUi(false, "armFailed", "alarmPermissionDenied")
        }
    }

    fun cancel(todoID: String) {
        if (todoID.isEmpty()) return
        pendingIntent(
            todoID = todoID,
            occurrenceKey = "",
            dueAtMillis = 0L,
            allDay = false,
            timeZone = "UTC",
        ).let { alarmManager?.cancel(it) }
        WorkManager.getInstance(appContext).cancelUniqueWork(deliveryWorkName(todoID))
        NotificationManagerCompat.from(appContext).cancel(notificationID(todoID))
    }

    /** Boot/package/timezone/time-change/initial recovery. Plans are bounded
     *  by the original store; only ids are remembered here. */
    fun applyPlans(plans: List<TodoReminderPlanUi>) {
        val planned = plans.associateBy { it.todoID }
        val known = preferences.getStringSet(KEY_ARMED, emptySet()) ?: emptySet()
        (known - planned.keys).forEach { stale ->
            cancel(stale)
        }
        plans.forEach { plan ->
            arm(
                todoID = plan.todoID,
                reminderAtMillis = plan.reminderAtMillis,
                dueAtMillis = plan.dueAtMillis,
                occurrenceKey = plan.occurrenceKey,
                allDay = plan.allDay,
                timeZone = plan.timeZone,
            )
        }
        preferences.edit().putStringSet(KEY_ARMED, planned.keys).apply()
    }

    fun postNotification(
        todoID: String,
        revision: Int,
        title: String,
        dueAtMillis: Long,
        allDay: Boolean,
        timeZone: String,
    ): Boolean {
        if (!notificationsUsable()) return false
        ensureChannel()
        val due = formatDue(dueAtMillis, allDay, timeZone)
        val content = Intent(appContext, MainActivity::class.java)
            .setAction(C06CalendarNavigation.ACTION_OPEN_TODO)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(C06CalendarNavigation.EXTRA_TODO_ID, todoID)
            .putExtra(C06CalendarNavigation.EXTRA_TODO_REVISION, revision)
        val contentPending = PendingIntent.getActivity(
            appContext,
            requestCode(todoID) xor 0x2C0FFEE,
            content,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val body = appContext.getString(R.string.calendar_todo_reminder_body, title, due)
        val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(appContext.getString(R.string.calendar_todo_reminder_title))
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setLocalOnly(true)
            .setAutoCancel(true)
            .setContentIntent(contentPending)
            .build()
        return try {
            NotificationManagerCompat.from(appContext).notify(notificationID(todoID), notification)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                appContext.getString(R.string.calendar_todo_channel),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = appContext.getString(R.string.calendar_todo_channel_description)
                setShowBadge(true)
            },
        )
    }

    private fun pendingIntent(
        todoID: String,
        occurrenceKey: String,
        dueAtMillis: Long,
        allDay: Boolean,
        timeZone: String,
    ): PendingIntent {
        val intent = Intent(appContext, TodoReminderReceiver::class.java)
            .setAction(TodoReminderReceiver.ACTION_REMIND)
            .setData(Uri.parse("floe://todo/reminder/$todoID"))
            .putExtra(TodoReminderReceiver.EXTRA_TODO_ID, todoID)
            .putExtra(TodoReminderReceiver.EXTRA_OCCURRENCE, occurrenceKey)
            .putExtra(TodoReminderReceiver.EXTRA_DUE_AT, dueAtMillis)
            .putExtra(TodoReminderReceiver.EXTRA_ALL_DAY, allDay)
            .putExtra(TodoReminderReceiver.EXTRA_TIME_ZONE, timeZone)
        return PendingIntent.getBroadcast(
            appContext,
            requestCode(todoID),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun formatDue(dueAtMillis: Long, allDay: Boolean, timeZone: String): String {
        val zone = runCatching { ZoneId.of(timeZone) }.getOrElse { ZoneId.systemDefault() }
        val instant = Instant.ofEpochMilli(dueAtMillis)
        return if (allDay) {
            DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.getDefault())
                .withZone(ZoneId.of("UTC"))
                .format(instant.atZone(ZoneId.of("UTC")).toLocalDate()
                    .atStartOfDay(zone).toLocalDate())
        } else {
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.getDefault())
                .withZone(zone)
                .format(instant)
        }
    }

    private fun deliveryWorkName(todoID: String): String = "floe.todo.reminder.deliver.$todoID"

    companion object {
        private const val PREFS = "floe.calendar.reminders"
        private const val KEY_ARMED = "armedTodoIDs"
        private const val CHANNEL_ID = "floe.todo_reminders"

        fun exactAlarmSettingsIntent(context: Context): Intent =
            if (Build.VERSION.SDK_INT >= 31) {
                Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            } else {
                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

        fun notificationSettingsIntent(context: Context): Intent =
            Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        fun notificationID(todoID: String): Int = stableRequestCode("notification:$todoID")

        fun requestCode(todoID: String): Int = stableRequestCode("alarm:$todoID")

        private fun stableRequestCode(raw: String): Int {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(raw.toByteArray(Charsets.UTF_8))
            var value = 0
            for (index in 0 until 4) {
                value = (value shl 8) or (digest[index].toInt() and 0xFF)
            }
            return value and 0x7FFFFFFF
        }
    }
}
