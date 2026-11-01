// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot
import com.floe.android.core.workbenchmedia.timeline.MediaTimeline
import com.floe.android.core.workbenchmedia.timeline.PlacedClip
import com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_CODEC
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.PreviewWindow
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoExportSettings
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import com.floe.android.feature.workbench.asset
import java.io.File
import kotlin.math.max
import kotlin.math.min

internal data class PlannedClip(
    val placed: PlacedClip,
    val clip: VideoClip,
    val asset: MediaAssetReference,
    val file: File,
    val probe: ProbedMedia,
)

internal data class PlannedMusic(
    val music: MusicClip,
    val asset: MediaAssetReference,
    val file: File,
    val probe: ProbedMedia,
    val offsetSeconds: Double,
    val lengthSeconds: Double,
    val trimStartSeconds: Double,
    val fadeInSeconds: Double,
    val fadeOutSeconds: Double,
)

internal data class CompositionPlan(
    val snapshot: VerifiedSnapshot,
    val clips: List<PlannedClip>,
    val music: List<PlannedMusic>,
    val captions: List<CaptionSegment>,
    val captionStyle: CaptionStyle,
    val durationSeconds: Double,
    val width: Int,
    val height: Int,
    val frameRate: Double,
    val codecMime: String,
    val quality: Double,
    val fileName: String,
    val window: PreviewWindow?,
    val coverTimeSeconds: Double?,
    val warnings: List<String>,
)

/**
 * Maps the actual typed `VideoTimeline` onto a Media3 composition plan and
 * refuses every case the pinned engine cannot render faithfully. The plan is
 * pure data (plus verified File handles); it opens no encoder and starts no
 * playback, so validation failures happen BEFORE the native project or any
 * output is touched.
 */
internal class CompositionPlanner(private val capabilities: MediaCapabilityProbe) {
    fun plan(
        snapshot: VerifiedSnapshot,
        settings: VideoExportSettings,
        window: PreviewWindow? = null,
        validateEncoding: Boolean = true,
    ): CompositionPlan {
        val project = snapshot.projection.project
        val timeline = snapshot.projection.timeline
        if (project.kind != "video") {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "The snapshot is not a video project")
        }
        if (project.canvas == null) {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Video project has no canvas")
        }
        if (timeline.clips.isEmpty()) {
            throw refusal(INVALID_PAYLOAD, "Add at least one clip before exporting")
        }
        if (!timeline.primaryVolume.isFinite() || timeline.primaryVolume < 0.0 || timeline.primaryVolume > 4.0) {
            throw refusal(INVALID_PAYLOAD, "Primary audio volume must be 0..4")
        }
        if (!timeline.captionStyle.fontSize.isFinite() || !timeline.captionStyle.positionY.isFinite() ||
            timeline.captionStyle.positionY < 0.0 || timeline.captionStyle.positionY > 1.0
        ) {
            throw refusal(INVALID_PAYLOAD, "Caption style values are invalid")
        }
        if (timeline.clips.size > MediaCapabilityProbe.MAX_CLIPS) {
            throw refusal(RENDER_UNSUPPORTED, "At most ${MediaCapabilityProbe.MAX_CLIPS} clips are supported")
        }
        val capabilitiesValue = capabilities.capabilities()
        if (validateEncoding) {
            validateSettings(settings)
            if (capabilitiesValue.encoders.isEmpty()) {
                throw refusal(RENDERER_UNAVAILABLE, "No platform video encoder is available")
            }
            if (capabilitiesValue.maxWidth > 0 && settings.width > capabilitiesValue.maxWidth ||
                capabilitiesValue.maxHeight > 0 && settings.height > capabilitiesValue.maxHeight
            ) {
                throw refusal(UNSUPPORTED_CODEC, "Requested resolution exceeds the actual encoder capability")
            }
            if (!capabilities.encoderSupportsVideo(
                    settings.codecMime, settings.width, settings.height, settings.frameRate,
                )
            ) {
                throw refusal(
                    UNSUPPORTED_CODEC,
                    "The requested encoder ${settings.codecMime} does not support ${settings.width}x${settings.height}@${settings.frameRate}",
                )
            }
            if ("mp4" !in capabilitiesValue.muxers ||
                !capabilities.supportsMuxerVideoMime(settings.codecMime)
            ) {
                throw refusal(
                    UNSUPPORTED_CODEC,
                    "The pinned MP4 muxer does not support the requested video sample format",
                )
            }
        }
        if (timeline.clips.any { it.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE }) {
            throw refusal(
                UNSUPPORTED_TRANSITION,
                "Cross-dissolve has no tested compositor in the pinned Media3 Transformer; no hard-cut substitution is made",
            )
        }

