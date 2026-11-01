// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.NetBareDataPlane
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/**
 * Real VpnService owner for the no-root path. It creates the TUN fd through
 * [NetBareDataPlane], keeps a specialUse foreground notification, and proves
 * the data plane/forwarders/sink settled before reporting a stopped state.
 * It never starts from a persisted Intent and never revives after process death.
 */
class VpnPacketCaptureService : VpnService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var host: CaptureHostController? = null
    private var active: Active? = null
    private var claimedLaunch: CaptureLaunch? = null
    private val stopStarted = AtomicBoolean(false)
    @Volatile
    private var destroying = false

    private data class Active(
        val launch: CaptureLaunch,
        val dataPlane: NetBareDataPlane,
        var timer: Job? = null,
        var monitor: Job? = null,
    )

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val runtime = CaptureServiceRuntime.current()
        if (runtime == null) {
            stopSelf()
            return
        }
        host = runtime
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (destroying) return START_NOT_STICKY
        when (intent?.action) {
            ACTION_START -> {
                val launchId = intent.getStringExtra(EXTRA_LAUNCH_ID)
                if (launchId == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startCapture(launchId)
            }
            ACTION_STOP -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                val current = active
                if (current != null && sessionId == current.launch.sessionId) {
                    stopInternal(CaptureEndReason.USER_STOP)
                } else if (current == null) {
                    stopSelf()
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopInternal(CaptureEndReason.VPN_REVOKED)
        super.onRevoke()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopInternal(CaptureEndReason.SERVICE_DESTROYED)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        destroying = true
        active?.let {
            runBlocking(Dispatchers.IO) {
                stopAndDrainBlocking(it, CaptureEndReason.SERVICE_DESTROYED)
            }
        } ?: claimedLaunch?.let {
            host?.failLaunch(it, "serviceDestroyed")
            claimedLaunch = null
        }
        serviceScope.cancel()
        host = null
        super.onDestroy()
    }

    private fun startCapture(launchId: String) {
        val host = host ?: run {
            stopSelf()
            return
        }
        val launch = host.claimLaunch(launchId) ?: run {
            stopSelf()
            return
        }
        claimedLaunch = launch
        if (launch.config.mode != com.floe.android.core.networkcapture.CaptureMode.VPN) {
            host.failLaunch(launch, "modeMismatch")
            stopSelf()
            return
        }
        val hostState = host.currentState()
        if (hostState.sessionId != launch.sessionId ||
            hostState.phase != com.floe.android.core.networkcapture.CapturePhase.STARTING
        ) {
            host.failLaunch(launch, "staleLaunch")
            stopSelf()
            return
        }
        if (active != null) {
            host.failLaunch(launch, "alreadyActive")
            stopSelf()
            return
        }
        if (!CaptureNotifications.ensureChannel(this) || !CaptureNotifications.isAllowed(this)) {
            host.failLaunch(launch, "notificationsDisabled")
            stopSelf()
            return
        }
        try {
            ServiceCompat.startForeground(
                this,
                CaptureNotifications.NOTIFICATION_ID,
                CaptureNotifications.build(
                    this,
                    host.currentState(),
                    VpnPacketCaptureService::class.java,
                    stopAction = VpnPacketCaptureService.ACTION_STOP,
                    sessionExtra = VpnPacketCaptureService.EXTRA_SESSION_ID,
                    starting = true,
                ),
                if (Build.VERSION.SDK_INT >= 34) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                } else {
                    0
                },
            )
        } catch (_: SecurityException) {
            host.failLaunch(launch, "foregroundStartFailed")
            stopSelf()
            return
        } catch (_: IllegalStateException) {
            host.failLaunch(launch, "foregroundStartFailed")
            stopSelf()
            return
        }

        val dataPlane = NetBareDataPlane(this, launch.plan, launch.artifact.sink)
        val start = dataPlane.start()
        if (!start.accepted) {
            claimedLaunch = null
            host.failLaunch(launch, start.code ?: "dataPlaneStartFailed")
            cleanupForeground()
            stopSelf()
            return
        }
        claimedLaunch = null
        val active = Active(launch = launch, dataPlane = dataPlane)
        this.active = active
        host.onVpnStarted(launch, start.startedAtMillis)
        updateNotification()
        active.timer = serviceScope.launch {
            delay(launch.config.maxDurationMillis)
            stopInternal(CaptureEndReason.DURATION_LIMIT)
        }
        active.monitor = serviceScope.launch {
            while (isActive) {
                delay(500L)
                val current = this@VpnPacketCaptureService.active ?: break
                if (current !== active) break
                val stats = active.launch.artifact.sink.stats()
                host.onVpnStats(launch.sessionId, stats)
                updateNotification()
                if (!active.dataPlane.isRunning()) {
                    val reason = active.dataPlane.requestedReason()
                        ?: if (active.dataPlane.failureCode() != null) {
                            CaptureEndReason.DATA_PLANE_ERROR
                        } else {
                            CaptureEndReason.VPN_REVOKED
                        }
                    stopInternal(reason)
                    break
                }
            }
        }
    }

    private fun stopInternal(reason: CaptureEndReason) {
        val current = active ?: run {
            claimedLaunch?.let { host?.failLaunch(it, "serviceStopped") }
            claimedLaunch = null
            cleanupForeground()
            stopSelf()
            return
        }
        if (!stopStarted.compareAndSet(false, true)) return
        host?.onServiceStopRequested(current.launch.sessionId, reason)
        serviceScope.launch {
            stopAndDrain(current, reason)
            stopSelf()
        }
    }

    private suspend fun stopAndDrain(current: Active, reason: CaptureEndReason) {
        current.timer?.cancel()
        current.monitor?.cancel()
        current.dataPlane.requestStop(reason)
        val proof = withContext(Dispatchers.IO) {
            current.dataPlane.awaitStopped(5_000L)
        }
        val sink = withContext(Dispatchers.IO) {
            current.launch.artifact.sink.closeAndDrain(5_000L)
        }
        cleanupForeground()
        host?.onVpnStopped(
            launch = current.launch,
            sink = sink,
            dataPlaneProof = DataPlaneProof(
                forwardersStopped = proof.forwardersStopped,
                threadStopped = proof.dataPlaneThreadStopped,
                vpnFdClosed = proof.vpnFdClosed,
                foregroundServiceStopped = true,
            ),
            reason = reason,
            dataPlaneFailure = current.dataPlane.failureCode(),
        )
        if (active === current) active = null
    }

    private suspend fun stopAndDrainBlocking(current: Active, reason: CaptureEndReason) {
        stopAndDrain(current, reason)
    }

    private fun updateNotification() {
        val host = host ?: return
        val state = host.currentState()
        if (state.phase == com.floe.android.core.networkcapture.CapturePhase.RUNNING ||
            state.phase == com.floe.android.core.networkcapture.CapturePhase.STOPPING
        ) {
            androidx.core.app.NotificationManagerCompat.from(this).notify(
                CaptureNotifications.NOTIFICATION_ID,
                CaptureNotifications.build(
                    this,
                    state,
                    VpnPacketCaptureService::class.java,
                    VpnPacketCaptureService.ACTION_STOP,
                    VpnPacketCaptureService.EXTRA_SESSION_ID,
                ),
            )
        }
    }

    private fun cleanupForeground() {
        CaptureNotifications.cancel(this)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    companion object {
        const val ACTION_START = "com.floe.android.action.PACKET_CAPTURE_START"
        const val ACTION_STOP = "com.floe.android.action.PACKET_CAPTURE_STOP"
        const val EXTRA_LAUNCH_ID = "launchId"
        const val EXTRA_SESSION_ID = "sessionId"
    }
}
