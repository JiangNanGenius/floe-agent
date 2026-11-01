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
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.WorkbenchHostApi
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.presentation.MediaBitmapLoader
import com.floe.android.feature.workbench.ui.presentation.MediaCommandPlanner
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import com.floe.android.feature.workbench.ui.presentation.MediaLayerGeometry
import com.floe.android.feature.workbench.ui.presentation.MediaNotice
import com.floe.android.feature.workbench.ui.presentation.MediaPreviewPaths
import java.util.UUID
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
) {
    var envelope: MediaProjectEnvelope by mutableStateOf(initial)
        private set
    var selectedLayerID: String? by mutableStateOf(null)
        private set
    var busy by mutableStateOf(false)
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

    private val operationMutex = Mutex()
    @Volatile private var retired = false
    @Volatile private var started = false

    fun start() {
        if (started || retired) return
        started = true
        scope.launch { refreshPreviews() }
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

    // MARK: - Command pipeline

    private fun launchCommand(
        command: MediaEditCommand,
        successNotice: MediaNotice? = null,
        clearSelection: Boolean = false,
        onSuccess: (() -> Unit)? = null,
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

    private suspend fun executeCommandLocked(command: MediaEditCommand): Boolean {
        val expected = envelope.project.revision
        try {
            host.apply(
                projectID = projectID,
                expectedRevision = expected,
                sessionToken = sessionToken,
                storage = storage,
                origin = origin,
                opID = newOperationID(),
                commands = listOf(command),
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
            val closed = runCatching {
                host.closeWorkbenchEditor(projectID, sessionToken)
            }.getOrDefault(false)
            assetBitmaps.clear()
            onRetired(this)
            return closed
        }
    }

    internal fun markRetired() {
        retired = true
        assetBitmaps.clear()
    }

    val isRetired: Boolean get() = retired
}
