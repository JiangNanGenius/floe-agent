// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CanvasSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Source-authored canonical Canvas preview payload tests (NOT RUN here).
 *
 * These pin the acceptance rules for the additive `canvasDocument` field: the
 * sheet may only render the exact same canvas/document/node/revision. An older
 * Core without the field, a bumped schema, a different revision or a missing
 * node is a typed unavailable — never the brief/spec metadata pretending to be
 * a scene.
 */
class DesignCanvasSnapshotPayloadTest {
    private val canvasID = "11111111-1111-4111-8111-111111111111"
    private val documentID = "22222222-2222-4222-8222-222222222222"
    private val nodeID = "33333333-3333-4333-8333-333333333333"

    private fun project(
        schema: Int = 7,
        id: String = canvasID,
        revision: Long = 42L,
        document: String = documentID,
        node: String = nodeID,
    ) = CanvasProject(
        id = id,
        schemaVersion = schema,
        name = "Design canvas",
        documents = listOf(
            CanvasDocument(
                id = document,
                name = "Page",
                nodes = listOf(
                    CanvasNode(
                        id = node,
                        kind = "text",
                        text = "Actual content",
                        position = CanvasPoint(10.0, 10.0),
                        size = CanvasSize(200.0, 120.0),
                    ),
                ),
                createdAt = "2026-11-01T00:00:00Z",
                updatedAt = "2026-11-01T00:00:00Z",
            ),
        ),
        selectedDocumentID = document,
        revision = revision,
        createdAt = "2026-11-01T00:00:00Z",
        updatedAt = "2026-11-01T00:00:00Z",
    )

    @Test
    fun exactCanonicalSceneIsAccepted() {
        val document = DesignCanvasSnapshotPayload.document(
            project = project(),
            canvasID = canvasID,
            documentID = documentID,
            nodeID = nodeID,
            revision = 42L,
        )
        assertEquals(documentID, document?.id)
        assertEquals("Actual content", document?.nodes?.single()?.text)
    }

    @Test
    fun oldCoreWithoutCanvasDocumentIsTypedUnavailable() {
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = null,
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
    }

    @Test
    fun differentSchemaRevisionOrIdentityIsNeverMixed() {
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = project(schema = 6),
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = project(revision = 41L),
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = project(id = "44444444-4444-4444-8444-444444444444"),
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
    }

    @Test
    fun missingDocumentOrSelectedNodeIsUnavailable() {
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = project(document = "55555555-5555-4555-8555-555555555555"),
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
        assertNull(
            DesignCanvasSnapshotPayload.document(
                project = project(node = "66666666-6666-4666-8666-666666666666"),
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                revision = 42L,
            ),
        )
    }
}
