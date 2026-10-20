// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM checks for the measured Settings host popover. These pin the
// window-pixel boundary math, content-fit height, trigger fallback and
// compact suppression. They do not render a device or claim App acceptance.

package com.floe.android.design

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FloeHostPopoverGeometryTest {

    private val metrics = FloeHostPopoverMetrics()

    private fun host(
        window: Rect = Rect(0f, 0f, 1280f, 900f),
        category: Rect? = Rect(0f, 0f, 350f, 900f),
        selectedCategory: Rect? = Rect(16f, 280f, 334f, 340f),
        selectedProvider: Rect? = null,
        trigger: Rect? = Rect(1100f, 20f, 1160f, 80f),
        categoryVisible: Boolean = true,
        wide: Boolean = true,
        safeInsets: FloeWindowInsetsPx = FloeWindowInsetsPx.Zero,
        imeBottom: Int = 0,
    ) = FloeSettingsHostGeometry(
        windowBoundsPx = window,
        categoryPaneBoundsPx = category,
        detailPaneBoundsPx = category?.let { Rect(it.right, it.top, window.right, window.bottom) },
        selectedCategoryRowBoundsPx = selectedCategory,
        selectedProviderRowBoundsPx = selectedProvider,
        triggerBoundsPx = trigger,
        safeInsetsPx = safeInsets,
        imeBottomInsetPx = imeBottom,
        wideLayout = wide,
        categoryPaneVisible = categoryVisible,
        density = 2f,
        fontScale = 1f,
    )

    @Test
    fun categoryBoundaryUsesMeasuredTrailingEdgeAndActualContentHeight() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, layout.mode)
        // 350 category - 32 edge insets - 10 arrow = 308 body width.
        assertEquals(308, layout.bodyWidthPx)
        assertEquals(16, layout.bodyLeftPx)
        assertEquals(318, layout.popupWidthPx)
        assertEquals(200, layout.bodyHeightPx)
        assertEquals(200, layout.popupHeightPx)
        assertEquals(210, layout.bodyTopPx)
        assertEquals(FloeHostPopoverArrow.RIGHT, layout.arrow)
        assertEquals(100, layout.arrowCenterYPx)
        assertEquals(308, layout.arrowLeftPx)
        assertEquals(91, layout.arrowTopPx)
        assertEquals(10, layout.arrowWidthPx)
        assertEquals(18, layout.arrowHeightPx)
        assertFalse(layout.contentScrolls)
    }

    @Test
    fun differentCategoryWidthAndWindowOffsetDoNotAssumeAScreenLeftOrFixed320() {
        val window = Rect(40f, 30f, 1320f, 930f)
        val wideCategory = host(
            window = window,
            category = Rect(40f, 30f, 460f, 930f),
            selectedCategory = Rect(56f, 400f, 444f, 460f),
            trigger = Rect(1140f, 50f, 1200f, 110f),
        )
        val wide = resolveFloeHostPopoverLayout(wideCategory, metrics, 200)
        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, wide.mode)
        assertEquals(320, wide.bodyWidthPx)
        assertEquals(114, wide.bodyLeftPx)
        assertEquals(434, wide.bodyLeftPx + wide.bodyWidthPx)
        assertEquals(444, wide.bodyLeftPx + wide.bodyWidthPx + wide.arrowWidthPx)

        val narrowCategory = host(
            window = window,
            category = Rect(40f, 30f, 340f, 930f),
            selectedCategory = Rect(56f, 400f, 324f, 460f),
            trigger = Rect(1140f, 50f, 1200f, 110f),
        )
        val narrow = resolveFloeHostPopoverLayout(narrowCategory, metrics, 200)
        // 300 category - 32 - 10 = 258; still inside the measured pane.
        assertEquals(258, narrow.bodyWidthPx)
        assertEquals(56, narrow.bodyLeftPx)
        assertEquals(56 + 258 + 10, 340 - 16)
    }

    @Test
    fun categoryResizeRecomputesTheBodyAndArrowTip() {
        val resized = host(
            category = Rect(0f, 0f, 400f, 900f),
            selectedCategory = Rect(16f, 300f, 384f, 360f),
        )
        val layout = resolveFloeHostPopoverLayout(resized, metrics, 200)
        // Preferred 320 wins once the category is wide enough for insets+arrow.
        assertEquals(320, layout.bodyWidthPx)
        assertEquals(54, layout.bodyLeftPx)
        // Measured category right edge (400) minus the design edge inset (16).
        assertEquals(400 - 16, layout.bodyLeftPx + layout.bodyWidthPx + layout.arrowWidthPx)

        val minimum = host(
            category = Rect(0f, 0f, 280f, 900f),
            selectedCategory = Rect(16f, 300f, 264f, 360f),
        )
        val minimumLayout = resolveFloeHostPopoverLayout(minimum, metrics, 200)
        assertEquals(238, minimumLayout.bodyWidthPx)
        assertEquals(16, minimumLayout.bodyLeftPx)
        assertEquals(16 + 238, 280 - 16 - 10)
    }

    @Test
    fun selectedRowScrolledAndPartiallyClippedClampsCardAndArrowInsideThePane() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                selectedCategory = Rect(16f, -40f, 334f, 20f),
            ),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, layout.mode)
        assertEquals(12, layout.bodyTopPx)
        assertEquals(24, layout.arrowCenterYPx)
        assertEquals(12 + 200, layout.bodyTopPx + layout.bodyHeightPx)
    }

    @Test
    fun selectedRowFullyOutsideThePaneUsesTheActualTriggerFallback() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                selectedCategory = Rect(16f, -100f, 334f, -40f),
            ),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.TRIGGER_FALLBACK, layout.mode)
        assertEquals(FloeHostPopoverArrow.UP, layout.arrow)
        // Trigger bottom 80 + 8 gap + 10 arrow = body top 98.
        assertEquals(98, layout.bodyTopPx)
        assertEquals(88, layout.popupTopPx)
        assertEquals(944, layout.bodyLeftPx)
        assertEquals(186, layout.arrowCenterXPx)
        assertEquals(0, layout.arrowTopPx)
    }

    @Test
    fun wideCollapsedUsesMeasuredTriggerAndFlipsAboveWhenBelowCannotFit() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                categoryVisible = false,
                category = Rect(0f, 0f, 350f, 900f),
                trigger = Rect(1100f, 700f, 1160f, 760f),
            ),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.TRIGGER_FALLBACK, layout.mode)
        assertEquals(FloeHostPopoverArrow.DOWN, layout.arrow)
        assertEquals(482, layout.popupTopPx)
        assertEquals(482, layout.bodyTopPx)
        assertEquals(200, layout.arrowTopPx)
        assertEquals(210, layout.popupHeightPx)
        assertEquals(944, layout.bodyLeftPx)
    }

    @Test
    fun imeAndInsetsShrinkTheScrollableBodyAndKeepItInsideTheSafeWindow() {
        val safeInsets = FloeWindowInsetsPx(topPx = 24, bottomPx = 40)
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                window = Rect(0f, 0f, 1280f, 900f),
                category = Rect(0f, 24f, 350f, 560f),
                selectedCategory = Rect(16f, 300f, 334f, 360f),
                safeInsets = safeInsets,
                imeBottom = 300,
            ),
            metrics = metrics,
            measuredContentHeightPx = 700,
        )

        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, layout.mode)
        // Safe height 536; 90% cap = 482, below the 512 pane allowance.
        assertEquals(482, layout.bodyHeightPx)
        assertTrue(layout.contentScrolls)
        assertTrue(layout.bodyTopPx >= 24 + 12)
        assertTrue(layout.bodyTopPx + layout.bodyHeightPx <= 900 - 40 - 300 - 12)
    }

    @Test
    fun translatedBodyHeightIsBoundedAndScrollsInsteadOfGrowingTheWindow() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(),
            metrics = metrics,
            measuredContentHeightPx = 900,
        )

        assertEquals(810, layout.bodyHeightPx)
        assertEquals(810, layout.popupHeightPx)
        assertTrue(layout.contentScrolls)
        assertTrue(layout.bodyTopPx >= 12)
        assertTrue(layout.bodyTopPx + layout.bodyHeightPx <= 900 - 12)
    }

    @Test
    fun narrowCompactIsSuppressedAndLeavesTheBottomSheetToTheDestination() {
        val geometry = host(wide = false, category = null, selectedCategory = null)
        val layout = resolveFloeHostPopoverLayout(geometry, metrics, 200)
        assertEquals(FloeHostPopoverMode.SUPPRESSED_COMPACT, layout.mode)
        assertEquals(0, layout.popupWidthPx)
        assertEquals(0, layout.popupHeightPx)
        assertFalse(layout.contentScrolls)
    }

    @Test
    fun fallbackWithoutAVisibleTriggerUsesABoundedCenteredCardWithoutAnArrow() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(categoryVisible = false, trigger = null),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.TRIGGER_FALLBACK, layout.mode)
        assertEquals(FloeHostPopoverArrow.NONE, layout.arrow)
        assertEquals(480, layout.bodyLeftPx)
        assertEquals(350, layout.bodyTopPx)
        assertEquals(200, layout.popupHeightPx)
    }

    @Test
    fun actualProviderRowAnchorWinsOverTheCategoryRowWhenMeasured() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                selectedCategory = Rect(16f, 180f, 334f, 240f),
                selectedProvider = Rect(400f, 470f, 900f, 530f),
            ),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, layout.mode)
        assertEquals(400, layout.bodyTopPx)
        assertEquals(100, layout.arrowCenterYPx)
    }

    @Test
    fun categoryTooNarrowForTheMinimumCardFallsBackToTheTrigger() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(
                category = Rect(0f, 0f, 200f, 900f),
                selectedCategory = Rect(16f, 280f, 184f, 340f),
            ),
            metrics = metrics,
            measuredContentHeightPx = 200,
        )

        assertEquals(FloeHostPopoverMode.TRIGGER_FALLBACK, layout.mode)
        assertEquals(FloeHostPopoverArrow.UP, layout.arrow)
        assertTrue(layout.bodyWidthPx >= metrics.minWidthPx)
    }

    @Test
    fun tinyContentStillProducesANonZeroBoundedCard() {
        val layout = resolveFloeHostPopoverLayout(
            geometry = host(),
            metrics = metrics,
            measuredContentHeightPx = 0,
        )

        assertEquals(FloeHostPopoverMode.CATEGORY_BOUNDARY, layout.mode)
        assertEquals(1, layout.bodyHeightPx)
        assertEquals(1, layout.popupHeightPx)
        assertEquals(FloeHostPopoverArrow.NONE, layout.arrow)
        assertTrue(layout.popupWidthPx > 0)
    }
}
