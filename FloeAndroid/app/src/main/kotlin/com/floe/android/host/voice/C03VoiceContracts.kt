// SPDX-License-Identifier: MPL-2.0
//
// C03 voice contracts — immutable, secret-free values shared by the App host,
// the system recognizer/TTS adapters and the Swift `floe.voice/7` client.
//
// This file contains no Android framework call and no network code. The
// persisted selection never carries a credential, endpoint password or raw
// provider response: cloud credentials stay in the existing provider secret
// reference resolved natively by the Swift domain.
package com.floe.android.host.voice

import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/** The only two product speech engines. `.system` is the default. */
enum class C03VoiceEngine(val wire: String) {
    SYSTEM("system"),
    CLOUD("cloud");

    companion object {
        fun fromWire(value: String?): C03VoiceEngine =
            entries.firstOrNull { it.wire == value } ?: SYSTEM
    }
}

/** One persisted, non-secret cloud speech route selection. */
data class C03CloudVoiceSelection(
    val providerID: String? = null,
    val modelID: String? = null,
    val voiceID: String = "",
    val language: String? = null,
    val rate: Double = 1.0,
) {
    val configured: Boolean
        get() = !providerID.isNullOrBlank() && !modelID.isNullOrBlank()

    fun normalized(): C03CloudVoiceSelection = copy(
        providerID = providerID?.trim()?.takeIf { it.isNotEmpty() },
        modelID = modelID?.trim()?.takeIf { it.isNotEmpty() },
        voiceID = voiceID.trim().take(200),
        language = language?.trim()?.takeIf { it.isNotEmpty() }?.take(64),
        rate = if (rate.isFinite()) rate.coerceIn(0.5, 2.0) else 1.0,
    )
}

/**
 * Persisted voice settings. This is deliberately a non-secret document:
 * provider/model IDs are ordinary configuration references, never keys.
 */
data class C03VoiceSettings(
    val schema: Int = CURRENT_SCHEMA,
    val inputLanguage: String? = null,
    /** Short interactive recognition engine. System is the first-use default. */
    val inputEngine: C03VoiceEngine = C03VoiceEngine.SYSTEM,
    val outputEngine: C03VoiceEngine = C03VoiceEngine.SYSTEM,
    val systemVoiceName: String? = null,
    val systemVoiceLocale: String? = null,
    val rate: Double = 1.0,
    val pitch: Double = 0.0,
    /** Cloud model used only by the finite interactive microphone. */
    val cloudInput: C03CloudVoiceSelection = C03CloudVoiceSelection(),
    val cloudOutput: C03CloudVoiceSelection = C03CloudVoiceSelection(),
    val transcriptionProviderID: String? = null,
    val transcriptionModelID: String? = null,
    val transcriptionLanguage: String? = null,
    val replaceTranscribedCaptions: Boolean = true,
) {
    fun normalized(): C03VoiceSettings = copy(
        schema = CURRENT_SCHEMA,
        inputLanguage = inputLanguage?.trim()?.takeIf { it.isNotEmpty() }?.take(64),
        inputEngine = inputEngine,
        outputEngine = outputEngine,
        systemVoiceName = systemVoiceName?.trim()?.takeIf { it.isNotEmpty() }?.take(200),
        systemVoiceLocale = systemVoiceLocale?.trim()?.takeIf { it.isNotEmpty() }?.take(64),
        rate = if (rate.isFinite()) rate.coerceIn(0.5, 2.0) else 1.0,
        pitch = if (pitch.isFinite()) pitch.coerceIn(-6.0, 6.0) else 0.0,
        cloudInput = cloudInput.normalized(),
        cloudOutput = cloudOutput.normalized().copy(
            rate = if (rate.isFinite()) rate.coerceIn(0.5, 2.0) else 1.0,
        ),
        transcriptionProviderID = transcriptionProviderID
            ?.trim()?.takeIf { it.isNotEmpty() },
        transcriptionModelID = transcriptionModelID
            ?.trim()?.takeIf { it.isNotEmpty() },
        transcriptionLanguage = transcriptionLanguage
            ?.trim()?.takeIf { it.isNotEmpty() }?.take(64),
    )

    val transcriptionConfigured: Boolean
        get() = !transcriptionProviderID.isNullOrBlank() &&
            !transcriptionModelID.isNullOrBlank()

    val cloudInputConfigured: Boolean get() = cloudInput.configured

    companion object {
        /** Schema 2 adds `inputEngine` + `cloudInput`; schema 1 is read-only-adopted. */
        const val CURRENT_SCHEMA = 2
        val DEFAULT = C03VoiceSettings()
    }
}

