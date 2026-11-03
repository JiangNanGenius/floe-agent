// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import android.content.Context
import com.floe.android.core.workbenchmedia.MediaDrainReport
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformConfig
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformFactory
import com.floe.android.core.workbenchmedia.WorkbenchMediaSession
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ImagePreviewReceipt
import com.floe.android.feature.workbench.ImagePreviewRequest
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.ProbedAsset
import com.floe.android.feature.workbench.RenderCapabilities
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.host.creative.MediaRenderTicketNativeTransport
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Typed process-scoped availability of the App media platform. */
internal sealed interface MediaWorkbenchPlatformState {
    /** No accepted native epoch has been bound yet. */
    data object Idle : MediaWorkbenchPlatformState

    data class Starting(val epoch: Long) : MediaWorkbenchPlatformState

    data class Ready(
        val epoch: Long,
        val ticketConsumerStarted: Boolean,
        val ticketReason: String? = null,
    ) : MediaWorkbenchPlatformState

    /** A retirement was requested; the session is retained until truly drained. */
    data class Draining(val epoch: Long) : MediaWorkbenchPlatformState

    /** A typed refusal; no fabricated success and no fallback platform. */
    data class Unavailable(val code: String, val reason: String? = null) :
        MediaWorkbenchPlatformState
}

/**
 * ONE process-scoped workbench media platform session over the REAL native
 * authority adapters.
 *
 * Lifecycle rules encoded here:
 *  * a session is created only after the native creative bind accepted the
 *    live epoch; the render-ticket consumer starts only after that bind;
 *  * a session factory is never installed for B while an A session still
 *    reports not-drained; the failed report keeps the A references owned;
 *  * Root background/rotation do not touch this owner; only an actual
 *    root/epoch replacement or process teardown calls [retireForRootStop];
 *  * UI/feature ports resolve the CURRENT session through [platform] on every
 *    call, so a rebind can never leave a stale captured session/root.
 */
