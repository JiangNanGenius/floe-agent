// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import androidx.media3.common.C
import androidx.media3.common.audio.GainProcessor
import kotlin.math.abs

/**
 * Constant clip gain. Media3's GainProcessor accepts a per-sample gain; a
 * 0...4 project volume is applied here exactly as the Swift audio mix does.
 * Unity is exposed as an explicit unity range so Media3 can skip copying.
 */
internal class ConstantGainProvider(private val gain: Float) : GainProcessor.GainProvider {
    override fun getGainFactorAtSamplePosition(samplePosition: Long, sampleRate: Int): Float =
        gain.coerceIn(0f, 16f)

    override fun isUnityUntil(samplePosition: Long, sampleRate: Int): Long =
        if (abs(gain - 1f) < 0.0001f) C.TIME_END_OF_SOURCE else C.TIME_UNSET
}

/**
 * Music gain curve over the music item's output timeline: `volume` plus a
 * linear fade-in from the item start and a linear fade-out ending at the
 * clamped music end. `samplePosition` is the Media3 stream position, which is
 * congruent with the sequence position (including the leading gap) at flush
 * time. Fades are in timeline seconds, exactly like the Swift audio mix
 * parameters. The provider is deliberately never "unity": fades require
 * per-sample evaluation.
 */
internal class MusicGainProvider(
    private val volume: Float,
    private val startSeconds: Double,
    private val lengthSeconds: Double,
    private val fadeInSeconds: Double,
    private val fadeOutSeconds: Double,
) : GainProcessor.GainProvider {
    override fun getGainFactorAtSamplePosition(samplePosition: Long, sampleRate: Int): Float {
        if (sampleRate <= 0) return 0f
        val seconds = samplePosition.toDouble() / sampleRate.toDouble()
        return AudioGainMath.musicGain(
            volume = volume.toDouble(),
            startSeconds = startSeconds,
            lengthSeconds = lengthSeconds,
            fadeInSeconds = fadeInSeconds,
            fadeOutSeconds = fadeOutSeconds,
            seconds = seconds,
        ).toFloat()
    }

    override fun isUnityUntil(samplePosition: Long, sampleRate: Int): Long = C.TIME_UNSET
}