/** One resolved cloud model offered by the existing configured providers. */
data class C03CloudModelChoice(
    val providerID: String,
    val providerName: String,
    val modelID: String,
    val remoteModelID: String,
    val displayName: String,
    val likelyASR: Boolean,
    val likelyTTS: Boolean,
    val credentialConfigured: Boolean,
) {
    val key: String get() = "$providerID|$modelID"
}

/** Non-secret capability snapshot. Cloud entries are real configured models. */
data class C03VoiceCapabilities(
    val cloudReady: Boolean = false,
    val transportReady: Boolean = false,
    val asrModels: List<C03CloudModelChoice> = emptyList(),
    val ttsModels: List<C03CloudModelChoice> = emptyList(),
    /** Hard ceiling for ONE provider upload; long media is split below it. */
    val maxAudioBytes: Long = 25L * 1024L * 1024L,
    /** Decoded PCM16 WAV chunk ceiling used by the native chunker. */
    val maxChunkBytes: Long = 20L * 1024L * 1024L,
    val maxSourceDurationSeconds: Int = 12 * 60 * 60,
    val maxTextCharacters: Int = 6_000,
    val maxSegments: Int = 2_000,
    val ttsSampleRate: Int = 24_000,
    val needsCoreUpdate: Boolean = false,
) {
    fun choiceFor(selection: C03CloudVoiceSelection): C03CloudModelChoice? =
        (asrModels + ttsModels).firstOrNull {
            it.providerID == selection.providerID && it.modelID == selection.modelID
        }
}

/** One system TTS voice exposed by the installed engine (no download). */
data class C03SystemVoice(
    val name: String,
    val locale: String,
    val displayName: String,
    val requiresNetwork: Boolean?,
)

enum class C03TtsAvailability {
    UNINITIALIZED,
    READY,
    SERVICE_MISSING,
    INIT_FAILED,
    MISSING_VOICE,
    UNCONFIGURED,
    FAILURE,
}

/** Typed, bounded failure vocabulary. Provider text and URLs never enter it. */
enum class C03VoiceErrorCode(val wire: String) {
    UNCONFIGURED("unconfigured"),
    CREDENTIAL_MISSING("credentialMissing"),
    TRANSPORT_UNAVAILABLE("transportUnavailable"),
    UNSUPPORTED_MODEL("unsupportedModel"),
    PROVIDER_REJECTED("providerRejected"),
    AUTHENTICATION("authentication"),
    QUOTA_OR_RATE_LIMITED("quotaOrRateLimited"),
    NETWORK("network"),
    CANCELLED("cancelled"),
    INVALID_SELECTION("invalidSelection"),
    FILE_TOO_LARGE("fileTooLarge"),
    FILE_UNREADABLE("fileUnreadable"),
    UNSUPPORTED_MEDIA("unsupportedMedia"),
    /** The device has no real decoder for this source audio track. */
    CODEC_UNAVAILABLE("codecUnavailable"),
    /** The provider returned text without real segment timing. */
    NEEDS_TIMING("needsTiming"),
    STALE_REVISION("staleRevision"),
    SESSION_REQUIRED("sessionRequired"),
    PROJECT_NOT_FOUND("projectNotFound"),
    MEDIA_UNAVAILABLE("mediaUnavailable"),
    WRITE_FAILED("writeFailed"),
    TIMEOUT("timeout"),
    BUSY("busy"),
    INVALID_RESPONSE("invalidResponse"),
    EMPTY_TRANSCRIPT("emptyTranscript"),
    PERMISSION_REQUIRED("permissionRequired"),
    CORE_UNAVAILABLE("coreUnavailable"),
    NEEDS_CORE_UPDATE("needsCoreUpdate"),
    INTERNAL("internal"),
}

