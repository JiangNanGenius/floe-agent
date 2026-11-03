// SPDX-License-Identifier: MPL-2.0
//
// App-side client for the additive Swift `floe.voice/7` channel.
//
// No cloud credential/model URL/response body crosses this file. It sends only
// provider/model IDs, owner/project identity, text or a project asset ID, and
// receives bounded status/pages/paths. The Swift domain resolves the existing
// provider secret reference at call time.
package com.floe.android.host.voice

import com.floe.android.bridge.SwiftCore
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

fun interface C03VoiceTransport {
    fun exchange(request: String): String
}

object SwiftC03VoiceTransport : C03VoiceTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

enum class C03CloudOperationState {
    RUNNING,
    COMPLETED,
    FAILED,
    CANCELLED;

    companion object {
        fun fromWire(value: String?): C03CloudOperationState = when (value) {
            "running" -> RUNNING
            "completed" -> COMPLETED
            "failed" -> FAILED
            "cancelled" -> CANCELLED
            else -> FAILED
        }
    }
}

data class C03AsrStatus(
    val state: C03CloudOperationState,
    val progress: Double,
    val segmentCount: Int,
    val failure: C03VoiceFailure?,
)

data class C03SegmentPage(
    val segments: List<C03TimedSegment>,
    val nextOffset: Int,
    val total: Int,
)

data class C03TtsStatus(
    val state: C03CloudOperationState,
    val progress: Double,
    val audioPath: String?,
    val sampleRate: Int,
    val durationSeconds: Double?,
    val failure: C03VoiceFailure?,
)

data class C03SettingsLoadResult(
    val found: Boolean,
    val unreadable: Boolean,
    val revision: Long,
    val settings: C03VoiceSettings?,
)

data class C03SettingsSaveResult(
    val revision: Long,
    val settings: C03VoiceSettings,
)

/** One trusted long-media plan. Paths are internal native staging handles. */
data class C03TranscriptionPlan(
    val operationID: String,
    val sourcePath: String,
    val stagingPath: String,
    val sourceBytes: Long,
    val durationSeconds: Double,
    val chunkLimitBytes: Long,
    val estimatedChunks: Int,
)

/** One finite-microphone staging handle returned by the trusted bridge. */
data class C03UtteranceStaging(
    val pathToken: String,
    val path: String,
    val maxDurationSeconds: Int,
)

