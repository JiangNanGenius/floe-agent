// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import android.graphics.Bitmap
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ImageExportSettings
import com.floe.android.feature.workbench.ImagePreviewRequest
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.RenderCapabilities
import com.floe.android.feature.workbench.VideoExportSettings
import com.floe.android.feature.workbench.ui.presentation.MediaBitmapLoader
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import com.floe.android.feature.workbench.ui.presentation.MediaPreviewPaths
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * G09-R2 feature editor capability bundle for one project editor.
 *
 * It owns only UI-facing retained state: real render capabilities, the
 * retained playback handle, generation state and the session export
 * coordinator. Every project mutation still runs through the R1 controller's
 * single CAS transaction path.
 */
@Stable
class MediaR2Editor internal constructor(
    private val ports: WorkbenchR2Ports,
    private val context: CreativeProjectContext,
    private val scope: CoroutineScope,
    private val projectKindProvider: () -> String,
    private val revisionProvider: () -> Long,
    private val retiredProvider: () -> Boolean,
    private val onPlaybackPosition: (Double) -> Unit,
    private val onProjectMutated: () -> Unit,
    val exports: MediaExportCoordinator,
) {
    val generation = WorkbenchGenerationController(
        api = ports.generation,
        context = context,
        scope = scope,
        isRetired = retiredProvider,
        onProjectMutated = onProjectMutated,
    )

    val enhancement = WorkbenchEnhancementController(
        api = ports.enhancement,
        context = context,
        scope = scope,
        isRetired = { retiredProvider() },
    )

    /**
     * Shared super-resolution backend configuration state for this editor.
     * The SAME flow backs the settings entry; the native side owns the one
     * typed configuration row and the credential in the original stores.
     */
    val enhancementConfiguration = WorkbenchEnhancementConfigurationController(
        api = ports.enhancementConfiguration,
        scope = scope,
    )

    val playback = WorkbenchPlaybackController(
        platform = ports.platform,
        prepareBinding = ports.renderBindings,
        releaseBinding = ports.releaseRenderBinding,
        contextProvider = { context },
        onPosition = onPlaybackPosition,
        scope = scope,
    )

    var capabilities: RenderCapabilities? by mutableStateOf(null)
        private set
    var capabilitiesLoading: Boolean by mutableStateOf(false)
        private set
    var capabilitiesFailure: MediaFailure? by mutableStateOf(null)
        private set

    var exportBusy: Boolean by mutableStateOf(false)
        private set
    var exportFailure: MediaFailure? by mutableStateOf(null)
        private set
    var lastExportJobID: String? by mutableStateOf(null)
        private set

    var imagePreview: Bitmap? by mutableStateOf(null)
        private set
    var imagePreviewBusy: Boolean by mutableStateOf(false)
        private set
    var imagePreviewFailure: MediaFailure? by mutableStateOf(null)
        private set
    var imagePreviewRevision: Long? by mutableStateOf(null)
        private set

    private var started = false
    private var previewJob: Job? = null

    fun start() {
        if (started || retiredProvider()) return
        started = true
        scope.launch { loadCapabilities() }
        scope.launch { exports.reattach(context) }
        generation.start()
    }

    fun stop() {
        generation.stop()
        previewJob?.cancel()
        previewJob = null
        playback.close()
    }

    fun clearExportFailure() {
        exportFailure = null
    }

    fun reattachExports() {
        if (retiredProvider()) return
        scope.launch { exports.reattach(context) }
    }

    fun clearImagePreviewFailure() {
        imagePreviewFailure = null
    }

    private suspend fun loadCapabilities() {
        if (capabilitiesLoading) return
        capabilitiesLoading = true
        try {
            val value = withContext(Dispatchers.Default) { ports.platform.capabilities() }
            if (!retiredProvider()) {
                capabilities = value
                capabilitiesFailure = null
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (!retiredProvider()) capabilitiesFailure = MediaFailures.from(error)
        } finally {
            capabilitiesLoading = false
        }
    }

    fun reloadCapabilities() {
        capabilitiesFailure = null
        capabilities = null
        scope.launch { loadCapabilities() }
    }

    // MARK: - Playback

    /** Rebuilds playback against the exact new revision (never a stale lease). */
    fun onVideoTimelineChanged(revision: Long, playheadSeconds: Double) {
        if (retiredProvider()) return
        playback.prepare(revision, playheadSeconds)
    }

    fun preparePlayback(revision: Long, playheadSeconds: Double) {
        if (retiredProvider()) return
        playback.prepare(revision, playheadSeconds)
    }

    // MARK: - Image preview (real platform renderer)

    fun requestImagePreview(debounceMillis: Long = 250L) {
        if (projectKindProvider() != "image" || retiredProvider()) return
        previewJob?.cancel()
        previewJob = scope.launch {
            delay(debounceMillis)
            renderImagePreview()
        }
    }

    private suspend fun renderImagePreview() {
        if (retiredProvider() || projectKindProvider() != "image") return
        imagePreviewBusy = true
        imagePreviewFailure = null
        val revision = revisionProvider()
        val attemptID = "preview-${UUID.randomUUID()}"
        var binding: MediaExportBinding? = null
        try {
            val prepared = ports.renderBindings.prepareRenderBinding(context, revision, attemptID)
            binding = prepared
            val receipt = ports.platform.renderImagePreview(ImagePreviewRequest(prepared))
            if (retiredProvider()) return
            val bitmap = withContext(Dispatchers.IO) {
                val path = MediaPreviewPaths.resolve(
                    prepared.mediaRootPath,
                    receipt.previewRelativePath,
                )
                path?.let { MediaBitmapLoader.load(it) }
            }
            if (bitmap == null) {
                imagePreviewFailure = MediaFailure(
                    com.floe.android.feature.workbench.ui.presentation.MediaFailureKind.EXPORT,
                    "rendererUnavailable",
                )
            } else {
                imagePreview = bitmap
                imagePreviewRevision = revision
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (!retiredProvider()) imagePreviewFailure = MediaFailures.from(error)
        } finally {
            imagePreviewBusy = false
            val prepared = binding
            if (prepared != null) {
                runCatching { ports.releaseRenderBinding.releaseRenderBinding(prepared) }
            }
        }
    }

    // MARK: - Export

    fun submitVideoExport(settings: VideoExportSettings) {
        submitExport(MediaExportKind.VIDEO) { binding ->
            MediaExportRequest.Video(binding, settings)
        }
    }

    fun submitImageExport(settings: ImageExportSettings) {
        submitExport(MediaExportKind.IMAGE) { binding ->
            MediaExportRequest.Image(binding, settings)
        }
    }

    /**
     * Explicit user retry only. A new attempt id and a fresh immutable binding
     * are used; an automatic retry after an unknown outcome never happens.
     */
    fun retryExport(jobID: String) {
        val record = exports.job(jobID) ?: return
        if (!record.owner.matches(context)) return
        if (!record.terminal || record.recovered) return
        val original = record.request ?: return
        submitExport(record.kind) { binding ->
            when (original) {
                is MediaExportRequest.Video ->
                    MediaExportRequest.Video(binding, original.settings)
                is MediaExportRequest.Image ->
                    MediaExportRequest.Image(binding, original.settings)
            }
        }
    }

    private fun submitExport(
        kind: MediaExportKind,
        build: (MediaExportBinding) -> MediaExportRequest,
    ) {
        if (retiredProvider() || exportBusy) return
        scope.launch {
            exportBusy = true
            exportFailure = null
            val attemptID = "export-${UUID.randomUUID()}"
            var binding: MediaExportBinding? = null
            try {
                val prepared = ports.renderBindings.prepareRenderBinding(
                    context,
                    revisionProvider(),
                    attemptID,
                )
                binding = prepared
                val request = build(prepared)
                val record = exports.submit(context, attemptID, request)
                lastExportJobID = record.jobID
                binding = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                exportFailure = MediaFailures.from(error)
            } finally {
                exportBusy = false
                val prepared = binding
                if (prepared != null) {
                    runCatching { ports.releaseRenderBinding.releaseRenderBinding(prepared) }
                }
            }
        }
    }

    suspend fun deliverExport(
        jobID: String,
        receipt: MediaExportReceipt,
    ): WorkbenchExportDeliveryResult {
        val result = try {
            ports.exportDelivery.deliverExport(receipt)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            WorkbenchExportDeliveryResult.Failed(
                (error as? com.floe.android.feature.canvas.CreativeException)?.code,
            )
        }
        exports.markDelivered(jobID, result)
        return result
    }
}
