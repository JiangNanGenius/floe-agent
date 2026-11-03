// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.floe.android.core.workbenchmedia.export.MediaExportReturns
import com.floe.android.core.workbenchmedia.export.ExportJob
import com.floe.android.core.workbenchmedia.R
import com.floe.android.core.workbenchmedia.export.ExportRuntimeHolder
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.WorkbenchR2Errors
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Service-owned media export. It becomes foreground only while a user-started
 * export is actually queued/running/verifying, shows normal progress and a
 * cancel action, and stops itself once the last owned job is terminal. It
 * does not auto-restore, does not use PiP, does not request an unlimited
 * notification keepalive, and does not start at boot.
 *
 * The service is deliberately thin: the bounded export state machine lives in
 * the module's runtime/engine; this class owns the Android foreground lifetime
 * and the Android 15+/API 35 timeout/denial contract.
 */
class MediaExportService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val handler = Handler(Looper.getMainLooper())
    private val active = ConcurrentHashMap.newKeySet<String>()
    private var foregroundStarted = false
    private var latest: MediaExportStatus? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        ExportRuntimeHolder.current()?.setServiceListener { status ->
            handler.post { onStatus(status) }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val runtime = ExportRuntimeHolder.current()
        if (runtime == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val jobID = intent?.getStringExtra(EXTRA_JOB_ID)
        if (jobID == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent.action == ACTION_CANCEL) {
            runtime.requestCancel(jobID)
            if (active.isEmpty() && !foregroundStarted) stopSelf(startId)
            return START_NOT_STICKY
        }
        val job = runtime.job(jobID)
        if (job == null || job.terminal) {
            if (active.isEmpty() && !foregroundStarted) stopSelf(startId)
            return START_NOT_STICKY
        }
        active += jobID
        latest = job.status
        if (!foregroundStarted && !promote(job)) {
            for (owned in active.toList()) {
                runtime.failStart(
                    owned,
                    "foregroundStartDenied",
                    "The media export foreground service could not start; run the export from the foreground",
                )
            }
            active.clear()
            stopSelf(startId)
            return START_NOT_STICKY
        }
        runtime.execute(jobID, scope)
        refreshNotification()
        return START_NOT_STICKY
    }

    /**
     * Android 15+ budget exhaustion. The system requires a prompt stopSelf;
     * the journal and status are settled as TIMEOUT without inventing a
     * completed receipt. Any still-running encoder is cancelled by the runtime
     * control and the engine deletes its own unfinished staging file only after
     * its writer returns. The runtime also keeps the native lifecycle pin
     * owned until that actual worker finally runs; publishing TIMEOUT here is
     * deliberately not treated as proof that the codec/file IO stopped.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        val runtime = ExportRuntimeHolder.current()
        runtime?.timeoutAll()
        runtime?.queuedOrRunning()?.forEach { job ->
            runtime.finish(
                job,
                MediaExportState.TIMEOUT,
                errorCode = WorkbenchR2Errors.RENDER_TIMEOUT,
                retryable = true,
            )
        }
        scope.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        val runtime = ExportRuntimeHolder.current()
        runtime?.setServiceListener(null)
        runtime?.markServiceDestroyed()
        scope.cancel()
        foregroundStarted = false
        super.onDestroy()
    }

    private fun onStatus(status: MediaExportStatus) {
        latest = status
        if (terminal(status.state)) {
            active -= status.jobID
            val next = active.firstOrNull()?.let { ExportRuntimeHolder.current()?.job(it)?.status }
            if (next != null) latest = next
        }
        if (active.isEmpty() && foregroundStarted) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            foregroundStarted = false
            return
        }
        refreshNotification()
    }

    private fun promote(job: ExportJob): Boolean {
        val notification = try {
            buildNotification(job.status)
        } catch (_: Exception) {
            return false
        }
        return try {
            when {
                Build.VERSION.SDK_INT >= 35 -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING,
                )
                Build.VERSION.SDK_INT >= 29 -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                else -> startForeground(NOTIFICATION_ID, notification)
            }
            foregroundStarted = true
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun refreshNotification() {
        if (!foregroundStarted) return
        val status = latest ?: return
        val notification = runCatching { buildNotification(status) }.getOrNull() ?: return
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(status: MediaExportStatus): Notification {
        val progress = status.progress?.coerceIn(0.0, 1.0)
        val text = buildString {
            append(stateLabel(status.state))
            if (progress != null) {
                append(" · ")
                append((progress * 100).toInt())
                append('%')
            }
        }
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_sys_download)
            .setContentTitle(getString(R.string.media_export_title))
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(!terminal(status.state))
            .setAutoCancel(false)
            .setContentIntent(returnIntent(status.jobID))
        if (progress != null) {
            builder.setProgress(1000, (progress * 1000).toInt(), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        val cancel = PendingIntent.getService(
            this,
            status.jobID.hashCode(),
            Intent(this, MediaExportService::class.java)
                .setAction(ACTION_CANCEL)
                .putExtra(EXTRA_JOB_ID, status.jobID),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        builder.addAction(
            Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                getString(R.string.media_export_cancel),
                cancel,
            ).build(),
        )
        return builder.build()
    }

    private fun returnIntent(jobID: String): PendingIntent? {
        val job = ExportRuntimeHolder.current()?.job(jobID) ?: return null
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.action = MediaExportReturns.ACTION
        launch.data = android.net.Uri.parse("floe-notification://media/" + job.returnToken)
        launch.putExtra(MediaExportReturns.EXTRA_TOKEN, job.returnToken)
        launch.putExtra(MediaExportReturns.EXTRA_REQUEST_ID, java.util.UUID.randomUUID().toString())
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT,
        )
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.media_export_channel_name), NotificationManager.IMPORTANCE_LOW).apply {
                description = getString(R.string.media_export_channel_description)
                setShowBadge(false)
            },
        )
    }

    private fun stateLabel(state: MediaExportState): String = getString(
        when (state) {
            MediaExportState.QUEUED -> R.string.media_export_state_queued
            MediaExportState.RUNNING -> R.string.media_export_state_running
            MediaExportState.VERIFYING -> R.string.media_export_state_verifying
            MediaExportState.COMPLETED -> R.string.media_export_state_completed
            MediaExportState.CANCELLED -> R.string.media_export_state_cancelled
            MediaExportState.FAILED -> R.string.media_export_state_failed
            MediaExportState.INTERRUPTED -> R.string.media_export_state_interrupted
            MediaExportState.TIMEOUT -> R.string.media_export_state_timeout
        },
    )

    private fun terminal(state: MediaExportState): Boolean =
        state == MediaExportState.COMPLETED || state == MediaExportState.CANCELLED ||
            state == MediaExportState.FAILED || state == MediaExportState.TIMEOUT ||
            state == MediaExportState.INTERRUPTED

    companion object {
        private const val CHANNEL_ID = "floe_media_exports"
        private const val NOTIFICATION_ID = 0x4D45
        const val ACTION_CANCEL = "com.floe.android.core.workbenchmedia.CANCEL_EXPORT"
        const val EXTRA_JOB_ID = "floe.workbenchmedia.export.jobID"

        /**
         * Starts the service only for an already-registered owned export. The
         * caller (platform submit from a user interaction) catches the
         * background-start denial and marks the job actionably failed.
         */
        fun start(context: Context, jobID: String): Boolean = try {
            context.startForegroundService(
                Intent(context, MediaExportService::class.java)
                    .setAction("com.floe.android.core.workbenchmedia.START_EXPORT")
                    .putExtra(EXTRA_JOB_ID, jobID),
            )
            true
        } catch (_: Exception) {
            false
        }

        fun cancel(context: Context, jobID: String) {
            runCatching {
                context.startService(
                    Intent(context, MediaExportService::class.java)
                        .setAction(ACTION_CANCEL)
                        .putExtra(EXTRA_JOB_ID, jobID),
                )
            }
        }
    }
}
