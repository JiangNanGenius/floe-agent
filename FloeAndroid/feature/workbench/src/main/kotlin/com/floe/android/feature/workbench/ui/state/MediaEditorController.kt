// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.state

import android.graphics.Bitmap
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CaptionAlignment
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.MediaAssetMetadata
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MergedLayerRaster
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoEditCommand
import com.floe.android.feature.workbench.VideoGenerationRequest
import com.floe.android.feature.workbench.VideoProjectEnvelope
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import com.floe.android.feature.workbench.WorkbenchHostApi
import com.floe.android.feature.workbench.WorkbenchR2Limits
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaGalleryCollection
import com.floe.android.feature.workbench.ui.api.MediaGallerySaveOutcome
import com.floe.android.feature.workbench.ui.api.MediaLayerRasterRequest
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.presentation.MediaBitmapLoader
import com.floe.android.feature.workbench.ui.presentation.MediaCommandPlanner
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import com.floe.android.feature.workbench.ui.presentation.MediaLayerGeometry
import com.floe.android.feature.workbench.ui.presentation.MediaNotice
import com.floe.android.feature.workbench.ui.presentation.MediaPreviewPaths
import com.floe.android.feature.workbench.ui.r2.MediaExportCoordinator
import com.floe.android.feature.workbench.ui.r2.MediaR2Editor
import com.floe.android.feature.workbench.ui.r2.VideoCommandPlanner
import com.floe.android.feature.workbench.ui.r2.WorkbenchExportDeliveryResult
import com.floe.android.feature.workbench.ui.r2.WorkbenchR2Ports
import com.floe.android.feature.workbench.ui.r2.WorkbenchVideoMath
import java.util.UUID
import kotlin.math.max
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Retained media project editor.
 *
 * The controller owns the exact editor token, the loaded native envelope and
 * the selection; the persisted project (including undo/redo history) is always
 * native. Preview bitmaps are decoded only from the trusted envelope
 * `mediaRootPath` with a bounded sampler and are never written back.
 */
