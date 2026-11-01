// SPDX-License-Identifier: MPL-2.0
//
// Deterministic RDP viewport math tests (authored, not run in this lane).

package com.floe.android.feature.rdp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RdpViewportTest {
    @Test
    fun fitLetterboxesAndMapsCentre() {
        val transform = rdpTransform(
            viewWidth = 1000f,
            viewHeight = 500f,
            frameWidth = 1440,
            frameHeight = 900,
            zoom = 1f,
            panX = 0f,
            panY = 0f,
        )
        val scale = minOf(1000f / 1440f, 500f / 900f)
        assertEquals(1440 * scale, transform.displayWidth, 0.001f)
        assertEquals((1000f - 1440 * scale) / 2f, transform.offsetX, 0.001f)
        assertEquals(0f, transform.offsetY, 0.001f)
        val point = rdpMapPoint(transform, 500f, 250f)
        assertEquals(720 to 450, point)
    }

    @Test
    fun letterboxClicksAreNotForwarded() {
        val transform = rdpTransform(1000f, 500f, 1440, 900, 1f, 0f, 0f)
        assertNull(rdpMapPoint(transform, 0f, 0f))
    }

    @Test
    fun zoomClampsAndPanStaysInsideTheFrame() {
        val zoomed = rdpClampZoom(8f, 2f)
        assertEquals(8f, zoomed, 0.001f)
        val (x, y) = rdpClampPan(1000f, 500f, 1440, 900, 2f, 100_000f, -100_000f)
        val base = minOf(1000f / 1440f, 500f / 900f)
        assertTrue(x <= (1440 * base * 2f - 1000f) / 2f)
        assertTrue(y >= -(900 * base * 2f - 500f) / 2f)
    }
}
