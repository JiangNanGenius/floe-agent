// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.effect.Crop
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import com.floe.android.feature.workbench.VideoClip
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Builds the ONE Media3 `Composition` used by both `CompositionPlayer` and
 * `Transformer`. It preserves clip order/trim/speed/rotation/crop/canvas
 * aspect-fit, primary volume/mute, music offset/trim/gain/fades and the
 * caption burn-in overlay. No transition (cross-dissolve is refused earlier),
 * no automatic codec/effect substitution.
 */
internal object Media3CompositionFactory {
    fun build(plan: CompositionPlan): Composition {
        val videoItems = plan.clips.map { planned ->
            val mediaItem = mediaItem(planned)
            val effects = Effects(
                /* audioProcessors= */ emptyList(),
                /* videoEffects= */ videoEffects(planned, plan),
            )
            val builder = EditedMediaItem.Builder(mediaItem)
                .setRemoveAudio(true)
                .setEffects(effects)
                .setDurationUs(sourceDurationUs(planned.probe.durationSeconds, planned.clip))
            if (abs(planned.clip.speed - 1.0) > 0.0001) {
                builder.setSpeed(ConstantSpeed(planned.clip.speed.toFloat()))
            }
            builder.build()
        }
        val sequences = ArrayList<EditedMediaItemSequence>()
        sequences += itemsSequence(C.TRACK_TYPE_VIDEO, videoItems)

        val audiblePrimary = plan.clips.any {
            it.probe.hasAudio && !it.clip.isMuted && it.clip.volume > 0.0
        }
        if (audiblePrimary && !plan.snapshot.projection.timeline.primaryMuted &&
            plan.snapshot.projection.timeline.primaryVolume > 0.0
        ) {
            val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
            for (planned in plan.clips) {
                val gain = (planned.clip.volume *
                    plan.snapshot.projection.timeline.primaryVolume).toFloat()
                val audible = planned.probe.hasAudio && !planned.clip.isMuted && gain > 0f
                if (audible) {
                    val item = EditedMediaItem.Builder(mediaItem(planned))
                        .setRemoveVideo(true)
                        .setEffects(Effects(listOf(GainProcessor(ConstantGainProvider(gain))), emptyList()))
                        .setDurationUs(sourceDurationUs(planned.probe.durationSeconds, planned.clip))
                        .also { if (abs(planned.clip.speed - 1.0) > 0.0001) it.setSpeed(ConstantSpeed(planned.clip.speed.toFloat())) }
                        .build()
                    builder.addItem(item)
                } else {
                    builder.addGap(durationUs(planned.placed.duration))
                }
            }
            sequences += builder.build()
        }

        for (music in plan.music) {
            val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
            if (music.offsetSeconds > 0.0005) builder.addGap(durationUs(music.offsetSeconds))
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
            sequences += builder.build()
        }

        val compositionVideoEffects: List<Effect> = if (plan.captions.isEmpty()) {
            emptyList()
        } else {
            listOf(
                OverlayEffect(
                    listOf(CaptionOverlay(plan.captions, plan.captionStyle)),
                ),
            )
        }
        return Composition.Builder(sequences)
            .setEffects(Effects(emptyList(), compositionVideoEffects))
            .build()
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

    private fun itemsSequence(trackType: Int, items: List<EditedMediaItem>): EditedMediaItemSequence {
        val builder = EditedMediaItemSequence.Builder(setOf(trackType))
        items.forEach(builder::addItem)
        return builder.build()
    }

    private fun durationUs(seconds: Double): Long =
        (seconds.coerceAtLeast(0.0) * 1_000_000.0).roundToLong()

    private fun sourceDurationUs(sourceSeconds: Double?, clip: VideoClip): Long {
        val seconds = sourceSeconds?.takeIf { it > 0.0 }
            ?: (clip.trimEnd - clip.trimStart)
        return (seconds.coerceAtLeast(0.001) * 1_000_000.0).roundToLong().coerceAtLeast(1L)
    }

    private class ConstantSpeed(private val speed: Float) : SpeedProvider {
        override fun getSpeed(timeUs: Long): Float = speed
        override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
    }
}
