// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.Size
import androidx.media3.effect.Crop
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.VideoClip
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToLong

/**
 * Builds the ONE Media3 `Composition` used by both `CompositionPlayer` and
 * `Transformer`. It preserves clip order/trim/speed/rotation/crop/canvas
 * aspect-fit, primary volume/mute, music offset/trim/gain/fades and the
 * caption burn-in overlay.
 *
 * Without a cross-dissolve the composition stays a single video sequence, so
 * the ordinary single-input HDR pipeline is used. With a cross-dissolve the
 * clips are assigned to the two verified compositor lanes; each lane becomes
 * one video sequence. Every lane gap is covered with real alpha-zero source
 * frames: a plain Media3 gap renders 30 fps SRGB_BT709_FULL blank frames,
 * which would both change a 50/60 fps output cadence and violate the
 * compositor's one-ColorInfo-per-input rule. [TimelineCompositorSettings]
 * supplies the per-input per-frame opacity. The same object is consumed by
 * preview and export. There is no hard-cut fallback: an unrepresentable
 * layout is refused before the engine starts.
 */
internal object Media3CompositionFactory {
    fun build(
        plan: CompositionPlan,
        isCancelled: () -> Boolean = { false },
    ): Composition {
        if (isCancelled()) throw CancellationException("Composition build was cancelled")
        if (plan.hdr.isHdr && plan.layout.usesCompositor) {
            throw refusal(
                UNSUPPORTED_TRANSITION,
                "HDR cross-dissolve is not supported by the verified Media3 compositor",
            )
        }
        val videoSequences = if (plan.layout.usesCompositor) {
            videoLaneSequences(plan, isCancelled)
        } else {
            listOf(videoSequence(plan, plan.clips, isCancelled))
        }
        val sequences = ArrayList<EditedMediaItemSequence>(videoSequences)
        if (plan.layout.usesCompositor) {
            sequences += audioLaneSequences(plan)
        } else {
            audioSequence(plan, plan.clips)?.let { sequences += it }
        }
        sequences += musicSequences(plan)

        val compositionVideoEffects: List<Effect> = if (plan.captions.isEmpty()) {
            emptyList()
        } else {
            listOf(OverlayEffect(listOf(CaptionOverlay(plan.captions, plan.captionStyle))))
        }
        val builder = Composition.Builder(sequences)
            .setEffects(Effects(emptyList(), compositionVideoEffects))
        if (plan.hdr.isHdr) {
            // Media3 falls back to tone mapping when an HDR encoder is not
            // available. The planner has already proven a real HDR encoder and
            // the final verifier rejects an SDR output, so this request is
            // explicit and honored rather than silently downgraded.
            builder.setHdrMode(Composition.HDR_MODE_KEEP_HDR)
        }
        if (videoSequences.size > 1) {
            builder.setVideoCompositorSettings(TimelineCompositorSettings(plan))
        }
        return builder.build()
    }

    private fun videoLaneSequences(
        plan: CompositionPlan,
        isCancelled: () -> Boolean,
    ): List<EditedMediaItemSequence> {
        val byID = plan.clips.associateBy { it.clip.id }
        val lanes = plan.layout.lanes.map { lane -> lane.mapNotNull(byID::get) }
        // Media3's blank gap frames are 30 fps SRGB_BT709_FULL. They would both
        // drive the primary clock and violate the compositor's requirement that
        // every input share one ColorInfo, so every gap in a multi-sequence
        // composition is covered with real alpha-zero source frames instead.
        val filler = plan.clips.maxByOrNull { it.clip.trimEnd - it.clip.trimStart }
            ?: plan.clips.first()
        return lanes.map { clips ->
            coverageVideoSequence(plan, clips, filler, isCancelled)
        }
    }

    private fun coverageVideoSequence(
        plan: CompositionPlan,
        clips: List<PlannedClip>,
        filler: PlannedClip,
        isCancelled: () -> Boolean,
    ): EditedMediaItemSequence {
        val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
        var cursorUs = 0L
        for (planned in clips) {
            if (isCancelled()) throw CancellationException("Composition build was cancelled")
            val startUs = durationUs(planned.placed.timelineStart)
            if (startUs > cursorUs + GAP_EPSILON_US) {
                addCoverage(builder, filler, startUs - cursorUs, plan)
            }
            builder.addItem(videoItem(planned, plan))
            cursorUs = max(cursorUs, durationUs(planned.placed.timelineEnd))
        }
        val endUs = durationUs(plan.durationSeconds)
        if (endUs > cursorUs + GAP_EPSILON_US) {
            addCoverage(builder, filler, endUs - cursorUs, plan)
        }
        return builder.build()
    }

