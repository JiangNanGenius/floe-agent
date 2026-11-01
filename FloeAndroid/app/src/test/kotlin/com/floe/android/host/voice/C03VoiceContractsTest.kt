// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C03VoiceContractsTest {
    @Test
    fun selectionNormalizationClampsRateAndDropsEmptyIds() {
        val normalized = C03CloudVoiceSelection(
            providerID = "  ",
            modelID = " model ",
            voiceID = "  alloy  ",
            language = "  ",
            rate = 9.0,
        ).normalized()
        assertNull(normalized.providerID)
        assertEquals("model", normalized.modelID)
        assertEquals("alloy", normalized.voiceID)
        assertNull(normalized.language)
        assertEquals(2.0, normalized.rate, 0.0)
        assertFalse(normalized.configured)
    }

    @Test
    fun settingsNormalizationKeepsNonSecretChooseAndPitchRange() {
        val settings = C03VoiceSettings(
            outputEngine = C03VoiceEngine.CLOUD,
            rate = -4.0,
            pitch = 12.0,
            cloudOutput = C03CloudVoiceSelection(
                providerID = "p1",
                modelID = "m1",
                voiceID = "v",
                rate = 0.1,
            ),
            transcriptionProviderID = "p1",
            transcriptionModelID = "m2",
        ).normalized()
        assertEquals(0.5, settings.rate, 0.0)
        assertEquals(6.0, settings.pitch, 0.0)
        assertEquals(0.5, settings.cloudOutput.rate, 0.0)
        assertTrue(settings.transcriptionConfigured)
        assertEquals(C03VoiceSettings.CURRENT_SCHEMA, settings.schema)
    }

    @Test
    fun timedSegmentRejectsInvalidTimeAndEmptyText() {
        assertNull(C03TimedSegment(-1.0, 1.0, "x").normalized())
        assertNull(C03TimedSegment(2.0, 1.0, "x").normalized())
        assertNull(C03TimedSegment(0.0, 1.0, "   ").normalized())
        assertNull(C03TimedSegment(Double.NaN, 1.0, "x").normalized())
        val valid = C03TimedSegment(0.25, 1.75, "  hello   world ").normalized()
        assertNotNull(valid)
        assertEquals(0.25, valid!!.start, 0.0)
        assertEquals(1.75, valid.end, 0.0)
        assertEquals("hello world", valid.text)
    }

    @Test
    fun textChunkerPreservesAllAuthoredTextAndRespectsBound() {
        val text = (1..400).joinToString(" ") { "word$it" }
        val chunks = C03TextChunker.split(text, 120)
        assertTrue(chunks.size > 1)
        assertTrue(chunks.all { it.length <= 120 })
        assertEquals(
            text.split(Regex("\\s+")).filter { it.isNotEmpty() },
            chunks.flatMap { it.split(Regex("\\s+")).filter { part -> part.isNotEmpty() } },
        )
        assertEquals(listOf("短句。"), C03TextChunker.split(" 短句。 ", 120))
    }

    @Test
    fun recognitionLifecycleHasOneTerminalAndNoFakeResult() {
        val lifecycle = C03RecognitionLifecycle()
        assertTrue(lifecycle.start())
        assertFalse(lifecycle.start())
        assertTrue(lifecycle.complete("  "))
        assertEquals(C03DictationState.FAILED, lifecycle.state)
        assertFalse(lifecycle.complete("late"))
        assertFalse(lifecycle.fail())
    }

    @Test
    fun recognitionCancelBeatsLateSuccess() {
        val lifecycle = C03RecognitionLifecycle()
        assertTrue(lifecycle.start())
        lifecycle.requestCancel()
        assertEquals(C03DictationState.CANCELLED, lifecycle.state)
        assertFalse(lifecycle.complete("late text"))
        assertEquals(C03DictationState.CANCELLED, lifecycle.state)
    }

    @Test
    fun firstUseDefaultsToSystemInputAndOutput() {
        val settings = C03VoiceSettings.DEFAULT
        assertEquals(C03VoiceEngine.SYSTEM, settings.inputEngine)
        assertEquals(C03VoiceEngine.SYSTEM, settings.outputEngine)
        assertNull(settings.cloudInput.providerID)
        assertNull(settings.cloudOutput.providerID)
        assertFalse(settings.cloudInputConfigured)
        assertEquals(2, C03VoiceSettings.CURRENT_SCHEMA)
    }

    @Test
    fun settingsNormalizationKeepsInputEngineAndCloudInputChoice() {
        val settings = C03VoiceSettings(
            inputEngine = C03VoiceEngine.CLOUD,
            cloudInput = C03CloudVoiceSelection(
                providerID = " p ",
                modelID = " m ",
                language = " en ",
                rate = 4.0,
            ),
            cloudOutput = C03CloudVoiceSelection("p", "m", "alloy", "en", 1.0),
        ).normalized()
        assertEquals(C03VoiceEngine.CLOUD, settings.inputEngine)
        assertEquals("p", settings.cloudInput.providerID)
        assertEquals("m", settings.cloudInput.modelID)
        assertEquals(2.0, settings.cloudInput.rate, 0.0)
        assertEquals("alloy", settings.cloudOutput.voiceID)
    }

    @Test
    fun temporaryConversationAllowsSystemButTypedRejectsCloud() {
        val owner = C03VoiceOwner(conversationID = "c1", temporary = true)
        val system = C03VoiceSettings.DEFAULT
        assertNull(
            C03VoiceInputGate.rejection(system, owner, true, C03VoiceCapabilities()),
        )
        val cloud = system.copy(
            inputEngine = C03VoiceEngine.CLOUD,
            cloudInput = C03CloudVoiceSelection("p", "m"),
        )
        val rejection = C03VoiceInputGate.rejection(
            cloud,
            owner,
            true,
            C03VoiceCapabilities(cloudReady = true),
        )
        assertEquals(C03VoiceErrorCode.UNCONFIGURED, rejection?.code)
        assertEquals("cloudInputUnavailableInTemporaryChat", rejection?.reason)
    }

    @Test
    fun cloudInputRequiresConfiguredModelAndPermission() {
        val cloud = C03VoiceSettings.DEFAULT.copy(inputEngine = C03VoiceEngine.CLOUD)
        val owner = C03VoiceOwner(conversationID = "c1")
        assertEquals(
            C03VoiceErrorCode.UNCONFIGURED,
            C03VoiceInputGate.rejection(
                cloud, owner, true, C03VoiceCapabilities(cloudReady = true),
            )?.code,
        )
        assertEquals(
            C03VoiceErrorCode.PERMISSION_REQUIRED,
            C03VoiceInputGate.rejection(
                cloud, owner, false, C03VoiceCapabilities(cloudReady = true),
            )?.code,
        )
    }

    @Test
    fun chunkBudgetStaysBelowProviderCeilingAndBounded() {
        assertEquals(24L * 1024L * 1024L, C03ChunkBudget.normalizedLimit(Long.MAX_VALUE))
        assertEquals(1L * 1024L * 1024L, C03ChunkBudget.normalizedLimit(1L))
        assertEquals(44L + C03ChunkBudget.payloadBytes(20L * 1024L * 1024L),
            20L * 1024L * 1024L)
        assertTrue(C03ChunkBudget.estimatedChunks(100L * 1024L * 1024L, 20L * 1024L * 1024L) >= 5)
        assertEquals(C03ChunkBudget.MAX_CHUNKS, C03ChunkBudget.estimatedChunks(Long.MAX_VALUE, 1L))
    }

    @Test
    fun wavHeaderIsCanonicalPcm16Mono() {
        val header = C03Wav.header(16_000, 1, 320)
        assertEquals(44, header.size)
        assertEquals("RIFF", String(header.copyOfRange(0, 4), Charsets.US_ASCII))
        assertEquals("WAVE", String(header.copyOfRange(8, 12), Charsets.US_ASCII))
        assertEquals("data", String(header.copyOfRange(36, 40), Charsets.US_ASCII))
        fun le16(offset: Int): Int =
            (header[offset].toInt() and 0xff) or
                ((header[offset + 1].toInt() and 0xff) shl 8)
        assertEquals(320, le16(40))
        assertEquals(1, le16(22))
    }

    @Test
    fun settingsCodecAdoptsLegacySchemaOneWithoutLosingOutputChoice() {
        val legacy = """
            {"schema":1,"outputEngine":"cloud","rate":1.25,
             "cloudOutput":{"providerID":"p","modelID":"m","voiceID":"alloy","rate":1.25},
             "transcriptionProviderID":"p","transcriptionModelID":"t"}
        """.trimIndent()
        val decoded = C03VoiceSettingsCodec.decode(legacy)
        assertFalse(decoded.unreadable)
        val settings = decoded.document?.settings
        assertNotNull(settings)
        assertEquals(C03VoiceEngine.SYSTEM, settings!!.inputEngine)
        assertEquals(C03VoiceEngine.CLOUD, settings.outputEngine)
        assertEquals("alloy", settings.cloudOutput.voiceID)
        assertEquals("p", settings.transcriptionProviderID)
        assertEquals(2, settings.schema)
    }

    @Test
    fun settingsCodecRejectsFutureSchemaSecretsAndBadRevision() {
        assertTrue(C03VoiceSettingsCodec.decode("""{"schema":3}""").unreadable)
        assertTrue(C03VoiceSettingsCodec.decode(
            """{"schema":1,"apiKey":"sk-secret"}""",
        ).unreadable)
        assertTrue(C03VoiceSettingsCodec.decode(
            """{"schema":1,"revision":-1}""",
        ).unreadable)
        assertTrue(C03VoiceSettingsCodec.decode("not-json").unreadable)
    }

    @Test
    fun settingsCodecRoundTripPreservesInputAndOutputChoices() {
        val source = C03VoiceSettings(
            inputEngine = C03VoiceEngine.CLOUD,
            outputEngine = C03VoiceEngine.CLOUD,
            cloudInput = C03CloudVoiceSelection("p", "m", language = "en"),
            cloudOutput = C03CloudVoiceSelection("p", "m", "alloy", "en", 1.25),
            transcriptionProviderID = "p",
            transcriptionModelID = "t",
        )
        val encoded = C03VoiceSettingsCodec.encode(source, revision = 7)
        val decoded = C03VoiceSettingsCodec.decode(encoded)
        assertFalse(decoded.unreadable)
        assertEquals(7L, decoded.document?.revision)
        assertEquals(C03VoiceEngine.CLOUD, decoded.document?.settings?.inputEngine)
        assertEquals("alloy", decoded.document?.settings?.cloudOutput?.voiceID)
        assertFalse(encoded.contains("apiKey", ignoreCase = true))
    }

    @Test
    fun failureWireRoundTripIsBoundedAndCodeTyped() {
        val failure = C03VoiceFailure(
            C03VoiceErrorCode.AUTHENTICATION,
            "providerAuth",
            retryable = false,
        )
        val wire = failure.toWire()
        val decoded = C03VoiceFailure.fromWire(wire)
        assertEquals(failure.code, decoded?.code)
        assertEquals(failure.reason, decoded?.reason)
        assertFalse(decoded?.retryable == true)
        assertEquals(
            "voiceCoreUnavailable",
            C03VoiceFailure.fromWire(
                C03Json.parse("""{"code":"coreUnavailable","reason":"voiceCoreUnavailable"}"""),
            )?.reason,
        )
    }
}
