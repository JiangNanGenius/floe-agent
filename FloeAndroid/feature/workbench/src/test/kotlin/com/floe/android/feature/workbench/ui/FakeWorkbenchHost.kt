// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeServiceStatus
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaMutationReceipt
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.WorkbenchHostApi
import kotlinx.coroutines.CompletableDeferred

/** Minimal native-authority double for the media controller tests. */
internal class FakeWorkbenchHost : WorkbenchHostApi {
    var availability: CreativeAvailability = CreativeAvailability.Available
    var openGate: CompletableDeferred<Unit>? = null
    var applyFailure: CreativeException? = null
    var activeToken: String? = null
    val projectID: String = "33333333-3333-3333-3333-333333333333"
    var projectName: String = "Project"
    var kind: String = "image"
    var revision: Long = 1
    var layers: List<ImageLayer> = emptyList()
    var assets: List<MediaAssetReference> = listOf(
        MediaAssetReference(
            id = "44444444-4444-4444-4444-444444444444",
            kind = "image",
            relativePath = "Workbench/Assets/image.png",
            originalName = "image.png",
            byteCount = 12,
        ),
    )
    var canUndo: Boolean = false
    var canRedo: Boolean = false
    var missingFile: Boolean = false
    var writable: Boolean = true

    val opened = mutableListOf<Pair<String, String>>()
    val openRequests = mutableListOf<Triple<String, CreativeStorageLayer?, CreativeOriginContext?>>()
    val closed = mutableListOf<Pair<String, String>>()
    val applies = mutableListOf<List<MediaEditCommand>>()
    val undoRequests = mutableListOf<String>()
    val redoRequests = mutableListOf<String>()

    override suspend fun bind(epoch: Long): CreativeBinding = CreativeBinding(epoch, true, "test")

    override suspend fun status(): CreativeServiceStatus = CreativeServiceStatus(
        availability = availability,
        boundEpoch = 1,
        schema = "floe.creative/5",
        actions = emptyList(),
        requestMaxBytes = 65_536,
        responseMaxBytes = 16 * 1024 * 1024,
        canvasSchemaVersion = 7,
        mediaSchemaVersion = 1,
    )

    override suspend fun mediaLibrary(): List<MediaProjectSummary> = listOf(
        MediaProjectSummary(
            id = projectID,
            name = projectName,
            kind = kind,
            revision = revision,
            updatedAt = "2026-11-01T00:00:00Z",
            ownerKind = "standalone",
            assetCount = assets.size,
            layerCount = layers.size,
            corrupt = false,
            writable = writable,
            provenanceWarning = false,
        ),
    )

    override suspend fun open(
        projectID: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
    ): MediaProjectEnvelope {
        openGate?.await()
        opened += projectID to sessionToken
        openRequests += Triple(projectID, storage, origin)
        activeToken = sessionToken
        return envelope()
    }

    override suspend fun create(
        name: String,
        kind: String,
        width: Int,
        height: Int,
        frameRate: Double?,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext,
        sessionToken: String,
    ): MediaProjectEnvelope {
        projectName = name
        this.kind = kind
        revision = 1
        layers = emptyList()
        activeToken = sessionToken
        return envelope()
    }

