// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import org.junit.Assert.*
import org.junit.Test

class RemoteVncPointerTest {
    private val fit = vncTransform(1000f, 2000f, 1000, 1000, 1f, 0f, 0f)
    private fun pointer(mode: VncInputMode = VncInputMode.TRACKPAD, slop: Float = 8f) =
        VncTouchPointer(1000, 1000, mode, 300, 500, slop)
    private fun buttons(actions: List<VncPointerAction>) = actions.filterIsInstance<VncPointerAction.Button>()

    @Test fun singleTapInLetterboxClicksCurrentPointerOnlyAfterDoubleTapWindow() {
        val p = pointer()
        p.setAbsolute(243, 317)
        assertTrue(p.down(800f, 30f, 0, fit).isEmpty())
        assertTrue(p.up(20).isEmpty())
        assertTrue(p.tick(319).isEmpty())
        assertEquals(listOf(
            VncPointerAction.Button("left", true, 243, 317),
            VncPointerAction.Button("left", false, 243, 317),
        ), p.tick(320))
        assertTrue(p.tick(1000).isEmpty())
    }

    @Test fun doubleTapAnywhereEmitsOnlyRightAndNeverAnEarlyLeft() {
        val p = pointer()
        assertTrue(p.down(20f, 20f, 0, fit).isEmpty())
        assertTrue(p.up(10).isEmpty())
        assertTrue(p.down(900f, 1900f, 100, fit).isEmpty())
        val actions = buttons(p.up(120))
        assertEquals(listOf("right", "right"), actions.map { it.button })
        assertEquals(listOf(true, false), actions.map { it.down })
        assertTrue(p.tick(1000).isEmpty())
    }

    @Test fun expiredFirstTapAndLaterTapProduceTwoLeftClicks() {
        val p = pointer()
        p.down(10f, 10f, 0, fit); p.up(10)
        val first = buttons(p.down(10f, 10f, 400, fit))
        p.up(420)
        val second = buttons(p.tick(720))
        assertEquals(listOf("left", "left"), first.map { it.button })
        assertEquals(first, second)
    }

    @Test fun trackpadMotionIsRelativeAndDoesNotPressLeft() {
        val p = pointer()
        p.setAbsolute(100, 200)
        p.down(800f, 20f, 0, fit)
        val actions = p.move(850f, 40f, fit)
        assertEquals(VncPointerPosition(150f, 220f), p.position)
        assertTrue(buttons(actions).isEmpty())
        assertTrue(p.up(80).isEmpty())
        assertTrue(p.tick(1000).isEmpty())
    }

    @Test fun relativeFractionalMovesAccumulateAndClampAtRealFrameEdges() {
        val p = pointer(slop = 0f)
        p.setAbsolute(100, 100); p.down(700f, 20f, 0, fit)
        repeat(10) { p.move(700f + (it + 1) * 0.25f, 20f, fit) }
        assertEquals(102.5f, p.position.x, 0.001f)
        p.move(100_000f, 100_000f, fit)
        assertEquals(999 to 999, p.position.pixel)
        p.move(-100_000f, -100_000f, fit)
        assertEquals(0 to 0, p.position.pixel)
    }

    @Test fun longHoldStartsDragAndCancelReleasesWithoutAnyClickAfterward() {
        val p = pointer()
        p.down(600f, 20f, 0, fit)
        assertTrue(p.tick(499).isEmpty())
        assertEquals(listOf(true), buttons(p.tick(500)).map { it.down })
        assertTrue(buttons(p.move(630f, 50f, fit)).isEmpty())
        val released = buttons(p.cancel())
        assertEquals(listOf("left"), released.map { it.button })
        assertEquals(listOf(false), released.map { it.down })
        assertTrue(p.up(900).isEmpty())
        assertTrue(p.tick(2000).isEmpty())
        assertNull(p.deadline)
    }

