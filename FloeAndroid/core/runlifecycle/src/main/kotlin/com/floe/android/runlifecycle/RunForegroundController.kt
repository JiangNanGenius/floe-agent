// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The single Core-side entry point for Agent foreground service ownership.
 *
 * [forApplication] is DATA-ONLY: it captures the application context and
 * never starts a service, never builds a notification channel and never
 * touches a permission. Real foreground promotion happens exclusively
 * through [acquireOperation], and ONLY for an already-registered real
 * operation — readiness false/unknown never creates an idle service, and
 * an app merely existing in the foreground is not owned work.
 *
 * Honest outcomes (no automatic OS grants, no Settings launches, no
 * permission dialogs; Main owns the visible POST_NOTIFICATIONS UX):
 *  * [RunForegroundFailure.NotificationsBlocked] — a usable foreground
 *    notification is impossible right now; the caller must NOT treat the
 *    operation as background-ready. App-foreground chat remains possible
 *    through the existing flow.
 *  * [RunForegroundFailure.StartDenied] — the OS refused to start the
 *    foreground service (user-started long work must acquire BEFORE the
 *    user backgrounds the app; a late async event cannot manufacture a
 *    start window).
 *  * [RunForegroundFailure.Unavailable] — unrecognized channel, refused
 *    start, or the live service did not confirm a REAL startForeground
 *    success within the bounded window.
 *  * [RunForegroundFailure.OwnerConflict] — the exact id is already owned
 *    under a different kind; the live registration is left untouched.
 *
 * A same-kind re-acquire attaches with refcount semantics and shares the
 * existing permit token; every attached lease must close before the owned
 * set changes. No lease close ever cancels work, and no stop path here
 * treats binder death or a stop request as lease release.
 */
