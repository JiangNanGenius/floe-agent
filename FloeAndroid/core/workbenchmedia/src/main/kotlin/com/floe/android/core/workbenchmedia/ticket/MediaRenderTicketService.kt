// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.ticket

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.TicketDrainReport
import com.floe.android.core.workbenchmedia.WorkbenchEpochOwner
import com.floe.android.core.workbenchmedia.WorkbenchLeaseAuthority
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformConfig
import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.image.ImageExporter
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_TIMEOUT
import com.floe.android.core.workbenchmedia.util.RENDER_CANCELLED
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_CODEC
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.atomicReplace
import com.floe.android.core.workbenchmedia.util.isExpired
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.video.CompositionPlanner
import com.floe.android.core.workbenchmedia.video.Media3VideoExporter
import com.floe.android.core.workbenchmedia.video.RenderControl
import com.floe.android.core.workbenchmedia.video.VideoVerifier
import com.floe.android.feature.workbench.ClaimedRenderTicket
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import com.floe.android.feature.workbench.MediaRenderTicketTransport
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.feature.workbench.RenderTicketReply
import com.floe.android.feature.workbench.RenderTicketReplyStatus
import com.floe.android.feature.workbench.WorkbenchR2Limits
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class RenderTicketServiceState(
    val running: Boolean,
    val bound: Boolean,
    val epoch: Long? = null,
    val activeTickets: Int = 0,
    val claimedTickets: Long = 0,
    val lastErrorCode: String? = null,
)

/**
 * Bounded consumer of the native MediaRenderTicketTransport. It runs on its
 * own IO dispatcher, never calls back into the Kotlin creative exchange while
 * rendering, claims at most two tickets, validates the native descriptor
 * (epoch/root/lease/revision/hash/settings), heartbeats/stops with the claim
 * token, dispatches a real renderer, and settles exactly once with a verified
 * receipt.
 */
