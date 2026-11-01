// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The facade methods must dispatch the closed native actions with the exact
 * byte-derived payload, and must refuse a stale staging token/epoch before any
 * request crosses the bridge. The envelopes stay the frozen DTOs.
 */
class CreativeProjectControllerSourceCreateTest {
    private class FakeTransport(private val responder: (JsonObject) -> String) :
        CreativeTransport {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return responder(Json.parseToJsonElement(request) as JsonObject)
        }
    }

    private val canvasResponse = """
        {"version":5,"ok":true,
         "project":{"id":"11111111-1111-1111-1111-111111111111","schemaVersion":7,
           "name":"Board","documents":[{"id":"22222222-2222-2222-2222-222222222222",
             "name":"Document","nodes":[],"createdAt":"2026-01-01T00:00:00Z",
             "updatedAt":"2026-01-01T00:00:00Z"}],
           "selectedDocumentID":"22222222-2222-2222-2222-222222222222",
           "revision":1,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
         "assetsBasePath":"/accepted/FloeAgent/Materials","writable":true,"recoveryWarnings":[]}
    """.trimIndent()

    private val mediaResponse = """
        {"version":5,"ok":true,
         "project":{"id":"33333333-3333-3333-3333-333333333333","kind":"image",
           "name":"Photo","createdAt":"2026-01-01T00:00:00Z",
           "updatedAt":"2026-01-01T00:00:00Z","revision":2,"ownerKind":"standalone"},
         "mediaRootPath":"/accepted/FloeAgent/WorkbenchRoot/3333",
         "storage":{"kind":"appOwned"},"writable":true,"warnings":[]}
    """.trimIndent()

    private fun transport(): FakeTransport = FakeTransport { request ->
        when (request["operation"]?.toString()?.trim('"')) {
            "handshake" -> """
                {"version":5,"ok":true,"schema":"floe.creative/5",
                 "actions":["canvas.patch","media.project.apply","canvas.createFromStaged",
                            "media.project.createFromStaged"],
                 "requestMaxBytes":65536,"responseMaxBytes":16777216,
                 "canvasSchemaVersion":7,"mediaSchemaVersion":1}
            """.trimIndent()
            "bind" -> """{"version":5,"ok":true,"bound":true,"epoch":7,"rootFingerprint":"root7"}"""
            "command" -> when (request["action"]?.toString()?.trim('"')) {
                "canvas.createFromStaged" -> canvasResponse
                "media.project.createFromStaged" -> mediaResponse
                else -> """{"version":5,"ok":false,"error":"unsupportedAction"}"""
            }
            else -> """{"version":5,"ok":false,"error":"unsupportedOperation"}"""
        }
    }

    @Test
    fun `canvas source create dispatches the closed action with measured fields`() = runBlocking {
        val transport = transport()
        val controller = CreativeProjectController(
            transport = transport, epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined)
        controller.bind(7)
        val envelope = controller.createCanvasFromStaged(CreativeCanvasSourceRequest(
            token = "session-1.token-1",
            opID = "op-canvas-1",
            name = "Board",
            workspaceID = null,
            fileName = "photo.png",
            mimeType = "image/png",
            byteCount = 2048,
            sha256 = "a".repeat(64),
            sourceKind = "image",
            width = 640,
            height = 480,
            sessionToken = "session-1"))
        assertEquals("11111111-1111-1111-1111-111111111111", envelope.project.id)
        assertEquals("/accepted/FloeAgent/Materials", envelope.assetsBasePath)

        val request = transport.requests.last()
        assertTrue(request.contains("\"action\":\"canvas.createFromStaged\""))
        assertTrue(request.contains("\"token\":\"session-1.token-1\""))
        assertTrue(request.contains("\"opID\":\"op-canvas-1\""))
        assertTrue(request.contains("\"sourceKind\":\"image\""))
        assertTrue(request.contains("\"width\":640"))
        assertTrue(request.contains("\"height\":480"))
        assertTrue(request.contains("\"byteCount\":2048"))
        assertTrue(request.contains("\"sha256\":\"${"a".repeat(64)}\""))
    }

    @Test
    fun `media source create dispatches explicit storage origin and measured metadata`() =
        runBlocking {
            val transport = transport()
            val controller = CreativeProjectController(
                transport = transport, epochProvider = { 7L },
                ioDispatcher = Dispatchers.Unconfined)
            controller.bind(7)
            val envelope = controller.createMediaFromStaged(CreativeMediaSourceRequest(
                token = "session-1.token-2",
                opID = "op-media-1",
                name = "Photo",
                kind = "image",
                storage = CreativeStorageLayer.AppOwned,
                origin = CreativeOriginContext(CreativeOriginContext.FILES),
                fileName = "photo.png",
                mimeType = "image/png",
                byteCount = 4096,
                sha256 = "b".repeat(64),
                sourceKind = "image",
                width = 640,
                height = 480,
                durationSeconds = null,
                frameRate = null,
                rotationDegrees = null,
                sessionToken = "session-1"))
            assertEquals("33333333-3333-3333-3333-333333333333", envelope.project.id)
            assertEquals(CreativeStorageLayer.AppOwned, envelope.storage)

            val request = transport.requests.last()
            assertTrue(request.contains("\"action\":\"media.project.createFromStaged\""))
            assertTrue(request.contains("\"storage\":{\"kind\":\"appOwned\"}"))
            assertTrue(request.contains("\"origin\":{\"kind\":\"files\"}"))
            assertTrue(request.contains("\"sourceKind\":\"image\""))
            assertTrue(request.contains("\"width\":640"))
        }

    @Test
    fun `a staging token from another session never crosses the bridge`() = runBlocking {
        val transport = transport()
        val controller = CreativeProjectController(
            transport = transport, epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined)
        controller.bind(7)
        val before = transport.requests.size
        val error = runCatching {
            controller.createCanvasFromStaged(CreativeCanvasSourceRequest(
                token = "other-session.token", opID = "op-canvas-2", name = "Board",
                workspaceID = null, fileName = "photo.png", mimeType = "image/png",
                byteCount = 10, sha256 = "c".repeat(64), sourceKind = "image",
                width = null, height = null, sessionToken = "session-1"))
        }.exceptionOrNull()
        assertTrue(error is CreativeException)
        assertEquals("assetStagingInvalid", (error as CreativeException).code)
        assertEquals(before, transport.requests.size)
    }

    @Test
    fun `a stale runtime epoch refuses source creation before dispatch`() = runBlocking {
        val transport = transport()
        var epoch = 7L
        val controller = CreativeProjectController(
            transport = transport, epochProvider = { epoch },
            ioDispatcher = Dispatchers.Unconfined)
        controller.bind(7)
        epoch = 8L
        val before = transport.requests.size
        val error = runCatching {
            controller.createMediaFromStaged(CreativeMediaSourceRequest(
                token = "session-1.token-3", opID = "op-media-2", name = "Photo",
                kind = "image", storage = CreativeStorageLayer.AppOwned, origin = null,
                fileName = "photo.png", mimeType = "image/png", byteCount = 10,
                sha256 = "d".repeat(64), sourceKind = "image", width = 640,
                height = 480, durationSeconds = null, frameRate = null,
                rotationDegrees = null, sessionToken = "session-1"))
        }.exceptionOrNull()
        assertTrue(error is CreativeException)
        assertEquals("staleGeneration", (error as CreativeException).code)
        assertEquals(before, transport.requests.size)
    }

    @Test
    fun `an invalid sha256 is refused before dispatch`() = runBlocking {
        val transport = transport()
        val controller = CreativeProjectController(
            transport = transport, epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined)
        controller.bind(7)
        val before = transport.requests.size
        val error = runCatching {
            controller.createCanvasFromStaged(CreativeCanvasSourceRequest(
                token = "session-1.token-4", opID = "op-canvas-3", name = "Board",
                workspaceID = null, fileName = "photo.png", mimeType = "image/png",
                byteCount = 10, sha256 = "not-a-digest", sourceKind = "image",
                width = null, height = null, sessionToken = "session-1"))
        }.exceptionOrNull()
        assertEquals("invalidDigest", (error as CreativeException).reason)
        assertEquals(before, transport.requests.size)
    }
}
