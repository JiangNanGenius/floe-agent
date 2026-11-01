// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.roundToInt

/**
 * Actual kind/metadata of the BYTES the user selected.
 *
 * The Android host is the trusted byte-measurement authority for the atomic
 * source-create facade: it reads the staged copy that was just written (never
 * a recorded project JSON field, a model string or a SAF display name) and
 * passes the measured dimensions/duration to the closed native action, which
 * bounds-checks and persists them. An unrecognised container is reported as
 * [CreativeSourceKind.FILE] for Canvas and refused for media creation, so an
 * "unknown" file never becomes a fabricated image/video project.
 */
internal enum class CreativeSourceKind(val wire: String) {
    IMAGE("image"),
    VIDEO("video"),
    AUDIO("audio"),
    FILE("file"),
}

internal data class CreativeSourceMetadata(
    val kind: CreativeSourceKind,
    val mimeType: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val durationSeconds: Double? = null,
    val frameRate: Double? = null,
    val rotationDegrees: Double? = null,
)

internal object CreativeSourceInspector {
    private const val PREFIX_BYTES = 1 shl 20
    private const val ISO_WINDOW_BYTES = 16L shl 20
    private const val MOOV_BYTES = 8 shl 20

    /** Inspect a staged file. Null means "not a recognised container". */
    fun inspect(file: File): CreativeSourceMetadata? {
        val length = file.length()
        if (length <= 0L) return null
        val prefixSize = minOf(length, PREFIX_BYTES.toLong()).toInt()
        val prefix = ByteArray(prefixSize)
        file.inputStream().use { input ->
            var read = 0
            while (read < prefixSize) {
                val next = input.read(prefix, read, prefixSize - read)
                if (next <= 0) break
                read += next
            }
            if (read < prefixSize) return null
        }
        if (looksLikeIsoBmff(prefix)) {
            val video = try {
                inspectIsoBmffFile(file)
            } catch (_: Throwable) {
                null
            }
            if (video != null) return video
            // An audio-only ISO-BMFF brand (M4A) has no video track header;
            // fall through to the in-memory classifier instead of reporting
            // an opaque file for a recognisable audio container.
        }
        return inspect(prefix)
    }

    /** Inspect in-memory bytes (used by focused JVM tests). */
    fun inspect(bytes: ByteArray): CreativeSourceMetadata? {
        if (bytes.size < 16) return null
        imageMetadata(bytes)?.let { return it }
        audioMetadata(bytes)?.let { return it }
        if (looksLikeIsoBmff(bytes)) return inspectIsoBmffBytes(bytes)
        return null
    }

    // MARK: - Image containers

