// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.workbench.CaptionAlignment
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoEditCommand
import com.floe.android.feature.workbench.VideoTransitionKind
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/**
 * Builders for the frozen R2 [VideoEditCommand] vocabulary.
 *
 * The UI clamps only to values the shared engine already documents, and every
 * user action becomes ONE command batch. It never rewrites
 * `project.videoTimeline` JSON and never invents an unsupported command.
 */
object VideoCommandPlanner {
    const val MIN_CLIP_SECONDS = 0.2
    const val MAX_MUSIC_SECONDS = 3600.0

    fun appendClip(
        assetID: String,
        sourceDurationSeconds: Double,
        id: String = UUID.randomUUID().toString(),
    ): VideoEditCommand.AppendClip {
        val duration = sourceDurationSeconds.coerceIn(MIN_CLIP_SECONDS, 24.0 * 3600.0)
        return VideoEditCommand.AppendClip(
            VideoClip(
                id = id,
                assetID = assetID,
                trimStart = 0.0,
                trimEnd = duration,
            ),
        )
    }

    fun updateClip(
        id: String,
        trimStart: Double? = null,
        trimEnd: Double? = null,
        speed: Double? = null,
        volume: Double? = null,
        isMuted: Boolean? = null,
        rotationDegrees: Double? = null,
        crop: OptionalUpdate<NormalizedRect> = OptionalUpdate.Unchanged,
        leadingTransition: VideoTransitionKind? = null,
        transitionDuration: Double? = null,
    ): VideoEditCommand.UpdateClip = VideoEditCommand.UpdateClip(
        id = id,
        trimStart = trimStart?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
        trimEnd = trimEnd?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
        speed = speed?.takeIf { it.isFinite() }?.coerceIn(0.1, 16.0),
        volume = volume?.takeIf { it.isFinite() }?.coerceIn(0.0, 4.0),
        isMuted = isMuted,
        rotationDegrees = rotationDegrees?.takeIf { it in ROTATIONS },
        crop = crop,
        leadingTransition = leadingTransition,
        transitionDuration = transitionDuration?.takeIf { it.isFinite() }?.coerceIn(0.1, 2.0),
    )

    fun split(id: String, atTimelineSeconds: Double): VideoEditCommand.SplitClip =
        VideoEditCommand.SplitClip(id, atTimelineSeconds.coerceAtLeast(0.0))

    fun duplicate(id: String): VideoEditCommand.DuplicateClip =
        VideoEditCommand.DuplicateClip(id)

    fun remove(id: String): VideoEditCommand.RemoveClip =
        VideoEditCommand.RemoveClip(id)

    /** One-step reorder; returns null when [id] is already at the edge. */
    fun moveClip(
        clips: List<VideoClip>,
        id: String,
        earlier: Boolean,
    ): VideoEditCommand.ReorderClips? {
        val index = clips.indexOfFirst { it.id == id }
        if (index < 0) return null
        val target = if (earlier) index - 1 else index + 1
        if (target !in clips.indices) return null
        val ordered = clips.map { it.id }.toMutableList()
        val moved = ordered.removeAt(index)
        ordered.add(target, moved)
        return VideoEditCommand.ReorderClips(ordered)
    }

    fun setPrimaryAudio(
        volume: Double? = null,
        muted: Boolean? = null,
    ): VideoEditCommand.SetPrimaryAudio = VideoEditCommand.SetPrimaryAudio(
        volume = volume?.takeIf { it.isFinite() }?.coerceIn(0.0, 4.0),
        muted = muted,
    )

    fun setCover(time: Double?): VideoEditCommand.SetCover =
        VideoEditCommand.SetCover(time?.takeIf { it.isFinite() }?.coerceAtLeast(0.0))

    fun shiftCaptions(bySeconds: Double): VideoEditCommand.ShiftCaptions =
        VideoEditCommand.ShiftCaptions(bySeconds.coerceIn(-86_400.0, 86_400.0))

    fun addMusic(
        assetID: String,
        sourceDurationSeconds: Double,
        id: String = UUID.randomUUID().toString(),
    ): VideoEditCommand.AddMusic {
        val duration = sourceDurationSeconds.coerceIn(0.1, MAX_MUSIC_SECONDS)
        return VideoEditCommand.AddMusic(
            MusicClip(
                id = id,
                assetID = assetID,
                offsetSeconds = 0.0,
                trimStart = 0.0,
                lengthSeconds = duration,
                volume = 1.0,
                fadeInSeconds = 0.0,
                fadeOutSeconds = 0.0,
            ),
        )
    }

