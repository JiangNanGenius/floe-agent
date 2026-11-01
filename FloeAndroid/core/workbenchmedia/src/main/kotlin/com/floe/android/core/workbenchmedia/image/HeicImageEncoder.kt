// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import androidx.heifwriter.HeifWriter
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.refusal
import java.io.File
import java.util.Locale

/**
 * Actual AndroidX `HeifWriter` 1.1.0 capability/encoder integration.
 *
 * The writer is used as a real HEIF encoder (MediaCodec `image/vnd.android.heic`
 * or the documented HEVC fallback). `Bitmap.compress` has no HEIC format and is
 * never used. HeifWriter 1.1.0 hard-codes `highBitDepthEnabled=false`, so this
 * path is explicitly an 8-bit SDR HEIF output; HDR sources are refused by
 * [HdrSourceProbe] instead of being silently tone-mapped.
 */
internal data class HeicCapability(
    val supported: Boolean,
    val encoderName: String? = null,
    val maxWidth: Int = 0,
    val maxHeight: Int = 0,
    val bitDepth: Int = 8,
    val alphaSupported: Boolean = false,
    val hdrSupported: Boolean = false,
    val reason: String? = null,
)

internal object HeicEncoderCapability {
    const val MAX_EDGE = 8_192

    @Volatile
    private var cached: HeicCapability? = null

    fun probe(force: Boolean = false): HeicCapability {
        cached?.let { if (!force) return it }
        synchronized(this) {
            cached?.let { if (!force) return it }
            val value = probeActual()
            cached = value
            return value
        }
    }

    fun supports(width: Int, height: Int): HeicCapability {
        val capability = probe()
        if (!capability.supported) return capability
        if (width < 2 || height < 2 || width > MAX_EDGE || height > MAX_EDGE ||
            (capability.maxWidth > 0 && width > capability.maxWidth) ||
            (capability.maxHeight > 0 && height > capability.maxHeight)
        ) {
            return capability.copy(
                supported = false,
                reason = "HEIC output must be within the encoder bounds and <= $MAX_EDGE px",
            )
        }
        return capability
    }

    private fun probeActual(): HeicCapability {
        if (Build.VERSION.SDK_INT < 28) {
            return HeicCapability(
                supported = false,
                reason = "HEIF/HEIC encoding requires Android 9 (API 28) or newer",
            )
        }
        var hevcFallback: MediaCodecInfo? = null
        try {
            val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            for (info in infos) {
                if (!info.isEncoder) continue
                for (mime in info.supportedTypes) {
                    if (mime != MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC &&
                        mime != MediaFormat.MIMETYPE_VIDEO_HEVC
                    ) {
                        continue
                    }
                    val caps = try {
                        info.getCapabilitiesForType(mime)
                    } catch (_: Exception) {
                        continue
                    }
                    val video = try {
                        caps.videoCapabilities
                    } catch (_: Exception) {
                        null
                    } ?: continue
                    val width = safeUpper(video.supportedWidths)
                    val height = safeUpper(video.supportedHeights)
                    if (mime == MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC && width > 0 && height > 0) {
                        return HeicCapability(
                            supported = true,
                            encoderName = info.name,
                            maxWidth = minOf(width, MAX_EDGE),
                            maxHeight = minOf(height, MAX_EDGE),
                            bitDepth = 8,
                            alphaSupported = false,
                            hdrSupported = false,
                        )
                    }
                    if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
                        // HeifWriter's documented fallback tiles into 512x512
                        // grid tiles. Require that exact capability so a codec
                        // that cannot serve the writer is not advertised.
                        if (runCatching { video.isSizeSupported(512, 512) }.getOrDefault(false)) {
                            if (hevcFallback == null) hevcFallback = info
                        }
                    }
                }
            }
        } catch (failure: Exception) {
            return HeicCapability(
                supported = false,
                reason = "The platform HEIF/HEVC encoder list could not be read: ${failure.message}",
            )
        }
        if (hevcFallback != null) {
            return HeicCapability(
                supported = true,
                encoderName = hevcFallback.name,
                // HeifWriter tiles HEVC fallback images into 512x512 grid
                // cells, so a bounded per-frame HEVC limit does not cap the
                // final still image. Keep Floe's own 8192px guard.
                maxWidth = MAX_EDGE,
                maxHeight = MAX_EDGE,
                bitDepth = 8,
                alphaSupported = false,
                hdrSupported = false,
            )
        }
        return HeicCapability(
            supported = false,
            reason = "The device exposes no HEIC or HEVC encoder for the AndroidX HeifWriter path",
        )
    }

    private fun safeUpper(range: android.util.Range<Int>?): Int = try {
        range?.upper ?: 0
    } catch (_: Exception) {
        0
    }
}

