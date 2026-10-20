// SPDX-License-Identifier: MPL-2.0
//
// Pure geometry tests for the compact floating protocol menu. The menu must
// right-align to the actual row/value trailing edge, prefer the space above
// with a small overlap, flip below when above cannot hold it, and clamp every
// edge to the live window. No device or Compose runtime is required.

package com.floe.android.feature.providers

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderProtocolMenuPositionTest {

    private val windowWidth = 1400
    private val windowHeight = 1000
    private val menuWidth = 272
    private val menuHeight = 200
    private val horizontalMargin = 16
    private val verticalMargin = 12
    private val overlap = 6

    private fun resolve(anchor: Rect) = resolveProviderProtocolMenuPosition(
        anchor = anchor,
        windowWidthPx = windowWidth,
        windowHeightPx = windowHeight,
        popupWidthPx = menuWidth,
        popupHeightPx = menuHeight,
        horizontalMarginPx = horizontalMargin,
        verticalMarginPx = verticalMargin,
        overlapPx = overlap,
    )

    @Test
    fun menuRightAlignsToTheActualRowTrailingEdge() {
        val position = resolve(Rect(left = 800f, top = 400f, right = 1100f, bottom = 448f))
        assertEquals(1100 - menuWidth, position.x)
        assertEquals(menuWidth, position.widthPx)
    }

    @Test
    fun menuPrefersAboveAndOverlapsTheRowByTheConfiguredAmount() {
        val anchor = Rect(left = 800f, top = 400f, right = 1100f, bottom = 448f)
        val position = resolve(anchor)
        assertTrue(position.placeAbove)
        assertEquals(400 - menuHeight + overlap, position.y)
    }

    @Test
    fun menuFlipsBelowWhenAboveCannotHoldIt() {
        val anchor = Rect(left = 800f, top = 90f, right = 1100f, bottom = 138f)
        val position = resolve(anchor)
        assertFalse(position.placeAbove)
        assertEquals(138 - overlap, position.y)
    }

    @Test
    fun menuClampsToTheLeftWindowMargin() {
        val position = resolve(Rect(left = 20f, top = 400f, right = 120f, bottom = 448f))
        assertEquals(horizontalMargin, position.x)
    }

    @Test
    fun menuWidthAndPositionClampToANarrowWindow() {
        val position = resolveProviderProtocolMenuPosition(
            anchor = Rect(left = 20f, top = 400f, right = 360f, bottom = 448f),
            windowWidthPx = 400,
            windowHeightPx = 800,
            popupWidthPx = 500,
            popupHeightPx = 200,
            horizontalMarginPx = horizontalMargin,
            verticalMarginPx = verticalMargin,
            overlapPx = overlap,
        )
        assertEquals(400 - horizontalMargin * 2, position.widthPx)
        assertEquals(horizontalMargin, position.x)
    }
}