data class C03VoiceFailure(
    val code: C03VoiceErrorCode,
    val reason: String? = null,
    val retryable: Boolean = false,
) : Exception("$code${reason?.let { ":$it" } ?: ""}") {
    /** A bounded code/reason map safe for diagnostics and UI. */
    fun toWire(): JsonObject = buildJsonObject {
        put("code", code.wire)
        reason?.let { put("reason", it.take(120)) }
        put("retryable", retryable)
    }

    companion object {
        fun fromWire(value: JsonObject?): C03VoiceFailure? {
            if (value == null) return null
            val raw = value.string("code") ?: return null
            val code = C03VoiceErrorCode.entries.firstOrNull { it.wire == raw }
                ?: C03VoiceErrorCode.INTERNAL
            return C03VoiceFailure(
                code,
                value.string("reason")?.take(120),
                value.bool("retryable") == true,
            )
        }
    }
}

/** One provider-timed transcript segment in the source media timeline. */
data class C03TimedSegment(
    val start: Double,
    val end: Double,
    val text: String,
) {
    fun normalized(): C03TimedSegment? {
        if (!start.isFinite() || !end.isFinite()) return null
        if (start < 0.0 || end <= start) return null
        if (end - start > 24.0 * 60.0 * 60.0) return null
        val clean = text.trim().replace(Regex("\\s+"), " ")
        if (clean.isEmpty() || clean.length > 2_000) return null
        return C03TimedSegment(start, end, clean)
    }
}

data class C03Transcript(
    val segments: List<C03TimedSegment>,
    val language: String?,
    val providerName: String,
    val modelDisplayName: String,
)

/** Owner identity propagated with every interactive/read-aloud request. */
data class C03VoiceOwner(
    val conversationID: String? = null,
    val taskID: String? = null,
    val environmentID: String? = null,
    val projectID: String? = null,
    /** True only for the RAM temporary conversation. Cloud mic is refused. */
    val temporary: Boolean = false,
) {
    fun toWire(): JsonObject = buildJsonObject {
        conversationID?.takeIf { it.isNotBlank() }?.let { put("conversationID", it) }
        taskID?.takeIf { it.isNotBlank() }?.let { put("taskID", it) }
        environmentID?.takeIf { it.isNotBlank() }?.let { put("environmentID", it) }
        projectID?.takeIf { it.isNotBlank() }?.let { put("projectID", it) }
        if (temporary) put("temporary", true)
    }
}

/** Explicit media-project context. Paths and file URLs are never accepted. */
data class C03MediaProjectContext(
    val projectID: String,
    val sessionToken: String,
    val storageKind: String,
    val workspaceID: String?,
    val originKind: String?,
    val originOwnerID: String?,
    val originEnvironmentID: String?,
    val expectedRevision: Long,
    val assetID: String,
) {
    fun toWire(): JsonObject = buildJsonObject {
        put("projectID", projectID)
        put("sessionToken", sessionToken)
        put("storage", buildJsonObject {
            put("kind", storageKind)
            workspaceID?.let { put("workspaceID", it) }
        })
        if (!originKind.isNullOrBlank()) {
            put("origin", buildJsonObject {
                put("kind", originKind)
                originOwnerID?.let { put("ownerID", it) }
                originEnvironmentID?.let { put("environmentID", it) }
            })
        }
        put("expectedRevision", expectedRevision)
        put("assetID", assetID)
    }
}

data class C03SubtitleReceipt(
    val projectID: String,
    val revision: Long,
    val canUndo: Boolean,
    val canRedo: Boolean,
    val operationID: String,
    val idempotent: Boolean,
)

