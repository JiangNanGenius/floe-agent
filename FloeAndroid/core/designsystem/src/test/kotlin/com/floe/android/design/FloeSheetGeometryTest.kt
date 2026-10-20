// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM checks for the anchored supplier-popover geometry. These are not a
// rendered-device proof: they pin the source-level clamp policy that keeps the
// 520/680 preferred card (420/540 minimum) attached to the measured field and
// inside the real window on every edge. The instrumentation fixture later
// exercises the same component with real Compose semantics on a device.

package com.floe.android.design

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FloeSheetGeometryTest {

    private val metrics = FloePopoverMetrics(
        preferredWidthPx = 520,
        minWidthPx = 420,
        preferredHeightPx = 680,
        minHeightPx = 540,
        horizontalMarginPx = 16,
        verticalMarginPx = 12,
        anchorGapPx = 8,
        arrowHeightPx = 10,
    )

    private fun row(centerX: Float, top: Float, bottom: Float) =
        Rect(left = centerX - 300f, top = top, right = centerX + 300f, bottom = bottom)

    @Test
    fun upperMiddleFieldOpensAboveAndCentresOnTheField() {
        val layout = resolveFloePopoverLayout(
            anchor = row(centerX = 640f, top = 300f, bottom = 348f),
            windowWidthPx = 1280,
            windowHeightPx = 800,
            metrics = metrics,
        )

        assertTrue("source capture places the chooser above the supplier row", layout.placeAbove)
        assertEquals(520, layout.widthPx)
        // 300 top - 8 gap - 10 arrow - 12 margin leaves 270px above.
        assertEquals(270, layout.cardHeightPx)
        assertEquals(640 - 260, layout.cardLeftPx)
        assertEquals(260, layout.arrowCenterInCardPx)
    }

    @Test
    fun leftEdgeAnchorClampsCardAndKeepsArrowPointingAtTheField() {
        val layout = resolveFloePopoverLayout(
            anchor = row(centerX = 100f, top = 400f, bottom = 448f),
            windowWidthPx = 1280,
            windowHeightPx = 800,
            metrics = metrics,
        )

        assertEquals(16, layout.cardLeftPx)
        assertEquals(100 - 16, layout.arrowCenterInCardPx)
    }

    @Test
    fun rightEdgeAnchorClampsCardWithoutLeavingTheWindow() {
        val layout = resolveFloePopoverLayout(
            anchor = row(centerX = 1200f, top = 400f, bottom = 448f),
            windowWidthPx = 1280,
            windowHeightPx = 800,
            metrics = metrics,
        )

        assertEquals(1280 - 16 - 520, layout.cardLeftPx)
        assertEquals(1200 - (1280 - 16 - 520), layout.arrowCenterInCardPx)
    }

    @Test
    fun fieldNearTopFlipsBelowWithTheActualFreeHeight() {
        val layout = resolveFloePopoverLayout(
            anchor = row(centerX = 640f, top = 100f, bottom = 148f),
            windowWidthPx = 1280,
            windowHeightPx = 800,
            metrics = metrics,
        )

        assertFalse(layout.placeAbove)
        // 800 - 148 bottom - 8 gap - 10 arrow - 12 margin = 622.
        assertEquals(622, layout.cardHeightPx)
    }

    @Test
    fun narrowWindowClampsWidthToTheVisibleWindow() {
        val layout = resolveFloePopoverLayout(
            anchor = row(centerX = 200f, top = 150f, bottom = 198f),
            windowWidthPx = 400,
            windowHeightPx = 300,
            metrics = metrics,
        )

        assertEquals(400 - 32, layout.widthPx)
        assertEquals(16, layout.cardLeftPx)
        assertTrue(layout.cardHeightPx in 1..300)
    }
}
