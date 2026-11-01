// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import com.floe.android.core.workbenchmedia.timeline.DissolveWindow
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class C03CompositionLayoutTest {
    private fun dissolve(from: String, to: String, start: Double, end: Double) =
        DissolveWindow(fromClipID = from, toClipID = to, start = start, end = end)

    @Test
    fun assignsTwoLanesAndRendersSourceOverCrossDissolve() {
        val layout = CompositionLayoutMath.layout(
            rawInputs = listOf(
                LayoutInput("a", 0.0, 5.0),
                LayoutInput("b", 4.6, 9.6),
            ),
            dissolves = listOf(dissolve("a", "b", 4.6, 5.0)),
        )
        assertEquals(listOf("a"), layout.lanes[0])
        assertEquals(listOf("b"), layout.lanes[1])
        assertEquals(0, layout.laneOf.getValue("a"))
        assertEquals(1, layout.laneOf.getValue("b"))

        // Primary lane 0 is on top and is the outgoing clip: 1 -> 0.
        assertEquals(0.5f, CompositionLayoutMath.alphaAt(0, 4.8, layout), 0.0001f)
        // The incoming clip underneath stays fully opaque.
        assertEquals(1f, CompositionLayoutMath.alphaAt(1, 4.8, layout), 0.0001f)
        // After its clip ends the top lane is transparent, not a held frame.
        assertEquals(0f, CompositionLayoutMath.alphaAt(0, 5.2, layout), 0.0001f)
        assertEquals(1f, CompositionLayoutMath.alphaAt(1, 5.2, layout), 0.0001f)
    }

    @Test
    fun incomingOnTopFadesInOverTheOutgoingBottomLane() {
        val layout = CompositionLayoutMath.layout(
            rawInputs = listOf(
                LayoutInput("a", 0.0, 5.0),
                LayoutInput("b", 4.6, 9.6),
                LayoutInput("c", 9.2, 14.2),
            ),
            dissolves = listOf(
                dissolve("a", "b", 4.6, 5.0),
                dissolve("b", "c", 9.2, 9.6),
            ),
        )
        assertEquals(listOf("a", "c"), layout.lanes[0])
        assertEquals(listOf("b"), layout.lanes[1])

        // B -> C: lane 0 (C) is on top and fades in; lane 1 (B) stays opaque.
        assertEquals(0.5f, CompositionLayoutMath.alphaAt(0, 9.4, layout), 0.0001f)
        assertEquals(1f, CompositionLayoutMath.alphaAt(1, 9.4, layout), 0.0001f)
        // A -> B: lane 0 (A) is the outgoing top clip.
        assertEquals(0.5f, CompositionLayoutMath.alphaAt(0, 4.8, layout), 0.0001f)
        assertEquals(1f, CompositionLayoutMath.alphaAt(1, 4.8, layout), 0.0001f)
    }

    @Test
    fun threeSimultaneousClipsAreRefusedInsteadOfDroppingAPicture() {
        try {
            CompositionLayoutMath.layout(
                rawInputs = listOf(
                    LayoutInput("a", 0.0, 10.0),
                    LayoutInput("b", 1.0, 11.0),
                    LayoutInput("c", 2.0, 12.0),
                ),
                dissolves = listOf(
                    dissolve("a", "b", 1.0, 2.0),
                    dissolve("b", "c", 2.0, 3.0),
                ),
            )
            fail("A three-way overlap cannot fit the verified two-sequence plan")
        } catch (failure: MediaRefusal) {
            assertEquals(UNSUPPORTED_TRANSITION, failure.code)
        }
    }

    @Test
    fun gapsAndEndedClipsAreFullyTransparent() {
        val layout = CompositionLayoutMath.layout(
            rawInputs = listOf(LayoutInput("a", 1.0, 2.0)),
            dissolves = emptyList(),
        )
        assertEquals(0f, CompositionLayoutMath.alphaAt(0, 0.5, layout), 0.0001f)
        assertEquals(1f, CompositionLayoutMath.alphaAt(0, 1.5, layout), 0.0001f)
        assertEquals(0f, CompositionLayoutMath.alphaAt(0, 2.5, layout), 0.0001f)
        assertEquals(0f, CompositionLayoutMath.alphaAt(1, 1.5, layout), 0.0001f)
    }

    @Test
    fun aWindowCuttingIntoADissolveKeepsTheOriginalProgress() {
        // A windowed preview can start at local 0 while the real dissolve began
        // 0.2 s before the window. At local 0 the outgoing clip must already be
        // half faded, not restart at full opacity.
        val layout = CompositionLayoutMath.layout(
            rawInputs = listOf(
                LayoutInput("a", 0.0, 0.2),
                LayoutInput("b", 0.0, 0.2),
            ),
            dissolves = listOf(dissolve("a", "b", -0.2, 0.2)),
        )
        assertEquals(0.5f, CompositionLayoutMath.alphaAt(0, 0.0, layout), 0.0001f)
        assertEquals(1f, CompositionLayoutMath.alphaAt(1, 0.0, layout), 0.0001f)
    }
}

class C03CompositionCoverageTest {
    @Test
    fun coverageSegmentsLoopTheSourceToTheExactGapDuration() {
        val segments = CompositionCoverage.segments(
            gapDurationUs = 12_000_000L,
            sourceStartUs = 1_000_000L,
            sourceEndUs = 6_000_000L,
        )
        assertEquals(3, segments.size)
        assertEquals(12_000_000L, segments.sumOf { it.durationUs })
        assertEquals(1_000_000L, segments[0].startUs)
        assertEquals(6_000_000L, segments[0].endUs)
        assertEquals(1_000_000L, segments[1].startUs)
        assertEquals(3_000_000L, segments[2].endUs)
    }

    @Test
    fun noCoverageForAnEmptyGapOrEmptySource() {
        assertEquals(emptyList<CoverageSegment>(), CompositionCoverage.segments(0L, 0L, 5_000_000L))
        assertEquals(emptyList<CoverageSegment>(), CompositionCoverage.segments(1_000_000L, 4L, 4L))
    }
}
