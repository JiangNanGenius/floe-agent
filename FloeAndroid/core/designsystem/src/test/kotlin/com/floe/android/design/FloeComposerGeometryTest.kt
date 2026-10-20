// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM checks for the explicit composer pane-geometry opt-in. These are
// not a rendered proof: they pin the source-level rules that a measured
// conversation pane fills its pane (no G01 720dp reading cap), that a narrower
// pane shrinks the inline-field budget, and that the native one-third height
// cap follows the supplied page height. The component instrumentation suite
// exercises the same rules against real Compose layout.

package com.floe.android.design

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FloeComposerGeometryTest {

    @Test
    fun widePaneUsesItsFullWidthInsteadOfTheG01ReadingCap() {
        val paneWidth = 1_100.dp
        val chromeWidth = FloeComposerGeometry.chromeWidthFor(paneWidth)

        assertEquals(
            "chrome is the pane minus the composer's own outer horizontal padding",
            paneWidth - FloeLayout.ComposerOuterHPadding * 2,
            chromeWidth,
        )
        assertTrue(
            "a measured wide pane must not be clamped to the G01 720dp centred chrome",
            chromeWidth > FloeLayout.ComposerMaxWidth,
        )
        val fieldWidth = FloeComposerGeometry.estimatedInlineFieldWidth(paneWidth, visibleControlCount = 3)
        assertTrue(
            "the wide field slot alone exceeds the old 720dp reading chrome",
            fieldWidth > FloeLayout.ComposerMaxWidth,
        )
    }

    @Test
    fun narrowerPaneAndCompactPhoneShrinkTheInlineFieldBudget() {
        val wide = FloeComposerGeometry.estimatedInlineFieldWidth(900.dp, visibleControlCount = 3)
        val narrowSplit = FloeComposerGeometry.estimatedInlineFieldWidth(520.dp, visibleControlCount = 3)
        val compactPhone = FloeComposerGeometry.estimatedInlineFieldWidth(360.dp, visibleControlCount = 3)

        assertTrue("same-window narrower detail pane must reflow", wide > narrowSplit)
        assertTrue("compact phone must not inherit tablet width", narrowSplit > compactPhone)
        assertTrue("the compact field still has a usable positive budget", compactPhone > 0.dp)
    }

    @Test
    fun runningStopControlReducesTheSamePaneBudget() {
        val idle = FloeComposerGeometry.estimatedInlineFieldWidth(900.dp, visibleControlCount = 3)
        val running = FloeComposerGeometry.estimatedInlineFieldWidth(900.dp, visibleControlCount = 4)

        assertTrue("the extra stop target must come out of the field budget", running < idle)
    }

    @Test
    fun compactPaneUsesTheSixLineBudgetAndWidePaneUsesEight() {
        assertEquals(
            FloeLayout.ComposerMaxLinesCompact,
            FloeComposerGeometry.inlineLineBudgetFor(360.dp),
        )
        assertEquals(
            FloeLayout.ComposerMaxLinesCompact,
            FloeComposerGeometry.inlineLineBudgetFor(520.dp),
        )
        assertEquals(
            FloeLayout.ComposerMaxLinesRegular,
            FloeComposerGeometry.inlineLineBudgetFor(900.dp),
        )
    }

    @Test
    fun fieldHeightCapIsOneThirdOfTheSuppliedPageHeight() {
        assertEquals(240.dp, FloeComposerGeometry.fieldHeightCapFor(720.dp))
        assertEquals(120.dp, FloeComposerGeometry.fieldHeightCapFor(360.dp))
        assertEquals(
            "a pathologically short pane still yields a valid min<=max constraint",
            FloeLayout.MinimumTarget,
            FloeComposerGeometry.fieldHeightCapFor(90.dp),
        )
    }

    @Test
    fun defaultLayoutKeepsEveryG01Rule() {
        val layout = FloeComposerLayout.Default

        assertNull(layout.paneWidth)
        assertNull(layout.pageHeight)
        assertFalse(layout.bottomInsetHandledByHost)
        assertFalse(layout.isPaneOptIn)
    }

    @Test
    fun explicitPaneLayoutIsRecognisedAsOptIn() {
        val layout = FloeComposerLayout(
            paneWidth = 1_100.dp,
            pageHeight = 800.dp,
            bottomInsetHandledByHost = true,
        )

        assertTrue(layout.isPaneOptIn)
        assertEquals(1_100.dp, layout.paneWidth)
        assertEquals(800.dp, layout.pageHeight)
        assertTrue(layout.bottomInsetHandledByHost)
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonPositivePaneWidthIsRejected() {
        FloeComposerLayout(paneWidth = 0.dp)
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonPositivePageHeightIsRejected() {
        FloeComposerLayout(pageHeight = 0.dp)
    }
}
