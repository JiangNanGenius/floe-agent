// SPDX-License-Identifier: MPL-2.0
//
// Android system TTS adapter. Initialization is asynchronous; completion is
// reported ONLY by UtteranceProgressListener.onDone. `speak()` returning
// SUCCESS means the utterance was enqueued, not that audio played.
//
// The adapter distinguishes:
//  * no installed TTS service / initialization failure;
//  * missing language data or an explicitly requested missing voice;
//  * a real synthesis failure;
//  * explicit user/owner cancellation.
// It never falls back to a cloud provider on its own.
package com.floe.android.host.voice

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch

sealed interface C03TtsSpeakResult {
    data class Started(val utteranceID: String) : C03TtsSpeakResult
    data class Failure(val failure: C03VoiceFailure) : C03TtsSpeakResult
}

interface C03TtsListener {
    /** Actual engine playback began (not merely enqueue). */
    fun onStarted(utteranceID: String)
    fun onCompleted(utteranceID: String)
    fun onFailed(utteranceID: String, failure: C03VoiceFailure)
    fun onCancelled(utteranceID: String)
}

/**
 * Production system TTS adapter. Construct and call only on the main thread;
 * all calls are marshalled there defensively.
 */
class C03SystemTextToSpeech(
    private val context: Context,
    private val onAvailability: (
        availability: C03TtsAvailability,
        engineName: String?,
        voices: List<C03SystemVoice>,
    ) -> Unit = { _, _, _ -> },
) {
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var availability = C03TtsAvailability.UNINITIALIZED
    private var engineName: String? = null
    private var voices: List<C03SystemVoice> = emptyList()
    private var currentUtterance: String? = null
    private var currentListener: C03TtsListener? = null
    private var cancelRequested = false
    private var initialized = false

    fun initialize() = onMain { initializeLocked() }

    private fun initializeLocked() {
        if (initialized) return
        initialized = true
        availability = C03TtsAvailability.UNINITIALIZED
        val created = try {
            TextToSpeech(context.applicationContext) { status ->
                main.post { onInit(status) }
            }
        } catch (_: Throwable) {
            null
        }
        if (created == null) {
            availability = C03TtsAvailability.SERVICE_MISSING
            onAvailability(availability, null, emptyList())
            return
        }
        tts = created
        created.setOnUtteranceProgressListener(Progress())
    }

    private fun onInit(status: Int) = onMain {
        val engine = tts ?: return@onMain
        if (status != TextToSpeech.SUCCESS) {
            availability = C03TtsAvailability.INIT_FAILED
            onAvailability(availability, null, emptyList())
            return@onMain
        }
        val installed = runCatching { engine.engines }.getOrDefault(emptySet())
        if (installed.isEmpty()) {
            availability = C03TtsAvailability.SERVICE_MISSING
            onAvailability(availability, null, emptyList())
            return@onMain
        }
        engineName = runCatching { engine.defaultEngine }
            ?.takeIf { it.isNotBlank() }
            ?: installed.firstOrNull()?.name
        voices = runCatching { engine.voices }.getOrNull()
            ?.map { voice ->
                C03SystemVoice(
                    name = voice.name,
                    locale = voice.locale.toLanguageTag(),
                    displayName = voice.name,
                    requiresNetwork = runCatching { voice.isNetworkConnectionRequired }.getOrNull(),
                )
            }
            ?.sortedWith(compareBy({ it.locale }, { it.displayName }))
            ?.take(500)
            .orEmpty()
        val languageResult = runCatching {
            engine.setLanguage(Locale.getDefault())
        }.getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        availability = when (languageResult) {
            TextToSpeech.LANG_MISSING_DATA,
            TextToSpeech.LANG_NOT_SUPPORTED -> C03TtsAvailability.UNCONFIGURED
            else -> C03TtsAvailability.READY
        }
        if (availability == C03TtsAvailability.READY) {
            engine.setOnUtteranceProgressListener(Progress())
        }
        onAvailability(availability, engineName, voices)
    }

    fun availability(): C03TtsAvailability = availability
    fun engineName(): String? = engineName
    fun voices(): List<C03SystemVoice> = voices

    /**
     * Applies an explicit language/voice selection. Returns null on success or
     * a typed failure; never silently keeps a different voice.
     */
    fun configure(languageTag: String?, voiceName: String?): C03VoiceFailure? = onMainValue {
        val engine = tts ?: return@onMainValue C03VoiceFailure(
            C03VoiceErrorCode.UNCONFIGURED,
            "ttsNotInitialized",
        )
        if (availability == C03TtsAvailability.SERVICE_MISSING ||
            availability == C03TtsAvailability.INIT_FAILED
        ) {
            return@onMainValue C03VoiceFailure(
                C03VoiceErrorCode.UNCONFIGURED,
                "ttsUnavailable",
            )
        }
        val locale = languageTag
            ?.takeIf { it.isNotBlank() }
            ?.let { runCatching { Locale.forLanguageTag(it) }.getOrNull() }
            ?: Locale.getDefault()
        val languageResult = runCatching { engine.setLanguage(locale) }
            .getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        when (languageResult) {
            TextToSpeech.LANG_MISSING_DATA ->
                return@onMainValue C03VoiceFailure(
                    C03VoiceErrorCode.UNCONFIGURED,
                    "missingLanguageData",
                )
            TextToSpeech.LANG_NOT_SUPPORTED ->
                return@onMainValue C03VoiceFailure(
                    C03VoiceErrorCode.INVALID_SELECTION,
                    "languageNotSupported",
                )
        }
        if (!voiceName.isNullOrBlank()) {
            val voice = runCatching { engine.voices }
                .getOrNull()
                ?.firstOrNull { it.name == voiceName }
                ?: return@onMainValue C03VoiceFailure(
                    C03VoiceErrorCode.UNCONFIGURED,
                    "voiceNotInstalled",
                )
            val voiceResult = runCatching { engine.voice = voice }
            val accepted = voiceResult.isSuccess &&
                runCatching { engine.voice?.name == voice.name }.getOrDefault(false)
            if (!accepted) {
                return@onMainValue C03VoiceFailure(
                    C03VoiceErrorCode.INVALID_SELECTION,
                    "voiceRejected",
                )
            }
        }
        availability = C03TtsAvailability.READY
        onAvailability(availability, engineName, voices)
        null
    }

    fun speak(
        text: String,
        rate: Double,
        pitchSemitones: Double,
        listener: C03TtsListener,
    ): C03TtsSpeakResult = onMainValue {
        val engine = tts
            ?: return@onMainValue C03TtsSpeakResult.Failure(
                C03VoiceFailure(C03VoiceErrorCode.UNCONFIGURED, "ttsNotInitialized"),
            )
        if (availability != C03TtsAvailability.READY) {
            return@onMainValue C03TtsSpeakResult.Failure(
                C03VoiceFailure(
                    C03VoiceErrorCode.UNCONFIGURED,
                    when (availability) {
                        C03TtsAvailability.SERVICE_MISSING -> "ttsServiceMissing"
                        C03TtsAvailability.INIT_FAILED -> "ttsInitFailed"
                        C03TtsAvailability.MISSING_VOICE -> "ttsVoiceMissing"
                        C03TtsAvailability.UNCONFIGURED -> "ttsUnconfigured"
                        else -> "ttsUnavailable"
                    },
                ),
            )
        }
        val clean = text.trim()
        if (clean.isEmpty()) {
            return@onMainValue C03TtsSpeakResult.Failure(
                C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "emptyText"),
            )
        }
        if (clean.length > MAX_UTTERANCE_CHARACTERS) {
            return@onMainValue C03TtsSpeakResult.Failure(
                C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "textTooLong"),
            )
        }
        val utteranceID = "c03-${UUID.randomUUID()}"
        cancelRequested = false
        currentUtterance?.let { previous ->
            currentListener?.onCancelled(previous)
        }
        currentUtterance = utteranceID
        currentListener = listener
        engine.speechRate = rate.coerceIn(0.5, 2.0).toFloat()
        engine.pitch = pitchToMultiplier(pitchSemitones)
        val result = try {
            engine.speak(clean, TextToSpeech.QUEUE_FLUSH, null, utteranceID)
        } catch (_: Throwable) {
            TextToSpeech.ERROR
        }
        if (result != TextToSpeech.SUCCESS) {
            currentUtterance = null
            currentListener = null
            return@onMainValue C03TtsSpeakResult.Failure(
                C03VoiceFailure(
                    C03VoiceErrorCode.INTERNAL,
                    "ttsEnqueueRejected",
                    retryable = true,
                ),
            )
        }
        C03TtsSpeakResult.Started(utteranceID)
    }

    fun stop(): String? = onMainValue {
        val id = currentUtterance
        if (id != null) {
            cancelRequested = true
            val listener = currentListener
            currentUtterance = null
            currentListener = null
            runCatching { tts?.stop() }
            listener?.onCancelled(id)
        }
        id
    }

    fun shutdown() = onMain {
        val id = currentUtterance
        if (id != null) {
            val listener = currentListener
            currentUtterance = null
            currentListener = null
            listener?.onCancelled(id)
        }
        currentListener = null
        cancelRequested = true
        runCatching { tts?.stop() }
        runCatching { tts?.shutdown() }
        tts = null
        initialized = false
        availability = C03TtsAvailability.UNINITIALIZED
    }

    private fun pitchToMultiplier(semitones: Double): Float {
        val clamped = if (semitones.isFinite()) semitones.coerceIn(-6.0, 6.0) else 0.0
        val multiplier = Math.pow(2.0, clamped / 12.0)
        return multiplier.toFloat().coerceIn(0.5f, 2.0f)
    }

    private inner class Progress : UtteranceProgressListener() {
        override fun onStart(utteranceID: String?) {
            val id = utteranceID ?: return
            main.post {
                if (currentUtterance == id && !cancelRequested) {
                    currentListener?.onStarted(id)
                }
            }
        }

        override fun onDone(utteranceID: String?) {
            val id = utteranceID ?: return
            main.post {
                if (currentUtterance != id) return@post
                if (cancelRequested) {
                    currentUtterance = null
                    currentListener = null
                    return@post
                }
                val listener = currentListener
                currentUtterance = null
                currentListener = null
                listener?.onCompleted(id)
            }
        }

        @Deprecated("Deprecated by Android but still delivered by platform engines.")
        override fun onError(utteranceID: String?) {
            onError(utteranceID, TextToSpeech.ERROR)
        }

        override fun onError(utteranceID: String?, errorCode: Int) {
            val id = utteranceID ?: return
            main.post {
                if (currentUtterance != id) return@post
                val listener = currentListener
                currentUtterance = null
                currentListener = null
                if (cancelRequested) {
                    listener?.onCancelled(id)
                } else {
                    listener?.onFailed(
                        id,
                        C03VoiceFailure(
                            C03VoiceErrorCode.INTERNAL,
                            "ttsSynthesisError_$errorCode",
                        ),
                    )
                }
            }
        }

        override fun onStop(utteranceID: String?, interrupted: Boolean) {
            val id = utteranceID ?: return
            main.post {
                if (currentUtterance != id) return@post
                val listener = currentListener
                currentUtterance = null
                currentListener = null
                listener?.onCancelled(id)
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun <T> onMainValue(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        var result: T? = null
        val latch = CountDownLatch(1)
        main.post {
            result = block()
            latch.countDown()
        }
        latch.await()
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    companion object {
        const val MAX_UTTERANCE_CHARACTERS = 4_000
    }
}
