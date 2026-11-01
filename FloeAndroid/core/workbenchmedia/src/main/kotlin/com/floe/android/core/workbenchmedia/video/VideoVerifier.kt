// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import com.floe.android.core.workbenchmedia.util.Digests
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.ExportVerification
import java.io.File
import kotlin.math.abs
import kotlin.math.max

internal data class VerifiedOutput(
    val verification: ExportVerification,
    val sha256: String,
    val byteCount: Long,
)

/**
 * Post-write verification. A receipt is emitted only after the exact staged
 * bytes decode on this device, the container reports the expected duration and
 * geometry, and the required audio tracks are present. This is a real decode
 * probe, not a success string.
 */
internal object VideoVerifier {
    fun verify(
        file: File,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedDurationSeconds: Double,
        codecMime: String,
        expectAudio: Boolean,
        maxBytes: Long,
    ): VerifiedOutput {
        if (!file.isFile || file.length() <= 0L || file.length() > maxBytes) {
            throw refusal(RENDERER_UNAVAILABLE, "Exported file size is invalid")
        }
        val sha = Digests.sha256(file, maxBytes)
            ?: throw refusal(RENDERER_UNAVAILABLE, "Exported file could not be hashed")
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: throw refusal(RENDERER_UNAVAILABLE, "Exported file has no readable duration")
            val duration = durationMs / 1000.0
            val rawWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
                ?: throw refusal(RENDERER_UNAVAILABLE, "Exported file has no video width")
            val rawHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
                ?: throw refusal(RENDERER_UNAVAILABLE, "Exported file has no video height")
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toDoubleOrNull()?.let(AssetProbe::normalizeRotation) ?: 0.0
            val width = if (rotation.toInt() % 180 == 90) rawHeight else rawWidth
            val height = if (rotation.toInt() % 180 == 90) rawWidth else rawHeight
            if (width != expectedWidth || height != expectedHeight) {
                throw refusal(
                    RENDER_UNSUPPORTED,
                    "Exported dimensions ${width}x$height do not match ${expectedWidth}x$expectedHeight",
                )
            }
            if (abs(duration - expectedDurationSeconds) > max(0.25, expectedDurationSeconds * 0.02)) {
                throw refusal(
                    RENDER_UNSUPPORTED,
                    "Exported duration $duration does not match the timeline $expectedDurationSeconds",
                )
            }
            val audioTracks = countAudioTracks(file)
            if (expectAudio && audioTracks <= 0) {
                throw refusal(RENDER_UNSUPPORTED, "Expected audio is missing from the export")
            }
            val frame = try {
                retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } catch (_: Exception) {
                null
            }
            if (frame == null) {
                throw refusal(RENDERER_UNAVAILABLE, "The exported file could not decode a frame")
            }
            frame.recycle()
            return VerifiedOutput(
                verification = ExportVerification(
                    playable = true,
                    decodedDurationSeconds = duration,
                    width = width,
                    height = height,
                    audioTrackCount = audioTracks,
                    container = "mp4",
                    codec = codecMime,
                ),
                sha256 = sha,
                byteCount = file.length(),
            )
        } catch (failure: com.floe.android.core.workbenchmedia.util.MediaRefusal) {
            throw failure
        } catch (failure: Exception) {
            throw refusal(RENDERER_UNAVAILABLE, "Exported file could not be verified: ${failure.message}")
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun countAudioTracks(file: File): Int {
        var extractor: MediaExtractor? = null
        return try {
            extractor = MediaExtractor()
            extractor.setDataSource(file.path)
            var count = 0
            for (index in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(index).getString(android.media.MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) count++
            }
            count
        } catch (_: Exception) {
            0
        } finally {
            runCatching { extractor?.release() }
        }
    }
}

internal object ImageVerifier {
    fun verify(
        file: File,
        expectedWidth: Int,
        expectedHeight: Int,
        format: String,
        maxBytes: Long,
    ): VerifiedOutput {
        if (!file.isFile || file.length() <= 0L || file.length() > maxBytes) {
            throw refusal(RENDERER_UNAVAILABLE, "Exported image size is invalid")
        }
        val sha = Digests.sha256(file, maxBytes)
            ?: throw refusal(RENDERER_UNAVAILABLE, "Exported image could not be hashed")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth != expectedWidth || bounds.outHeight != expectedHeight) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Exported image dimensions ${bounds.outWidth}x${bounds.outHeight} do not match ${expectedWidth}x$expectedHeight",
            )
        }
        val bitmap: Bitmap? = try {
            BitmapFactory.decodeFile(file.path)
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: Exception) {
            null
        }
        if (bitmap == null) throw refusal(RENDERER_UNAVAILABLE, "Exported image could not be decoded")
        bitmap.recycle()
        return VerifiedOutput(
            verification = ExportVerification(
                playable = true,
                decodedDurationSeconds = null,
                width = expectedWidth,
                height = expectedHeight,
                audioTrackCount = 0,
                container = format.lowercase(),
                codec = format.lowercase(),
            ),
            sha256 = sha,
            byteCount = file.length(),
        )
    }

    fun detectFormat(file: File): String? {
        val header = ByteArray(16)
        val read = try {
            file.inputStream().use { it.read(header) }
        } catch (_: Exception) {
            return null
        }
        if (read >= 8 && header[0] == 0x89.toByte() && header[1] == 'P'.code.toByte() &&
            header[2] == 'N'.code.toByte() && header[3] == 'G'.code.toByte()
        ) return "png"
        if (read >= 3 && header[0] == 0xFF.toByte() && header[1] == 0xD8.toByte() &&
            header[2] == 0xFF.toByte()
        ) return "jpeg"
        if (read >= 12 && header[4] == 'f'.code.toByte() && header[5] == 't'.code.toByte() &&
            header[6] == 'y'.code.toByte() && header[7] == 'p'.code.toByte()
        ) return "heic"
        return null
    }
}
