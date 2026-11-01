// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.floe.android.R

/**
 * FULL-only, bounded lifecycle owner for an inline notification pairing reply.
 *
 * The notification broadcast itself is held with goAsync only for a short
 * deadline below the platform broadcast window. The real wireless-debugging
 * handshake can take up to the root controller's 15 s pairing timeout, so this
 * user-initiated operation needs a real foreground owner while Floe is behind
 * Android Settings. The service:
 *  - starts only after the live host accepted a single-use notification token;
 *  - has no command surface, no Intent extras, no binder and no task state;
 *  - promotes a low-importance progress notification;
 *  - stops on host completion/failure/cancel/close and in all cases after a
 *    hard 60 s bound (no endless foreground service, no PiP, no keep-alive).
 */
class PairingForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val boundedStop = Runnable { stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        PairingNotificationAccess.ensureServiceChannel(this) ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = NotificationCompat.Builder(
            this, PairingNotificationPolicy.SERVICE_CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(
                getString(R.string.device_access_pairing_notification_title))
            .setContentText(getString(R.string.device_access_pairing_service_text))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    PairingNotificationPolicy.SERVICE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(
                    PairingNotificationPolicy.SERVICE_NOTIFICATION_ID,
                    notification,
                )
            }
            handler.removeCallbacks(boundedStop)
            handler.postDelayed(boundedStop, MAX_LIFETIME_MILLIS)
            START_NOT_STICKY
        } catch (_: Throwable) {
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(boundedStop)
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        super.onDestroy()
    }

    companion object {
        /** Hard upper bound; the host normally stops this much sooner. */
        const val MAX_LIFETIME_MILLIS = 60_000L

        /**
         * Returns false when the platform refuses a background FGS start. The
         * receiver's bounded goAsync deadline still covers the short attempt;
         * no forever service is fabricated as a fallback.
         */
        fun start(context: Context): Boolean = try {
            context.startForegroundService(
                Intent(context, PairingForegroundService::class.java))
            true
        } catch (_: Throwable) {
            false
        }

        fun stop(context: Context) {
            runCatching {
                context.stopService(
                    Intent(context, PairingForegroundService::class.java))
            }
        }
    }
}
