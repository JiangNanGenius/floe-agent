// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.export.ExportRuntime
import com.floe.android.core.workbenchmedia.export.ExportRuntimeHolder
import com.floe.android.core.workbenchmedia.lifecycle.LifecyclePinTracker
import com.floe.android.core.workbenchmedia.ticket.MediaRenderTicketService
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.SessionDrainFence
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.ImagePreviewReceipt
import com.floe.android.feature.workbench.ImagePreviewRequest
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.MediaProjectToolExportCapability
import com.floe.android.feature.workbench.MediaProjectToolExportPort
import com.floe.android.feature.workbench.MediaProjectToolExportRoute
import com.floe.android.feature.workbench.MediaProjectToolExportSubmission
import com.floe.android.feature.workbench.MediaRenderTicketTransport
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.ProbedAsset
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.WorkbenchR2Errors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal class WorkbenchMediaSessionImpl(
    private val config: WorkbenchMediaPlatformConfig,
) : WorkbenchMediaSession {
    private val clock: MediaClock = object : MediaClock {
        override fun nowMillis(): Long = config.clockMillis()
    }
    private val capabilities = MediaCapabilityProbe(clock)
    private val gate = SessionDrainFence()
    private val pins = LifecyclePinTracker(config.lifecycleAuthority, config.ioDispatcher)
    private val runtime = ExportRuntime(
        config = config,
        authority = config.leaseAuthority,
        epochOwner = config.epochOwner,
        capabilities = capabilities,
        pins = pins,
        fence = gate,
        clock = clock,
    )
    private val ticketService = MediaRenderTicketService(
        config = config,
        authority = config.leaseAuthority,
        epochOwner = config.epochOwner,
        capabilities = capabilities,
        clock = clock,
    )
    private val delegate = Media3WorkbenchMediaPlatform(
        context = config.context,
        config = config,
        authority = config.leaseAuthority,
        capabilities = capabilities,
        clock = clock,
        runtime = runtime,
        pins = pins,
    )
    private val players = ConcurrentHashMap.newKeySet<PlaybackHandle>()
    private val activeAdmissions = AtomicInteger(0)
    private val closed = AtomicBoolean(false)
    private val retireMutex = Mutex()
    @Volatile private var retiredReport: MediaDrainReport? = null
    private val installed = ExportRuntimeHolder.install(runtime)

    init {
        check(installed) {
            "Another WorkbenchMediaSession already owns the process export runtime"
        }
    }

    override val platform: WorkbenchMediaPlatform = object : WorkbenchMediaPlatform by delegate {
        override fun createPlayer(request: PlaybackRequest): PlaybackHandle = accepting {
            val handle = delegate.createPlayer(request)
            players += handle
            TrackingPlaybackHandle(handle) { players.remove(handle) }
        }

        override suspend fun probe(request: MediaAssetProbeRequest): ProbedAsset =
            acceptingSuspend { delegate.probe(request) }

        override suspend fun renderImagePreview(request: ImagePreviewRequest): ImagePreviewReceipt =
            acceptingSuspend { delegate.renderImagePreview(request) }

        override suspend fun submitExport(request: MediaExportRequest): MediaExportJobHandle =
            acceptingSuspend { delegate.submitExport(request) }
    }

    override val toolExport: MediaProjectToolExportPort = object : MediaProjectToolExportPort {
        override fun capability(): MediaProjectToolExportCapability =
            MediaProjectToolExportCapability(
                route = MediaProjectToolExportRoute.UNAVAILABLE,
                registered = false,
                reason = "The native media render-ticket submission/registration path is not attached; " +
                    "export is available only through the verified platform request path",
            )

        override suspend fun submitExport(request: MediaExportRequest): MediaProjectToolExportSubmission {
            throw CreativeException(
                WorkbenchR2Errors.RENDERER_UNAVAILABLE,
                "The native media render-ticket submission path is unavailable",
            )
        }
    }

    override suspend fun startRenderTickets(
        transport: MediaRenderTicketTransport,
        epoch: Long,
    ): Boolean {
        if (closed.get() || gate.isFenced()) return false
        activeAdmissions.incrementAndGet()
        try {
            if (closed.get() || gate.isFenced()) return false
            return withContext(config.ioDispatcher) { ticketService.start(transport, epoch) }
        } finally {
            activeAdmissions.decrementAndGet()
        }
    }

    override fun ticketState(): com.floe.android.core.workbenchmedia.ticket.RenderTicketServiceState =
        ticketService.state()

    override suspend fun stopRenderTickets(timeoutMillis: Long): TicketDrainReport =
        withContext(config.ioDispatcher) { ticketService.stopAndDrain(timeoutMillis) }

    override suspend fun listRecoveredExports(
        context: CreativeProjectContext,
        limit: Int,
    ): List<MediaExportStatus> = try {
        acceptingSuspend { runtime.listRecoveredExports(context, limit) }
    } catch (failure: MediaRefusal) {
        throw CreativeException(failure.code, failure.message, failure.retryable, failure)
    }

    /**
     * Root-stop drain. The fence is set before any cancel so a concurrent
     * submission/player/preview cannot be handed a root that native is about
     * to unbind. Success requires actual export workers, ticket claims, player
     * releases and native lifecycle pins to be gone; this method never treats
     * a cancel request or a UI terminal status as drain proof.
     */
    override suspend fun drain(timeoutMillis: Long): MediaDrainReport {
        val startedAt = System.currentTimeMillis()
        val budget = timeoutMillis.coerceIn(0L, 60_000L)
        fun remaining(): Long =
            (budget - (System.currentTimeMillis() - startedAt)).coerceAtLeast(0L)
        gate.fence()
        pins.fence()
        runtime.requestCancelAll()
        // A createPlayer/preview/submit that passed the fence check just before
        // Root stop is already in flight. Wait for it to finish so its handle
        // and pin are visible to the player/pin snapshots below; never report
        // drained while an admission is still running.
        while (activeAdmissions.get() > 0 && remaining() > 0L) {
            delay(10L)
        }
        val admissionsQuiesced = activeAdmissions.get() == 0

        val ticketReport = ticketService.stopAndDrain(remaining())
        // Close actual players (decoders) and prove they are gone before
        // reporting drained. A retained PlaybackHandle is not an idle resource.
        for (player in players.toList()) {
            if (runCatching { player.close() }.isSuccess) {
                players.remove(player)
            }
        }
        val (exportsDrained, activeExports) = runtime.drain(remaining())
        // Exports/previews/players release their native pins from their actual
        // worker/player-close path; this wait must follow those paths.
        val pinReport = pins.awaitDrained(remaining())
        val drained = admissionsQuiesced && exportsDrained && ticketReport.drained &&
            players.isEmpty() && pinReport.drained
        return MediaDrainReport(
            drained = drained,
            activeExports = activeExports,
            activeTickets = ticketReport.activeTickets,
            openPlayers = players.size,
            outstandingPins = pinReport.outstanding + pinReport.inFlightAcquisitions,
            pinReleaseUnknown = pinReport.releaseUnknown,
            reason = when {
                !admissionsQuiesced -> "A media admission is still in flight"
                !ticketReport.drained -> ticketReport.reason ?: "Render tickets are still owned"
                !exportsDrained -> "Export workers are still owned"
                !players.isEmpty() -> "Playback players are still open"
                !pinReport.drained -> pinReport.reason ?: "Native lifecycle pins are still owned"
                else -> null
            },
            measuredAt = clock.nowIso(),
        )
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        gate.fence()
        pins.fence()
        runtime.requestCancelAll()
        // AutoCloseable may be called on the UI thread. Root/epoch replacement
        // must await retire() instead; this background call is only a
        // best-effort cleanup for callers that cannot suspend. It releases the
        // process registry only after an actual drain and always retains
        // ownership when the drain is incomplete.
        Thread({
            runCatching { runBlocking { retire(10_000L) } }
        }, "floe-media-drain").start()
    }

    /**
     * Awaitable one-way retirement. `drain` proves the workers/players/claims/
     * pins are gone; this method then synchronously clears the render-ticket
     * transport and the process export registry so a new epoch's
     * factory/session cannot collide with a stale registry. A failed drain
     * returns `drained=false` with every ownership reference retained (a later
     * retire may retry); the registry is cleared only on the success path,
     * strictly before `drained=true` is returned.
     */
    override suspend fun retire(timeoutMillis: Long): MediaDrainReport = retireMutex.withLock {
        retiredReport?.let { return@withLock it }
        closed.set(true)
        gate.fence()
        pins.fence()
        runtime.requestCancelAll()
        val report = drain(timeoutMillis)
        if (!report.drained) return@withLock report
        // Ordered synchronous release: stop accepting/transport claims, then
        // stop the export scope, then the pin registry and the process holder.
        ticketService.closeNow()
        runtime.shutdown()
        pins.shutdown()
        if (!ExportRuntimeHolder.clear(runtime)) {
            // Not expected after a successful install; never claim retirement of
            // a registry this session no longer owns.
            return@withLock report.copy(
                drained = false,
                reason = "The process export registry is owned by another session",
            )
        }
        retiredReport = report
        report
    }

    private fun ensureAccepting() {
        if (closed.get()) {
            throw CreativeException(RENDERER_UNAVAILABLE, "The media session is closed")
        }
        if (gate.isFenced()) {
            throw CreativeException(
                RENDERER_UNAVAILABLE,
                "The media session is draining; wait for a new accepted epoch and session",
                true,
            )
        }
    }

    private fun <T> accepting(block: () -> T): T {
        ensureAccepting()
        activeAdmissions.incrementAndGet()
        try {
            ensureAccepting()
            return block()
        } finally {
            activeAdmissions.decrementAndGet()
        }
    }

    private suspend fun <T> acceptingSuspend(block: suspend () -> T): T {
        ensureAccepting()
        activeAdmissions.incrementAndGet()
        try {
            ensureAccepting()
            return block()
        } finally {
            activeAdmissions.decrementAndGet()
        }
    }

    private class TrackingPlaybackHandle(
        private val delegate: PlaybackHandle,
        private val onClosed: () -> Unit,
    ) : PlaybackHandle by delegate {
        private val closed = AtomicBoolean(false)
        override fun close() {
            if (closed.compareAndSet(false, true)) {
                try {
                    delegate.close()
                    onClosed()
                } catch (failure: Throwable) {
                    closed.set(false)
                    throw failure
                }
            }
        }
    }
}
