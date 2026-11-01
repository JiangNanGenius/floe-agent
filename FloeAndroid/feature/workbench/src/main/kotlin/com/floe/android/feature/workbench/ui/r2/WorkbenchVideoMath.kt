// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTimeline
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** One clip placed on the unified timeline after speed retiming. */
data class PlacedVideoClip(
    val clip: VideoClip,
    val timelineStart: Double,
    val timelineEnd: Double,
) {
    val duration: Double get() = (timelineEnd - timelineStart).coerceAtLeast(0.0)
}

/**
 * Pure UI-side projection of the shared timeline math
 * (`FloeAgent/Sources/FloeWorkbench/MediaTimelineMath.swift`).
 *
 * This is presentation math only: the native transaction engine remains the
 * authority for every stored value. It exists so the playhead, captions,
 * music and dissolve windows line up with the renderer instead of using a
 * second, subtly different time base.
 */
object WorkbenchVideoMath {
    const val MIN_CLIP_DURATION = 0.05
    const val MIN_CAPTION_DURATION = 0.01
    const val MAX_MUSIC_LENGTH = 3600.0

    fun timelineDuration(clip: VideoClip): Double {
        val source = (clip.trimEnd - clip.trimStart).coerceAtLeast(0.0)
        val speed = if (clip.speed.isFinite() && clip.speed > 0.0) clip.speed else 1.0
        return source / speed
    }

    /**
     * Places clips on the timeline. A leading cross-dissolve overlaps the head
     * of a clip with the tail of its predecessor and contracts the timeline by
     * that overlap, matching the shared engine.
     */
    fun placeClips(clips: List<VideoClip>): List<PlacedVideoClip> {
        var cursor = 0.0
        return clips.mapIndexed { index, clip ->
            val duration = timelineDuration(clip)
            var start = cursor
            if (index > 0 &&
                clip.leadingTransition == com.floe.android.feature.workbench.VideoTransitionKind.CROSS_DISSOLVE
            ) {
                val overlap = minOf(clip.transitionDuration, duration, cursor)
                start -= max(0.0, overlap)
            }
            val placed = PlacedVideoClip(
                clip = clip,
                timelineStart = max(0.0, start),
                timelineEnd = max(0.0, start) + duration,
            )
            cursor = placed.timelineEnd
            placed
        }
    }

    fun timelineEnd(timeline: VideoTimeline): Double =
        placeClips(timeline.clips).lastOrNull()?.timelineEnd ?: 0.0

    /** Sum of retimed clip durations, matching the shared `primaryDuration`. */
    fun primaryDuration(timeline: VideoTimeline): Double =
        timeline.clips.sumOf { timelineDuration(it) }

    /** Playhead duration: the placed tail, or 0 for an empty timeline. */
    fun duration(timeline: VideoTimeline): Double = timelineEnd(timeline)

    fun clipAt(seconds: Double, placed: List<PlacedVideoClip>): PlacedVideoClip? =
        placed.firstOrNull { seconds >= it.timelineStart && seconds < it.timelineEnd }

    fun captionAt(seconds: Double, captions: List<CaptionSegment>): CaptionSegment? =
        captions.firstOrNull { seconds >= it.start && seconds <= it.end }

    /**
     * Offset within a clip for `splitClip`, clamped to the engine's minimum
     * edge margin. Returns null when the playhead is outside the clip.
     */
    fun splitOffset(
        playheadSeconds: Double,
        placed: PlacedVideoClip?,
    ): Double? {
        if (placed == null || placed.duration <= MIN_CLIP_DURATION * 2) return null
        val local = playheadSeconds - placed.timelineStart
        if (local < 0.0 || local > placed.duration) return null
        return local.coerceIn(0.01, placed.duration - 0.02)
    }

    fun snapCandidates(timeline: VideoTimeline): List<Double> {
        val values = ArrayList<Double>()
        values += 0.0
        for (placed in placeClips(timeline.clips)) {
            values += placed.timelineStart
            values += placed.timelineEnd
        }
        for (music in timeline.music) {
            values += music.offsetSeconds
            values += music.offsetSeconds + music.lengthSeconds
        }
        for (caption in timeline.captions) {
            values += caption.start
            values += caption.end
        }
        return values.filter { it.isFinite() && it >= 0.0 }.distinct().sorted()
    }

    fun snap(seconds: Double, candidates: List<Double>, tolerance: Double = 0.08): Double {
        var best = seconds
        var distance = tolerance
        for (candidate in candidates) {
            val delta = abs(candidate - seconds)
            if (delta <= distance) {
                distance = delta
                best = candidate
            }
        }
        return best
    }

    fun quantizeSourceTime(seconds: Double, frameRate: Double): Double {
        val fps = if (frameRate.isFinite() && frameRate > 0.0) frameRate else 30.0
        return ((seconds * fps).roundToLong()).toDouble() / fps
    }

    fun frameStep(
        seconds: Double,
        deltaFrames: Int,
        frameRate: Double,
        duration: Double,
    ): Double {
        val fps = if (frameRate.isFinite() && frameRate > 0.0) frameRate else 30.0
        val frame = (max(0.0, seconds) * fps).roundToLong()
        val next = max(0L, frame + deltaFrames) / fps
        return min(max(0.0, next), max(0.0, duration))
    }

    /** Exact `HH:MM:SS:FF` timecode for a timeline position. */
    fun timecode(seconds: Double, frameRate: Double): String {
        val fps = if (frameRate.isFinite() && frameRate > 0.0) frameRate else 30.0
        val roundedFps = max(1, fps.roundToLong().toInt())
        val totalFrames = (max(0.0, seconds) * fps).roundToLong()
        val framesPerHour = max(1L, (fps * 3600.0).roundToLong())
        val framesPerMinute = max(1L, (fps * 60.0).roundToLong())
        val hours = totalFrames / framesPerHour
        val minutes = (totalFrames % framesPerHour) / framesPerMinute
        val secondsPart = (totalFrames % framesPerMinute) / roundedFps
        val frames = totalFrames % roundedFps
        return String.format(Locale.US, "%02d:%02d:%02d:%02d", hours, minutes, secondsPart, frames)
    }

    fun formatSeconds(seconds: Double): String =
        String.format(Locale.US, "%.1fs", seconds.coerceAtLeast(0.0))

    /**
     * Centered normalized crop for [aspect] (width / height). Mirrors the
     * shared clip crop preset semantics; null/unknown dimensions return the
     * unchanged unit rect and the caller must not issue a crop command.
     */
    fun centeredCrop(
        aspect: Double,
        sourceWidth: Int,
        sourceHeight: Int,
    ): NormalizedRect? {
        if (!aspect.isFinite() || aspect <= 0.0 || sourceWidth <= 0 || sourceHeight <= 0) {
            return null
        }
        val sourceAspect = sourceWidth.toDouble() / sourceHeight.toDouble()
        return if (sourceAspect > aspect) {
            val width = aspect / sourceAspect
            NormalizedRect(x = (1.0 - width) / 2.0, y = 0.0, width = width, height = 1.0)
        } else {
            val height = sourceAspect / aspect
            NormalizedRect(x = 0.0, y = (1.0 - height) / 2.0, width = 1.0, height = height)
        }
    }

    /** True when the timeline contains an edit the actual renderer refuses. */
    fun hasCrossDissolve(timeline: VideoTimeline): Boolean =
        timeline.clips.any {
            it.leadingTransition ==
                com.floe.android.feature.workbench.VideoTransitionKind.CROSS_DISSOLVE
        }
}
