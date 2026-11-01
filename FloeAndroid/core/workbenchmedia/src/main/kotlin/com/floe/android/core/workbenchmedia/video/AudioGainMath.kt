// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import kotlin.math.max
import kotlin.math.min

/**
 * Pure music/clip gain math shared by the real Media3 GainProcessor and the
 * module's JVM tests. A music item is placed at [startSeconds] on the sequence
 * timeline; its gain ramps linearly in over [fadeInSeconds] and out over
 * [fadeOutSeconds] ending at `startSeconds + lengthSeconds`.
 */
internal object AudioGainMath {
    fun clipGain(volume: Double, primaryVolume: Double): Double =
        (volume * primaryVolume).coerceIn(0.0, 16.0)

    fun musicGain(
        volume: Double,
        startSeconds: Double,
        lengthSeconds: Double,
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        seconds: Double,
    ): Double {
        if (!seconds.isFinite() || !lengthSeconds.isFinite() || lengthSeconds <= 0.0) return 0.0
        val local = seconds - startSeconds
        if (local < 0.0 || local > lengthSeconds) return 0.0
        val fadeIn = if (fadeInSeconds > 0.0) min(1.0, local / fadeInSeconds) else 1.0
        val remaining = max(0.0, lengthSeconds - local)
        val fadeOut = if (fadeOutSeconds > 0.0) min(1.0, remaining / fadeOutSeconds) else 1.0
        return (volume * min(fadeIn, fadeOut)).coerceIn(0.0, 4.0)
    }
}