    private fun imageMetadata(bytes: ByteArray): CreativeSourceMetadata? {
        if (isPng(bytes)) {
            val width = readU32(bytes, 16)
            val height = readU32(bytes, 20)
            if (positive(width, height)) {
                return CreativeSourceMetadata(
                    kind = CreativeSourceKind.IMAGE, mimeType = "image/png",
                    width = width, height = height)
            }
            return null
        }
        if (isGif(bytes)) {
            val width = readU16Le(bytes, 6)
            val height = readU16Le(bytes, 8)
            if (positive(width, height)) {
                return CreativeSourceMetadata(
                    kind = CreativeSourceKind.IMAGE, mimeType = "image/gif",
                    width = width, height = height)
            }
            return null
        }
        if (isBmp(bytes)) {
            val width = readU32(bytes, 18)
            val height = abs(readI32(bytes, 22))
            if (positive(width, height)) {
                return CreativeSourceMetadata(
                    kind = CreativeSourceKind.IMAGE, mimeType = "image/bmp",
                    width = width, height = height)
            }
            return null
        }
        if (isWebp(bytes)) {
            val chunk = ascii(bytes, 12, 4)
            val payload = 20
            when (chunk) {
                "VP8X" -> {
                    val width = 1 + readU24Le(bytes, payload + 4)
                    val height = 1 + readU24Le(bytes, payload + 7)
                    if (positive(width, height)) {
                        return CreativeSourceMetadata(
                            kind = CreativeSourceKind.IMAGE, mimeType = "image/webp",
                            width = width, height = height)
                    }
                }
                "VP8L" -> {
                    if (bytes.size > payload + 8 && (bytes[payload].toInt() and 0xFF) == 0x2F) {
                        val b1 = bytes[payload + 1].toInt() and 0xFF
                        val b2 = bytes[payload + 2].toInt() and 0xFF
                        val b3 = bytes[payload + 3].toInt() and 0xFF
                        val b4 = bytes[payload + 4].toInt() and 0xFF
                        val width = 1 + (((b2 and 0x3F) shl 8) or b1)
                        val height = 1 + (((b4 and 0x0F) shl 10) or (b3 shl 2) or ((b2 and 0xC0) shr 6))
                        if (positive(width, height)) {
                            return CreativeSourceMetadata(
                                kind = CreativeSourceKind.IMAGE, mimeType = "image/webp",
                                width = width, height = height)
                        }
                    }
                }
                "VP8 " -> {
                    if (bytes.size > payload + 10 &&
                        (bytes[payload + 3].toInt() and 0xFF) == 0x9D &&
                        (bytes[payload + 4].toInt() and 0xFF) == 0x01 &&
                        (bytes[payload + 5].toInt() and 0xFF) == 0x2A) {
                        val width = readU16Le(bytes, payload + 6) and 0x3FFF
                        val height = readU16Le(bytes, payload + 8) and 0x3FFF
                        if (positive(width, height)) {
                            return CreativeSourceMetadata(
                                kind = CreativeSourceKind.IMAGE, mimeType = "image/webp",
                                width = width, height = height)
                        }
                    }
                }
            }
            return null
        }
        if (bytes.size > 4 &&
            (bytes[0].toInt() and 0xFF) == 0xFF &&
            (bytes[1].toInt() and 0xFF) == 0xD8) {
            return jpegMetadata(bytes)
        }
        return null
    }

    private fun jpegMetadata(bytes: ByteArray): CreativeSourceMetadata? {
        var position = 2
        while (position + 4 <= bytes.size) {
            if ((bytes[position].toInt() and 0xFF) != 0xFF) {
                position++
                continue
            }
            val marker = bytes[position + 1].toInt() and 0xFF
            if (marker == 0xD8 || marker == 0x01 || marker in 0xD0..0xD7) {
                position += 2
                continue
            }
            if (marker == 0xD9 || marker == 0xDA) return null
            val segment = readU16(bytes, position + 2)
            if (segment < 2) return null
            val isStartOfFrame = marker in 0xC0..0xC3 ||
                marker in 0xC5..0xC7 ||
                marker in 0xC9..0xCB ||
                marker in 0xCD..0xCF
            if (isStartOfFrame) {
                if (position + 9 > bytes.size) return null
                val height = readU16(bytes, position + 5)
                val width = readU16(bytes, position + 7)
                if (!positive(width, height)) return null
                return CreativeSourceMetadata(
                    kind = CreativeSourceKind.IMAGE, mimeType = "image/jpeg",
                    width = width, height = height)
            }
            position += 2 + segment
        }
        return null
    }

    // MARK: - Audio containers (Canvas file/audio nodes only)

