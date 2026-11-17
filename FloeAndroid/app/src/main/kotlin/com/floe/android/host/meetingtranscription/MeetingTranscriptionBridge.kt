// SPDX-License-Identifier: MPL-2.0
//
// Minimal client for the additive Swift `floe.voice/7` meeting ASR operations.
//
// This file never receives a provider credential, endpoint URL or response
// body. It sends only canonical meeting/material IDs, bounded chunk timing and
// the selected provider/model IDs already stored in the canonical voice
// settings. The Swift domain resolves the existing provider secret reference
// at call time.
package com.floe.android.host.meetingtranscription

import com.floe.android.host.voice.C03CloudSpeechClient
import com.floe.android.host.voice.C03CloudVoiceSelection
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import com.floe.android.host.voice.C03VoiceTransport
import com.floe.android.host.voice.SwiftC03VoiceTransport
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal data class MeetingTranscriptionConfiguration(
    val selection: C03CloudVoiceSelection,
    val language: String?,
    val providerName: String,
)

internal data class MeetingTranscriptionCloudPlan(
    val operationId: String,
    val stagingPath: String,
    val chunkLimitBytes: Long,
    val estimatedChunks: Int,
    val sourceBytes: Long,
    val durationSeconds: Double,
)

internal data class MeetingTranscriptionPage(
    val segments: List<C03TimedSegment>,
    val total: Int,
)

/**
 * The exact cloud surface the meeting owner needs. It has no access to a G09
 * media project, a task owner or a 60-second utterance staging path.
 */
internal interface MeetingTranscriptionBackend {
    suspend fun configuration(epoch: Long): MeetingTranscriptionConfiguration

    suspend fun plan(
        epoch: Long,
        meetingId: String,
        materialId: String,
        sourceBytes: Long,
        durationSeconds: Double,
        configuration: MeetingTranscriptionConfiguration,
    ): MeetingTranscriptionCloudPlan

    suspend fun applyChunk(
        meetingId: String,
        materialId: String,
        operationId: String,
        chunkIndex: Int,
        sourceStartSeconds: Double,
        sourceDurationSeconds: Double,
        sampleRate: Int,
        channels: Int,
    ): Int

    suspend fun finish(
        meetingId: String,
        materialId: String,
        operationId: String,
        totalChunks: Int,
        sourceDurationSeconds: Double,
    ): Int

    suspend fun page(
        meetingId: String,
        materialId: String,
        operationId: String,
        offset: Int,
        limit: Int,
    ): MeetingTranscriptionPage

    suspend fun cancel(
        meetingId: String,
        materialId: String,
        operationId: String,
    )
}