    private fun addCoverage(
        builder: EditedMediaItemSequence.Builder,
        filler: PlannedClip,
        gapUs: Long,
        plan: CompositionPlan,
    ) {
        if (gapUs <= 0L) return
        val sourceStartUs = durationUs(filler.clip.trimStart)
        val sourceEndUs = durationUs(filler.clip.trimEnd)
            .coerceAtLeast(sourceStartUs + 1L)
        val segments = CompositionCoverage.segments(gapUs, sourceStartUs, sourceEndUs)
        if (segments.isEmpty()) {
            builder.addGap(gapUs)
            return
        }
        for (segment in segments) {
            builder.addItem(fillerItem(plan, filler, segment))
        }
    }

    private fun fillerItem(
        plan: CompositionPlan,
        filler: PlannedClip,
        segment: CoverageSegment,
    ): EditedMediaItem {
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(filler.file))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionUs(segment.startUs)
                    .setEndPositionUs(segment.endUs)
                    .build(),
            )
            .build()
        return EditedMediaItem.Builder(mediaItem)
            .setRemoveAudio(true)
            .setEffects(Effects(emptyList(), videoEffects(filler, plan)))
            .setDurationUs(sourceDurationUs(filler.probe.durationSeconds, filler.clip))
            .build()
    }

    private fun audioLaneSequences(plan: CompositionPlan): List<EditedMediaItemSequence> {
        val byID = plan.clips.associateBy { it.clip.id }
        return plan.layout.lanes.mapNotNull { lane ->
            audioSequence(plan, lane.mapNotNull(byID::get))
        }
    }

    private fun videoSequence(
        plan: CompositionPlan,
        clips: List<PlannedClip>,
        isCancelled: () -> Boolean,
    ): EditedMediaItemSequence {
        val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
        var cursorUs = 0L
        for (planned in clips) {
            if (isCancelled()) throw CancellationException("Composition build was cancelled")
            val startUs = durationUs(planned.placed.timelineStart)
            if (startUs > cursorUs + GAP_EPSILON_US) builder.addGap(startUs - cursorUs)
            builder.addItem(videoItem(planned, plan))
            cursorUs = max(cursorUs, durationUs(planned.placed.timelineEnd))
        }
        addTrailingGap(builder, plan.durationSeconds, cursorUs)
        return builder.build()
    }

    private fun audioSequence(
        plan: CompositionPlan,
        clips: List<PlannedClip>,
    ): EditedMediaItemSequence? {
        val timeline = plan.snapshot.projection.timeline
        val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
        var cursorUs = 0L
        var hasAudibleItem = false
        for (planned in clips) {
            val startUs = durationUs(planned.placed.timelineStart)
            if (startUs > cursorUs + GAP_EPSILON_US) builder.addGap(startUs - cursorUs)
            val gain = (planned.clip.volume * timeline.primaryVolume).toFloat()
            val audible = planned.probe.hasAudio &&
                !planned.clip.isMuted &&
                gain > 0f &&
                !timeline.primaryMuted
            if (audible) {
                builder.addItem(audioItem(planned, gain))
                hasAudibleItem = true
            } else {
                builder.addGap(durationUs(planned.placed.duration))
            }
            cursorUs = max(cursorUs, durationUs(planned.placed.timelineEnd))
        }
        addTrailingGap(builder, plan.durationSeconds, cursorUs)
        return if (hasAudibleItem) builder.build() else null
    }

    private fun addTrailingGap(
        builder: EditedMediaItemSequence.Builder,
        durationSeconds: Double,
        cursorUs: Long,
    ) {
        val endUs = durationUs(durationSeconds)
        if (endUs > cursorUs + GAP_EPSILON_US) builder.addGap(endUs - cursorUs)
    }

    private fun videoItem(planned: PlannedClip, plan: CompositionPlan): EditedMediaItem {
        val builder = EditedMediaItem.Builder(mediaItem(planned))
            .setRemoveAudio(true)
            .setEffects(Effects(emptyList(), videoEffects(planned, plan)))
            .setDurationUs(sourceDurationUs(planned.probe.durationSeconds, planned.clip))
        if (abs(planned.clip.speed - 1.0) > 0.0001) {
            builder.setSpeed(ConstantSpeed(planned.clip.speed.toFloat()))
        }
        return builder.build()
    }

    private fun audioItem(planned: PlannedClip, gain: Float): EditedMediaItem {
        val builder = EditedMediaItem.Builder(mediaItem(planned))
            .setRemoveVideo(true)
            .setEffects(Effects(listOf(GainProcessor(ConstantGainProvider(gain))), emptyList()))
            .setDurationUs(sourceDurationUs(planned.probe.durationSeconds, planned.clip))
        if (abs(planned.clip.speed - 1.0) > 0.0001) {
            builder.setSpeed(ConstantSpeed(planned.clip.speed.toFloat()))
        }
        return builder.build()
    }

    private fun musicSequences(plan: CompositionPlan): List<EditedMediaItemSequence> =
        plan.music.map { music ->
            val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
            if (music.offsetSeconds > 0.0005) {
                builder.addGap(durationUs(music.offsetSeconds))
            }
            val startUs = (music.trimStartSeconds * 1_000_000.0).roundToLong()
            val endUs = ((music.trimStartSeconds + music.lengthSeconds) * 1_000_000.0).roundToLong()
            val mediaItem = MediaItem.Builder()
                .setUri(Uri.fromFile(music.file))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionUs(startUs)
                        .setEndPositionUs(endUs)
                        .build(),
                )
                .build()
            val gain = GainProcessor(
                MusicGainProvider(
                    volume = music.music.volume.toFloat(),
                    startSeconds = music.offsetSeconds,
                    lengthSeconds = music.lengthSeconds,
                    fadeInSeconds = music.fadeInSeconds,
                    fadeOutSeconds = music.fadeOutSeconds,
                ),
            )
            val item = EditedMediaItem.Builder(mediaItem)
                .setRemoveVideo(true)
                .setEffects(Effects(listOf(gain), emptyList()))
                .setDurationUs(
                    ((music.probe.durationSeconds ?: music.lengthSeconds).coerceAtLeast(0.001) * 1_000_000.0)
                        .roundToLong()
                        .coerceAtLeast(1L),
                )
                .build()
            builder.addItem(item)
            builder.build()
        }

    private fun mediaItem(planned: PlannedClip): MediaItem {
        val startUs = (planned.clip.trimStart * 1_000_000.0).roundToLong().coerceAtLeast(0L)
        val endUs = (planned.clip.trimEnd * 1_000_000.0).roundToLong().coerceAtLeast(startUs + 1L)
        return MediaItem.Builder()
            .setUri(Uri.fromFile(planned.file))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionUs(startUs)
                    .setEndPositionUs(endUs)
                    .build(),
            )
            .build()
    }

    private fun videoEffects(planned: PlannedClip, plan: CompositionPlan): List<Effect> {
        val effects = ArrayList<Effect>()
        planned.clip.crop?.let { crop ->
            val ndc = cropToNdc(crop)
            if (!ndc.isUnit) effects += Crop(ndc.left, ndc.right, ndc.bottom, ndc.top)
        }
        val rotation = media3RotationDegrees(planned.clip.rotationDegrees)
        if (rotation != 0f) {
            effects += ScaleAndRotateTransformation.Builder()
                .setRotationDegrees(rotation)
                .build()
        }
        // Frame-rate mapping is only downward: the planner has already refused
        // a request above every source rate. FrameDropEffect is a real engine
        // effect, not a claimed fps relabel.
        val sourceRate = planned.probe.frameRate
        if (sourceRate != null && plan.frameRate + 0.5 < sourceRate) {
            effects += FrameDropEffect.createDefaultFrameDropEffect(plan.frameRate.toFloat())
        }
        effects += Presentation.createForWidthAndHeight(
            plan.width,
            plan.height,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )
        return effects
    }

    private fun durationUs(seconds: Double): Long =
        (seconds.coerceAtLeast(0.0) * 1_000_000.0).roundToLong().coerceAtLeast(0L)

    private fun sourceDurationUs(sourceSeconds: Double?, clip: VideoClip): Long {
        // durationUs is the ORIGINAL media duration, not the clipped range.
        // trimEnd is always a safe lower bound when the probe could not read
        // the container duration.
        val seconds = sourceSeconds?.takeIf { it > 0.0 } ?: clip.trimEnd
        return (seconds.coerceAtLeast(0.001) * 1_000_000.0).roundToLong().coerceAtLeast(1L)
    }

    private const val GAP_EPSILON_US = 500L

    private class ConstantSpeed(private val speed: Float) : SpeedProvider {
        override fun getSpeed(timeUs: Long): Float = speed
        override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
    }

    /**
     * The compositor input ids are the order of the video sequences: lane 0 is
     * the primary input drawn on top, lane 1 is underneath. Gaps and ended
     * clips are transparent, so a held blank/last frame cannot cover the other
     * lane.
     */
    private class TimelineCompositorSettings(
        private val plan: CompositionPlan,
    ) : VideoCompositorSettings {
        override fun getOutputSize(inputSizes: List<Size>): Size = Size(plan.width, plan.height)

        override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
            val alpha = CompositionLayoutMath.alphaAt(
                laneIndex = inputId,
                seconds = presentationTimeUs / 1_000_000.0,
                layout = plan.layout,
            )
            return StaticOverlaySettings.Builder()
                .setAlphaScale(alpha)
                .build()
        }
    }
}