    @Test fun longDragLiftsButtonAtFinalRelativeLocation() {
        val p = pointer()
        p.setAbsolute(200, 300); p.down(500f, 20f, 0, fit); p.tick(500)
        p.move(530f, 50f, fit)
        assertEquals(listOf(VncPointerAction.Button("left", false, 230, 330)), p.up(600))
    }

    @Test fun takeoverOrModeChangeDropsPendingClicksAndHeldButtons() {
        val p = pointer()
        p.down(20f, 20f, 0, fit); p.up(20)
        p.cancel() // actual UI calls this on multitouch takeover/menu/background
        assertTrue(p.tick(1000).isEmpty())
        p.down(20f, 20f, 2000, fit); p.tick(2500)
        assertEquals(listOf(false), buttons(p.changeMode(VncInputMode.DIRECT)).map { it.down })
        assertTrue(p.up(2600).isEmpty())
        assertTrue(p.tick(3000).isEmpty())
    }

    @Test fun directTouchMapsToFingerAndConsecutiveTapsRemainLeftDoubleClick() {
        val p = pointer(VncInputMode.DIRECT)
        assertTrue(p.down(100f, 100f, 0, fit).isEmpty()) // black letterbox
        assertTrue(p.up(10).isEmpty())
        p.down(123f, 745f, 20, fit)
        val first = p.up(40)
        p.down(123f, 745f, 100, fit)
        assertEquals(first, p.up(120))
        assertEquals(listOf(VncPointerAction.Button("left", true, 123, 245),
            VncPointerAction.Button("left", false, 123, 245)), first)
    }

    @Test fun directDragStartsAtDownPointAndCancellationReleases() {
        val p = pointer(VncInputMode.DIRECT)
        p.down(100f, 700f, 0, fit)
        val moved = p.move(140f, 740f, fit)
        assertEquals(VncPointerAction.Button("left", true, 100, 200), moved.first())
        assertEquals(VncPointerPosition(140f, 240f), p.position)
        assertEquals(listOf(VncPointerAction.Button("left", false, 140, 240)), p.cancel())
    }

    @Test fun directLongPressRightClickDoesNotAddLeftOnLift() {
        val p = pointer(VncInputMode.DIRECT)
        p.down(100f, 700f, 0, fit)
        assertEquals(listOf("right", "right"), buttons(p.tick(500)).map { it.button })
        assertTrue(p.up(800).isEmpty())
    }

    @Test fun resizeClampsRatherThanRecenterAndCancelsPendingGesture() {
        val p = pointer()
        p.setAbsolute(800, 900); p.down(10f, 10f, 0, fit); p.up(10)
        p.resize(640, 480)
        assertEquals(639 to 479, p.position.pixel)
        assertTrue(p.tick(1000).isEmpty())
        val empty = VncTouchPointer(0, 0, VncInputMode.TRACKPAD, 300, 500, 8f)
        empty.resize(1000, 1000)
        assertEquals(VncPointerPosition(499.5f, 499.5f), empty.position)
    }

    @Test fun storedSelectionIsStableAndUnknownValuesKeepOriginalDirectBehavior() {
        assertEquals(VncInputMode.TRACKPAD, VncInputMode.restore("trackpad"))
        assertEquals(VncInputMode.DIRECT, VncInputMode.restore("direct"))
        assertEquals(VncInputMode.DIRECT, VncInputMode.restore(null))
        assertEquals(VncInputMode.DIRECT, VncInputMode.restore("future_value"))
    }

    @Test fun zoomedPointerPansIntoViewWithoutOverscrollingImage() {
        val t = vncTransform(1000f, 1000f, 1000, 1000, 2f, 0f, 0f)
        val pan = vncPanToPointer(t, VncPointerPosition(950f, 50f), 1000f, 1000f, 2f, 0f, 0f, 24f)
        val next = vncTransform(1000f, 1000f, 1000, 1000, 2f, pan.first, pan.second)
        assertEquals(976f, next.offsetX + 950f * next.scale, 0.001f)
        assertEquals(24f, next.offsetY + 50f * next.scale, 0.001f)
        assertTrue(pan.first >= -500f && pan.second <= 500f)
    }
}