internal data class EncodedHeic(
    val file: File,
    val width: Int,
    val height: Int,
    val byteCount: Long,
)

/**
 * Bounded, real HEIF encode using AndroidX HeifWriter 1.1.0.
 *
 * One bitmap is written to the exact staging file. `stop()` must complete
 * successfully before the caller publishes anything; a timeout/codec error or
 * a missing HEIF `ftyp`/brand is a typed failure. The writer never receives a
 * source path and never mutates the source bitmap.
 */
internal object HeicImageEncoder {
    const val STOP_TIMEOUT_MS = 30_000L

    fun encode(
        bitmap: Bitmap,
        quality: Double,
        staging: File,
    ): EncodedHeic {
        if (Build.VERSION.SDK_INT < 28) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "HEIF/HEIC encoding requires Android 9 (API 28) or newer",
            )
        }
        if (bitmap.width < 2 || bitmap.height < 2) {
            throw refusal(RENDER_UNSUPPORTED, "HEIC output dimensions are invalid")
        }
        val capability = HeicEncoderCapability.supports(bitmap.width, bitmap.height)
        if (!capability.supported) {
            throw refusal(
                RENDER_UNSUPPORTED,
                capability.reason ?: "HEIC encoding is unavailable on this device",
            )
        }
        if (!quality.isFinite() || quality < 0.0 || quality > 1.0) {
            throw refusal(RENDER_UNSUPPORTED, "HEIC quality must be 0...1")
        }
        staging.parentFile?.mkdirs()
        if (staging.exists()) staging.delete()
        val q = (quality * 100.0).toInt().coerceIn(0, 100)
        var writer: HeifWriter? = null
        try {
            writer = HeifWriter.Builder(
                staging.absolutePath,
                bitmap.width,
                bitmap.height,
                HeifWriter.INPUT_MODE_BITMAP,
            )
                .setQuality(q)
                .setMaxImages(1)
                .setGridEnabled(true)
                .build()
            writer.start()
            writer.addBitmap(bitmap)
            writer.stop(STOP_TIMEOUT_MS)
        } catch (error: Exception) {
            staging.delete()
            throw refusal(
                RENDERER_UNAVAILABLE,
                "HEIF encoder failed: ${error.javaClass.simpleName}: ${error.message}",
            )
        } finally {
            runCatching { writer?.close() }
        }
        if (!staging.isFile || staging.length() <= 0L) {
            staging.delete()
            throw refusal(RENDERER_UNAVAILABLE, "HEIF encoder produced no output")
        }
        val format = HeifHeaderInspector.detect(staging)
        if (format != "heic") {
            val detected = format ?: "unknown"
            staging.delete()
            throw refusal(
                RENDERER_UNAVAILABLE,
                "HEIF output header is not a supported HEIC brand ($detected)",
            )
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(staging.absolutePath, bounds)
        if (bounds.outWidth != bitmap.width || bounds.outHeight != bitmap.height) {
            staging.delete()
            throw refusal(
                RENDERER_UNAVAILABLE,
                "HEIF output dimensions ${bounds.outWidth}x${bounds.outHeight} do not match ${bitmap.width}x${bitmap.height}",
            )
        }
        return EncodedHeic(staging, bitmap.width, bitmap.height, staging.length())
    }
}

/**
 * ISO-BMFF `ftyp` inspection for a real HEIC/HEIF file. A generic MP4/AVIF
 * header is never relabelled as HEIC.
 */
internal object HeifHeaderInspector {
    private val HEIF_BRANDS = setOf("heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1")

