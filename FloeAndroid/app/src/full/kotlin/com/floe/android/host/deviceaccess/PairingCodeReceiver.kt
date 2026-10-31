// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import com.floe.android.R
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FULL-channel only. Explicit, non-exported receiver for the inline pairing
 * notification's RemoteInput reply.
 *
 * The notification's action PendingIntent is created by Floe with this exact
 * component and is mutable only because the platform must attach RemoteInput
 * results. No implicit intent is ever used, so another app cannot retarget it;
 * in addition the receiver checks the explicit component again and the host
 * checks a RAM-only single-use token before touching the root controller.
 *
 * The six-digit code is copied straight from the platform CharSequence into a
 * caller-owned CharArray and handed to the live [DeviceAccessHost] submission
 * path. It is never logged, persisted, put in a notification body or used as a
 * port/command override.
 *
 * Lifecycle: this receiver holds goAsync until the host reports settlement or
 * the explicit 8 s broadcast deadline. Because the real TLS pairing handshake
 * can outlive that window, the host starts the bounded
 * [PairingForegroundService] only after accepting this token. Returning from
 * onReceive alone is never treated as process-lifetime ownership.
 */
class PairingCodeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val component = intent.component
        if (!PairingNotificationPolicy.ownsReply(
                action = intent.action,
                componentClass = component?.className,
                componentPackage = component?.packageName,
                expectedClass = PairingCodeReceiver::class.java.name,
                expectedPackage = context.packageName,
            )
        ) {
            return
        }
        val results = try {
            RemoteInput.getResultsFromIntent(intent)
        } catch (_: Throwable) {
            null
        }
        val code = PairingNotificationPolicy.readCode(
            results?.getCharSequence(PairingNotificationPolicy.KEY_CODE),
        )
        // Hold this broadcast open until the host reports a bounded settlement
        // (success/failure/cancel/timeout) — or until the explicit goAsync
        // deadline. The real handshake may outlive this window, so the host
        // also owns a bounded user-initiated FGS; the receiver never claims
        // that returning from onReceive alone keeps the process alive.
        val pending = goAsync()
        val finished = AtomicBoolean(false)
        val handler = Handler(Looper.getMainLooper())
        val deadline = Runnable {
            if (finished.compareAndSet(false, true)) {
                code?.fill('\u0000')
                runCatching { results?.clear() }
                runCatching { pending.finish() }
            }
        }
        handler.postDelayed(deadline, GO_ASYNC_DEADLINE_MILLIS)
        val finishHandoff: () -> Unit = {
            if (finished.compareAndSet(false, true)) {
                handler.removeCallbacks(deadline)
                code?.fill('\u0000')
                runCatching { results?.clear() }
                runCatching { pending.finish() }
            }
        }
        val handled = try {
            PairingNotificationRelay.deliver(
                nonce = intent.getStringExtra(PairingNotificationPolicy.EXTRA_NONCE),
                epoch = intent.getLongExtra(
                    PairingNotificationPolicy.EXTRA_EPOCH, Long.MIN_VALUE),
                generation = intent.getLongExtra(
                    PairingNotificationPolicy.EXTRA_GENERATION, Long.MIN_VALUE),
                code = code,
                onFinished = finishHandoff,
            )
        } catch (_: Throwable) {
            false
        }
        if (!handled) {
            // No live host/session: the notification is stale after process
            // death or cancellation. Remove it; never revive an old action.
            finishHandoff()
            PairingNotificationRelay.cancelOwnedNotification(context)
        }
    }

    private companion object {
        /**
         * Stay below the platform broadcast deadline. The host's bounded FGS
         * owns the potentially longer 15 s TLS pairing handshake after this.
         */
        const val GO_ASYNC_DEADLINE_MILLIS = 8_000L
    }
}

/**
 * Process-local handoff from the manifest receiver to the Application-owned
 * [DeviceAccessHost]. This is deliberately not a credential/trust store: it
 * holds one live object reference and the token lives inside that host. The
 * callback is the receiver's bounded goAsync completion; the host invokes it
 * on success, failure, cancel, timeout or close.
 */
internal object PairingNotificationRelay {
    @Volatile
    private var host: DeviceAccessHost? = null

    fun attach(current: DeviceAccessHost) {
        host = current
    }

    fun detach(current: DeviceAccessHost) {
        if (host === current) host = null
    }

    fun deliver(
        nonce: String?,
        epoch: Long,
        generation: Long,
        code: CharArray?,
        onFinished: (() -> Unit)? = null,
    ): Boolean {
        val current = host ?: return false
        return current.onPairingNotificationReply(
            nonce, epoch, generation, code, onFinished)
    }

    fun cancelOwnedNotification(context: Context) {
        runCatching {
            NotificationManagerCompat.from(context)
                .cancel(PairingNotificationPolicy.NOTIFICATION_ID)
        }
    }
}

/**
 * Platform reads for the FULL inline pairing notification. Kept separate from
 * the pure policy so API 33+ permission/channel truth is explicit at both the
 * host (before posting) and the settings UI (before/when requesting access).
 */
internal object PairingNotificationAccess {

    fun availability(context: Context): PairingNotificationPolicy.Availability {
        val manager = context.getSystemService(NotificationManager::class.java)
        val notificationsEnabled = manager?.areNotificationsEnabled() == true
        val channelBlocked = manager
            ?.getNotificationChannel(PairingNotificationPolicy.CHANNEL_ID)
            ?.importance == NotificationManager.IMPORTANCE_NONE
        val permissionGranted = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        return PairingNotificationPolicy.availability(
            sdkInt = Build.VERSION.SDK_INT,
            permissionGranted = permissionGranted,
            notificationsEnabled = notificationsEnabled,
            channelBlocked = channelBlocked,
        )
    }

    /** True only when asking the platform API 33+ notification permission helps. */
    fun canRequestPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun ensureChannel(context: Context): NotificationManager? {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return null
        if (manager.getNotificationChannel(PairingNotificationPolicy.CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    PairingNotificationPolicy.CHANNEL_ID,
                    context.getString(R.string.device_access_pairing_notification_channel),
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
        return manager
    }

    fun ensureServiceChannel(context: Context): NotificationManager? {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return null
        if (manager.getNotificationChannel(PairingNotificationPolicy.SERVICE_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    PairingNotificationPolicy.SERVICE_CHANNEL_ID,
                    context.getString(R.string.device_access_pairing_service_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        return manager
    }

    /** Existing notification settings for this app, with a safe fallback. */
    fun openSettings(context: Context): Boolean {
        val notification = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (start(context, notification)) return true
        val details = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return start(context, details)
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: Throwable) {
        false
    }
}
