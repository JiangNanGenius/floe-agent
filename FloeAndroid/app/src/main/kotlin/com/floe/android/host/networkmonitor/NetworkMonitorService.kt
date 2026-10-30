// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import com.floe.android.core.networkmonitor.NetworkMonitorEndReason
import com.floe.android.core.networkmonitor.NetworkMonitorPhase
import com.floe.android.core.networkmonitor.NetworkMonitorSessionState
import com.floe.android.core.networkmonitor.NetworkMonitoringEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Bounded dataSync foreground work: real user-started probe fetches, not an idle keepalive.
 * The app-wide dataSync budget can be shared with other services; onTimeout never retries or
 * assumes an independent allowance. START_NOT_STICKY prevents process-death/force-stop revival.
 *
 * The Service never owns launch admission by itself: [NetworkMonitorHost] records the CLAIMED
 * launch and performs the synchronous `engine.start` under its lock, so a Stop or root
 * retirement that lands in the foreground-start window fences the launch instead of allowing a
 * stale measurement to begin afterwards.
 */
class NetworkMonitorService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var host: NetworkMonitorHost? = null
    private var engine: NetworkMonitoringEngine? = null
    private var stateJob: Job? = null
    private var startedSessionId: String? = null
    private var claimedLaunch: NetworkMonitorLaunchLedger.Launch? = null
    private var destroying = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val host = NetworkMonitorServiceRuntime.current()
        if (host == null) {
            stopSelf()
            return
        }
        this.host = host
        val engine = NetworkMonitoringEngine(host.executor, serviceScope, Dispatchers.IO)
        if (!host.attach(NetworkMonitorServiceAttachment(engine, ::onNotificationPermissionRevoked))) {
            this.host = null
            stopSelf()
            return
        }
        this.engine = engine
        stateJob = serviceScope.launch {
            engine.state.collect { state -> onMonitorState(state) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (destroying) return START_NOT_STICKY
        when (intent?.action) {
            ACTION_STOP -> handleStop(intent)
            ACTION_START -> {
                val launchId = intent.getStringExtra(EXTRA_LAUNCH_ID)
                val host = host
                if (launchId == null || host == null) {
                    stopIfIdle()
                    return START_NOT_STICKY
                }
                // Unknown, replayed, cross-process, retired or post-process-death
                // tokens never start work and never disturb another session.
                val launch = host.claimLaunch(launchId)
                if (launch == null) {
                    stopIfIdle()
                    return START_NOT_STICKY
                }
                claimedLaunch = launch
                startSession(launch)
            }
            else -> stopIfIdle()
        }
        return START_NOT_STICKY
    }

    /**
     * Destroy an idle Service, but never kill the instance that is about to
     * receive a newer explicit Start. A stale launch token must not cancel a
     * different pending launch.
     */
    private fun stopIfIdle() {
        if (startedSessionId == null && claimedLaunch == null && host?.hasUnstartedLaunch() != true) {
            stopSelf()
        }
    }

    private fun handleStop(intent: Intent) {
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        val claim = claimedLaunch
        when {
            startedSessionId != null && sessionId != null ->
                stopSession(sessionId, NetworkMonitorEndReason.USER_STOP, immediate = false)
            claim != null && sessionId == claim.sessionId -> {
                // The foreground notification's own Stop can land before
                // engine.start; clear only this exact claimed launch.
                claimedLaunch = null
                host?.abandonClaimedLaunch(claim, NetworkMonitorEndReason.USER_STOP)
                cleanupForeground()
                stopIfIdle()
            }
            startedSessionId == null && claim == null -> stopIfIdle()
            // A mismatched/session-less Stop never cancels another launch/session.
        }
    }

    private fun startSession(launch: NetworkMonitorLaunchLedger.Launch) {
        val engine = engine
        if (engine == null) {
            claimedLaunch = null
            host?.failClaimedLaunch(launch, NetworkMonitorEndReason.FOREGROUND_START_FAILED)
            stopIfIdle()
            return
        }
        if (!NetworkMonitorNotificationAccess.isAllowed(this) || !NetworkMonitorNotifications.ensureChannel(this)) {
            claimedLaunch = null
            host?.failClaimedLaunch(launch, NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED)
            stopIfIdle()
            return
        }
        try {
            ServiceCompat.startForeground(
                this,
                NetworkMonitorNotifications.NOTIFICATION_ID,
                NetworkMonitorNotifications.starting(this, launch.sessionId),
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (_: SecurityException) {
            claimedLaunch = null
            host?.failClaimedLaunch(launch, NetworkMonitorEndReason.FOREGROUND_START_FAILED)
            cleanupForeground()
            stopIfIdle()
            return
        } catch (_: IllegalStateException) {
            claimedLaunch = null
            host?.failClaimedLaunch(launch, NetworkMonitorEndReason.FOREGROUND_START_FAILED)
            cleanupForeground()
            stopIfIdle()
            return
        }
        startedSessionId = launch.sessionId
        val host = host
        val outcome = host?.startClaimedLaunch(launch, engine)
            ?: NetworkMonitorClaimedStartOutcome.Refused
        claimedLaunch = null
        when (outcome) {
            is NetworkMonitorClaimedStartOutcome.Started -> Unit
            is NetworkMonitorClaimedStartOutcome.AlreadyActive -> {
                startedSessionId = outcome.sessionId
            }
            NetworkMonitorClaimedStartOutcome.Refused,
            NetworkMonitorClaimedStartOutcome.Failed -> {
                // Refused: the exact Stop/root retirement already published the
                // truthful terminal. Failed: the host published start failure.
                startedSessionId = null
                cleanupForeground()
                stopIfIdle()
            }
        }
    }

    private fun onMonitorState(state: NetworkMonitorSessionState) {
        val engine = engine ?: return
        if (destroying) return
        val sessionId = startedSessionId
        if (sessionId == null) {
            // No session is owned here (pending/claimed, or a terminal was
            // already published). Never let a stale non-terminal engine
            // transition overwrite that terminal truth; a real terminal still
            // updates the retained last snapshot.
            if (state.phase != NetworkMonitorPhase.IDLE && state.isTerminal) {
                host?.publish(engine, state)
            }
            return
        }
        host?.publish(engine, state)
        if (state.sessionId != sessionId) return
        if (state.isActive) {
            if (!NetworkMonitorNotificationAccess.isAllowed(this) ||
                !NetworkMonitorNotifications.ensureChannel(this)
            ) {
                stopImmediately(sessionId, NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED)
                return
            }
            try {
                NotificationManagerCompat.from(this).notify(
                    NetworkMonitorNotifications.NOTIFICATION_ID,
                    NetworkMonitorNotifications.update(this, state),
                )
            } catch (_: SecurityException) {
                stopImmediately(sessionId, NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED)
            }
        } else if (state.isTerminal) {
            // Release the terminal session before stopping the idle Service so
            // a following explicit Start is not mistaken for a duplicate.
            startedSessionId = null
            cleanupForeground()
            stopIfIdle()
        }
    }

    private fun stopSession(sessionId: String, reason: NetworkMonitorEndReason, immediate: Boolean) {
        if (startedSessionId != sessionId) return
        if (immediate) {
            stopImmediately(sessionId, reason)
        } else {
            engine?.requestStop(sessionId, reason)
        }
    }

    /** API35 budget, task removal and revoked-notification path: prompt stop, no restart/backoff. */
    private fun stopImmediately(sessionId: String, reason: NetworkMonitorEndReason) {
        if (startedSessionId != sessionId) return
        val engine = engine
        if (engine != null) host?.publishServiceTerminal(engine, sessionId, reason)
        engine?.requestStop(sessionId, reason)
        startedSessionId = null
        cleanupForeground()
        stopSelf()
    }

    private fun cleanupForeground() {
        NetworkMonitorNotifications.cancel(this)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    private fun onNotificationPermissionRevoked() {
        startedSessionId?.let { stopImmediately(it, NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED) }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        startedSessionId?.let { stopImmediately(it, NetworkMonitorEndReason.TIME_BUDGET_EXHAUSTED) }
            ?: stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        startedSessionId?.let { stopImmediately(it, NetworkMonitorEndReason.TASK_REMOVED) }
            ?: stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        destroying = true
        stateJob?.cancel()
        stateJob = null
        val ownedEngine = engine
        ownedEngine?.close()
        val sessionId = startedSessionId
        val claim = claimedLaunch
        if (ownedEngine != null && sessionId != null) {
            host?.publishServiceTerminal(ownedEngine, sessionId, NetworkMonitorEndReason.SERVICE_DESTROYED)
        } else if (claim != null) {
            host?.abandonClaimedLaunch(claim, NetworkMonitorEndReason.SERVICE_DESTROYED)
        }
        claimedLaunch = null
        startedSessionId = null
        ownedEngine?.let { host?.detach(it) }
        engine = null
        host = null
        serviceScope.cancel()
        NetworkMonitorNotifications.cancel(this)
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.floe.android.action.NETWORK_MONITOR_START"
        const val ACTION_STOP = "com.floe.android.action.NETWORK_MONITOR_STOP"
        const val EXTRA_LAUNCH_ID = "launchId"
        const val EXTRA_SESSION_ID = "sessionId"
    }
}
