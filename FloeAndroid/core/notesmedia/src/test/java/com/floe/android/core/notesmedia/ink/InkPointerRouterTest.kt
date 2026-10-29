// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InkPointerRouterTest {

    private fun sample(
        action: InkPointerAction,
        pointerId: Int = 0,
        pointerCount: Int = 1,
        tool: InkPointerKind = InkPointerKind.FINGER,
        x: Float = 10f,
        y: Float = 10f,
        button: Boolean = false,
        canceled: Boolean = false,
        pointers: List<InkPointerPosition> = listOf(InkPointerPosition(pointerId, x, y)),
    ) = InkPointerSample(
        action = action,
        pointerId = pointerId,
        pointerCount = pointerCount,
        toolType = tool,
        xPx = x,
        yPx = y,
        primaryButtonPressed = button,
        canceledBySystem = canceled,
        pointers = pointers,
    )

    @Test
    fun fingerWritesByDefault() {
        val router = InkPointerRouter { InkInputConfig() }
        val intents = router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.FINGER))
        assertTrue(intents.single() is InkGestureIntent.BeginStroke)
    }

    @Test
    fun penOnlyMakesFingersNavigateAndPenWrite() {
        val router = InkPointerRouter { InkInputConfig(penOnly = true, fingerWriting = false) }
        assertTrue(router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.FINGER)).single() is InkGestureIntent.Ignored)
        assertTrue(router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.PEN)).single() is InkGestureIntent.BeginStroke)
        assertTrue(router.onSample(sample(InkPointerAction.MOVE, tool = InkPointerKind.PEN)).single() is InkGestureIntent.ExtendStroke)
        assertTrue(router.onSample(sample(InkPointerAction.UP, tool = InkPointerKind.PEN)).single() is InkGestureIntent.EndStroke)
    }

    @Test
    fun secondFingerCancelsStrokeAndStartsTransform() {
        val router = InkPointerRouter { InkInputConfig() }
        router.onSample(sample(InkPointerAction.DOWN, pointerId = 0, x = 100f, y = 100f))
        val intents = router.onSample(
            sample(
                InkPointerAction.POINTER_DOWN,
                pointerId = 1,
                pointerCount = 2,
                x = 300f,
                y = 100f,
                pointers = listOf(InkPointerPosition(0, 100f, 100f), InkPointerPosition(1, 300f, 100f)),
            ),
        )
        assertEquals(2, intents.size)
        assertTrue(intents[0] is InkGestureIntent.CancelInk)
        assertTrue(intents[1] is InkGestureIntent.TransformStart)
        assertTrue(router.isTransforming)
        assertFalse(router.hasActiveStroke)
    }

    @Test
    fun pinchMoveReportsDeltaAndScale() {
        val router = InkPointerRouter { InkInputConfig() }
        router.onSample(
            sample(
                InkPointerAction.POINTER_DOWN,
                pointerId = 1,
                pointerCount = 2,
                x = 300f,
                y = 100f,
                pointers = listOf(InkPointerPosition(0, 100f, 100f), InkPointerPosition(1, 300f, 100f)),
            ),
        )
        val move = router.onSample(
            sample(
                InkPointerAction.MOVE,
                pointerId = 0,
                pointerCount = 2,
                x = 50f,
                y = 100f,
                pointers = listOf(InkPointerPosition(0, 50f, 100f), InkPointerPosition(1, 350f, 100f)),
            ),
        ).single()
        assertTrue(move is InkGestureIntent.TransformMove)
        val transform = move as InkGestureIntent.TransformMove
        assertEquals(0f, transform.dxPx, 0.01f)
        assertEquals(1.5f, transform.scaleFactor, 0.01f)
    }

    @Test
    fun pointerUpEndsTransformAndRemainingFingerDoesNotInk() {
        val router = InkPointerRouter { InkInputConfig() }
        router.onSample(
            sample(
                InkPointerAction.POINTER_DOWN,
                pointerId = 1,
                pointerCount = 2,
                pointers = listOf(InkPointerPosition(0, 100f, 100f), InkPointerPosition(1, 300f, 100f)),
            ),
        )
        val up = router.onSample(
            sample(
                InkPointerAction.POINTER_UP,
                pointerId = 1,
                pointerCount = 2,
                pointers = listOf(InkPointerPosition(0, 100f, 100f), InkPointerPosition(1, 300f, 100f)),
            ),
        )
        assertTrue(up.any { it is InkGestureIntent.TransformEnd })
        val remaining = router.onSample(
            sample(
                InkPointerAction.MOVE,
                pointerId = 0,
                pointerCount = 1,
                pointers = listOf(InkPointerPosition(0, 120f, 120f)),
            ),
        )
        assertTrue(remaining.single() is InkGestureIntent.Ignored)
    }

    @Test
    fun systemCancelRollsBackStroke() {
        val router = InkPointerRouter { InkInputConfig() }
        router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.PEN))
        val intents = router.onSample(sample(InkPointerAction.CANCEL, tool = InkPointerKind.PEN, canceled = true))
        assertTrue(intents.any { it is InkGestureIntent.CancelInk })
        assertFalse(router.hasActiveStroke)
    }

    @Test
    fun eraserToolAndEraserModeBothErase() {
        val tool = InkPointerRouter { InkInputConfig() }
        assertTrue(
            tool.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.ERASER)).single()
                is InkGestureIntent.BeginErase,
        )
        val mode = InkPointerRouter { InkInputConfig(eraserMode = true) }
        assertTrue(
            mode.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.PEN)).single()
                is InkGestureIntent.BeginErase,
        )
    }

    @Test
    fun mouseOnlyWritesWhilePrimaryButtonIsPressed() {
        val router = InkPointerRouter { InkInputConfig() }
        assertTrue(
            router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.MOUSE, button = false)).single()
                is InkGestureIntent.Ignored,
        )
        assertTrue(
            router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.MOUSE, button = true)).single()
                is InkGestureIntent.BeginStroke,
        )
    }

    @Test
    fun resetForgetsAnyOpenGesture() {
        val router = InkPointerRouter { InkInputConfig() }
        router.onSample(sample(InkPointerAction.DOWN, tool = InkPointerKind.PEN))
        router.reset()
        assertFalse(router.hasActiveStroke)
        assertTrue(router.onSample(sample(InkPointerAction.MOVE, tool = InkPointerKind.PEN)).single() is InkGestureIntent.Ignored)
    }
}
