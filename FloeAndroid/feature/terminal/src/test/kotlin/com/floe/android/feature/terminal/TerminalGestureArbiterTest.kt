// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import com.floe.android.feature.terminal.TerminalGestureArbiter.Mode
import com.floe.android.feature.terminal.TerminalGestureArbiter.Release
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Deterministic coverage of the SAME arbiter the Compose view drives: which
 * pointer gesture owns the surface (pan vs long-press selection vs tap vs
 * double tap) and that a selection gesture produces no clipboard side effect
 * in the decision layer. Rendering/device behaviour remains a candidate02
 * device check, not a claim of this JVM test.
 */
class TerminalGestureArbiterTest {
    private fun arbiter(
        slop: Float = 8f,
        longPressMillis: Long = 400,
        doubleTapMillis: Long = 300,
        doubleTapMinMillis: Long = 40,
    ) = TerminalGestureArbiter(slop, longPressMillis, doubleTapMillis, doubleTapMinMillis)

    @Test
    fun dragBeforeLongPressPansAndNeverBecomesSelection() {
        val gesture = arbiter()
        gesture.down(100f, 100f, 0)
        assertEquals(Mode.Undecided, gesture.move(100f, 104f, 50))
        assertEquals(Mode.Pan, gesture.move(100f, 120f, 80))
        // Holding longer mid-drag must not switch to selection.
        assertEquals(Mode.Pan, gesture.move(100f, 300f, 900))
        assertEquals(Release.None, gesture.up(950))
    }

    @Test
    fun holdThenCrossSlopSelects() {
        val gesture = arbiter()
        gesture.down(100f, 100f, 0)
        // Sub-slop movement while waiting is still undecided.
        assertEquals(Mode.Undecided, gesture.move(101f, 103f, 200))
        assertEquals(Mode.Undecided, gesture.move(101f, 106f, 390))
        assertEquals(Mode.Selection, gesture.move(101f, 130f, 450))
        assertEquals(Mode.Selection, gesture.move(101f, 160f, 500))
        assertEquals(Release.None, gesture.up(520))
    }

    @Test
    fun longPressWithoutMovementSelectsOnReleaseAndIsNotADoubleTap() {
        val gesture = arbiter()
        gesture.down(100f, 100f, 0)
        assertEquals(Mode.Undecided, gesture.move(100f, 102f, 300))
        assertEquals(Release.LongPress, gesture.up(420))
        // Long press clears double-tap memory: the next quick tap is a tap.
        gesture.down(100f, 100f, 450)
        assertEquals(Release.Tap, gesture.up(500))
    }

    @Test
    fun quickSecondTapIsDoubleTapAndMemoryResets() {
        val gesture = arbiter()
        gesture.down(10f, 10f, 0)
        assertEquals(Release.Tap, gesture.up(50))
        gesture.down(10f, 10f, 120)
        assertEquals(Release.DoubleTap, gesture.up(160))
        // A third tap in the same window is a fresh single tap.
        gesture.down(10f, 10f, 200)
        assertEquals(Release.Tap, gesture.up(250))
    }

    @Test
    fun slowSecondTapIsSingleAndTooFastSecondTapIsSingle() {
        val gesture = arbiter()
        gesture.down(10f, 10f, 0)
        assertEquals(Release.Tap, gesture.up(50))
        gesture.down(10f, 10f, 200)
        assertEquals(Release.Tap, gesture.up(400)) // 350 ms after the first up

        val fast = arbiter()
        fast.down(10f, 10f, 0)
        assertEquals(Release.Tap, fast.up(100))
        fast.down(10f, 10f, 110)
        assertEquals(Release.Tap, fast.up(120)) // 20 ms - below doubleTapMin
    }

    @Test
    fun dragBetweenTapsClearsDoubleTapMemory() {
        val gesture = arbiter()
        gesture.down(0f, 0f, 0)
        assertEquals(Release.Tap, gesture.up(50))
        gesture.down(0f, 0f, 100)
        assertEquals(Mode.Pan, gesture.move(0f, 40f, 150))
        assertEquals(Release.None, gesture.up(200))
        gesture.down(0f, 0f, 250)
        assertEquals(Release.Tap, gesture.up(300))
    }

    @Test
    fun jitterWithinSlopIsStillATap() {
        val gesture = arbiter()
        gesture.down(50f, 50f, 0)
        assertEquals(Mode.Undecided, gesture.move(53f, 53f, 80))
        assertEquals(Mode.Undecided, gesture.move(54f, 54f, 120))
        assertEquals(Release.Tap, gesture.up(140))
    }

    @Test
    fun cancelLeavesNoReleaseOrDoubleTapMemory() {
        val gesture = arbiter()
        gesture.down(0f, 0f, 0)
        assertEquals(Mode.Pan, gesture.move(0f, 40f, 100))
        gesture.cancel()
        assertEquals(Release.None, gesture.up(150))
        gesture.down(0f, 0f, 180)
        assertEquals(Release.Tap, gesture.up(220))
    }

    @Test
    fun selectionIsTheOnlyReleaseEffectOfALongPressDrag() {
        // The arbiter has no paste/copy effect at all: a long-press drag can
        // only report Selection through move() and None on release. The view
        // is responsible for selecting cells; clipboard actions stay on the
        // explicit toolbar buttons and double tap.
        val gesture = arbiter()
        gesture.down(0f, 0f, 0)
        assertEquals(Mode.Selection, gesture.move(0f, 30f, 500))
        assertEquals(Release.None, gesture.up(520))
    }
}