    private fun audioMetadata(bytes: ByteArray): CreativeSourceMetadata? {
        if (ascii(bytes, 0, 3) == "ID3") {
            return CreativeSourceMetadata(
                kind = CreativeSourceKind.AUDIO, mimeType = "audio/mpeg")
        }
        if ((bytes[0].toInt() and 0xFF) == 0xFF &&
            (bytes[1].toInt() and 0xE0) == 0xE0) {
            return CreativeSourceMetadata(
                kind = CreativeSourceKind.AUDIO, mimeType = "audio/mpeg")
        }
        if (ascii(bytes, 0, 4) == "RIFF" && ascii(bytes, 8, 4) == "WAVE") {
            return CreativeSourceMetadata(
                kind = CreativeSourceKind.AUDIO, mimeType = "audio/wav")
        }
        if (ascii(bytes, 0, 4) == "fLaC") {
            return CreativeSourceMetadata(
                kind = CreativeSourceKind.AUDIO, mimeType = "audio/flac")
        }
        if (ascii(bytes, 0, 4) == "OggS") {
            return CreativeSourceMetadata(
                kind = CreativeSourceKind.AUDIO, mimeType = "audio/ogg")
        }
        if (looksLikeIsoBmff(bytes)) {
            val brand = ascii(bytes, 8, 4)
            if (brand.startsWith("M4A") || brand.startsWith("M4B")) {
                return CreativeSourceMetadata(
                    kind = CreativeSourceKind.AUDIO, mimeType = "audio/mp4")
            }
        }
        return null
    }

    // MARK: - ISO base media (MP4/MOV/M4V)

    private fun looksLikeIsoBmff(bytes: ByteArray): Boolean =
        bytes.size >= 12 && ascii(bytes, 4, 4) == "ftyp"

    private fun inspectIsoBmffBytes(bytes: ByteArray): CreativeSourceMetadata? {
        val moov = findBox(bytes, 0, bytes.size, "moov") ?: return null
        return parseMoov(bytes, moov.first, moov.second)?.copy(mimeType = "video/mp4")
    }

    private fun inspectIsoBmffFile(file: File): CreativeSourceMetadata? {
        RandomAccessFile(file, "r").use { access ->
            val length = access.length()
            val headerLimit = minOf(length, ISO_WINDOW_BYTES)
            var offset = 0L
            var moovStart = -1L
            var moovSize = 0L
            while (offset + 8 <= headerLimit) {
                access.seek(offset)
                val size32 = readU32(access)
                val type = readFourCC(access)
                val boxSize = when (size32) {
                    1L -> readU64(access)
                    0L -> length - offset
                    else -> size32
                }
                if (boxSize < 8 || offset + boxSize > length) break
                if (type == "moov") {
                    moovStart = offset
                    moovSize = boxSize
                    break
                }
                offset += boxSize
            }
            if (moovStart < 0L && length > ISO_WINDOW_BYTES) {
                val tailStart = length - ISO_WINDOW_BYTES
                val window = ByteArray(ISO_WINDOW_BYTES.toInt())
                access.seek(tailStart)
                access.readFully(window)
                var index = 0
                while (index + 8 <= window.size) {
                    if (window[index] == 'm'.code.toByte() &&
                        window[index + 1] == 'o'.code.toByte() &&
                        window[index + 2] == 'o'.code.toByte() &&
                        window[index + 3] == 'v'.code.toByte()) {
                        val candidateStart = index - 4
                        if (candidateStart >= 0) {
                            val size = readU32(window, candidateStart).toLong()
                            if (size >= 8 && candidateStart + size <= window.size) {
                                moovStart = tailStart + candidateStart
                                moovSize = size
                                break
                            }
                        }
                    }
                    index++
                }
            }
            if (moovStart < 0L || moovSize < 8L) {
                // Some recorders write an audio-only M4A brand with no video
                // track; the brand check above reports that as AUDIO.
                return null
            }
            val payloadSize = minOf(moovSize - 8L, MOOV_BYTES.toLong()).toInt()
            val payload = ByteArray(payloadSize)
            access.seek(moovStart + 8)
            access.readFully(payload)
            return parseMoov(payload, 0, payload.size)?.copy(mimeType = "video/mp4")
        }
    }

    private fun findBox(bytes: ByteArray, start: Int, end: Int, wanted: String): Pair<Int, Int>? {
        var offset = start
        while (offset + 8 <= end) {
            val size32 = readU32(bytes, offset).toLong() and 0xFFFFFFFFL
            val type = ascii(bytes, offset + 4, 4)
            val size = when (size32) {
                1L -> {
                    if (offset + 16 > end) return null
                    readU64(bytes, offset + 8)
                }
                0L -> (end - offset).toLong()
                else -> size32
            }
            if (size < 8 || offset + size > end) return null
            if (type == wanted) return Pair(offset + 8, (offset + size).toInt())
            offset += size.toInt()
        }
        return null
    }