internal class SwiftMeetingTranscriptionBackend(
    private val transport: C03VoiceTransport = SwiftC03VoiceTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : MeetingTranscriptionBackend {
    private val speech = C03CloudSpeechClient(transport, ioDispatcher)
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = false
        explicitNulls = false
    }

    override suspend fun configuration(epoch: Long): MeetingTranscriptionConfiguration {
        val loaded = speech.loadSettings(epoch)
        if (loaded.unreadable) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.UNCONFIGURED,
                "transcriptionSettingsUnreadable",
            )
        }
        val settings = loaded.settings ?: throw C03VoiceFailure(
            C03VoiceErrorCode.UNCONFIGURED,
            "transcriptionNotConfigured",
        )
        val normalized = settings.normalized()
        if (!normalized.transcriptionConfigured) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.UNCONFIGURED,
                "transcriptionNotConfigured",
            )
        }
        val capabilities = speech.capabilities()
        if (!capabilities.transportReady) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.TRANSPORT_UNAVAILABLE,
                "cloudTransportNotAdmitted",
                retryable = true,
            )
        }
        val selection = C03CloudVoiceSelection(
            providerID = normalized.transcriptionProviderID,
            modelID = normalized.transcriptionModelID,
            language = normalized.transcriptionLanguage,
        ).normalized()
        val choice = capabilities.choiceFor(selection) ?: throw C03VoiceFailure(
            C03VoiceErrorCode.UNSUPPORTED_MODEL,
            "transcriptionModelUnavailable",
        )
        if (!choice.credentialConfigured) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.CREDENTIAL_MISSING,
                "transcriptionCredentialMissing",
            )
        }
        return MeetingTranscriptionConfiguration(
            selection = selection,
            language = normalized.transcriptionLanguage,
            providerName = choice.providerName,
        )
    }

    override suspend fun plan(
        epoch: Long,
        meetingId: String,
        materialId: String,
        sourceBytes: Long,
        durationSeconds: Double,
        configuration: MeetingTranscriptionConfiguration,
    ): MeetingTranscriptionCloudPlan {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.meeting.asr.plan")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
                put("meetingID", meetingId)
                put("materialID", materialId)
                put("sourceBytes", sourceBytes)
                put("durationSeconds", durationSeconds)
                put("selection", configuration.selection.toWire())
                configuration.language?.let { put("language", it) }
            },
        )
        val operationId = response.string("operationID")
            ?.takeIf { it.isNotBlank() && it.length <= 128 }
            ?: throw C03VoiceFailure(
                C03VoiceErrorCode.INVALID_RESPONSE,
                "missingOperationID",
            )
        val stagingPath = response.string("stagingPath")
            ?.takeIf { it.isNotBlank() && it.length <= 4_096 }
            ?: throw C03VoiceFailure(
                C03VoiceErrorCode.INVALID_RESPONSE,
                "missingStagingPath",
            )
        return MeetingTranscriptionCloudPlan(
            operationId = operationId,
            stagingPath = stagingPath,
            chunkLimitBytes = (response.long("chunkLimitBytes")
                ?: DEFAULT_CHUNK_BYTES).coerceIn(MIN_CHUNK_BYTES, MAX_CHUNK_BYTES),
            estimatedChunks = (response.int("estimatedChunks") ?: 1).coerceIn(1, 512),
            sourceBytes = (response.long("sourceBytes") ?: sourceBytes)
                .coerceIn(1L, 8L * 1024L * 1024L * 1024L),
            durationSeconds = (response.double("durationSeconds") ?: durationSeconds)
                .coerceIn(0.001, 12.0 * 60.0 * 60.0),
        )
    }

    override suspend fun applyChunk(
        meetingId: String,
        materialId: String,
        operationId: String,
        chunkIndex: Int,
        sourceStartSeconds: Double,
        sourceDurationSeconds: Double,
        sampleRate: Int,
        channels: Int,
    ): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.meeting.asr.chunk")
                put("requestID", UUID.randomUUID().toString())
                put("meetingID", meetingId)
                put("materialID", materialId)
                put("operationID", operationId)
                put("chunkIndex", chunkIndex)
                put("sourceStart", sourceStartSeconds)
                put("sourceDuration", sourceDurationSeconds)
                put("sampleRate", sampleRate)
                put("channels", channels)
            },
        )
        return (response.int("segmentCount") ?: 0).coerceIn(0, 5_000)
    }

    override suspend fun finish(
        meetingId: String,
        materialId: String,
        operationId: String,
        totalChunks: Int,
        sourceDurationSeconds: Double,
    ): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.meeting.asr.finish")
                put("requestID", UUID.randomUUID().toString())
                put("meetingID", meetingId)
                put("materialID", materialId)
                put("operationID", operationId)
                put("totalChunks", totalChunks)
                put("sourceDuration", sourceDurationSeconds)
            },
        )
        return (response.int("segmentCount") ?: 0).coerceIn(0, 5_000)
    }

    override suspend fun page(
        meetingId: String,
        materialId: String,
        operationId: String,
        offset: Int,
        limit: Int,
    ): MeetingTranscriptionPage {
        if (offset < 0 || limit <= 0 || limit > MAX_PAGE_LIMIT) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidPageBounds")
        }
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.meeting.asr.page")
                put("requestID", UUID.randomUUID().toString())
                put("meetingID", meetingId)
                put("materialID", materialId)
                put("operationID", operationId)
                put("offset", offset)
                put("limit", limit)
            },
        )
        return decodePage(response, offset, limit)
    }

    /**
     * Strictly decodes one page. Every field is required at its exact wire
     * type; a malformed segment, a dropped element, an inconsistent cursor or
     * an empty page before the reported total is a typed failure, never a
     * partial page. The manager must never commit from a silently truncated
     * read.
     */
    private fun decodePage(
        response: JsonObject,
        offset: Int,
        limit: Int,
    ): MeetingTranscriptionPage {
        if (offset < 0 || limit <= 0 || limit > MAX_PAGE_LIMIT) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidPageBounds")
        }
        val rawSegments = response.array("segments")
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingSegments")
        val total = response.strictInt("total")
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingTotal")
        if (total < 0 || offset > total) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidPageBounds")
        }
        val nextOffset = response.strictInt("nextOffset")
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingNextOffset")
        if (rawSegments.size > limit) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "pageTooLarge")
        }
        val segments = ArrayList<C03TimedSegment>(rawSegments.size)
        for (element in rawSegments) {
            val item = element as? JsonObject
                ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSegment")
            val start = item.strictDouble("start")
                ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSegmentTiming")
            val end = item.strictDouble("end")
                ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSegmentTiming")
            val text = item.strictString("text")
                ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSegmentText")
            val normalized = C03TimedSegment(start, end, text).normalized()
                ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSegment")
            segments.add(normalized)
        }
        val endOffset = offset.toLong() + segments.size.toLong()
        if (segments.isEmpty() && offset < total) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "emptyPageBeforeTotal")
        }
        if (nextOffset.toLong() != endOffset || endOffset > total.toLong()) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidNextOffset")
        }
        return MeetingTranscriptionPage(segments = segments, total = total)
    }

    override suspend fun cancel(
        meetingId: String,
        materialId: String,
        operationId: String,
    ) {
        call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.meeting.asr.cancel")
                put("requestID", UUID.randomUUID().toString())
                put("meetingID", meetingId)
                put("materialID", materialId)
                put("operationID", operationId)
            },
        )
    }

    private suspend fun call(request: JsonObject): JsonObject {
        val raw = try {
            withContext(ioDispatcher) { transport.exchange(request.toString()) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.CORE_UNAVAILABLE,
                "voiceCoreUnavailable",
                retryable = true,
            )
        }
        val response = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw C03VoiceFailure(
            C03VoiceErrorCode.INVALID_RESPONSE,
            "invalidJSON",
        )
        if (response.bool("ok") != true) throw typedFailure(response)
        return response
    }

    private fun typedFailure(response: JsonObject): C03VoiceFailure {
        val codeRaw = response.string("error") ?: response.string("code")
        if (codeRaw == "invalidSelection" &&
            response.string("reason") == "unsupportedOperation"
        ) {
            // The installed native core predates the meeting ASR operations.
            // This is an update requirement, not a bad meeting identity.
            return C03VoiceFailure(
                C03VoiceErrorCode.NEEDS_CORE_UPDATE,
                "meetingVoiceOperationsUnavailable",
                retryable = false,
            )
        }
        val direct = when (codeRaw) {
            "unsupportedVersion" -> C03VoiceErrorCode.NEEDS_CORE_UPDATE
            "runtimeUnavailable", "voiceUnavailable" -> C03VoiceErrorCode.CORE_UNAVAILABLE
            else -> null
        }
        if (direct != null) {
            return C03VoiceFailure(
                direct,
                response.string("reason")?.take(120),
                retryable = response.bool("retryable") == true,
            )
        }
        val mapped = C03VoiceFailure.fromWire(
            buildJsonObject {
                put("code", JsonPrimitive(codeRaw ?: "internal"))
                response.string("reason")?.let { put("reason", JsonPrimitive(it.take(120))) }
                put("retryable", JsonPrimitive(response.bool("retryable") == true))
            },
        )
        return mapped ?: C03VoiceFailure(
            C03VoiceErrorCode.INTERNAL,
            "voiceResponseInvalid",
        )
    }

    private fun C03CloudVoiceSelection.toWire(): JsonObject = buildJsonObject {
        put("engine", "cloud")
        put("providerID", providerID)
        put("modelID", modelID)
        put("voiceID", voiceID)
        put("language", language)
        put("rate", rate)
    }

    private fun JsonObject.string(key: String): String? {
        val element = this[key] ?: return null
        if (element is JsonNull) return null
        return (element as? JsonPrimitive)?.contentOrNull
    }

    private fun JsonObject.strictString(key: String): String? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        if (primitive is JsonNull || !primitive.isString) return null
        return primitive.content
    }

    private fun JsonObject.strictInt(key: String): Int? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        if (primitive is JsonNull || primitive.isString) return null
        return primitive.intOrNull
    }

    private fun JsonObject.strictDouble(key: String): Double? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        if (primitive is JsonNull || primitive.isString) return null
        return primitive.doubleOrNull
    }

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.doubleOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray

    companion object {
        private const val VERSION = 7
        private const val MIN_CHUNK_BYTES = 1L * 1024L * 1024L
        private const val MAX_CHUNK_BYTES = 24L * 1024L * 1024L
        private const val DEFAULT_CHUNK_BYTES = 20L * 1024L * 1024L

        /** Matches the native page clamp: one response never exceeds 200 rows. */
        private const val MAX_PAGE_LIMIT = 200
    }
}
