// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.content.Context
import android.content.Intent
import android.net.VpnService
import com.floe.android.core.networkcapture.CaptureAnalysisPublisher
import com.floe.android.core.networkcapture.CaptureAnalysisResult
import com.floe.android.core.networkcapture.CaptureArtifact
import com.floe.android.core.networkcapture.CaptureArtifactResult
import com.floe.android.core.networkcapture.CaptureArtifactStore
import com.floe.android.core.networkcapture.CaptureConfig
import com.floe.android.core.networkcapture.CaptureDrainRegistry
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureFailure
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureOwner
import com.floe.android.core.networkcapture.CapturePhase
import com.floe.android.core.networkcapture.CaptureSinkSummary
import com.floe.android.core.networkcapture.CaptureState
import com.floe.android.core.networkcapture.CaptureStateMachine
import com.floe.android.core.networkcapture.CaptureStats
import com.floe.android.core.networkcapture.CaptureStopProof
import com.floe.android.core.networkcapture.PcapCaptureSink
import com.floe.android.core.networkcapture.RootCaptureAvailability
import com.floe.android.core.networkcapture.RootCaptureBackend
import com.floe.android.core.networkcapture.RootCaptureProgress
import com.floe.android.core.networkcapture.RootCaptureRequest
import com.floe.android.core.networkcapture.RootCaptureStart
import com.floe.android.core.networkcapture.RawCaptureExporter
import com.floe.android.core.networkcapture.RawCaptureLibrary
import com.floe.android.core.networkcapture.RawCaptureRecord
import com.floe.android.core.networkcapture.RawExportOutcome
import com.floe.android.core.networkcapture.RawExportSink
import com.floe.android.core.networkcapture.VpnPlan
import com.floe.android.core.pcap.PcapAnalysisStore
import com.floe.android.feature.network.RawCaptureExportReceiptUi
import com.floe.android.feature.network.RawCaptureItemUi
import com.floe.android.feature.network.RawCaptureLibraryUiState
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

sealed interface CaptureStartPreparation {
    data class ConsentRequired(val sessionId: String, val intent: Intent) : CaptureStartPreparation
    data class Started(val sessionId: String) : CaptureStartPreparation
    data class AlreadyActive(val sessionId: String) : CaptureStartPreparation
    data class Unsupported(val availability: RootCaptureAvailability) : CaptureStartPreparation
    data class Refused(val code: String) : CaptureStartPreparation
}

data class CaptureLaunch(
    val launchId: String,
    val sessionId: String,
    val config: CaptureConfig,
    val plan: VpnPlan,
    val artifact: CaptureArtifact,
    val expiresAtMillis: Long,
)

/** One explicit SAF CreateDocument hand-off; stale generations are rejected. */
data class RawExportPreparation(
    val requestId: String,
    val sessionId: String,
    val suggestedName: String,
    internal val generation: Long,
)

private data class PendingRawExport(
    val requestId: String,
    val sessionId: String,
    val suggestedName: String,
    val generation: Long,
    val requestedAtMillis: Long,
)

private data class PendingConsent(
    val sessionId: String,
    val launchId: String,
    val config: CaptureConfig,
    val plan: VpnPlan,
    val expiresAtMillis: Long,
)

/**
 * Application-scoped live capture owner.
 *
 * UI calls are admitted only for a visible user action. The controller owns
 * the launch ticket, state machine, raw artifact and analysis publication; the
 * foreground service owns the real TUN fd, data-plane thread, forwarders and
 * notification. View destruction does not stop capture; an explicit Stop,
 * system revoke, service destruction or RootStop drains it.
 */
