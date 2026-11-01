// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CanvasPatch
import com.floe.android.feature.canvas.CanvasPatchOperation
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaEditCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeWireCodecTest {
    @Test
    fun `old core unsupported version maps to needsCoreUpdate`() {
        val error = runCatching {
            CreativeWire.response("""{"version":1,"ok":false,"error":"unsupportedVersion"}""")
        }.exceptionOrNull()
        assertTrue(error is CreativeException)
        assertEquals("needsCoreUpdate", (error as CreativeException).code)
        assertFalse(error.retryable)
    }

    @Test
    fun `v5 typed failure preserves code reason and retryable`() {
        val error = runCatching {
            CreativeWire.response(
                """{"version":5,"ok":false,"error":"staleGeneration","reason":"stale","retryable":true}""")
        }.exceptionOrNull() as CreativeException
        assertEquals("staleGeneration", error.code)
        assertEquals("stale", error.reason)
        assertTrue(error.retryable)
    }

    @Test
    fun `handshake accepts only the creative v5 schema and actions`() {
        val state = CreativeWire.handshakeState(
            CreativeWire.response(
                """{"version":5,"ok":true,"schema":"floe.creative/5","actions":["canvas.patch","media.project.apply"],"requestMaxBytes":65536,"responseMaxBytes":16777216,"canvasSchemaVersion":7,"mediaSchemaVersion":1}"""))
        assertEquals("floe.creative/5", state.schema)
        assertEquals(65_536, state.requestMaxBytes)
        assertTrue(state.actions.contains("canvas.patch"))
    }

    @Test
    fun `canvas project decodes alternating UUID arrays not objects`() {
        val project = CreativeWire.decodeCanvasProject(
            CreativeWire.response(
                """{"version":5,"ok":true,"project":{"id":"11111111-1111-1111-1111-111111111111","schemaVersion":7,"name":"Board","documents":[{"id":"22222222-2222-2222-2222-222222222222","name":"Doc","nodes":[],"connections":[],"strokes":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"selectedDocumentID":"22222222-2222-2222-2222-222222222222","agentConversationIDsByDocument":["22222222-2222-2222-2222-222222222222","33333333-3333-3333-3333-333333333333"],"viewports":["22222222-2222-2222-2222-222222222222",{"center":{"x":10,"y":20},"scale":1.5}],"revision":3,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}""").let {
                    (it["project"] as kotlinx.serialization.json.JsonObject)
                })
        assertEquals(1, project.viewports.size)
        assertEquals("22222222-2222-2222-2222-222222222222", project.viewports[0].documentID)
        assertEquals(1.5, project.viewports[0].viewport.scale, 0.0001)
        assertEquals(1, project.agentConversationIDsByDocument.size)
        assertEquals("33333333-3333-3333-3333-333333333333",
            project.agentConversationIDsByDocument[0].conversationID)
    }

    @Test
    fun `canvas patch and media command encode the exact closed wire shape`() {
        val patch = CanvasPatchRequest(
            canvasID = "11111111-1111-1111-1111-111111111111",
            expectedRevision = 3,
            sessionToken = "session-1",
            opID = "op-1",
            patch = CanvasPatch(
                canvasID = "11111111-1111-1111-1111-111111111111",
                documentID = "22222222-2222-2222-2222-222222222222",
                expectedRevision = 3,
                operations = listOf(
                    CanvasPatchOperation(
                        id = "33333333-3333-3333-3333-333333333333",
                        kind = "create",
                        nodeID = "44444444-4444-4444-4444-444444444444",
                        nodeKind = "text",
                        text = "Hello",
                        position = CanvasPoint(10.0, 20.0),
                        size = CanvasSize(100.0, 40.0),
                    ))))
        val encoded = CreativeWire.encodeCanvasPatch(patch)
        assertEquals("session-1", encoded["sessionToken"]?.toString()?.trim('"'))
        assertEquals("op-1", encoded["opID"]?.toString()?.trim('"'))
        val operations = (encoded["patch"] as kotlinx.serialization.json.JsonObject)["operations"]
        assertTrue(operations.toString().contains("\"kind\":\"create\""))

        val canvas = CreativeWire.encodeMediaCommand(
            MediaEditCommand.SetCanvas(width = 800, height = 600, frameRate = null))
        assertEquals("setCanvas", canvas["type"]?.toString()?.trim('"'))
        assertEquals("800", canvas["width"]?.toString())

        val storage = CreativeWire.encodeStorage(
            CreativeStorageLayer.Workspace("55555555-5555-5555-5555-555555555555"))
        assertEquals("workspace", storage["kind"]?.toString()?.trim('"'))
        assertEquals("55555555-5555-5555-5555-555555555555",
            storage["workspaceID"]?.toString()?.trim('"'))

        val origin = CreativeWire.encodeOrigin(
            CreativeOriginContext(
                kind = CreativeOriginContext.WORKSPACE,
                ownerID = "55555555-5555-5555-5555-555555555555",
                environmentID = "env-1"))
        assertEquals("workspace", origin["kind"]?.toString()?.trim('"'))
        assertEquals("env-1", origin["environmentID"]?.toString()?.trim('"'))
    }

    @Test
    fun `media project derives undo state and keeps opaque timeline`() {
        val project = CreativeWire.decodeMediaProject(
            CreativeWire.response(
                """{"version":5,"ok":true,"project":{"id":"44444444-4444-4444-4444-444444444444","schemaVersion":1,"kind":"image","name":"Poster","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","revision":2,"canvas":{"width":800,"height":600},"assets":[],"imageLayers":[{"id":"55555555-5555-5555-5555-555555555555","kind":"text","name":"Title","transform":{"centerX":0.5,"centerY":0.5,"scale":1,"rotationDegrees":0},"opacity":1,"isHidden":false,"isLocked":false,"adjustment":{},"text":{"text":"Hello","fontSize":48,"colorHex":"#000000"}}],"ownerKind":"standalone","ownerID":"44444444-4444-4444-4444-444444444444","undoHistory":[{"revision":1}],"redoHistory":[],"videoTimeline":{"clips":[]},"unknownOperations":[]}}""").let {
                    (it["project"] as kotlinx.serialization.json.JsonObject)
                })
        assertTrue(project.canUndo)
        assertFalse(project.canRedo)
        assertEquals(1, project.imageLayers.size)
        assertEquals("Hello", project.imageLayers[0].text?.text)
        assertTrue(project.videoTimeline != null)
    }
}
