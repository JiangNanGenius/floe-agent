// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

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
import com.floe.android.core.networkmonitor.NetworkMonitorSessionState
import java.util.Locale

internal object NetworkMonitorNotifications {
    const val CHANNEL_ID = "floe.network.monitoring.v1"
    const val NOTIFICATION_ID = 70_072

    fun ensureChannel(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                if (isChinese()) "网络监控" else "Network monitoring",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = if (isChinese()) "用户启动的限时网络测量" else "Bounded user-started network measurements"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            }
            manager.createNotificationChannel(channel)
        }
        return manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    fun starting(context: Context, sessionId: String): Notification = build(
        context = context,
        state = NetworkMonitorSessionState(sessionId = sessionId),
        starting = true,
    )

    fun update(context: Context, state: NetworkMonitorSessionState): Notification =
        build(context, state, starting = false)

    private fun build(context: Context, state: NetworkMonitorSessionState, starting: Boolean): Notification {
        val sessionId = requireNotNull(state.sessionId) { "a monitoring notification requires a stable session" }
        val copy = NetworkMonitorNotificationCopy.forState(state, isChinese(), starting)
        val stopIntent = Intent(context, NetworkMonitorService::class.java)
            .setAction(NetworkMonitorService.ACTION_STOP)
            .setData(Uri.parse("floe://network-monitor/stop/$sessionId"))
            .putExtra(NetworkMonitorService.EXTRA_SESSION_ID, sessionId)
        val stop = PendingIntent.getService(
            context,
            sessionId.hashCode(),
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(copy.title)
            .setContentText(copy.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(copy.text))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(0, copy.stop, stop)
            .setPublicVersion(
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle(copy.title)
                    .setContentText(if (isChinese()) "限时测量正在进行" else "Bounded measurement in progress")
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .build(),
            )
        if (!starting && state.startedAtEpochMillis > 0) {
            builder.setWhen(state.startedAtEpochMillis).setUsesChronometer(true)
        }
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    sessionId.hashCode(),
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun isChinese(): Boolean = Locale.getDefault().language.startsWith("zh", ignoreCase = true)
}

/** Pure notification projection: no target, SSID, address, owner or raw result is included. */
internal object NetworkMonitorNotificationCopy {
    data class Copy(val title: String, val text: String, val stop: String)

    fun forState(state: NetworkMonitorSessionState, chinese: Boolean, starting: Boolean = false): Copy {
        val observation = state.lastObservation
        return forResult(
            chinese = chinese,
            starting = starting || observation == null,
            status = observation?.status,
            available = observation?.actualNetwork?.booleans?.get("available"),
            count = state.observationCount,
        )
    }

    fun forResult(
        chinese: Boolean,
        starting: Boolean,
        status: String?,
        available: Boolean?,
        count: Long,
    ): Copy {
        val title = if (chinese) "网络监控" else "Network monitoring"
        val stop = if (chinese) "停止" else "Stop"
        if (starting) {
            return Copy(title, if (chinese) "正在开始限时测量" else "Starting bounded measurement", stop)
        }
        val latest = when {
            status == "permissionRequired" -> if (chinese) "需要权限" else "Permission required"
            status == "timeout" -> if (chinese) "最近测量超时" else "Latest measurement timed out"
            status != "ok" -> if (chinese) "最近测量失败" else "Latest measurement failed"
            available == true -> if (chinese) "最近测量：网络可用" else "Latest measurement: network available"
            available == false -> if (chinese) "最近测量：网络不可用" else "Latest measurement: network unavailable"
            else -> if (chinese) "最近测量已完成" else "Latest measurement completed"
        }
        val samples = if (chinese) "$count 次采样" else "$count ${if (count == 1L) "sample" else "samples"}"
        return Copy(title, "$latest · $samples", stop)
    }
}