internal class MediaWorkbenchPlatformOwner(
    context: Context,
    private val hostProvider: () -> CreativeHostController,
    private val receiptRecorder: MediaWorkbenchReceiptRecorder? = null,
    private val retireTimeoutMillis: Long = DEFAULT_RETIRE_TIMEOUT_MS,
) {
    companion object {
        const val DEFAULT_RETIRE_TIMEOUT_MS = 15_000L
    }

    val epochOwner = MediaWorkbenchEpochOwner(hostProvider)
    val leaseAuthority = MediaWorkbenchLeaseAuthority(hostProvider)
    val recoveryAuthority = MediaWorkbenchRecoveryAuthority(hostProvider)
    val lifecycleAuthority = MediaWorkbenchLifecycleAuthority(hostProvider)

    private val applicationContext = context.applicationContext
    private val mutex = Mutex()
    private val mutableState = MutableStateFlow<MediaWorkbenchPlatformState>(
        MediaWorkbenchPlatformState.Idle)
    val state: StateFlow<MediaWorkbenchPlatformState> = mutableState

    @Volatile
    private var session: WorkbenchMediaSession? = null

    @Volatile
    private var boundEpoch: Long = 0L

    @Volatile
    private var fenced: Boolean = false

    @Volatile
    private var lastDrain: MediaDrainReport? = null

    /** Exact native ticket transport started for the current session. */
    @Volatile
    private var ticketTransport: MediaRenderTicketNativeTransport? = null

    private val generation = AtomicLong(0L)

    /**
     * Lazy live-session facade. Every call resolves the CURRENT owner state;
     * an unbound/fenced platform is a typed retryable refusal, never a dummy
     * renderer or a permanent R1 "unavailable" substitute.
     */
    val platform: WorkbenchMediaPlatform = object : WorkbenchMediaPlatform {
        override fun capabilities(): RenderCapabilities = requireSession().platform.capabilities()

        override fun createPlayer(request: PlaybackRequest): PlaybackHandle =
            requireSession().platform.createPlayer(request)

        override suspend fun probe(request: MediaAssetProbeRequest): ProbedAsset =
            requireSession().platform.probe(request)

        override suspend fun renderImagePreview(
            request: ImagePreviewRequest,
        ): ImagePreviewReceipt = requireSession().platform.renderImagePreview(request)

        override suspend fun submitExport(
            request: MediaExportRequest,
        ): MediaExportJobHandle = requireSession().platform.submitExport(request)

        override suspend fun exportStatus(
            context: CreativeProjectContext,
            jobID: String,
        ): MediaExportStatus {
            val status = requireSession().platform.exportStatus(context, jobID)
            // Capture the full verified receipt identity + owner only from a
            // real platform reply. A capture failure does not fail the status
            // read; Save/Share will refuse without an exact owner proof.
            try {
                receiptRecorder?.recordVerifiedStatus(context, status)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // No captured authority; delivery refuses honestly.
            }
            return status
        }

        override suspend fun cancelExport(
            context: CreativeProjectContext,
            jobID: String,
        ): MediaExportJobHandle = requireSession().platform.cancelExport(context, jobID)

        override fun observeExport(
            context: CreativeProjectContext,
            jobID: String,
            listener: (MediaExportStatus) -> Unit,
        ): AutoCloseable {
            val session = requireSession()
            return session.platform.observeExport(context, jobID) { status ->
                // Record the exact completed receipt (prepared capture or a
                // resolved current owner) before the UI can present Save.
                try {
                    receiptRecorder?.recordObservedStatus(context, status)
                } catch (_: Throwable) {
                    // Bounded/no-authority only; the callback still runs.
                }
                listener(status)
            }
        }
    }

    /**
     * Called ONLY after `creativeHost.bindCurrent()` accepted [epoch].
     *
     * Clears the root-stop fence, reuses the exact same-epoch session (the
     * ticket start is idempotent for the same transport/epoch), or retires a
     * previous-epoch session and installs the new one ONLY on a truly drained
     * report. FALSE leaves the old references owned and the Root bound.
     */
    suspend fun onNativeCreativeBound(epoch: Long): Boolean {
        if (epoch <= 0L || !epochOwner.isEpochLive(epoch)) {
            mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                "staleGeneration", "acceptedRootNotLive")
            return false
        }
        return mutex.withLock {
            if (epoch <= 0L || !epochOwner.isEpochLive(epoch)) {
                mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                    "staleGeneration", "acceptedRootNotLive")
                return@withLock false
            }
            val current = session
            if (current != null && boundEpoch == epoch) {
                val started = startTickets(current, epoch)
                fenced = false
                mutableState.value = MediaWorkbenchPlatformState.Ready(
                    epoch = epoch,
                    ticketConsumerStarted = started.first,
                    ticketReason = started.second)
                return@withLock true
            }
            if (current != null) {
                // New epoch attempt: nothing may be admitted while A retires.
                fenced = true
                mutableState.value = MediaWorkbenchPlatformState.Draining(boundEpoch)
                val report = try {
                    current.retire(retireTimeoutMillis)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    null
                }
                lastDrain = report
                // The old renderer's consumer is retiring: stop advertising
                // its readiness lease immediately (settling claims keep their
                // own tokens). A still-draining report keeps Root bound below.
                ticketTransport?.stopConsumer(boundEpoch)
                ticketTransport = null
                if (report?.drained != true) {
                    // A work/claim/pin is still owned: NEVER start B.
                    mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                        "mediaPlatformDrainPending", report?.reason ?: "drainPending")
                    return@withLock false
                }
                session = null
                boundEpoch = 0L
            }
            mutableState.value = MediaWorkbenchPlatformState.Starting(epoch)
            val created = try {
                WorkbenchMediaPlatformFactory.create(config())
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                    "mediaPlatformUnavailable", error.javaClass.simpleName)
                return@withLock false
            }
            if (!epochOwner.isEpochLive(epoch)) {
                // The accepted root changed while the factory was constructed:
                // do not publish this session for another epoch.
                runCatching { created.close() }
                mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                    "staleGeneration", "acceptedRootNotLive")
                return@withLock false
            }
            val started = startTickets(created, epoch)
            session = created
            boundEpoch = epoch
            fenced = false
            generation.incrementAndGet()
            mutableState.value = MediaWorkbenchPlatformState.Ready(
                epoch = epoch,
                ticketConsumerStarted = started.first,
                ticketReason = started.second)
            true
        }
    }

    /** Fence new App media work immediately (Root-stop step 1). */
    fun fenceForRootStop() {
        fenced = true
    }

    /**
     * Root-stop step 2: await the old platform workers/players/claims/pins.
     * A failed retirement keeps the exact session references; Root must stay
     * bound and a later exact-epoch attempt may retry.
     */
    suspend fun retireForRootStop(
        timeoutMillis: Long = retireTimeoutMillis,
    ): Boolean = mutex.withLock {
        fenced = true
        val current = session
        if (current == null) {
            mutableState.value = MediaWorkbenchPlatformState.Idle
            return@withLock true
        }
        mutableState.value = MediaWorkbenchPlatformState.Draining(boundEpoch)
        val report = try {
            current.retire(timeoutMillis.coerceIn(0L, 60_000L))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            null
        }
        lastDrain = report
        ticketTransport?.stopConsumer(boundEpoch)
        ticketTransport = null
        if (report?.drained == true) {
            session = null
            boundEpoch = 0L
            mutableState.value = MediaWorkbenchPlatformState.Idle
            true
        } else {
            mutableState.value = MediaWorkbenchPlatformState.Unavailable(
                "mediaPlatformDrainPending", report?.reason ?: "retireUnconfirmed")
            false
        }
    }

    fun currentSession(): WorkbenchMediaSession? = session

    fun currentBoundEpoch(): Long = boundEpoch

    fun isFenced(): Boolean = fenced

    fun lastDrainReport(): MediaDrainReport? = lastDrain

    /** Bounded, content-free diagnostic detail for Settings/Diagnostics. */
    fun diagnosticSummary(): String {
        val current = session
        val tickets = current?.ticketState()
        return buildString {
            append(mutableState.value.javaClass.simpleName.lowercase())
            append(":epoch=").append(boundEpoch)
            append(":generation=").append(generation.get())
            if (tickets != null) {
                append(":tickets=").append(tickets.javaClass.simpleName.lowercase())
            }
            lastDrain?.let { append(":pins=").append(it.outstandingPins) }
        }
    }

    private suspend fun startTickets(
        session: WorkbenchMediaSession,
        epoch: Long,
    ): Pair<Boolean, String?> = try {
        val transport = hostProvider().r2RenderTickets
        val native = transport as? MediaRenderTicketNativeTransport
        val started = session.startRenderTickets(transport, epoch)
        if (started) {
            ticketTransport = native
            // The real claim loop is now running. Mark the bounded consumer
            // readiness lease immediately; every later claim poll refreshes
            // it, so a stalled/retired consumer hides media.project.
            runCatching { native?.markConsumerReady(epoch) }
        }
        if (started) Pair<Boolean, String?>(true, null)
        else Pair<Boolean, String?>(false, "ticketConsumerRefused")
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Pair<Boolean, String?>(
            false,
            (error as? CreativeException)?.code ?: "ticketConsumerUnavailable")
    }

    private fun requireSession(): WorkbenchMediaSession {
        if (fenced) {
            throw CreativeException(
                "staleGeneration", "mediaPlatformStopping", retryable = true)
        }
        return session ?: throw CreativeException(
            "rendererUnavailable", "mediaPlatformUnbound", retryable = true)
    }

    private fun config(): WorkbenchMediaPlatformConfig = WorkbenchMediaPlatformConfig(
        context = applicationContext,
        epochOwner = epochOwner,
        leaseAuthority = leaseAuthority,
        recoveryAuthority = recoveryAuthority,
        lifecycleAuthority = lifecycleAuthority,
        ioDispatcher = Dispatchers.IO,
        clockMillis = System::currentTimeMillis,
        progressPollMillis = 500L,
        ticketHeartbeatMillis = 5_000L,
    )
}
