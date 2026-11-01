// SPDX-License-Identifier: MPL-2.0
//
// Android system recognition adapter for SHORT interactive dictation.
//
// Lifecycle rules enforced here (official SpeechRecognizer contract):
//  * creation, listener installation, startListening, stopListening, cancel
//    and destroy all execute on the main Looper;
//  * one session at a time, one terminal callback, and a bounded 60 s window;
//  * onResults is the ONLY success signal; no text is fabricated from partials;
//  * onError is classified, and cancellation is distinguished from failure;
//  * destroy() always runs after a terminal result/error/cancel;
//  * this adapter is never used for long audio files. File transcription is a
//    separate cloud/Linux route.
package com.floe.android.host.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/** Callbacks are delivered on the main thread. */
interface C03DictationListener {
    fun onListening()
    fun onPartial(text: String)
    fun onFinal(text: String)
    fun onFailure(failure: C03VoiceFailure)
    fun onCancelled()
}

interface C03SpeechRecognizerPort {
    fun isAvailable(): Boolean
    fun start(
        languageTag: String?,
        partialResults: Boolean,
        listener: C03DictationListener,
    ): Boolean
    fun stop()
    fun cancel()
    fun destroy()
}

/**
 * Production adapter. Construct on the main thread (or let the host construct
 * it there); every SpeechRecognizer call is marshalled to the main Looper even
 * when a caller accidentally invokes it from an IO coroutine.
 */
