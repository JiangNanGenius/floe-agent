// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeHostServiceTest {
    private class FakeTransport(
        private val responder: (JsonObject) -> String,
    ) : CreativeTransport {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            val objectValue = Json.parseToJsonElement(request) as JsonObject
            return responder(objectValue)
        }
    }

    private val handshake = """
        {"version":5,"ok":true,"schema":"floe.creative/5","actions":["canvas.patch","media.project.apply"],
         "requestMaxBytes":65536,"responseMaxBytes":16777216,"canvasSchemaVersion":7,"mediaSchemaVersion":1}
    """.trimIndent()

    private fun goodTransport(): FakeTransport = FakeTransport { request ->
        when (request["operation"]?.toString()?.trim('"')) {
            "handshake" -> handshake
            "bind" -> """{"version":5,"ok":true,"bound":true,"epoch":7,"rootFingerprint":"abcd1234"}"""
            "command" -> when (request["action"]?.toString()?.trim('"')) {
                "canvas.library" -> """
                    {"version":5,"ok":true,"projects":[
                      {"id":"11111111-1111-1111-1111-111111111111","name":"Board",
                       "revision":2,"updatedAt":"2026-01-01T00:00:00Z","schemaVersion":7,
                       "documentCount":1,"corrupt":false,"writable":true}]}
                """.trimIndent()
                "canvas.session.close", "media.session.close" ->
                    """{"version":5,"ok":true,"closed":true,"replaced":false}"""
                else -> """{"version":5,"ok":false,"error":"unsupportedAction"}"""
            }
            else -> """{"version":5,"ok":false,"error":"unsupportedOperation"}"""
        }
    }

    @Test
    fun `v5 bind and typed canvas library use the existing bridge`() = runBlocking {
        var epoch = 7L
        val transport = goodTransport()
        val controller = CreativeProjectController(
            transport = transport,
            epochProvider = { epoch },
            ioDispatcher = Dispatchers.Unconfined,
        )
        val binding = controller.bind(7)
        assertTrue(binding.bound)
        assertEquals(7L, binding.epoch)
        assertEquals("abcd1234", binding.rootFingerprint)

        val projects = controller.canvasLibrary()
        assertEquals(1, projects.size)
        assertEquals("Board", projects[0].name)
        assertEquals(2L, projects[0].revision)
        assertEquals(3, transport.requests.size)
        assertTrue(transport.requests[0].contains("\"operation\":\"handshake\""))
        assertTrue(transport.requests[1].contains("\"operation\":\"bind\""))
        assertTrue(transport.requests[2].contains("\"action\":\"canvas.library\""))

        epoch = 8L
        val stale = runCatching { controller.canvasLibrary() }.exceptionOrNull()
        assertTrue(stale is CreativeException)
        assertEquals("staleGeneration", (stale as CreativeException).code)
    }

    @Test
    fun `old core without v5 reports needsCoreUpdate and never dispatches data`() = runBlocking {
        val transport = FakeTransport {
            """{"version":1,"ok":false,"error":"unsupportedVersion"}"""
        }
        val controller = CreativeProjectController(
            transport = transport,
            epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined,
        )
        val status = controller.status()
        assertEquals(CreativeAvailability.NeedsCoreUpdate, status.availability)
        assertEquals("creativeBridgeV5Unsupported", status.reason)

        val bind = runCatching { controller.bind(7) }.exceptionOrNull()
        assertTrue(bind is CreativeException)
        assertEquals("needsCoreUpdate", (bind as CreativeException).code)
        assertFalse(bind.retryable)
        assertTrue(transport.requests.all { it.contains("\"operation\":\"handshake\"") })
    }

    @Test
    fun `token scoped close uses the dedicated action and returns closed`() = runBlocking {
        val transport = goodTransport()
        val controller = CreativeProjectController(
            transport = transport,
            epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined,
        )
        controller.bind(7)
        val closed = controller.closeCanvasEditor(
            "11111111-1111-1111-1111-111111111111", "session-1")
        assertTrue(closed)
        assertTrue(transport.requests.last().contains("\"action\":\"canvas.session.close\""))
        assertTrue(transport.requests.last().contains("\"sessionToken\":\"session-1\""))
    }

    @Test
    fun `staging token must belong to the live session before dispatch`() = runBlocking {
        val transport = goodTransport()
        val controller = CreativeProjectController(
            transport = transport,
            epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined,
        )
        controller.bind(7)
        val before = transport.requests.size
        val error = runCatching {
            controller.importAsset(
                token = "other-session.token", opID = "op-1",
                fileName = "a.png", mimeType = "image/png",
                byteCount = 3, sha256 = "a".repeat(64), sessionToken = "session-1")
        }.exceptionOrNull()
        assertTrue(error is CreativeException)
        assertEquals("assetStagingInvalid", (error as CreativeException).code)
        assertEquals(before, transport.requests.size)
    }
}
