// SPDX-License-Identifier: MPL-2.0
//
// Bounded, sequential PCM16 WAV chunk extraction for long media.
//
// This decoder uses the platform MediaExtractor/MediaCodec primitives already
// present on Android (no new dependency, no Media3 version change). It never
// splits a compressed container byte-for-byte: it decodes the real audio track
// and writes at most one bounded WAV chunk at a time, deleting that chunk as
// soon as the trusted Swift uploader has accepted it. Memory is bounded by one
// decoder output buffer plus one chunk file; the source file is never loaded
// into memory and no full-file PCM copy is retained.
//
// A missing decoder is a typed CODEC_UNAVAILABLE capability failure. A missing
// audio track is typed UNSUPPORTED_MEDIA. Neither is reported as a generic
// platform-unsupported placeholder while an implementation exists here.
package com.floe.android.host.voice

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

data class C03AudioChunk(
    val index: Int,
    val file: File,
    /** Absolute source-media time of this chunk's first decoded sample. */
    val sourceStartSeconds: Double,
    val durationSeconds: Double,
    val sampleRate: Int,
    /** Always 1 after the real downmix; kept explicit for the bridge. */
    val channels: Int,
)

/** Pure budget helpers, exercised by JVM tests without an Android codec. */
internal object C03ChunkBudget {
    const val DEFAULT_CHUNK_BYTES = 20L * 1024L * 1024L
    const val MAX_CHUNK_BYTES = 24L * 1024L * 1024L
    const val MAX_CHUNKS = 512

    fun normalizedLimit(requested: Long): Long =
        requested.coerceIn(1L * 1024L * 1024L, MAX_CHUNK_BYTES)

    fun payloadBytes(limit: Long): Long =
        (normalizedLimit(limit) - C03Wav.HEADER_BYTES).coerceAtLeast(2L)

    fun estimatedChunks(sourceBytes: Long, limit: Long): Int {
        if (sourceBytes <= 0L) return 1
        val boundedLimit = normalizedLimit(limit)
        val estimated = ((sourceBytes - 1L) / boundedLimit) + 1L
        return estimated.coerceIn(1L, MAX_CHUNKS.toLong()).toInt()
    }
}