    override suspend fun apply(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
        commands: List<MediaEditCommand>,
    ): MediaProjectReceipt {
        applies += commands
        applyFailure?.let { throw it }
        if (sessionToken != activeToken) throw CreativeException("staleSession", "test")
        if (expectedRevision != revision) {
            throw CreativeException("revisionConflict", "test")
        }
        var next = layers
        for (command in commands) {
            when (command) {
                is MediaEditCommand.AddImageLayer -> next = next + command.layer
                is MediaEditCommand.UpdateLayer -> next = next.map { layer ->
                    if (layer.id != command.id) layer else layer.copy(
                        transform = command.transform ?: layer.transform,
                        opacity = command.opacity ?: layer.opacity,
                        isHidden = command.isHidden ?: layer.isHidden,
                        isLocked = command.isLocked ?: layer.isLocked,
                        adjustment = command.adjustment ?: layer.adjustment,
                        text = command.text ?: layer.text,
                        crop = when (val crop = command.crop) {
                            is com.floe.android.feature.workbench.OptionalUpdate.Set -> crop.value
                            com.floe.android.feature.workbench.OptionalUpdate.Clear -> null
                            com.floe.android.feature.workbench.OptionalUpdate.Unchanged -> layer.crop
                        },
                    )
                }
                is MediaEditCommand.RemoveLayer -> next = next.filterNot { it.id == command.id }
                is MediaEditCommand.MoveLayer -> {
                    val layer = next.firstOrNull { it.id == command.id }
                    if (layer != null) {
                        next = next.filterNot { it.id == command.id }.toMutableList().apply {
                            add(command.toIndex.coerceIn(0, size), layer)
                        }
                    }
                }
                is MediaEditCommand.AddFreehandStroke -> next = next.map { layer ->
                    if (layer.id != command.id) layer else layer.copy(
                        freehand = com.floe.android.feature.workbench.ImageFreehandContent(
                            strokes = (layer.freehand?.strokes.orEmpty() + command.stroke),
                        ),
                    )
                }
                is MediaEditCommand.DuplicateLayer -> {
                    val index = next.indexOfFirst { it.id == command.id }
                    if (index >= 0) {
                        val copy = next[index].copy(
                            id = "55555555-5555-5555-5555-555555555555",
                            name = next[index].name + " copy",
                        )
                        next = next.toMutableList().apply { add(index + 1, copy) }
                    }
                }
                else -> Unit
            }
        }
        layers = next
        revision += 1
        canUndo = true
        canRedo = false
        return MediaProjectReceipt(
            projectID = projectID,
            revision = revision,
            canUndo = canUndo,
            canRedo = canRedo,
            opID = opID,
            idempotent = false,
        )
    }

    override suspend fun undo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt {
        undoRequests += opID
        revision += 1
        canUndo = false
        canRedo = true
        return MediaProjectReceipt(
            projectID = projectID,
            revision = revision,
            canUndo = canUndo,
            canRedo = canRedo,
            opID = opID,
            idempotent = false,
        )
    }

    override suspend fun redo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt {
        redoRequests += opID
        revision += 1
        canUndo = true
        canRedo = false
        return MediaProjectReceipt(
            projectID = projectID,
            revision = revision,
            canUndo = canUndo,
            canRedo = canRedo,
            opID = opID,
            idempotent = false,
        )
    }

    override suspend fun rename(
        projectID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ): MediaMutationReceipt {
        projectName = name
        revision += 1
        return MediaMutationReceipt(
            projectID = projectID,
            name = name,
            revision = revision,
            deleted = false,
            canUndo = canUndo,
            canRedo = canRedo,
            opID = opID ?: "rename",
            idempotent = false,
        )
    }

    override suspend fun delete(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ) {
        activeToken = null
    }

    override suspend fun importAsset(
        token: String,
        opID: String,
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
    ): MediaAssetReceipt {
        val asset = MediaAssetReference(
            id = "66666666-6666-6666-6666-666666666666",
            kind = "image",
            relativePath = "Workbench/Assets/imported.png",
            originalName = fileName,
            byteCount = byteCount,
        )
        assets = assets + asset
        return MediaAssetReceipt(
            projectID = projectID,
            asset = asset,
            revision = revision,
            canUndo = canUndo,
            canRedo = canRedo,
            opID = opID,
            idempotent = false,
        )
    }

    override suspend fun relink(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        assetID: String,
        relativePath: String,
        opID: String?,
    ): MediaProjectReceipt = MediaProjectReceipt(
        projectID = projectID,
        revision = revision,
        canUndo = canUndo,
        canRedo = canRedo,
        opID = opID ?: "relink",
        idempotent = false,
    )

    override suspend fun closeWorkbenchEditor(projectID: String, sessionToken: String): Boolean {
        closed += projectID to sessionToken
        return if (activeToken == sessionToken) {
            activeToken = null
            true
        } else {
            false
        }
    }

    fun envelope(): MediaProjectEnvelope = MediaProjectEnvelope(
        project = MediaProject(
            id = projectID,
            kind = kind,
            name = projectName,
            createdAt = "2026-11-01T00:00:00Z",
            updatedAt = "2026-11-01T00:00:00Z",
            revision = revision,
            canvas = MediaCanvas(2048, 2048),
            assets = assets,
            imageLayers = layers,
            ownerKind = "standalone",
            canUndo = canUndo,
            canRedo = canRedo,
        ),
        mediaRootPath = if (missingFile) "/tmp/floe-workbench-missing" else "/tmp",
        storage = CreativeStorageLayer.AppOwned,
        writable = writable,
        warnings = emptyList(),
    )
}