    fun detect(file: File): String? {
        val header = ByteArray(256)
        val read = try {
            file.inputStream().use { it.read(header) }
        } catch (_: Exception) {
            return null
        }
        if (read < 16) return null
        val boxSize = readInt(header, 0)
        if (boxSize < 16 || boxSize > read) return null
        if (!header.ascii(4, 4).equals("ftyp", ignoreCase = true)) return null
        val major = header.ascii(8, 4).lowercase(Locale.ROOT)
        if (major == "avif" || major == "avis") return "avif"
        val brands = LinkedHashSet<String>()
        brands += major
        var offset = 16
        while (offset + 4 <= boxSize && offset + 4 <= read) {
            brands += header.ascii(offset, 4).lowercase(Locale.ROOT)
            offset += 4
        }
        return if (brands.any { it in HEIF_BRANDS }) "heic" else null
    }

    private fun readInt(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 24) or
            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
            (bytes[offset + 3].toInt() and 0xff)

    private fun ByteArray.ascii(offset: Int, length: Int): String =
        String(this, offset, length, Charsets.ISO_8859_1)
}

/**
 * Source HDR/high-bit-depth boundary for the current 8-bit image pipeline.
 *
 * HeifWriter 1.1.0 always constructs an 8-bit encoder (`highBitDepthEnabled =
 * false`), and no gain-map/colour-transfer metadata is written. Therefore an
 * HDR source (PQ/HLG transfer, >8-bit HEIF/AV1 bit depth, or a gain-map
 * auxiliary item) must be refused before encoding instead of being silently
 * tone-mapped or having its metadata reset. The same source guard is used
 * by PNG/JPEG export and layer rasters; none silently converts a known HDR source.
 */
internal object HdrSourceProbe {
    const val SCAN_BYTES = 4 * 1024 * 1024

    data class Result(val isHdr: Boolean, val detail: String? = null)

    fun inspect(file: File): Result {
        if (!file.isFile || file.length() <= 0L) return Result(false)
        val head = readPrefix(file, SCAN_BYTES)
        val tail = if (file.length() > SCAN_BYTES) readSuffix(file, SCAN_BYTES) else ByteArray(0)
        val bytes = if (tail.isEmpty()) head else head + tail
        if (containsAscii(bytes, "hdrgainmap") ||
            containsAscii(bytes, "urn:com:apple:photo:2020:aux:hdrgainmap") ||
            containsAscii(bytes, "urn:iso:std:iso:ts:21496:-1") ||
            containsAscii(bytes, "hdrgm:Version") ||
            containsAscii(bytes, "GContainer")
        ) {
            return Result(true, "gainMap")
        }
        if (looksLikeIsoBmff(bytes)) {
            when {
                hasPqOrHlgColour(bytes) -> return Result(true, "pqOrHlgTransfer")
                hasHighBitDepthBox(bytes) -> return Result(true, "highBitDepth")
                hasToneMapBox(bytes) -> return Result(true, "toneMapDerived")
            }
            return Result(false)
        }
        if (looksLikePng(bytes)) {
            if (hasPngCicpHighDynamicRange(bytes)) return Result(true, "pngCicp")
            return Result(false)
        }
        // JPEG UltraHDR is identified by its XMP gain-map namespace; it is
        // covered by the ASCII markers above. Other JPEGs are SDR here.
        return Result(false)
    }

    private fun readPrefix(file: File, limit: Int): ByteArray = try {
        val length = minOf(file.length(), limit.toLong()).toInt()
        val buffer = ByteArray(length)
        file.inputStream().use { input ->
            var offset = 0
            while (offset < length) {
                val read = input.read(buffer, offset, length - offset)
                if (read <= 0) break
                offset += read
            }
        }
        buffer
    } catch (_: Exception) {
        ByteArray(0)
    }

    private fun readSuffix(file: File, limit: Int): ByteArray = try {
        val length = minOf(file.length(), limit.toLong()).toInt()
        java.io.RandomAccessFile(file, "r").use { access ->
            access.seek(file.length() - length)
            val buffer = ByteArray(length)
            access.readFully(buffer)
            buffer
        }
    } catch (_: Exception) {
        ByteArray(0)
    }

    private fun containsAscii(bytes: ByteArray, needle: String): Boolean {
        val target = needle.toByteArray(Charsets.ISO_8859_1)
        if (target.isEmpty() || target.size > bytes.size) return false
        outer@ for (index in 0..(bytes.size - target.size)) {
            for (j in target.indices) {
                if (bytes[index + j] != target[j]) continue@outer
            }
            return true
        }
        return false
    }

