// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.voice

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class C03CloudSpeechClientTest {
    private class RecordingTransport(
        private val response: String,
    ) : C03VoiceTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests += request
            return response
        }
    }

    private fun client(transport: C03VoiceTransport) =
        C03CloudSpeechClient(transport, Dispatchers.Unconfined)

    @Test
    fun capabilitiesParseOnlyRealConfiguredModelsAndBounds() = runBlocking {
        val transport = RecordingTransport(
            """
            {"ok":true,"cloudReady":true,"transportReady":true,
             "asrModels":[{"providerID":"p1","providerName":"P","modelID":"m1",
               "remoteModelID":"whisper-1","displayName":"Whisper","likelyASR":true,
               "likelyTTS":false,"credentialConfigured":true}],
             "ttsModels":[],"maxAudioBytes":999999999999,"maxTextCharacters":99,
             "maxSegments":99999,"ttsSampleRate":1}
            """.trimIndent(),
        )
        val result = client(transport).capabilities()
        assertTrue(result.cloudReady)
        assertEquals(1, result.asrModels.size)
        assertTrue(result.asrModels.single().likelyASR)
        assertEquals(64L * 1024L * 1024L, result.maxAudioBytes)
        assertEquals(99, result.maxTextCharacters)
        assertEquals(5_000, result.maxSegments)
        assertEquals(8_000, result.ttsSampleRate)
    }

    @Test
    fun transcriptionStartCarriesOnlyNonSecretOwnerAndProjectIdentity() = runBlocking {
        val transport = RecordingTransport("""{"ok":true,"operationID":"op-1"}""")
        val media = C03MediaProjectContext(
            projectID = "11111111-1111-1111-1111-111111111111",
            sessionToken = "token",
            storageKind = "appOwned",
            workspaceID = null,
            originKind = "chat",
            originOwnerID = "22222222-2222-2222-2222-222222222222",
            originEnvironmentID = "env",
            expectedRevision = 7L,
            assetID = "33333333-3333-3333-3333-333333333333",
        )
        val id = client(transport).startTranscription(
            media = media,
            selection = C03CloudVoiceSelection("p1", "m1", "v1", "en", 1.0),
            language = "en",
            owner = C03VoiceOwner(conversationID = "c1"),
        )
        assertEquals("op-1", id)
        val request = C03Json.parse(transport.requests.single())!!
        assertEquals(7, request.int("version"))
        assertEquals("c03.asr.start", request.string("operation"))
        val wire = request.toString()
        assertFalse(wire.contains("apiKey", ignoreCase = true))
        assertFalse(wire.contains("authorization", ignoreCase = true))
        assertFalse(wire.contains("http", ignoreCase = true))
        assertEquals("p1", request.obj("selection")?.string("providerID"))
        assertEquals("m1", request.obj("selection")?.string("modelID"))
        assertEquals(7L, request.obj("media")?.long("expectedRevision"))
    }

    @Test
    fun pageAndStatusParseBoundedSegments() = runBlocking {
        val transport = RecordingTransport(
            """
            {"ok":true,"state":"completed","progress":1.0,"segmentCount":2,
             "segments":[{"start":0.0,"end":1.2,"text":" Hello "},
               {"start":1.2,"end":2.4,"text":"世界"}],
             "nextOffset":2,"total":2}
            """.trimIndent(),
        )
        val page = client(transport).transcriptionPage("op", 0, 200)
        assertEquals(2, page.segments.size)
        assertEquals("Hello", page.segments.first().text)
        assertEquals(2, page.nextOffset)
        assertEquals(2, page.total)
    }

    @Test
    fun unsupportedVersionBecomesNeedsCoreUpdate() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":false,"error":"unsupportedVersion","reason":"v7Unsupported"}""",
        )
        try {
            client(transport).capabilities()
            fail("expected typed failure")
        } catch (failure: C03VoiceFailure) {
            assertEquals(C03VoiceErrorCode.NEEDS_CORE_UPDATE, failure.code)
        }
    }

    @Test
    fun ttsStatusReturnsRealPathAndFailureWithoutProviderText() = runBlocking {
        val transport = RecordingTransport(
            """
            {"ok":true,"state":"failed","progress":0.4,
             "failure":{"code":"authentication","reason":"providerAuth","retryable":false}}
            """.trimIndent(),
        )
        val status = client(transport).synthesisStatus("op")
        assertEquals(C03CloudOperationState.FAILED, status.state)
        assertEquals(C03VoiceErrorCode.AUTHENTICATION, status.failure?.code)
        assertNull(status.audioPath)
        assertFalse(status.failure?.reason?.contains("Bearer") == true)
    }

    @Test
    fun subtitleReceiptRequiresRealReceiptObject() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":true,"receipt":{"projectID":"p","revision":8,"canUndo":true,
                "canRedo":false,"opID":"o","idempotent":false}}""",
        )
        val receipt = client(transport).writeSubtitles(
            operationID = "op",
            media = C03MediaProjectContext(
                "p", "s", "appOwned", null, null, null, null, 7, "a",
            ),
            expectedRevision = 7,
            replaceTranscribed = true,
        )
        assertEquals("p", receipt.projectID)
        assertEquals(8L, receipt.revision)
        assertTrue(receipt.canUndo)
    }

    @Test
    fun requestIsRejectedBeforeTransportWhenResponseIsMalformed() = runBlocking {
        val transport = RecordingTransport("not json")
        try {
            client(transport).capabilities()
            fail("expected typed failure")
        } catch (failure: C03VoiceFailure) {
            assertEquals(C03VoiceErrorCode.INVALID_RESPONSE, failure.code)
        }
    }

    @Test
    fun settingsLoadUsesCanonicalOperationAndEpochWithoutSecretShape() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":true,"found":true,"unreadable":false,"revision":4,
                "settings":{"schema":2,"revision":4,"inputEngine":"system",
                  "outputEngine":"cloud",
                  "cloudInput":{"providerID":"p","modelID":"m","voiceID":"","rate":1.0},
                  "cloudOutput":{"providerID":"p","modelID":"m","voiceID":"alloy","rate":1.0},
                  "rate":1.0,"pitch":0.0,"replaceTranscribedCaptions":true}}""",
        )
        val loaded = client(transport).loadSettings(epoch = 9L)
        assertTrue(loaded.found)
        assertEquals(4L, loaded.revision)
        assertEquals(C03VoiceEngine.SYSTEM, loaded.settings?.inputEngine)
        assertEquals("alloy", loaded.settings?.cloudOutput?.voiceID)
        val request = C03Json.parse(transport.requests.single())!!
        assertEquals("c03.settings.load", request.string("operation"))
        assertEquals(9L, request.long("epoch"))
        assertFalse(request.toString().contains("apiKey", ignoreCase = true))
    }

    @Test
    fun settingsSaveCarriesExpectedRevisionAndNormalizedNonSecretDocument() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":true,"revision":5,"settings":{"schema":2,"inputEngine":"cloud",
                "outputEngine":"system","cloudInput":{"providerID":"p","modelID":"m"},
                "cloudOutput":{},"rate":1.0,"pitch":0.0,
                "replaceTranscribedCaptions":false}}""",
        )
        val saved = client(transport).saveSettings(
            C03VoiceSettings(
                inputEngine = C03VoiceEngine.CLOUD,
                cloudInput = C03CloudVoiceSelection("p", "m"),
            ),
            expectedRevision = 4L,
            epoch = 9L,
        )
        assertEquals(5L, saved.revision)
        val request = C03Json.parse(transport.requests.single())!!
        assertEquals("c03.settings.save", request.string("operation"))
        assertEquals(4L, request.long("expectedRevision"))
        assertEquals(9L, request.long("epoch"))
        assertEquals("cloud", request.obj("settings")?.string("inputEngine"))
        assertFalse(request.toString().contains("secret", ignoreCase = true))
    }

    @Test
    fun longMediaPlanAndChunkRequestsCarryOffsetsNotPaths() = runBlocking {
        val media = C03MediaProjectContext(
            "11111111-1111-1111-1111-111111111111", "token", "appOwned",
            null, "chat", "22222222-2222-2222-2222-222222222222", "env", 7,
            "33333333-3333-3333-3333-333333333333",
        )
        val planTransport = RecordingTransport(
            """{"ok":true,"operationID":"op-2","sourcePath":"/root/source.mp4",
                "stagingPath":"/root/Voice/ASR/op-2","sourceBytes":90000000,
                "durationSeconds":3600.0,"chunkLimitBytes":20971520,
                "estimatedChunks":5}""",
        )
        val plan = client(planTransport).planTranscription(
            media, C03CloudVoiceSelection("p", "m"), "en",
            C03VoiceOwner(projectID = "11111111-1111-1111-1111-111111111111"),
            epoch = 9L,
        )
        assertEquals("op-2", plan.operationID)
        assertEquals(5, plan.estimatedChunks)
        val chunkTransport = RecordingTransport("""{"ok":true,"segmentCount":3}""")
        val count = client(chunkTransport).applyChunk(
            operationID = "op-2",
            chunkIndex = 2,
            sourceStartSeconds = 120.5,
            sourceDurationSeconds = 60.0,
            sampleRate = 16000,
            channels = 1,
        )
        assertEquals(3, count)
        val chunkRequest = C03Json.parse(chunkTransport.requests.single())!!
        assertEquals("c03.asr.chunk", chunkRequest.string("operation"))
        assertEquals(2, chunkRequest.int("chunkIndex"))
        assertEquals(120.5, chunkRequest.double("sourceStart") ?: -1.0, 0.0)
        assertFalse(chunkRequest.toString().contains("/root", ignoreCase = true))
        assertFalse(chunkRequest.toString().contains("Bearer", ignoreCase = true))
    }

    @Test
    fun utteranceBeginReturnsOnlyTrustedNativeStagingHandle() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":true,"pathToken":"token-1","path":"/root/Voice/Utterances/u.wav",
                "maxDurationSeconds":60}""",
        )
        val staging = client(transport).beginUtterance(
            C03VoiceOwner(conversationID = "c1"),
            epoch = 9L,
        )
        assertEquals("token-1", staging.pathToken)
        assertEquals(60, staging.maxDurationSeconds)
        val request = C03Json.parse(transport.requests.single())!!
        assertEquals("c03.utterance.begin", request.string("operation"))
        assertEquals("c1", request.obj("owner")?.string("conversationID"))
        assertFalse(request.toString().contains("apiKey", ignoreCase = true))
    }

    @Test
    fun textOnlyNeedsTimingFailureIsTyped() = runBlocking {
        val transport = RecordingTransport(
            """{"ok":false,"error":"needsTiming","reason":"providerReturnedNoTiming"}""",
        )
        try {
            client(transport).finishTranscription("op", 2, 120.0)
            fail("expected needsTiming")
        } catch (failure: C03VoiceFailure) {
            assertEquals(C03VoiceErrorCode.NEEDS_TIMING, failure.code)
        }
    }

    private fun JsonObject.int(key: String): Int? = C03Json.int(this[key])
    private fun JsonObject.long(key: String): Long? = C03Json.long(this[key])
    private fun JsonObject.string(key: String): String? = C03Json.string(this[key])
    private fun JsonObject.double(key: String): Double? = C03Json.double(this[key])
    private fun JsonObject.obj(key: String): JsonObject? = C03Json.objectValue(this[key])
}
