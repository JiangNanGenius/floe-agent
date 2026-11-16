// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.floe.android.R
import java.util.Locale

/** Ongoing microphone notification for the single recording service. */
internal object MeetingRecordingNotifications {
    const val CHANNEL_ID = "floe.meeting.recording.v1"
    const val NOTIFICATION_ID = 0x4D524331

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.meeting_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.meeting_channel_description)
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    fun build(
        context: Context,
        state: MeetingRecordingState,
    ): Notification {
        val title = context.getString(R.string.meeting_notification_title)
        val text = when (state.phase) {
            MeetingRecordingPhase.STARTING -> context.getString(R.string.meeting_notification_starting)
            MeetingRecordingPhase.PAUSED -> context.getString(
                R.string.meeting_notification_paused,
                formatElapsed(state.elapsedMillis),
            )
            MeetingRecordingPhase.STOPPING -> context.getString(R.string.meeting_notification_finishing)
            MeetingRecordingPhase.RECORDING -> context.getString(
                R.string.meeting_notification_recording,
                formatElapsed(state.elapsedMillis),
            )
            else -> context.getString(R.string.meeting_notification_finishing)
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        val recordingId = state.recordingId
        if (recordingId != null &&
            (state.phase == MeetingRecordingPhase.RECORDING || state.phase == MeetingRecordingPhase.PAUSED)
        ) {
            val stop = Intent(context, MeetingRecordingService::class.java)
                .setAction(MeetingRecordingService.ACTION_STOP)
                .setData(Uri.parse("floe://meeting-recording/stop/$recordingId"))
                .putExtra(MeetingRecordingService.EXTRA_MEETING_ID, state.meetingId)
                .putExtra(MeetingRecordingService.EXTRA_RECORDING_ID, recordingId)
            val stopPending = PendingIntent.getForegroundService(
                context,
                NOTIFICATION_ID,
                stop,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                0,
                context.getString(R.string.meeting_notification_stop),
                stopPending,
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val openPending = PendingIntent.getActivity(
                context,
                NOTIFICATION_ID xor 0x2B,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.setContentIntent(openPending)
        }
        return builder.build()
    }

    fun update(context: Context, state: MeetingRecordingState) {
        runCatching {
            NotificationManagerCompat.from(context)
                .notify(NOTIFICATION_ID, build(context, state))
        }
    }

    fun cancel(context: Context) {
        runCatching { NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID) }
    }

    private fun formatElapsed(millis: Long): String {
        val totalSeconds = (millis.coerceAtLeast(0L) / 1_000L)
        val seconds = totalSeconds % 60
        val minutes = (totalSeconds / 60) % 60
        val hours = totalSeconds / 3_600
        return if (hours > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format(Locale.ROOT, "%02d:%02d", minutes, seconds)
        }
    }
}