        val placed = MediaTimeline.placeClips(timeline.clips)
        val fullDuration = MediaTimeline.placedDuration(placed)
        if (fullDuration <= 0.05 || !fullDuration.isFinite()) {
            throw refusal(INVALID_PAYLOAD, "The timeline duration is invalid")
        }
        if (fullDuration > MediaCapabilityProbe.MAX_DURATION_SECONDS) {
            throw refusal(RENDER_UNSUPPORTED, "The timeline exceeds the 3600 s export limit")
        }

        val plannedClips = ArrayList<PlannedClip>(placed.size)
        val warnings = ArrayList<String>()
        for (item in placed) {
            validateClip(item.clip)
            val asset = project.asset(item.clip.assetID)
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip asset ${item.clip.assetID} is missing")
            if (asset.kind != "video") {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip asset ${asset.id} is not a video")
            }
            val file = MediaPaths.resolveExistingUnder(snapshot.root, asset.relativePath)
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip asset path is missing or escapes the media root")
            val probe = AssetProbe.probe(file, "video")
            val effectiveEnd = probe.durationSeconds?.let { min(item.clip.trimEnd, it) } ?: item.clip.trimEnd
            if (effectiveEnd <= item.clip.trimStart + 0.05) {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip source range is empty after probing")
            }
            if (probe.durationSeconds != null && item.clip.trimEnd > probe.durationSeconds + 0.05) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "Clip ${item.clip.id} trim end exceeds the measured source duration",
                )
            }
            val mime = probe.mimeType
            if (mime == null || !capabilities.hasVideoDecoder(mime)) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "No decoder is available for source ${mime ?: "unknown"}",
                )
            }
            val decodedW = probe.width
            val decodedH = probe.height
            if (!capabilities.decoderSupportsVideo(mime, decodedW, decodedH) &&
                !capabilities.decoderSupportsVideo(mime, decodedH, decodedW)
            ) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "The source decoder does not support ${decodedW}x$decodedH",
                )
            }
            plannedClips += PlannedClip(item, item.clip, asset, file, probe)
        }

        val hasAudiblePrimary = plannedClips.any { it.probe.hasAudio && !it.clip.isMuted && it.clip.volume > 0.0 } &&
            !timeline.primaryMuted && timeline.primaryVolume > 0.0
        val plannedMusic = planMusic(snapshot, timeline, fullDuration, warnings)
        val hasMusic = plannedMusic.isNotEmpty()
        if (validateEncoding && (hasAudiblePrimary || hasMusic) &&
            (!capabilities.hasAudioEncoder() || !capabilities.supportsMuxerAudioMime())
        ) {
            throw refusal(UNSUPPORTED_CODEC, "No muxable AAC audio path is available for the mixed audio output")
        }
        if (validateEncoding) {
            val knownSourceRates = plannedClips.mapNotNull { it.probe.frameRate?.takeIf { fps -> fps > 0.0 } }
            if (knownSourceRates.size != plannedClips.size) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "Source frame rate could not be measured for every clip; an explicit output frame rate cannot be guaranteed",
                )
            }
            val minimumRate = knownSourceRates.minOrNull() ?: settings.frameRate
            if (settings.frameRate > minimumRate + 0.5) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "Cannot increase ${minimumRate}fps source to ${settings.frameRate}fps with the pinned engine",
                )
            }
        }

        validateCaptions(timeline, fullDuration)
        val cover = MediaTimeline.coverTime(timeline.coverTime, fullDuration)
        val base = CompositionPlan(
            snapshot = snapshot,
            clips = plannedClips,
            music = plannedMusic,
            captions = timeline.captions,
            captionStyle = timeline.captionStyle,
            durationSeconds = fullDuration,
            width = settings.width,
            height = settings.height,
            frameRate = settings.frameRate,
            codecMime = settings.codecMime,
            quality = settings.quality,
            fileName = settings.fileName,
            window = null,
            coverTimeSeconds = cover,
            warnings = warnings,
        )
        return if (window == null) base else windowed(base, window)
    }

    private fun planMusic(
        snapshot: VerifiedSnapshot,
        timeline: VideoTimeline,
        timelineDuration: Double,
        warnings: MutableList<String>,
    ): List<PlannedMusic> {
        val result = ArrayList<PlannedMusic>()
        for (item in timeline.music) {
            if (!item.offsetSeconds.isFinite() || !item.trimStart.isFinite() || !item.lengthSeconds.isFinite() ||
                !item.fadeInSeconds.isFinite() || !item.fadeOutSeconds.isFinite()
            ) {
                throw refusal(INVALID_PAYLOAD, "Music times must be finite")
            }
            if (item.offsetSeconds > timelineDuration + 0.05) {
                throw refusal(INVALID_PAYLOAD, "A music clip starts after the video ends")
            }
            if (item.volume < 0.0 || item.volume > 4.0) {
                throw refusal(INVALID_PAYLOAD, "Music volume must be 0..4")
            }
            val asset = snapshot.projection.project.asset(item.assetID)
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music asset ${item.assetID} is missing")
            if (asset.kind != "audio") {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music asset ${asset.id} is not audio")
            }
            val file = MediaPaths.resolveExistingUnder(snapshot.root, asset.relativePath)
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music asset path is missing or escapes the media root")
            val probe = AssetProbe.probe(file, "audio")
            val requestedStart = max(0.0, item.offsetSeconds)
            val requestedEnd = min(requestedStart + max(0.0, item.lengthSeconds), timelineDuration)
            var start = requestedStart
            var end = requestedEnd
            if (probe.durationSeconds != null && item.trimStart >= probe.durationSeconds - 0.05) {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music trim start is beyond the source duration")
            }
            if (probe.durationSeconds != null) {
                val available = max(0.0, probe.durationSeconds - item.trimStart)
                if (end - start > available + 0.05) {
                    end = start + available
                    warnings += "Music ${item.id} was clamped to the source duration"
                }
            }
            if (end - start <= 0.05) continue
            val fadeIn = item.fadeInSeconds.coerceIn(0.0, max(0.0, end - start))
            val fadeOut = item.fadeOutSeconds.coerceIn(0.0, max(0.0, end - start))
            result += PlannedMusic(
                music = item,
                asset = asset,
                file = file,
                probe = probe,
                offsetSeconds = start,
                lengthSeconds = end - start,
                trimStartSeconds = max(0.0, item.trimStart),
                fadeInSeconds = fadeIn,
                fadeOutSeconds = fadeOut,
            )
        }
        return result
    }

    private fun validateSettings(settings: VideoExportSettings) {
        if (settings.width < 2 || settings.height < 2 || settings.width > 8192 || settings.height > 8192 ||
            settings.width % 2 != 0 || settings.height % 2 != 0
        ) {
            throw refusal(INVALID_PAYLOAD, "Video dimensions must be even and 2..8192 px")
        }
        if (!settings.frameRate.isFinite() || settings.frameRate <= 0.0 || settings.frameRate > 240.0) {
            throw refusal(INVALID_PAYLOAD, "Frame rate must be in (0, 240]")
        }
        if (!settings.quality.isFinite() || settings.quality < 0.01 || settings.quality > 1.0) {
            throw refusal(INVALID_PAYLOAD, "Export quality must be 0.01...1")
        }
        if (settings.codecMime.isBlank() || !settings.codecMime.startsWith("video/")) {
            throw refusal(UNSUPPORTED_CODEC, "An actual video encoder MIME is required")
        }
        if (settings.fileName.length > 255) {
            throw refusal(INVALID_PAYLOAD, "File name is too long")
        }
    }

    private fun validateClip(clip: VideoClip) {
        if (!clip.trimStart.isFinite() || !clip.trimEnd.isFinite() || !clip.speed.isFinite() ||
            !clip.volume.isFinite() || !clip.rotationDegrees.isFinite() || !clip.transitionDuration.isFinite()
        ) {
            throw refusal(INVALID_PAYLOAD, "Clip values must be finite")
        }
        if (clip.trimStart < 0.0 || clip.trimEnd <= clip.trimStart + 0.05) {
            throw refusal(INVALID_PAYLOAD, "Clip source range is invalid")
        }
        if (clip.speed < 0.1 || clip.speed > 16.0) {
            throw refusal(INVALID_PAYLOAD, "Clip speed must be 0.1..16")
        }
        if (clip.volume < 0.0 || clip.volume > 4.0) {
            throw refusal(INVALID_PAYLOAD, "Clip volume must be 0..4")
        }
        clip.crop?.let { crop ->
            if (!crop.x.isFinite() || !crop.y.isFinite() || !crop.width.isFinite() || !crop.height.isFinite() ||
                crop.x < 0.0 || crop.y < 0.0 || crop.width <= 0.0 || crop.height <= 0.0 ||
                crop.x + crop.width > 1.0001 || crop.y + crop.height > 1.0001
            ) {
                throw refusal(INVALID_PAYLOAD, "Clip crop must be a valid normalized rect")
            }
        }
    }

    private fun validateCaptions(timeline: VideoTimeline, duration: Double) {
        for (caption in timeline.captions) {
            if (!caption.start.isFinite() || !caption.end.isFinite() || caption.end <= caption.start) {
                throw refusal(INVALID_PAYLOAD, "Caption times are invalid")
            }
            if (caption.end > duration + 0.05) {
                throw refusal(INVALID_PAYLOAD, "A caption ends after the timeline")
            }
            if (caption.text.toByteArray(Charsets.UTF_8).size > 2_000) {
                throw refusal(INVALID_PAYLOAD, "Caption text exceeds 2000 bytes")
            }
        }
    }

    /**
     * Playback plan: same clips/music/captions mapping, but no encoder/bitrate
     * or output-fps promise (CompositionPlayer plays the source cadence). The
     * canvas dimensions still drive aspect-fit; source decode validity and
     * the cross-dissolve refusal still apply.
     */
    fun planForPlayback(snapshot: VerifiedSnapshot): CompositionPlan {
        val canvas = snapshot.projection.project.canvas
            ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Video project has no canvas")
        val settings = VideoExportSettings(
            codecMime = "video/avc",
            width = canvas.width,
            height = canvas.height,
            frameRate = 240.0,
            quality = 0.5,
            fileName = "playback",
        )
        return plan(snapshot, settings, validateEncoding = false)
    }

    private fun windowed(plan: CompositionPlan, window: PreviewWindow): CompositionPlan {
        if (!window.startSeconds.isFinite() || !window.durationSeconds.isFinite() ||
            window.startSeconds < 0.0 || window.durationSeconds <= 0.0
        ) {
            throw refusal(INVALID_PAYLOAD, "Preview window is invalid")
        }
        val start = max(0.0, window.startSeconds)
        val end = min(plan.durationSeconds, start + window.durationSeconds)
        if (end - start <= 0.05) throw refusal(INVALID_PAYLOAD, "Preview window is outside the timeline")
        val clips = plan.clips.mapNotNull { planned ->
            val left = max(planned.placed.timelineStart, start)
            val right = min(planned.placed.timelineEnd, end)
            if (right - left <= 0.01) return@mapNotNull null
            val sourceStart = planned.clip.trimStart + (left - planned.placed.timelineStart) * planned.clip.speed
            val sourceEnd = planned.clip.trimStart + (right - planned.placed.timelineStart) * planned.clip.speed
            val clip = planned.clip.copy(
                trimStart = sourceStart,
                trimEnd = sourceEnd,
                leadingTransition = VideoTransitionKind.NONE,
            )
            planned.copy(
                placed = PlacedClip(clip, left - start, right - start),
                clip = clip,
            )
        }
        if (clips.isEmpty()) throw refusal(INVALID_PAYLOAD, "Preview window selects no clips")
        val music = plan.music.mapNotNull { planned ->
            val left = max(planned.offsetSeconds, start)
            val right = min(planned.offsetSeconds + planned.lengthSeconds, end)
            if (right - left <= 0.05) return@mapNotNull null
            val originalEnd = planned.offsetSeconds + planned.lengthSeconds
            val trimmedOut = left - planned.offsetSeconds
            planned.copy(
                offsetSeconds = left - start,
                lengthSeconds = right - left,
                trimStartSeconds = planned.trimStartSeconds + trimmedOut,
                fadeInSeconds = (planned.fadeInSeconds - trimmedOut).coerceIn(0.0, right - left),
                fadeOutSeconds = (planned.fadeOutSeconds - (originalEnd - right)).coerceIn(0.0, right - left),
            )
        }
        val captions = plan.captions.mapNotNull { caption ->
            val left = max(caption.start, start)
            val right = min(caption.end, end)
            if (right - left <= 0.01) null else caption.copy(start = left - start, end = right - start)
        }
        val cover = plan.coverTimeSeconds?.let { if (it in start..end) it - start else null }
        return plan.copy(
            clips = clips,
            music = music,
            captions = captions,
            durationSeconds = end - start,
            window = window,
            coverTimeSeconds = cover,
        )
    }
}
