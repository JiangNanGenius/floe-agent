// SPDX-License-Identifier: MPL-2.0
//
// One continuous AudioRecord PCM16 capture used only when the user explicitly
// enables live cloud transcription for a take.
//
// The default meeting recorder remains MediaRecorder/AAC. In live mode this
// capture is the ONE microphone owner: it writes the canonical durable WAV and
// rotates independently finalized, bounded WAV fragments for the existing
// cloud-ASR path. No second microphone and no reader of an unfinished MP4 are
// involved. Fragment sidecars are written before the fragment is handed to the
// cloud queue so a process death cannot silently lose its measured timing.
package com.floe.android.host.meeting

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.floe.android.host.voice.C03Wav
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal class MeetingPcmCapture(
    private val canonicalFile: File,
    private val fragmentDirectory: File?,
    private val chunkSeconds: Int = DEFAULT_CHUNK_SECONDS,
    private val sampleRate: Int = SAMPLE_RATE,
    private val onFragment: (MeetingLiveFragment) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val lock = Any()
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var canonical: RandomAccessFile? = null
    private var fragment: FragmentWriter? = null
    private var fragmentIndex = 0
    private var fragmentStartFrames = 0L
    private var frames = 0L
    private var errorReported = false

    @Volatile
    private var running = false

    @Volatile
    private var paused = false

    @Volatile
    private var pauseAcknowledged = false

    @Volatile
    private var fragmentsEnabled = fragmentDirectory != null

    fun start() {
        if (running) return
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            throw IllegalStateException("audioCaptureUnavailable")
        }
        // Two seconds of device-side buffering absorbs the bounded manifest
        // write that happens at each 30 s fragment boundary.
        val captureBufferBytes = maxOf(minBuffer * 2, sampleRate * 4)
        val created = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            captureBufferBytes,
        )
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            throw IllegalStateException("audioCaptureUnavailable")
        }
        try {
            created.startRecording()
        } catch (error: Throwable) {
            created.release()
            throw error
        }
        if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            runCatching { created.stop() }
            runCatching { created.release() }
            throw IllegalStateException("microphoneStartFailed")
        }
        val out = try {
            RandomAccessFile(canonicalFile, "rw").also { file ->
                file.setLength(0L)
                file.write(C03Wav.header(sampleRate, channels = 1, dataBytes = 0))
            }
        } catch (error: Throwable) {
            runCatching { created.stop() }
            runCatching { created.release() }
            throw error
        }
        synchronized(lock) {
            canonical = out
            frames = 0L
            fragment = null
            fragmentIndex = 0
            fragmentStartFrames = 0L
            record = created
            running = true
            paused = false
        }
        fragmentDirectory?.let { directory ->
            if (!directory.isDirectory && !directory.mkdirs()) {
                runCatching { created.stop() }
                runCatching { created.release() }
                runCatching { out.close() }
                synchronized(lock) {
                    canonical = null
                    record = null
                    running = false
                }
                throw IllegalStateException("liveFragmentDirectoryUnavailable")
            }
        }
        val bufferBytes = maxOf(minBuffer * 2, sampleRate / 5 * 2)
        val worker = Thread({ captureLoop(bufferBytes) }, "meeting-live-pcm")
        worker.isDaemon = true
        thread = worker
        worker.start()
    }

    fun pause(): Boolean {
        if (!running) return true
        paused = true
        val deadline = System.currentTimeMillis() + PAUSE_DRAIN_TIMEOUT_MILLIS
        while (!pauseAcknowledged && running && System.currentTimeMillis() < deadline) {
            Thread.sleep(5L)
        }
        runCatching { record?.stop() }
        val finished = synchronized(lock) {
            val ready = finalizeFragmentLocked()
            patchCanonicalHeaderLocked()
            ready
        }
        finished?.let(onFragment)
        return true
    }

    fun resume(): Boolean {
        if (!running) return false
        val current = record ?: return false
        if (!paused) return true
        return try {
            current.startRecording()
            if (current.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                false
            } else {
                paused = false
                pauseAcknowledged = false
                true
            }
        } catch (_: Throwable) {
            false
        }
    }

    fun stop(discard: Boolean = false): Boolean {
        val current = thread
        if (running) {
            if (!paused && !discard) {
                runCatching { pause() }
            }
            running = false
            paused = false
            runCatching { record?.stop() }
            current?.interrupt()
            if (current != null && current !== Thread.currentThread()) {
                runCatching { current.join(STOP_JOIN_TIMEOUT_MILLIS) }
            }
        }
        var safetyFragment: MeetingLiveFragment? = null
        synchronized(lock) {
            if (discard) {
                abortFragmentLocked()
            } else {
                // pause() normally finalized the last fragment; this is the
                // safety net for a capture that ended because of an error.
                safetyFragment = finalizeFragmentLocked()
                patchCanonicalHeaderLocked()
            }
            runCatching { canonical?.close() }
            canonical = null
            runCatching { record?.release() }
            record = null
        }
        thread = null
        safetyFragment?.let(onFragment)
        if (discard) return false
        return canonicalFile.length() > 44L
    }

    /** Stops creating cloud fragments; canonical local capture continues. */
    fun disableLiveFragments() {
        fragmentsEnabled = false
        synchronized(lock) {
            abortFragmentLocked()
        }
    }

    private fun captureLoop(bufferBytes: Int) {
        val shorts = ShortArray(maxOf(1_024, bufferBytes / 2))
        val bytes = ByteArray(shorts.size * 2)
        while (running) {
            if (paused) {
                pauseAcknowledged = true
                while (paused && running) {
                    try {
                        Thread.sleep(10L)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return
                    }
                }
                pauseAcknowledged = false
                continue
            }
            val current = record
            if (current == null) {
                running = false
                break
            }
            val read = try {
                current.read(shorts, 0, shorts.size, AudioRecord.READ_BLOCKING)
            } catch (_: Throwable) {
                if (!running) break else -1
            }
            if (read > 0) {
                var target = 0
                for (index in 0 until read) {
                    val value = shorts[index].toInt()
                    bytes[target] = (value and 0xff).toByte()
                    bytes[target + 1] = ((value ushr 8) and 0xff).toByte()
                    target += 2
                }
                var ready: MeetingLiveFragment? = null
                try {
                    synchronized(lock) {
                        if (canonical == null || frames * 2L + read * 2L > MAX_CANONICAL_BYTES) {
                            if (!errorReported) {
                                errorReported = true
                                onError("recordingTooLong")
                            }
                            running = false
                        } else if (running) {
                            appendLocked(bytes, read)
                            if (shouldRotateLocked()) ready = finalizeFragmentLocked()
                        }
                    }
                } catch (_: Throwable) {
                    if (!errorReported) {
                        errorReported = true
                        onError("captureWriteFailed")
                    }
                    running = false
                    break
                }
                ready?.let(onFragment)
                if (!running) break
            } else if (read < 0) {
                if (running && !paused && !errorReported) {
                    errorReported = true
                    onError("microphoneReadFailed")
                }
                if (!running) break
                if (!paused) {
                    running = false
                    break
                }
            } else {
                try {
                    Thread.sleep(5L)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
        }
    }

    private fun appendLocked(bytes: ByteArray, framesRead: Int) {
        val out = canonical ?: return
        out.write(bytes, 0, framesRead * 2)
        frames += framesRead
        if (!fragmentsEnabled) return
        val directory = fragmentDirectory ?: return
        var current = fragment
        if (current == null) {
            // Keep the unconfirmed live spool bounded. Confirmed fragments are
            // deleted by the cloud owner, so this is a real on-disk budget.
            val pendingBytes = directory.listFiles()?.sumOf { it.length() } ?: 0L
            if (pendingBytes + sampleRate.toLong() * 2L * chunkSeconds > MAX_LIVE_SPOOL_BYTES) {
                fragmentsEnabled = false
                return
            }
            fragmentIndex += 1
            fragmentStartFrames = frames - framesRead
            current = FragmentWriter(
                file = File(directory, "fragment-%05d.wav".format(fragmentIndex - 1)),
                sampleRate = sampleRate,
            )
            fragment = current
        }
        current.write(bytes, framesRead * 2)
    }

    private fun shouldRotateLocked(): Boolean {
        if (!fragmentsEnabled || fragment == null) return false
        return frames - fragmentStartFrames >= sampleRate.toLong() * chunkSeconds
    }

    private fun finalizeFragmentLocked(): MeetingLiveFragment? {
        val current = fragment ?: return null
        fragment = null
        val finish = current.finish()
        if (finish.dataBytes <= 0L) {
            runCatching { current.file.delete() }
            return null
        }
        val endFrames = frames
        val startMillis = fragmentStartFrames * 1_000L / sampleRate
        val endMillis = endFrames * 1_000L / sampleRate
        if (endMillis <= startMillis) {
            runCatching { current.file.delete() }
            return null
        }
        val result = MeetingLiveFragment(
            index = fragmentIndex - 1,
            fileName = current.file.name,
            startMillis = startMillis,
            durationMillis = endMillis - startMillis,
            sampleRate = sampleRate,
            channels = 1,
            sizeBytes = current.file.length(),
        )
        runCatching { writeMeetingLiveFragmentSidecar(current.file, result) }
            .onFailure {
                runCatching { current.file.delete() }
                return null
            }
        return result
    }

    private fun abortFragmentLocked() {
        val current = fragment ?: return
        fragment = null
        current.abort()
    }

    private fun patchCanonicalHeaderLocked() {
        val out = canonical ?: return
        runCatching {
            val dataBytes = (frames * 2L).coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
            out.seek(0L)
            out.write(C03Wav.header(sampleRate, channels = 1, dataBytes = dataBytes))
            out.fd.sync()
        }
    }

    private class FragmentWriter(
        val file: File,
        val sampleRate: Int,
    ) {
        private val output = RandomAccessFile(file, "rw")
        private var bytes = 0L

        init {
            output.setLength(0L)
            output.write(C03Wav.header(sampleRate, channels = 1, dataBytes = 0))
        }

        fun write(data: ByteArray, length: Int) {
            output.write(data, 0, length)
            bytes += length.toLong()
        }

        fun finish(): FinishedFragment {
            val dataBytes = bytes.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
            runCatching {
                output.seek(0L)
                output.write(C03Wav.header(sampleRate, channels = 1, dataBytes = dataBytes))
                output.fd.sync()
            }
            runCatching { output.close() }
            return FinishedFragment(file, dataBytes.toLong())
        }

        fun abort() {
            runCatching { output.close() }
            runCatching { file.delete() }
        }
    }

    private data class FinishedFragment(val file: File, val dataBytes: Long)

    private companion object {
        const val SAMPLE_RATE = 16_000
        const val DEFAULT_CHUNK_SECONDS = 30
        const val MAX_CANONICAL_BYTES = 1_800_000_000L
        const val MAX_LIVE_SPOOL_BYTES = 512L * 1024L * 1024L
        const val PAUSE_DRAIN_TIMEOUT_MILLIS = 1_000L
        const val STOP_JOIN_TIMEOUT_MILLIS = 3_000L
    }
}

private const val LIVE_FRAGMENT_SIDECAR_VERSION = 1

internal fun writeMeetingLiveFragmentSidecar(file: File, fragment: MeetingLiveFragment) {
    val target = File(file.parentFile, file.nameWithoutExtension + ".json")
    val temp = File(file.parentFile, "${target.name}.tmp-${UUID.randomUUID()}")
    try {
        val bytes = buildJsonObject {
            put("schemaVersion", LIVE_FRAGMENT_SIDECAR_VERSION)
            put("index", fragment.index)
            put("fileName", fragment.fileName)
            put("startMillis", fragment.startMillis)
            put("durationMillis", fragment.durationMillis)
            put("sampleRate", fragment.sampleRate)
            put("channels", fragment.channels)
            put("sizeBytes", fragment.sizeBytes)
        }.toString().toByteArray(Charsets.UTF_8)
        FileOutputStream(temp).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        moveAtomically(temp, target)
    } finally {
        if (temp.exists()) runCatching { temp.delete() }
    }
}

internal fun readMeetingLiveFragmentSidecar(file: File): MeetingLiveFragment? {
    if (!file.isFile || file.length() <= 0L || file.length() > 64L * 1024L) return null
    val obj = runCatching {
        Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
    }.getOrNull() ?: return null
    if (obj.intOrNull("schemaVersion") != LIVE_FRAGMENT_SIDECAR_VERSION) return null
    val index = obj.intOrNull("index") ?: return null
    val fileName = (obj["fileName"] as? kotlinx.serialization.json.JsonPrimitive)
        ?.contentOrNull ?: return null
    return MeetingLiveFragment(
        index = index,
        fileName = fileName,
        startMillis = obj.longOrNull("startMillis") ?: return null,
        durationMillis = obj.longOrNull("durationMillis") ?: return null,
        sampleRate = obj.intOrNull("sampleRate") ?: return null,
        channels = obj.intOrNull("channels") ?: return null,
        sizeBytes = obj.longOrNull("sizeBytes") ?: return null,
    )
}

/**
 * Repairs the RIFF/data sizes of a PCM16 WAV whose header was written before
 * the capture ended. Returns true only for a valid PCM16 RIFF/WAVE file with a
 * data chunk; unrelated containers are left untouched.
 */
internal fun repairPcmWavHeader(file: File): Boolean {
    if (!file.isFile || file.length() < 44L || file.length() > Int.MAX_VALUE) return false
    return try {
        RandomAccessFile(file, "rw").use { raf ->
            val header = ByteArray(12)
            raf.readFully(header)
            if (String(header, 0, 4, Charsets.US_ASCII) != "RIFF" ||
                String(header, 8, 4, Charsets.US_ASCII) != "WAVE"
            ) {
                return false
            }
            var offset = 12L
            var formatOk = false
            var dataOffset = -1L
            while (offset + 8 <= raf.length()) {
                raf.seek(offset)
                val id = ByteArray(4)
                raf.readFully(id)
                val size = readLe32(raf)
                val chunkData = offset + 8
                if (size < 0) return false
                when (String(id, Charsets.US_ASCII)) {
                    "fmt " -> {
                        if (size < 16 || chunkData + size > raf.length()) return false
                        raf.seek(chunkData)
                        val format = readLe16(raf)
                        val channels = readLe16(raf)
                        val sampleRate = readLe32(raf)
                        raf.skipBytes(6)
                        val bits = readLe16(raf)
                        formatOk = format == 1 && channels in 1..8 &&
                            sampleRate in 8_000..192_000 && bits == 16
                    }
                    "data" -> {
                        dataOffset = chunkData
                        break
                    }
                }
                offset = chunkData + size + (size and 1)
            }
            if (!formatOk || dataOffset < 0L) return false
            val actualData = (raf.length() - dataOffset).coerceAtLeast(0L)
            if (actualData < 2L || actualData > Int.MAX_VALUE.toLong() - 40L) return false
            raf.seek(4L)
            writeLe32(raf, (actualData + 36L).toInt())
            raf.seek(dataOffset - 4L)
            writeLe32(raf, actualData.toInt())
            raf.fd.sync()
            true
        }
    } catch (_: Throwable) {
        false
    }
}

internal object MeetingPcmWavHeader {
    fun dataOffset(file: File): Long? {
        if (!file.isFile || file.length() < 44L) return null
        return try {
            RandomAccessFile(file, "r").use { raf ->
                val header = ByteArray(12)
                raf.readFully(header)
                if (String(header, 0, 4, Charsets.US_ASCII) != "RIFF" ||
                    String(header, 8, 4, Charsets.US_ASCII) != "WAVE"
                ) {
                    return null
                }
                var offset = 12L
                while (offset + 8 <= raf.length()) {
                    raf.seek(offset)
                    val id = ByteArray(4)
                    raf.readFully(id)
                    val size = readLe32(raf)
                    if (size < 0) return null
                    if (String(id, Charsets.US_ASCII) == "data") {
                        return offset + 8
                    }
                    offset += 8L + size + (size and 1)
                }
                null
            }
        } catch (_: Throwable) {
            null
        }
    }
}

private fun readLe16(raf: RandomAccessFile): Int {
    val b0 = raf.read()
    val b1 = raf.read()
    if (b0 < 0 || b1 < 0) return -1
    return (b0 and 0xff) or ((b1 and 0xff) shl 8)
}

private fun readLe32(raf: RandomAccessFile): Int {
    val bytes = ByteArray(4)
    raf.readFully(bytes)
    return ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).int
}

