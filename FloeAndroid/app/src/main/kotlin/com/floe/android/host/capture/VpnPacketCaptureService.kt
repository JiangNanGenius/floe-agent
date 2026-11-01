// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.floe.android.core.networkcapture.CaptureDrainRegistry
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.DataPlaneStopProof
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

/**
 * Real VpnService owner for the no-root path. It creates the TUN fd through
 * [NetBareDataPlane], keeps a specialUse foreground notification, and proves
 * the data plane/forwarders/sink settled before reporting a stopped state.
 * It never starts from a persisted Intent and never revives after process death.
 *
 * The drain itself is owned by [CaptureServiceRuntime.drainOwner] from the
 * first stop request: this Service only observes settlement and stops its own
 * notification. If Android destroys the Service while the drain is still
 * unproven, the deferred join and the one finalize run in the process owner
 * with the SAME data plane, forwarders, sink and staging file.
 */
class VpnPacketCaptureService : VpnService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var host: CaptureHostController? = null
    private var active: Active? = null
    private var claimedLaunch: CaptureLaunch? = null
    private var settleObserver: Job? = null
    private val foregroundStopped = AtomicBoolean(false)
    @Volatile
    private var destroying = false

    private class Active(
        val launch: CaptureLaunch,
        val dataPlane: NetBareDataPlane,
    ) {
        val ownerToken = Any()
        var timer: Job? = null
        var monitor: Job? = null

        @Volatile
        var retainedTask: CaptureDrainOwner.Task<VpnDrainResult>? = null
    }

    private data class VpnDrainResult(
        val proof: DataPlaneStopProof,
        val sink: com.floe.android.core.networkcapture.CaptureSinkSummary,
        val failure: String?,
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
                    // A repeated RootStop/USER_STOP joins the same retained
                    // drain; it never creates a second capture or releases a
                    // live thread just because an earlier wait timed out.
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
        val current = active
        if (current != null) {
            val controller = host
            val retained = retainDrain(current, controller, CaptureEndReason.SERVICE_DESTROYED)
            if (retained) {
                // Bounded: a false result is honest and the retained job keeps
                // running in the process owner after this Service is gone.
                runBlocking(Dispatchers.IO) {
                    CaptureServiceRuntime.drainOwner()
                        .awaitSettled(current.launch.sessionId, DESTROY_SETTLE_WAIT_MILLIS)
                }
            }
            markServiceStopped(current.launch.sessionId)
        } else {
            claimedLaunch?.let { host?.failLaunch(it, "serviceDestroyed") }
            claimedLaunch = null
        }
        settleObserver?.cancel()
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
        if (launch.config.mode != CaptureMode.VPN) {
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
        CaptureDrainRegistry.shared.register(launch.sessionId, CaptureMode.VPN)
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
        host?.onServiceStopRequested(current.launch.sessionId, reason)
        if (!retainDrain(current, host, reason)) {
            // A conflicting owner for the same session must not finalize
            // underneath it; the ledger stays outstanding (fail closed).
            return
        }
        if (settleObserver?.isActive != true) {
            settleObserver = serviceScope.launch(Dispatchers.Default) {
                val owner = CaptureServiceRuntime.drainOwner()
                while (owner.isRetained(current.launch.sessionId)) {
                    delay(CaptureLimits.DRAIN_RETRY_MILLIS)
                }
                markServiceStopped(current.launch.sessionId)
                if (this@VpnPacketCaptureService.active === current) {
                    this@VpnPacketCaptureService.active = null
                }
                if (!destroying) stopSelf()
            }
        }
    }

    /**
     * Transfer the same [Active] to the process owner. Idempotent for every
     * explicit stop/revoke/timer path and for Service destruction.
     */
    private fun retainDrain(
        current: Active,
        controller: CaptureHostController?,
        reason: CaptureEndReason,
    ): Boolean {
        current.retainedTask?.let { return true }
        val task = VpnDrainTask(current, controller, reason)
        return when (CaptureServiceRuntime.drainOwner().retain(task)) {
            CaptureDrainOwner.Retention.STARTED,
            CaptureDrainOwner.Retention.ALREADY_RETAINED -> {
                current.retainedTask = task
                true
            }
            CaptureDrainOwner.Retention.CONFLICT,
            CaptureDrainOwner.Retention.INVALID_SESSION -> false
        }
    }

    private inner class VpnDrainTask(
        private val current: Active,
        private val controller: CaptureHostController?,
        private val reason: CaptureEndReason,
    ) : CaptureDrainOwner.Task<VpnDrainResult>() {
        override val sessionId: String = current.launch.sessionId
        override val mode: CaptureMode = CaptureMode.VPN
        override val ownerToken: Any = current.ownerToken

        override suspend fun attempt(): CaptureDrainOwner.Attempt<VpnDrainResult> {
            current.dataPlane.requestStop(reason)
            val proof = current.dataPlane.awaitStopped(CaptureLimits.STOP_WAIT_MILLIS)
            val sink = current.launch.artifact.sink.closeAndDrain(CaptureLimits.DRAIN_WAIT_MILLIS)
            val writerJoined = !current.launch.artifact.sink.isWriterAlive()
            val settled = proof.dataPlaneThreadStopped && proof.forwardersStopped &&
                proof.vpnFdClosed && sink.drained && writerJoined
            CaptureDrainRegistry.shared.update(sessionId) {
                it.copy(
                    stopRequested = true,
                    dataPlaneThreadStopped = proof.dataPlaneThreadStopped,
                    forwardersStopped = proof.forwardersStopped,
                    vpnFdClosed = proof.vpnFdClosed,
                    sinkDrained = sink.drained,
                    sinkWriterJoined = writerJoined,
                    lastFailure = current.dataPlane.failureCode(),
                )
            }
            val failure = current.dataPlane.failureCode()
            return if (settled) {
                CaptureDrainOwner.Attempt(true, VpnDrainResult(proof, sink, failure))
            } else {
                CaptureDrainOwner.Attempt(
                    settled = false,
                    failure = failure ?: "stopNotProven",
                )
            }
        }

        override fun finalize(value: VpnDrainResult) {
            markServiceStopped(sessionId)
            controller?.onVpnStopped(
                launch = current.launch,
                sink = value.sink,
                dataPlaneProof = DataPlaneProof(
                    forwardersStopped = value.proof.forwardersStopped,
                    threadStopped = value.proof.dataPlaneThreadStopped,
                    vpnFdClosed = value.proof.vpnFdClosed,
                    foregroundServiceStopped = true,
                ),
                reason = reason,
                dataPlaneFailure = value.failure,
            )
            if (controller == null) {
                // No Application host exists in this process; the ledger still
                // records the real settle so a later RootStop is not blocked.
                CaptureDrainRegistry.shared.completeAfterFinalize(sessionId)
            }
        }
    }

    /**
     * Stop the foreground/notification state exactly once. This is the ACTUAL
     * stopForeground call, so the ledger flag is never inferred from a request.
     */
    private fun markServiceStopped(sessionId: String) {
        if (!foregroundStopped.compareAndSet(false, true)) return
        cleanupForeground()
        CaptureDrainRegistry.shared.update(sessionId) { it.copy(vpnServiceStopped = true) }
    }

    private fun updateNotification() {
        val host = host ?: return
        val state = host.currentState()
        if (state.phase == com.floe.android.core.networkcapture.CapturePhase.RUNNING ||
            state.phase == com.floe.android.core.networkcapture.CapturePhase.STOPPING
        ) {
            runCatching {
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
    }

    private fun cleanupForeground() {
        runCatching { CaptureNotifications.cancel(this) }
        runCatching { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
    }

    companion object {
        const val ACTION_START = "com.floe.android.action.PACKET_CAPTURE_START"
        const val ACTION_STOP = "com.floe.android.action.PACKET_CAPTURE_STOP"
        const val EXTRA_LAUNCH_ID = "launchId"
        const val EXTRA_SESSION_ID = "sessionId"

        /**
         * Service.onDestroy must return promptly; the retained process owner
         * continues after this bounded wait returns false.
         */
        private const val DESTROY_SETTLE_WAIT_MILLIS = 1_500L
    }
}