class C03SystemSpeechRecognizer(
    private val context: Context,
) : C03SpeechRecognizerPort {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var listener: C03DictationListener? = null
    private var terminal = true
    private var cancelRequested = false
    private var stopRequested = false
    private var startedAtMillis = 0L
    private var fallbackToken = 0L

    override fun isAvailable(): Boolean = onMainValue {
        runCatching {
            SpeechRecognizer.isRecognitionAvailable(context.applicationContext)
        }.getOrDefault(false)
    }

    override fun start(
        languageTag: String?,
        partialResults: Boolean,
        listener: C03DictationListener,
    ): Boolean = onMainValue {
        if (!terminal || recognizer != null) return@onMainValue false
        if (!isAvailable()) {
            listener.onFailure(
                C03VoiceFailure(C03VoiceErrorCode.CORE_UNAVAILABLE, "recognizerUnavailable"),
            )
            return@onMainValue false
        }
        terminal = false
        cancelRequested = false
        stopRequested = false
        startedAtMillis = System.currentTimeMillis()
        this.listener = listener
        val created = try {
            SpeechRecognizer.createSpeechRecognizer(context.applicationContext)
        } catch (_: Throwable) {
            null
        }
        if (created == null) {
            terminal = true
            this.listener = null
            listener.onFailure(
                C03VoiceFailure(C03VoiceErrorCode.CORE_UNAVAILABLE, "recognizerCreateFailed"),
            )
            return@onMainValue false
        }
        recognizer = created
        created.setRecognitionListener(RecognitionCallbacks())
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, partialResults)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            languageTag?.takeIf { it.isNotBlank() }?.let {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, it)
            }
        }
        try {
            created.startListening(intent)
            listener.onListening()
            scheduleTimeout()
            true
        } catch (_: Throwable) {
            finishFailure(
                C03VoiceFailure(
                    C03VoiceErrorCode.INTERNAL,
                    "recognizerStartFailed",
                    retryable = true,
                ),
            )
            false
        }
    }

    override fun stop() = onMain {
        if (terminal || recognizer == null) return@onMain
        stopRequested = true
        runCatching { recognizer?.stopListening() }
        // The platform may omit a terminal callback after stopListening. The
        // bounded fallback reports a truthful timeout/no-result; it never
        // invents text from the last partial result.
        val token = ++fallbackToken
        main.postDelayed({
            if (token == fallbackToken && !terminal) {
                finishFailure(
                    C03VoiceFailure(
                        C03VoiceErrorCode.TIMEOUT,
                        "recognizerNoFinalResult",
                        retryable = true,
                    ),
                )
            }
        }, STOP_FINALIZE_TIMEOUT_MILLIS)
    }

    override fun cancel() = onMain {
        if (terminal) return@onMain
        cancelRequested = true
        val captured = listener
        finish(cancelled = true)
        captured?.onCancelled()
    }

    override fun destroy() = onMain {
        finish(cancelled = true)
        listener = null
    }

    private fun scheduleTimeout() {
        val token = ++fallbackToken
        main.postDelayed({
            if (token == fallbackToken && !terminal) {
                finishFailure(
                    C03VoiceFailure(
                        C03VoiceErrorCode.TIMEOUT,
                        "recognizerSessionExpired",
                        retryable = true,
                    ),
                )
            }
        }, SESSION_TIMEOUT_MILLIS)
    }

    private fun finishFailure(failure: C03VoiceFailure) {
        if (terminal) return
        val captured = listener
        finish(cancelled = false)
        captured?.onFailure(failure)
    }

    private fun finish(cancelled: Boolean) {
        if (terminal) return
        terminal = true
        cancelRequested = cancelled
        fallbackToken++
        main.removeCallbacksAndMessages(null)
        val captured = recognizer
        recognizer = null
        listener = null
        if (captured != null) {
            runCatching { captured.cancel() }
            runCatching { captured.destroy() }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            main.post(block)
        }
    }

    private inline fun <T> onMainValue(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        var value: T? = null
        val latch = java.util.concurrent.CountDownLatch(1)
        main.post {
            value = block()
            latch.countDown()
        }
        latch.await()
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private inner class RecognitionCallbacks : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                main.post { onEndOfSpeech() }
                return
            }
            if (!terminal) {
                stopRequested = true
            }
        }

        override fun onError(error: Int) {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                main.post { onError(error) }
                return
            }
            if (terminal) return
            if (cancelRequested) {
                val captured = listener
                finish(cancelled = true)
                captured?.onCancelled()
                return
            }
            finishFailure(classifyError(error))
        }

        override fun onResults(results: Bundle?) {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                main.post { onResults(results) }
                return
            }
            if (terminal || cancelRequested) return
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isEmpty()) {
                finishFailure(
                    C03VoiceFailure(C03VoiceErrorCode.EMPTY_TRANSCRIPT, "noRecognizedText"),
                )
                return
            }
            val captured = listener
            finish(cancelled = false)
            captured?.onFinal(text)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                main.post { onPartialResults(partialResults) }
                return
            }
            if (terminal || cancelRequested) return
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isNotEmpty()) listener?.onPartial(text)
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun classifyError(error: Int): C03VoiceFailure {
        val elapsed = System.currentTimeMillis() - startedAtMillis
        return when (error) {
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                C03VoiceFailure(C03VoiceErrorCode.PERMISSION_REQUIRED, "recognitionPermission")
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                C03VoiceFailure(C03VoiceErrorCode.BUSY, "recognizerBusy", retryable = true)
            SpeechRecognizer.ERROR_NO_MATCH,
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                C03VoiceFailure(
                    C03VoiceErrorCode.TIMEOUT,
                    if (elapsed >= SESSION_TIMEOUT_MILLIS) "sessionTimeout" else "noSpeech",
                    retryable = true,
                )
            SpeechRecognizer.ERROR_NETWORK,
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED ->
                C03VoiceFailure(
                    C03VoiceErrorCode.NETWORK,
                    "recognitionNetwork",
                    retryable = true,
                )
            SpeechRecognizer.ERROR_SERVER ->
                C03VoiceFailure(
                    C03VoiceErrorCode.PROVIDER_REJECTED,
                    "recognitionServer",
                    retryable = true,
                )
            SpeechRecognizer.ERROR_AUDIO ->
                C03VoiceFailure(C03VoiceErrorCode.INTERNAL, "recognitionAudio")
            SpeechRecognizer.ERROR_CLIENT ->
                C03VoiceFailure(
                    C03VoiceErrorCode.INTERNAL,
                    if (stopRequested) "stoppedWithoutFinal" else "recognitionClient",
                    retryable = stopRequested,
                )
            else -> {
                if (Build.VERSION.SDK_INT >= 31 &&
                    error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED
                ) {
                    C03VoiceFailure(
                        C03VoiceErrorCode.INVALID_SELECTION,
                        "languageNotSupported",
                    )
                } else if (Build.VERSION.SDK_INT >= 31 &&
                    error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE
                ) {
                    C03VoiceFailure(
                        C03VoiceErrorCode.UNCONFIGURED,
                        "languageUnavailable",
                    )
                } else if (Build.VERSION.SDK_INT >= 33 &&
                    error == SpeechRecognizer.ERROR_TOO_MANY_REQUESTS
                ) {
                    C03VoiceFailure(
                        C03VoiceErrorCode.QUOTA_OR_RATE_LIMITED,
                        "recognitionRateLimited",
                        retryable = true,
                    )
                } else if (Build.VERSION.SDK_INT >= 34 &&
                    error == SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT
                ) {
                    C03VoiceFailure(
                        C03VoiceErrorCode.UNCONFIGURED,
                        "supportCheckUnavailable",
                    )
                } else {
                    C03VoiceFailure(
                        C03VoiceErrorCode.INTERNAL,
                        "recognitionError_$error",
                        retryable = false,
                    )
                }
            }
        }
    }

    companion object {
        const val SESSION_TIMEOUT_MILLIS = 60_000L
        const val STOP_FINALIZE_TIMEOUT_MILLIS = 5_000L
    }
}