/** Live dictation state. `COMPLETED` is only emitted with real final text. */
enum class C03DictationState {
    IDLE,
    PERMISSION_REQUIRED,
    LISTENING,
    FINALIZING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

/** Read-aloud state. `COMPLETED` requires the adapter/player terminal callback. */
enum class C03SpeechOutputState {
    IDLE,
    PREPARING,
    SPEAKING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

/** Long media-transcription state. Only the Swift domain produces completion. */
sealed interface C03TranscriptionState {
    data object Idle : C03TranscriptionState
    data class Running(val progress: Double) : C03TranscriptionState
    data class Completed(val receipt: C03SubtitleReceipt) : C03TranscriptionState
    data class Failed(val failure: C03VoiceFailure) : C03TranscriptionState
    data object Cancelled : C03TranscriptionState
}

data class C03VoiceSnapshot(
    val settings: C03VoiceSettings = C03VoiceSettings.DEFAULT,
    val settingsUnreadable: Boolean = false,
    val recognizerAvailable: Boolean = false,
    val microphonePermissionGranted: Boolean = false,
    val ttsAvailability: C03TtsAvailability = C03TtsAvailability.UNINITIALIZED,
    val ttsEngineName: String? = null,
    val systemVoices: List<C03SystemVoice> = emptyList(),
    val capabilities: C03VoiceCapabilities = C03VoiceCapabilities(),
    val dictation: C03DictationState = C03DictationState.IDLE,
    val partialText: String = "",
    val output: C03SpeechOutputState = C03SpeechOutputState.IDLE,
    val lastError: C03VoiceFailure? = null,
    val coreVersion: Int? = null,
) {
    val cloudInputCredentialReady: Boolean
        get() = capabilities.choiceFor(settings.cloudInput)?.credentialConfigured == true

    val cloudOutputCredentialReady: Boolean
        get() = capabilities.choiceFor(settings.cloudOutput)?.credentialConfigured == true

    val inputAvailable: Boolean
        get() = when (settings.inputEngine) {
            C03VoiceEngine.SYSTEM -> recognizerAvailable && microphonePermissionGranted
            C03VoiceEngine.CLOUD ->
                capabilities.cloudReady &&
                    settings.cloudInput.configured &&
                    cloudInputCredentialReady &&
                    microphonePermissionGranted
        }

    val outputAvailable: Boolean
        get() = when (settings.outputEngine) {
            C03VoiceEngine.SYSTEM -> ttsAvailability == C03TtsAvailability.READY
            C03VoiceEngine.CLOUD ->
                capabilities.cloudReady &&
                    settings.cloudOutput.configured &&
                    cloudOutputCredentialReady
        }

    val cloudOutputConfigured: Boolean
        get() = capabilities.cloudReady && settings.cloudOutput.configured
}

/**
 * Pure admission policy shared by the host and JVM tests.
 *
 * System dictation is text-only and remains available in a RAM temporary
 * conversation. Cloud microphone capture is refused there until a RAM-only
 * upload path is proven; no transcript/audio/task is silently persisted.
 */
internal object C03VoiceInputGate {
    fun rejection(
        settings: C03VoiceSettings,
        owner: C03VoiceOwner,
        microphoneGranted: Boolean,
        capabilities: C03VoiceCapabilities,
    ): C03VoiceFailure? {
        if (owner.conversationID.isNullOrBlank() && owner.taskID.isNullOrBlank()) {
            return C03VoiceFailure(
                C03VoiceErrorCode.INVALID_SELECTION,
                "voiceOwnerRequired",
            )
        }
        if (!microphoneGranted) {
            return C03VoiceFailure(
                C03VoiceErrorCode.PERMISSION_REQUIRED,
                "microphonePermissionRequired",
            )
        }
        return when (settings.inputEngine) {
            C03VoiceEngine.SYSTEM -> null
            C03VoiceEngine.CLOUD -> when {
                owner.temporary -> C03VoiceFailure(
                    C03VoiceErrorCode.UNCONFIGURED,
                    "cloudInputUnavailableInTemporaryChat",
                )
                !capabilities.cloudReady -> C03VoiceFailure(
                    C03VoiceErrorCode.TRANSPORT_UNAVAILABLE,
                    "cloudInputNotReady",
                    retryable = true,
                )
                !settings.cloudInput.configured -> C03VoiceFailure(
                    C03VoiceErrorCode.UNCONFIGURED,
                    "cloudInputNotConfigured",
                )
                capabilities.choiceFor(settings.cloudInput)?.credentialConfigured != true ->
                    C03VoiceFailure(
                        C03VoiceErrorCode.CREDENTIAL_MISSING,
                        "cloudInputCredentialMissing",
                    )
                else -> null
            }
        }
    }
}

/** Small JSON helpers. Every accessor is total and bounded. */
internal object C03Json {
    val value: Json = Json {
        ignoreUnknownKeys = true
        isLenient = false
        explicitNulls = false
    }

    fun parse(raw: String): JsonObject? =
        runCatching { value.parseToJsonElement(raw) as? JsonObject }.getOrNull()

    fun primitive(value: JsonElement?): JsonPrimitive? = value as? JsonPrimitive

    fun string(value: JsonElement?): String? {
        val primitive = primitive(value) ?: return null
        if (primitive is JsonNull) return null
        return primitive.contentOrNull
    }

    fun long(value: JsonElement?): Long? = primitive(value)?.longOrNull

