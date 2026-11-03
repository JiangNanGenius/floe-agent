// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasOperationResult
import com.floe.android.feature.canvas.CanvasPatch
import com.floe.android.feature.canvas.CanvasPatchOperation
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasRecoveryState
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.ui.api.CanvasAssetImport
import com.floe.android.feature.canvas.ui.api.CanvasEditorPorts
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.presentation.CanvasEditRecord
import com.floe.android.feature.canvas.ui.presentation.CanvasFailure
import com.floe.android.feature.canvas.ui.presentation.CanvasFailureKind
import com.floe.android.feature.canvas.ui.presentation.CanvasFailures
import com.floe.android.feature.canvas.ui.presentation.CanvasGeometry
import com.floe.android.feature.canvas.ui.presentation.CanvasNodeSemantics
import com.floe.android.feature.canvas.ui.presentation.CanvasNotice
import com.floe.android.feature.canvas.ui.presentation.CanvasPatchPlanner
import com.floe.android.feature.canvas.ui.presentation.CanvasView
import com.floe.android.feature.canvas.ui.presentation.CanvasViewportPolicy
import com.floe.android.feature.canvas.ui.presentation.NodeGeometry
import com.floe.android.feature.canvas.ui.presentation.ResizeCorner
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** In-progress gesture preview; never persisted until a patch commits. */
data class CanvasGesturePreview(
    val nodeID: String,
    val position: CanvasPoint,
    val size: CanvasSize,
    val rotation: Double,
)

/**
 * Retained Canvas document editor.
 *
 * The controller owns the exact editor [sessionToken], the loaded native
 * envelope (the sole project authority), the in-memory selection and the UI
 * undo stack. It never writes project JSON itself: every change is one
 * `CanvasHostApi.patch` with the exact expected revision, a durable op id and
 * a following native reload. A failed or late result can never mutate another
 * editor because the session constructs exactly one controller per open and
 * retires it by identity.
 */
