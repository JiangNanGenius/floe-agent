// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.TransformationRequest
import androidx.media3.transformer.VideoEncoderSettings
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_CANCELLED
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_CODEC
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.refusal
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A cancel request is a request; the caller must still await actual stop. */
internal class RenderControl {
    @Volatile var cancelRequested: Boolean = false
        private set

    fun requestCancel() {
        cancelRequested = true
    }
}

/**
 * Real Media3 Transformer export. It uses the SAME `Composition` object as
 * playback, a real platform encoder, an explicit bitrate derived from quality,
 * and no codec/format fallback. Any fallback reported by the engine is a
 * failure, never a silently accepted different output.
 */
internal class Media3VideoExporter(
    private val context: Context,
    private val progressPollMillis: Long,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    suspend fun export(
        plan: CompositionPlan,
        output: File,
        control: RenderControl,
        onProgress: (Double) -> Unit,
    ) {
        if (control.cancelRequested) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        val composition = Media3CompositionFactory.build(plan)
        val done = CompletableDeferred<ExportOutcome>()
        val fallbackApplied = AtomicBoolean(false)
        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                done.complete(ExportOutcome.Completed)
            }

            override fun onError(
                composition: Composition,
                exportResult: ExportResult,
                exportException: ExportException,
            ) {
                done.complete(ExportOutcome.Failed(exportException))
            }

            override fun onFallbackApplied(
                composition: Composition,
                originalTransformationRequest: TransformationRequest,
                fallbackTransformationRequest: TransformationRequest,
            ) {
                fallbackApplied.set(true)
            }
        }
        val encoderFactory = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder()
                    .setBitrate(videoBitrate(plan.width, plan.height, plan.frameRate, plan.quality))
                    .build(),
            )
            .setEnableFallback(false)
            .setEnableFormatFallback(false)
            .build()
        val transformer = Transformer.Builder(context)
            .setLooper(Looper.getMainLooper())
            .setVideoMimeType(plan.codecMime)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoderFactory)
            .addListener(listener)
            .build()

        var completedNormally = false
        try {
            onMain {
                if (control.cancelRequested) {
                    done.complete(ExportOutcome.Cancelled)
                } else {
                    try {
                        transformer.start(composition, output.absolutePath)
                    } catch (failure: Exception) {
                        done.complete(ExportOutcome.StartFailed(failure))
                    }
                }
            }
            val ticker = CoroutineScope(Dispatchers.IO).launch {
                val holder = ProgressHolder()
                while (!done.isCompleted) {
                    if (control.cancelRequested) {
                        onMain {
                            runCatching { transformer.cancel() }
                            done.complete(ExportOutcome.Cancelled)
                        }
                        return@launch
                    }
                    val progress = runCatching { progressPercent(transformer, holder) }.getOrDefault(0)
                    onProgress(progress / 100.0)
                    delay(progressPollMillis)
                }
            }
            try {
                when (val outcome = done.await()) {
                    ExportOutcome.Completed -> {
                        completedNormally = true
                        if (fallbackApplied.get()) {
                            throw refusal(
                                RENDER_UNSUPPORTED,
                                "The engine applied an unrequested format/resolution fallback",
                            )
                        }
                        if (control.cancelRequested) throw refusal(RENDER_CANCELLED, "Export was cancelled")
                        if (!output.isFile || output.length() <= 0L) {
                            throw refusal(RENDERER_UNAVAILABLE, "The encoder produced no output file")
                        }
                    }

                    ExportOutcome.Cancelled -> throw refusal(RENDER_CANCELLED, "Export was cancelled")
                    is ExportOutcome.StartFailed -> {
                        if (control.cancelRequested) {
                            throw refusal(RENDER_CANCELLED, "Export was cancelled")
                        }
                        throw refusal(
                            RENDERER_UNAVAILABLE,
                            "The encoder could not start: ${outcome.failure.message}",
                        )
                    }

                    is ExportOutcome.Failed -> throw mapFailure(outcome.failure, control.cancelRequested)
                }
            } finally {
                ticker.cancel()
            }
        } finally {
            if (!completedNormally && !done.isCompleted) {
                onMain { runCatching { transformer.cancel() } }
            }
            runCatching { onMain { transformer.removeListener(listener) } }
        }
    }

    private fun progressPercent(transformer: Transformer, holder: ProgressHolder): Int = onMain {
        try {
            if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                holder.progress.coerceIn(0, 100)
            } else {
                0
            }
        } catch (_: Exception) {
            0
        }
    }

    private fun mapFailure(exception: ExportException, cancelled: Boolean) =
        if (cancelled) {
            refusal(RENDER_CANCELLED, "Export was cancelled")
        } else {
            when (exception.errorCode) {
                ExportException.ERROR_CODE_DECODER_INIT_FAILED,
                ExportException.ERROR_CODE_DECODING_FAILED,
                ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                -> refusal(UNSUPPORTED_SOURCE_FORMAT, "The source cannot be decoded (${exception.errorCode})")

                ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
                ExportException.ERROR_CODE_ENCODING_FAILED,
                ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED,
                -> refusal(UNSUPPORTED_CODEC, "The requested encoder cannot render this output (${exception.errorCode})")

                ExportException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED,
                -> refusal(RENDER_UNSUPPORTED, "Video effects could not be rendered (${exception.errorCode})")

                else -> refusal(
                    RENDERER_UNAVAILABLE,
                    "Media3 export failed with code ${exception.errorCode}",
                    retryable = false,
                )
            }
        }

    /**
     * Minimal main-thread bridge: Transformer requires its application thread;
     * the module intentionally does not add coroutines-android or a second
     * dispatcher just for that. The bounded latch never blocks the UI thread.
     */
    private fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var value: T? = null
        var failure: Throwable? = null
        mainHandler.post {
            try {
                value = block()
            } catch (error: Throwable) {
                failure = error
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw IllegalStateException("Media3 main-thread call timed out")
        }
        failure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private sealed interface ExportOutcome {
        data object Completed : ExportOutcome
        data object Cancelled : ExportOutcome
        data class Failed(val failure: ExportException) : ExportOutcome
        data class StartFailed(val failure: Exception) : ExportOutcome
    }
}