    /** Reads `mvhd` duration and the first video `tkhd` from a moov payload. */
    private fun parseMoov(bytes: ByteArray, start: Int, end: Int): CreativeSourceMetadata? {
        var durationSeconds: Double? = null
        var width = 0
        var height = 0
        var rotation = 0.0
        var offset = start
        while (offset + 8 <= end) {
            val size32 = readU32(bytes, offset).toLong() and 0xFFFFFFFFL
            val type = ascii(bytes, offset + 4, 4)
            val size = when (size32) {
                1L -> {
                    if (offset + 16 > end) break
                    readU64(bytes, offset + 8)
                }
                0L -> (end - offset).toLong()
                else -> size32
            }
            if (size < 8 || offset + size > end) break
            val payloadStart = offset + 8
            val payloadEnd = offset + size.toInt()
            when (type) {
                "mvhd" -> durationSeconds = parseMvhd(bytes, payloadStart, payloadEnd)
                "trak" -> {
                    if (width <= 0 || height <= 0) {
                        val track = parseTrak(bytes, payloadStart, payloadEnd)
                        if (track != null && track.first > 0 && track.second > 0) {
                            width = track.first
                            height = track.second
                            rotation = track.third
                        }
                    }
                }
            }
            offset = payloadEnd
        }
        if (width <= 0 || height <= 0) return null
        val rotated = rotation.roundToInt() % 180 != 0
        val displayWidth = if (rotated) height else width
        val displayHeight = if (rotated) width else height
        return CreativeSourceMetadata(
            kind = CreativeSourceKind.VIDEO,
            width = displayWidth,
            height = displayHeight,
            durationSeconds = durationSeconds,
            rotationDegrees = rotation)
    }

    private fun parseMvhd(bytes: ByteArray, start: Int, end: Int): Double? {
        if (end - start < 20) return null
        val version = bytes[start].toInt() and 0xFF
        return if (version == 1) {
            if (end - start < 32) return null
            val timescale = readU32(bytes, start + 20)
            val duration = readU64(bytes, start + 24)
            if (timescale <= 0 || duration <= 0) null
            else duration.toDouble() / timescale.toDouble()
        } else {
            val timescale = readU32(bytes, start + 12)
            val duration = readU32(bytes, start + 16).toLong() and 0xFFFFFFFFL
            if (timescale <= 0 || duration <= 0) null
            else duration.toDouble() / timescale.toDouble()
        }
    }

    private fun parseTrak(bytes: ByteArray, start: Int, end: Int): Triple<Int, Int, Double>? {
        var offset = start
        while (offset + 8 <= end) {
            val size32 = readU32(bytes, offset).toLong() and 0xFFFFFFFFL
            val type = ascii(bytes, offset + 4, 4)
            val size = when (size32) {
                1L -> readU64(bytes, offset + 8)
                0L -> (end - offset).toLong()
                else -> size32
            }
            if (size < 8 || offset + size > end) return null
            if (type == "tkhd") {
                return parseTkhd(bytes, offset + 8, offset + size.toInt())
            }
            offset += size.toInt()
        }
        return null
    }

