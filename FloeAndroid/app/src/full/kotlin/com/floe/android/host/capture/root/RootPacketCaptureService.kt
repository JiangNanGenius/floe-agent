// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture.root

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.floe.android.core.networkcapture.CaptureDrainRegistry
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.PcapRecordCounter
import com.floe.android.core.networkcapture.RootCaptureArtifact
import com.floe.android.core.networkcapture.RootCaptureProgress
import com.floe.android.core.networkcapture.RootCaptureRequest
import com.floe.android.core.networkcapture.RootCaptureStart
import com.floe.android.host.capture.CaptureDrainOwner
import com.floe.android.host.capture.CaptureHostController
import com.floe.android.host.capture.CaptureNotifications
import com.floe.android.host.capture.CaptureServiceRuntime
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Foreground owner for the Full-only root capture path.
 *
 * The root helper process, its file, the App chunk reader and the raw artifact
 * each have one owner. This service forwards the backend's real drain proof to
 * the host; when a stop times out it keeps the same session/client/staging
 * file alive and transfers the retry to the process-owned [CaptureDrainOwner].
 * Destroying this Service therefore cannot lose the only retry owner: a later
 * RootStop observes the same ledger entry and the same finalize pass.
 */
class RootPacketCaptureService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var host: CaptureHostController? = null
    private var session: Session? = null
    private var claimedRoot: RootCaptureRequest? = null
    private var settleObserver: Job? = null
    private val foregroundStopped = AtomicBoolean(false)
    @Volatile
    private var destroying = false

    private class Session(
        val request: RootCaptureRequest,
        val artifact: RootCaptureArtifact,
        val counter: PcapRecordCounter,
    ) {
        val ownerToken = Any()
        val finishOnce = AtomicBoolean(false)
        var startJob: Job? = null

        @Volatile
        var retainedTask: CaptureDrainOwner.Task<RootDrainResult>? = null

        @Volatile
        var lastEndReason: CaptureEndReason? = null

        /** False when the terminal path is a failure; never publish complete. */
        @Volatile
        var completionAllowed: Boolean = true
    }

    private data class RootDrainResult(val progress: RootCaptureProgress)

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
        val current = session
        if (current != null) {
            val retained = retainDrain(current, host, CaptureEndReason.SERVICE_DESTROYED)
            if (retained) {
                // Bounded: the retained process owner keeps the same session,
                // backend client, start job and artifact after this returns.
                runBlocking(Dispatchers.IO) {
                    CaptureServiceRuntime.drainOwner()
                        .awaitSettled(current.artifact.sessionId, DESTROY_SETTLE_WAIT_MILLIS)
                }
            }
        }
        claimedRoot?.let { host?.failRootLaunch(it, "serviceDestroyed") }
        claimedRoot = null
        settleObserver?.cancel()
        markForegroundStopped()
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
        if (state.mode != CaptureMode.ROOT ||
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
        CaptureDrainRegistry.shared.register(artifact.sessionId, CaptureMode.ROOT)
        host.onRootStarted(artifact.sessionId, System.currentTimeMillis())
        updateNotification(host, RootCaptureProgress(0, 0, malformed = false))
        value.startJob = scope.launch(Dispatchers.IO) {
            try {
                val backend = host.rootBackendOrNull()
                if (backend == null) {
                    releaseNoRootOwner(artifact.sessionId)
                    finish(
                        host,
                        value,
                        CaptureEndReason.HELPER_UNAVAILABLE,
                        proof = false,
                        writerJoined = true,
                    )
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
                when (result) {
                    is RootCaptureStart.Completed -> {
                        val progress = result.progress.copy(
                            endReason = result.progress.endReason ?: value.lastEndReason,
                        )
                        if (progress.drainProven) markRootDrained(artifact.sessionId)
                        val failedDataPlane =
                            progress.endReason == CaptureEndReason.DATA_PLANE_ERROR
                        if (failedDataPlane) {
                            // A genuine helper/data-plane failure (including a
                            // daemon-loss recovery tombstone) is never
                            // published as a complete capture, even though the
                            // resource ledger is settled.
                            value.completionAllowed = false
                        }
                        finish(
                            host,
                            value,
                            progress.endReason ?: CaptureEndReason.USER_STOP,
                            proof = progress.drainProven && !progress.malformed &&
                                !failedDataPlane,
                            writerJoined = true,
                            drainSettled = progress.drainProven,
                        )
                        stopSelf()
                    }
                    is RootCaptureStart.Started -> {
                        // A stop owns the drain. Leave the session/client/file
                        // untouched for stopInternal.
                    }
                    is RootCaptureStart.Unavailable -> {
                        val reason = when {
                            result.code.startsWith("helper") -> CaptureEndReason.HELPER_UNAVAILABLE
                            result.code.startsWith("root") ||
                                result.code.startsWith("service") -> CaptureEndReason.PERMISSION_REVOKED
                            else -> CaptureEndReason.DATA_PLANE_ERROR
                        }
                        stopInternal(reason, completionAllowed = false)
                    }
                    is RootCaptureStart.Failed -> {
                        stopInternal(
                            if (result.code.startsWith("helper")) {
                                CaptureEndReason.HELPER_UNAVAILABLE
                            } else {
                                CaptureEndReason.DATA_PLANE_ERROR
                            },
                            completionAllowed = false,
                        )
                    }
                }
            } catch (_: Throwable) {
                // A throw may happen after the helper started. Keep the
                // session/client and let the stop drain prove process exit.
                // If no backend exists at all, there is no root owner to wait
                // for and the artifact can be closed with an honest failure.
                if (session === value) {
                    if (host.rootBackendOrNull() == null) {
                        releaseNoRootOwner(artifact.sessionId)
                        finish(
                            host,
                            value,
                            CaptureEndReason.DATA_PLANE_ERROR,
                            proof = false,
                            writerJoined = true,
                        )
                        stopSelf()
                    } else {
                        stopInternal(CaptureEndReason.DATA_PLANE_ERROR, false)
                    }
                }
            }
        }
    }

    private fun stopInternal(reason: CaptureEndReason, completionAllowed: Boolean = true) {
        val value = session ?: run {
            claimedRoot?.let { host?.failRootLaunch(it, "serviceStopped") }
            claimedRoot = null
            stopSelf()
            return
        }
        if (!completionAllowed) value.completionAllowed = false
        host?.onServiceStopRequested(value.artifact.sessionId, reason)
        if (!retainDrain(value, host, reason)) return
        if (settleObserver?.isActive != true) {
            settleObserver = scope.launch(Dispatchers.Default) {
                val owner = CaptureServiceRuntime.drainOwner()
                while (owner.isRetained(value.artifact.sessionId)) {
                    delay(CaptureLimits.DRAIN_RETRY_MILLIS)
                }
                markForegroundStopped()
                if (this@RootPacketCaptureService.session === value) {
                    this@RootPacketCaptureService.session = null
                }
                if (!destroying) stopSelf()
            }
        }
    }

    /**
     * Transfer the exact Session (same start job, client owner, counter and
     * artifact) to the process owner. A repeated stop is idempotent.
     */
    private fun retainDrain(
        value: Session,
        controller: CaptureHostController?,
        reason: CaptureEndReason,
    ): Boolean {
        value.retainedTask?.let { return true }
        val task = RootDrainTask(value, controller, reason)
        return when (CaptureServiceRuntime.drainOwner().retain(task)) {
            CaptureDrainOwner.Retention.STARTED,
            CaptureDrainOwner.Retention.ALREADY_RETAINED -> {
                value.retainedTask = task
                true
            }
            CaptureDrainOwner.Retention.CONFLICT,
            CaptureDrainOwner.Retention.INVALID_SESSION -> false
        }
    }

    private inner class RootDrainTask(
        private val value: Session,
        private val controller: CaptureHostController?,
        private val reason: CaptureEndReason,
    ) : CaptureDrainOwner.Task<RootDrainResult>() {
        override val sessionId: String = value.artifact.sessionId
        override val mode: CaptureMode = CaptureMode.ROOT
        override val ownerToken: Any = value.ownerToken

        /**
         * Retry the exact backend/client until it proves process exit and the
         * tail read. The start job join bounds the App-side writer: the same
         * artifact is never finalized while that job can still append.
         */
        override suspend fun attempt(): CaptureDrainOwner.Attempt<RootDrainResult> {
            val backend = controller?.rootBackendOrNull()
            val stop = if (backend != null) {
                withTimeoutOrNull(STOP_BUDGET_MILLIS) {
                    withContext(Dispatchers.IO) {
                        runCatching { backend.stop() }.getOrNull()
                    }
                }
            } else {
                null
            }
            val joined = withTimeoutOrNull(JOIN_BUDGET_MILLIS) {
                value.startJob?.join()
                true
            } ?: false
            if (stop?.endReason == CaptureEndReason.DATA_PLANE_ERROR) {
                // Includes the root server's client-lease end: the process is
                // gone but the tail was not consumed, so this is a failure,
                // not a complete capture.
                value.completionAllowed = false
            }
            val drained = joined && (backend == null || stop?.drainProven == true)
            val progress = synchronized(value.counter) {
                RootCaptureProgress(
                    bytes = value.counter.bytes,
                    packets = value.counter.packets,
                    malformed = value.counter.isMalformed,
                    endReason = stop?.endReason ?: value.lastEndReason ?: reason,
                    drainProven = drained,
                )
            }
            CaptureDrainRegistry.shared.update(sessionId) {
                it.copy(
                    stopRequested = true,
                    rootStartJobJoined = joined,
                    rootProcessExited = drained,
                    rootFileOwnerClosed = drained,
                    rootDrainProven = drained,
                )
            }
            return if (drained) {
                CaptureDrainOwner.Attempt(true, RootDrainResult(progress))
            } else {
                CaptureDrainOwner.Attempt(
                    settled = false,
                    failure = stop?.endReason?.wire ?: "stopNotProven",
                )
            }
        }

        override fun finalize(value: RootDrainResult) {
            finish(
                controller,
                this.value,
                value.progress.endReason ?: reason,
                proof = this.value.completionAllowed && !value.progress.malformed,
                writerJoined = true,
                drainSettled = true,
            )
            markForegroundStopped()
            if (controller == null) {
                CaptureDrainRegistry.shared.completeAfterFinalize(sessionId)
            }
        }
    }

    private fun finish(
        controller: CaptureHostController?,
        value: Session,
        reason: CaptureEndReason,
        proof: Boolean,
        writerJoined: Boolean,
        drainSettled: Boolean = false,
    ) {
        // Use the exact controller captured by the finalizing owner; the
        // Service field is already null after onDestroy, but the artifact must
        // still be finalized through the Application-owned host.
        val host = controller ?: return
        if (!writerJoined) return
        if (!value.finishOnce.compareAndSet(false, true)) {
            // A natural completion already handed the one finalize to the
            // host; make sure the ledger is removed now that this attempt has
            // proved the resource fields (completeAfterFinalize fails closed
            // while anything is still outstanding).
            if (drainSettled) {
                CaptureDrainRegistry.shared.completeAfterFinalize(value.artifact.sessionId)
            }
            return
        }
        val progress = synchronized(value.counter) {
            val counted = value.counter.finish()
            RootCaptureProgress(
                bytes = counted.bytes,
                packets = counted.packets,
                malformed = counted.malformed,
                endReason = reason,
                drainProven = proof,
            )
        }
        runCatching { value.artifact.flush() }
        host.onRootStopped(
            value.request,
            value.artifact,
            progress,
            reason,
            proof,
            writerJoined,
            drainSettled,
        )
        if (session === value) session = null
    }

    private fun markRootDrained(sessionId: String) {
        CaptureDrainRegistry.shared.update(sessionId) {
            it.copy(
                stopRequested = true,
                rootStartJobJoined = true,
                rootProcessExited = true,
                rootFileOwnerClosed = true,
                rootDrainProven = true,
            )
        }
    }

    /** No helper process ever existed; remove only a resource-free ledger. */
    private fun releaseNoRootOwner(sessionId: String) {
        CaptureDrainRegistry.shared.update(sessionId) {
            it.copy(
                stopRequested = true,
                rootStartJobJoined = true,
                rootProcessExited = true,
                rootFileOwnerClosed = true,
                rootDrainProven = true,
            )
        }
    }

    private fun updateNotification(host: CaptureHostController?, progress: RootCaptureProgress) {
        if (host == null || !CaptureNotifications.isAllowed(this)) return
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

    private fun markForegroundStopped() {
        if (!foregroundStopped.compareAndSet(false, true)) return
        runCatching { CaptureNotifications.cancel(this) }
        runCatching { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
    }

    companion object {
        const val ACTION_START = "com.floe.android.action.ROOT_CAPTURE_START"
        const val ACTION_STOP = "com.floe.android.action.ROOT_CAPTURE_STOP"
        const val EXTRA_LAUNCH_ID = "launchId"
        const val EXTRA_SESSION_ID = "sessionId"

        /** Service.onDestroy is bounded; the process owner continues after it. */
        private const val DESTROY_SETTLE_WAIT_MILLIS = 1_500L
        private const val STOP_BUDGET_MILLIS = 14_000L
        private const val JOIN_BUDGET_MILLIS = 2_000L
    }
}