class C03CloudSpeechClient(
    private val transport: C03VoiceTransport = SwiftC03VoiceTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    /** Returns the installed channel version, or fails typed. */
    suspend fun handshake(): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "handshake")
                put("requestID", UUID.randomUUID().toString())
            },
        )
        return response.int("version") ?: VERSION
    }

    suspend fun capabilities(): C03VoiceCapabilities {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.capabilities")
                put("requestID", UUID.randomUUID().toString())
            },
        )
        return C03VoiceCapabilities(
            cloudReady = response.bool("cloudReady") == true,
            transportReady = response.bool("transportReady") == true,
            asrModels = parseModels(response.array("asrModels")),
            ttsModels = parseModels(response.array("ttsModels")),
            maxAudioBytes = response.long("maxAudioBytes")?.coerceIn(1L, 64L * 1024L * 1024L)
                ?: (25L * 1024L * 1024L),
            maxChunkBytes = response.long("maxChunkBytes")?.coerceIn(
                1L * 1024L * 1024L,
                24L * 1024L * 1024L,
            ) ?: (20L * 1024L * 1024L),
            maxSourceDurationSeconds = response.int("maxSourceDurationSeconds")
                ?.coerceIn(60, 24 * 60 * 60) ?: (12 * 60 * 60),
            maxTextCharacters = response.int("maxTextCharacters")?.coerceIn(1, 6_000) ?: 6_000,
            maxSegments = response.int("maxSegments")?.coerceIn(1, 5_000) ?: 2_000,
            ttsSampleRate = response.int("ttsSampleRate")?.coerceIn(8_000, 48_000) ?: 24_000,
            needsCoreUpdate = response.bool("needsCoreUpdate") == true,
        )
    }

    suspend fun loadSettings(epoch: Long?): C03SettingsLoadResult {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.settings.load")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
            },
        )
        val found = response.bool("found") == true
        val unreadable = response.bool("unreadable") == true
        val revision = (response.long("revision") ?: 0L).coerceAtLeast(0L)
        val settingsObject = response.obj("settings")
        val decoded = settingsObject?.let { C03VoiceSettingsCodec.decode(it.toString()) }
        return C03SettingsLoadResult(
            found = found,
            unreadable = unreadable || (settingsObject != null && decoded?.document == null),
            revision = revision,
            settings = decoded?.document?.settings,
        )
    }

    suspend fun saveSettings(
        settings: C03VoiceSettings,
        expectedRevision: Long,
        epoch: Long?,
    ): C03SettingsSaveResult {
        val document = C03Json.parse(C03VoiceSettingsCodec.encode(settings, expectedRevision))
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INTERNAL, "settingsEncodeFailed")
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.settings.save")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
                put("expectedRevision", expectedRevision.coerceAtLeast(0L))
                put("settings", document)
            },
        )
        val savedObject = response.obj("settings")
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingSettings")
        val decoded = C03VoiceSettingsCodec.decode(savedObject.toString())
            .document
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidSettings")
        return C03SettingsSaveResult(
            revision = (response.long("revision") ?: decoded.revision).coerceAtLeast(0L),
            settings = decoded.settings,
        )
    }

    /**
     * Validates the real G09 asset and creates bounded native staging. The
     * caller never supplies a media path; the bridge resolves it.
     */
    suspend fun planTranscription(
        media: C03MediaProjectContext,
        selection: C03CloudVoiceSelection,
        language: String?,
        owner: C03VoiceOwner,
        epoch: Long?,
    ): C03TranscriptionPlan {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.plan")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
                put("media", media.toWire())
                put("selection", selection.toWire())
                put("owner", owner.toWire())
                put("language", language)
            },
        )
        val operationID = response.string("operationID")?.boundedOperationID()
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingOperationID")
        val sourcePath = response.string("sourcePath")
            ?.takeIf { it.isNotBlank() && it.length <= 4_096 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingSourcePath")
        val stagingPath = response.string("stagingPath")
            ?.takeIf { it.isNotBlank() && it.length <= 4_096 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingStagingPath")
        return C03TranscriptionPlan(
            operationID = operationID,
            sourcePath = sourcePath,
            stagingPath = stagingPath,
            sourceBytes = (response.long("sourceBytes") ?: 0L).coerceAtLeast(0L),
            durationSeconds = (response.double("durationSeconds") ?: 0.0)
                .coerceIn(0.0, 24.0 * 60.0 * 60.0),
            chunkLimitBytes = (response.long("chunkLimitBytes")
                ?: (20L * 1024L * 1024L)).coerceIn(1L * 1024L * 1024L, 24L * 1024L * 1024L),
            estimatedChunks = (response.int("estimatedChunks") ?: 1)
                .coerceIn(1, C03ChunkBudget.MAX_CHUNKS),
        )
    }

    suspend fun applyChunk(
        operationID: String,
        chunkIndex: Int,
        sourceStartSeconds: Double,
        sourceDurationSeconds: Double,
        sampleRate: Int,
        channels: Int,
    ): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.chunk")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
                put("chunkIndex", chunkIndex.coerceAtLeast(0))
                put("sourceStart", sourceStartSeconds)
                put("sourceDuration", sourceDurationSeconds)
                put("sampleRate", sampleRate)
                put("channels", channels)
            },
        )
        return (response.int("segmentCount") ?: 0).coerceIn(0, 5_000)
    }

    suspend fun finishTranscription(
        operationID: String,
        totalChunks: Int,
        sourceDurationSeconds: Double,
    ): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.finish")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
                put("totalChunks", totalChunks.coerceAtLeast(0))
                put("sourceDuration", sourceDurationSeconds)
            },
        )
        return (response.int("segmentCount") ?: 0).coerceIn(0, 5_000)
    }

    suspend fun beginUtterance(owner: C03VoiceOwner, epoch: Long?): C03UtteranceStaging {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.utterance.begin")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
                put("owner", owner.toWire())
            },
        )
        val token = response.string("pathToken")
            ?.takeIf { it.isNotBlank() && it.length <= 128 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingPathToken")
        val path = response.string("path")
            ?.takeIf { it.isNotBlank() && it.length <= 4_096 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingUtterancePath")
        return C03UtteranceStaging(
            pathToken = token,
            path = path,
            maxDurationSeconds = (response.int("maxDurationSeconds") ?: 60)
                .coerceIn(5, 60),
        )
    }

    suspend fun startUtterance(
        staging: C03UtteranceStaging,
        selection: C03CloudVoiceSelection,
        language: String?,
        owner: C03VoiceOwner,
        epoch: Long?,
    ): String {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.utterance.start")
                put("requestID", UUID.randomUUID().toString())
                put("epoch", epoch)
                put("pathToken", staging.pathToken)
                put("path", staging.path)
                put("selection", selection.toWire())
                put("owner", owner.toWire())
                put("language", language)
            },
        )
        return response.string("operationID")?.boundedOperationID()
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingOperationID")
    }

    suspend fun transcriptionText(operationID: String): String {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.text")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
            },
        )
        return response.string("text")?.take(8_000).orEmpty()
    }

    suspend fun startTranscription(
        media: C03MediaProjectContext,
        selection: C03CloudVoiceSelection,
        language: String?,
        owner: C03VoiceOwner,
    ): String {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.start")
                put("requestID", UUID.randomUUID().toString())
                put("media", media.toWire())
                put("selection", selection.toWire())
                put("owner", owner.toWire())
                put("language", language)
            },
        )
        return response.string("operationID")
            ?.takeIf { it.isNotBlank() && it.length <= 128 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingOperationID")
    }

    suspend fun transcriptionStatus(operationID: String): C03AsrStatus {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.status")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
            },
        )
        return C03AsrStatus(
            state = C03CloudOperationState.fromWire(response.string("state")),
            progress = (response.double("progress") ?: 0.0).coerceIn(0.0, 1.0),
            segmentCount = (response.int("segmentCount") ?: 0).coerceIn(0, 5_000),
            failure = C03VoiceFailure.fromWire(response.obj("failure")),
        )
    }

    suspend fun transcriptionPage(
        operationID: String,
        offset: Int,
        limit: Int,
    ): C03SegmentPage {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.page")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
                put("offset", offset.coerceAtLeast(0))
                put("limit", limit.coerceIn(1, 200))
            },
        )
        val segments = response.array("segments")?.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            C03TimedSegment(
                start = item.double("start") ?: return@mapNotNull null,
                end = item.double("end") ?: return@mapNotNull null,
                text = item.string("text") ?: return@mapNotNull null,
            ).normalized()
        }.orEmpty()
        return C03SegmentPage(
            segments = segments,
            nextOffset = (response.int("nextOffset") ?: (offset + segments.size))
                .coerceAtLeast(offset),
            total = (response.int("total") ?: (offset + segments.size))
                .coerceAtLeast(offset + segments.size),
        )
    }

    suspend fun cancelTranscription(operationID: String) {
        call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.asr.cancel")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
            },
        )
    }

    suspend fun writeSubtitles(
        operationID: String,
        media: C03MediaProjectContext,
        expectedRevision: Long,
        replaceTranscribed: Boolean,
    ): C03SubtitleReceipt {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.subtitle.write")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
                put("media", media.toWire())
                put("expectedRevision", expectedRevision)
                put("mode", if (replaceTranscribed) "replaceTranscription" else "append")
                put("opID", UUID.randomUUID().toString())
            },
        )
        val receipt = response.obj("receipt")
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingReceipt")
        return C03SubtitleReceipt(
            projectID = receipt.string("projectID").orEmpty(),
            revision = receipt.long("revision") ?: -1L,
            canUndo = receipt.bool("canUndo") == true,
            canRedo = receipt.bool("canRedo") == true,
            operationID = receipt.string("opID").orEmpty(),
            idempotent = receipt.bool("idempotent") == true,
        )
    }

    suspend fun startSynthesis(
        text: String,
        selection: C03CloudVoiceSelection,
        owner: C03VoiceOwner,
    ): String {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.tts.start")
                put("requestID", UUID.randomUUID().toString())
                put("selection", selection.toWire())
                put("owner", owner.toWire())
                put("text", text)
            },
        )
        return response.string("operationID")
            ?.takeIf { it.isNotBlank() && it.length <= 128 }
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingOperationID")
    }

    suspend fun synthesisStatus(operationID: String): C03TtsStatus {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.tts.status")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
            },
        )
        return C03TtsStatus(
            state = C03CloudOperationState.fromWire(response.string("state")),
            progress = (response.double("progress") ?: 0.0).coerceIn(0.0, 1.0),
            audioPath = response.string("audioPath"),
            sampleRate = response.int("sampleRate")?.coerceIn(8_000, 48_000) ?: 24_000,
            durationSeconds = response.double("durationSeconds"),
            failure = C03VoiceFailure.fromWire(response.obj("failure")),
        )
    }

    suspend fun cancelSynthesis(operationID: String) {
        call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c03.tts.cancel")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID)
            },
        )
    }

    suspend fun releaseSynthesis(operationID: String) {
        runCatching {
            call(
                buildJsonObject {
                    put("version", VERSION)
                    put("operation", "c03.tts.release")
                    put("requestID", UUID.randomUUID().toString())
                    put("operationID", operationID)
                },
            )
        }
    }

    /**
     * Requests cancellation of every native voice operation and waits for the
     * native actor's real task settlement. Returns `true` only when the
     * bounded bridge call confirmed the drain; `false` keeps the caller's
     * root-generation drain pending so it can retry instead of retiring a
     * root while owned provider work is still live.
     */
    suspend fun cancelAll(): Boolean {
        return try {
            call(
                buildJsonObject {
                    put("version", VERSION)
                    put("operation", "c03.cancelAll")
                    put("requestID", UUID.randomUUID().toString())
                },
            )
            true
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: C03VoiceFailure) {
            // No v7 channel / an older bridge cannot own a v7 operation, so
            // there is nothing to drain. Every other typed failure is an
            // honest pending result for the caller.
            failure.code == C03VoiceErrorCode.NEEDS_CORE_UPDATE ||
                (failure.code == C03VoiceErrorCode.INVALID_SELECTION &&
                    failure.reason == "unsupportedOperation")
        } catch (_: Throwable) {
            false
        }
    }

    private suspend fun call(request: JsonObject): JsonObject {
        val raw = try {
            withContext(ioDispatcher) {
                transport.exchange(request.toString())
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            throw C03VoiceFailure(
                C03VoiceErrorCode.CORE_UNAVAILABLE,
                "voiceCoreUnavailable",
                retryable = true,
            )
        }
        val response = C03Json.parse(raw)
            ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "invalidJSON")
        if (response.bool("ok") != true) {
            throw typedFailure(response)
        }
        return response
    }

    private fun typedFailure(response: JsonObject): C03VoiceFailure {
        val codeRaw = response.string("error") ?: response.string("code")
        val reason = response.string("reason")?.take(120)
        val error = when (codeRaw) {
            "unsupportedVersion" -> C03VoiceErrorCode.NEEDS_CORE_UPDATE
            "runtimeUnavailable", "voiceUnavailable" -> C03VoiceErrorCode.CORE_UNAVAILABLE
            "unconfigured" -> C03VoiceErrorCode.UNCONFIGURED
            "credentialMissing" -> C03VoiceErrorCode.CREDENTIAL_MISSING
            "transportUnavailable" -> C03VoiceErrorCode.TRANSPORT_UNAVAILABLE
            "unsupportedModel" -> C03VoiceErrorCode.UNSUPPORTED_MODEL
            "authentication" -> C03VoiceErrorCode.AUTHENTICATION
            "quotaOrRateLimited" -> C03VoiceErrorCode.QUOTA_OR_RATE_LIMITED
            "cancelled" -> C03VoiceErrorCode.CANCELLED
            "fileTooLarge" -> C03VoiceErrorCode.FILE_TOO_LARGE
            "fileUnreadable" -> C03VoiceErrorCode.FILE_UNREADABLE
            "unsupportedMedia" -> C03VoiceErrorCode.UNSUPPORTED_MEDIA
            "codecUnavailable" -> C03VoiceErrorCode.CODEC_UNAVAILABLE
            "needsTiming" -> C03VoiceErrorCode.NEEDS_TIMING
            "revisionConflict", "staleRevision" -> C03VoiceErrorCode.STALE_REVISION
            "sessionRequired", "staleSession" -> C03VoiceErrorCode.SESSION_REQUIRED
            "projectNotFound" -> C03VoiceErrorCode.PROJECT_NOT_FOUND
            "mediaUnavailable" -> C03VoiceErrorCode.MEDIA_UNAVAILABLE
            "writeFailed" -> C03VoiceErrorCode.WRITE_FAILED
            "timeout" -> C03VoiceErrorCode.TIMEOUT
            "busy" -> C03VoiceErrorCode.BUSY
            "emptyTranscript" -> C03VoiceErrorCode.EMPTY_TRANSCRIPT
            "providerRejected" -> C03VoiceErrorCode.PROVIDER_REJECTED
            else -> C03VoiceErrorCode.INTERNAL
        }
        return C03VoiceFailure(
            error,
            reason ?: codeRaw?.take(80),
            retryable = response.bool("retryable") == true,
        )
    }

    private fun parseModels(array: JsonArray?): List<C03CloudModelChoice> =
        array?.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            C03CloudModelChoice(
                providerID = item.string("providerID") ?: return@mapNotNull null,
                providerName = item.string("providerName").orEmpty().take(120),
                modelID = item.string("modelID") ?: return@mapNotNull null,
                remoteModelID = item.string("remoteModelID").orEmpty().take(200),
                displayName = item.string("displayName").orEmpty().take(200),
                likelyASR = item.bool("likelyASR") == true,
                likelyTTS = item.bool("likelyTTS") == true,
                credentialConfigured = item.bool("credentialConfigured") == true,
            )
        }
            ?.take(100)
            .orEmpty()

    private fun C03CloudVoiceSelection.toWire(): JsonObject = buildJsonObject {
        put("engine", C03VoiceEngine.CLOUD.wire)
        put("providerID", providerID)
        put("modelID", modelID)
        put("voiceID", voiceID)
        put("language", language)
        put("rate", rate)
    }

    private fun JsonObject.int(key: String): Int? = C03Json.int(this[key])
    private fun JsonObject.long(key: String): Long? = C03Json.long(this[key])
    private fun JsonObject.double(key: String): Double? = C03Json.double(this[key])
    private fun JsonObject.bool(key: String): Boolean? = C03Json.bool(this[key])
    private fun JsonObject.string(key: String): String? = C03Json.string(this[key])
    private fun JsonObject.array(key: String): JsonArray? = C03Json.array(this[key])
    private fun JsonObject.obj(key: String): JsonObject? = C03Json.objectValue(this[key])

    companion object {
        const val VERSION = 7
    }
}

private fun String.boundedOperationID(): String? =
    trim().takeIf { it.isNotEmpty() && it.length <= 128 }
