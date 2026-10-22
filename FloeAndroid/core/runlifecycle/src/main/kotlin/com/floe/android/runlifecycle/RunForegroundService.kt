// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * The ONE Core specialUse foreground service for actually-owned Agent work
 * (Main REPLACES the old runtime-own-FGS prototype with this; the runtime
 * component is a bound-only service whose process importance is inherited
 * from its Core foreground client).
 *
 * Hard rules implemented here:
 *  * exported=false, START_NOT_STICKY: no reboot/redelivery, no
 *    force-stop resurrection, no PiP and no idle keep-alive. The Intent it
 *    receives carries NO command, owner or task authority — it is never
 *    read; the service promotes ONLY work already registered in the
 *    transient in-process owned-operation registry.
 *  * A usable notification is verified on the REAL framework state before
 *    [startForeground]; confirmation of an ACTUAL successful
 *    [startForeground] call is what flips the shared foreground truth
 *    flag the permits consult. No boolean preference or stored string is
 *    ever the proof; a failure is reported as a typed denial so the
 *    acquirer can roll back and the App can report background availability
 *    honestly (blocked notifications are never reported as ready).
 *  * The stop action is an immutable PendingIntent into the nonexported
 *    [RunForegroundStopReceiver], stamped with the owned-set stamp the
 *    notification was rendered with: a stale press is fenced and can never
 *    cancel a new unrelated run; a live press only routes cancellation
 *    requests to the ORIGINAL owners' cancel paths — ownership is
 *    nonterminal until the real work settles.
 *  * The service stops PROMPTLY once every actual operation has settled
 *    (owned set empty). It never runs just because the App exists or a
 *    future schedule/approval is waiting.
 *  * CURRENT-instance ownership (Main review round 4): every
 *    end/denial/confirm/sync/stop path carries this instance and is
 *    fenced by RunForegroundState's locked ownership. A replaced or
 *    destroyed instance whose callback arrives late cannot clear a
 *    newer live instance's foreground truth, stamp or listener, and
 *    cannot arm a denial; the CURRENT instance's real destroy still
 *    ends protection truthfully in one atomic step.
 *  * Small icon reuses the installed Floe app icon asset
 *    ([Context.getApplicationInfo] .icon): no Apple SF assets, no Material
 *    redesign.
 */
