// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored R2 design contract checks. NOT RUN in contracts09. */
class DesignContractTest {
    @Test
    fun `design actions are closed and match the typed action enum`() {
        assertEquals(
            DesignActionKind.entries.map { it.wire },
            DesignWireActions.ALL)
        assertEquals(18, DesignWireActions.ALL.size)
        assertEquals(7, DesignWireActions.CANVAS.size)
        assertEquals(11, DesignWireActions.OWNER.size)
        assertEquals(DesignWireActions.ALL.size, DesignWireActions.ALL.distinct().size)
        assertTrue(DesignWireActions.CANVAS.all { it.startsWith("design.canvas.") })
        assertTrue(DesignWireActions.OWNER.all { it.startsWith("design.owner.") })
        assertTrue(DesignActionKind.OWNER_ADOPT.mutation)
        assertFalse(DesignActionKind.OWNER_COMPARE.mutation)
    }

    @Test
    fun `target identity keeps explicit owner document source storage and origin`() {
        val target = DesignTargetIdentity(
            kind = DesignTargetKind.FILE_DOCUMENT,
            ownerID = "workspace-1",
            documentID = "doc-1",
            sourceID = "notes/plan.md",
            environmentID = "env-1",
            revision = "rev-1",
            originConversationID = "chat-1",
        )
        val binding = DesignTargetBinding(
            target = target,
            storage = CreativeStorageLayer.Workspace("workspace-1"),
            origin = CreativeOriginContext(CreativeOriginContext.FILES, ownerID = "file-1"),
            sessionToken = "session-1",
        )
        assertEquals("fileDocument", binding.target.kind.wire)
        assertEquals("workspace-1", binding.target.ownerID)
        assertEquals("notes/plan.md", binding.target.sourceID)
        assertTrue(binding.storage is CreativeStorageLayer.Workspace)
        assertNotNull(binding.origin)
        assertEquals("session-1", binding.sessionToken)
        assertEquals("canvasNode", DesignTargetKind.CANVAS_NODE.wire)
        assertEquals("creativeDocument", DesignTargetKind.CREATIVE_DOCUMENT.wire)
        assertEquals("chatAttachment", DesignTargetKind.CHAT_ATTACHMENT.wire)
        assertTrue(DesignWireErrors.ALL.contains(DesignWireErrors.DESIGN_PUBLICATION_PENDING))
        assertTrue(DesignWireErrors.ALL.contains(DesignWireErrors.DESIGN_PREVIEW_TOO_LARGE))
        assertEquals(8, DesignWireErrors.ALL.size)
    }

    @Test
    fun `project projection preserves the exact shared json including unknown fields`() {
        val raw = JsonObject(
            mapOf(
                "nodeID" to JsonPrimitive("node-1"),
                "contentType" to JsonPrimitive("notes"),
                "unknownFutureField" to JsonPrimitive("kept")
            )
        )
        val projection = DesignProjectProjection(
            contentType = DesignContentType.NOTES,
            brief = DesignBriefModel(goal = "Explain the design", createdAt = "2026-11-01T00:00:00Z"),
            spec = DesignSpecModel(palette = listOf("#ffffff")),
            candidates = emptyList(),
            createdAt = "2026-11-01T00:00:00Z",
            updatedAt = "2026-11-01T00:00:00Z",
            rawProject = raw,
        )
        assertEquals("kept", (projection.rawProject["unknownFutureField"] as JsonPrimitive).content)
        assertEquals(raw, projection.rawProject)
        assertEquals(DesignContentType.NOTES, projection.contentType)
        assertEquals("Explain the design", projection.brief?.goal)
    }

    @Test
    fun `decision and publication states do not collapse pending into success`() {
        val pendingDelivery = DesignDelivery(DesignDeliveryState.PENDING, "task ingress unavailable")
        val pendingPublication = DesignPublication(
            state = DesignPublicationState.PENDING,
            reason = "publication port not connected",
        )
        assertFalse(pendingDelivery.state == DesignDeliveryState.DELIVERED)
        assertFalse(pendingPublication.state == DesignPublicationState.PUBLISHED)
        assertEquals("pending", pendingDelivery.state.wire)
        assertEquals("notRequired", DesignPublicationState.NOT_REQUIRED.wire)
        assertEquals("published", DesignPublicationState.PUBLISHED.wire)
    }

    @Test
    fun `preview and export receipts carry verified path digest and size`() {
        val target = DesignTargetIdentity(
            kind = DesignTargetKind.CANVAS_NODE,
            ownerID = "canvas-1",
            documentID = "doc-1",
            sourceID = "node-1",
        )
        val preview = DesignPreviewReceipt(
            target = target,
            ownerRevision = 3,
            candidateID = "candidate-1",
            format = "png",
            rootPath = "/trusted/design-root",
            relativePath = "DesignPreviews/candidate-1.png",
            byteCount = 1234,
            sha256 = "a".repeat(64),
            width = 640,
            height = 480,
            createdAt = "2026-11-01T00:00:00Z",
        )
        val export = DesignExportReceipt(
            target = target,
            ownerRevision = 3,
            revisionID = "rev-2",
            format = "png",
            rootPath = "/trusted/design-root",
            relativePath = "DesignExports/rev-2.png",
            byteCount = 1234,
            sha256 = "b".repeat(64),
            createdAt = "2026-11-01T00:00:00Z",
        )
        assertTrue(preview.relativePath.isNotEmpty())
        assertTrue(preview.rootPath.startsWith("/"))
        assertEquals(64, preview.sha256.length)
        assertEquals(1234L, preview.byteCount)
        assertTrue(export.relativePath.isNotEmpty())
        assertTrue(export.rootPath.startsWith("/"))
        assertFalse(export.relativePath.startsWith("/"))
        assertEquals(DesignWireLimits.MAX_PREVIEW_BYTES, 8 * 1024 * 1024)
        assertEquals(DesignWireLimits.MAX_DESIGN_SOURCE_BYTES, 64L * 1024 * 1024)
    }
}