    private fun parseTkhd(bytes: ByteArray, start: Int, end: Int): Triple<Int, Int, Double>? {
        if (end - start < 84) return null
        val version = bytes[start].toInt() and 0xFF
        val matrixOffset: Int
        val widthOffset: Int
        val heightOffset: Int
        if (version == 1) {
            if (end - start < 96) return null
            matrixOffset = start + 52
            widthOffset = start + 88
            heightOffset = start + 92
        } else {
            matrixOffset = start + 40
            widthOffset = start + 76
            heightOffset = start + 80
        }
        val width = (readU32(bytes, widthOffset) ushr 16)
        val height = (readU32(bytes, heightOffset) ushr 16)
        val a = readI32(bytes, matrixOffset) / 65536.0
        val b = readI32(bytes, matrixOffset + 4) / 65536.0
        val degrees: Double = if (a == 0.0 && b == 0.0) {
            0.0
        } else {
            var value = Math.toDegrees(atan2(b, a))
            if (value < 0) value += 360.0
            val snapped = (value / 90.0).roundToInt() * 90
            ((snapped % 360 + 360) % 360).toDouble()
        }
        return Triple(width, height, degrees)
    }

    // MARK: - Primitive readers

    /** Header presence check: a huge image is still an image (the media
     *  facade rejects out-of-budget dimensions explicitly). */
    private fun positive(width: Int, height: Int): Boolean =
        width > 0 && height > 0

    private fun isPng(bytes: ByteArray): Boolean =
        bytes.size >= 24 &&
            (bytes[0].toInt() and 0xFF) == 0x89 &&
            bytes[1] == 'P'.code.toByte() && bytes[2] == 'N'.code.toByte() &&
            bytes[3] == 'G'.code.toByte() &&
            bytes[4] == 0x0D.toByte() && bytes[5] == 0x0A.toByte() &&
            bytes[6] == 0x1A.toByte() && bytes[7] == 0x0A.toByte() &&
            ascii(bytes, 12, 4) == "IHDR"

    private fun isGif(bytes: ByteArray): Boolean =
        bytes.size >= 10 && (ascii(bytes, 0, 6) == "GIF87a" || ascii(bytes, 0, 6) == "GIF89a")

    private fun isBmp(bytes: ByteArray): Boolean =
        bytes.size >= 26 && bytes[0] == 'B'.code.toByte() && bytes[1] == 'M'.code.toByte()

    private fun isWebp(bytes: ByteArray): Boolean =
        bytes.size >= 30 && ascii(bytes, 0, 4) == "RIFF" && ascii(bytes, 8, 4) == "WEBP"

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String {
        if (offset < 0 || offset + length > bytes.size) return ""
        return buildString(length) {
            for (index in offset until offset + length) {
                val value = bytes[index].toInt() and 0xFF
                if (value < 0x20 || value > 0x7E) return ""
                append(value.toChar())
            }
        }
    }

    private fun readU16(bytes: ByteArray, offset: Int): Int {
        if (offset + 2 > bytes.size) return 0
        return ((bytes[offset].toInt() and 0xFF) shl 8) or
            (bytes[offset + 1].toInt() and 0xFF)
    }

    private fun readU16Le(bytes: ByteArray, offset: Int): Int {
        if (offset + 2 > bytes.size) return 0
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun readU24Le(bytes: ByteArray, offset: Int): Int {
        if (offset + 3 > bytes.size) return 0
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16)
    }

    private fun readU32(bytes: ByteArray, offset: Int): Int {
        if (offset + 4 > bytes.size) return 0
        return ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)
    }

    private fun readI32(bytes: ByteArray, offset: Int): Int = readU32(bytes, offset)

    private fun readU64(bytes: ByteArray, offset: Int): Long {
        if (offset + 8 > bytes.size) return 0
        var value = 0L
        for (index in 0 until 8) {
            value = (value shl 8) or (bytes[offset + index].toLong() and 0xFF)
        }
        return value
    }

    private fun readU32(access: RandomAccessFile): Long {
        var value = 0L
        for (index in 0 until 4) {
            value = (value shl 8) or (access.read().toLong() and 0xFF)
        }
        return value
    }

    private fun readU64(access: RandomAccessFile): Long {
        var value = 0L
        for (index in 0 until 8) {
            value = (value shl 8) or (access.read().toLong() and 0xFF)
        }
        return value
    }

    private fun readFourCC(access: RandomAccessFile): String {
        val value = ByteArray(4)
        access.readFully(value)
        return ascii(value, 0, 4)
    }
}
