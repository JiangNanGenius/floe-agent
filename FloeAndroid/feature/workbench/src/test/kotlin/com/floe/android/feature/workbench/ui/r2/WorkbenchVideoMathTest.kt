// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionSource
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkbenchVideoMathTest {
    @Test
    fun speedRetimesClipPlacement() {
        val clips = listOf(
            clip("a", trimStart = 0.0, trimEnd = 4.0, speed = 1.0),
            clip("b", trimStart = 0.0, trimEnd = 4.0, speed = 2.0),
        )
        val placed = WorkbenchVideoMath.placeClips(clips)
        assertEquals(4.0, placed[0].duration, 0.0001)
        assertEquals(2.0, placed[1].duration, 0.0001)
        assertEquals(4.0, placed[1].timelineStart, 0.0001)
        assertEquals(6.0, placed[1].timelineEnd, 0.0001)
        assertEquals(6.0, WorkbenchVideoMath.duration(VideoTimeline(clips = clips)), 0.0001)
    }

    @Test
    fun crossDissolveContractsTheTimeline() {
        val clips = listOf(
            clip("a", trimStart = 0.0, trimEnd = 4.0),
            clip(
                "b",
                trimStart = 0.0,
                trimEnd = 4.0,
                transition = VideoTransitionKind.CROSS_DISSOLVE,
                transitionDuration = 1.0,
            ),
        )
        val placed = WorkbenchVideoMath.placeClips(clips)
        assertEquals(3.0, placed[1].timelineStart, 0.0001)
        assertEquals(7.0, placed[1].timelineEnd, 0.0001)
        assertTrue(WorkbenchVideoMath.hasCrossDissolve(VideoTimeline(clips = clips)))
    }

    @Test
    fun timecodeAndFrameStepStayOnTheFrameGrid() {
        assertEquals("00:00:01:00", WorkbenchVideoMath.timecode(1.0, 30.0))
        assertEquals("00:00:00:29", WorkbenchVideoMath.timecode(29.0 / 30.0, 30.0))
        assertEquals(1.0 / 30.0, WorkbenchVideoMath.frameStep(0.0, 1, 30.0, 5.0), 0.00001)
        assertEquals(0.0, WorkbenchVideoMath.frameStep(0.0, -1, 30.0, 5.0), 0.00001)
    }

    @Test
    fun captionLookupIncludesBothEdges() {
        val caption = CaptionSegment(
            id = "c",
            start = 1.0,
            end = 2.0,
            text = "Hello",
            source = CaptionSource.MANUAL,
        )
        assertEquals(caption, WorkbenchVideoMath.captionAt(1.0, listOf(caption)))
        assertEquals(caption, WorkbenchVideoMath.captionAt(2.0, listOf(caption)))
        assertNull(WorkbenchVideoMath.captionAt(2.1, listOf(caption)))
    }

    @Test
    fun centeredCropFitsTheUnitSquare() {
        val wide = WorkbenchVideoMath.centeredCrop(1.0, 1920, 1080)!!
        assertEquals(1080.0 / 1920.0, wide.width, 0.0001)
        assertEquals(1.0, wide.height, 0.0001)
        assertEquals(0.5 - wide.width / 2.0, wide.x, 0.0001)
        val tall = WorkbenchVideoMath.centeredCrop(1.0, 1080, 1920)!!
        assertEquals(1.0, tall.width, 0.0001)
        assertEquals(1080.0 / 1920.0, tall.height, 0.0001)
    }

    @Test
    fun splitOffsetIsClampedInsideTheClip() {
        val placed = WorkbenchVideoMath.placeClips(
            listOf(clip("a", 0.0, 4.0)),
        ).single()
        assertEquals(0.01, WorkbenchVideoMath.splitOffset(0.0, placed)!!, 0.0001)
        assertEquals(3.98, WorkbenchVideoMath.splitOffset(3.99, placed)!!, 0.0001)
        assertNull(WorkbenchVideoMath.splitOffset(-1.0, placed))
    }

    private fun clip(
        id: String,
        trimStart: Double,
        trimEnd: Double,
        speed: Double = 1.0,
        transition: VideoTransitionKind = VideoTransitionKind.NONE,
        transitionDuration: Double = 0.4,
    ) = VideoClip(
        id = id,
        assetID = "asset-$id",
        trimStart = trimStart,
        trimEnd = trimEnd,
        speed = speed,
        leadingTransition = transition,
        transitionDuration = transitionDuration,
    )
}
