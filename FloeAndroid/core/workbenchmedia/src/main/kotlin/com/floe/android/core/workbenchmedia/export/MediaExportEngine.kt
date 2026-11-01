// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.WorkbenchLeaseAuthority
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformConfig
import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.image.ImageExporter
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDER_TIMEOUT
import com.floe.android.core.workbenchmedia.util.RENDER_CANCELLED
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.atomicReplace
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.video.CompositionPlanner
import com.floe.android.core.workbenchmedia.video.Media3VideoExporter
import com.floe.android.core.workbenchmedia.video.VideoVerifier
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportState
import kotlinx.coroutines.CancellationException
import java.io.File

/**
 * The service-owned export state machine. It re-proves the immutable lease at
 * execution time (the editor may already be closed), writes into a
 * task-owned staging file, verifies the exact bytes, then atomically publishes
 * and emits a receipt. Failure/cancel deletes only this attempt's unfinished
 * staging file; a post-publish cancel is reported as the truthful completed
 * receipt instead of a false rollback.
 */
internal class MediaExportEngine(
    private val config: WorkbenchMediaPlatformConfig,
    private val authority: WorkbenchLeaseAuthority,
    capabilities: MediaCapabilityProbe,
    private val clock: MediaClock,
) {
    private val planner = CompositionPlanner(capabilities)
    private val videoExporter = Media3VideoExporter(config.context, config.progressPollMillis)

    suspend fun execute(job: ExportJob, runtime: ExportRuntime) {
        try {
            if (job.terminal) return
            if (job.cancelRequested.get()) {
                runtime.finish(job, MediaExportState.CANCELLED, errorCode = RENDER_CANCELLED)
                return
            }
            runtime.publish(
                job,
                com.floe.android.feature.workbench.MediaExportStatus(
                    jobID = job.jobID,
                    kind = job.kind,
                    state = MediaExportState.RUNNING,
                    updatedAt = clock.nowIso(),
                    progress = 0.01,
                ),
            )
            val decision = authority.validateRenderBinding(job.binding)
            val grant = when (decision) {
                is AuthorityDecision.Accepted -> decision.grant
                is AuthorityDecision.Refused -> throw refusal(decision.code, decision.reason, decision.retryable)
            }
            val snapshot = SnapshotVerifier.verify(
                SnapshotExpectation(
                    epoch = grant.epoch,
                    projectID = job.context.projectID,
                    revision = job.binding.projectRevision,
                    timelineDigest = job.binding.timelineDigest,
                    mediaRootPath = job.binding.mediaRootPath,
                    attemptID = job.binding.attemptID,
                    lease = job.binding.snapshot,
                ),
                grant,
                clock,
            )
            when (val request = job.request) {
                is MediaExportRequest.Video -> exportVideo(job, runtime, request, snapshot)
                is MediaExportRequest.Image -> exportImage(job, runtime, request, snapshot)
            }
        } catch (_: CancellationException) {
            if (!job.terminal) {
                if (job.interrupted) {
                    runtime.finish(job, MediaExportState.INTERRUPTED, errorCode = "serviceDestroyed")
                } else {
                    runtime.finish(job, MediaExportState.CANCELLED, errorCode = RENDER_CANCELLED)
                }
            }
            throw CancellationException("Export job cancelled")
        } catch (failure: MediaRefusal) {
            if (job.terminal) return
            when {
                job.interrupted -> runtime.finish(
                    job,
                    MediaExportState.INTERRUPTED,
                    errorCode = "serviceDestroyed",
                )
                job.timeoutRequested.get() -> runtime.finish(
                    job,
                    MediaExportState.TIMEOUT,
                    errorCode = RENDER_TIMEOUT,
                )
                job.cancelRequested.get() -> runtime.finish(
                    job,
                    MediaExportState.CANCELLED,
                    errorCode = RENDER_CANCELLED,
                )
                else -> runtime.finish(
                    job,
                    MediaExportState.FAILED,
                    errorCode = failure.code,
                    retryable = failure.retryable,
                )
            }
        } catch (failure: OutOfMemoryError) {
            if (!job.terminal) {
                runtime.finish(
                    job,
                    MediaExportState.FAILED,
                    errorCode = RENDERER_UNAVAILABLE,
                    retryable = true,
                )
            }
        } catch (failure: Throwable) {
            if (!job.terminal) {
                runtime.finish(
                    job,
                    MediaExportState.FAILED,
                    errorCode = RENDERER_UNAVAILABLE,
                    retryable = false,
                )
            }
        }
    }

    private suspend fun exportVideo(
        job: ExportJob,
        runtime: ExportRuntime,
        request: MediaExportRequest.Video,
        snapshot: VerifiedSnapshot,
    ) {
        if (job.cancelRequested.get()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        val plan = planner.plan(snapshot, request.settings)
        val outputRelative = "Workbench/Exports/${job.attemptID}.mp4"
        val output = MediaPaths.resolveOutputUnder(snapshot.root, outputRelative)
            ?: throw refusal(STORAGE_UNAVAILABLE, "Export output path escapes the trusted root")
        if (output.exists()) throw refusal(WRITE_FAILED, "The export attempt output already exists")
        val parent = output.parentFile
            ?: throw refusal(STORAGE_UNAVAILABLE, "Export output directory is unavailable")
        if (!parent.isDirectory && !parent.mkdirs()) {
            throw refusal(STORAGE_UNAVAILABLE, "Export output directory could not be created")
        }
        val staging = File(parent, ".${job.attemptID}.mp4.part")
        staging.delete()
        runtime.publish(
            job,
            com.floe.android.feature.workbench.MediaExportStatus(
                jobID = job.jobID,
                kind = job.kind,
                state = MediaExportState.RUNNING,
                updatedAt = clock.nowIso(),
                progress = 0.03,
            ),
        )
        try {
            videoExporter.export(plan, staging, job.control) { progress ->
                if (!job.cancelRequested.get()) {
                    runtime.publish(
                        job,
                        com.floe.android.feature.workbench.MediaExportStatus(
                            jobID = job.jobID,
                            kind = job.kind,
                            state = MediaExportState.RUNNING,
                            updatedAt = clock.nowIso(),
                            progress = (0.03 + progress.coerceIn(0.0, 1.0) * 0.9).coerceIn(0.03, 0.93),
                        ),
                        persist = false,
                    )
                }
            }
            if (job.cancelRequested.get()) {
                throw refusal(RENDER_CANCELLED, "Export was cancelled")
            }
            runtime.publish(
                job,
                com.floe.android.feature.workbench.MediaExportStatus(
                    jobID = job.jobID,
                    kind = job.kind,
                    state = MediaExportState.VERIFYING,
                    updatedAt = clock.nowIso(),
                    progress = 0.95,
                ),
            )
            val expectAudio = (plan.clips.any { it.probe.hasAudio && !it.clip.isMuted && it.clip.volume > 0.0 } &&
                !plan.snapshot.projection.timeline.primaryMuted &&
                plan.snapshot.projection.timeline.primaryVolume > 0.0) || plan.music.isNotEmpty()
            val verified = VideoVerifier.verify(
                file = staging,
                expectedWidth = plan.width,
                expectedHeight = plan.height,
                expectedDurationSeconds = plan.durationSeconds,
                codecMime = plan.codecMime,
                expectAudio = expectAudio,
                maxBytes = MediaCapabilityProbe.MAX_OUTPUT_BYTES,
            )
            if (job.cancelRequested.get()) {
                throw refusal(RENDER_CANCELLED, "Export was cancelled")
            }
            if (output.exists()) throw refusal(WRITE_FAILED, "The export attempt output already exists")
            atomicReplace(staging, output)
            val receipt = MediaExportReceipt(
                binding = MediaExportReceiptBinding(
                    projectID = job.context.projectID,
                    mediaRootPath = snapshot.root.path,
                    projectRevision = job.binding.projectRevision,
                    timelineDigest = job.binding.timelineDigest,
                    attemptID = job.attemptID,
                ),
                kind = MediaExportKind.VIDEO,
                outputRelativePath = outputRelative,
                mimeType = "video/mp4",
                byteCount = verified.byteCount,
                sha256 = verified.sha256,
                verification = verified.verification,
                completedAt = clock.nowIso(),
            )
            runtime.finish(job, MediaExportState.COMPLETED, receipt = receipt, progress = 1.0)
        } catch (failure: Throwable) {
            staging.delete()
            throw failure
        }
    }

    private suspend fun exportImage(
        job: ExportJob,
        runtime: ExportRuntime,
        request: MediaExportRequest.Image,
        snapshot: VerifiedSnapshot,
    ) {
        if (job.cancelRequested.get()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        val extension = request.settings.format.lowercase()
        if (extension != "png" && extension != "jpeg" && extension != "heic") {
            throw refusal(com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED, "Unsupported image format ${request.settings.format}")
        }
        val outputRelative = "Workbench/Exports/${job.attemptID}.$extension"
        val output = MediaPaths.resolveOutputUnder(snapshot.root, outputRelative)
            ?: throw refusal(STORAGE_UNAVAILABLE, "Export output path escapes the trusted root")
        runtime.publish(
            job,
            com.floe.android.feature.workbench.MediaExportStatus(
                jobID = job.jobID,
                kind = job.kind,
                state = MediaExportState.RUNNING,
                updatedAt = clock.nowIso(),
                progress = 0.2,
            ),
        )
        val verified = ImageExporter.writeVerified(
            snapshot = snapshot,
            settings = request.settings,
            output = output,
            attemptID = job.attemptID,
        ) { job.cancelRequested.get() || job.timeoutRequested.get() || job.interrupted }
        if (job.cancelRequested.get() && !output.isFile) {
            throw refusal(RENDER_CANCELLED, "Export was cancelled")
        }
        val receipt = MediaExportReceipt(
            binding = MediaExportReceiptBinding(
                projectID = job.context.projectID,
                mediaRootPath = snapshot.root.path,
                projectRevision = job.binding.projectRevision,
                timelineDigest = job.binding.timelineDigest,
                attemptID = job.attemptID,
            ),
            kind = MediaExportKind.IMAGE,
            outputRelativePath = outputRelative,
            mimeType = when (extension) {
                "png" -> "image/png"
                "heic" -> "image/heic"
                else -> "image/jpeg"
            },
            byteCount = verified.byteCount,
            sha256 = verified.sha256,
            verification = verified.verification,
            completedAt = clock.nowIso(),
        )
        runtime.finish(job, MediaExportState.COMPLETED, receipt = receipt, progress = 1.0)
    }

}
