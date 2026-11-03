// SPDX-License-Identifier: MPL-2.0
//
// Plays ONE Swift-rendered WAV file for cloud read-aloud. The completion
// continuation resumes only from MediaPlayer's actual onCompletion callback;
// enqueue/prepare is never reported as spoken. The temporary file is deleted
// after completion, failure, cancellation or explicit stop.
package com.floe.android.host.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import java.io.File
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

class C03CloudAudioPlayer(private val context: Context) {
    private var player: MediaPlayer? = null
    private var currentPath: String? = null

    suspend fun play(path: String, onStarted: () -> Unit = {}) {
        val file = validatedFile(path)
        suspendCancellableCoroutine { continuation ->
            val mediaPlayer = MediaPlayer()
            player = mediaPlayer
            currentPath = file.absolutePath
            var terminated = false
            fun release(deleteFile: Boolean) {
                if (terminated) return
                terminated = true
                runCatching { mediaPlayer.reset() }
                runCatching { mediaPlayer.release() }
                if (player === mediaPlayer) player = null
                if (deleteFile) runCatching { file.delete() }
                if (currentPath == file.absolutePath) currentPath = null
            }
            mediaPlayer.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            mediaPlayer.setOnPreparedListener {
                if (!continuation.isActive) return@setOnPreparedListener
                it.start()
                onStarted()
            }
            mediaPlayer.setOnCompletionListener {
                release(deleteFile = true)
                if (continuation.isActive) continuation.resume(Unit)
            }
            mediaPlayer.setOnErrorListener { _, what, extra ->
                release(deleteFile = true)
                if (continuation.isActive) {
                    continuation.resumeWith(
                        kotlin.Result.failure<Unit>(
                            C03VoiceFailure(
                                C03VoiceErrorCode.INTERNAL,
                                "audioPlayback_${what}_$extra",
                            ),
                        ),
                    )
                }
                true
            }
            continuation.invokeOnCancellation {
                release(deleteFile = true)
            }
            try {
                mediaPlayer.setDataSource(file.absolutePath)
                mediaPlayer.prepareAsync()
            } catch (_: Throwable) {
                release(deleteFile = true)
                if (continuation.isActive) {
                    continuation.resumeWith(
                        kotlin.Result.failure<Unit>(
                            C03VoiceFailure(C03VoiceErrorCode.MEDIA_UNAVAILABLE, "audioOpenFailed"),
                        ),
                    )
                }
            }
        }
    }

    fun stop() {
        val mediaPlayer = player
        player = null
        if (mediaPlayer != null) {
            runCatching { mediaPlayer.stop() }
            runCatching { mediaPlayer.reset() }
            runCatching { mediaPlayer.release() }
        }
        currentPath?.let { path -> runCatching { File(path).delete() } }
        currentPath = null
    }

    private fun validatedFile(path: String): File {
        if (path.isBlank() || path.length > 4_096) {
            throw C03VoiceFailure(C03VoiceErrorCode.MEDIA_UNAVAILABLE, "invalidAudioPath")
        }
        val file = runCatching { File(path).canonicalFile }.getOrElse {
            throw C03VoiceFailure(C03VoiceErrorCode.MEDIA_UNAVAILABLE, "invalidAudioPath")
        }
        val roots = listOf(
            context.filesDir,
            context.cacheDir,
            context.noBackupFilesDir,
        ).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        val contained = roots.any { root ->
            file.path == root.path || file.path.startsWith(root.path + File.separator)
        }
        if (!contained || !file.isFile || file.length() <= 0L || file.length() > MAX_WAV_BYTES) {
            throw C03VoiceFailure(C03VoiceErrorCode.MEDIA_UNAVAILABLE, "audioUnavailable")
        }
        return file
    }

    companion object {
        const val MAX_WAV_BYTES = 64L * 1024L * 1024L
    }
}
