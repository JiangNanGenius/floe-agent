// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.capability

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.DefaultMuxer
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.feature.workbench.CodecCapability
import com.floe.android.feature.workbench.RenderCapabilities
import kotlin.math.min

/**
 * Actual platform/engine capability probe. It never promises a universal
 * codec and never reports an encoder that `MediaCodecList` did not expose.
 *
 * This hardware probe alone does not bind composition or image writers.
 * Media3WorkbenchMediaPlatform adds its actual GL compositor and HeifWriter
 * capability checks before exposing the combined rendering surface.
 */
internal class MediaCapabilityProbe(
    private val clock: MediaClock,
) {
    internal data class CodecEntry(
        val mimeType: String,
        val isEncoder: Boolean,
        val hardwareAccelerated: Boolean,
        val video: MediaCodecInfo.VideoCapabilities?,
        val capability: CodecCapability,
    )

    @Volatile private var cached: RenderCapabilities? = null
    @Volatile private var entries: List<CodecEntry> = emptyList()
    @Volatile private var muxerVideoMimes: Set<String> = emptySet()
    @Volatile private var muxerAudioMimes: Set<String> = emptySet()

    fun capabilities(forceRefresh: Boolean = false): RenderCapabilities {
        cached?.let { if (!forceRefresh) return it }
        synchronized(this) {
            cached?.let { if (!forceRefresh) return it }
            val probed = probe()
            cached = probed.first
            entries = probed.second
            return probed.first
        }
    }

    fun encoderSupportsVideo(mime: String, width: Int, height: Int, frameRate: Double): Boolean =
        entries.filter { it.isEncoder && it.mimeType == mime }.any { entry ->
            val video = entry.video ?: return@any false
            supports(video, width, height, frameRate)
        }

    fun decoderSupportsVideo(mime: String, width: Int, height: Int): Boolean =
        entries.filter { !it.isEncoder && it.mimeType == mime }.any { entry ->
            val video = entry.video ?: return@any false
            supports(video, width, height, frameRate = 0.0)
        }

    fun hasAudioEncoder(mime: String = MimeTypes.AUDIO_AAC): Boolean =
        entries.any { it.isEncoder && it.mimeType == mime }

    fun hasVideoDecoder(mime: String): Boolean = entries.any { !it.isEncoder && it.mimeType == mime }

    fun supportsMuxerVideoMime(mime: String): Boolean = mime in muxerVideoMimes

    fun supportsMuxerAudioMime(mime: String = MimeTypes.AUDIO_AAC): Boolean = mime in muxerAudioMimes

    private fun supports(video: MediaCodecInfo.VideoCapabilities, width: Int, height: Int, frameRate: Double): Boolean =
        try {
            val sizeOk = video.isSizeSupported(width, height)
            if (!sizeOk) false
            else if (frameRate > 0.0) video.areSizeAndRateSupported(width, height, frameRate) else true
        } catch (_: IllegalArgumentException) {
            false
        }

    private fun probe(): Pair<RenderCapabilities, List<CodecEntry>> {
        val codecEntries = ArrayList<CodecEntry>()
        val encoders = LinkedHashMap<String, CodecCapability>()
        val decoders = LinkedHashMap<String, CodecCapability>()
        try {
            val infos = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            for (info in infos) {
                for (mime in info.supportedTypes) {
                    val isVideo = mime.startsWith("video/")
                    val isAudio = mime.startsWith("audio/")
                    if (!isVideo && !isAudio) continue
                    val videoCaps = if (isVideo) {
                        try {
                            info.getCapabilitiesForType(mime).videoCapabilities
                        } catch (_: Exception) {
                            null
                        }
                    } else {
                        null
                    }
                    if (isVideo && videoCaps == null) continue
                    val hardware = if (android.os.Build.VERSION.SDK_INT >= 29) {
                        try {
                            info.isHardwareAccelerated
                        } catch (_: Exception) {
                            false
                        }
                    } else {
                        false
                    }
                    var maxWidth = 0
                    var maxHeight = 0
                    var maxFps = 0.0
                    if (videoCaps != null) {
                        maxWidth = safeUpper(videoCaps.supportedWidths)
                        maxHeight = safeUpper(videoCaps.supportedHeights)
                        maxFps = try {
                            val rates = videoCaps.getSupportedFrameRatesFor(
                                maxWidth.coerceAtLeast(2), maxHeight.coerceAtLeast(2))
                            rates.upper ?: 0.0
                        } catch (_: Exception) {
                            0.0
                        }
                    }
                    if (isVideo) {
                        maxWidth = min(maxWidth, MAX_REPORTED_EDGE)
                        maxHeight = min(maxHeight, MAX_REPORTED_EDGE)
                    }
                    val capability = CodecCapability(
                        mimeType = mime,
                        isEncoder = info.isEncoder,
                        hardwareAccelerated = hardware,
                        maxWidth = if (isVideo) maxWidth else 0,
                        maxHeight = if (isVideo) maxHeight else 0,
                        maxFrameRate = if (isVideo) maxFps else 0.0,
                    )
                    codecEntries += CodecEntry(
                        mimeType = mime,
                        isEncoder = info.isEncoder,
                        hardwareAccelerated = hardware,
                        video = videoCaps,
                        capability = capability,
                    )
                    val target = if (info.isEncoder) encoders else decoders
                    val previous = target[mime]
                    target[mime] = if (previous == null) capability else merge(previous, capability)
                }
            }
        } catch (failure: Exception) {
            // A failed platform enumeration must not invent codecs. The caller
            // receives an empty capability surface with the actual reason.
            entries = emptyList()
            muxerVideoMimes = emptySet()
            muxerAudioMimes = emptySet()
            return RenderCapabilities(
                encoders = emptyList(),
                decoders = emptyList(),
                muxers = emptyList(),
                imageFormats = listOf("png", "jpeg"),
                heicSupported = false,
                crossDissolveSupported = false,
                maxWidth = 0,
                maxHeight = 0,
                maxFrameRate = 0.0,
                maxDurationSeconds = MAX_DURATION_SECONDS,
                maxClips = MAX_CLIPS,
                maxOutputBytes = MAX_OUTPUT_BYTES,
                unavailableReasons = mapOf(
                    "codec.probe" to "The platform codec list could not be read: ${failure.message}",
                ),
                probedAt = clock.nowIso(),
            ) to emptyList()
        }

        val videoEncoders = encoders.values.filter { it.mimeType.startsWith("video/") }
        val videoDecoders = decoders.values.filter { it.mimeType.startsWith("video/") }
        val maxWidth = videoEncoders.maxOfOrNull { it.maxWidth } ?: 0
        val maxHeight = videoEncoders.maxOfOrNull { it.maxHeight } ?: 0
        val maxFps = videoEncoders.maxOfOrNull { it.maxFrameRate } ?: 0.0

        val muxers = ArrayList<String>()
        val reasons = LinkedHashMap<String, String>()
        val muxerFactory = runCatching { DefaultMuxer.Factory() }.getOrNull()
        val muxerMimes = try {
            muxerFactory?.getSupportedSampleMimeTypes(C.TRACK_TYPE_VIDEO)
        } catch (_: Exception) {
            null
        }
        val muxerAudio = try {
            muxerFactory?.getSupportedSampleMimeTypes(C.TRACK_TYPE_AUDIO)
        } catch (_: Exception) {
            null
        }
        muxerVideoMimes = muxerMimes?.toSet() ?: emptySet()
        muxerAudioMimes = muxerAudio?.toSet() ?: emptySet()
        if (muxerVideoMimes.isNotEmpty()) {
            muxers += "mp4"
        } else {
            reasons["muxer.mp4"] = "The pinned in-app MP4 muxer did not report a supported video sample format"
        }
        if (!hasAudioEncoder(MimeTypes.AUDIO_AAC)) {
            reasons["audio.aac"] = "No AAC encoder is available for a mixed-audio MP4 output"
        }
        if (videoEncoders.isEmpty()) {
            reasons["codec.videoEncoder"] = "The device exposed no video encoder"
        }
        reasons["image.heic"] = "HEIC export is not implemented in this source stage; PNG/JPEG are the offered image outputs"
        reasons["transition.crossDissolve"] = "Cross dissolve requires the bound Media3 composition adapter"

        val result = RenderCapabilities(
            encoders = encoders.values.toList(),
            decoders = decoders.values.toList(),
            muxers = muxers,
            imageFormats = listOf("png", "jpeg"),
            heicSupported = false,
            crossDissolveSupported = false,
            maxWidth = maxWidth,
            maxHeight = maxHeight,
            maxFrameRate = maxFps,
            maxDurationSeconds = MAX_DURATION_SECONDS,
            maxClips = MAX_CLIPS,
            maxOutputBytes = MAX_OUTPUT_BYTES,
            unavailableReasons = reasons,
            probedAt = clock.nowIso(),
        )
        return result to codecEntries
    }

    private fun safeUpper(range: android.util.Range<Int>?): Int = try {
        range?.upper ?: 0
    } catch (_: Exception) {
        0
    }

    private fun merge(a: CodecCapability, b: CodecCapability): CodecCapability = a.copy(
        hardwareAccelerated = a.hardwareAccelerated || b.hardwareAccelerated,
        maxWidth = maxOf(a.maxWidth, b.maxWidth),
        maxHeight = maxOf(a.maxHeight, b.maxHeight),
        maxFrameRate = maxOf(a.maxFrameRate, b.maxFrameRate),
    )

    companion object {
        const val MAX_REPORTED_EDGE = 8192
        const val MAX_DURATION_SECONDS = 3_600.0
        const val MAX_CLIPS = 24
        const val MAX_OUTPUT_BYTES = 8L * 1024L * 1024L * 1024L
    }
}