@Stable
class CanvasEditorController internal constructor(
    private val host: CanvasHostApi,
    private val ports: CanvasEditorPorts,
    initial: CanvasProjectEnvelope,
    val sessionToken: String,
    initialRecovery: CanvasRecoveryState? = null,
    private val scope: CoroutineScope,
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
    private val onRetired: (CanvasEditorController) -> Unit = {},
) {
    var envelope: CanvasProjectEnvelope by mutableStateOf(initial)
        private set
    var selectedDocumentID: String by mutableStateOf(initial.project.selectedDocumentID)
        private set
    var selectedNodeIDs: Set<String> by mutableStateOf(emptySet())
        private set
    var busy by mutableStateOf(false)
        private set
    var failure: CanvasFailure? by mutableStateOf(null)
        private set
    var notice: CanvasNotice? by mutableStateOf(null)
        private set
    var recovery: CanvasRecoveryState? by mutableStateOf(initialRecovery)
        private set
    var needsReload by mutableStateOf(false)
        private set
    var canUndo by mutableStateOf(false)
        private set
    var canRedo by mutableStateOf(false)
        private set
    var gesturePreview: CanvasGesturePreview? by mutableStateOf(null)
        private set

    var surfaceWidthPx: Int by mutableStateOf(0)
        private set
    var surfaceHeightPx: Int by mutableStateOf(0)
        private set
    private var surfaceDensity: Float = 1f

    val canvasID: String get() = envelope.project.id
    val canvasName: String get() = envelope.project.name
    val revision: Long get() = envelope.project.revision
    val writable: Boolean get() = envelope.writable
    val assetsBasePath: String get() = envelope.assetsBasePath
    val project get() = envelope.project
    val documents: List<CanvasDocument> get() = envelope.project.documents
    val activeDocument: CanvasDocument?
        get() = documents.firstOrNull { it.id == selectedDocumentID }
    val selectedNode: CanvasNode?
        get() = activeDocument?.nodes?.firstOrNull { it.id in selectedNodeIDs }

    val canEditSelection: Boolean
        get() = writable && !busy && !needsReload && selectedNode?.let {
            !CanvasNodeSemantics.isReadOnly(it)
        } == true

    val canDeleteSelection: Boolean
        get() = writable && !busy && !needsReload && selectedNode?.let {
            !CanvasNodeSemantics.isReadOnly(it)
        } == true

    private val undoStack = ArrayDeque<CanvasEditRecord>()
    private val redoStack = ArrayDeque<CanvasEditRecord>()
    private val viewports = mutableStateMapOf<String, CanvasView>()
    private val operationMutex = Mutex()
    @Volatile private var retired = false
    @Volatile private var closeRequested = false

    // MARK: - Viewport / selection

    fun viewportFor(documentID: String): CanvasView =
        viewports[documentID] ?: CanvasView()

    fun updateViewport(documentID: String, view: CanvasView) {
        viewports[documentID] = view
    }

    fun panBy(dxPx: Float, dyPx: Float) {
        val id = selectedDocumentID
        viewports[id] = CanvasViewportPolicy.pan(viewportFor(id), dxPx, dyPx)
    }

    fun zoomBy(factor: Float, anchorX: Float, anchorY: Float) {
        val id = selectedDocumentID
        viewports[id] = CanvasViewportPolicy.zoomAround(
            viewportFor(id), anchorX, anchorY, factor)
    }

    fun onSurfaceMeasured(widthPx: Int, heightPx: Int, density: Float) {
        if (widthPx <= 0 || heightPx <= 0 || density <= 0f || !density.isFinite()) return
        surfaceWidthPx = widthPx
        surfaceHeightPx = heightPx
        surfaceDensity = density
    }

    /** Fit the active document once per editor while the viewport is untouched. */
    fun ensureInitialViewport() {
        val id = selectedDocumentID
        if (viewports.containsKey(id) || surfaceWidthPx <= 1) return
        val bounds = CanvasViewportPolicy.contentBounds(activeDocument?.nodes.orEmpty())
        viewports[id] = if (bounds == null) {
            CanvasView()
        } else {
            CanvasViewportPolicy.fit(
                bounds, surfaceWidthPx, surfaceHeightPx, surfaceDensity)
        }
    }

    fun fitToContent() {
        if (surfaceWidthPx <= 1) return
        val bounds = CanvasViewportPolicy.contentBounds(activeDocument?.nodes.orEmpty())
        viewports[selectedDocumentID] = CanvasViewportPolicy.fit(
            bounds, surfaceWidthPx, surfaceHeightPx, surfaceDensity)
    }

    fun surfaceCenterWorld(): CanvasPoint {
        val id = selectedDocumentID
        return CanvasViewportPolicy.surfaceCenterWorld(
            viewportFor(id), surfaceWidthPx.coerceAtLeast(1),
            surfaceHeightPx.coerceAtLeast(1), surfaceDensity)
    }

    fun selectDocument(documentID: String) {
        if (documents.none { it.id == documentID }) return
        selectedDocumentID = documentID
        selectedNodeIDs = emptySet()
        gesturePreview = null
    }

    fun selectNode(nodeID: String) {
        if (activeDocument?.nodes?.any { it.id == nodeID } != true) return
        selectedNodeIDs = setOf(nodeID)
    }

    fun clearSelection() {
        selectedNodeIDs = emptySet()
        gesturePreview = null
    }

    fun clearNotice() {
        notice = null
    }

    fun clearFailure() {
        if (failure?.kind == CanvasFailureKind.REVISION_CONFLICT ||
            failure?.kind == CanvasFailureKind.OUTCOME_UNKNOWN
        ) {
            return
        }
        failure = null
    }

    // MARK: - Gestures

    fun beginMove(nodeID: String) {
        val node = activeDocument?.nodes?.firstOrNull { it.id == nodeID } ?: return
        if (!writable || busy || needsReload) return
        if (CanvasNodeSemantics.isReadOnly(node)) return
        selectedNodeIDs = setOf(nodeID)
        gesturePreview = CanvasGesturePreview(node.id, node.position, node.size, node.rotation)
    }

    fun dragMove(dxWorld: Double, dyWorld: Double) {
        val preview = gesturePreview ?: return
        gesturePreview = preview.copy(
            position = CanvasPoint(
                x = preview.position.x + dxWorld,
                y = preview.position.y + dyWorld,
            ),
        )
    }

    fun beginResize(nodeID: String) {
        val node = activeDocument?.nodes?.firstOrNull { it.id == nodeID } ?: return
        if (!writable || busy || CanvasNodeSemantics.isReadOnly(node) || needsReload) return
        selectedNodeIDs = setOf(nodeID)
        gesturePreview = CanvasGesturePreview(node.id, node.position, node.size, node.rotation)
    }

    fun resizeBy(corner: ResizeCorner, dxWorld: Double, dyWorld: Double) {
        val preview = gesturePreview ?: return
        val next = CanvasGeometry.resizeFromCorner(
            NodeGeometry(preview.position, preview.size), corner, dxWorld, dyWorld)
        gesturePreview = preview.copy(position = next.position, size = next.size)
    }

    fun beginRotate(nodeID: String) {
        val node = activeDocument?.nodes?.firstOrNull { it.id == nodeID } ?: return
        if (!writable || busy || CanvasNodeSemantics.isReadOnly(node) || needsReload) return
        selectedNodeIDs = setOf(nodeID)
        gesturePreview = CanvasGesturePreview(node.id, node.position, node.size, node.rotation)
    }

    fun rotateBy(degreesDelta: Double) {
        val preview = gesturePreview ?: return
        gesturePreview = preview.copy(
            rotation = CanvasGeometry.normalizedRotation(preview.rotation + degreesDelta))
    }

    fun cancelGesture() {
        gesturePreview = null
    }

    fun commitGesture() {
        val preview = gesturePreview ?: return
        if (busy || needsReload || !writable) {
            gesturePreview = null
            return
        }
        val node = activeDocument?.nodes?.firstOrNull { it.id == preview.nodeID }
        if (node == null) {
            gesturePreview = null
            return
        }
        if (preview.position == node.position && preview.size == node.size &&
            preview.rotation == node.rotation
        ) {
            gesturePreview = null
            return
        }
        val updated = node.copy(
            position = preview.position,
            size = preview.size,
            rotation = preview.rotation,
        )
        commitSingleUpdate(
            before = node,
            after = updated,
            addedAssets = emptyList(),
            removedAssets = emptyList(),
            keepGesturePreview = true,
        )
    }

    // MARK: - Edits

    fun createNode(kind: String, text: String? = null, asset: CanvasAssetReference? = null) {
        if (!writable || busy || needsReload) return
        val document = activeDocument ?: return
        val nodeID = UUID.randomUUID().toString()
        val position = surfaceCenterWorld()
        val size = CanvasNodeSemantics.defaultSize(kind)
        val shape = if (kind == CanvasNodeSemantics.KIND_SHAPE) "roundedRectangle" else null
        val create = CanvasPatchPlanner.createOperation(
            nodeID = nodeID, kind = kind, position = position, size = size,
            text = text, shape = shape, asset = asset)
        val undo = CanvasPatchPlanner.deleteOperation(listOf(nodeID))
        val redo = CanvasPatchPlanner.createOperation(
            nodeID = nodeID, kind = kind, position = position, size = size,
            text = text, shape = shape, asset = asset)
        val record = CanvasEditRecord(
            documentID = document.id,
            undoOperation = undo,
            redoOperation = redo,
            undoReferenceOps = asset?.let {
                CanvasPatchPlanner.referenceOperations(
                    newOperationID(), emptyList(), listOf(it.id))
            }.orEmpty(),
            redoReferenceOps = asset?.let {
                CanvasPatchPlanner.referenceOperations(
                    newOperationID(), listOf(it.id), emptyList())
            }.orEmpty(),
        )
        launchPatch(
            documentID = document.id,
            operations = listOf(create),
            record = record,
            addedAssets = asset?.let { listOf(it.id) }.orEmpty(),
            onSuccess = { selectedNodeIDs = setOf(nodeID) },
        )
    }

    fun updateText(text: String) {
        val node = selectedNode ?: return
        if (!canEditSelection) return
        if (node.kind !in setOf(
                CanvasNodeSemantics.KIND_TEXT,
                CanvasNodeSemantics.KIND_STICKY,
                CanvasNodeSemantics.KIND_CARD,
            )
        ) return
        if (node.text == text) return
        commitSingleUpdate(node, node.copy(text = text))
    }

    fun updateShape(shape: String) {
        val node = selectedNode ?: return
        if (!canEditSelection || node.kind != CanvasNodeSemantics.KIND_SHAPE) return
        if (shape !in CanvasNodeSemantics.shapeKinds || node.shape == shape) return
        commitSingleUpdate(node, node.copy(shape = shape))
    }

    fun setLocked(locked: Boolean) {
        val node = selectedNode ?: return
        if (!writable || busy || needsReload || node.isLocked == locked) return
        if (CanvasNodeSemantics.isCadBound(node) || node.scene3D != null) return
        commitSingleUpdate(node, node.copy(isLocked = locked))
    }

    fun setRotation(degrees: Double) {
        val node = selectedNode ?: return
        if (!canEditSelection) return
        val rotation = CanvasGeometry.normalizedRotation(degrees)
        if (rotation == node.rotation) return
        commitSingleUpdate(node, node.copy(rotation = rotation))
    }

    fun setSize(size: CanvasSize) {
        val node = selectedNode ?: return
        if (!canEditSelection) return
        if (size.width < CanvasGeometry.MIN_NODE_SIZE ||
            size.height < CanvasGeometry.MIN_NODE_SIZE ||
            !size.width.isFinite() || !size.height.isFinite()
        ) return
        if (size == node.size) return
        commitSingleUpdate(node, node.copy(size = size))
    }

    fun setPosition(position: CanvasPoint) {
        val node = selectedNode ?: return
        if (!canEditSelection) return
        if (!position.x.isFinite() || !position.y.isFinite() || position == node.position) return
        commitSingleUpdate(node, node.copy(position = position))
    }

    fun replaceSelectedImage(asset: CanvasAssetReference) {
        val node = selectedNode ?: return
        if (!canEditSelection || node.kind != CanvasNodeSemantics.KIND_IMAGE) return
        replaceImageFor(node, asset)
    }

    /**
     * Import one replacement image through the App host, then update only the
     * still-selected image node. A changed selection drops the result instead
     * of retargeting the imported asset onto another node.
     */
    fun importReplacementImage(picked: CanvasPickedSource) {
        val nodeID = selectedNode?.id ?: return
        if (!canEditSelection) return
        scope.launch {
            val asset = try {
                operationMutex.withLock {
                    if (retired) return@withLock null
                    busy = true
                    failure = null
                    try {
                        val receipt = ports.assetImport.importCanvasAsset(
                            source = picked,
                            canvasID = canvasID,
                            sessionToken = sessionToken,
                            opID = newOperationID(),
                        )
                        receipt.asset
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Throwable) {
                        failure = CanvasFailures.from(error)
                        null
                    } finally {
                        busy = false
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            }
            if (asset == null || retired) return@launch
            if (selectedNodeIDs != setOf(nodeID)) return@launch
            val live = activeDocument?.nodes?.firstOrNull { it.id == nodeID } ?: return@launch
            if (live.kind != CanvasNodeSemantics.KIND_IMAGE ||
                CanvasNodeSemantics.isReadOnly(live)
            ) return@launch
            replaceImageFor(live, asset)
        }
    }

    private fun replaceImageFor(node: CanvasNode, asset: CanvasAssetReference) {
        if (!writable || busy || needsReload) return
        if (node.asset?.id == asset.id && node.asset?.contentHash == asset.contentHash) return
        val oldAssetID = node.asset?.id
        commitSingleUpdate(
            before = node,
            after = node.copy(asset = asset, metadata = node.metadata - "placeholder"),
            addedAssets = listOf(asset.id),
            removedAssets = listOfNotNull(oldAssetID),
        )
    }

    fun deleteSelected() {
        val node = selectedNode ?: return
        val document = activeDocument ?: return
        if (!canDeleteSelection) return
        if (node.isLocked) return
        val removedAssets = listOfNotNull(node.asset?.id)
        launchPatch(
            documentID = document.id,
            operations = listOf(CanvasPatchPlanner.deleteOperation(listOf(node.id))),
            record = null,
            addedAssets = emptyList(),
            removedAssets = removedAssets,
            clearsHistory = true,
            onSuccess = {
                selectedNodeIDs = emptySet()
                notice = CanvasNotice.DELETION_NOT_UNDOABLE
            },
        )
    }

    fun importImage(picked: CanvasPickedSource) {
        if (!writable || busy || needsReload) return
        val document = activeDocument ?: return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                try {
                    val receipt = ports.assetImport.importCanvasAsset(
                        source = picked,
                        canvasID = canvasID,
                        sessionToken = sessionToken,
                        opID = newOperationID(),
                    )
                    if (retired) return@withLock
                    insertImportedImage(document.id, receipt.asset)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    private suspend fun insertImportedImage(documentID: String, asset: CanvasAssetReference) {
        val nodeID = UUID.randomUUID().toString()
        val position = surfaceCenterWorld()
        val size = CanvasNodeSemantics.defaultSize(CanvasNodeSemantics.KIND_IMAGE)
        val create = CanvasPatchPlanner.createOperation(
            nodeID = nodeID, kind = CanvasNodeSemantics.KIND_IMAGE,
            position = position, size = size, asset = asset)
        val record = CanvasEditRecord(
            documentID = documentID,
            undoOperation = CanvasPatchPlanner.deleteOperation(listOf(nodeID)),
            redoOperation = CanvasPatchPlanner.createOperation(
                nodeID = nodeID, kind = CanvasNodeSemantics.KIND_IMAGE,
                position = position, size = size, asset = asset),
            undoReferenceOps = CanvasPatchPlanner.referenceOperations(
                newOperationID(), emptyList(), listOf(asset.id)),
            redoReferenceOps = CanvasPatchPlanner.referenceOperations(
                newOperationID(), listOf(asset.id), emptyList()),
        )
        val applied = executePatch(
            documentID = documentID,
            operations = listOf(create),
            addedAssets = listOf(asset.id),
            removedAssets = emptyList(),
        )
        if (applied) {
            pushHistory(record)
            selectedNodeIDs = setOf(nodeID)
        }
    }

    fun undo() {
        val record = undoStack.removeLastOrNull() ?: return
        applyHistory(record, undo = true)
    }

    fun redo() {
        val record = redoStack.removeLastOrNull() ?: return
        applyHistory(record, undo = false)
    }

    private fun applyHistory(record: CanvasEditRecord, undo: Boolean) {
        val operation = if (undo) record.undoOperation else record.redoOperation
        val refs = if (undo) record.undoReferenceOps else record.redoReferenceOps
        val added = refs.filter { it.delta > 0 }.map { it.assetID }
        val removed = refs.filter { it.delta < 0 }.map { it.assetID }
        launchPatch(
            documentID = record.documentID,
            operations = listOf(operation),
            record = null,
            addedAssets = added,
            removedAssets = removed,
            onSuccess = {
                if (undo) {
                    redoStack.addLast(record)
                } else {
                    undoStack.addLast(record)
                }
                syncHistoryFlags()
            },
            onFailure = {
                if (undo) undoStack.addLast(record) else redoStack.addLast(record)
            },
        )
    }

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
                        canvasID = canvasID,
                        expectedRevision = envelope.project.revision,
                        name = clean,
                        sessionToken = sessionToken,
                        opID = newOperationID(),
                    )
                    if (retired) return@withLock
                    refreshLocked(clearHistory = false)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                    if (failure?.kind == CanvasFailureKind.REVISION_CONFLICT) {
                        needsReload = true
                    }
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
                    refreshLocked(clearHistory = true)
                    needsReload = false
                    notice = CanvasNotice.RELOADED_FROM_DISK
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    /**
     * Authoritative Canvas reload after a design adoption committed a normal
     * Canvas patch. This is the SAME host open the normal patch pipeline uses:
     * it keeps the current document/selection and the UI undo stack, so the
     * design sheet never owns a second Canvas store or a competing selection.
     * Any failure leaves the committed receipt visible to the design sheet and
     * marks the editor for an explicit safe reload.
     */
    suspend fun refreshEnvelopeAfterDesignAdoption(): Boolean {
        return operationMutex.withLock {
            if (retired) return@withLock false
            busy = true
            try {
                refreshLocked(clearHistory = false)
                needsReload = false
                failure = null
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = CanvasFailures.from(error)
                needsReload = true
                false
            } finally {
                busy = false
            }
        }
    }

    /** Token-scoped retirement; waits for an in-flight patch to settle. */
    suspend fun retire(): Boolean {
        operationMutex.withLock {
            if (retired) return false
            retired = true
            closeRequested = true
            gesturePreview = null
            val closed = runCatching {
                host.closeCanvasEditor(canvasID, sessionToken)
            }.getOrDefault(false)
            onRetired(this)
            return closed
        }
    }

    /**
     * Mark this controller retired without a close round-trip (used only when
     * the session itself is shutting down and the exact token close is issued
     * by the session).
     */
    internal fun markRetired() {
        retired = true
        gesturePreview = null
    }

    val isRetired: Boolean get() = retired

    // MARK: - Patch pipeline

    private fun commitSingleUpdate(
        before: CanvasNode,
        after: CanvasNode,
        addedAssets: List<String> = emptyList(),
        removedAssets: List<String> = emptyList(),
        keepGesturePreview: Boolean = false,
    ) {
        val document = activeDocument ?: return
        val forward = CanvasPatchPlanner.snapshotUpdate(after)
        val inverse = CanvasPatchPlanner.snapshotUpdate(before)
        val undoRefs = CanvasPatchPlanner.referenceOperations(
            newOperationID(), removedAssets, addedAssets)
        val redoRefs = CanvasPatchPlanner.referenceOperations(
            newOperationID(), addedAssets, removedAssets)
        val record = CanvasEditRecord(
            documentID = document.id,
            undoOperation = inverse,
            redoOperation = forward,
            undoReferenceOps = undoRefs,
            redoReferenceOps = redoRefs,
        )
        launchPatch(
            documentID = document.id,
            operations = listOf(forward),
            record = record,
            addedAssets = addedAssets,
            removedAssets = removedAssets,
            keepGesturePreview = keepGesturePreview,
        )
    }

    private fun launchPatch(
        documentID: String,
        operations: List<CanvasPatchOperation>,
        record: CanvasEditRecord?,
        addedAssets: List<String> = emptyList(),
        removedAssets: List<String> = emptyList(),
        clearsHistory: Boolean = false,
        keepGesturePreview: Boolean = false,
        onSuccess: () -> Unit = {},
        onFailure: () -> Unit = {},
    ) {
        if (retired) return
        scope.launch {
            operationMutex.withLock {
                if (retired) return@withLock
                busy = true
                failure = null
                val applied = executePatch(
                    documentID = documentID,
                    operations = operations,
                    addedAssets = addedAssets,
                    removedAssets = removedAssets,
                )
                if (applied) {
                    if (clearsHistory) clearHistory()
                    if (record != null) pushHistory(record)
                    if (!keepGesturePreview) gesturePreview = null
                    onSuccess()
                } else {
                    if (keepGesturePreview) gesturePreview = null
                    onFailure()
                }
                busy = false
            }
        }
    }

    private suspend fun executePatch(
        documentID: String,
        operations: List<CanvasPatchOperation>,
        addedAssets: List<String>,
        removedAssets: List<String>,
    ): Boolean {
        val opID = newOperationID()
        val expectedRevision = envelope.project.revision
        val result: CanvasOperationResult
        try {
            result = host.patch(
                CanvasPatchRequest(
                    canvasID = canvasID,
                    expectedRevision = expectedRevision,
                    sessionToken = sessionToken,
                    opID = opID,
                    patch = CanvasPatch(
                        canvasID = canvasID,
                        documentID = documentID,
                        expectedRevision = expectedRevision,
                        operations = operations,
                    ),
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val mapped = CanvasFailures.from(error)
            failure = mapped
            if (mapped.kind == CanvasFailureKind.REVISION_CONFLICT ||
                mapped.kind == CanvasFailureKind.OUTCOME_UNKNOWN
            ) {
                needsReload = true
            }
            return false
        }
        if (retired) return false
        // The committed revision is durable even if the following reload
        // fails; surface that truth instead of pretending the edit vanished.
        val referenceOps = CanvasPatchPlanner.referenceOperations(
            opID, addedAssets, removedAssets)
        var referenceWarning = false
        if (referenceOps.isNotEmpty()) {
            try {
                recovery = host.referenceOp(canvasID, sessionToken, referenceOps)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                referenceWarning = true
            }
        }
        return try {
            refreshLocked(clearHistory = false)
            if (referenceWarning) notice = CanvasNotice.REFERENCE_PENDING
            if (result.revision != envelope.project.revision) {
                // Defensive: the reload must reflect at least the committed
                // revision, otherwise force a conflict-style reload gate.
                needsReload = true
            }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val mapped = CanvasFailures.from(error)
            failure = mapped
            needsReload = true
            true
        }
    }

    private suspend fun refreshLocked(clearHistory: Boolean) {
        val refreshed = host.open(canvasID, sessionToken)
        if (retired) return
        envelope = refreshed
        if (documents.none { it.id == selectedDocumentID }) {
            selectedDocumentID = refreshed.project.selectedDocumentID
            selectedNodeIDs = emptySet()
            gesturePreview = null
        }
        val existingNodes = activeDocument?.nodes?.map { it.id }?.toSet().orEmpty()
        selectedNodeIDs = selectedNodeIDs.intersect(existingNodes)
        if (clearHistory) {
            clearHistory()
            needsReload = false
        }
        recovery = runCatching { host.recover(canvasID) }.getOrNull()
    }

    private fun pushHistory(record: CanvasEditRecord) {
        undoStack.addLast(record)
        while (undoStack.size > HISTORY_LIMIT) undoStack.removeFirst()
        redoStack.clear()
        syncHistoryFlags()
    }

    private fun clearHistory() {
        undoStack.clear()
        redoStack.clear()
        syncHistoryFlags()
    }

    private fun syncHistoryFlags() {
        canUndo = undoStack.isNotEmpty()
        canRedo = redoStack.isNotEmpty()
    }

    private companion object {
        const val HISTORY_LIMIT = 60
    }
}
