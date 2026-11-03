// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored image-bounds tests (NOT RUN here).
 *
 * The previous sampler used `&&`, so a very wide/tall image was fully decoded
 * before allocation. These tests pin the corrected rule: EITHER dimension is
 * bounded before the real decode, and the existing pixel/bitmap caps stay in
 * force for the caller.
 */
class DesignImageBoundsTest {
    @Test
    fun extremelyWideImageIsSampledEvenWhenHeightFits() {
        assertEquals(2, DesignImageBounds.sampleSize(4000, 100))
        assertEquals(8, DesignImageBounds.sampleSize(9000, 12))
    }

    @Test
    fun extremelyTallImageIsSampledEvenWhenWidthFits() {
        assertEquals(4, DesignImageBounds.sampleSize(100, 5000))
        assertEquals(16, DesignImageBounds.sampleSize(24, 20000))
    }

    @Test
    fun alreadyBoundedImagesAreNotDownsampled() {
        assertEquals(1, DesignImageBounds.sampleSize(2048, 2048))
        assertEquals(1, DesignImageBounds.sampleSize(1, 1))
        assertEquals(2, DesignImageBounds.sampleSize(2049, 10))
    }

    @Test
    fun everySampledDimensionStaysWithinTheBound() {
        val cases = listOf(
            4000 to 100,
            100 to 5000,
            12000 to 9000,
            60_000 to 30,
            30 to 60_000,
            Int.MAX_VALUE to 1,
            1 to Int.MAX_VALUE,
        )
        for ((width, height) in cases) {
            val sample = DesignImageBounds.sampleSize(width, height)
            assertTrue("sample must be positive for ${width}x$height", sample > 0)
            assertTrue(
                "width must be bounded for ${width}x$height (sample=$sample)",
                width / sample <= DesignImageBounds.MAX_IMAGE_DIMENSION,
            )
            assertTrue(
                "height must be bounded for ${width}x$height (sample=$sample)",
                height / sample <= DesignImageBounds.MAX_IMAGE_DIMENSION,
            )
        }
    }

    @Test
    fun nonPositiveBoundsAreNotTreatedAsRealImages() {
        assertEquals(1, DesignImageBounds.sampleSize(0, 100))
        assertEquals(1, DesignImageBounds.sampleSize(100, -1))
    }
}
