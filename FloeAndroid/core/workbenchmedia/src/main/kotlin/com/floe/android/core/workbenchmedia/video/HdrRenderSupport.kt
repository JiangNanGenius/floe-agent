// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.transformer.EncoderUtil
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_CANCELLED
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_CODEC
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.VideoExportSettings
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.math.max

internal data class TrackColor(
    val colorStandard: Int?,
    val colorTransfer: Int?,
    val colorRange: Int?,
    val hdrStaticInfo: ByteArray?,
    val mimeType: String? = null,
    val codecProfile: Int? = null,
    val dynamicHdrMetadataPresent: Boolean = false,
)

/**
 * Real HDR encoder and container work for the video export path.
 *
 * - `validateEncoder` refuses before render when no actual encoder supports
 *   HDR editing for the requested codec/size/rate. It never chooses to
 *   tone-map.
 * - `preserveIfNeeded` remuxes the encoded MP4 (samples unchanged) through
 *   `MediaMuxer` when static metadata is present, because Media3 1.11.1's
 *   in-app muxer writes a non-standard SmDm box instead of the mdcv/clli
 *   boxes the platform muxer emits for the 25-byte CTA-861.3 payload.
 * - `verifyOutput` proves the exact HDR transfer/primaries/range/static
 *   metadata survived before the caller can publish a receipt.
 */
internal object HdrRenderSupport {
    fun colorInfo(hdr: HdrPlan): ColorInfo = ColorInfo.Builder()
        .setColorSpace(hdr.colorStandard ?: C.COLOR_SPACE_BT2020)
        .setColorTransfer(hdr.colorTransfer ?: C.COLOR_TRANSFER_ST2084)
        .setColorRange(hdr.colorRange ?: C.COLOR_RANGE_LIMITED)
        .setHdrStaticInfo(hdr.hdrStaticInfo)
        .build()

    fun validateEncoder(settings: VideoExportSettings, hdr: HdrPlan) {
        if (!hdr.isHdr) return
        val mime = settings.codecMime
        val colorInfo = colorInfo(hdr)
        val candidates = try {
            EncoderUtil.getSupportedEncodersForHdrEditing(mime, colorInfo)
        } catch (_: Exception) {
            emptyList()
        }
        if (candidates.isEmpty()) {
            throw refusal(
                UNSUPPORTED_CODEC,
                "No $mime encoder on this device supports ${hdr.label} HDR editing; " +
                    "the export was not tone-mapped",
            )
        }
        val supported = candidates.any { info ->
            val hdrProfile = try {
                EncoderUtil.isHdrEditingSupported(info, mime, colorInfo)
            } catch (_: Exception) {
                false
            }
            hdrProfile && sizeAndRateSupported(info, mime, settings)
        }
        if (!supported) {
            throw refusal(
                UNSUPPORTED_CODEC,
                "The ${hdr.label} encoder does not support " +
                    "${settings.width}x${settings.height}@${settings.frameRate}",
            )
        }
    }

