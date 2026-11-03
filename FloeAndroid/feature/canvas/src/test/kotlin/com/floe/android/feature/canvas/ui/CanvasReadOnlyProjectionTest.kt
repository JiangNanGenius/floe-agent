// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.ui.CanvasReadOnlyProjection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored read-only Canvas preview projection tests (NOT RUN here).
 *
 * They assert that the design preview renders the EXACT captured document
 * (same id/revision/document/node), never a fallback document and never a
 * fabricated image. Rendering itself is Compose/device evidence and stays a
 * later App/device gate.
 */
class CanvasReadOnlyProjectionTest {
    private val documentID = "11111111-1111-4111-8111-111111111111"
    private val otherDocumentID = "99999999-9999-4999-8999-999999999999"
    private val textNodeID = "22222222-2222-4222-8222-222222222222"
    private val imageNodeID = "33333333-3333-4333-8333-333333333333"
    private val shapeNodeID = "44444444-4444-4444-8444-444444444444"
    private val imageAssetID = "55555555-5555-4555-8555-555555555555"

    private fun node(
        id: String,
        kind: String,
        zIndex: Int,
        text: String = "",
        assetID: String? = null,
        x: Double = 120.0,
        y: Double = 100.0,
        width: Double = 220.0,
        height: Double = 140.0,
    ) = CanvasNode(
        id = id,
        kind = kind,
        text = text,
        position = CanvasPoint(x, y),
        size = CanvasSize(width, height),
        zIndex = zIndex,
        asset = assetID?.let {
            CanvasAssetReference(id = it, contentHash = "a".repeat(64))
        },
    )

    private fun project(revision: Long = 12L) = CanvasProject(
        id = "66666666-6666-4666-8666-666666666666",
        name = "Preview",
        documents = listOf(
            CanvasDocument(
                id = documentID,
                name = "Page",
                nodes = listOf(
                    node(textNodeID, "text", 1, text = "Real captured copy"),
                    node(imageNodeID, "image", 1, assetID = imageAssetID),
                    node(shapeNodeID, "shape", 2, text = "Rounded"),
                ),
                createdAt = "2026-11-01T00:00:00Z",
                updatedAt = "2026-11-01T00:00:00Z",
            ),
            CanvasDocument(
                id = otherDocumentID,
                name = "Other page",
                nodes = listOf(node(shapeNodeID, "shape", 0)),
                createdAt = "2026-11-01T00:00:00Z",
                updatedAt = "2026-11-01T00:00:00Z",
            ),
        ),
        selectedDocumentID = documentID,
        revision = revision,
        createdAt = "2026-11-01T00:00:00Z",
        updatedAt = "2026-11-01T00:00:00Z",
    )

    @Test
    fun documentIsTheExactCapturedPageAndNeverTheSelectedFallback() {
        val value = project()
        assertEquals(documentID, CanvasReadOnlyProjection.document(value, documentID)?.id)
        assertNull(CanvasReadOnlyProjection.document(value, "00000000-0000-4000-8000-000000000000"))
        assertNotNull(CanvasReadOnlyProjection.document(value, otherDocumentID))
        // The captured project/revision is preserved verbatim, not re-derived.
        assertEquals(12L, value.revision)
    }

    @Test
    fun nodesKeepTheEditorZOrderDeterministically() {
        val document = CanvasReadOnlyProjection.document(project(), documentID)!!
        val ordered = CanvasReadOnlyProjection.sortedNodes(document).map { it.id }
        assertEquals(listOf(textNodeID, imageNodeID, shapeNodeID), ordered)
        assertTrue(document.nodes.any { it.id == imageNodeID && it.asset?.id == imageAssetID })
    }

    @Test
    fun fitViewBoundsTheRealContentAndUsesBoundedZoom() {
        val document = CanvasReadOnlyProjection.document(project(), documentID)!!
        val view = CanvasReadOnlyProjection.fitView(document, 1200, 800, density = 2f)
        assertTrue(view.zoom.isFinite())
        assertTrue(view.zoom in 0.2f..1f)
        assertTrue(view.panX.isFinite())
        assertTrue(view.panY.isFinite())
        val empty = CanvasReadOnlyProjection.fitView(
            document.copy(nodes = emptyList()), 1200, 800, density = 2f)
        assertEquals(1f, empty.zoom)
    }

    @Test
    fun unverifiedOrAbsentAssetNeverProducesABitmap() {
        val empty = emptyMap<String, android.graphics.Bitmap>()
        assertNull(CanvasReadOnlyProjection.bitmapFor(imageAssetID, empty))
        assertNull(CanvasReadOnlyProjection.bitmapFor(null, empty))
        assertNull(CanvasReadOnlyProjection.bitmapFor("77777777-7777-4777-8777-777777777777", empty))
    }
}
