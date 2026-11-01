// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageRequestState
import com.floe.android.feature.workbench.MediaJobState
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored source-level tests for the App generation host. They use a fake
 * transport (no native library, network or provider) and assert exact wire
 * identity plus DTO decoding. Actual execution belongs to the integrated
 * App/Kotlin batch.
 */
class CreativeR2GenerationHostTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val context = CreativeProjectContext(
        projectID = "11111111-1111-4111-8111-111111111111",
        sessionToken = "session-generation-1",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext(CreativeOriginContext.STANDALONE))

    private class FakeTransport(
        private val responder: (String, JsonObject) -> String,
    ) : CreativeTransport {
        val requests = mutableListOf<JsonObject>()

        override fun exchange(request: String): String {
            val body = Json.parseToJsonElement(request) as JsonObject
            requests.add(body)
            val action = body["action"]?.jsonPrimitive?.content ?: ""
            val payload = body["payload"] as? JsonObject ?: JsonObject(emptyMap())
            return responder(action, payload)
        }
    }

    private fun envelope(fields: String): String =
        """{"version":6,"schema":"floe.creative/6","ok":true$fields}"""

    private class FakeForeground : GenerationForegroundPort {
        val acquired = mutableListOf<String>()
        val released = mutableListOf<String>()

        override suspend fun acquire(
            jobID: String, epoch: Long, projectID: String,
        ): GenerationForegroundClaim {
            acquired += jobID
            return GenerationForegroundClaim(
                jobID = jobID, epoch = epoch,
                projectID = projectID, token = "test-token")
        }

        override fun release(claim: GenerationForegroundClaim?) {
            claim?.let { released += it.jobID }
        }

        override fun release(jobID: String, epoch: Long) {
            released += jobID
        }

        override fun cancel(jobID: String, epoch: Long) {
            released += jobID
        }

        override fun releaseAll(epoch: Long) = Unit
    }

    private fun host(
        responder: (String, JsonObject) -> String,
    ): Pair<CreativeR2GenerationHost, FakeTransport> {
        val transport = FakeTransport(responder)
        return CreativeR2GenerationHost(
            transport = transport, epochProvider = { 42L },
            foreground = FakeForeground()) to transport
    }

    @Test
    fun `models decode configured routes, availability and reference policy`() =
        runBlocking {
            val (host, _) = host { action, _ ->
                assertEquals("generation.models", action)
                envelope(
                    ""","image":[{"routeID":"route-1","remoteModelID":"gpt-image-1",
                    "providerID":"provider-1","providerName":"Synthetic",
                    "kind":"image","enabled":true,"available":true,
                    "parameters":{"sizes":["1024x1024"],"aspectRatios":["1:1"],
                    "resolutions":["1K"],"maxCount":2,"maxReferenceImages":1,
                    "supportsImageToVideo":false,"supportsFirstFrame":false,
                    "codecs":[]},
                    "referenceImagePolicy":{"maxImages":1,
                    "maxBytesPerImage":12582912,
                    "acceptedMimeTypes":["image/png","image/jpeg"]},
                    "costNote":"The provider account is authoritative."}],
                    "video":[]""")
            }
            val catalog = host.models()
            val route = catalog.image.single()
            assertEquals("route-1", route.routeID)
            assertTrue(route.available)
            assertEquals(2, route.parameters.maxCount)
            assertEquals(1, route.referenceImagePolicy.maxImages)
            assertEquals(12_582_912L, route.referenceImagePolicy.maxBytesPerImage)
            assertTrue(route.costNote.isNotEmpty())
        }

    @Test
    fun `submit image carries explicit context, revision, opID and request identity`() =
        runBlocking {
            val (host, transport) = host { action, _ ->
                assertEquals("generation.image.submit", action)
                envelope(
                    ""","requestID":"request-1",
                    "projectID":"11111111-1111-4111-8111-111111111111",
                    "acceptedAt":"2026-11-01T00:00:00Z",
                    "state":"submitted","idempotent":false""")
            }
            val handle = host.submitImage(
                context = context,
                expectedRevision = 7,
                opID = "op-image-1",
                request = ImageGenerationRequest(
                    prompt = "a red square",
                    modelRouteID = "route-1",
                    count = 2,
                    idempotencyKey = "idem-image-1",
                ),
            )
            assertEquals("request-1", handle.requestID)
            assertEquals(ImageRequestState.SUBMITTED, handle.state)
            val body = transport.requests.single()
            val payload = body["payload"]!!.jsonObject
            assertEquals(
                context.projectID,
                payload["context"]!!.jsonObject["projectID"]!!.jsonPrimitive.content)
            assertEquals(7L, payload["expectedRevision"]!!.jsonPrimitive.content.toLong())
            assertEquals("op-image-1", payload["opID"]!!.jsonPrimitive.content)
            val request = payload["request"]!!.jsonObject
            assertEquals("route-1", request["modelRouteID"]!!.jsonPrimitive.content)
            assertEquals("idem-image-1", request["idempotencyKey"]!!.jsonPrimitive.content)
            assertEquals(2, request["count"]!!.jsonPrimitive.content.toInt())
            assertFalse(request.containsKey("path"))
        }

    @Test
    fun `jobs uses the frozen status action without a jobID and decodes durable state`() =
        runBlocking {
            val (host, transport) = host { action, _ ->
                assertEquals("generation.video.status", action)
                envelope(
                    ""","jobs":[{"jobID":"job-1",
                    "projectID":"11111111-1111-4111-8111-111111111111",
                    "state":"waitingForProvider","updatedAt":"2026-11-01T00:00:00Z",
                    "resultAvailable":false,"providerTaskReferencePresent":true,
                    "retryable":false,"canCancel":true}]""")
            }
            val jobs = host.jobs(context, 50)
            assertEquals(1, jobs.size)
            assertEquals("job-1", jobs.single().jobID)
            assertEquals(MediaJobState.WAITING_FOR_PROVIDER, jobs.single().state)
            assertTrue(jobs.single().providerTaskReferencePresent)
            val payload = transport.requests.single()["payload"]!!.jsonObject
            assertFalse(payload.containsKey("jobID"))
            assertEquals(50, payload["limit"]!!.jsonPrimitive.content.toInt())
        }

    @Test
    fun `candidate accept decodes the native media receipt`() = runBlocking {
        val (host, _) = host { action, _ ->
            assertEquals("generation.candidates.accept", action)
            envelope(
                ""","projectID":"11111111-1111-4111-8111-111111111111",
                "revision":3,"canUndo":true,"canRedo":false,
                "opID":"accept-1","idempotent":false""")
        }
        val receipt = host.acceptCandidate(
            context = context,
            expectedRevision = 2,
            candidateID = "candidate-1",
            opID = "accept-1",
        )
        assertEquals(3L, receipt.revision)
        assertTrue(receipt.canUndo)
        assertFalse(receipt.idempotent)
    }

    @Test
    fun `typed native refusal is surfaced without a fabricated success`() = runBlocking {
        val (host, _) = host { _, _ ->
            """{"version":6,"schema":"floe.creative/6","ok":false,
               "error":"outcomeUnknown","retryable":false}"""
        }
        try {
            host.refreshJob(context, "job-unknown")
            throw AssertionError("expected a typed refusal")
        } catch (error: CreativeException) {
            assertEquals("outcomeUnknown", error.code)
            assertFalse(error.retryable)
        }
    }

    @Test
    fun `foreground snapshot parser is strict and never fabricates terminal truth`() {
        val running = GenerationForegroundWire.parse(
            "state=running;terminal=0;progress=0.4200;task=1;epoch=42")
        assertEquals("running", running?.state)
        assertEquals(false, running?.terminal)
        assertEquals(0.42, running?.progress ?: 0.0, 0.0001)
        assertTrue(running?.hasProviderTask == true)

        val ready = GenerationForegroundWire.parse(
            "state=ready;terminal=1;progress=-1;task=0;epoch=42")
        assertEquals(true, ready?.terminal)
        assertEquals(null, ready?.progress)

        assertNull(GenerationForegroundWire.parse("state=running;terminal=0"))
        assertNull(GenerationForegroundWire.parse(
            "state=running;terminal=0;progress=1.5;task=1;epoch=42"))
        assertNull(GenerationForegroundWire.parse(
            "state=../escape;terminal=0;progress=-1;task=1;epoch=42"))
        assertNull(GenerationForegroundWire.parse(
            "state=running;terminal=0;progress=-1;task=1;epoch=0"))
    }
}