@Stable
class MediaEditorController internal constructor(
    private val host: WorkbenchHostApi,
    private val ports: MediaEditorPorts,
    initial: MediaProjectEnvelope,
    val sessionToken: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
    val editCopy: Boolean,
    private val scope: CoroutineScope,
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
    private val onRetired: (MediaEditorController) -> Unit = {},
    private val r2Ports: WorkbenchR2Ports? = null,
    private val exportCoordinator: MediaExportCoordinator? = null,
) {
    var envelope: MediaProjectEnvelope by mutableStateOf(initial)
        private set
    var selectedLayerID: String? by mutableStateOf(null)
        private set
    var busy by mutableStateOf(false)
        private set
    /** C03 long-file transcription in flight; it does not borrow [busy] so the
     * editor can show the real progress/error without a fake apply state. */
    var transcriptionBusy by mutableStateOf(false)
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var notice: MediaNotice? by mutableStateOf(null)
        private set
    var needsReload by mutableStateOf(false)
        private set
    var missingAssetIDs: Set<String> by mutableStateOf(emptySet())
        private set
    var previewRevision by mutableStateOf(0)
        private set
    val assetBitmaps = mutableStateMapOf<String, Bitmap>()

    // MARK: - G09-R2 retained video state

    var videoEnvelope: VideoProjectEnvelope? by mutableStateOf(null)
        private set
    var videoLoading by mutableStateOf(false)
        private set
    var selectedClipID: String? by mutableStateOf(null)
        private set
    var playheadSeconds: Double by mutableStateOf(0.0)
        private set
    var pixelsPerSecond by mutableStateOf(90f)
        private set
    var snapEnabled by mutableStateOf(true)
        private set
    var showCaptionSafeArea by mutableStateOf(false)
        private set
    var videoNotice: VideoNotice? by mutableStateOf(null)
        private set

    private val r2Context = CreativeProjectContext(
        projectID = initial.project.id,
        sessionToken = sessionToken,
        storage = storage,
        origin = origin,
    )

    /**
     * Real R2 capability bundle. Null means this session was created without
     * the R2 ports, so video stays an honest unavailable state and AI/export
     * entry points are not offered. There is no in-module stub.
     */
    val r2: MediaR2Editor? = if (r2Ports != null && exportCoordinator != null) {
        MediaR2Editor(
            ports = r2Ports,
            context = r2Context,
            scope = scope,
            projectKindProvider = { envelope.project.kind },
            revisionProvider = { envelope.project.revision },
            retiredProvider = { retired },
            onPlaybackPosition = { position ->
                if (position.isFinite() && position >= 0.0) playheadSeconds = position
            },
            onProjectMutated = { refreshProjectFromR2() },
            exports = exportCoordinator,
        )
    } else {
        null
    }

    val videoTimeline: VideoTimeline? get() = videoEnvelope?.timeline
    val videoPlaced: List<com.floe.android.feature.workbench.ui.r2.PlacedVideoClip>
        get() = videoTimeline?.let { WorkbenchVideoMath.placeClips(it.clips) }.orEmpty()
    val videoDuration: Double
        get() = r2?.playback?.durationSeconds?.takeIf { it > 0.0 }
            ?: WorkbenchVideoMath.duration(videoTimeline ?: VideoTimeline())
    val selectedVideoClip: VideoClip?
        get() = selectedClipID?.let { id -> videoTimeline?.clips?.firstOrNull { it.id == id } }

    val projectID: String get() = envelope.project.id
    val project get() = envelope.project
    val mediaRootPath: String get() = envelope.mediaRootPath
    val writable: Boolean get() = envelope.writable
    val revision: Long get() = envelope.project.revision
    val isImageProject: Boolean get() = envelope.project.kind == "image"
    val isVideoProject: Boolean get() = envelope.project.kind == "video"
    val selectedLayer: ImageLayer?
        get() = selectedLayerID?.let { id ->
            envelope.project.imageLayers.firstOrNull { it.id == id }
        }
    val canUndo: Boolean get() = envelope.project.canUndo && !busy && !needsReload
    val canRedo: Boolean get() = envelope.project.canRedo && !busy && !needsReload
    val layerRasterAvailable: Boolean get() = ports.layerRaster != null
    val gallerySaveAvailable: Boolean get() = ports.gallerySave != null

    private val operationMutex = Mutex()
    @Volatile private var retired = false
    @Volatile private var started = false

    fun start() {
        if (started || retired) return
        started = true
        scope.launch { refreshPreviews() }
        r2?.start()
        when {
            isVideoProject && r2 != null -> loadVideo()
            isImageProject && r2 != null -> r2?.requestImagePreview()
        }
    }

    fun selectLayer(layerID: String?) {
        selectedLayerID = layerID?.takeIf { id ->
            envelope.project.imageLayers.any { it.id == id }
        }
    }

    fun clearNotice() {
        notice = null
    }

    fun clearFailure() {
        if (failure?.kind == MediaFailureKind.REVISION_CONFLICT ||
            failure?.kind == MediaFailureKind.OUTCOME_UNKNOWN
        ) return
        failure = null
    }

    // MARK: - Project-level operations

    fun rename(newName: String) {
        val clean = newName.trim()
        if (clean.isEmpty() || busy || !writable) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    host.rename(
                        projectID = projectID,
                        expectedRevision = envelope.project.revision,
                        name = clean,
                        sessionToken = sessionToken,
                        storage = storage,
                        origin = origin,
                        opID = newOperationID(),
                    )
                    if (retired) return@withLock
                    refreshLocked()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun reload() {
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    if (refreshLocked()) {
                        selectedLayerID = selectedLayerID?.takeIf { id ->
                            envelope.project.imageLayers.any { it.id == id }
                        }
                        needsReload = false
                        notice = MediaNotice.RELOADED
                    }
                } finally {
                    busy = false
                }
            }
        }
    }

    fun undo() {
        runHistory(undo = true)
    }

    fun redo() {
        runHistory(undo = false)
    }

    private fun runHistory(undo: Boolean) {
        if (busy || needsReload) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    if (undo) {
                        host.undo(
                            projectID = projectID,
                            expectedRevision = envelope.project.revision,
                            sessionToken = sessionToken,
                            storage = storage,
                            origin = origin,
                            opID = newOperationID(),
                        )
                    } else {
                        host.redo(
                            projectID = projectID,
                            expectedRevision = envelope.project.revision,
                            sessionToken = sessionToken,
                            storage = storage,
                            origin = origin,
                            opID = newOperationID(),
                        )
                    }
                    if (retired) return@withLock
                    refreshLocked()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    val typed = error as? CreativeException
                    if (typed?.reason in setOf("nothingToUndo", "nothingToRedo")) {
                        failure = null
                    } else {
                        handleFailure(error)
                    }
                } finally {
                    busy = false
                }
            }
        }
    }

    // MARK: - C03 selection / layer merge / copy / fill / cut

    val hasSelection: Boolean
        get() = envelope.project.imageSelection?.let(::selectionHasShapes) == true

    fun clearLayerOperation() {
        layerOperation = LayerOperationState()
    }

    fun clearGallerySave() {
        gallerySave = GallerySaveState()
    }

    /** Full-canvas rectangle selection; the same vector selection engine as a drawn shape. */
    fun selectAll() {
        if (!isImageProject) return
        launchCommand(
            MediaEditCommand.SetImageSelection(selectAllSelection()),
            successCompletion = LayerOperationCompletion.SELECTION_SET,
        )
    }

    fun clearSelection() {
        if (!isImageProject) return
        launchCommand(
            MediaEditCommand.SetImageSelection(null),
            successCompletion = LayerOperationCompletion.SELECTION_CLEARED,
        )
    }

    /**
     * Explicit normalized rectangle selection (0...1). This is the same
     * vector rectangle shape the shared command engine/rendering mask accepts;
     * it is not a pixel-snapshot or a second selection store.
     */
    fun setRectangleSelection(x: Double, y: Double, width: Double, height: Double) {
        if (!isImageProject) return
        if (!x.isFinite() || !y.isFinite() || !width.isFinite() || !height.isFinite() ||
            x < 0.0 || y < 0.0 || width <= 0.0 || height <= 0.0 ||
            x + width > 1.0001 || y + height > 1.0001
        ) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "invalidSelectionRect"),
            )
            return
        }
        launchCommand(
            MediaEditCommand.SetImageSelection(
                rectangleSelection(
                    x.coerceIn(0.0, 1.0),
                    y.coerceIn(0.0, 1.0),
                    width.coerceIn(0.0, 1.0 - x.coerceIn(0.0, 1.0)),
                    height.coerceIn(0.0, 1.0 - y.coerceIn(0.0, 1.0)),
                ),
            ),
            successCompletion = LayerOperationCompletion.SELECTION_SET,
        )
    }

    /**
     * Selection fill: a real `.fill` image layer masked by the complete vector
     * selection. This is the fixed iOS `fillSelection` semantics, not a
     * bucket-fill that guesses a colour from neighboring pixels.
     */
    fun fillSelection(colorHex: String = "#FFFFFF", opacity: Double = 1.0) {
        if (!isImageProject || busy || !writable || needsReload) return
        val selection = envelope.project.imageSelection
        if (selection == null || !selectionHasShapes(selection)) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "selectionRequired"),
            )
            return
        }
        val layerID = UUID.randomUUID().toString()
        val layer = ImageLayer(
            id = layerID,
            kind = "fill",
            name = "Fill",
            transform = com.floe.android.feature.workbench.ImageLayerTransform(),
            opacity = opacity.coerceIn(0.0, 1.0),
            selectionMask = selection,
            fillColorHex = colorHex,
        )
        launchCommand(
            MediaEditCommand.AddImageLayer(layer),
            onSuccess = { selectedLayerID = layerID },
            successCompletion = LayerOperationCompletion.FILLED,
        )
    }

    /** Non-destructive cut: the native engine appends one region mask stroke. */
    fun cutSelection(layerID: String? = selectedLayerID) {
        if (!isImageProject) return
        val id = layerID ?: return
        val layer = envelope.project.imageLayers.firstOrNull { it.id == id } ?: return
        if (layer.isLocked) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "layerLocked"),
            )
            return
        }
        if (!hasSelection) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "selectionRequired"),
            )
            return
        }
        launchCommand(
            MediaEditCommand.CutSelection(layerID = id),
            successCompletion = LayerOperationCompletion.CUT,
        )
    }

    /**
     * Renders the selection ∩ source layer through the real platform renderer,
     * registers the verified PNG as a project asset, then commits addAsset +
     * copySelection as ONE native CAS/undo transaction.
     */
    fun copySelectionToNewLayer(sourceLayerID: String? = selectedLayerID) {
        val port = ports.layerRaster
        if (port == null || !isImageProject || busy || !writable || needsReload) return
        val sourceID = sourceLayerID ?: return
        val source = envelope.project.imageLayers.firstOrNull { it.id == sourceID } ?: return
        if (source.isLocked) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "layerLocked"),
            )
            return
        }
        val selection = envelope.project.imageSelection
        if (selection == null || !selectionHasShapes(selection)) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "selectionRequired"),
            )
            return
        }
        runLayerRasterTransaction(port, "copySelection", listOf(sourceID), selection) { receipt ->
            val asset = receipt.toAssetReference()
            listOf(
                MediaEditCommand.AddAsset(asset),
                MediaEditCommand.CopySelection(
                    sourceLayerID = sourceID,
                    name = "Selection Copy",
                    raster = MergedLayerRaster(
                        assetID = receipt.assetID,
                        width = receipt.width,
                        height = receipt.height,
                        contentHash = receipt.sha256,
                    ),
                ),
            )
        }
    }

    /**
     * Renders ONLY the named visible layers through the shared full-canvas
     * renderer (no whole-canvas adjustment), registers the verified PNG, then
     * commits addAsset + mergeLayers as ONE native CAS/undo transaction.
     */
    fun mergeLayers(layerIDs: List<String>, name: String? = null) {
        val port = ports.layerRaster
        val ids = layerIDs.distinct()
        if (port == null || !isImageProject || busy || !writable || needsReload) return
        if (ids.size < 2 || ids.size != layerIDs.size) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "mergeNeedsTwoLayers"),
            )
            return
        }
        if (ids.any { id ->
                val layer = envelope.project.imageLayers.firstOrNull { it.id == id }
                layer == null || layer.isLocked
            }
        ) {
            layerOperation = LayerOperationState(
                failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "layerLocked"),
            )
            return
        }
        val mergeName = name?.trim()?.takeIf { it.isNotEmpty() }
        runLayerRasterTransaction(port, "merge", ids, null) { receipt ->
            val asset = receipt.toAssetReference()
            listOf(
                MediaEditCommand.AddAsset(asset),
                MediaEditCommand.MergeLayers(
                    ids = ids,
                    name = mergeName,
                    raster = MergedLayerRaster(
                        assetID = receipt.assetID,
                        width = receipt.width,
                        height = receipt.height,
                        contentHash = receipt.sha256,
                    ),
                ),
            )
        }
    }

    private fun runLayerRasterTransaction(
        port: com.floe.android.feature.workbench.ui.api.MediaLayerRasterPort,
        mode: String,
        layerIDs: List<String>,
        selection: kotlinx.serialization.json.JsonObject?,
        build: (com.floe.android.feature.workbench.ui.api.MediaLayerRasterReceipt) -> List<MediaEditCommand>,
    ): Boolean {
        if (busy || !writable || needsReload) return false
        val completion = if (mode == "merge") {
            LayerOperationCompletion.MERGED
        } else {
            LayerOperationCompletion.COPIED
        }
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                layerOperation = LayerOperationState(busy = true)
                try {
                    val request = MediaLayerRasterRequest(
                        layerIDs = layerIDs,
                        selection = selection,
                        name = if (mode == "merge") "Merged layers" else "Selection copy",
                    )
                    val receipt = port.renderLayerRaster(
                        context = r2Context,
                        expectedRevision = envelope.project.revision,
                        mode = mode,
                        request = request,
                    )
                    if (retired) return@withLock
                    if (receipt.projectID != projectID ||
                        receipt.projectRevision != envelope.project.revision
                    ) {
                        layerOperation = LayerOperationState(
                            failure = MediaFailure(
                                MediaFailureKind.REVISION_CONFLICT,
                                "layerRasterRevisionChanged",
                            ),
                        )
                        return@withLock
                    }
                    if (!applyCommandsLocked(build(receipt))) {
                        layerOperation = LayerOperationState(
                            failure = failure ?: MediaFailure(
                                MediaFailureKind.REVISION_CONFLICT,
                                "layerCommitFailed",
                            ),
                        )
                        return@withLock
                    }
                    layerOperation = LayerOperationState(completed = completion)
                    selectedLayerID = envelope.project.imageLayers
                        .firstOrNull { it.assetID == receipt.assetID }?.id
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                    layerOperation = LayerOperationState(failure = MediaFailures.from(error))
                } finally {
                    busy = false
                    if (layerOperation.busy) {
                        layerOperation = layerOperation.copy(busy = false)
                    }
                }
            }
        }
        return Unit
    }

    private fun selectAllSelection(): kotlinx.serialization.json.JsonObject = buildJsonObject {
        put("feather", 0.0)
        put("inverted", false)
        putJsonArray("shapes") {
            add(buildJsonObject {
                put("kind", "rectangle")
                put("operation", "replace")
                putJsonArray("points") {
                    add(buildJsonObject { put("x", 0.0); put("y", 0.0) })
                    add(buildJsonObject { put("x", 1.0); put("y", 1.0) })
                }
            })
        }
    }

    private fun rectangleSelection(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
    ): kotlinx.serialization.json.JsonObject = buildJsonObject {
        put("feather", 0.0)
        put("inverted", false)
        putJsonArray("shapes") {
            add(buildJsonObject {
                put("kind", "rectangle")
                put("operation", "replace")
                putJsonArray("points") {
                    add(buildJsonObject { put("x", x); put("y", y) })
                    add(buildJsonObject { put("x", x + width); put("y", y + height) })
                }
            })
        }
    }

    private fun selectionHasShapes(value: kotlinx.serialization.json.JsonObject): Boolean {
        val shapes = value["shapes"] as? kotlinx.serialization.json.JsonArray ?: return false
        return shapes.isNotEmpty()
    }

    private fun com.floe.android.feature.workbench.ui.api.MediaLayerRasterReceipt
        .toAssetReference(): MediaAssetReference = MediaAssetReference(
            id = assetID,
            kind = "image",
            relativePath = relativePath,
            originalName = originalName,
            byteCount = byteCount,
            contentHash = sha256,
            metadata = MediaAssetMetadata(width = width, height = height, hasAlpha = true),
        )

    // MARK: - Gallery save

    /**
     * Saves one verified image/video export receipt to the device gallery
     * through the App-owned MediaStore port. The receipt is re-proved against
     * the live project root inside the host; this controller never passes a
     * path or fabricates a URI.
     */
    fun saveReceiptToGallery(jobID: String, receipt: com.floe.android.feature.workbench.MediaExportReceipt) {
        val port = ports.gallerySave
        if (port == null || gallerySave.busy) return
        if (receipt.binding.projectID != projectID) {
            gallerySave = GallerySaveState(
                failure = MediaFailure(MediaFailureKind.OWNER_BLOCKED, "galleryOwnerMismatch"),
            )
            return
        }
        val job = r2?.exports?.job(jobID)
        if (job != null && !job.owner.matches(r2Context)) {
            gallerySave = GallerySaveState(
                failure = MediaFailure(MediaFailureKind.OWNER_BLOCKED, "galleryOwnerMismatch"),
            )
            return
        }
        val collection = if (receipt.kind == MediaExportKind.IMAGE) {
            MediaGalleryCollection.IMAGE
        } else {
            MediaGalleryCollection.VIDEO
        }
        scope.launch {
            gallerySave = GallerySaveState(busy = true)
            try {
                when (val outcome = port.saveToGallery(r2Context, receipt, collection)) {
                    is MediaGallerySaveOutcome.Saved -> {
                        gallerySave = GallerySaveState(savedDisplayName = outcome.displayName)
                    }
                    is MediaGallerySaveOutcome.PermissionRequired -> {
                        gallerySave = GallerySaveState(permission = outcome.permission)
                    }
                    is MediaGallerySaveOutcome.Failed -> {
                        gallerySave = GallerySaveState(
                            failure = MediaFailure(
                                when (outcome.code) {
                                    "galleryOwnerMismatch", "galleryRootRefused",
                                    "gallerySourceRefused", "gallerySourceChanged" ->
                                        MediaFailureKind.OWNER_BLOCKED
                                    "galleryStagingUnavailable", "galleryDirectoryUnavailable",
                                    "galleryPendingInsertFailed", "galleryWriteFailed" ->
                                        MediaFailureKind.STORAGE
                                    "unsupportedMimeType", "collectionMismatch",
                                    "invalidReceipt", "unverifiedReceipt" ->
                                        MediaFailureKind.INVALID_REQUEST
                                    else -> MediaFailureKind.EXPORT
                                },
                                outcome.code,
                                outcome.retryable,
                            ),
                            pendingCleaned = outcome.pendingCleaned,
                        )
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                gallerySave = GallerySaveState(failure = MediaFailures.from(error))
            }
        }
    }

    // MARK: - Assets / layers

    fun importAsset(picked: MediaPickedSource) {
        if (busy || !writable || needsReload) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    val receipt = ports.assetImport.importMediaAsset(
                        source = picked,
                        projectID = projectID,
                        expectedRevision = envelope.project.revision,
                        storage = storage,
                        origin = origin,
                        sessionToken = sessionToken,
                        opID = newOperationID(),
                    )
                    if (retired) return@withLock
                    if (!refreshLocked()) return@withLock
                    if (isImageProject) {
                        val layerID = UUID.randomUUID().toString()
                        val applied = executeCommandLocked(
                            MediaCommandPlanner.addImageLayer(receipt.asset, id = layerID))
                        notice = if (applied) {
                            if (applied) selectedLayerID = layerID
                            MediaNotice.ASSET_IMPORTED
                        } else {
                            MediaNotice.ASSET_IMPORTED_NO_LAYER
                        }
                    } else {
                        notice = MediaNotice.ASSET_IMPORTED
                    }
                    schedulePreviews()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun addAssetAsLayer(assetID: String) {
        val asset = envelope.project.assets.firstOrNull { it.id == assetID } ?: return
        if (asset.kind != "image" || !isImageProject) return
        val layerID = UUID.randomUUID().toString()
        launchCommand(
            MediaCommandPlanner.addImageLayer(asset, id = layerID),
            onSuccess = { selectedLayerID = layerID },
        )
    }

    fun addTextLayer(
        text: String,
        fontSize: Double = 48.0,
        colorHex: String = "#000000",
    ) {
        if (text.isBlank() || !isImageProject) return
        val layerID = UUID.randomUUID().toString()
        launchCommand(
            MediaCommandPlanner.addTextLayer(text, fontSize, colorHex, id = layerID),
            onSuccess = { selectedLayerID = layerID },
        )
    }

    fun addFreehandStroke(stroke: ImageFreehandStroke, layerName: String = "Drawing") {
        if (!isImageProject || stroke.points.isEmpty()) return
        val layer = selectedLayer?.takeIf { it.kind == "freehand" && !it.isLocked }
        if (layer != null) {
            launchCommand(MediaCommandPlanner.addFreehandStroke(layer, stroke))
            return
        }
        val layerID = UUID.randomUUID().toString()
        launchCommand(
            MediaCommandPlanner.addFreehandLayer(stroke, id = layerID, name = layerName),
            onSuccess = { selectedLayerID = layerID },
        )
    }

    fun setOpacity(value: Double) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.updateOpacity(layer, value))
    }

    fun setScale(value: Double) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.updateTransform(layer, scale = value))
    }

    fun setRotation(value: Double) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.updateTransform(layer, rotationDegrees = value))
    }

    fun setCenter(centerX: Double, centerY: Double) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.updateTransform(layer, centerX, centerY))
    }

    fun flip(horizontal: Boolean) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.flip(layer, horizontal))
    }

    fun setHidden(hidden: Boolean) {
        val layer = selectedLayer ?: return
        launchCommand(MediaCommandPlanner.setHidden(layer, hidden))
    }

    fun setLocked(locked: Boolean) {
        val layer = selectedLayer ?: return
        launchCommand(MediaCommandPlanner.setLocked(layer, locked))
    }

    fun setCrop(crop: NormalizedRect?) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer) || layer.kind != "image") return
        launchCommand(MediaCommandPlanner.setCrop(layer, crop))
    }

    fun setCropAspect(aspect: Double?) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer) || layer.kind != "image") return
        val asset = layer.assetID?.let { id ->
            envelope.project.assets.firstOrNull { it.id == id }
        }
        val bitmap = layer.assetID?.let { assetBitmaps[it] }
        val width = bitmap?.width ?: asset?.metadata?.width ?: 0
        val height = bitmap?.height ?: asset?.metadata?.height ?: 0
        val rect = if (aspect == null) {
            null
        } else {
            if (width <= 0 || height <= 0) return
            MediaLayerGeometry.centeredCrop(aspect, width, height)
        }
        launchCommand(MediaCommandPlanner.setCrop(layer, rect))
    }

    fun setText(content: ImageTextContent) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer) || layer.kind != "text") return
        launchCommand(MediaCommandPlanner.updateText(layer, content))
    }

    fun setLayerAdjustment(adjustment: ImageLayerAdjustment) {
        val layer = selectedLayer ?: return
        if (!canEditGeometry(layer)) return
        launchCommand(MediaCommandPlanner.updateAdjustment(layer, adjustment))
    }

    fun setCanvasAdjustment(adjustment: ImageLayerAdjustment) {
        if (!isImageProject) return
        launchCommand(MediaCommandPlanner.setCanvasAdjustment(adjustment))
    }

    fun removeSelectedLayer() {
        val layer = selectedLayer ?: return
        if (layer.isLocked) return
        launchCommand(
            command = MediaCommandPlanner.remove(layer),
            successNotice = MediaNotice.LAYER_REMOVED,
            clearSelection = true,
        )
    }

    fun duplicateSelectedLayer() {
        val layer = selectedLayer ?: return
        launchCommand(MediaCommandPlanner.duplicate(layer))
    }

    fun moveSelectedLayer(up: Boolean) {
        val layer = selectedLayer ?: return
        if (layer.isLocked) return
        val layers = envelope.project.imageLayers
        val index = layers.indexOfFirst { it.id == layer.id }
        if (index < 0) return
        val target = if (up) index - 1 else index + 1
        if (target !in layers.indices) return
        launchCommand(MediaCommandPlanner.move(layer, target))
    }

    fun assetPath(assetID: String): String? {
        val asset = envelope.project.assets.firstOrNull { it.id == assetID } ?: return null
        return MediaPreviewPaths.resolve(envelope.mediaRootPath, asset.relativePath)
    }

    fun asset(assetID: String): MediaAssetReference? =
        envelope.project.assets.firstOrNull { it.id == assetID }

    // MARK: - G09-R2 video timeline

    fun selectClip(clipID: String?) {
        selectedClipID = clipID?.takeIf { id ->
            videoTimeline?.clips?.any { it.id == id } == true
        }
    }

    fun setPlayhead(seconds: Double) {
        val clamped = if (seconds.isFinite()) {
            seconds.coerceIn(0.0, max(0.0, videoDuration))
        } else {
            0.0
        }
        val snapped = if (snapEnabled) {
            WorkbenchVideoMath.snap(clamped, snapCandidates())
        } else {
            clamped
        }
        playheadSeconds = snapped
        r2?.playback?.seekTo(snapped)
    }

    fun updatePixelsPerSecond(value: Float) {
        pixelsPerSecond = value.coerceIn(20f, 240f)
    }

    fun updateSnapEnabled(value: Boolean) {
        snapEnabled = value
    }

    fun updateShowCaptionSafeArea(value: Boolean) {
        showCaptionSafeArea = value
    }

    fun clearVideoNotice() {
        videoNotice = null
    }

    fun reloadVideo() {
        loadVideo()
    }

    private fun snapCandidates(): List<Double> =
        videoTimeline?.let { WorkbenchVideoMath.snapCandidates(it) }.orEmpty()

    private fun loadVideo() {
        if (videoLoading || retired || r2 == null) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                videoLoading = true
                failure = null
                try {
                    if (!refreshVideoLocked()) needsReload = true
                } finally {
                    videoLoading = false
                }
            }
        }
    }

    private fun currentVideoRevision(): Long =
        videoEnvelope?.project?.revision ?: envelope.project.revision

    /**
     * Runs one video command batch inside the existing editor lock/busy
     * lifecycle. [build] may import an asset first; the expected revision is
     * read AFTER it returns so the CAS uses the revision caused by the import.
     */
    private fun runVideoTransaction(
        notice: VideoNotice? = null,
        afterCommit: (() -> Unit)? = null,
        build: suspend () -> List<VideoEditCommand>,
    ) {
        if (busy || !writable || needsReload) return
        val video = r2Ports?.video ?: return
        if (retired) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    val commands = build()
                    if (commands.isEmpty() || retired) return@withLock
                    if (commands.size > WorkbenchR2Limits.VIDEO_COMMANDS_PER_APPLY) {
                        failure = MediaFailure(
                            MediaFailureKind.INVALID_REQUEST,
                            "invalidPayload",
                        )
                        return@withLock
                    }
                    video.applyVideo(
                        context = r2Context,
                        expectedRevision = currentVideoRevision(),
                        opID = newOperationID(),
                        commands = commands,
                    )
                    if (retired) return@withLock
                    if (!refreshVideoLocked()) {
                        needsReload = true
                        return@withLock
                    }
                    afterCommit?.invoke()
                    if (notice != null) videoNotice = notice
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun applyVideoCommands(commands: List<VideoEditCommand>, notice: VideoNotice? = null) {
        if (commands.isEmpty()) return
        runVideoTransaction(notice) { commands }
    }

    /**
     * C03: transcribe the selected clip's real project asset through the
     * App-owned cloud route and write timed captions with the existing project
     * CAS. The port must resolve the exact project/asset; this controller never
     * falls back to a filename search or a preview blob. A failed/stale write
     * leaves [videoEnvelope] unchanged and sets a typed failure.
     */
    fun transcribeSelectedClip() {
        if (transcriptionBusy || retired || !writable || needsReload) return
        val port = ports.transcription ?: return
        val assetID = selectedVideoClip?.assetID
            ?: videoTimeline?.clips?.firstOrNull()?.assetID
            ?: return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                transcriptionBusy = true
                failure = null
                try {
                    val receipt = port.transcribeAndApply(
                        context = r2Context,
                        assetID = assetID,
                        expectedRevision = currentVideoRevision(),
                    )
                    if (retired) return@withLock
                    if (receipt.projectID != r2Context.projectID) {
                        failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "projectMismatch")
                        return@withLock
                    }
                    if (!refreshVideoLocked()) {
                        needsReload = true
                        return@withLock
                    }
                    videoNotice = VideoNotice.CAPTION_ADDED
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                } finally {
                    transcriptionBusy = false
                }
            }
        }
    }

    fun updateSelectedClip(
        trimStart: Double? = null,
        trimEnd: Double? = null,
        speed: Double? = null,
        volume: Double? = null,
        isMuted: Boolean? = null,
        rotationDegrees: Double? = null,
        crop: OptionalUpdate<NormalizedRect> = OptionalUpdate.Unchanged,
        leadingTransition: VideoTransitionKind? = null,
        transitionDuration: Double? = null,
    ) {
        val clip = selectedVideoClip ?: return
        val safeStart = trimStart?.let {
            it.coerceIn(0.0, max(0.0, clip.trimEnd - WorkbenchVideoMath.MIN_CLIP_DURATION))
        }
        val safeEnd = trimEnd?.let {
            it.coerceAtLeast(clip.trimStart + WorkbenchVideoMath.MIN_CLIP_DURATION)
        }
        val command = VideoCommandPlanner.updateClip(
            id = clip.id,
            trimStart = safeStart,
            trimEnd = safeEnd,
            speed = speed,
            volume = volume,
            isMuted = isMuted,
            rotationDegrees = rotationDegrees,
            crop = crop,
            leadingTransition = leadingTransition,
            transitionDuration = transitionDuration,
        )
        runVideoTransaction { listOf(command) }
    }

    fun setSelectedClipCropAspect(aspect: Double?) {
        val clip = selectedVideoClip ?: return
        if (aspect == null) {
            runVideoTransaction {
                listOf(VideoCommandPlanner.updateClip(clip.id, crop = OptionalUpdate.Clear))
            }
            return
        }
        val asset = asset(clip.assetID) ?: return
        val width = asset.metadata?.width ?: 0
        val height = asset.metadata?.height ?: 0
        val crop = WorkbenchVideoMath.centeredCrop(aspect, width, height) ?: return
        runVideoTransaction {
            listOf(
                VideoCommandPlanner.updateClip(
                    clip.id,
                    crop = OptionalUpdate.Set(crop),
                ),
            )
        }
    }

    fun setSelectedClipTransition(kind: VideoTransitionKind) {
        val clip = selectedVideoClip ?: return
        if (kind == VideoTransitionKind.CROSS_DISSOLVE &&
            r2?.capabilities?.crossDissolveSupported != true
        ) {
            return
        }
        runVideoTransaction {
            listOf(VideoCommandPlanner.updateClip(clip.id, leadingTransition = kind))
        }
    }

    fun splitSelectedClipAtPlayhead() {
        val placed = videoPlaced.firstOrNull { it.clip.id == selectedClipID } ?: return
        val offset = WorkbenchVideoMath.splitOffset(playheadSeconds, placed) ?: return
        runVideoTransaction(VideoNotice.CLIP_SPLIT) {
            listOf(VideoCommandPlanner.split(placed.clip.id, offset))
        }
    }

    fun duplicateSelectedClip() {
        val clip = selectedVideoClip ?: return
        runVideoTransaction(VideoNotice.CLIP_DUPLICATED) {
            listOf(VideoCommandPlanner.duplicate(clip.id))
        }
    }

    fun removeSelectedClip() {
        val clip = selectedVideoClip ?: return
        runVideoTransaction(VideoNotice.CLIP_REMOVED) {
            listOf(VideoCommandPlanner.remove(clip.id))
        }
    }

    fun moveSelectedClip(earlier: Boolean) {
        val timeline = videoTimeline ?: return
        val clipID = selectedClipID ?: return
        val command = VideoCommandPlanner.moveClip(timeline.clips, clipID, earlier) ?: return
        runVideoTransaction(VideoNotice.CLIP_REORDERED) { listOf(command) }
    }

    fun setPrimaryVolume(value: Double) {
        runVideoTransaction {
            listOf(VideoCommandPlanner.setPrimaryAudio(volume = value))
        }
    }

    fun setPrimaryMuted(muted: Boolean) {
        runVideoTransaction {
            listOf(VideoCommandPlanner.setPrimaryAudio(muted = muted))
        }
    }

    fun setCoverAtPlayhead() {
        if (videoDuration <= 0.0) return
        runVideoTransaction(VideoNotice.COVER_SET) {
            listOf(VideoCommandPlanner.setCover(playheadSeconds))
        }
    }

    fun clearCover() {
        runVideoTransaction(VideoNotice.COVER_CLEARED) {
            listOf(VideoCommandPlanner.setCover(null))
        }
    }

    fun setCaptionStyle(style: CaptionStyle) {
        runVideoTransaction {
            listOf(VideoCommandPlanner.setCaptionStyle(style))
        }
    }

    fun addCaption(text: String, startSeconds: Double, endSeconds: Double) {
        val command = VideoCommandPlanner.addCaption(text, startSeconds, endSeconds) ?: return
        runVideoTransaction(VideoNotice.CAPTION_ADDED) { listOf(command) }
    }

    fun updateCaption(
        captionID: String,
        start: Double? = null,
        end: Double? = null,
        text: String? = null,
    ) {
        val command = VideoCommandPlanner.updateCaption(captionID, start, end, text) ?: return
        runVideoTransaction { listOf(command) }
    }

    fun removeCaption(captionID: String) {
        runVideoTransaction(VideoNotice.CAPTION_REMOVED) {
            listOf(VideoCommandPlanner.removeCaption(captionID))
        }
    }

    fun shiftCaptions(bySeconds: Double) {
        runVideoTransaction(VideoNotice.CAPTION_SHIFTED) {
            listOf(VideoCommandPlanner.shiftCaptions(bySeconds))
        }
    }

    fun setVideoCanvas(width: Int, height: Int, frameRate: Double?) {
        runVideoTransaction(VideoNotice.CANVAS_UPDATED) {
            listOf(VideoCommandPlanner.setCanvas(width, height, frameRate))
        }
    }

    fun addMusic(assetID: String) {
        runVideoTransaction(VideoNotice.MUSIC_ADDED) {
            val asset = asset(assetID) ?: return@runVideoTransaction emptyList()
            val duration = resolveAssetDuration(asset)
                ?: throw CreativeException(
                    "unsupportedSourceFormat",
                    "audio duration is unavailable",
                )
            listOf(VideoCommandPlanner.addMusic(asset.id, duration))
        }
    }

    fun updateMusic(
        musicID: String,
        offsetSeconds: Double? = null,
        trimStart: Double? = null,
        lengthSeconds: Double? = null,
        volume: Double? = null,
        fadeInSeconds: Double? = null,
        fadeOutSeconds: Double? = null,
    ) {
        runVideoTransaction {
            listOf(
                VideoCommandPlanner.updateMusic(
                    id = musicID,
                    offsetSeconds = offsetSeconds,
                    trimStart = trimStart,
                    lengthSeconds = lengthSeconds,
                    volume = volume,
                    fadeInSeconds = fadeInSeconds,
                    fadeOutSeconds = fadeOutSeconds,
                ),
            )
        }
    }

    fun removeMusic(musicID: String) {
        runVideoTransaction(VideoNotice.MUSIC_REMOVED) {
            listOf(VideoCommandPlanner.removeMusic(musicID))
        }
    }

    fun addClipFromAsset(assetID: String) {
        runVideoTransaction(VideoNotice.CLIP_ADDED) {
            val asset = asset(assetID) ?: return@runVideoTransaction emptyList()
            val duration = resolveAssetDuration(asset)
                ?: throw CreativeException(
                    "unsupportedSourceFormat",
                    "video duration is unavailable",
                )
            listOf(VideoCommandPlanner.appendClip(asset.id, duration))
        }
    }

    fun importVideoClip(picked: MediaPickedSource) {
        if (!isVideoProject) return
        var importedAssetID: String? = null
        runVideoTransaction(
            notice = VideoNotice.CLIP_ADDED,
            afterCommit = {
                val id = importedAssetID
                selectedClipID = if (id == null) {
                    null
                } else {
                    videoTimeline?.clips?.lastOrNull { it.assetID == id }?.id
                }
            },
        ) {
            val receipt = ports.assetImport.importMediaAsset(
                source = picked,
                projectID = projectID,
                expectedRevision = currentVideoRevision(),
                storage = storage,
                origin = origin,
                sessionToken = sessionToken,
                opID = newOperationID(),
            )
            importedAssetID = receipt.asset.id
            if (!refreshVideoLocked()) return@runVideoTransaction emptyList()
            val duration = resolveAssetDuration(receipt.asset)
                ?: throw CreativeException(
                    "unsupportedSourceFormat",
                    "video duration is unavailable",
                )
            listOf(VideoCommandPlanner.appendClip(receipt.asset.id, duration))
        }
    }

    fun importMusic(picked: MediaPickedSource) {
        if (!isVideoProject) return
        runVideoTransaction(VideoNotice.MUSIC_ADDED) {
            val receipt = ports.assetImport.importMediaAsset(
                source = picked,
                projectID = projectID,
                expectedRevision = currentVideoRevision(),
                storage = storage,
                origin = origin,
                sessionToken = sessionToken,
                opID = newOperationID(),
            )
            if (!refreshVideoLocked()) return@runVideoTransaction emptyList()
            val duration = resolveAssetDuration(receipt.asset)
                ?: throw CreativeException(
                    "unsupportedSourceFormat",
                    "audio duration is unavailable",
                )
            listOf(VideoCommandPlanner.addMusic(receipt.asset.id, duration))
        }
    }

    private suspend fun resolveAssetDuration(asset: MediaAssetReference): Double? {
        val measured = asset.metadata?.durationSeconds
        if (measured != null && measured.isFinite() && measured > 0.05) return measured
        val platform = r2Ports?.platform ?: return null
        return runCatching {
            platform.probe(
                MediaAssetProbeRequest(
                    context = r2Context,
                    mediaRootPath = mediaRootPath,
                    relativePath = asset.relativePath,
                ),
            ).durationSeconds
        }.getOrNull()?.takeIf { it.isFinite() && it > 0.05 }
    }

    // MARK: - G09-R2 generation / candidates

    fun submitImageGeneration(request: ImageGenerationRequest) {
        if (!isImageProject) return
        r2?.generation?.submitImageAtRevision(request, revision)
    }

    fun submitVideoGeneration(request: VideoGenerationRequest) {
        r2?.generation?.submitVideoAtRevision(request, revision)
    }

    fun refreshGeneration() {
        r2?.generation?.refreshAll()
    }

    fun refreshGenerationJob(jobID: String) {
        r2?.generation?.refreshJob(jobID)
    }

    fun cancelGenerationJob(jobID: String) {
        r2?.generation?.cancelJob(jobID)
    }

    fun deliverGenerationResult(jobID: String) {
        r2?.generation?.deliverResult(jobID)
    }

    fun refreshImageRequest(requestID: String) {
        r2?.generation?.refreshImageRequest(requestID)
    }

    fun dismissImageRequest(requestID: String) {
        r2?.generation?.dismissImageRequest(requestID)
    }

    fun acceptGenerationCandidate(candidateID: String) {
        r2?.generation?.acceptCandidate(candidateID, revision)
    }

    fun rejectGenerationCandidate(candidateID: String) {
        r2?.generation?.rejectCandidate(candidateID)
    }

    // MARK: - G09-R2 export

    val exportJobs: List<com.floe.android.feature.workbench.ui.r2.WorkbenchExportJob>
        get() = r2?.exports?.jobsFor(r2Context).orEmpty()

    fun submitVideoExport(settings: com.floe.android.feature.workbench.VideoExportSettings) {
        if (!isVideoProject) return
        r2?.submitVideoExport(settings)
    }

    fun submitImageExport(settings: com.floe.android.feature.workbench.ImageExportSettings) {
        if (!isImageProject) return
        r2?.submitImageExport(settings)
    }

    fun cancelExport(jobID: String) {
        r2?.exports?.cancel(jobID)
    }

    fun refreshExport(jobID: String) {
        r2?.exports?.refresh(jobID)
    }

    fun retryExport(jobID: String) {
        r2?.retryExport(jobID)
    }

    suspend fun deliverExport(
        jobID: String,
        receipt: com.floe.android.feature.workbench.MediaExportReceipt,
    ): WorkbenchExportDeliveryResult? = r2?.deliverExport(jobID, receipt)

    fun clearExportFailure() {
        r2?.clearExportFailure()
    }

    fun recoverExports() {
        r2?.reattachExports()
    }

    // MARK: - Command pipeline


    private fun launchCommand(
        command: MediaEditCommand,
        successNotice: MediaNotice? = null,
        clearSelection: Boolean = false,
        onSuccess: (() -> Unit)? = null,
        successCompletion: LayerOperationCompletion? = null,
    ) {
        if (busy || !writable || needsReload) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    val applied = executeCommandLocked(command)
                    if (applied) {
                        if (successNotice != null) notice = successNotice
                        if (clearSelection) selectedLayerID = null
                        if (successCompletion != null) {
                            layerOperation = LayerOperationState(completed = successCompletion)
                        }
                        onSuccess?.invoke()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    handleFailure(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    private suspend fun executeCommandLocked(command: MediaEditCommand): Boolean =
        applyCommandsLocked(listOf(command))

    private suspend fun applyCommandsLocked(commands: List<MediaEditCommand>): Boolean {
        if (commands.isEmpty()) return false
        val expected = envelope.project.revision
        try {
            host.apply(
                projectID = projectID,
                expectedRevision = expected,
                sessionToken = sessionToken,
                storage = storage,
                origin = origin,
                opID = newOperationID(),
                commands = commands,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            handleFailure(error)
            return false
        }
        if (retired) return false
        val refreshed = refreshLocked()
        if (!refreshed) needsReload = true
        return true
    }

    private suspend fun refreshLocked(): Boolean {
        if (envelope.project.kind == "video" && r2 != null) {
            return refreshVideoLocked()
        }
        val refreshed = refreshEnvelopeLocked()
        if (refreshed && isImageProject && r2 != null) {
            r2?.requestImagePreview()
        }
        return refreshed
    }

    private suspend fun refreshEnvelopeLocked(): Boolean {
        return try {
            val value = host.open(
                projectID = projectID,
                sessionToken = sessionToken,
                storage = storage,
                origin = origin,
            )
            if (retired) return false
            envelope = value
            selectedLayerID = selectedLayerID?.takeIf { id ->
                value.project.imageLayers.any { it.id == id }
            }
            needsReload = false
            schedulePreviews()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            needsReload = true
            failure = MediaFailures.from(error)
            false
        }
    }

    /**
     * Loads the typed video projection through the R2 host API. The returned
     * envelope is the actual native project/revision, so the R1 editor
     * envelope is updated from it instead of reopening a second time.
     */
    private suspend fun refreshVideoLocked(): Boolean {
        val video = r2Ports?.video ?: return false
        return try {
            val value = video.loadVideo(r2Context)
            if (retired) return false
            if (value.project.id != projectID) return false
            videoEnvelope = value
            envelope = MediaProjectEnvelope(
                project = value.project,
                mediaRootPath = value.mediaRootPath,
                storage = value.storage,
                writable = value.writable,
                warnings = value.warnings,
            )
            needsReload = false
            normalizeVideoState()
            schedulePreviews()
            r2?.onVideoTimelineChanged(value.project.revision, playheadSeconds)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            needsReload = true
            failure = MediaFailures.from(error)
            false
        }
    }

    private fun normalizeVideoState() {
        val timeline = videoEnvelope?.timeline ?: return
        selectedClipID = selectedClipID?.takeIf { id ->
            timeline.clips.any { it.id == id }
        }
        val duration = WorkbenchVideoMath.duration(timeline)
        playheadSeconds = playheadSeconds.coerceIn(0.0, max(0.0, duration))
    }

    /** Reload after a generation candidate commit mutated the project. */
    private fun refreshProjectFromR2() {
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                try {
                    if (!refreshLocked()) needsReload = true
                } finally {
                    busy = false
                }
            }
        }
    }

    private fun handleFailure(error: Throwable) {
        val mapped = MediaFailures.from(error)
        failure = mapped
        if (mapped.kind == MediaFailureKind.REVISION_CONFLICT ||
            mapped.kind == MediaFailureKind.OUTCOME_UNKNOWN ||
            mapped.kind == MediaFailureKind.SESSION_LOST
        ) {
            needsReload = true
        }
    }

    private fun canEditGeometry(layer: ImageLayer): Boolean =
        writable && !busy && !needsReload && !layer.isLocked

    // MARK: - Preview bitmaps

    private fun schedulePreviews() {
        scope.launch { refreshPreviews() }
    }

    private suspend fun refreshPreviews() {
        val snapshot = envelope
        val assets = snapshot.project.assets
        val loaded = LinkedHashMap<String, Bitmap>()
        val missing = LinkedHashSet<String>()
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            for (asset in assets) {
                if (retired) return@withContext
                val path = MediaPreviewPaths.resolve(snapshot.mediaRootPath, asset.relativePath)
                if (path == null) {
                    missing += asset.id
                    continue
                }
                if (asset.kind != "image") {
                    // Video/audio assets are represented by metadata, not
                    // decoded as still previews; existence was just checked.
                    continue
                }
                val bitmap = MediaBitmapLoader.load(path)
                if (bitmap == null) missing += asset.id else loaded[asset.id] = bitmap
            }
        }
        if (retired || envelope.project.id != snapshot.project.id) return
        val liveIDs = assets.map { it.id }.toSet()
        assetBitmaps.keys.retainAll(liveIDs)
        for ((id, bitmap) in loaded) assetBitmaps[id] = bitmap
        for (id in liveIDs) if (id !in loaded) assetBitmaps.remove(id)
        missingAssetIDs = missing
        previewRevision += 1
    }

    // MARK: - Retirement

    suspend fun retire(): Boolean {
        operationMutex.withLock {
            if (retired) return false
            retired = true
            r2?.stop()
            val closed = runCatching {
                host.closeWorkbenchEditor(projectID, sessionToken)
            }.getOrDefault(false)
            assetBitmaps.clear()
            videoEnvelope = null
            onRetired(this)
            return closed
        }
    }

    internal fun markRetired() {
        retired = true
        r2?.stop()
        assetBitmaps.clear()
        videoEnvelope = null
    }

    val isRetired: Boolean get() = retired
}

/** User-visible outcome of one committed video timeline command batch. */
enum class VideoNotice {
    CLIP_ADDED,
    CLIP_DUPLICATED,
    CLIP_REMOVED,
    CLIP_SPLIT,
    CLIP_REORDERED,
    COVER_SET,
    COVER_CLEARED,
    CAPTION_ADDED,
    CAPTION_REMOVED,
    CAPTION_SHIFTED,
    MUSIC_ADDED,
    MUSIC_REMOVED,
    CANVAS_UPDATED,
}

/** User-visible terminal outcome of one C03 layer operation. */
enum class LayerOperationCompletion {
    SELECTION_SET,
    SELECTION_CLEARED,
    FILLED,
    CUT,
    COPIED,
    MERGED,
}

data class LayerOperationState(
    val busy: Boolean = false,
    val completed: LayerOperationCompletion? = null,
    val failure: MediaFailure? = null,
)

data class GallerySaveState(
    val busy: Boolean = false,
    val savedDisplayName: String? = null,
    val permission: String? = null,
    val failure: MediaFailure? = null,
    val pendingCleaned: Boolean = true,
)