    fun int(value: JsonElement?): Int? = primitive(value)?.intOrNull

    fun double(value: JsonElement?): Double? = primitive(value)?.doubleOrNull

    fun bool(value: JsonElement?): Boolean? = primitive(value)?.booleanOrNull

    fun array(value: JsonElement?): JsonArray? = value as? JsonArray

    fun objectValue(value: JsonElement?): JsonObject? = value as? JsonObject

    fun stringList(value: JsonElement?): List<String> =
        array(value)?.mapNotNull { string(it) } ?: emptyList()
}

internal fun JsonObject.string(key: String): String? = C03Json.string(this[key])
internal fun JsonObject.long(key: String): Long? = C03Json.long(this[key])
internal fun JsonObject.int(key: String): Int? = C03Json.int(this[key])
internal fun JsonObject.double(key: String): Double? = C03Json.double(this[key])
internal fun JsonObject.bool(key: String): Boolean? = C03Json.bool(this[key])
internal fun JsonObject.array(key: String): JsonArray? = C03Json.array(this[key])
internal fun JsonObject.obj(key: String): JsonObject? = C03Json.objectValue(this[key])

internal fun kotlinx.serialization.json.JsonObjectBuilder.put(key: String, value: String?) {
    if (value != null) put(key, JsonPrimitive(value))
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.put(key: String, value: Long?) {
    if (value != null) put(key, JsonPrimitive(value))
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.put(key: String, value: Int?) {
    if (value != null) put(key, JsonPrimitive(value))
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.put(key: String, value: Double?) {
    if (value != null) put(key, JsonPrimitive(value))
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.put(key: String, value: Boolean?) {
    if (value != null) put(key, JsonPrimitive(value))
}

/** Locale helpers shared by recognizer/TTS/UI. */
internal object C03Locale {
    fun defaultLanguageTag(): String {
        val locale = Locale.getDefault()
        return locale.toLanguageTag().takeIf { it.isNotBlank() && it != "und" }
            ?: "en-US"
    }

    fun matches(locale: String?, languageTag: String?): Boolean {
        if (locale.isNullOrBlank() || languageTag.isNullOrBlank()) return false
        val left = locale.replace('_', '-').lowercase(Locale.ROOT)
        val right = languageTag.replace('_', '-').lowercase(Locale.ROOT)
        return left == right || left.substringBefore('-') == right.substringBefore('-')
    }

    fun isChinese(): Boolean =
        Locale.getDefault().language.lowercase(Locale.ROOT).startsWith("zh")
}

/** Pure recognition state machine used by both the adapter and JVM tests. */
internal class C03RecognitionLifecycle {
    var state: C03DictationState = C03DictationState.IDLE
        private set
    var sawResult: Boolean = false
        private set
    var terminalEmitted: Boolean = false
        private set
    var cancelRequested: Boolean = false
        private set

    fun start(): Boolean {
        if (state == C03DictationState.LISTENING ||
            state == C03DictationState.FINALIZING
        ) {
            return false
        }
        state = C03DictationState.LISTENING
        sawResult = false
        terminalEmitted = false
        cancelRequested = false
        return true
    }

    fun acceptPartial() {
        if (state == C03DictationState.LISTENING) state = C03DictationState.LISTENING
    }

    fun requestStop() {
        if (state == C03DictationState.LISTENING) state = C03DictationState.FINALIZING
    }

    fun requestCancel() {
        cancelRequested = true
        if (state == C03DictationState.LISTENING ||
            state == C03DictationState.FINALIZING ||
            state == C03DictationState.PERMISSION_REQUIRED
        ) {
            state = C03DictationState.CANCELLED
            terminalEmitted = true
        }
    }

    fun complete(text: String?): Boolean {
        if (terminalEmitted || cancelRequested) return false
        val clean = text?.trim().orEmpty()
        if (clean.isEmpty()) {
            state = C03DictationState.FAILED
            terminalEmitted = true
            return false
        }
        sawResult = true
        state = C03DictationState.COMPLETED
        terminalEmitted = true
        return true
    }

    fun fail(): Boolean {
        if (terminalEmitted || cancelRequested) return false
        state = C03DictationState.FAILED
        terminalEmitted = true
        return true
    }

    fun reset() {
        state = C03DictationState.IDLE
        sawResult = false
        terminalEmitted = false
        cancelRequested = false
    }
}
