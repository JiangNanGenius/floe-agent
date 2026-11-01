// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CanvasAssetReceipt
import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasAssetReferenceOperation
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CanvasMutationReceipt
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasOperationResult
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CanvasRecoveryState
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeServiceStatus
import kotlinx.coroutines.CompletableDeferred

/**
 * Minimal native-authority double for controller tests. It applies only the
 * patch vocabulary the R1 UI emits (create/update/delete) and enforces the
 * exact revision/session rules the real host enforces.
 */
internal class FakeCanvasHost : CanvasHostApi {
    var availability: CreativeAvailability = CreativeAvailability.Available
    var openGate: CompletableDeferred<Unit>? = null
    var patchFailure: CreativeException? = null
    var renameFailure: CreativeException? = null
    var activeToken: String? = null
    var documentID: String = "11111111-1111-1111-1111-111111111111"
    var projectID: String = "22222222-2222-2222-2222-222222222222"
    var revision: Long = 1
    val opened = mutableListOf<Pair<String, String>>()
    val closed = mutableListOf<Pair<String, String>>()
    val patches = mutableListOf<CanvasPatchRequest>()
    val renames = mutableListOf<Triple<String, Long, String>>()
    val referenceOps = mutableListOf<List<CanvasAssetReferenceOperation>>()
    var nodes: List<CanvasNode> = emptyList()
    var name: String = "Canvas"
    var writable: Boolean = true
    var assetBasePath: String = "/tmp/materials"

    override suspend fun bind(epoch: Long): CreativeBinding =
        CreativeBinding(epoch, true, "test")

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

    override suspend fun canvasLibrary(): List<CanvasProjectSummary> = listOf(
        CanvasProjectSummary(
            id = projectID,
            name = name,
            revision = revision,
            updatedAt = "2026-11-01T00:00:00Z",
            schemaVersion = 7,
            documentCount = 1,
            corrupt = false,
            writable = writable,
        ),
    )

    override suspend fun open(canvasID: String, sessionToken: String): CanvasProjectEnvelope {
        openGate?.await()
        opened += canvasID to sessionToken
        activeToken = sessionToken
        return envelope()
    }

    override suspend fun create(
        name: String,
        workspaceID: String?,
        sessionToken: String,
    ): CanvasProjectEnvelope {
        this.name = name
        revision = 1
        nodes = emptyList()
        activeToken = sessionToken
        return envelope()
    }

    override suspend fun patch(request: CanvasPatchRequest): CanvasOperationResult {
        patches += request
        patchFailure?.let { throw it }
        if (request.sessionToken != activeToken) {
            throw CreativeException("staleSession", "test")
        }
        if (request.expectedRevision != revision) {
            throw CreativeException("revisionConflict", "test")
        }
        var next = nodes
        var changed = mutableListOf<String>()
        for (operation in request.patch.operations) {
            when (operation.kind) {
                "create" -> {
                    val node = CanvasNode(
                        id = operation.nodeID ?: operation.id,
                        kind = operation.nodeKind ?: "text",
                        text = operation.text ?: "",
                        position = operation.position ?: CanvasPoint(0.0, 0.0),
                        size = operation.size ?: CanvasSize(100.0, 100.0),
                        shape = operation.shape,
                        asset = operation.asset,
                    )
                    next = next + node
                    changed += node.id
                }
                "update" -> {
                    val nodeID = operation.nodeID ?: continue
                    next = next.map { node ->
                        if (node.id != nodeID) node else node.copy(
                            text = operation.text ?: node.text,
                            position = operation.position ?: node.position,
                            size = operation.size ?: node.size,
                            rotation = operation.rotation ?: node.rotation,
                            isLocked = operation.isLocked ?: node.isLocked,
                            shape = operation.shape ?: node.shape,
                            asset = operation.asset ?: node.asset,
                        )
                    }
                    changed += nodeID
                }
                "delete" -> {
                    val ids = (operation.nodeIDs ?: listOfNotNull(operation.nodeID)).toSet()
                    next = next.filterNot { it.id in ids }
                    changed += ids
                }
            }
        }
        nodes = next
        val previous = revision
        revision += 1
        return CanvasOperationResult(
            canvasID = request.canvasID,
            documentID = request.patch.documentID,
            previousRevision = previous,
            revision = revision,
            changedNodeIDs = changed,
            changedConnectionIDs = emptyList(),
            undoToken = null,
            opID = request.opID,
            idempotent = false,
        )
    }

    override suspend fun rename(
        canvasID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        opID: String?,
    ): CanvasMutationReceipt {
        renameFailure?.let { throw it }
        if (expectedRevision != revision) {
            throw CreativeException("revisionConflict", "test")
        }
        renames += Triple(canvasID, expectedRevision, name)
        this.name = name
        revision += 1
        return CanvasMutationReceipt(
            canvasID = canvasID,
            name = name,
            revision = revision,
            deleted = false,
            opID = opID ?: "rename",
            idempotent = false,
        )
    }

    override suspend fun delete(
        canvasID: String,
        expectedRevision: Long,
        sessionToken: String,
        opID: String?,
    ) {
        if (expectedRevision != revision) {
            throw CreativeException("revisionConflict", "test")
        }
        activeToken = null
    }

    override suspend fun importAsset(
        token: String,
        opID: String,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
        sessionToken: String,
    ): CanvasAssetReceipt = CanvasAssetReceipt(
        asset = CanvasAssetReference(id = "asset-1", contentHash = sha256),
        deduplicated = false,
        opID = opID,
        idempotent = false,
    )

    override suspend fun discardAsset(token: String) = Unit

    override suspend fun referenceOp(
        canvasID: String,
        sessionToken: String,
        operations: List<CanvasAssetReferenceOperation>,
    ): CanvasRecoveryState {
        referenceOps += operations
        return CanvasRecoveryState(canvasID, pendingOperations = 0, appliedOperations = operations.size)
    }

    override suspend fun recover(canvasID: String): CanvasRecoveryState =
        CanvasRecoveryState(canvasID, pendingOperations = 0, appliedOperations = 0)

    override suspend fun closeCanvasEditor(canvasID: String, sessionToken: String): Boolean {
        closed += canvasID to sessionToken
        return if (activeToken == sessionToken) {
            activeToken = null
            true
        } else {
            false
        }
    }

    fun envelope(): CanvasProjectEnvelope {
        val document = CanvasDocument(
            id = documentID,
            name = "Canvas",
            nodes = nodes,
            createdAt = "2026-11-01T00:00:00Z",
            updatedAt = "2026-11-01T00:00:00Z",
        )
        return CanvasProjectEnvelope(
            project = CanvasProject(
                id = projectID,
                name = name,
                documents = listOf(document),
                selectedDocumentID = documentID,
                revision = revision,
                createdAt = "2026-11-01T00:00:00Z",
                updatedAt = "2026-11-01T00:00:00Z",
            ),
            assetsBasePath = assetBasePath,
            writable = writable,
        )
    }
}
