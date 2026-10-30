// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic coverage for the finger-pan arithmetic that the Compose
 * view wires to its drag detector: direction, fractional accumulation,
 * transcript clamping and degenerate input. The view's gesture *decision*
 * (long-press selection vs plain drag pan) is exercised on device; nothing
 * here re-implements the renderer or the emulator.
 */
class TerminalScrollPanTest {
    private fun step(
        rows: Int,
        dragY: Float,
        carry: Float = 0f,
        cell: Float = 20f,
        transcript: Int = 100,
    ) = TerminalScrollPan.step(rows, carry, dragY, cell, transcript)

    @Test
    fun dragDownRevealsOlderRowsAndDragUpReturnsTowardThePrompt() {
        // One cell of downward finger movement = one older row.
        assertEquals(3, step(rows = 2, dragY = 20f).scrollRows)
        assertEquals(2, step(rows = 3, dragY = -20f).scrollRows)
        // A two-cell flick moves exactly two rows.
        assertEquals(5, step(rows = 3, dragY = 40f).scrollRows)
        assertEquals(0, step(rows = 2, dragY = -40f).scrollRows)
    }

    @Test
    fun fractionalRowsCarryAcrossMoveEvents() {
        val first = step(rows = 0, dragY = 8f, cell = 20f) // 0.4 row
        assertEquals(0, first.scrollRows)
        assertEquals(0.4f, first.carry, 0.0001f)

        val second = TerminalScrollPan.step(first.scrollRows, first.carry, 8f, 20f, 100)
        assertEquals(0, second.scrollRows)
        assertEquals(0.8f, second.carry, 0.0001f)

        val third = TerminalScrollPan.step(second.scrollRows, second.carry, 8f, 20f, 100)
        assertEquals(1, third.scrollRows) // 1.2 rows -> one whole row + 0.2
        assertEquals(0.2f, third.carry, 0.0001f)

        // Reversing direction cancels the carried fraction instead of
        // producing an immediate opposite jump.
        val reversed = TerminalScrollPan.step(third.scrollRows, third.carry, -6f, 20f, 100)
        assertEquals(1, reversed.scrollRows)
        assertEquals(-0.1f, reversed.carry, 0.0001f)
    }

    @Test
    fun clampsToTheRealTranscriptAndDropsHiddenDebtAtTheBound() {
        // At the live bottom, upward motion cannot go below row 0.
        assertEquals(0, step(rows = 0, dragY = -60f, transcript = 12).scrollRows)
        // Pulling past the oldest row clamps to the transcript bound.
        val top = step(rows = 10, dragY = 90f, transcript = 12)
        assertEquals(12, top.scrollRows)
        assertEquals(0f, top.carry, 0.0001f)
        // No hidden debt: reversing at the top responds on the next row.
        val back = TerminalScrollPan.step(top.scrollRows, top.carry, -20f, 20f, 12)
        assertEquals(11, back.scrollRows)
        // Sub-row outward motion at a bound does not accumulate either.
        val edge = TerminalScrollPan.step(0, 0f, -8f, 20f, 12)
        assertEquals(0, edge.scrollRows)
        assertEquals(0f, edge.carry, 0.0001f)
        assertEquals(12, TerminalScrollPan.step(12, 0f, 8f, 20f, 12).scrollRows)
    }

    @Test
    fun zeroTranscriptNeverScrollsOrCarries() {
        val result = step(rows = 7, carry = 0.5f, dragY = 40f, transcript = 0)
        assertEquals(0, result.scrollRows)
        assertEquals(0f, result.carry, 0.0001f)
        // A negative bound is as empty as a zero one.
        assertEquals(0, step(rows = 7, dragY = 40f, transcript = -4).scrollRows)
    }

    @Test
    fun nonFiniteOrDegenerateInputLeavesTheViewportUnchanged() {
        val nan = step(rows = 4, carry = 0.25f, dragY = Float.NaN)
        assertEquals(4, nan.scrollRows)
        assertEquals(0.25f, nan.carry, 0.0001f)

        val infinite = step(rows = 4, carry = 0.25f, dragY = Float.POSITIVE_INFINITY)
        assertEquals(4, infinite.scrollRows)
        assertEquals(0.25f, infinite.carry, 0.0001f)

        for (cell in listOf(0f, -20f, Float.NaN, Float.POSITIVE_INFINITY)) {
            val degenerate = TerminalScrollPan.step(4, 0.25f, 20f, cell, 100)
            assertEquals(4, degenerate.scrollRows)
            assertEquals(0.25f, degenerate.carry, 0.0001f)
        }
    }

    @Test
    fun hugeFiniteDragClampsWithoutOverflow() {
        val down = step(rows = 3, dragY = Float.MAX_VALUE, cell = 1f, transcript = 50)
        assertEquals(50, down.scrollRows)
        assertEquals(0f, down.carry, 0.0001f)

        val up = step(rows = 3, dragY = -Float.MAX_VALUE, cell = 1f, transcript = 50)
        assertEquals(0, up.scrollRows)
        assertEquals(0f, up.carry, 0.0001f)
    }

    @Test
    fun panStepsFeedTheRealTranscriptViewport() {
        val engine = G04TerminalEngine(20, 5, host = object : TerminalEngineHost {
            override fun writeToPty(bytes: ByteArray) = Unit
            override fun log(level: String, message: String) = Unit
        })
        for (line in 1..30) engine.feed("line$line\r\n".toByteArray(Charsets.UTF_8))
        val transcriptRows = engine.activeTranscriptRows()
        assertTrue("test needs a real transcript, got $transcriptRows", transcriptRows >= 10)

        val bottom = engine.viewportText(0)
        val scrolledTo = TerminalScrollPan.step(0, 0f, 60f, 20f, transcriptRows)
        assertEquals(3, scrolledTo.scrollRows)
        val scrolled = engine.viewportText(scrolledTo.scrollRows)
        assertTrue("scrolled viewport must have content", scrolled.isNotEmpty())
        assertNotEquals("panning must move the rendered viewport", bottom, scrolled)

        // A drag past the end of the real transcript clamps to the newest
        // older row the engine actually retains.
        val top = TerminalScrollPan.step(
            0, 0f, 20f * (transcriptRows + 5), 20f, transcriptRows,
        )
        assertEquals(transcriptRows, top.scrollRows)
        assertNotEquals(bottom, engine.viewportText(top.scrollRows))

        // Panning back by the whole transcript returns to the live bottom.
        val back = TerminalScrollPan.step(
            top.scrollRows, 0f, -20f * transcriptRows, 20f, transcriptRows,
        )
        assertEquals(0, back.scrollRows)
    }
}
