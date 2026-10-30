// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The tablet IME regression is a chrome/viewport budget failure: with the
 * keyboard open the inspector is ~364dp high, so preserving the 33dp live
 * sync hint and full control padding leaves the PTY surface with almost no
 * height. These cases pin the actual decision boundary, not a second layout:
 *  - a keyboard-height pane compacts and keeps a useful PTY viewport;
 *  - a normal pane keeps the full chrome and its explanatory hint;
 *  - a pathological short pane is still reported as not useful (the caller
 *    must not claim a usable viewport just because the math is positive).
 */
class TerminalViewportBudgetTest {

    @Test
    fun keyboardHeightInspectorCompactsAndKeepsUsefulViewport() {
        // A 2560x1600 tablet at 2x density in the compact inspector: ~364dp
        // pane after the status bar/header; the keyboard-resized window is
        // this order in the observed device dump.
        val available = 364f
        assertTrue(TerminalViewportBudget.compact(available))
        assertTrue(TerminalViewportBudget.hasUsefulViewport(available))
        // 364 - (31 tab + 36 status + 52 controls) = 245dp of real terminal.
        assertEquals(245f, TerminalViewportBudget.viewportHeightDp(available), 0.001f)
        assertFalse(TerminalViewportBudget.showsLiveHint(available))
    }

    @Test
    fun normalInspectorKeepsFullChromeAndSyncHint() {
        val available = 800f
        assertFalse(TerminalViewportBudget.compact(available))
        assertTrue(TerminalViewportBudget.showsLiveHint(available))
        // 800 - (35 tab + 36 status + 33 hint + 60 controls) = 636dp.
        assertEquals(636f, TerminalViewportBudget.viewportHeightDp(available), 0.001f)
    }

    @Test
    fun boundaryIsDeterministicAndExtremeShortPaneIsNotClaimedUseful() {
        assertTrue(TerminalViewportBudget.compact(419.9f))
        assertFalse(TerminalViewportBudget.compact(420f))
        // 180 - 119 = 61dp: positive but below the useful-viewport floor.
        assertEquals(61f, TerminalViewportBudget.viewportHeightDp(180f), 0.001f)
        assertFalse(TerminalViewportBudget.hasUsefulViewport(180f))
    }
}