class RunForegroundController private constructor(
    private val appContext: Context,
) {

    companion object {
        /** Bounded window for the SERVICE to report a real startForeground
         *  success. The service either confirms, reports a typed denial or
         *  the window closes honestly; no silent success is possible. */
        private const val CONFIRM_TIMEOUT_MS = 10_000L

        @Volatile
        private var sharedInstance: RunForegroundController? = null

        /** Data-only creation; exactly one controller per Core process. */
        fun forApplication(context: Context): RunForegroundController {
            sharedInstance?.let { return it }
            synchronized(this) {
                sharedInstance?.let { return it }
                val created = RunForegroundController(context.applicationContext)
                sharedInstance = created
                return created
            }
        }
    }

    /**
     * Registers service ownership for one REAL operation and returns its
     * lease once the Core foreground service has CONFIRMED an actual
     * startForeground success (or immediately when an already-confirmed
     * live service covers the same exact registration).
     *
     * @param operationID stable UUID string. UI operations mint it at the
     *   explicit action; Agent/job ids come from the ORIGINAL runtime
     *   context/state — this class never invents, derives or infers ids.
     * @param stopHandler routes the notification Stop action to the
     *   operation's REAL cancellation path owned by the caller (canonical
     *   run.cancel, session release channel, installer stop). A stop press
     *   cancels nothing by itself: the lease stays owned until the actual
     *   work settles and its owner closes it.
     */
    suspend fun acquireOperation(
        operationID: String,
        kind: OperationKind,
        stopHandler: RunStopHandler? = null,
    ): ForegroundLease {
        val stableID = OperationIds.normalize(operationID)

        // Build/channel reality first: only the four settled Core channels
        // have a runtime peer, and nothing here can run on a foreign or
        // test package pretending to be Core.
        val runtimePackageName = try {
            com.floe.android.runtimeipc.RuntimePackages.forCore(appContext.packageName).runtime
        } catch (failure: SecurityException) {
            throw RunForegroundFailure.Unavailable("core-channel-unrecognized")
        } catch (failure: IllegalArgumentException) {
            throw RunForegroundFailure.Unavailable("core-channel-ambiguous")
        }

        // Honest preflight on REAL framework state. Blocked notifications
        // must never be reported as background-ready.
        preflightNotifications()?.let { throw it }

        RunForegroundState.armNextAcquisition()
        val entry = when (val outcome = RunForegroundState.acquire(
            operationID = stableID,
            kind = kind,
            stopHandler = stopHandler,
            runtimePackageName = runtimePackageName,
            coreContext = appContext,
        )) {
            is RunForegroundState.RegistrationOutcome.Registered -> outcome.entry
            is RunForegroundState.RegistrationOutcome.Conflicting -> {
                // Nothing mutated by this call; report honestly.
                throw RunForegroundFailure.OwnerConflict(stableID, outcome.existingKind, kind)
            }
        }
        val lease = ForegroundLease(
            operationID = stableID,
            kind = kind,
            runtimePermit = entry.token,
            ownerGeneration = entry.ownerGeneration,
        )

        if (RunForegroundState.foreground.value) {
            // A live, CONFIRMED foreground service already exists; the
            // owned-set listener re-rendered it with the new set stamp.
            return lease
        }

        // The Intent is deliberately data-free: no extras, no action, no
        // command authority. The service promotes only work already
        // registered above; onStartCommand never reads task/lease/owner
        // information from any Intent.
        val serviceIntent = Intent(appContext, RunForegroundService::class.java)
        try {
            appContext.startForegroundService(serviceIntent)
        } catch (failure: Exception) {
            // Release ONLY this call's contribution (refcount-exact).
            lease.close()
            val name = failure.javaClass.name
            if (name.endsWith("ForegroundServiceStartNotAllowedException") ||
                name.endsWith("ForegroundServiceDidNotStartInTimeException")
            ) {
                throw RunForegroundFailure.StartDenied("system-refused-foreground-start")
            }
            if (failure is SecurityException) {
                throw RunForegroundFailure.StartDenied("foreground-service-permission-missing")
            }
            throw RunForegroundFailure.Unavailable("start-delivery-failed")
        }

        // Cancellation edge (Main review): if the acquirer's coroutine is
        // cancelled while waiting for confirmation, the REAL operation has
        // NOT yet been admitted by the caller, so this call's registration
        // contribution must be released exactly once before the
        // CancellationException is rethrown. Refcount release keeps any
        // OTHER attached holder of the same live operation intact; a
        // created registration rolling to empty stops the service through
        // the owned-set listener (never a leaked idle FGS).
        val confirmed = try {
            withTimeoutOrNull(CONFIRM_TIMEOUT_MS) {
                RunForegroundState.foreground.first { running -> running }
                Unit
            }
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            lease.close()
            throw cancellation
        }
        if (confirmed == null) {
            val denial = RunForegroundState.takeDenial()
            lease.close()
            throw denial ?: RunForegroundFailure.Unavailable("start-foreground-unconfirmed")
        }
        // A denial armed during a concurrently-successful confirm is no
        // longer relevant to this acquirer (foreground IS real now).
        RunForegroundState.takeDenial()
        return lease
    }

    /** Diagnostics for Main's honest reporting only: ids whose REAL work
     *  is still protected by the Core foreground service. */
    fun heldOperations(): Set<String> = RunForegroundState.heldOperationIDs()

    /** True only while a live service instance has confirmed an ACTUAL
     *  startForeground success. Never a boolean preference, a stored
     *  status string or a model answer. */
    fun isForegroundConfirmed(): Boolean = RunForegroundState.foreground.value

    /** Honest live read of the owned-work CPU wake (diagnostics for
     *  Main's reporting only; the wake itself is owned by the service +
     *  coordinator, never by this controller or any view). */
    fun isCpuWakeHeld(): Boolean = OwnedWorkWakeCoordinator.isCpuWakeHeld()

    private fun preflightNotifications(): RunForegroundFailure? {
        if (Build.VERSION.SDK_INT >= 33 &&
            appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return RunForegroundFailure.NotificationsBlocked("post-notifications-not-granted")
        }
        val manager = appContext.getSystemService(NotificationManager::class.java)
            ?: return RunForegroundFailure.Unavailable("notification-manager-unavailable")
        val channel = manager.notificationChannels
            .firstOrNull { it.id == RunForegroundService.CHANNEL_ID }
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
}
