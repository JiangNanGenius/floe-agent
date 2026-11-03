// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.refusal
import java.io.File

internal data class ProbedMedia(
    val kind: String,
    val mimeType: String?,
    val byteCount: Long,
    val width: Int,
    val height: Int,
    val durationSeconds: Double?,
    val frameRate: Double?,
    val audioTrackCount: Int,
    val rotationDegrees: Double,
    val hasVideo: Boolean,
    val hasAudio: Boolean,
    val colorStandard: Int? = null,
    val colorTransfer: Int? = null,
    val colorRange: Int? = null,
    val hdrStaticInfo: ByteArray? = null,
    val codecProfile: Int? = null,
    val dynamicHdrMetadataPresent: Boolean = false,
) {
    val displayWidth: Int get() = if (rotationDegrees.toInt() % 180 == 90) height else width
    val displayHeight: Int get() = if (rotationDegrees.toInt() % 180 == 90) width else height
}

/**
 * Bounded platform probe. It reads container metadata only for video/audio and
 * bounds only for images; no full decode happens here. A missing/corrupt file
 * is a typed source-format refusal, never a silent skip.
 */
internal object AssetProbe {
    fun probe(file: File, expectedKind: String): ProbedMedia {
        if (!file.isFile) throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Asset is not a regular file")
        return when (expectedKind) {
            "image" -> probeImage(file)
            "video" -> probeVideo(file)
            "audio" -> probeAudio(file)
            else -> throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unsupported asset kind $expectedKind")
        }
    }

    private fun probeImage(file: File): ProbedMedia {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Image dimensions could not be read")
        }
        return ProbedMedia(
            kind = "image",
            mimeType = bounds.outMimeType,
            byteCount = file.length(),
            width = bounds.outWidth,
            height = bounds.outHeight,
            durationSeconds = null,
            frameRate = null,
            audioTrackCount = 0,
            rotationDegrees = 0.0,
            hasVideo = false,
            hasAudio = false,
        )
    }

    private fun probeVideo(file: File): ProbedMedia {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            if (!hasVideo) {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "File has no video track")
            }
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            if (width <= 0 || height <= 0) {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Video dimensions could not be read")
            }
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.takeIf { it > 0 }?.div(1000.0)
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toDoubleOrNull()?.let(::normalizeRotation) ?: 0.0
            val frameCount = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                ?.toLongOrNull()
            val captureFps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                ?.toDoubleOrNull()?.takeIf { it > 0.0 }
            val derivedFps = if (captureFps == null && frameCount != null && duration != null && duration > 0) {
                frameCount / duration
            } else {
                captureFps
            }
            val color = HdrRenderSupport.readTrackColor(file)
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "The video track format could not be read")
            return ProbedMedia(
                kind = "video",
                // Decoder matching needs the elementary track codec, not the
                // container MIME (for example video/avc instead of video/mp4).
                mimeType = color.mimeType,
                byteCount = file.length(),
                width = width,
                height = height,
                durationSeconds = duration,
                frameRate = derivedFps,
                audioTrackCount = countAudioTracks(file),
                rotationDegrees = rotation,
                hasVideo = true,
                hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes",
                colorStandard = color.colorStandard,
                colorTransfer = color.colorTransfer,
                colorRange = color.colorRange,
                hdrStaticInfo = color.hdrStaticInfo,
                codecProfile = color.codecProfile,
                dynamicHdrMetadataPresent = color.dynamicHdrMetadataPresent,
            )
        } catch (failure: Exception) {
            if (failure is com.floe.android.core.workbenchmedia.util.MediaRefusal) throw failure
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Video metadata could not be read: ${failure.message}")
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // best effort
            }
        }
    }

    private fun probeAudio(file: File): ProbedMedia {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            if (!hasAudio) {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "File has no audio track")
            }
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.takeIf { it > 0 }?.div(1000.0)
            return ProbedMedia(
                kind = "audio",
                mimeType = trackMime(file, "audio/"),
                byteCount = file.length(),
                width = 0,
                height = 0,
                durationSeconds = duration,
                frameRate = null,
                audioTrackCount = countAudioTracks(file),
                rotationDegrees = 0.0,
                hasVideo = false,
                hasAudio = true,
            )
        } catch (failure: Exception) {
            if (failure is com.floe.android.core.workbenchmedia.util.MediaRefusal) throw failure
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Audio metadata could not be read: ${failure.message}")
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // best effort
            }
        }
    }

    private fun trackMime(file: File, prefix: String): String {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.path)
            for (index in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(index)
                    .getString(android.media.MediaFormat.KEY_MIME)
                if (mime?.startsWith(prefix) == true) return mime
            }
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "The media track format could not be read")
        } finally {
            runCatching { extractor.release() }
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
            try {
                extractor?.release()
            } catch (_: Exception) {
                // best effort
            }
        }
    }

    fun normalizeRotation(value: Double): Double {
        if (!value.isFinite()) return 0.0
        var normalized = value % 360.0
        if (normalized < 0) normalized += 360.0
        return normalized
    }
}
