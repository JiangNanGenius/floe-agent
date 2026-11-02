// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Bounded cloud-generation `dataSync` owner, non-exported and App-owned.
 *
 * It is started ONLY by [GenerationForegroundOwner.acquire] for an already
 * persisted native job; the Intent carries an opaque claim token and nothing
 * else. `onStartCommand` looks the claim up in the in-process owner; an
 * unknown/replayed token never starts work and never disturbs another claim.
 *
 * The service calls `startForeground` with `dataSync` and confirms the owner
 * only after the framework accepted it. If the start is refused, the owner
 * reports a definite denial to native and no paid provider request is
 * dispatched. The pump reads the exact durable native job state, updates the
 * notification, and stops on terminal/timeout/unknown. It never keeps an idle
 * service, never uses Picture-in-Picture and never restarts after task death.
 */
class GenerationForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var pumpJob: Job? = null
    private var destroying = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (!GenerationForegroundOwner.isInitialized) {
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (destroying) return START_NOT_STICKY
        when (intent?.action) {
            GenerationForegroundOwner.ACTION_START -> handleStart(intent)
            else -> stopIfIdle()
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        val token = intent.getStringExtra(GenerationForegroundOwner.EXTRA_TOKEN)
        val claim = token?.let { GenerationForegroundOwner.claimForStart(it) }
        if (token == null || claim == null) {
            stopIfIdle()
            return
        }
        if (GenerationForegroundOwner.activeCount() == 0) {
            stopIfIdle()
            return
        }
        val notification = GenerationForegroundOwner.buildNotification(this)
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                if (Build.VERSION.SDK_INT >= 29) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else {
                    0
                })
        } catch (_: SecurityException) {
            GenerationForegroundOwner.failStart(token, "startDenied")
            stopSelf()
            return
        } catch (_: IllegalStateException) {
            GenerationForegroundOwner.failStart(token, "startDenied")
            stopSelf()
            return
        } catch (_: RuntimeException) {
            GenerationForegroundOwner.failStart(token, "startDenied")
            stopSelf()
            return
        }
        GenerationForegroundOwner.confirmStart(token)
        GenerationForegroundOwner.updateNotification(this)
        startPump()
    }

    private fun startPump() {
        if (pumpJob?.isActive == true) return
        pumpJob = scope.launch {
            while (isActive) {
                delay(PUMP_INTERVAL_MILLIS)
                val active = GenerationForegroundOwner.pump()
                if (!active) {
                    stopSelf()
                    break
                }
                // The owner renders the current notification from the same
                // native snapshot; this call also reasserts the FGS entry if
                // the system dropped an update while Doze was active.
                GenerationForegroundOwner.updateNotification(this@GenerationForegroundService)
            }
        }
    }

    private fun stopIfIdle() {
        if (GenerationForegroundOwner.activeCount() == 0) {
            stopSelf()
        } else {
            GenerationForegroundOwner.updateNotification(this)
        }
    }

    /**
     * API 35+ bounded dataSync timeout. The app-wide dataSync allowance is
     * shared; this owner never assumes a fresh allowance or retries after the
     * system timeout. The exact native jobs are cancelled/released as
     * interrupted/unknown (never a blind paid resubmission).
     */
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        GenerationForegroundOwner.onSystemTimeout()
        stopSelf()
    }

    override fun onDestroy() {
        destroying = true
        pumpJob?.cancel()
        pumpJob = null
        GenerationForegroundOwner.onServiceDestroyed()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_ID = 0x46474E31
        private const val PUMP_INTERVAL_MILLIS = 2_000L
    }
}

/**
 * Notification Cancel action only. It is non-exported (same-app PendingIntent
 * only); it cancels the exact live claims through the native lease proof and
 * never accepts an arbitrary job id/root from the Intent.
 */
class GenerationForegroundCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != GenerationForegroundOwner.ACTION_CANCEL_ALL) return
        val tokens = intent.getStringArrayListExtra(GenerationForegroundOwner.EXTRA_CANCEL_TOKENS) ?: return
        GenerationForegroundOwner.cancelCaptured(tokens)
    }
}
