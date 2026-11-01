// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture.root

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.floe.android.host.capture.CaptureHostController
import com.floe.android.host.capture.CaptureNotifications
import com.floe.android.host.capture.CaptureServiceRuntime
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.PcapRecordCounter
import com.floe.android.core.networkcapture.RootCaptureArtifact
import com.floe.android.core.networkcapture.RootCaptureProgress
import com.floe.android.core.networkcapture.RootCaptureRequest
import com.floe.android.core.networkcapture.RootCaptureStart
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Foreground owner for the Full-only root capture path. It contains no root
 * implementation itself: [RootCaptureBackend] is loaded by the host only when
 * the Full class is present. The service owns the raw file, progress counter,
 * notification and stop/drain proof.
 */
class RootPacketCaptureService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var host: CaptureHostController? = null
    private var session: Session? = null
    private var claimedRoot: RootCaptureRequest? = null
    private val stopping = AtomicBoolean(false)
    @Volatile
    private var destroying = false

    private data class Session(
        val request: RootCaptureRequest,
        val artifact: RootCaptureArtifact,
        val counter: PcapRecordCounter,
        var startJob: Job? = null,
    ) {
        @Volatile
        var lastEndReason: CaptureEndReason? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        host = CaptureServiceRuntime.current()
        if (host == null) stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (destroying) return START_NOT_STICKY
        when (intent?.action) {
            ACTION_START -> {
                val launchId = intent.getStringExtra(EXTRA_LAUNCH_ID) ?: run {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startRoot(launchId)
            }
            ACTION_STOP -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                val current = session
                if (current != null && sessionId == current.artifact.sessionId) {
                    stopInternal(CaptureEndReason.USER_STOP)
                } else if (current == null) {
                    stopSelf()
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopInternal(CaptureEndReason.SERVICE_DESTROYED)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        destroying = true
        session?.let { value ->
            runBlocking(Dispatchers.IO) {
                stopAndDrain(value, CaptureEndReason.SERVICE_DESTROYED)
            }
        }
        claimedRoot?.let { host?.failRootLaunch(it, "serviceDestroyed") }
        claimedRoot = null
        cleanupForeground()
        scope.cancel()
        host = null
        super.onDestroy()
    }

    private fun startRoot(launchId: String) {
        val host = host ?: run {
            stopSelf()
            return
        }
        val request = host.claimRootLaunch(launchId) ?: run {
            stopSelf()
            return
        }
        claimedRoot = request
        val state = host.currentState()
        if (state.mode != com.floe.android.core.networkcapture.CaptureMode.ROOT ||
            state.phase != com.floe.android.core.networkcapture.CapturePhase.STARTING
        ) {
            host.failRootLaunch(request, "staleLaunch")
            stopSelf()
            return
        }
        if (session != null) {
            host.failRootLaunch(request, "alreadyActive")
            stopSelf()
            return
        }
        if (!CaptureNotifications.ensureChannel(this) || !CaptureNotifications.isAllowed(this)) {
            host.failRootLaunch(request, "notificationsDisabled")
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
                    RootPacketCaptureService::class.java,
                    stopAction = RootPacketCaptureService.ACTION_STOP,
                    sessionExtra = RootPacketCaptureService.EXTRA_SESSION_ID,
                    starting = true,
                ),
                if (Build.VERSION.SDK_INT >= 34) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                } else {
                    0
                },
            )
        } catch (_: SecurityException) {
            host.failRootLaunch(request, "permissionRevoked")
            stopSelf()
            return
        } catch (_: IllegalStateException) {
            host.failRootLaunch(request, "foregroundStartFailed")
            stopSelf()
            return
        }
        val artifact = host.beginRootArtifact(request)
        if (artifact == null) {
            host.failRootLaunch(request, "artifactCreateFailed")
            stopSelf()
            return
        }
        claimedRoot = null
        val counter = PcapRecordCounter()
        val value = Session(request, artifact, counter)
        session = value
        host.onRootStarted(artifact.sessionId, System.currentTimeMillis())
        updateNotification(host, RootCaptureProgress(0, 0, malformed = false))
        value.startJob = scope.launch(Dispatchers.IO) {
            try {
            val backend = host.rootBackendOrNull()
            if (backend == null) {
                finish(value, CaptureEndReason.HELPER_UNAVAILABLE, proof = false)
                stopSelf()
                return@launch
            }
            val result = backend.start(
                request = request,
                onChunk = { bytes, offset, length ->
                    synchronized(counter) {
                        artifact.write(bytes, offset, length)
                        counter.consume(bytes, offset, length)
                        val progress = RootCaptureProgress(
                            bytes = counter.bytes,
                            packets = counter.packets,
                            malformed = counter.isMalformed,
                        )
                        host.onRootProgress(artifact.sessionId, progress)
                        updateNotification(host, progress)
                    }
                },
                onProgress = { progress ->
                    value.lastEndReason = progress.endReason ?: value.lastEndReason
                    host.onRootProgress(artifact.sessionId, progress)
                    updateNotification(host, progress)
                },
            )
            if (result !is RootCaptureStart.Started) {
                finish(
                    value,
                    when {
                        result is RootCaptureStart.Unavailable &&
                            result.code.startsWith("helper") -> CaptureEndReason.HELPER_UNAVAILABLE
                        result is RootCaptureStart.Failed &&
                            result.code.startsWith("helper") -> CaptureEndReason.HELPER_UNAVAILABLE
                        result is RootCaptureStart.Unavailable &&
                            result.code.startsWith("root") -> CaptureEndReason.PERMISSION_REVOKED
                        else -> CaptureEndReason.DATA_PLANE_ERROR
                    },
                    proof = false,
                )
                stopSelf()
                return@launch
            }
            // A natural return means the helper ended (duration/limit/error).
            val naturalReason = value.lastEndReason ?: CaptureEndReason.DATA_PLANE_ERROR
            finish(value, naturalReason, proof = naturalReason != CaptureEndReason.DATA_PLANE_ERROR)
            stopSelf()
            } catch (_: Throwable) {
                finish(value, CaptureEndReason.DATA_PLANE_ERROR, proof = false)
                stopSelf()
            }
        }
    }

    private fun stopInternal(reason: CaptureEndReason) {
        val value = session ?: run {
            claimedRoot?.let { host?.failRootLaunch(it, "serviceStopped") }
            claimedRoot = null
            stopSelf()
            return
        }
        if (!stopping.compareAndSet(false, true)) return
        host?.onServiceStopRequested(value.artifact.sessionId, reason)
        scope.launch {
            stopAndDrain(value, reason)
            stopSelf()
        }
    }

    private suspend fun stopAndDrain(value: Session, reason: CaptureEndReason) {
        val host = host ?: return
        val backend = host.rootBackendOrNull()
        val stopResult = withTimeoutOrNull(CaptureLimits.STOP_WAIT_MILLIS) {
            runCatching { backend?.stop() }.getOrNull()
        }
        val joined = withTimeoutOrNull(CaptureLimits.STOP_WAIT_MILLIS) {
            value.startJob?.join()
            true
        } ?: false
        val progress = synchronized(value.counter) {
            val counted = value.counter.finish()
            RootCaptureProgress(
                bytes = counted.bytes,
                packets = counted.packets,
                malformed = counted.malformed,
                endReason = reason,
            )
        }
        val stoppedCleanly = stopResult != null &&
            stopResult.endReason != CaptureEndReason.DATA_PLANE_ERROR
        finish(value, reason, proof = joined && stoppedCleanly)
    }

    private fun finish(value: Session, reason: CaptureEndReason, proof: Boolean) {
        val host = host ?: return
        if (!finishOnce.compareAndSet(false, true)) return
        val progress = synchronized(value.counter) {
            val counted = value.counter.finish()
            RootCaptureProgress(
                bytes = counted.bytes,
                packets = counted.packets,
                malformed = counted.malformed,
                endReason = reason,
            )
        }
        runCatching { value.artifact.flush() }
        cleanupForeground()
        host.onRootStopped(value.request, value.artifact, progress, reason, proof)
        if (session === value) session = null
    }

    private fun updateNotification(host: CaptureHostController, progress: RootCaptureProgress) {
        if (!CaptureNotifications.isAllowed(this)) return
        runCatching {
            androidx.core.app.NotificationManagerCompat.from(this).notify(
                CaptureNotifications.NOTIFICATION_ID,
                CaptureNotifications.build(
                    this,
                    host.currentState(),
                    RootPacketCaptureService::class.java,
                    RootPacketCaptureService.ACTION_STOP,
                    RootPacketCaptureService.EXTRA_SESSION_ID,
                ),
            )
        }
    }

    private fun cleanupForeground() {
        CaptureNotifications.cancel(this)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    private val finishOnce = AtomicBoolean(false)

    companion object {
        const val ACTION_START = "com.floe.android.action.ROOT_CAPTURE_START"
        const val ACTION_STOP = "com.floe.android.action.ROOT_CAPTURE_STOP"
        const val EXTRA_LAUNCH_ID = "launchId"
        const val EXTRA_SESSION_ID = "sessionId"
    }
}
