// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.timeline

import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

data class PlacedClip(
    val clip: VideoClip,
    val timelineStart: Double,
    val timelineEnd: Double,
) {
    val duration: Double get() = timelineEnd - timelineStart
}

data class PlacedMusic(
    val music: MusicClip,
    val timelineStart: Double,
    val timelineEnd: Double,
)

data class DissolveWindow(
    val fromClipID: String,
    val toClipID: String,
    val start: Double,
    val end: Double,
) {
    val duration: Double get() = end - start
}

/**
 * Kotlin port of the actual Swift `MediaTimelineMath` placement semantics
 * (`FloeAgent/Sources/FloeWorkbench/MediaTimelineMath.swift` at 10fc0083).
 * Pure functions only: no player, no encoder, no wall clock. The same
 * placements drive playback planning, export and verification expectations.
 *
 * Cross-dissolve placements also drive the shared preview/export composition.
 * Unsupported HDR or multi-clip overlap cases are refused by the planner;
 * a transition is never silently replaced with a hard cut.
 */
object MediaTimeline {
    const val MIN_DURATION = 0.0001

    fun clipDuration(clip: VideoClip): Double {
        val source = max(0.0, clip.trimEnd - clip.trimStart)
        return source / max(clip.speed.coerceAtLeast(MIN_DURATION), MIN_DURATION)
    }

    fun timelineDuration(timeline: VideoTimeline): Double = timeline.clips.sumOf(::clipDuration)

    fun placeClips(clips: List<VideoClip>): List<PlacedClip> {
        var cursor = 0.0
        val placed = ArrayList<PlacedClip>(clips.size)
        clips.forEachIndexed { index, clip ->
            val duration = clipDuration(clip)
            var start = cursor
            if (index > 0 && clip.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE) {
                val overlap = min(clip.transitionDuration, min(duration, cursor))
                start -= max(0.0, overlap)
            }
            val timelineStart = max(0.0, start)
            val element = PlacedClip(clip, timelineStart, timelineStart + duration)
            placed += element
            cursor = element.timelineEnd
        }
        return placed
    }

    fun placeMusic(music: List<MusicClip>, timelineEnd: Double): List<PlacedMusic> = music.mapNotNull { item ->
        if (!item.offsetSeconds.isFinite() || !item.lengthSeconds.isFinite()) return@mapNotNull null
        val start = max(0.0, item.offsetSeconds)
        val end = min(start + max(0.0, item.lengthSeconds), max(0.0, timelineEnd))
        if (end - start <= 0.05) null else PlacedMusic(item, start, end)
    }

    fun dissolveWindows(placed: List<PlacedClip>): List<DissolveWindow> {
        val windows = ArrayList<DissolveWindow>()
        for (index in 1 until placed.size) {
            val current = placed[index]
            if (current.clip.leadingTransition != VideoTransitionKind.CROSS_DISSOLVE) continue
            val previous = placed[index - 1]
            val overlap = min(current.clip.transitionDuration, min(current.duration, previous.duration))
            if (overlap <= 0.05) continue
            windows += DissolveWindow(
                fromClipID = previous.clip.id,
                toClipID = current.clip.id,
                start = current.timelineStart,
                end = current.timelineStart + overlap,
            )
        }
        return windows
    }

    fun sourceTime(placed: PlacedClip, timelineSeconds: Double): Double? {
        if (timelineSeconds < placed.timelineStart || timelineSeconds > placed.timelineEnd) return null
        val local = timelineSeconds - placed.timelineStart
        return placed.clip.trimStart + local * placed.clip.speed
    }

    fun clipAt(seconds: Double, placed: List<PlacedClip>): PlacedClip? =
        placed.firstOrNull { seconds >= it.timelineStart && seconds < it.timelineEnd }
            ?: placed.lastOrNull { it.duration > 0 }

    fun captionAt(seconds: Double, captions: List<CaptionSegment>): CaptionSegment? =
        captions.firstOrNull { seconds >= it.start && seconds <= it.end }

    fun primaryDuration(timeline: VideoTimeline): Double = timelineDuration(timeline)

    fun placedDuration(placed: List<PlacedClip>): Double = placed.lastOrNull()?.timelineEnd ?: 0.0

    /**
     * The explicit cover time is clamped into the primary timeline; a
     * non-finite request is not guessed. `null` means the UI may derive the
     * first visual frame, exactly like the shared model.
     */
    fun coverTime(requested: Double?, timelineDuration: Double): Double? {
        if (requested == null || !requested.isFinite() || timelineDuration <= 0.0) return null
        return min(max(0.0, requested), timelineDuration)
    }

    /**
     * Splits at a timeline offset within the clip. Returns source seconds.
     * Throws [IllegalArgumentException] when the split is too close to an edge
     * (the native transaction engine owns the final validation).
     */
    fun splitPoint(clip: VideoClip, withinClipSeconds: Double): Double {
        val sourceSeconds = clip.trimStart + withinClipSeconds * clip.speed
        require(sourceSeconds > clip.trimStart + 0.05 && sourceSeconds < clip.trimEnd - 0.05) {
            "Split point is too close to a clip edge"
        }
        return sourceSeconds
    }

    fun retimeCaptions(
        captions: List<CaptionSegment>,
        placedAfter: PlacedClip,
        previousDuration: Double,
    ): List<CaptionSegment> {
        val delta = placedAfter.duration - previousDuration
        if (abs(delta) <= 0.001) return captions
        val boundary = placedAfter.timelineStart + min(previousDuration, placedAfter.duration)
        return captions.map { caption ->
            if (caption.start >= boundary - 0.001) {
                val start = max(0.0, caption.start + delta)
                caption.copy(start = start, end = max(start + 0.01, caption.end + delta))
            } else {
                caption
            }
        }
    }

    fun shiftCaptions(
        captions: List<CaptionSegment>,
        bySeconds: Double,
        duration: Double,
    ): List<CaptionSegment> {
        if (!bySeconds.isFinite() || bySeconds == 0.0) return captions
        return captions.mapNotNull { caption ->
            val start = max(0.0, caption.start + bySeconds)
            if (start >= duration + 0.5) return@mapNotNull null
            val end = min(max(start + 0.01, caption.end + bySeconds), max(duration, start + 0.01))
            caption.copy(start = start, end = end)
        }
    }

    /** Frame-step math used by the transport bar; clamped to `0..duration`. */
    fun frameStep(seconds: Double, deltaFrames: Int, frameRate: Double, duration: Double): Double {
        val fps = if (frameRate > 0) frameRate else 30.0
        val frame = (max(0.0, seconds) * fps).toLong()
        val next = (frame + deltaFrames).coerceAtLeast(0L) / fps
        return min(max(0.0, next), max(0.0, duration))
    }
}