    private fun looksLikeIsoBmff(bytes: ByteArray): Boolean =
        bytes.size >= 12 && bytes.ascii(4, 4) == "ftyp"

    private fun looksLikePng(bytes: ByteArray): Boolean =
        bytes.size >= 8 && bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte() &&
            bytes[2] == 'N'.code.toByte() && bytes[3] == 'G'.code.toByte()

    private fun hasPqOrHlgColour(bytes: ByteArray): Boolean {
        var index = 0
        while (index + 8 < bytes.size) {
            if (bytes.ascii(index, 4) == "colr" &&
                bytes.ascii(index + 4, 4) == "nclx" &&
                index + 12 <= bytes.size
            ) {
                val transfer = ((bytes[index + 10].toInt() and 0xff) shl 8) or
                    (bytes[index + 11].toInt() and 0xff)
                if (transfer == 16 || transfer == 18) return true
            }
            index++
        }
        return false
    }

    private fun hasHighBitDepthBox(bytes: ByteArray): Boolean {
        var index = 0
        while (index + 8 < bytes.size) {
            if (bytes.ascii(index, 4) == "pixi" && index + 9 <= bytes.size) {
                val channelsOffset = index + 8
                val channels = bytes[channelsOffset].toInt() and 0xff
                if (channels in 1..8) {
                    for (channel in 0 until channels) {
                        val position = channelsOffset + 1 + channel
                        if (position < bytes.size && (bytes[position].toInt() and 0xff) > 8) {
                            return true
                        }
                    }
                }
            }
            if (bytes.ascii(index, 4) == "hvcC" && index + 24 < bytes.size) {
                val luma = bytes[index + 21].toInt() and 0x07
                val chroma = bytes[index + 22].toInt() and 0x07
                if (luma > 0 || chroma > 0) return true
            }
            if (bytes.ascii(index, 4) == "av1C" && index + 8 < bytes.size) {
                val highBitDepth = (bytes[index + 6].toInt() and 0x40) != 0
                val twelveBit = (bytes[index + 6].toInt() and 0x20) != 0
                if (highBitDepth || twelveBit) return true
            }
            index++
        }
        return false
    }

    private fun hasToneMapBox(bytes: ByteArray): Boolean {
        var index = 0
        while (index + 8 < bytes.size) {
            if (bytes.ascii(index, 4) == "tmap") {
                return true
            }
            index++
        }
        return false
    }

    private fun hasPngCicpHighDynamicRange(bytes: ByteArray): Boolean {
        var index = 8
        while (index + 12 <= bytes.size) {
            val length = ((bytes[index].toInt() and 0xff) shl 24) or
                ((bytes[index + 1].toInt() and 0xff) shl 16) or
                ((bytes[index + 2].toInt() and 0xff) shl 8) or
                (bytes[index + 3].toInt() and 0xff)
            if (length < 0 || index + 12 + length > bytes.size) return false
            val type = bytes.ascii(index + 4, 4)
            if (type == "cICP" && length >= 4) {
                // cICP data: colour primaries, transfer characteristics,
                // matrix coefficients, video full range.
                val transfer = bytes[index + 9].toInt() and 0xff
                if (transfer == 16 || transfer == 18) return true
            }
            if (type == "IEND") return false
            index += 12 + length
        }
        return false
    }

    private fun ByteArray.ascii(offset: Int, length: Int): String =
        String(this, offset, length, Charsets.ISO_8859_1)

    fun projectHasHdrSource(
        project: com.floe.android.feature.workbench.MediaProject,
        root: File,
    ): Result {
        for (layer in project.imageLayers) {
            if (layer.kind != "image" || layer.isHidden || layer.opacity <= 0.0) continue
            val assetID = layer.assetID ?: continue
            val asset = project.assets.firstOrNull { it.id == assetID } ?: continue
            val file = com.floe.android.core.workbenchmedia.util.MediaPaths
                .resolveExistingUnder(root, asset.relativePath) ?: continue
            val result = inspect(file)
            if (result.isHdr) return result
        }
        return Result(false)
    }
}

/** Small helper used by diagnostics/tests; never a success string. */
internal fun heicCapability(): HeicCapability = HeicEncoderCapability.probe()