class RunForegroundService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var wakeHandleCandidate: CpuWakeHandle? = null

    /** Applies the real-work wake rule for this instance against the ACTUAL
     *  framework state. Never invents protection: [OwnedWorkWakeCoordinator]
     *  only acquires while foreground is confirmed AND owned work is live,
     *  and only releases once the owned set settled empty. The candidate is
     *  built on the APPLICATION context (a per-instance Context could leak
     *  into the process-canonical wake), and the coordinator keeps exactly
     *  ONE process wake object: this instance either installs it or adopts
     *  the wake already held by the process — a recreated instance can
     *  neither strand the old WakeLock nor stack a second one. */
    private fun syncWake() {
        val candidate = wakeHandleCandidate
            ?: PowerManagerWakeHandle(applicationContext).also { wakeHandleCandidate = it }
        OwnedWorkWakeCoordinator.sync(this, candidate,
            foregroundConfirmed = RunForegroundState.foreground.value,
            ownedEmpty = !RunForegroundState.hasHeldWork())
    }

    override fun onCreate() {
        super.onCreate()
        // The settle watch lives in the companion (process lifetime): the
        // wake's release at REAL settlement must survive every instance's
        // teardown, when the per-instance listener is already gone.
        OwnedWorkWakeCoordinator.installSettleWatch(settleWatch)
        ensureChannel()
        // Identity-fenced listener AND atomic current-owner transfer:
        // from this bind only this instance's guarded calls can mutate
        // the shared truth; a retiring instance can never clear a newer
        // instance's listener or protection.
        RunForegroundState.bindServiceListener(this) {
            handler.post { syncWithOwnedState() }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_NOT_STICKY everywhere: nothing is redelivered or restored;
        // ownership is TRANSIENT and process-local by design. The intent
        // argument is NEVER read (no command/owner/task extras authority).
        if (!hasChannel()) {
            RunForegroundState.reportServiceDenial(this,
                RunForegroundFailure.Unavailable("core-channel-unrecognized")
            )
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (!RunForegroundState.hasHeldWork()) {
            // Started/promoted with NO already-registered owned work:
            // never manufacture foreground from nothing. Whoever is
            // waiting learns this through the bounded confirm window.
            RunForegroundState.reportServiceDenial(this,
                RunForegroundFailure.Unavailable("no-owned-work-at-start")
            )
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val block = blockedReason()
        if (block != null) {
            RunForegroundState.reportServiceDenial(this, block)
            RunForegroundState.endForeground(this)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (!promote()) {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    /** Called from the owned-set listener and after attach re-renders.
     *  A post from the listener can outlive this instance's role: the
     *  FIRST fence is the ACTUAL current ownership check, and every
     *  shared mutation below (stop-when-idle, promote, denial) re-fences
     *  under the state's decision lock, so no check/act window exists
     *  for a replaced instance's late callback. */
    private fun syncWithOwnedState() {
        if (!RunForegroundState.isCurrentService(this)) return
        if (RunForegroundState.stopWhenIdle(this) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }) {
            syncWake()
            return
        }
        if (RunForegroundState.foreground.value) {
            promote()
        } else {
            syncWake()
        }
        // If not foreground while work IS owned, a pending onStartCommand
        // from the acquirer is responsible; a dead promotion path was
        // already reported as a typed denial there.
    }

    /** Builds and applies the notification and calls startForeground.
     *  Returns true ONLY after an ACTUAL startForeground success that
     *  the CURRENT ownership fence accepted — the single source of the
     *  shared foreground truth flag. A success arriving after this
     *  instance was replaced retires its own notification instead of
     *  claiming the truth or the stamp for the newer service. */
    private fun promote(): Boolean {
        val stamp = RunForegroundState.currentStamp
        val notification = try {
            buildNotification(stamp)
        } catch (failure: Exception) {
            RunForegroundState.reportServiceDenial(this,
                RunForegroundFailure.Unavailable("notification-build-failed")
            )
            RunForegroundState.endForeground(this)
            return false
        }
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            if (!RunForegroundState.confirmForeground(this, stamp)) {
                // This instance was REPLACED while the startForeground
                // call was in flight: a dead instance never claims or
                // stamps the shared truth. Retire OUR OWN notification
                // honestly and stop; the newer live instance owns the
                // protection from here.
                runCatching {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                return false
            }
            // Wake ownership follows the CONFIRMED service, never the mere
            // intent to start one.
            syncWake()
            true
        } catch (failure: IllegalStateException) {
            RunForegroundState.reportServiceDenial(this,
                RunForegroundFailure.StartDenied("start-foreground-refused")
            )
            RunForegroundState.endForeground(this)
            false
        } catch (failure: SecurityException) {
            RunForegroundState.reportServiceDenial(this,
                RunForegroundFailure.StartDenied("foreground-type-permission-missing")
            )
            RunForegroundState.endForeground(this)
            false
        }
    }

    private fun buildNotification(stamp: Long): Notification {
        val key = NotificationCopy.keyFor(RunForegroundState.heldKinds())
            ?: throw IllegalStateException("no held work")
        ensureChannel()
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(getString(R.string.floe_run_foreground_title))
            .setContentText(getString(copyResFor(key)))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.floe_run_foreground_stop),
                    stopIntent(stamp),
                ).build()
            )
            .build()
    }

    private fun copyResFor(key: NotificationCopy.Key): Int = when (key) {
        NotificationCopy.Key.AGENT_RUN -> R.string.floe_run_foreground_agent_run
        NotificationCopy.Key.ENVIRONMENT_INSTALL -> R.string.floe_run_foreground_install
        NotificationCopy.Key.LOCAL_EXECUTION -> R.string.floe_run_foreground_session
        NotificationCopy.Key.DURABLE_JOB -> R.string.floe_run_foreground_job
        NotificationCopy.Key.MULTIPLE -> R.string.floe_run_foreground_multiple
    }

    private fun openAppIntent(): PendingIntent? = try {
        PendingIntent.getActivity(
            this,
            0,
            Intent().setClassName(packageName, MAIN_ACTIVITY),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    } catch (failure: Exception) {
        null // Notification stays usable without a content intent.
    }

    /** Immutable stop PendingIntent. It carries ONLY the rendered
     *  owned-set stamp — fence data, not a command: the receiver fires
     *  ONLY current-live exact owners' cancel routes, and a stale stamp
     *  is ignored (a new unrelated operation can never be cancelled by an
     *  old notification). FLAG_CANCEL_CURRENT ensures only the latest
     *  rendered press is deliverable. */
    private fun stopIntent(stamp: Long): PendingIntent {
        val intent = Intent(this, RunForegroundStopReceiver::class.java)
            .setAction(RunForegroundStopReceiver.ACTION_STOP)
            .putExtra(RunForegroundStopReceiver.EXTRA_NOTIFICATION_STAMP, stamp)
        return PendingIntent.getBroadcast(
            this,
            STOP_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT,
        )
    }

    private fun blockedReason(): RunForegroundFailure? {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return RunForegroundFailure.NotificationsBlocked("post-notifications-not-granted")
        }
        val manager = getSystemService(NotificationManager::class.java)
            ?: return RunForegroundFailure.Unavailable("notification-manager-unavailable")
        val channel = manager.notificationChannels.firstOrNull { it.id == CHANNEL_ID }
        return when (NotificationGate.classify(
            sdkInt = Build.VERSION.SDK_INT,
            postNotificationsGranted = true,
            notificationsEnabled = manager.areNotificationsEnabled(),
            channelExists = channel != null,
            channelBlocked = channel?.importance == NotificationManager.IMPORTANCE_NONE,
        )) {
            NotificationGate.Block.NOTIFICATIONS_DISABLED ->
                RunForegroundFailure.NotificationsBlocked("app-notifications-disabled")
            NotificationGate.Block.CHANNEL_BLOCKED ->
                RunForegroundFailure.NotificationsBlocked("channel-blocked")
            else -> null
        }
    }

    private fun hasChannel(): Boolean = try {
        com.floe.android.runtimeipc.RuntimePackages.forCore(packageName)
        true
    } catch (failure: Exception) {
        false
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.notificationChannels.none { it.id == CHANNEL_ID }) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.floe_run_foreground_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = getString(R.string.floe_run_foreground_channel_description)
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        // Atomic ownership-fenced retirement (Main review round 4):
        // the CURRENT instance's real destroy ends listener, ownership,
        // applied stamp and the foreground truth in ONE fenced step —
        // permits then answer 0 while foreground is not real, honestly.
        // A REPLACED instance destroyed late changes NOTHING: the newer
        // live instance's protection, stamp and listener stay intact,
        // because the shared truth belongs to the ACTUAL current owner,
        // not to whichever destroy callback arrives. Registrations are
        // NOT cancelled here (binder death / service teardown never
        // equals lease release); Main's runtime linkToDeath path
        // requests a REAL process stop on its side.
        RunForegroundState.retireService(this)
        // A dying instance never drops the CPU wake while real work is
        // still owned: the coordinator KEEPS the process-canonical wake
        // (a newer instance adopts it, a stale instance can neither strand
        // nor stack it), and it releases only when the owned set has
        // ACTUALLY settled — even if this was the last instance, the
        // companion settle watch rechecks the real owned set and applies
        // the release at real settlement. The truth it syncs against is
        // now the REAL current state: a stale retire above left a newer
        // confirmation untouched, so this instance's late sync can only
        // KEEP (work owned) or truthfully RELEASE (settled empty) — it
        // can no longer release-under-a-false-flag the newer service set.
        syncWake()
        super.onDestroy()
    }

    companion object {
        /** Channel is distinct from the runtime component's own channel;
         *  this is the CORE app's Agent task channel. */
        const val CHANNEL_ID = "floe-agent-tasks"
        const val NOTIFICATION_ID = 1047
        private const val STOP_REQUEST_CODE = 1
        /** Only used as the notification tap target; the class name is
         *  the stable Core launcher activity, never a command source. */
        private const val MAIN_ACTIVITY = "com.floe.android.MainActivity"

        /** Bounded settle-latency of the process wake watch when it is
         *  the ONLY observer left (every service instance already
         *  destroyed while real work was still owned). Cheap truth reads
         *  only, and the chain cancels itself the moment the wake is not
         *  held — it never runs for an idle process. */
        private const val SETTLE_CHECK_MS = 1_000L
        private val settleHandler = Handler(Looper.getMainLooper())
        private val settleRecheck = Runnable {
            OwnedWorkWakeCoordinator.syncFromProcessWatch(
                foregroundConfirmed = RunForegroundState.foreground.value,
                ownedEmpty = !RunForegroundState.hasHeldWork(),
            )
        }
        /** One pending recheck at a time (removeCallbacks coalesces a
         *  live instance's syncs and the watch into at most one flight).
         *  Every ACQUIRE/KEEP re-arms, every RELEASE/IDLE cancels: a
         *  self-stopping chain, alive exactly while the real wake is held,
         *  owned by the companion — not by any service instance. */
        private val settleWatch = object : SettleWatch {
            override fun scheduleSettledCheck() {
                settleHandler.removeCallbacks(settleRecheck)
                settleHandler.postDelayed(settleRecheck, SETTLE_CHECK_MS)
            }

            override fun cancelSettledCheck() {
                settleHandler.removeCallbacks(settleRecheck)
            }
        }
    }
}
