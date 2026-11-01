// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.ui.presentation.CanvasPatchPlanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasPatchPlannerTest {
    private val node = CanvasNode(
        id = "node-1",
        kind = "text",
        text = "hello",
        position = CanvasPoint(10.0, 20.0),
        size = CanvasSize(120.0, 80.0),
        rotation = 15.0,
        isLocked = false,
    )

    @Test
    fun createOperationUsesStableNodeIdentity() {
        val operation = CanvasPatchPlanner.createOperation(
            nodeID = "new-node",
            kind = "stickyNote",
            position = CanvasPoint(1.0, 2.0),
            size = CanvasSize(200.0, 100.0),
            text = "note",
        )
        assertEquals("create", operation.kind)
        assertEquals("new-node", operation.id)
        assertEquals("new-node", operation.nodeID)
        assertEquals("stickyNote", operation.nodeKind)
        assertEquals(200.0, operation.size?.width ?: 0.0, 0.0001)
    }

    @Test
    fun snapshotUpdateCarriesEveryEditableField() {
        val update = CanvasPatchPlanner.snapshotUpdate(node)
        assertEquals("update", update.kind)
        assertEquals(node.id, update.nodeID)
        assertEquals(node.text, update.text)
        assertEquals(node.position, update.position)
        assertEquals(node.size, update.size)
        assertEquals(node.rotation, update.rotation)
        assertEquals(node.isLocked, update.isLocked)
        assertNull(update.shape)
    }

    @Test
    fun referenceOperationsAreUniqueAndPositiveFirst() {
        val ops = CanvasPatchPlanner.referenceOperations(
            patchOpID = "op.1",
            addedAssetIDs = listOf("a", "b", "a"),
            removedAssetIDs = listOf("c"),
        )
        assertEquals(listOf(1, 1, -1), ops.map { it.delta })
        assertEquals(ops.size, ops.map { it.opID }.toSet().size)
        assertTrue(ops.all { it.opID.startsWith("op.1.ref.") })
    }

    @Test
    fun deleteOperationCarriesAllIDs() {
        val deletion = CanvasPatchPlanner.deleteOperation(listOf("a", "b"))
        assertEquals("delete", deletion.kind)
        assertEquals(listOf("a", "b"), deletion.nodeIDs)
    }

    @Test
    fun assetIDsAreCollectedOnlyFromReferencingNodes() {
        val withAsset = node.copy(asset = CanvasAssetReference(id = "asset-1"))
        assertEquals(listOf("asset-1"), CanvasPatchPlanner.assetIDsOf(listOf(withAsset, node)))
    }
}