    fun updateMusic(
        id: String,
        offsetSeconds: Double? = null,
        trimStart: Double? = null,
        lengthSeconds: Double? = null,
        volume: Double? = null,
        fadeInSeconds: Double? = null,
        fadeOutSeconds: Double? = null,
    ): VideoEditCommand.UpdateMusic = VideoEditCommand.UpdateMusic(
        id = id,
        offsetSeconds = offsetSeconds?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
        trimStart = trimStart?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
        lengthSeconds = lengthSeconds?.takeIf { it.isFinite() }?.coerceAtLeast(0.1),
        volume = volume?.takeIf { it.isFinite() }?.coerceIn(0.0, 4.0),
        fadeInSeconds = fadeInSeconds?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
        fadeOutSeconds = fadeOutSeconds?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
    )

    fun removeMusic(id: String): VideoEditCommand.RemoveMusic =
        VideoEditCommand.RemoveMusic(id)

    fun addCaption(
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        id: String = UUID.randomUUID().toString(),
    ): VideoEditCommand.AddCaption? {
        val clean = text.trim().take(2000)
        if (clean.isEmpty()) return null
        val start = startSeconds.coerceAtLeast(0.0)
        val end = max(start + WorkbenchVideoMath.MIN_CAPTION_DURATION, endSeconds)
        if (!end.isFinite() || end <= start) return null
        return VideoEditCommand.AddCaption(
            CaptionSegment(
                id = id,
                start = start,
                end = end,
                text = clean,
                source = com.floe.android.feature.workbench.CaptionSource.MANUAL,
            ),
        )
    }

    fun updateCaption(
        id: String,
        start: Double? = null,
        end: Double? = null,
        text: String? = null,
    ): VideoEditCommand.UpdateCaption? {
        val clean = text?.trim()?.take(2000)
        if (clean != null && clean.isEmpty()) return null
        if (start == null && end == null && clean == null) return null
        return VideoEditCommand.UpdateCaption(
            id = id,
            start = start?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
            end = end?.takeIf { it.isFinite() }?.coerceAtLeast(0.0),
            text = clean,
        )
    }

    fun removeCaption(id: String): VideoEditCommand.RemoveCaption =
        VideoEditCommand.RemoveCaption(id)

    fun setCaptionStyle(style: CaptionStyle): VideoEditCommand.SetCaptionStyle =
        VideoEditCommand.SetCaptionStyle(
            style.copy(
                fontSize = style.fontSize.coerceIn(8.0, 200.0),
                positionY = style.positionY.coerceIn(0.0, 1.0),
            ),
        )

    fun withCaptionAlignment(
        style: CaptionStyle,
        alignment: CaptionAlignment,
    ): CaptionStyle = style.copy(alignment = alignment)

    fun withCaptionSafeArea(style: CaptionStyle, respects: Boolean): CaptionStyle =
        style.copy(respectsSafeArea = respects)

    fun withCaptionPositionY(style: CaptionStyle, positionY: Double): CaptionStyle =
        style.copy(positionY = positionY.coerceIn(0.0, 1.0))

    fun withCaptionSize(style: CaptionStyle, fontSize: Double): CaptionStyle =
        style.copy(fontSize = fontSize.coerceIn(8.0, 200.0))

    fun withCaptionColor(style: CaptionStyle, colorHex: String): CaptionStyle =
        style.copy(colorHex = colorHex)

    fun setCanvas(
        width: Int,
        height: Int,
        frameRate: Double? = null,
    ): VideoEditCommand.SetCanvas = VideoEditCommand.SetCanvas(
        width = width.coerceIn(2, 8192),
        height = height.coerceIn(2, 8192),
        frameRate = frameRate?.takeIf { it.isFinite() }?.coerceIn(1.0, 120.0),
    )

    /**
     * Music length when the source duration is unknown: keep the whole track,
     * but never claim audio longer than the shared cap.
     */
    fun musicLength(sourceDurationSeconds: Double?): Double =
        sourceDurationSeconds?.takeIf { it.isFinite() && it > 0.05 }
            ?.coerceAtMost(MAX_MUSIC_SECONDS) ?: min(30.0, MAX_MUSIC_SECONDS)

    private val ROTATIONS = setOf(0.0, 90.0, 180.0, 270.0, -90.0, -180.0, -270.0)
}