    fun preserveIfNeeded(hdr: HdrPlan, output: File, isCancelled: () -> Boolean) {
        if (!hdr.isHdr || hdr.hdrStaticInfo == null) return
        if (isCancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        val parent = output.parentFile
            ?: throw refusal(STORAGE_UNAVAILABLE, "HDR output directory is unavailable")
        val usable = parent.usableSpace
        if (usable > 0L && usable < output.length() + (16L * 1024L * 1024L)) {
            throw refusal(STORAGE_UNAVAILABLE, "Not enough free space to preserve HDR metadata")
        }
        val temp = File(parent, ".${output.name}.hdr-part")
        temp.delete()
        try {
            // Never wrap SDR samples in HDR boxes: the encoder must have
            // already produced an HDR color encoding. Only the static-info
            // boxes are repaired by the remux.
            verifyColorEncoding(output, hdr, requireStatic = false, requireRange = false)
            remux(output, temp, hdr, isCancelled)
            if (isCancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
            verifyOutput(temp, hdr)
            try {
                Files.move(
                    temp.toPath(),
                    output.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temp.toPath(), output.toPath(), StandardCopyOption.REPLACE_EXISTING)
            } catch (_: UnsupportedOperationException) {
                Files.move(temp.toPath(), output.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (failure: com.floe.android.core.workbenchmedia.util.MediaRefusal) {
            throw failure
        } catch (failure: Exception) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "HDR metadata could not be preserved: ${failure.message}",
            )
        } finally {
            temp.delete()
        }
    }

    fun verifyOutput(file: File, hdr: HdrPlan) {
        verifyColorEncoding(file, hdr, requireStatic = true, requireRange = true)
    }

    private fun verifyColorEncoding(
        file: File,
        hdr: HdrPlan,
        requireStatic: Boolean,
        requireRange: Boolean,
    ) {
        if (!hdr.isHdr) return
        val actual = readTrackColor(file)
            ?: throw refusal(
                RENDER_UNSUPPORTED,
                "Exported HDR file has no readable video color metadata",
            )
        if (actual.colorStandard != hdr.colorStandard ||
            actual.colorTransfer != hdr.colorTransfer ||
            (requireRange && actual.colorRange != hdr.colorRange)
        ) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Exported color metadata (${actual.colorStandard}/${actual.colorTransfer}/${actual.colorRange}) " +
                    "does not match the ${hdr.label} source; HDR was not retained",
            )
        }
        if (requireStatic && hdr.hdrStaticInfo != null && !hdr.sameStaticInfo(actual.hdrStaticInfo)) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Exported HDR static metadata was not retained; the output was rejected",
            )
        }
    }

    /** Reads the first video track's color metadata; null when unreadable. */
    fun readTrackColor(file: File): TrackColor? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                return TrackColor(
                    colorStandard = format.integerOrNull(MediaFormat.KEY_COLOR_STANDARD),
                    colorTransfer = format.integerOrNull(MediaFormat.KEY_COLOR_TRANSFER),
                    colorRange = format.integerOrNull(MediaFormat.KEY_COLOR_RANGE),
                    hdrStaticInfo = format.staticInfo(),
                    mimeType = mime,
                    codecProfile = format.integerOrNull(MediaFormat.KEY_PROFILE),
                    dynamicHdrMetadataPresent = format.containsKey(MediaFormat.KEY_HDR10_PLUS_INFO) ||
                        format.containsKey(MediaFormat.KEY_HDR_ST2094_50_INFO),
                )
            }
            null
        } catch (_: Exception) {
            null
        } finally {
            runCatching { extractor.release() }
        }
    }

    private fun remux(
        source: File,
        destination: File,
        hdr: HdrPlan,
        isCancelled: () -> Boolean,
    ) {
        val extractor = MediaExtractor()
        val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            extractor.setDataSource(source.path)
            val trackMap = IntArray(extractor.trackCount) { -1 }
            var videoTrackSeen = false
            var maxSampleBytes = 4 * 1024 * 1024
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    if (videoTrackSeen) continue
                    videoTrackSeen = true
                    format.setInteger(MediaFormat.KEY_COLOR_STANDARD, hdr.colorStandard!!)
                    format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, hdr.colorTransfer!!)
                    format.setInteger(MediaFormat.KEY_COLOR_RANGE, hdr.colorRange!!)
                    hdr.hdrStaticInfo?.let {
                        format.setByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO, ByteBuffer.wrap(it))
                    }
                }
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxSampleBytes = max(maxSampleBytes, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
                trackMap[index] = muxer.addTrack(format)
            }
            if (!videoTrackSeen) {
                throw refusal(RENDER_UNSUPPORTED, "The encoded file has no video track to remux")
            }
            val rotation = readRotation(source)
            if (rotation != 0) muxer.setOrientationHint(rotation)
            muxer.start()
            for (index in 0 until extractor.trackCount) {
                if (trackMap[index] >= 0) extractor.selectTrack(index)
            }
            val buffer = ByteBuffer.allocateDirect(
                maxSampleBytes.coerceIn(1, 32 * 1024 * 1024),
            )
            val info = MediaCodec.BufferInfo()
            var samples = 0
            while (true) {
                if (isCancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
                val track = extractor.sampleTrackIndex
                if (track < 0) break
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val outputTrack = trackMap[track]
                if (outputTrack >= 0) {
                    info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
                    muxer.writeSampleData(outputTrack, buffer, info)
                }
                extractor.advance()
                samples += 1
                if (samples % 32 == 0 && isCancelled()) {
                    throw refusal(RENDER_CANCELLED, "Export was cancelled")
                }
            }
            muxer.stop()
        } finally {
            runCatching { muxer.release() }
            runCatching { extractor.release() }
        }
    }

    private fun readRotation(file: File): Int {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            val raw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            ((raw % 360) + 360) % 360
        } catch (_: Exception) {
            0
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun sizeAndRateSupported(
        info: android.media.MediaCodecInfo,
        mime: String,
        settings: VideoExportSettings,
    ): Boolean {
        return try {
            val video = info.getCapabilitiesForType(mime).videoCapabilities ?: return false
            video.isSizeSupported(settings.width, settings.height) &&
                video.areSizeAndRateSupported(settings.width, settings.height, settings.frameRate)
        } catch (_: Exception) {
            false
        }
    }

    private fun MediaFormat.integerOrNull(key: String): Int? =
        if (containsKey(key)) {
            try {
                getInteger(key)
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }

    private fun MediaFormat.staticInfo(): ByteArray? {
        val buffer = try {
            if (!containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) null else getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)
        } catch (_: Exception) {
            null
        } ?: return null
        return try {
            val copy = buffer.duplicate()
            copy.rewind()
            val bytes = ByteArray(copy.remaining())
            copy.get(bytes)
            bytes
        } catch (_: Exception) {
            null
        }
    }
}