class C03AudioChunker(
    private val maxChunks: Int = C03ChunkBudget.MAX_CHUNKS,
) {
    @Volatile
    private var cancelled = false

    fun cancel() {
        cancelled = true
    }

    /**
     * Decode [sourcePath] into sequential chunks under [stagingPath] and emit
     * each one exactly once through [onChunk]. The callback is responsible for
     * uploading; it must return before the next chunk is produced, which keeps
     * disk use to one chunk. Cancellation is checked between decoder buffers.
     */
    suspend fun extract(
        sourcePath: String,
        stagingPath: String,
        chunkLimitBytes: Long,
        onChunk: suspend (C03AudioChunk) -> Unit,
    ) {
        val source = validatedSource(sourcePath)
        val staging = File(stagingPath).canonicalFile
        if (!staging.isDirectory && !staging.mkdirs()) {
            throw C03VoiceFailure(C03VoiceErrorCode.WRITE_FAILED, "chunkStagingUnavailable")
        }
        val limit = C03ChunkBudget.normalizedLimit(chunkLimitBytes)
        val maxPayload = C03ChunkBudget.payloadBytes(limit)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var writer: ChunkWriter? = null
        var chunkIndex = 0
        var chunkStartUs = 0L
        try {
            try {
                extractor.setDataSource(source.absolutePath)
            } catch (_: Throwable) {
                throw C03VoiceFailure(C03VoiceErrorCode.FILE_UNREADABLE, "audioSourceUnreadable")
            }
            var trackIndex = -1
            var trackFormat: MediaFormat? = null
            var trackMime: String? = null
            for (index in 0 until extractor.trackCount) {
                val format = runCatching { extractor.getTrackFormat(index) }.getOrNull() ?: continue
                val mime = format.stringOrNull(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = index
                    trackFormat = format
                    trackMime = mime
                    break
                }
            }
            if (trackIndex < 0 || trackFormat == null || trackMime == null) {
                throw C03VoiceFailure(C03VoiceErrorCode.UNSUPPORTED_MEDIA, "audioTrackMissing")
            }
            extractor.selectTrack(trackIndex)
            val decoder = try {
                MediaCodec.createDecoderByType(trackMime)
            } catch (_: Throwable) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.CODEC_UNAVAILABLE,
                    "audioDecoderUnavailable",
                )
            }
            codec = decoder
            try {
                // Request 16-bit PCM where the decoder supports it; the output
                // format below is authoritative and float/8-bit are converted.
                runCatching {
                    trackFormat.setInteger(
                        MediaFormat.KEY_PCM_ENCODING,
                        AudioFormat.ENCODING_PCM_16BIT,
                    )
                }
                decoder.configure(trackFormat, null, null, 0)
                decoder.start()
            } catch (_: Throwable) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.CODEC_UNAVAILABLE,
                    "audioDecoderUnavailable",
                )
            }
            var sampleRate = trackFormat.intOrNull(MediaFormat.KEY_SAMPLE_RATE)
                ?.coerceIn(8_000, 192_000) ?: 16_000
            var sourceChannels = trackFormat.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)
                ?.coerceIn(1, 8) ?: 1
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            val info = MediaCodec.BufferInfo()
            var inputEnded = false
            var outputEnded = false

            suspend fun flushCurrent() {
                val current = writer ?: return
                writer = null
                val duration = current.finish()
                if (duration <= 0.0) {
                    current.file.delete()
                    return
                }
                val chunk = C03AudioChunk(
                    index = chunkIndex,
                    file = current.file,
                    sourceStartSeconds = chunkStartUs.toDouble() / 1_000_000.0,
                    durationSeconds = duration,
                    sampleRate = current.sampleRate,
                    channels = 1,
                )
                chunkIndex++
                try {
                    onChunk(chunk)
                } finally {
                    current.file.delete()
                }
            }

            while (!outputEnded) {
                currentCoroutineContext().ensureActive()
                if (cancelled) throw kotlinx.coroutines.CancellationException("chunkCancelled")
                if (!inputEnded) {
                    val inputIndex = runCatching { decoder.dequeueInputBuffer(10_000L) }
                        .getOrElse { -1 }
                    if (inputIndex >= 0) {
                        val buffer = runCatching { decoder.getInputBuffer(inputIndex) }.getOrNull()
                        if (buffer == null) {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0L,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        } else {
                            val size = runCatching { extractor.readSampleData(buffer, 0) }
                                .getOrDefault(-1)
                            if (size < 0) {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    0,
                                    0L,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputEnded = true
                            } else {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    size,
                                    extractor.sampleTime.coerceAtLeast(0L),
                                    0,
                                )
                                runCatching { extractor.advance() }
                            }
                        }
                    }
                }
                val outputIndex = runCatching { decoder.dequeueOutputBuffer(info, 10_000L) }
                    .getOrElse { MediaCodec.INFO_TRY_AGAIN_LATER }
                when {
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        flushCurrent()
                        val outputFormat = decoder.outputFormat
                        sampleRate = outputFormat.intOrNull(MediaFormat.KEY_SAMPLE_RATE)
                            ?.coerceIn(8_000, 192_000) ?: sampleRate
                        sourceChannels = outputFormat.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)
                            ?.coerceIn(1, 8) ?: sourceChannels
                        pcmEncoding = outputFormat.intOrNull(MediaFormat.KEY_PCM_ENCODING)
                            ?: pcmEncoding
                    }
                    outputIndex >= 0 -> {
                        if (info.size > 0) {
                            val outputBuffer = runCatching {
                                decoder.getOutputBuffer(outputIndex)
                            }.getOrNull()
                            if (outputBuffer != null) {
                                val bytes = ByteArray(info.size)
                                outputBuffer.position(info.offset)
                                outputBuffer.get(bytes, 0, info.size)
                                val pcm = downmixToPcm16(
                                    bytes,
                                    sourceChannels,
                                    pcmEncoding,
                                )
                                if (pcm.isNotEmpty()) {
                                    val current = writer
                                    val expectedStartUs = chunkStartUs +
                                        ((current?.durationMicros() ?: 0L))
                                    val gap = info.presentationTimeUs - expectedStartUs
                                    if (current != null &&
                                        (current.bytes + pcm.size > maxPayload ||
                                            gap > 250_000L)
                                    ) {
                                        flushCurrent()
                                    }
                                    if (writer == null) {
                                        if (chunkIndex >= maxChunks) {
                                            throw C03VoiceFailure(
                                                C03VoiceErrorCode.FILE_TOO_LARGE,
                                                "tooManyAudioChunks",
                                            )
                                        }
                                        chunkStartUs = info.presentationTimeUs.coerceAtLeast(0L)
                                        writer = ChunkWriter(
                                            file = File(
                                                staging,
                                                "chunk-%05d.wav".format(chunkIndex),
                                            ),
                                            sampleRate = sampleRate,
                                        )
                                    }
                                    writer?.write(pcm)
                                }
                            }
                        }
                        decoder.releaseOutputBuffer(outputIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEnded = true
                        }
                    }
                    else -> delay(2L)
                }
            }
            flushCurrent()
            if (chunkIndex == 0) {
                throw C03VoiceFailure(C03VoiceErrorCode.EMPTY_TRANSCRIPT, "audioTrackEmpty")
            }
        } catch (cancelledError: kotlinx.coroutines.CancellationException) {
            throw cancelledError
        } finally {
            writer?.let { runCatching { it.abort() } }
            codec?.let { active ->
                runCatching { active.stop() }
                runCatching { active.release() }
            }
            runCatching { extractor.release() }
            staging.listFiles()?.forEach { runCatching { it.delete() } }
        }
    }

    private fun validatedSource(path: String): File {
        if (path.isBlank() || path.length > 4_096) {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidAudioSource")
        }
        val file = runCatching { File(path).canonicalFile }.getOrElse {
            throw C03VoiceFailure(C03VoiceErrorCode.INVALID_SELECTION, "invalidAudioSource")
        }
        if (!file.isFile || file.length() <= 0L) {
            throw C03VoiceFailure(C03VoiceErrorCode.FILE_UNREADABLE, "audioSourceUnreadable")
        }
        return file
    }

    private fun downmixToPcm16(
        bytes: ByteArray,
        channels: Int,
        encoding: Int,
    ): ByteArray {
        val safeChannels = channels.coerceIn(1, 8)
        return when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> {
                val frameBytes = safeChannels * 2
                if (frameBytes <= 0 || bytes.size < frameBytes) return ByteArray(0)
                val frames = bytes.size / frameBytes
                val output = ByteArray(frames * 2)
                var source = 0
                var target = 0
                repeat(frames) {
                    var sum = 0
                    repeat(safeChannels) {
                        val value = (bytes[source].toInt() and 0xff) or
                            (bytes[source + 1].toInt() shl 8)
                        sum += value.toShort().toInt()
                        source += 2
                    }
                    val mono = (sum / safeChannels).coerceIn(-32_768, 32_767)
                    output[target] = (mono and 0xff).toByte()
                    output[target + 1] = ((mono ushr 8) and 0xff).toByte()
                    target += 2
                }
                output
            }
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val frameBytes = safeChannels * 4
                if (frameBytes <= 0 || bytes.size < frameBytes) return ByteArray(0)
                val frames = bytes.size / frameBytes
                val output = ByteArray(frames * 2)
                val buffer = java.nio.ByteBuffer.wrap(bytes)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                var target = 0
                repeat(frames) {
                    var sum = 0.0
                    repeat(safeChannels) {
                        sum += buffer.float.coerceIn(-1.0f, 1.0f)
                    }
                    val mono = ((sum / safeChannels) * 32_767.0)
                        .coerceIn(-32_768.0, 32_767.0).toInt()
                    output[target] = (mono and 0xff).toByte()
                    output[target + 1] = ((mono ushr 8) and 0xff).toByte()
                    target += 2
                }
                output
            }
            AudioFormat.ENCODING_PCM_8BIT -> {
                val frames = bytes.size / safeChannels
                if (frames <= 0) return ByteArray(0)
                val output = ByteArray(frames * 2)
                var target = 0
                var source = 0
                repeat(frames) {
                    var sum = 0
                    repeat(safeChannels) {
                        sum += ((bytes[source].toInt() and 0xff) - 128) shl 8
                        source++
                    }
                    val mono = (sum / safeChannels).coerceIn(-32_768, 32_767)
                    output[target] = (mono and 0xff).toByte()
                    output[target + 1] = ((mono ushr 8) and 0xff).toByte()
                    target += 2
                }
                output
            }
            else -> throw C03VoiceFailure(
                C03VoiceErrorCode.CODEC_UNAVAILABLE,
                "pcmEncodingUnsupported",
            )
        }
    }

    private inner class ChunkWriter(
        val file: File,
        val sampleRate: Int,
    ) {
        private val raf = RandomAccessFile(file, "rw")
        var bytes: Long = 0L
            private set

        init {
            raf.setLength(0L)
            raf.write(C03Wav.header(sampleRate, channels = 1, dataBytes = 0))
        }

        fun write(pcm: ByteArray) {
            raf.write(pcm)
            bytes += pcm.size.toLong()
        }

        fun durationMicros(): Long =
            if (sampleRate <= 0) 0L else bytes * 1_000_000L / (sampleRate.toLong() * 2L)

        fun finish(): Double {
            val dataBytes = bytes.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
            raf.seek(0L)
            raf.write(C03Wav.header(sampleRate, channels = 1, dataBytes = dataBytes))
            raf.close()
            return dataBytes.toDouble() / (sampleRate.toDouble() * 2.0)
        }

        fun abort() {
            runCatching { raf.close() }
            runCatching { file.delete() }
        }
    }
}

private fun MediaFormat.stringOrNull(key: String): String? =
    if (containsKey(key)) runCatching { getString(key) }.getOrNull() else null

private fun MediaFormat.intOrNull(key: String): Int? =
    if (containsKey(key)) runCatching { getInteger(key) }.getOrNull() else null
