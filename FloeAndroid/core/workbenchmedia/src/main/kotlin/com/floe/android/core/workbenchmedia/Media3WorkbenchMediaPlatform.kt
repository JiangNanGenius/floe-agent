// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import android.content.Context
import android.graphics.BitmapFactory
import com.floe.android.core.workbenchmedia.MediaLifecycleKind
import com.floe.android.core.workbenchmedia.MediaLifecyclePinRequest
import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.export.ExportRuntime
import com.floe.android.core.workbenchmedia.image.ImageExporter
import com.floe.android.core.workbenchmedia.lifecycle.LifecyclePinTracker
import com.floe.android.core.workbenchmedia.playback.Media3PlaybackHandle
import com.floe.android.core.workbenchmedia.service.MediaExportService
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.atomicReplace
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.writeFullySync
import com.floe.android.core.workbenchmedia.video.AssetProbe
import com.floe.android.core.workbenchmedia.video.CompositionPlanner
import com.floe.android.core.workbenchmedia.video.ImageVerifier
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.workbench.ImagePreviewReceipt
import com.floe.android.feature.workbench.ImagePreviewRequest
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.ProbedAsset
import com.floe.android.feature.workbench.RenderCapabilities
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import java.io.File
import kotlinx.coroutines.withContext

internal class Media3WorkbenchMediaPlatform(
    private val context: Context,
    private val config: WorkbenchMediaPlatformConfig,
    private val authority: WorkbenchLeaseAuthority,
    private val capabilities: MediaCapabilityProbe,
    private val clock: MediaClock,
    private val runtime: ExportRuntime,
    private val pins: LifecyclePinTracker,
) : WorkbenchMediaPlatform {
    private val planner = CompositionPlanner(capabilities)

    override fun capabilities(): RenderCapabilities = capabilities.capabilities()

    override fun createPlayer(request: PlaybackRequest): PlaybackHandle {
        validateBindingStructure(request.binding)
        return try {
            Media3PlaybackHandle(
                context = context,
                config = config,
                authority = authority,
                planner = planner,
                request = request,
                pins = pins,
            )
        } catch (failure: Throwable) {
            throw CreativeException(
                RENDERER_UNAVAILABLE,
                failure.message ?: "The platform player could not be created",
                false,
                failure,
            )
        }
    }

    override suspend fun probe(request: MediaAssetProbeRequest): ProbedAsset =
        withContext(config.ioDispatcher) { probeInternal(request) }

    private suspend fun probeInternal(request: MediaAssetProbeRequest): ProbedAsset {
        if (request.context.projectID.isBlank() || !CreativeSessionTokens.isValid(request.context.sessionToken)) {
            throw CreativeException("invalidSession", "A valid project/session context is required")
        }
        val decision = authority.validateProbeRoot(request)
        val grant = when (decision) {
            is AuthorityDecision.Accepted -> decision.grant
            is AuthorityDecision.Refused -> throw CreativeException(decision.code, decision.reason, decision.retryable)
        }
        if (grant.projectID != null && grant.projectID != request.context.projectID) {
            throw CreativeException(RENDER_UNSUPPORTED, "The probe grant belongs to another project")
        }
        val root = MediaPaths.canonicalRoot(grant.mediaRootPath)
            ?: throw CreativeException(STORAGE_UNAVAILABLE, "The accepted media root is not available")
        val requestRoot = MediaPaths.canonicalRoot(request.mediaRootPath)
            ?: throw CreativeException(STORAGE_UNAVAILABLE, "The requested media root is not available")
        if (root.path != requestRoot.path) {
            throw CreativeException(RENDER_UNSUPPORTED, "The requested root differs from the accepted root")
        }
        val file = MediaPaths.resolveExistingUnder(root, request.relativePath)
            ?: throw CreativeException(RENDER_UNSUPPORTED, "The probe path is missing or escapes the media root")
        val imageBounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, imageBounds)
        if (imageBounds.outWidth > 0 && imageBounds.outHeight > 0) {
            return ProbedAsset(
                relativePath = request.relativePath,
                kind = "image",
                mimeType = imageBounds.outMimeType ?: "",
                byteCount = file.length(),
                width = imageBounds.outWidth,
                height = imageBounds.outHeight,
            )
        }
        val video = runCatching { AssetProbe.probe(file, "video") }.getOrNull()
        if (video != null) {
            capabilities.capabilities()
            return ProbedAsset(
                relativePath = request.relativePath,
                kind = "video",
                mimeType = video.mimeType ?: "",
                byteCount = file.length(),
                width = video.width,
                height = video.height,
                durationSeconds = video.durationSeconds,
                frameRate = video.frameRate,
                audioTrackCount = video.audioTrackCount,
                rotationDegrees = video.rotationDegrees,
                codec = video.mimeType,
                unsupportedReason = video.mimeType?.let {
                    if (capabilities.hasVideoDecoder(it)) null else "No platform decoder for $it"
                },
            )
        }
        val audio = runCatching { AssetProbe.probe(file, "audio") }.getOrNull()
        if (audio != null) {
            return ProbedAsset(
                relativePath = request.relativePath,
                kind = "audio",
                mimeType = audio.mimeType ?: "",
                byteCount = file.length(),
                durationSeconds = audio.durationSeconds,
                audioTrackCount = audio.audioTrackCount,
                codec = audio.mimeType,
            )
        }
        return ProbedAsset(
            relativePath = request.relativePath,
            kind = "unknown",
            mimeType = "",
            byteCount = file.length(),
            unsupportedReason = "The file is not a supported image, video or audio asset",
        )
    }

    override suspend fun renderImagePreview(request: ImagePreviewRequest): ImagePreviewReceipt =
        withContext(config.ioDispatcher) { renderImagePreviewInternal(request) }

    private suspend fun renderImagePreviewInternal(request: ImagePreviewRequest): ImagePreviewReceipt {
        validateBindingStructure(request.binding)
        if (request.window != null) {
            throw CreativeException(
                RENDER_UNSUPPORTED,
                "A time window is not applicable to a still-image project preview",
            )
        }
        if (request.binding.context.projectID.isBlank() ||
            !CreativeSessionTokens.isValid(request.binding.context.sessionToken)
        ) {
            throw CreativeException("invalidSession", "A valid project/session context is required")
        }
        val decision = authority.validateRenderBinding(request.binding)
        val grant = when (decision) {
            is AuthorityDecision.Accepted -> decision.grant
            is AuthorityDecision.Refused -> throw CreativeException(decision.code, decision.reason, decision.retryable)
        }
        val pin = try {
            pins.acquire(
                MediaLifecyclePinRequest(
                    context = request.binding.context,
                    kind = MediaLifecycleKind.PREVIEW,
                    epoch = grant.epoch,
                    mediaRootPath = grant.mediaRootPath,
                    attemptID = request.binding.attemptID,
                ),
            )
        } catch (failure: MediaRefusal) {
            throw CreativeException(failure.code, failure.message, failure.retryable, failure)
        }
        try {
            val snapshot = try {
                SnapshotVerifier.verify(expectationFor(request.binding, grant.epoch), grant, clock)
            } catch (failure: MediaRefusal) {
                throw CreativeException(failure.code, failure.message, failure.retryable, failure)
            }
            val encoded = try {
                ImageExporter.preview(snapshot)
            } catch (failure: MediaRefusal) {
                throw CreativeException(failure.code, failure.message, failure.retryable, failure)
            }
            val relative = "Workbench/Previews/${request.binding.attemptID}.png"
            val output = MediaPaths.resolveOutputUnder(snapshot.root, relative)
                ?: throw CreativeException(STORAGE_UNAVAILABLE, "Preview path escapes the trusted media root")
            if (output.exists()) {
                throw CreativeException(WRITE_FAILED, "The preview attempt already exists")
            }
            val parent = output.parentFile
                ?: throw CreativeException(STORAGE_UNAVAILABLE, "Preview directory is unavailable")
            if (!parent.isDirectory && !parent.mkdirs()) {
                throw CreativeException(STORAGE_UNAVAILABLE, "Preview directory could not be created")
            }
            val staging = File(parent, ".${request.binding.attemptID}.png.part")
            try {
                staging.delete()
                writeFullySync(staging, encoded.bytes)
                val verified = ImageVerifier.verify(
                    staging,
                    encoded.width,
                    encoded.height,
                    "png",
                    ImageExporter.MAX_OUTPUT_BYTES,
                )
                atomicReplace(staging, output)
                return ImagePreviewReceipt(
                    binding = MediaExportReceiptBinding(
                        projectID = request.binding.context.projectID,
                        mediaRootPath = snapshot.root.path,
                        projectRevision = request.binding.projectRevision,
                        timelineDigest = request.binding.timelineDigest,
                        attemptID = request.binding.attemptID,
                    ),
                    previewRelativePath = relative,
                    mimeType = "image/png",
                    byteCount = verified.byteCount,
                    sha256 = verified.sha256,
                    width = encoded.width,
                    height = encoded.height,
                    generatedAt = clock.nowIso(),
                )
            } catch (failure: MediaRefusal) {
                staging.delete()
                throw CreativeException(failure.code, failure.message, failure.retryable, failure)
            } catch (failure: Exception) {
                staging.delete()
                throw CreativeException(WRITE_FAILED, "Preview could not be published", false, failure)
            }
        } finally {
            // Actual preview render/read/write has stopped (or failed) before
            // the native pin is released. A failed release is retained by the
            // tracker and makes session drain fail closed.
            pins.release(pin)
        }
    }

    override suspend fun submitExport(request: MediaExportRequest): MediaExportJobHandle =
        withContext(config.ioDispatcher) { submitExportInternal(request) }

    private suspend fun submitExportInternal(request: MediaExportRequest): MediaExportJobHandle {
        val handle = try {
            runtime.submit(request)
        } catch (failure: MediaRefusal) {
            throw CreativeException(failure.code, failure.message, failure.retryable, failure)
        }
        if (!MediaExportService.start(context, handle.jobID)) {
            runtime.failStart(
                handle.jobID,
                "foregroundStartDenied",
                "The export could not start its foreground service; run it from the foreground",
            )
        }
        val job = runtime.job(handle.jobID)
        return MediaExportJobHandle(
            jobID = handle.jobID,
            kind = handle.kind,
            state = job?.status?.state ?: MediaExportState.FAILED,
            acceptedAt = handle.acceptedAt,
        )
    }

    override suspend fun exportStatus(
        context: com.floe.android.feature.workbench.CreativeProjectContext,
        jobID: String,
    ): MediaExportStatus = withContext(config.ioDispatcher) { exportStatusInternal(context, jobID) }

    private suspend fun exportStatusInternal(
        context: com.floe.android.feature.workbench.CreativeProjectContext,
        jobID: String,
    ): MediaExportStatus = try {
        runtime.status(context, jobID)
    } catch (failure: MediaRefusal) {
        throw CreativeException(failure.code, failure.message, failure.retryable, failure)
    }

    override suspend fun cancelExport(
        context: com.floe.android.feature.workbench.CreativeProjectContext,
        jobID: String,
    ): MediaExportJobHandle = withContext(config.ioDispatcher) { cancelExportInternal(context, jobID) }

    private suspend fun cancelExportInternal(
        context: com.floe.android.feature.workbench.CreativeProjectContext,
        jobID: String,
    ): MediaExportJobHandle {
        val handle = try {
            runtime.cancel(context, jobID)
        } catch (failure: MediaRefusal) {
            throw CreativeException(failure.code, failure.message, failure.retryable, failure)
        }
        MediaExportService.cancel(this.context, jobID)
        return handle
    }

    override fun observeExport(
        context: com.floe.android.feature.workbench.CreativeProjectContext,
        jobID: String,
        listener: (MediaExportStatus) -> Unit,
    ): AutoCloseable = try {
        runtime.observe(context, jobID, listener)
    } catch (failure: MediaRefusal) {
        throw CreativeException(failure.code, failure.message, failure.retryable, failure)
    }

    private fun validateBindingStructure(binding: MediaExportBinding) {
        if (binding.attemptID.isBlank() || !MediaPaths.safeComponent(binding.attemptID)) {
            throw CreativeException("invalidPayload", "The attempt id is not a safe component")
        }
        if (binding.mediaRootPath != binding.snapshot.mediaRootPath) {
            throw CreativeException(RENDER_UNSUPPORTED, "The binding root differs from the snapshot lease root")
        }
    }

    private fun expectationFor(binding: MediaExportBinding, epoch: Long): SnapshotExpectation =
        SnapshotExpectation(
            epoch = epoch,
            projectID = binding.context.projectID,
            revision = binding.projectRevision,
            timelineDigest = binding.timelineDigest,
            mediaRootPath = binding.mediaRootPath,
            attemptID = binding.attemptID,
            lease = binding.snapshot,
        )
}
