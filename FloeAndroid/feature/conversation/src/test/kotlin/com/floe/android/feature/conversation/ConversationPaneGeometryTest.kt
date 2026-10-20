// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM checks for the conversation host's measured-pane contract. They
// prove that the destination's explicit geometry is translated into the
// shared composer opt-in without re-reading the window/screen, and that the
// inset ownership flag is preserved so the composer never double-pads.
// Rendered width/height/overflow behaviour is authored in
// ConversationPaneGeometryUiTest (device component suite, authored NOT run in
// this source-only package).

package com.floe.android.feature.conversation

import androidx.compose.ui.unit.dp
import com.floe.android.design.FloeComposerGeometry
import com.floe.android.design.FloeLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationPaneGeometryTest {

    @Test
    fun actualDetailPaneMapsToTheExplicitComposerOptIn() {
        val geometry = ConversationPaneGeometry(
            width = 1_100.dp,
            height = 760.dp,
            bottomInset = 24.dp,
            imeBottomInset = 0.dp,
            fontScale = 1f,
        )

        val layout = geometry.toComposerLayout()

        assertEquals("the composer must fill the measured pane width", 1_100.dp, layout.paneWidth)
        assertEquals("the one-third cap uses the pane height", 760.dp, layout.pageHeight)
        assertTrue(
            "the measured pane already excludes the consumed bottom inset",
            layout.bottomInsetHandledByHost,
        )
    }

    @Test
    fun hostThatHasNotConsumedInsetsKeepsComposerOwnedPadding() {
        val geometry = ConversationPaneGeometry(
            width = 900.dp,
            height = 700.dp,
            insetsConsumedByHost = false,
        )

        assertFalse(geometry.toComposerLayout().bottomInsetHandledByHost)
    }

    @Test
    fun imeInsetIsCarriedExplicitlyButNeverSubtractedTwice() {
        val keyboardOpen = ConversationPaneGeometry(
            width = 900.dp,
            height = 420.dp,
            bottomInset = 48.dp,
            imeBottomInset = 320.dp,
        )

        assertEquals(320.dp, keyboardOpen.imeBottomInset)
        assertEquals(
            "height is already the post-inset pane; the composer must not subtract the IME again",
            420.dp,
            keyboardOpen.toComposerLayout().pageHeight,
        )
    }

    @Test
    fun splitPaneWidthAndFontScaleChangeTheSameGeometryContract() {
        val wide = ConversationPaneGeometry(width = 900.dp, height = 700.dp)
        val narrower = ConversationPaneGeometry(width = 520.dp, height = 700.dp)
        val largeType = ConversationPaneGeometry(width = 900.dp, height = 700.dp, fontScale = 2f)

        val wideField = FloeComposerGeometry.estimatedInlineFieldWidth(
            wide.width,
            visibleControlCount = 3,
        )
        val narrowField = FloeComposerGeometry.estimatedInlineFieldWidth(
            narrower.width,
            visibleControlCount = 3,
        )

        assertTrue(wideField > narrowField)
        assertEquals(1f, wide.fontScale, 0f)
        assertEquals(2f, largeType.fontScale, 0f)
        assertEquals(
            "font scale must not change the pane width",
            wide.width,
            largeType.width,
        )
    }

    @Test
    fun nonFullHeightSplitPaneKeepsTheNativeOneThirdCap() {
        val splitPane = ConversationPaneGeometry(width = 900.dp, height = 360.dp)

        assertEquals(
            120.dp,
            FloeComposerGeometry.fieldHeightCapFor(splitPane.height),
        )
        assertTrue(
            "a non-full-height pane still supplies a valid positive height",
            splitPane.height > FloeLayout.MinimumTarget,
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun zeroWidthPaneIsRejectedInsteadOfClippingSilently() {
        ConversationPaneGeometry(width = 0.dp, height = 700.dp)
    }

    @Test(expected = IllegalArgumentException::class)
    fun zeroHeightPaneIsRejectedInsteadOfClippingSilently() {
        ConversationPaneGeometry(width = 900.dp, height = 0.dp)
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonPositiveFontScaleIsRejected() {
        ConversationPaneGeometry(width = 900.dp, height = 700.dp, fontScale = 0f)
    }
}