class CaptureHostController internal constructor(
    context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val workspaceIdProvider: () -> String? = { null },
    private val taskIdProvider: () -> String? = { null },
    private val runIdProvider: () -> String? = { null },
    private val projectIdProvider: () -> String? = { null },
    private val environmentIdProvider: () -> String? = { null },
    private val jobIdProvider: () -> String? = { null },
    private val onPcapPublished: () -> Unit = {},
    private val rootBackend: RootCaptureBackend? = RootCaptureBackendLoader.load(context),
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val appContext = context.applicationContext
    private val ownerNonce = UUID.randomUUID().toString()
    private val store = CaptureArtifactStore(File(appContext.filesDir, "packet-captures"))
    private val captureDirectory = File(appContext.filesDir, "packet-captures")
    private val analysisPublisher = CaptureAnalysisPublisher(
        PcapAnalysisStore(File(appContext.filesDir, "network-artifacts/pcap")),
    )
    private val rawLibrary = RawCaptureLibrary(captureDirectory)
    private val rawExporter = RawCaptureExporter()
    private val drainRegistry = CaptureDrainRegistry.shared
    private val machine = CaptureStateMachine()
    private val lock = Any()
    private val mutableState = MutableStateFlow(CaptureState())
    val state: StateFlow<CaptureState> = mutableState.asStateFlow()
    private val mutableRawState = MutableStateFlow(RawCaptureLibraryUiState())
    val rawState: StateFlow<RawCaptureLibraryUiState> = mutableRawState.asStateFlow()

    private val pendingConsent = LinkedHashMap<String, PendingConsent>()
    private val pendingLaunches = LinkedHashMap<String, CaptureLaunch>()
    private val finishJobs = LinkedHashSet<Job>()
    private var activeLaunch: CaptureLaunch? = null
    private var finishInProgress = false
    private var pendingRawExport: PendingRawExport? = null
    private var rawExportGeneration = 0L
    private var rawExportJob: Job? = null
    private val rawExportCancelled = AtomicBoolean(false)

    fun enter() {
        // A capture is service-owned; opening the panel never starts/stops it.
    }

    fun leave() {
        // Explicitly do not stop: view lifetime is not capture lifetime.
    }

    fun rootAvailability(): RootCaptureAvailability =
        rootBackend?.availability() ?: RootCaptureAvailability.playBuild()

    fun requestVpnStart(detailed: Boolean, durationMinutes: Int): CaptureStartPreparation {
        val config = buildConfig(CaptureMode.VPN, detailed, durationMinutes)
            ?: return CaptureStartPreparation.Refused("invalidLimits")
        synchronized(lock) {
            mutableState.value.sessionId?.takeIf { mutableState.value.isActive }?.let {
                return CaptureStartPreparation.AlreadyActive(it)
            }
            val consent = try {
                VpnService.prepare(appContext)
            } catch (_: Throwable) {
                mutableState.value = machine.fail(
                    mutableState.value,
                    CaptureFailure("vpnPrepareFailed"),
                    CaptureEndReason.DATA_PLANE_ERROR,
                    atMillis = now(),
                )
                return CaptureStartPreparation.Refused("vpnPrepareFailed")
            }
            val sessionId = UUID.randomUUID().toString()
            val launchId = UUID.randomUUID().toString()
            val plan = VpnPlan.fromConfig(config, appContext.packageName)
            mutableState.value = machine.begin(
                current = mutableState.value,
                owner = config.owner,
                mode = CaptureMode.VPN,
                sessionId = sessionId,
                launchId = launchId,
                requiresConsent = consent != null,
            )
            if (consent != null) {
                pendingConsent[sessionId] = PendingConsent(
                    sessionId = sessionId,
                    launchId = launchId,
                    config = config,
                    plan = plan,
                    expiresAtMillis = now() + 5L * 60L * 1000L,
                )
                return CaptureStartPreparation.ConsentRequired(sessionId, consent)
            }
            return startVpnLaunch(sessionId, launchId, config, plan)
        }
    }

    fun onConsentResult(sessionId: String, granted: Boolean): CaptureStartPreparation {
        val pending = synchronized(lock) {
            val value = pendingConsent.remove(sessionId) ?: return CaptureStartPreparation.Refused(
                "consentExpired",
            )
            if (value.expiresAtMillis < now()) {
                mutableState.value = machine.requestStop(
                    mutableState.value, CaptureEndReason.USER_CANCELLED, now(),
                )
                return CaptureStartPreparation.Refused("consentExpired")
            }
            value
        }
        if (!granted) {
            mutableState.value = machine.requestStop(
                mutableState.value, CaptureEndReason.USER_CANCELLED, now(),
            )
            return CaptureStartPreparation.Refused("consentDenied")
        }
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId ||
                mutableState.value.phase != CapturePhase.CONSENT_REQUIRED
            ) {
                return CaptureStartPreparation.Refused("consentExpired")
            }
            mutableState.value = machine.markStarting(mutableState.value)
            return startVpnLaunchLocked(pending.sessionId, pending.launchId, pending.config, pending.plan)
        }
    }

    fun requestRootStart(detailed: Boolean, durationMinutes: Int): CaptureStartPreparation {
        val backend = rootBackend ?: return CaptureStartPreparation.Unsupported(
            RootCaptureAvailability.playBuild(),
        )
        val availability = backend.availability()
        if (!availability.available) {
            synchronized(lock) {
                mutableState.value = CaptureState.unsupported(
                    CaptureFailure(availability.code ?: "rootUnavailable", availability.message),
                    CaptureMode.ROOT,
                )
            }
            return CaptureStartPreparation.Unsupported(availability)
        }
        val config = buildConfig(CaptureMode.ROOT, detailed, durationMinutes)
            ?: return CaptureStartPreparation.Refused("invalidLimits")
        synchronized(lock) {
            mutableState.value.sessionId?.takeIf { mutableState.value.isActive }?.let {
                return CaptureStartPreparation.AlreadyActive(it)
            }
            val sessionId = UUID.randomUUID().toString()
            val launchId = UUID.randomUUID().toString()
            mutableState.value = machine.begin(
                current = mutableState.value,
                owner = config.owner,
                mode = CaptureMode.ROOT,
                sessionId = sessionId,
                launchId = launchId,
                requiresConsent = false,
            ).copy(ipv6Bypass = false)
            val request = RootCaptureRequest(owner = config.owner, config = config)
            pendingRootLaunches[launchId] = request to (now() + 60_000L)
            val intent = Intent()
                .setClassName(appContext, RootCaptureBackendLoader.FULL_SERVICE_CLASS)
                .setAction(ROOT_SERVICE_ACTION_START)
                .putExtra(ROOT_SERVICE_EXTRA_LAUNCH_ID, launchId)
            return try {
                androidx.core.content.ContextCompat.startForegroundService(appContext, intent)
                CaptureStartPreparation.Started(sessionId)
            } catch (_: Throwable) {
                pendingRootLaunches.remove(launchId)
                mutableState.value = machine.fail(
                    mutableState.value,
                    CaptureFailure("rootServiceStartFailed"),
                    CaptureEndReason.DATA_PLANE_ERROR,
                    atMillis = now(),
                )
                CaptureStartPreparation.Refused("rootServiceStartFailed")
            }
        }
    }

    fun stop(sessionId: String) {
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId) return
            val phase = mutableState.value.phase
            if (phase == CapturePhase.CONSENT_REQUIRED) {
                pendingConsent.remove(sessionId)
                mutableState.value = machine.requestStop(
                    mutableState.value, CaptureEndReason.USER_CANCELLED, now(),
                )
                return
            }
            if (phase == CapturePhase.RUNNING || phase == CapturePhase.STOPPING ||
                phase == CapturePhase.STARTING
            ) {
                mutableState.value = machine.requestStop(
                    mutableState.value, CaptureEndReason.USER_STOP, now(),
                )
            }
            val stale = pendingLaunches.values.filter { it.sessionId == sessionId }
            stale.forEach { store.abandon(it.artifact) }
            pendingLaunches.values.removeAll(stale.toSet())
        }
        val mode = mutableState.value.mode
        val intent = if (mode == CaptureMode.ROOT) {
            Intent()
                .setClassName(appContext, RootCaptureBackendLoader.FULL_SERVICE_CLASS)
                .setAction(ROOT_SERVICE_ACTION_STOP)
                .putExtra(ROOT_SERVICE_EXTRA_SESSION_ID, sessionId)
        } else {
            Intent(appContext, VpnPacketCaptureService::class.java)
                .setAction(VpnPacketCaptureService.ACTION_STOP)
                .putExtra(VpnPacketCaptureService.EXTRA_SESSION_ID, sessionId)
        }
        runCatching { appContext.startService(intent) }
    }

    fun onServiceStopRequested(sessionId: String, reason: CaptureEndReason) {
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId) return
            if (mutableState.value.phase == CapturePhase.RUNNING ||
                mutableState.value.phase == CapturePhase.STOPPING
            ) {
                mutableState.value = machine.requestStop(mutableState.value, reason, now())
            }
        }
    }

    fun onVpnStarted(launch: CaptureLaunch, startedAtMillis: Long) {
        synchronized(lock) {
            if (mutableState.value.sessionId != launch.sessionId) return
            activeLaunch = launch
            runCatching {
                mutableState.value = machine.markRunning(mutableState.value, startedAtMillis)
            }
        }
    }

    fun onVpnStats(sessionId: String, stats: CaptureStats) {
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId) return
            if (mutableState.value.phase == CapturePhase.RUNNING ||
                mutableState.value.phase == CapturePhase.STOPPING
            ) {
                runCatching { machine.updateStats(mutableState.value, stats) }
                    .onSuccess { mutableState.value = it }
            }
        }
    }

    fun failLaunch(launch: CaptureLaunch, code: String) {
        synchronized(lock) {
            if (activeLaunch === launch) activeLaunch = null
            pendingLaunches.remove(launch.launchId)
            store.abandon(launch.artifact)
            if (mutableState.value.sessionId != launch.sessionId) return
            mutableState.value = machine.fail(
                mutableState.value,
                CaptureFailure(code),
                CaptureEndReason.DATA_PLANE_ERROR,
                atMillis = now(),
            )
        }
    }

    /**
     * Service teardown result. The raw file is finalized before analysis; an
     * incomplete drain is preserved as a partial capture and is never
     * reported as a successful stop.
     */
    fun onVpnStopped(
        launch: CaptureLaunch,
        sink: CaptureSinkSummary,
        dataPlaneProof: DataPlaneProof,
        reason: CaptureEndReason,
        dataPlaneFailure: String?,
    ) {
        val proofComplete = dataPlaneProof.forwardersStopped &&
            dataPlaneProof.threadStopped && dataPlaneProof.vpnFdClosed &&
            sink.drained && !launch.artifact.sink.isWriterAlive()
        synchronized(lock) {
            if (mutableState.value.sessionId != launch.sessionId) {
                store.abandon(launch.artifact)
                // Preserve the ledger only for a real live owner; abandon
                // already kept a live writer's staging file.
                drainRegistry.completeAfterFinalize(launch.sessionId)
                return
            }
            if (activeLaunch === launch) activeLaunch = null
            if (mutableState.value.phase == CapturePhase.RUNNING) {
                mutableState.value = machine.requestStop(mutableState.value, reason, now())
            }
            if (mutableState.value.phase == CapturePhase.STOPPING) {
                mutableState.value = machine.markFinalizing(mutableState.value)
            }
            if (finishInProgress) return
            finishInProgress = true
        }
        val job = scope.launch(ioDispatcher, start = kotlinx.coroutines.CoroutineStart.LAZY) {
            // The service only calls this after its real drain, but a late
            // writer/owner must still never be closed by the store. Wait for
            // the same sink thread; if it stays alive this job remains owned
            // and RootStop stays blocked instead of publishing a torn file.
            awaitSinkWriter(launch.artifact.sink)
            val result = try {
                store.finalize(
                    artifact = launch.artifact,
                    sink = sink,
                    state = mutableState.value,
                    startedAtMillis = mutableState.value.startedAtMillis,
                    endedAtMillis = now(),
                    limitations = limitationsFor(mutableState.value.stats, sink),
                    stopProven = proofComplete,
                )
            } catch (_: Throwable) {
                null
            }
            val analysis = result?.let {
                analysisPublisher.publish(
                    owner = launch.config.owner,
                    result = it,
                    detailed = launch.config.detailed,
                )
            } ?: CaptureAnalysisResult(
                analysisId = null,
                failure = CaptureFailure("artifactFinalizeFailed"),
                summaryStatus = null,
                limitations = emptyList(),
            )
            synchronized(lock) {
                finishInProgress = false
                val current = mutableState.value
                if (current.sessionId != launch.sessionId) return@launch
                // The staging artifact has now been finalized (or preserved
                // as partial). Remove the ledger entry only when every real
                // resource owner already settled; a late writer keeps it.
                drainRegistry.completeAfterFinalize(launch.sessionId)
                val failure = when {
                    dataPlaneFailure != null -> CaptureFailure(dataPlaneFailure)
                    sink.failure != null -> sink.failure
                    !proofComplete -> CaptureFailure("stopNotProven")
                    else -> analysis.failure
                }
                val canComplete = failure == null && result != null && result.partial == false &&
                    current.phase == CapturePhase.FINALIZING
                mutableState.value = if (canComplete) {
                    runCatching {
                        machine.complete(
                        current = current,
                        analysisId = analysis.analysisId,
                        rawCaptureId = result!!.sessionId,
                        stats = current.stats.copy(
                            writtenPackets = sink.writtenPackets,
                            writtenBytes = sink.writtenBytes,
                            capturedPackets = sink.capturedPackets,
                            capturedBytes = sink.capturedBytes,
                            droppedPackets = sink.droppedPackets,
                            droppedBytes = sink.droppedBytes,
                            truncatedPackets = sink.truncatedPackets,
                            unsupportedPackets = sink.unsupportedPackets,
                            ipv6BypassedPackets = sink.ipv6BypassedPackets,
                        ),
                        limitations = limitationsFor(current.stats, sink),
                        proof = CaptureStopProof(
                            stopRequested = true,
                            forwardersStopped = dataPlaneProof.forwardersStopped,
                            dataPlaneThreadStopped = dataPlaneProof.threadStopped,
                            sinkDrained = sink.drained,
                            vpnFdClosed = dataPlaneProof.vpnFdClosed,
                            foregroundServiceStopped = dataPlaneProof.foregroundServiceStopped,
                            sinkWriterJoined = !launch.artifact.sink.isWriterAlive(),
                            mode = CaptureMode.VPN,
                        ),
                        atMillis = now(),
                        )
                    }.getOrElse {
                        machine.fail(
                            current = current,
                            failure = CaptureFailure("stopNotProven"),
                            reason = reason,
                            stats = current.stats,
                            limitations = limitationsFor(current.stats, sink),
                            atMillis = now(),
                        ).copy(analysisId = analysis.analysisId, rawCaptureId = result?.sessionId)
                    }
                } else {
                    machine.fail(
                        current = current,
                        failure = failure ?: CaptureFailure("captureIncomplete"),
                        reason = reason,
                        stats = current.stats.copy(
                            writtenPackets = sink.writtenPackets,
                            writtenBytes = sink.writtenBytes,
                            capturedPackets = sink.capturedPackets,
                            capturedBytes = sink.capturedBytes,
                            droppedPackets = sink.droppedPackets,
                            droppedBytes = sink.droppedBytes,
                            truncatedPackets = sink.truncatedPackets,
                            unsupportedPackets = sink.unsupportedPackets,
                            ipv6BypassedPackets = sink.ipv6BypassedPackets,
                        ),
                        limitations = limitationsFor(current.stats, sink),
                        atMillis = now(),
                    ).copy(analysisId = analysis.analysisId, rawCaptureId = result?.sessionId)
                }
            }
            if (analysis.analysisId != null) onPcapPublished()
            refreshRawCaptures()
        }
        synchronized(lock) { finishJobs.add(job) }
        job.invokeOnCompletion { synchronized(lock) { finishJobs.remove(job) } }
        job.start()
    }

    fun claimLaunch(launchId: String): CaptureLaunch? {
        return synchronized(lock) {
            val value = pendingLaunches.remove(launchId) ?: return null
            if (value.expiresAtMillis < now()) {
                store.abandon(value.artifact)
                if (mutableState.value.sessionId == value.sessionId) {
                    mutableState.value = machine.fail(
                        mutableState.value,
                        CaptureFailure("launchExpired"),
                        CaptureEndReason.DATA_PLANE_ERROR,
                        atMillis = now(),
                    )
                }
                return null
            }
            if (mutableState.value.sessionId != value.sessionId ||
                mutableState.value.phase == CapturePhase.CANCELLED ||
                mutableState.value.phase == CapturePhase.FAILED ||
                mutableState.value.phase == CapturePhase.COMPLETED
            ) {
                store.abandon(value.artifact)
                return null
            }
            value
        }
    }

    fun claimRootLaunch(launchId: String): RootCaptureRequest? {
        // Root sessions are started by RootPacketCaptureService; the service
        // asks the controller for the exact validated request, not a raw path.
        return synchronized(lock) {
            val value = pendingRootLaunches.remove(launchId) ?: return null
            if (value.second < now()) return null
            value.first
        }
    }

    fun rootBackendOrNull(): RootCaptureBackend? = rootBackend

    fun failRootLaunch(request: RootCaptureRequest, code: String) {
        synchronized(lock) {
            if (mutableState.value.mode != CaptureMode.ROOT || mutableState.value.phase.isTerminal) return
            mutableState.value = machine.fail(
                mutableState.value,
                CaptureFailure(code),
                when (code) {
                    "notificationsDisabled", "permissionRevoked" -> CaptureEndReason.PERMISSION_REVOKED
                    "helperUnavailable" -> CaptureEndReason.HELPER_UNAVAILABLE
                    else -> CaptureEndReason.DATA_PLANE_ERROR
                },
                atMillis = now(),
            )
        }
    }

    fun beginRootArtifact(request: RootCaptureRequest): com.floe.android.core.networkcapture.RootCaptureArtifact? {
        val sessionId = mutableState.value.sessionId ?: return null
        return try {
            store.beginRoot(
                sessionId = sessionId,
                owner = request.owner,
                maxDurationMillis = request.config.maxDurationMillis,
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun onRootStarted(sessionId: String, startedAtMillis: Long) {
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId) return
            runCatching {
                mutableState.value = machine.markRunning(mutableState.value, startedAtMillis)
            }
        }
    }

    fun onRootStopped(
        request: RootCaptureRequest,
        artifact: com.floe.android.core.networkcapture.RootCaptureArtifact,
        progress: RootCaptureProgress,
        reason: CaptureEndReason,
        proofComplete: Boolean,
        writerJoined: Boolean,
        drainSettled: Boolean,
    ) {
        if (!writerJoined) return
        synchronized(lock) {
            if (mutableState.value.sessionId != artifact.sessionId) {
                store.abandonRoot(artifact)
                drainRegistry.completeAfterFinalize(artifact.sessionId)
                return
            }
            if (mutableState.value.phase == CapturePhase.RUNNING) {
                mutableState.value = machine.requestStop(mutableState.value, reason, now())
            }
            if (mutableState.value.phase == CapturePhase.STOPPING) {
                mutableState.value = machine.markFinalizing(mutableState.value)
            }
            if (finishInProgress) return
            finishInProgress = true
        }
        val job = scope.launch(ioDispatcher, start = kotlinx.coroutines.CoroutineStart.LAZY) {
            val result = try {
                store.finalizeRoot(
                    artifact = artifact,
                    progress = progress,
                    state = mutableState.value,
                    startedAtMillis = mutableState.value.startedAtMillis,
                    endedAtMillis = now(),
                    limitations = rootLimitations(progress),
                    stopProven = proofComplete,
                    writerJoined = writerJoined,
                )
            } catch (_: Throwable) {
                null
            }
            val analysis = result?.let {
                analysisPublisher.publish(
                    owner = request.owner,
                    result = it,
                    detailed = request.config.detailed,
                )
            } ?: CaptureAnalysisResult(
                analysisId = null,
                failure = CaptureFailure("artifactFinalizeFailed"),
                summaryStatus = null,
                limitations = emptyList(),
            )
            synchronized(lock) {
                finishInProgress = false
                val current = mutableState.value
                if (current.sessionId != artifact.sessionId) return@launch
                // Finalize already ran for the same staging artifact. The
                // ledger removes only after process/file/start-join settled.
                drainRegistry.completeAfterFinalize(artifact.sessionId)
                val failure = when {
                    progress.malformed -> CaptureFailure("pcapMalformed")
                    progress.endReason == CaptureEndReason.HELPER_UNAVAILABLE ->
                        CaptureFailure("helperUnavailable")
                    !proofComplete -> CaptureFailure("stopNotProven")
                    else -> analysis.failure
                }
                val canComplete = failure == null && result != null &&
                    !result.partial && drainSettled &&
                    current.phase == CapturePhase.FINALIZING
                mutableState.value = if (canComplete) {
                    runCatching {
                        machine.complete(
                            current = current,
                            analysisId = analysis.analysisId,
                            rawCaptureId = result!!.sessionId,
                            stats = current.stats.copy(
                                capturedPackets = progress.packets,
                                capturedBytes = progress.bytes,
                                writtenPackets = progress.packets,
                                writtenBytes = progress.bytes,
                            ),
                            limitations = rootLimitations(progress),
                            proof = CaptureStopProof(
                                stopRequested = true,
                                sinkDrained = drainSettled,
                                sinkWriterJoined = writerJoined,
                                mode = CaptureMode.ROOT,
                                rootProcessExited = drainSettled,
                                rootFileOwnerClosed = drainSettled,
                                rootDrainProven = drainSettled,
                            ),
                            atMillis = now(),
                        )
                    }.getOrElse {
                        machine.fail(
                            current, CaptureFailure("stopNotProven"), reason,
                            stats = current.stats, atMillis = now(),
                        ).copy(analysisId = analysis.analysisId, rawCaptureId = result?.sessionId)
                    }
                } else {
                    machine.fail(
                        current,
                        failure ?: CaptureFailure("captureIncomplete"),
                        reason,
                        stats = current.stats.copy(
                            capturedPackets = progress.packets,
                            capturedBytes = progress.bytes,
                            writtenPackets = progress.packets,
                            writtenBytes = progress.bytes,
                        ),
                        limitations = rootLimitations(progress),
                        atMillis = now(),
                    ).copy(analysisId = analysis.analysisId, rawCaptureId = result?.sessionId)
                }
            }
            if (analysis.analysisId != null) onPcapPublished()
            refreshRawCaptures()
        }
        synchronized(lock) { finishJobs.add(job) }
        job.invokeOnCompletion { synchronized(lock) { finishJobs.remove(job) } }
        job.start()
    }

    fun onRootProgress(sessionId: String, progress: RootCaptureProgress) {
        synchronized(lock) {
            if (mutableState.value.sessionId != sessionId) return
            if (mutableState.value.phase == CapturePhase.RUNNING ||
                mutableState.value.phase == CapturePhase.STOPPING
            ) {
                runCatching {
                    machine.updateStats(
                        mutableState.value,
                        mutableState.value.stats.copy(
                            capturedPackets = progress.packets,
                            capturedBytes = progress.bytes,
                            writtenPackets = progress.packets,
                            writtenBytes = progress.bytes,
                        ),
                    )
                }.onSuccess { mutableState.value = it }
            }
        }
    }

    /**
     * RootStop gate. It cancels any picker/export and waits for the owned
     * raw-copy job, then requests the capture stop and waits for both the
     * terminal/finalize jobs and the real drain ledger. A false result keeps
     * the old root generation pending; a later RootStop retries the same
     * owned drain rather than replaying the capture.
     */
    suspend fun prepareForRootStop(epoch: Long, waitMillis: Long): Boolean {
        require(waitMillis > 0) { "timeout" }
        // A SAF picker callback that arrives after retirement must not write.
        synchronized(lock) {
            rawExportGeneration += 1
            pendingRawExport = null
        }
        rawExportCancelled.set(true)
        if (!awaitRawExportIdle(waitMillis)) return false
        val activeSession = synchronized(lock) {
            pendingConsent.clear()
            pendingRootLaunches.clear()
            pendingLaunches.values.forEach { store.abandon(it.artifact) }
            pendingLaunches.clear()
            val current = mutableState.value
            val canRequestStop = current.phase == CapturePhase.RUNNING ||
                current.phase == CapturePhase.STOPPING ||
                current.phase == CapturePhase.STARTING ||
                current.phase == CapturePhase.CONSENT_REQUIRED
            if (canRequestStop && current.sessionId != null) {
                mutableState.value = machine.requestStop(
                    current, CaptureEndReason.ROOT_STOP, now(),
                )
            }
            current.sessionId?.takeIf {
                current.phase == CapturePhase.RUNNING || current.phase == CapturePhase.STOPPING ||
                    current.phase == CapturePhase.FINALIZING
            }
        }
        if (activeSession != null) {
            val mode = mutableState.value.mode
            val intent = if (mode == CaptureMode.ROOT) {
                Intent()
                    .setClassName(appContext, RootCaptureBackendLoader.FULL_SERVICE_CLASS)
                    .setAction(ROOT_SERVICE_ACTION_STOP)
                    .putExtra(ROOT_SERVICE_EXTRA_SESSION_ID, activeSession)
            } else {
                Intent(appContext, VpnPacketCaptureService::class.java)
                    .setAction(VpnPacketCaptureService.ACTION_STOP)
                    .putExtra(VpnPacketCaptureService.EXTRA_SESSION_ID, activeSession)
            }
            runCatching { appContext.startService(intent) }
        }
        return try {
            withTimeout(waitMillis) {
                while (true) {
                    val done = synchronized(lock) {
                        val current = mutableState.value
                        val session = current.sessionId ?: activeSession
                        current.phase.isTerminal && activeLaunch == null &&
                            pendingLaunches.isEmpty() && finishJobs.isEmpty() &&
                            !finishInProgress &&
                            (session == null || drainRegistry.isSettled(session))
                    }
                    if (done) return@withTimeout true
                    kotlinx.coroutines.delay(50L)
                }
                @Suppress("UNREACHABLE_CODE")
                false
            }
        } catch (_: TimeoutCancellationException) {
            false
        }
    }

    /** Reload the retained raw-capture manifest projection off the main thread. */
    fun refreshRawCaptures() {
        scope.launch(ioDispatcher) {
            val listing = runCatching { rawLibrary.list() }
                .getOrElse { com.floe.android.core.networkcapture.RawCaptureListing(emptyList(), 1) }
            mutableRawState.update {
                it.copy(
                    captures = listing.records.map { record -> record.toUi() },
                    loading = false,
                    invalid = listing.invalid,
                )
            }
        }
    }

    /**
     * First half of an explicit export: bind one session to one picker
     * generation. The actual copy starts only after the App host receives the
     * user-chosen SAF URI. Stale request ids/generations are rejected.
     */
    fun prepareRawExport(sessionId: String): RawExportPreparation? {
        synchronized(lock) {
            if (rawExportJob?.isActive == true) return null
            val item = mutableRawState.value.captures.firstOrNull { it.sessionId == sessionId }
                ?: return null
            rawExportGeneration += 1
            val generation = rawExportGeneration
            val requestId = UUID.randomUUID().toString()
            val suffix = item.sessionId.take(8)
            val suggestedName = "floe-capture-$suffix-$generation.pcap"
            pendingRawExport = PendingRawExport(
                requestId = requestId,
                sessionId = sessionId,
                suggestedName = suggestedName,
                generation = generation,
                requestedAtMillis = now(),
            )
            return RawExportPreparation(requestId, sessionId, suggestedName, generation)
        }
    }

    fun onRawExportPickerCancelled(requestId: String) {
        synchronized(lock) {
            if (pendingRawExport?.requestId == requestId) pendingRawExport = null
        }
    }

    /**
     * Second half: the SAF URI is already user-created. The request generation,
     * session identity and record integrity are re-checked before any write.
     */
    fun onRawExportPicked(requestId: String, uri: android.net.Uri) {
        val pending = synchronized(lock) {
            val value = pendingRawExport ?: return
            if (value.requestId != requestId ||
                value.generation != rawExportGeneration ||
                now() - value.requestedAtMillis > CaptureLimits.RAW_EXPORT_PICKER_TIMEOUT_MILLIS
            ) {
                pendingRawExport = null
                return
            }
            pendingRawExport = null
            rawExportCancelled.set(false)
            mutableRawState.value = mutableRawState.value.copy(
                exporting = true,
                exportingSessionId = value.sessionId,
                failure = null,
                exported = null,
            )
            value
        }
        val job = scope.launch(ioDispatcher, start = kotlinx.coroutines.CoroutineStart.LAZY) {
            val outcome = try {
                val record = rawLibrary.find(pending.sessionId)
                if (record == null) {
                    RawExportOutcome.Failed("captureNotFound")
                } else {
                    rawExporter.export(
                        record = record,
                        sink = SafRawExportSink(appContext.contentResolver, uri, pending.suggestedName),
                        displayName = pending.suggestedName,
                        checkCancelled = {
                            rawExportCancelled.get() ||
                                synchronized(lock) { rawExportGeneration != pending.generation }
                        },
                    )
                }
            } catch (_: Throwable) {
                RawExportOutcome.Failed("captureExportFailed")
            }
            try {
                synchronized(lock) {
                    mutableRawState.value = when (outcome) {
                        is RawExportOutcome.Success -> mutableRawState.value.copy(
                            exporting = false,
                            exportingSessionId = null,
                            failure = null,
                            exported = RawCaptureExportReceiptUi(
                                sessionId = outcome.receipt.sessionId,
                                bytes = outcome.receipt.bytes,
                                sha256 = outcome.receipt.sha256,
                                partial = outcome.receipt.partial,
                                exportedAtMillis = outcome.receipt.exportedAtMillis,
                                displayName = outcome.receipt.displayName,
                            ),
                        )
                        is RawExportOutcome.Failed -> mutableRawState.value.copy(
                            exporting = false,
                            exportingSessionId = null,
                            failure = com.floe.android.feature.network.NetworkArtifactFailure.EXPORT_FAILED,
                        )
                        RawExportOutcome.Cancelled -> mutableRawState.value.copy(
                            exporting = false,
                            exportingSessionId = null,
                            failure = com.floe.android.feature.network.NetworkArtifactFailure.CANCELLED,
                        )
                    }
                }
            } finally {
                synchronized(lock) { rawExportJob = null }
            }
        }
        rawExportJob = job
        job.start()
    }

    fun cancelRawExport() {
        rawExportCancelled.set(true)
        synchronized(lock) {
            rawExportGeneration += 1
            pendingRawExport = null
        }
    }

    fun currentState(): CaptureState = mutableState.value

    private fun buildConfig(
        mode: CaptureMode,
        detailed: Boolean,
        durationMinutes: Int,
    ): CaptureConfig? {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return null
        val owner = try {
            CaptureOwner(
                ownerId = "packet-capture-ui:$ownerNonce",
                nativeEpoch = epoch,
                taskId = taskIdProvider(),
                runId = runIdProvider(),
                workspaceId = workspaceIdProvider(),
                projectId = projectIdProvider(),
                environmentId = environmentIdProvider(),
                jobId = jobIdProvider(),
            )
        } catch (_: IllegalArgumentException) {
            return null
        }
        val maxDuration = if (mode == CaptureMode.ROOT) {
            CaptureLimits.MAX_ROOT_DURATION_MILLIS
        } else {
            CaptureLimits.MAX_DURATION_MILLIS
        }
        val duration = durationMinutes.coerceIn(1L, maxDuration / 60_000L) * 60_000L
        return try {
            CaptureConfig(
                owner = owner,
                mode = mode,
                detailed = detailed,
                maxDurationMillis = duration,
                maxBytes = if (mode == CaptureMode.ROOT) {
                    CaptureLimits.MAX_ROOT_BYTES
                } else {
                    CaptureLimits.MAX_BYTES
                },
                maxPackets = if (mode == CaptureMode.ROOT) {
                    CaptureLimits.MAX_ROOT_PACKETS
                } else {
                    CaptureLimits.MAX_PACKETS
                },
                mtu = CaptureLimits.DEFAULT_MTU,
                sessionName = "Floe capture",
            )
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun startVpnLaunch(
        sessionId: String,
        launchId: String,
        config: CaptureConfig,
        plan: VpnPlan,
    ): CaptureStartPreparation = synchronized(lock) {
        startVpnLaunchLocked(sessionId, launchId, config, plan)
    }

    private fun startVpnLaunchLocked(
        sessionId: String,
        launchId: String,
        config: CaptureConfig,
        plan: VpnPlan,
    ): CaptureStartPreparation {
        val artifact = try {
            store.begin(
                sessionId = sessionId,
                owner = config.owner,
                mode = CaptureMode.VPN,
                detailed = config.detailed,
                maxBytes = config.maxBytes,
                maxPackets = config.maxPackets,
                maxDurationMillis = config.maxDurationMillis,
            )
        } catch (_: IOException) {
            mutableState.value = machine.fail(
                mutableState.value,
                CaptureFailure("artifactCreateFailed"),
                CaptureEndReason.DATA_PLANE_ERROR,
                atMillis = now(),
            )
            return CaptureStartPreparation.Refused("artifactCreateFailed")
        }
        val launch = CaptureLaunch(
            launchId = launchId,
            sessionId = sessionId,
            config = config,
            plan = plan,
            artifact = artifact,
            expiresAtMillis = now() + 60_000L,
        )
        pendingLaunches[launchId] = launch
        val intent = Intent(appContext, VpnPacketCaptureService::class.java)
            .setAction(VpnPacketCaptureService.ACTION_START)
            .putExtra(VpnPacketCaptureService.EXTRA_LAUNCH_ID, launchId)
        return try {
            androidx.core.content.ContextCompat.startForegroundService(appContext, intent)
            CaptureStartPreparation.Started(sessionId)
        } catch (_: Throwable) {
            pendingLaunches.remove(launchId)
            store.abandon(artifact)
            mutableState.value = machine.fail(
                mutableState.value,
                CaptureFailure("serviceStartFailed"),
                CaptureEndReason.DATA_PLANE_ERROR,
                atMillis = now(),
            )
            CaptureStartPreparation.Refused("serviceStartFailed")
        }
    }

    private val pendingRootLaunches = LinkedHashMap<String, Pair<RootCaptureRequest, Long>>()

    private fun rootLimitations(progress: RootCaptureProgress): List<String> = buildList {
        add("Root capture records the phone's native interfaces, not the Linux guest.")
        add("Encrypted TLS/QUIC traffic is recorded unchanged; payloads remain encrypted.")
        add("IPv4 and IPv6 are captured as the pinned tcpdump helper provides them.")
        add("The root helper is built from pinned sources and verified against this Full package; no arbitrary executable or URL is accepted.")
        if (progress.malformed) add("The PCAP stream was malformed or truncated; the file is partial.")
    }.take(CaptureLimits.MAX_LIMITATIONS)

    private suspend fun awaitSinkWriter(sink: PcapCaptureSink) {
        while (sink.isWriterAlive()) {
            kotlinx.coroutines.delay(CaptureLimits.DRAIN_RETRY_MILLIS)
        }
    }

    private suspend fun awaitRawExportIdle(waitMillis: Long): Boolean {
        val job = synchronized(lock) { rawExportJob } ?: return true
        return try {
            withTimeout(waitMillis) { job.join() }
            true
        } catch (_: TimeoutCancellationException) {
            false
        } catch (_: Throwable) {
            // Cancellation never deletes a source or invents a receipt.
            false
        }
    }

    private fun RawCaptureRecord.toUi(): RawCaptureItemUi = RawCaptureItemUi(
        sessionId = sessionId,
        mode = mode.wire,
        createdAtMillis = createdAtMillis,
        bytes = bytes,
        sha256 = sha256,
        partial = partial,
        endReason = endReason,
    )

    /**
     * SAF adapter. `deleteCreatedDestination` is deliberately conservative:
     * it removes only a newly named file from this request; the original
     * capture and any user file with another name are never touched.
     */
    private class SafRawExportSink(
        private val resolver: android.content.ContentResolver,
        private val uri: android.net.Uri,
        private val expectedName: String,
    ) : RawExportSink {
        override fun openDestination(): OutputStream =
            resolver.openOutputStream(uri, "wt") ?: throw IOException("destinationUnavailable")

        override fun openDestinationForRead(): InputStream =
            resolver.openInputStream(uri) ?: throw IOException("destinationUnavailable")

        override fun deleteCreatedDestination(): Boolean {
            val name = runCatching {
                resolver.query(
                    uri,
                    arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                    null, null, null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
            }.getOrNull()
            if (name != expectedName) return false
            return runCatching {
                android.provider.DocumentsContract.deleteDocument(resolver, uri)
            }.getOrDefault(false)
        }
    }

    private fun limitationsFor(stats: CaptureStats, sink: CaptureSinkSummary): List<String> = buildList {
        add("TLS/QUIC is forwarded unchanged without decryption; captures may contain unencrypted protocol payloads.")
        add("IPv6 traffic bypasses this VPN because no IPv6 route is installed; IPv4 is captured.")
        add("ICMP is not forwarded; ping is outside this capture.")
        add("The Floe app's own traffic is excluded from the VPN.")
        if (sink.droppedPackets > 0) {
            add("${sink.droppedPackets} packets were dropped by the bounded capture queue.")
        }
        if (sink.unsupportedPackets > 0) {
            add("${sink.unsupportedPackets} unsupported protocol packets were not forwarded.")
        }
        if (sink.ipv6BypassedPackets > 0) {
            add("${sink.ipv6BypassedPackets} unexpected IPv6 packets were not forwarded.")
        }
        if (sink.limitReason != null) {
            add("Capture stopped at the configured ${sink.limitReason!!.wire} bound.")
        }
        if (!sink.drained) {
            add("The capture writer did not drain before the stop deadline; the file is partial.")
        }
    }.take(CaptureLimits.MAX_LIMITATIONS)
}

private const val ROOT_SERVICE_ACTION_START = "com.floe.android.action.ROOT_CAPTURE_START"
private const val ROOT_SERVICE_ACTION_STOP = "com.floe.android.action.ROOT_CAPTURE_STOP"
private const val ROOT_SERVICE_EXTRA_LAUNCH_ID = "launchId"
private const val ROOT_SERVICE_EXTRA_SESSION_ID = "sessionId"

/** Small adapter type keeps the App host independent of the service class. */
data class DataPlaneProof(
    val forwardersStopped: Boolean,
    val threadStopped: Boolean,
    val vpnFdClosed: Boolean,
    val foregroundServiceStopped: Boolean,
)