internal class MediaRenderTicketService(
    private val config: WorkbenchMediaPlatformConfig,
    private val authority: WorkbenchLeaseAuthority,
    private val epochOwner: WorkbenchEpochOwner,
    private val capabilities: MediaCapabilityProbe,
    private val clock: MediaClock,
) {
    private val scope = CoroutineScope(SupervisorJob() + config.ioDispatcher)
    private val planner = CompositionPlanner(capabilities)
    private val videoExporter = Media3VideoExporter(config.context, config.progressPollMillis)
    private val active = ConcurrentHashMap<String, TicketJob>()
    private val claimedCounter = java.util.concurrent.atomic.AtomicLong(0)
    private val lastError = java.util.concurrent.atomic.AtomicReference<String?>(null)
    private val stopRequested = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    @Volatile private var transport: MediaRenderTicketTransport? = null
    @Volatile private var epoch: Long? = null
    @Volatile private var loopJob: Job? = null

    fun state(): RenderTicketServiceState = RenderTicketServiceState(
        running = running.get(),
        bound = transport != null && epoch != null,
        epoch = epoch,
        activeTickets = active.size,
        claimedTickets = claimedCounter.get(),
        lastErrorCode = lastError.get(),
    )

    suspend fun start(transport: MediaRenderTicketTransport, epoch: Long): Boolean {
        val currentTransport = this.transport
        val currentEpoch = this.epoch
        if (running.get()) {
            return currentTransport === transport && currentEpoch == epoch
        }
        if (stopRequested.get()) return false
        if (epochOwner.currentEpoch() != epoch || !epochOwner.isEpochLive(epoch)) {
            lastError.set("renderTicketExpired")
            return false
        }
        val bound = try {
            transport.bind(epoch)
        } catch (_: Exception) {
            false
        }
        if (!bound) {
            lastError.set("rendererUnavailable")
            return false
        }
        this.transport = transport
        this.epoch = epoch
        running.set(true)
        loopJob = scope.launch { claimLoop() }
        return true
    }

    suspend fun stopAndDrain(timeoutMillis: Long): TicketDrainReport {
        stopRequested.set(true)
        val current = transport
        for (job in active.values) {
            job.control.requestCancel()
        }
        val loop = loopJob
        loop?.cancel()
        // A claim may be in flight when stop() arrives. Do not report drained
        // until the claim loop has actually exited; otherwise a late claim could
        // keep a native Root reference after the caller was told it was safe.
        val loopJoined = withTimeoutOrNull(timeoutMillis.coerceIn(0L, 60_000L)) {
            loop?.join()
            true
        } ?: false
        val deadline = System.currentTimeMillis() + timeoutMillis.coerceIn(0L, 60_000L)
        while (System.currentTimeMillis() < deadline && active.isNotEmpty()) {
            delay(50L)
        }
        var retirementFailed = false
        if (current != null) {
            // Close only tickets whose worker has actually stopped. A still
            // active renderer must keep its claim: Root must not retire while
            // codec work is in flight. close(ticketID, claimToken) is the
            // authenticated retirement acknowledgement; a failed acknowledgement
            // keeps the claim (and the Root reference) alive for a later drain.
            for (job in active.values.toList()) {
                if (job.finished.get()) {
                    val retired = runCatching {
                        current.close(job.claim.descriptor.ticketID, job.claim.claimToken)
                    }.isSuccess
                    if (retired) {
                        active.remove(job.claim.descriptor.ticketID, job)
                    } else {
                        retirementFailed = true
                    }
                }
            }
        }
        val remaining = active.size
        running.set(false)
        if (remaining == 0 && !retirementFailed) {
            transport = null
            epoch = null
        }
        return TicketDrainReport(
            drained = remaining == 0 && !retirementFailed && loopJoined,
            activeTickets = remaining,
            claimedTickets = claimedCounter.get().toInt(),
            reason = when {
                !loopJoined -> "The ticket claim loop is still stopping"
                remaining > 0 -> "Renderers are still stopping"
                retirementFailed -> "A claimed ticket retirement acknowledgement failed"
                else -> null
            },
            measuredAt = clock.nowIso(),
        )
    }

    fun closeNow() {
        stopRequested.set(true)
        for (job in active.values) job.control.requestCancel()
        loopJob?.cancel()
        scope.cancel()
        running.set(false)
        transport = null
        epoch = null
    }

    private suspend fun claimLoop() {
        while (!stopRequested.get() && running.get()) {
            if (active.size >= WorkbenchR2Limits.MAX_LIVE_RENDER_TICKETS) {
                delay(100L)
                continue
            }
            val current = transport
            if (current == null) {
                running.set(false)
                break
            }
            val currentEpoch = epoch
            if (currentEpoch == null) {
                running.set(false)
                break
            }
            if (epochOwner.currentEpoch() != currentEpoch || !epochOwner.isEpochLive(currentEpoch)) {
                lastError.set("renderTicketExpired")
                running.set(false)
                break
            }
            val claim = try {
                current.claim(500L)
            } catch (failure: Exception) {
                lastError.set(RENDERER_UNAVAILABLE)
                delay(500L)
                continue
            }
            if (claim == null) {
                delay(200L)
                continue
            }
            if (stopRequested.get()) {
                runCatching { current.close(claim.descriptor.ticketID, claim.claimToken) }
                break
            }
            val ticketID = claim.descriptor.ticketID
            val live = runCatching { current.isLive(ticketID) }.getOrDefault(false)
            if (!live) {
                runCatching { current.close(ticketID, claim.claimToken) }
                continue
            }
            val job = TicketJob(claim)
            active[ticketID] = job
            claimedCounter.incrementAndGet()
            scope.launch { runTicket(job, current) }
        }
    }

    private suspend fun runTicket(job: TicketJob, transport: MediaRenderTicketTransport) {
        val descriptor = job.claim.descriptor
        val heartbeat = scope.launch { heartbeatLoop(job, transport) }
        try {
            val outcome = withTimeoutOrNull(renderTimeoutMillis(descriptor)) {
                render(job, transport)
            }
            if (outcome == null) {
                job.control.requestCancel()
                reply(job, RenderTicketReplyStatus.TIMEOUT, errorCode = RENDER_TIMEOUT)
            } else {
                when (outcome) {
                    is TicketOutcome.Completed -> reply(job, RenderTicketReplyStatus.COMPLETED, receipt = outcome.receipt)
                    is TicketOutcome.Failed -> {
                        job.control.requestCancel()
                        reply(
                            job,
                            outcome.status,
                            errorCode = outcome.code,
                        )
                    }
                }
            }
        } catch (_: CancellationException) {
            job.control.requestCancel()
            reply(job, RenderTicketReplyStatus.CANCELLED, errorCode = RENDER_CANCELLED)
        } catch (failure: MediaRefusal) {
            reply(job, statusFor(failure.code), errorCode = failure.code)
        } catch (_: Throwable) {
            reply(job, RenderTicketReplyStatus.FAILED, errorCode = RENDERER_UNAVAILABLE)
        } finally {
            heartbeat.cancel()
            job.finished.set(true)
            val retired = runCatching {
                transport.close(descriptor.ticketID, job.claim.claimToken)
            }.isSuccess
            if (retired) active.remove(descriptor.ticketID, job)
        }
    }

    private suspend fun render(job: TicketJob, transport: MediaRenderTicketTransport): TicketOutcome {
        val descriptor = job.claim.descriptor
        if (job.claim.claimToken.isBlank()) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, "renderTicketNotFound")
        }
        if (descriptor.descriptorVersion != 1) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        }
        if (!MediaPaths.safeComponent(descriptor.attemptID) ||
            !MediaPaths.safeComponent(descriptor.ticketID, max = 200) ||
            descriptor.ownerReference.isBlank() ||
            descriptor.leaseID.isBlank() ||
            descriptor.timelineDigest.isBlank() ||
            descriptor.snapshotRelativePath.isBlank() ||
            descriptor.descriptorByteCount !in 1..WorkbenchR2Limits.RENDER_DESCRIPTOR_BYTES
        ) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, INVALID_PAYLOAD)
        }
        val currentEpoch = epoch ?: return TicketOutcome.Failed(
            RenderTicketReplyStatus.FAILED, "renderTicketNotFound")
        if (descriptor.epoch != currentEpoch ||
            epochOwner.currentEpoch() != currentEpoch ||
            !epochOwner.isEpochLive(currentEpoch)
        ) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, "renderTicketExpired")
        }
        if (isExpired(descriptor.snapshotLeaseExpiresAt, clock) ||
            isExpired(descriptor.expiresAt, clock) ||
            isExpired(job.claim.leaseExpiresAt, clock)
        ) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.TIMEOUT, "renderTicketExpired")
        }
        val decision = authority.validateTicket(descriptor, job.claim.claimToken)
        val grant = when (decision) {
            is AuthorityDecision.Accepted -> decision.grant
            is AuthorityDecision.Refused -> return TicketOutcome.Failed(
                RenderTicketReplyStatus.FAILED,
                decision.code,
            )
        }
        if (grant.epoch != descriptor.epoch ||
            grant.projectID != null && grant.projectID != descriptor.projectID ||
            grant.revision != null && grant.revision != descriptor.projectRevision ||
            grant.timelineDigest != null && grant.timelineDigest != descriptor.timelineDigest
        ) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, "renderTicketExpired")
        }
        val snapshot = SnapshotVerifier.verify(
            SnapshotVerifier.expectationForDescriptor(descriptor),
            grant,
            clock,
        )
        val output = MediaPaths.resolveOutputUnder(snapshot.root, descriptor.outputRelativePath)
            ?: return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, STORAGE_UNAVAILABLE)
        if (!output.relativePathIsSafe(descriptor)) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        }
        if (output.exists()) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, WRITE_FAILED)
        }
        return when (descriptor.kind) {
            MediaExportKind.IMAGE -> renderImage(job, descriptor, snapshot, output)
            MediaExportKind.VIDEO, MediaExportKind.PREVIEW -> {
                if (descriptor.videoSettings != null) {
                    renderVideo(job, descriptor, snapshot, output)
                } else if (descriptor.imageSettings != null && descriptor.kind == MediaExportKind.PREVIEW) {
                    renderImage(job, descriptor, snapshot, output)
                } else {
                    TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
                }
            }
        }
    }

    private suspend fun renderVideo(
        job: TicketJob,
        descriptor: RenderTicketDescriptor,
        snapshot: com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot,
        output: File,
    ): TicketOutcome {
        val settings = descriptor.videoSettings
            ?: return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        val plan = try {
            planner.plan(snapshot, settings, descriptor.previewWindow)
        } catch (failure: MediaRefusal) {
            return TicketOutcome.Failed(statusFor(failure.code), failure.code)
        }
        if (output.name != "${descriptor.attemptID}.mp4") {
            return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        }
        val parent = output.parentFile
            ?: return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, STORAGE_UNAVAILABLE)
        if (!parent.isDirectory && !parent.mkdirs()) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, STORAGE_UNAVAILABLE)
        }
        val staging = File(parent, ".${descriptor.attemptID}.mp4.part")
        try {
            staging.delete()
            videoExporter.export(plan, staging, job.control) { }
            if (job.control.cancelRequested) {
                return TicketOutcome.Failed(RenderTicketReplyStatus.CANCELLED, RENDER_CANCELLED)
            }
            val expectAudio = (plan.clips.any { it.probe.hasAudio && !it.clip.isMuted && it.clip.volume > 0.0 } &&
                !plan.snapshot.projection.timeline.primaryMuted &&
                plan.snapshot.projection.timeline.primaryVolume > 0.0) || plan.music.isNotEmpty()
            val verified = VideoVerifier.verify(
                staging,
                plan.width,
                plan.height,
                plan.durationSeconds,
                plan.codecMime,
                expectAudio,
                MediaCapabilityProbe.MAX_OUTPUT_BYTES,
            )
            if (job.control.cancelRequested) {
                return TicketOutcome.Failed(RenderTicketReplyStatus.CANCELLED, RENDER_CANCELLED)
            }
            if (output.exists()) return TicketOutcome.Failed(RenderTicketReplyStatus.FAILED, WRITE_FAILED)
            atomicReplace(staging, output)
            return TicketOutcome.Completed(
                MediaExportReceipt(
                    binding = receiptBinding(descriptor, snapshot.root),
                    kind = descriptor.kind,
                    outputRelativePath = descriptor.outputRelativePath,
                    mimeType = "video/mp4",
                    byteCount = verified.byteCount,
                    sha256 = verified.sha256,
                    verification = verified.verification,
                    completedAt = clock.nowIso(),
                ),
            )
        } finally {
            staging.delete()
        }
    }

    private fun renderImage(
        job: TicketJob,
        descriptor: RenderTicketDescriptor,
        snapshot: com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot,
        output: File,
    ): TicketOutcome {
        val settings = descriptor.imageSettings
            ?: return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        val extension = settings.format.lowercase()
        if (extension != "png" && extension != "jpeg" ||
            output.name != "${descriptor.attemptID}.$extension"
        ) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.UNSUPPORTED, "renderUnsupported")
        }
        if (job.control.cancelRequested) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.CANCELLED, RENDER_CANCELLED)
        }
        val verified = try {
            ImageExporter.writeVerified(snapshot, settings, output, descriptor.attemptID) {
                job.control.cancelRequested
            }
        } catch (failure: MediaRefusal) {
            return TicketOutcome.Failed(statusFor(failure.code), failure.code)
        }
        if (job.control.cancelRequested && !output.exists()) {
            return TicketOutcome.Failed(RenderTicketReplyStatus.CANCELLED, RENDER_CANCELLED)
        }
        val format = settings.format.lowercase()
        return TicketOutcome.Completed(
            MediaExportReceipt(
                binding = receiptBinding(descriptor, snapshot.root),
                kind = descriptor.kind,
                outputRelativePath = descriptor.outputRelativePath,
                mimeType = if (format == "png") "image/png" else "image/jpeg",
                byteCount = verified.byteCount,
                sha256 = verified.sha256,
                verification = verified.verification,
                completedAt = clock.nowIso(),
            ),
        )
    }

    private suspend fun heartbeatLoop(job: TicketJob, transport: MediaRenderTicketTransport) {
        while (!job.finished.get() && !job.control.cancelRequested) {
            delay(config.ticketHeartbeatMillis)
            if (job.finished.get()) return
            val alive = try {
                transport.heartbeat(job.claim.descriptor.ticketID, job.claim.claimToken)
            } catch (_: Exception) {
                false
            }
            if (!alive) {
                job.control.requestCancel()
                return
            }
            val stop = try {
                transport.shouldStop(job.claim.descriptor.ticketID, job.claim.claimToken)
            } catch (_: Exception) {
                true
            }
            if (stop) {
                job.control.requestCancel()
                return
            }
        }
    }

    private suspend fun reply(
        job: TicketJob,
        status: RenderTicketReplyStatus,
        receipt: MediaExportReceipt? = null,
        errorCode: String? = null,
    ) {
        if (!job.gate.trySettle()) return
        if (status != RenderTicketReplyStatus.COMPLETED && errorCode != null) {
            lastError.set(errorCode)
        }
        val transport = transport ?: return
        val descriptor = job.claim.descriptor
        val reply = RenderTicketReply(
            ticketID = descriptor.ticketID,
            status = status,
            receipt = receipt,
            errorCode = errorCode,
            completedAt = clock.nowIso(),
            replyByteCount = 0,
        )
        val bounded = reply.copy(
            replyByteCount = reply.toString().toByteArray(Charsets.UTF_8).size
                .coerceIn(0, WorkbenchR2Limits.RENDER_REPLY_BYTES),
        )
        runCatching {
            transport.complete(descriptor.ticketID, job.claim.claimToken, bounded)
        }.onFailure {
            lastError.set(RENDERER_UNAVAILABLE)
        }
    }

    private fun statusFor(code: String): RenderTicketReplyStatus = when (code) {
        UNSUPPORTED_CODEC, UNSUPPORTED_TRANSITION, UNSUPPORTED_SOURCE_FORMAT, RENDER_UNSUPPORTED ->
            RenderTicketReplyStatus.UNSUPPORTED
        RENDER_CANCELLED -> RenderTicketReplyStatus.CANCELLED
        RENDER_TIMEOUT -> RenderTicketReplyStatus.TIMEOUT
        else -> RenderTicketReplyStatus.FAILED
    }

    private fun renderTimeoutMillis(descriptor: RenderTicketDescriptor): Long =
        if (descriptor.kind == MediaExportKind.IMAGE) {
            5L * 60L * 1000L
        } else {
            30L * 60L * 1000L
        }

    private fun receiptBinding(
        descriptor: RenderTicketDescriptor,
        root: File,
    ) = MediaExportReceiptBinding(
        projectID = descriptor.projectID,
        mediaRootPath = root.path,
        projectRevision = descriptor.projectRevision,
        timelineDigest = descriptor.timelineDigest,
        attemptID = descriptor.attemptID,
    )

    private fun File.relativePathIsSafe(descriptor: RenderTicketDescriptor): Boolean {
        val relative = descriptor.outputRelativePath
        val prefix = if (descriptor.kind == MediaExportKind.PREVIEW) {
            "Workbench/Previews/"
        } else {
            "Workbench/Exports/"
        }
        if (!relative.startsWith(prefix)) return false
        val name = relative.removePrefix(prefix)
        return name.startsWith("${descriptor.attemptID}.") && !name.contains('/') && !name.contains('\\')
    }

    private class TicketJob(val claim: ClaimedRenderTicket) {
        val control = RenderControl()
        val gate = SettlementGate()
        val finished = AtomicBoolean(false)
    }

    private sealed interface TicketOutcome {
        data class Completed(val receipt: MediaExportReceipt) : TicketOutcome
        data class Failed(val status: RenderTicketReplyStatus, val code: String) : TicketOutcome
    }
}
