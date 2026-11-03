// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.ticket.SettlementGate
import com.floe.android.core.workbenchmedia.video.AudioGainMath
import com.floe.android.core.workbenchmedia.video.cropToNdc
import com.floe.android.core.workbenchmedia.video.fitInto
import com.floe.android.core.workbenchmedia.video.media3RotationDegrees
import com.floe.android.core.workbenchmedia.video.videoBitrate
import com.floe.android.feature.workbench.NormalizedRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoGeometryTest {
    @Test
    fun cropMapsTopLeadingRectToMedia3Ndc() {
        val ndc = cropToNdc(NormalizedRect(0.25, 0.10, 0.5, 0.4))
        assertEquals(-0.5f, ndc.left, 0.0001f)
        assertEquals(0.5f, ndc.right, 0.0001f)
        assertEquals(0.0f, ndc.bottom, 0.0001f)
        assertEquals(0.8f, ndc.top, 0.0001f)
        assertFalse(ndc.isUnit)
    }

    @Test
    fun unitCropIsDetected() {
        assertTrue(cropToNdc(NormalizedRect.UNIT).isUnit)
    }

    @Test
    fun clockwiseRotationMapsToNegativeMedia3Degrees() {
        assertEquals(0f, media3RotationDegrees(0.0), 0.0001f)
        assertEquals(-90f, media3RotationDegrees(90.0), 0.0001f)
        assertEquals(-90f, media3RotationDegrees(450.0), 0.0001f)
    }

    @Test
    fun aspectFitKeepsSourceRatioInsideCanvas() {
        val (width, height) = fitInto(1920.0, 1080.0, 1080.0, 1920.0)
        assertEquals(1080.0, width, 0.001)
        assertEquals(607.5, height, 0.001)
    }

    @Test
    fun bitrateMappingIsBoundedAndMonotonicInQuality() {
        val low = videoBitrate(1920, 1080, 30.0, 0.1)
        val high = videoBitrate(1920, 1080, 30.0, 0.9)
        assertTrue(high > low)
        assertTrue(low >= 500_000)
        assertTrue(high <= 80_000_000)
    }

    @Test
    fun musicFadesAreLinearAndClamped() {
        val gain = AudioGainMath.musicGain(
            volume = 1.0,
            startSeconds = 2.0,
            lengthSeconds = 10.0,
            fadeInSeconds = 2.0,
            fadeOutSeconds = 2.0,
            seconds = 2.0,
        )
        assertEquals(0.0, gain, 0.0001)
        assertEquals(0.5, AudioGainMath.musicGain(1.0, 2.0, 10.0, 2.0, 2.0, 3.0), 0.0001)
        assertEquals(1.0, AudioGainMath.musicGain(1.0, 2.0, 10.0, 2.0, 2.0, 7.0), 0.0001)
        assertEquals(0.5, AudioGainMath.musicGain(1.0, 2.0, 10.0, 2.0, 2.0, 11.0), 0.0001)
        assertEquals(0.0, AudioGainMath.musicGain(1.0, 2.0, 10.0, 2.0, 2.0, 12.5), 0.0001)
    }

    @Test
    fun settlementGateSettlesExactlyOnce() {
        val gate = SettlementGate()
        assertTrue(gate.trySettle())
        assertFalse(gate.trySettle())
        assertTrue(gate.isSettled())
    }
}
