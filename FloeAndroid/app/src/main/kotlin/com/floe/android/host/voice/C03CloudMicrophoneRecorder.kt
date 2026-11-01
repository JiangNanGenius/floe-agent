// SPDX-License-Identifier: MPL-2.0
//
// One FINITE cloud-microphone utterance recorder.
//
// This is deliberately not a continuous stream: a single AudioRecord captures
// at most 60 seconds of PCM16 mono at 16 kHz, the user (or the cap) stops it,
// and the bounded WAV is uploaded once. `startRecording`/`read`/`stop`/
// `release` are the only lifecycle calls, and a failure, cancel or epoch loss
// always releases the recorder and deletes the staging WAV. The file lives
// under the accepted root's `Voice/Utterances` staging namespace created by
// the trusted Swift bridge; no arbitrary path is accepted.
package com.floe.android.host.voice

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.io.RandomAccessFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal class C03CloudMicrophoneRecorder(
    private val context: Context,
    private val sampleRate: Int = 16_000,
    private val maxDurationMillis: Long = 60_000L,
) {
    @Volatile
    private var stopRequested = false

    @Volatile
    private var cancelled = false

    @Volatile
    private var record: AudioRecord? = null

    @Volatile
    private var output: File? = null

    /**
     * Captures one finite utterance. [path] must be the staging path returned
     * by `c03.utterance.begin`; the file is created here and always removed on
     * cancel/failure. Returns the actual captured duration in seconds.
     */
    suspend fun capture(path: String): Double = withContext(Dispatchers.IO) {
        val file = validatedFile(path)
        output = file
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            file.delete()
            throw C03VoiceFailure(
                C03VoiceErrorCode.CODEC_UNAVAILABLE,
                "audioCaptureUnavailable",
            )
        }
        val created = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuffer * 2,
            )
        } catch (_: SecurityException) {
            file.delete()
            throw C03VoiceFailure(
                C03VoiceErrorCode.PERMISSION_REQUIRED,
                "microphonePermissionRequired",
            )
        } catch (_: Throwable) {
            file.delete()
            throw C03VoiceFailure(
                C03VoiceErrorCode.CODEC_UNAVAILABLE,
                "audioCaptureUnavailable",
            )
        }
        record = created
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            record = null
            file.delete()
            throw C03VoiceFailure(
                C03VoiceErrorCode.CODEC_UNAVAILABLE,
                "audioCaptureUnavailable",
            )
        }
        var recordedBytes = 0L
        try {
            try {
                created.startRecording()
            } catch (permission: SecurityException) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.PERMISSION_REQUIRED,
                    "microphonePermissionRequired",
                )
            } catch (_: Throwable) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.INTERNAL,
                    "microphoneStartFailed",
                    retryable = true,
                )
            }
            if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.INTERNAL,
                    "microphoneStartFailed",
                    retryable = true,
                )
            }
            val buffer = ByteArray(maxOf(4_096, minBuffer * 2))
            val startedAt = System.nanoTime()
            RandomAccessFile(file, "rw").use { raf ->
                raf.setLength(0L)
                raf.write(C03Wav.header(sampleRate, channels = 1, dataBytes = 0))
                while (!stopRequested && !cancelled) {
                    currentCoroutineContext().ensureActive()
                    val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L
                    if (elapsedMillis >= maxDurationMillis) break
                    val read = try {
                        created.read(buffer, 0, buffer.size)
                    } catch (_: Throwable) {
                        if (stopRequested || cancelled) break else -1
                    }
                    if (read > 0) {
                        if (recordedBytes + read > MAX_UTTERANCE_BYTES) break
                        raf.write(buffer, 0, read)
                        recordedBytes += read.toLong()
                        continue
                    }
                    if (stopRequested || cancelled) break
                    if (read < 0) {
                        throw C03VoiceFailure(
                            C03VoiceErrorCode.INTERNAL,
                            "microphoneReadFailed",
                            retryable = true,
                        )
                    }
                    // read == 0 is a transient empty read; yield briefly.
                    kotlinx.coroutines.delay(5L)
                }
                if (cancelled) {
                    throw kotlinx.coroutines.CancellationException("microphoneCancelled")
                }
                raf.seek(0L)
                raf.write(
                    C03Wav.header(
                        sampleRate,
                        channels = 1,
                        dataBytes = recordedBytes.toInt(),
                    ),
                )
            }
            val duration = recordedBytes.toDouble() / (sampleRate.toDouble() * 2.0)
            if (duration < MIN_UTTERANCE_SECONDS) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.EMPTY_TRANSCRIPT,
                    "utteranceTooShort",
                )
            }
            duration
        } finally {
            runCatching { created.stop() }
            runCatching { created.release() }
            record = null
            if (cancelled) runCatching { file.delete() }
        }
    }

    /** Ask the capture loop to finish and upload the finite utterance. */
    fun stop() {
        stopRequested = true
        runCatching { record?.stop() }
    }

    /** Explicit user cancel / conversation retirement / RootStop. */
    fun cancel() {
        cancelled = true
        stopRequested = true
        runCatching { record?.stop() }
        output?.let { file -> runCatching { file.delete() } }
    }

    private fun validatedFile(path: String): File {
        if (path.isBlank() || path.length > 4_096) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidUtterancePath")
        }
        val file = runCatching { File(path).canonicalFile }.getOrElse {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidUtterancePath")
        }
        val roots = listOf(context.filesDir, context.cacheDir, context.noBackupFilesDir)
            .mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        val contained = roots.any { root ->
            file.path == root.path || file.path.startsWith(root.path + File.separator)
        }
        if (!contained) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidUtterancePath")
        }
        val parent = file.parentFile
        if (parent == null || (!parent.isDirectory && !parent.mkdirs())) {
            throw C03VoiceFailure(C03VoiceErrorCode.WRITE_FAILED, "utteranceStagingUnavailable")
        }
        if (file.exists()) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "utterancePathOccupied")
        }
        return file
    }

    companion object {
        const val MIN_UTTERANCE_SECONDS = 0.25
        const val MAX_UTTERANCE_BYTES = 8L * 1024L * 1024L
    }
}

