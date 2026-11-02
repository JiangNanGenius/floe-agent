// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.Manifest
import android.app.Notification
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
import androidx.core.content.ContextCompat
import com.floe.android.MainActivity
import com.floe.android.core.networkcapture.CapturePhase
import com.floe.android.core.networkcapture.CaptureState
import java.util.Locale

object CaptureNotifications {
    const val CHANNEL_ID = "floe.packet.capture.v1"
    const val NOTIFICATION_ID = 70_073

    fun ensureChannel(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    if (isChinese()) "网络抓包" else "Packet capture",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = if (isChinese()) {
                        "用户启动的本地抓包与转发"
                    } else {
                        "User-started local packet capture and forwarding"
                    }
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            )
        }
        return manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    fun isAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    fun build(
        context: Context,
        state: CaptureState,
        serviceClass: Class<*>,
        stopAction: String,
        sessionExtra: String,
        starting: Boolean = false,
    ): Notification {
        val sessionId = state.sessionId ?: "pending"
        val chinese = isChinese()
        val title = if (chinese) "网络抓包" else "Packet capture"
        val text = when {
            starting -> if (chinese) "正在建立本地 VPN…" else "Starting local VPN…"
            state.phase == CapturePhase.STOPPING -> if (chinese) "正在停止并保存…" else "Stopping and saving…"
            state.phase == CapturePhase.FINALIZING -> if (chinese) "正在分析抓包…" else "Analyzing capture…"
            state.phase == CapturePhase.RUNNING -> {
                val prefix = if (chinese) "抓包中" else "Capturing"
                "$prefix · ${state.stats.capturedPackets} ${if (chinese) "包" else "packets"} · " +
                    formatBytes(state.stats.capturedBytes) +
                    (if (state.stats.droppedPackets > 0) {
                        " · ${state.stats.droppedPackets} ${if (chinese) "丢弃" else "dropped"}"
                    } else "")
            }
            else -> if (chinese) "抓包已停止" else "Capture stopped"
        }
        val stop = Intent(context, serviceClass)
            .setAction(stopAction)
            .setData(Uri.parse("floe://packet-capture/stop/$sessionId"))
            .putExtra(sessionExtra, sessionId)
        val stopPending = PendingIntent.getService(
            context,
            sessionId.hashCode(),
            stop,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val open = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(PacketCaptureIntents.EXTRA_DESTINATION, PacketCaptureIntents.DESTINATION_NETWORK_CAPTURE)
        val openPending = PendingIntent.getActivity(
            context,
            sessionId.hashCode() xor 0x5A5A,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
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
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPending)
            .setPublicVersion(
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle(title)
                    .setContentText(if (chinese) "本地抓包正在进行" else "Local capture in progress")
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .build(),
            )
        if (state.phase == CapturePhase.RUNNING || state.phase == CapturePhase.STOPPING) {
            builder.addAction(0, if (chinese) "停止" else "Stop", stopPending)
        }
        if (state.phase == CapturePhase.RUNNING && state.startedAtMillis != null) {
            builder.setWhen(requireNotNull(state.startedAtMillis)).setUsesChronometer(true)
        }
        return builder.build()
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format(Locale.ROOT, "%.1f KiB", kb)
        return String.format(Locale.ROOT, "%.1f MiB", kb / 1024.0)
    }

    private fun isChinese(): Boolean = Locale.getDefault().language.startsWith("zh", ignoreCase = true)
}
