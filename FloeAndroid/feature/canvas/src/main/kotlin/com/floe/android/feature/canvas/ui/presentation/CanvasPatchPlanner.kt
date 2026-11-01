// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.presentation

import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasAssetReferenceOperation
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasPatchOperation
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasSize
import java.util.UUID

/**
 * Builds the frozen native Canvas patch vocabulary (`create`/`update`/
 * `delete`). The wire operation kinds and UUID field names are the native
 * contract; this UI never rewrites a whole CanvasProject DTO.
 */
object CanvasPatchPlanner {
    fun createOperation(
        nodeID: String,
        kind: String,
        position: CanvasPoint,
        size: CanvasSize,
        text: String? = null,
        shape: String? = null,
        asset: CanvasAssetReference? = null,
    ): CanvasPatchOperation = CanvasPatchOperation(
        id = nodeID,
        kind = "create",
        nodeID = nodeID,
        nodeKind = kind,
        position = position,
        size = size,
        text = text,
        shape = shape,
        asset = asset,
    )

    /**
     * A complete `update` snapshot of the node's editable fields. The same
     * builder produces both the forward and inverse operation: omitted fields
     * mean "unchanged" in the native vocabulary, so a full snapshot is the
     * only way to express an undo of text/geometry/lock/shape/asset changes.
     */
    fun snapshotUpdate(node: CanvasNode): CanvasPatchOperation = CanvasPatchOperation(
        id = UUID.randomUUID().toString(),
        kind = "update",
        nodeID = node.id,
        position = node.position,
        size = node.size,
        rotation = node.rotation,
        text = node.text,
        isLocked = node.isLocked,
        shape = node.shape,
        asset = node.asset,
    )

    fun deleteOperation(nodeIDs: Collection<String>): CanvasPatchOperation =
        CanvasPatchOperation(
            id = UUID.randomUUID().toString(),
            kind = "delete",
            nodeIDs = nodeIDs.toList(),
        )

    /**
     * Reference-delta operations tied to one committed patch operation id.
     * Positive references are applied before negative ones by the native
     * journal, so a crash can only over-retain bytes.
     */
    fun referenceOperations(
        patchOpID: String,
        addedAssetIDs: Collection<String>,
        removedAssetIDs: Collection<String> = emptyList(),
    ): List<CanvasAssetReferenceOperation> {
        var index = 0
        val result = ArrayList<CanvasAssetReferenceOperation>()
        for (assetID in addedAssetIDs.distinct()) {
            result += CanvasAssetReferenceOperation(
                opID = "$patchOpID.ref.${index++}", assetID = assetID, delta = 1)
        }
        for (assetID in removedAssetIDs.distinct()) {
            result += CanvasAssetReferenceOperation(
                opID = "$patchOpID.ref.${index++}", assetID = assetID, delta = -1)
        }
        return result
    }

    fun assetIDsOf(nodes: Collection<CanvasNode>): List<String> =
        nodes.mapNotNull { it.asset?.id }
}

/** One reversible UI edit; redo/undo are explicit native patches. */
data class CanvasEditRecord(
    val documentID: String,
    val undoOperation: CanvasPatchOperation,
    val redoOperation: CanvasPatchOperation,
    val undoReferenceOps: List<CanvasAssetReferenceOperation> = emptyList(),
    val redoReferenceOps: List<CanvasAssetReferenceOperation> = emptyList(),
)
