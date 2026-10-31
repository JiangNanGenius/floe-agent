// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.floe.android.MainActivity
import com.floe.android.R

/**
 * Actionable platform notices for scheduled tasks. A missing exact-alarm
 * grant or a blocked background start is a VISIBLE waiting state with a real
 * action — never a success claim and never a fake completion notification.
 */
internal object TaskScheduleNotifications {
    private const val CHANNEL_ID = "floe.scheduled_tasks"
    private const val EXTRA_SCHEDULE_ID = "floe.schedule.extra.scheduleID"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.schedule_notification_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.schedule_notification_channel_description)
                setShowBadge(true)
            },
        )
    }

    fun postWaitingForExactPermission(
        context: Context,
        scheduleID: String,
        scheduleTitle: String,
    ) {
        ensureChannel(context)
        if (!TaskScheduleAlarmScheduler.notificationsUsable(context)) return
        val flexible = Intent(context, TaskScheduleWakeReceiver::class.java)
            .setAction(TaskScheduleWakeReceiver.ACTION_USE_FLEXIBLE)
            .putExtra(EXTRA_SCHEDULE_ID, scheduleID)
        val flexiblePending = PendingIntent.getBroadcast(
            context,
            scheduleID.hashCode(),
            flexible,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val settingsIntent = if (Build.VERSION.SDK_INT >= 31) {
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                .setData(Uri.parse("package:${context.packageName}"))
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${context.packageName}"))
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val settingsPending = PendingIntent.getActivity(
            context,
            (scheduleID.hashCode() xor 0x51F15E),
            settingsIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(context.getString(R.string.schedule_waiting_exact_title))
            .setContentText(context.getString(
                R.string.schedule_waiting_exact_body,
                scheduleTitle.ifBlank { context.getString(R.string.schedule_generic_task) }.take(80)))
            .setStyle(NotificationCompat.BigTextStyle().bigText(
                context.getString(
                    R.string.schedule_waiting_exact_body,
                    scheduleTitle.ifBlank { context.getString(R.string.schedule_generic_task) }.take(80))))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context, scheduleID))
            .addAction(0, context.getString(R.string.schedule_action_allow_exact), settingsPending)
            .addAction(0, context.getString(R.string.schedule_action_use_flexible), flexiblePending)
            .build()
        notify(context, scheduleID, notification)
    }

    fun postTransportPending(
        context: Context,
        scheduleID: String,
        scheduleTitle: String,
    ) {
        ensureChannel(context)
        if (!TaskScheduleAlarmScheduler.notificationsUsable(context)) return
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(context.getString(R.string.schedule_pending_title))
            .setContentText(context.getString(
                R.string.schedule_pending_body,
                scheduleTitle.ifBlank { context.getString(R.string.schedule_generic_task) }.take(80)))
            .setStyle(NotificationCompat.BigTextStyle().bigText(
                context.getString(
                    R.string.schedule_pending_body,
                    scheduleTitle.ifBlank { context.getString(R.string.schedule_generic_task) }.take(80))))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context, scheduleID))
            .build()
        notify(context, scheduleID, notification)
    }

    fun cancel(context: Context, scheduleID: String) {
        if (!TaskScheduleAlarmScheduler.notificationsUsable(context)) return
        NotificationManagerCompat.from(context).cancel(notificationID(scheduleID))
    }

    private fun openAppIntent(context: Context, scheduleID: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_SCHEDULE_ID, scheduleID)
        return PendingIntent.getActivity(
            context,
            scheduleID.hashCode() xor 0x2A7C,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notify(context: Context, scheduleID: String, notification: android.app.Notification) {
        try {
            NotificationManagerCompat.from(context).notify(notificationID(scheduleID), notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS denied after the check: the in-app status
            // remains the visible truth and nothing is claimed.
        }
    }

    private fun notificationID(scheduleID: String): Int = scheduleID.hashCode() and 0x7FFFFFFF
}