/** Canonical PCM16 little-endian WAV header used by captured utterances. */
internal object C03Wav {
    const val HEADER_BYTES = 44

    fun header(sampleRate: Int, channels: Int, dataBytes: Int): ByteArray {
        val safeRate = sampleRate.coerceIn(8_000, 192_000)
        val safeChannels = channels.coerceIn(1, 8)
        val blockAlign = safeChannels * 2
        val byteRate = safeRate * blockAlign
        val data = dataBytes.coerceAtLeast(0)
        val result = ByteArray(HEADER_BYTES)
        fun putAscii(offset: Int, value: String) {
            value.toByteArray(Charsets.US_ASCII).copyInto(result, offset)
        }
        fun putLe16(offset: Int, value: Int) {
            result[offset] = (value and 0xff).toByte()
            result[offset + 1] = ((value ushr 8) and 0xff).toByte()
        }
        fun putLe32(offset: Int, value: Int) {
            result[offset] = (value and 0xff).toByte()
            result[offset + 1] = ((value ushr 8) and 0xff).toByte()
            result[offset + 2] = ((value ushr 16) and 0xff).toByte()
            result[offset + 3] = ((value ushr 24) and 0xff).toByte()
        }
        putAscii(0, "RIFF")
        putLe32(4, 36 + data)
        putAscii(8, "WAVE")
        putAscii(12, "fmt ")
        putLe32(16, 16)
        putLe16(20, 1)
        putLe16(22, safeChannels)
        putLe32(24, safeRate)
        putLe32(28, byteRate)
        putLe16(32, blockAlign)
        putLe16(34, 16)
        putAscii(36, "data")
        putLe32(40, data)
        return result
    }
}
