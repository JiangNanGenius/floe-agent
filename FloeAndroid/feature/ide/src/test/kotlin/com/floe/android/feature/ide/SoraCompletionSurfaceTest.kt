// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.sora.FloeCompletionPlacement
import com.floe.android.feature.ide.sora.FloeCompletionScroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM regressions for the bounded Sora completion surface
 * (job-9d948bf8148347c0). The ANR itself lives in the vendored 0.24.4
 * DefaultCompletionLayout synthetic-touch loop; these tests pin the pure
 * decisions that replace it — the exact actual device geometry from
 * device/c05-completion-pri.xml (CodeEditor [1700,643][2560,788] = 860x145px
 * strip, caret Line 3 of a 3-line doc, rowHeight≈48px, density 2.0) and the
 * single-step list placement that can never loop. AUTHORED SOURCE ONLY —
 * not executed by the authoring job; Main runs the changed-boundary batch.
 */
class SoraCompletionSurfaceTest {

    // The actual evidence geometry: 860x145 editor strip; panelY = 2*48 + 24
    // (third line's top + half row) = 120; below = 25px — Sora's own
    // setMaxHeight(25) sub-row popup, its scroll compensation blocked by
    // scrollMaxY == 0 on the 3-line document.
    private val evidenceWidth = 860
    private val evidenceHeight = 145
    private val evidencePanelY = 120f
    private val evidenceRow = 48f
    private val evidenceDp = 2f

    @Test
    fun actualSubRowEvidenceGeometryFlipsABoundedPopupAboveTheCaret() {
        // 860 < 500dp*2 = full-width mode (Sora's own rule); content =
        // 3 candidates * 45px item height.
        val flip = FloeCompletionPlacement.flipAboveCaret(
            editorWidth = evidenceWidth, editorHeight = evidenceHeight,
            panelX = 300f, panelY = evidencePanelY,
            rowHeight = evidenceRow, dpUnit = evidenceDp,
            fullWidth = true, contentHeight = 135,
        )
        assertNotNull("the ANR geometry must produce a flipped popup", flip)
        val window = flip!!
        assertEquals(evidenceWidth * 7 / 8, window.width)
        assertEquals((evidenceWidth / 8f / 2f).toInt(), window.x)
        // above = panelY - row/2 = 96; height = min(200dp=400, 96, 135) = 96.
        assertEquals(96, window.height)
        assertEquals(0, window.y)
        // The caret row stays unobstructed: the popup bottom never reaches
        // the caret row's top edge.
        assertTrue(window.y + window.height <= evidencePanelY - evidenceRow / 2f)
        assertTrue(window.height >= 1)
    }

    @Test
    fun usableBelowStripKeepsSorasOwnPlacementUntouched() {
        assertNull(
            FloeCompletionPlacement.flipAboveCaret(
                editorWidth = evidenceWidth, editorHeight = 600,
                panelX = 300f, panelY = 200f,
                rowHeight = evidenceRow, dpUnit = evidenceDp,
                fullWidth = true, contentHeight = 135,
            ),
        )
        // Exactly at the 2.5-row floor is still usable (no flip).
        assertNull(
            FloeCompletionPlacement.flipAboveCaret(
                editorWidth = evidenceWidth, editorHeight = 320,
                panelX = 300f, panelY = 200f,
                rowHeight = evidenceRow, dpUnit = evidenceDp,
                fullWidth = true, contentHeight = 135,
            ),
        )
    }

    @Test
    fun noRoomAnywhereKeepsTheHonestBoundedResultAndNeverHides() {
        // Caret near the top of the same compressed strip: below is sub-usable
        // AND above cannot fit one full row — the helper must return null so
        // Sora's own bounded placement stays (completion is never hidden or
        // faked by this decision).
        assertNull(
            FloeCompletionPlacement.flipAboveCaret(
                editorWidth = evidenceWidth, editorHeight = evidenceHeight,
                panelX = 300f, panelY = 30f,
                rowHeight = evidenceRow, dpUnit = evidenceDp,
                fullWidth = true, contentHeight = 135,
            ),
        )
    }