private fun writeLe32(raf: RandomAccessFile, value: Int) {
    raf.write(
        byteArrayOf(
            (value and 0xff).toByte(),
            ((value ushr 8) and 0xff).toByte(),
            ((value ushr 16) and 0xff).toByte(),
            ((value ushr 24) and 0xff).toByte(),
        ),
    )
}

/**
 * Client-side speech presence for one finalized live fragment. Returns null
 * when the audio cannot be inspected: callers must then take the ordinary
 * provider path instead of misclassifying the fragment as silence.
 */
internal fun meetingFragmentHasVoice(file: File): Boolean? {
    if (!file.isFile || file.length() <= 44L) return null
    val offset = MeetingPcmWavHeader.dataOffset(file) ?: return null
    val dataBytes = file.length() - offset
    if (dataBytes <= 0L || dataBytes > 16L * 1024L * 1024L) return null
    val bytes = try {
        RandomAccessFile(file, "r").use { input ->
            input.seek(offset)
            ByteArray(dataBytes.toInt()).also { input.readFully(it) }
        }
    } catch (_: Throwable) {
        return null
    }
    val samples = bytes.size / 2
    if (samples <= 0) return null
    val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    var voicedSamples = 0
    var index = 0
    while (index + VOICE_WINDOW_SAMPLES <= samples) {
        var energy = 0.0
        repeat(VOICE_WINDOW_SAMPLES) {
            val value = buffer.getShort(index * 2).toInt() / 32_768.0
            energy += value * value
            index += 1
        }
        if (kotlin.math.sqrt(energy / VOICE_WINDOW_SAMPLES) >= VOICE_RMS) {
            voicedSamples += VOICE_WINDOW_SAMPLES
            if (voicedSamples >= VOICE_MIN_SAMPLES) return true
        }
    }
    return false
}

private const val VOICE_RMS = 0.002
private const val VOICE_WINDOW_SAMPLES = 800
private const val VOICE_MIN_SAMPLES = 1_600