    @Test
    fun flipIsClampedByContentAndByThe200dpCap() {
        // Content smaller than the available strip hugs the content.
        val hugged = FloeCompletionPlacement.flipAboveCaret(
            editorWidth = evidenceWidth, editorHeight = evidenceHeight,
            panelX = 300f, panelY = evidencePanelY,
            rowHeight = evidenceRow, dpUnit = evidenceDp,
            fullWidth = true, contentHeight = 50,
        )
        assertNotNull(hugged)
        assertEquals(50, hugged!!.height)
        assertEquals((96f - 50f).toInt(), hugged.y)
        // A tall strip caps at Sora's own 200dp, follow-cursor width rule.
        val capped = FloeCompletionPlacement.flipAboveCaret(
            editorWidth = 860, editorHeight = 1000,
            panelX = 250f, panelY = 900f,
            rowHeight = evidenceRow, dpUnit = evidenceDp,
            fullWidth = false, contentHeight = 0,
        )
        assertNotNull(capped)
        assertEquals((200f * evidenceDp).toInt(), capped!!.height)
        assertEquals(minOf(300f * evidenceDp, 860 / 2f).toInt(), capped.width)
        assertEquals(250, capped.x)
        assertEquals((900f - evidenceRow / 2f - 400f).toInt(), capped.y)
    }

    @Test
    fun degenerateGeometryNeverProducesAWindowOrACrash() {
        assertNull(FloeCompletionPlacement.flipAboveCaret(860, 145, 0f, 120f, 0f, 2f, true, 100))
        assertNull(FloeCompletionPlacement.flipAboveCaret(860, 145, 0f, 120f, 48f, 0f, true, 100))
        assertNull(FloeCompletionPlacement.flipAboveCaret(0, 145, 0f, 120f, 48f, 2f, true, 100))
        assertNull(FloeCompletionPlacement.flipAboveCaret(860, 0, 0f, 120f, 48f, 2f, true, 100))
    }

    @Test
    fun subRowViewportPlacementIsASingleStepThatAlwaysConverges() {
        // The exact ANR shape: viewport shows ONE position (first == last),
        // Tab moved the selection to it or past it. The decision is one
        // bounded step — never an iteration — for every combination.
        assertEquals(FloeCompletionScroll.Placement.TOP, FloeCompletionScroll.resolve(0, 0, 0))
        assertEquals(FloeCompletionScroll.Placement.BOTTOM, FloeCompletionScroll.resolve(0, 0, 1))
        assertEquals(FloeCompletionScroll.Placement.TOP, FloeCompletionScroll.resolve(2, 6, 2))
        assertEquals(FloeCompletionScroll.Placement.TOP, FloeCompletionScroll.resolve(2, 6, 1))
        assertEquals(FloeCompletionScroll.Placement.BOTTOM, FloeCompletionScroll.resolve(2, 6, 6))
        assertEquals(FloeCompletionScroll.Placement.BOTTOM, FloeCompletionScroll.resolve(2, 6, 9))
        assertEquals(FloeCompletionScroll.Placement.NONE, FloeCompletionScroll.resolve(2, 6, 4))
        assertEquals(FloeCompletionScroll.Placement.NONE, FloeCompletionScroll.resolve(2, 6, 3))
        assertEquals(FloeCompletionScroll.Placement.NONE, FloeCompletionScroll.resolve(2, 6, 5))
        // Total + defensive: invalid inputs decide without throwing.
        assertEquals(FloeCompletionScroll.Placement.NONE, FloeCompletionScroll.resolve(0, 5, -1))
        assertEquals(FloeCompletionScroll.Placement.NONE, FloeCompletionScroll.resolve(5, 3, 4))
    }

    @Test
    fun everyAcceptedSuggestionPositionDecidesInExactlyOneStep() {
        // Totality across realistic list shapes: for any viewport and any
        // accepted-suggestion position, resolve answers one placement — the
        // loop that caused the ANR has no equivalent state space here.
        for (count in 1..12) {
            for (first in 0 until count) {
                for (last in first until count) {
                    for (position in 0 until count) {
                        val placement = FloeCompletionScroll.resolve(first, last, position)
                        assertTrue(placement in setOf(
                            FloeCompletionScroll.Placement.NONE,
                            FloeCompletionScroll.Placement.TOP,
                            FloeCompletionScroll.Placement.BOTTOM))
                        if (placement == FloeCompletionScroll.Placement.NONE) {
                            assertTrue("NONE only strictly inside the viewport",
                                position in (first + 1) until last)
                        }
                    }
                }
            }
        }
    }
}
