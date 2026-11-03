// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.timeline.MediaTimeline
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaTimelineTest {
    private fun clip(
        id: String,
        start: Double,
        end: Double,
        speed: Double = 1.0,
        transition: VideoTransitionKind = VideoTransitionKind.NONE,
    ) = VideoClip(
        id = id,
        assetID = "asset-$id",
        trimStart = start,
        trimEnd = end,
        speed = speed,
        leadingTransition = transition,
        transitionDuration = 0.4,
    )

    @Test
    fun placeClipsAppliesSpeedAndKeepsOrder() {
        val placed = MediaTimeline.placeClips(
            listOf(clip("a", 0.0, 10.0, speed = 2.0), clip("b", 0.0, 5.0)),
        )
        assertEquals(2, placed.size)
        assertEquals(0.0, placed[0].timelineStart, 0.0001)
        assertEquals(5.0, placed[0].timelineEnd, 0.0001)
        assertEquals(5.0, placed[1].timelineStart, 0.0001)
        assertEquals(10.0, placed[1].timelineEnd, 0.0001)
        assertEquals(10.0, MediaTimeline.placedDuration(placed), 0.0001)
    }

    @Test
    fun crossDissolveContractsTimelineLikeTheSwiftEngine() {
        val placed = MediaTimeline.placeClips(
            listOf(
                clip("a", 0.0, 6.0),
                clip("b", 0.0, 6.0, transition = VideoTransitionKind.CROSS_DISSOLVE),
            ),
        )
        assertEquals(5.6, placed[1].timelineStart, 0.0001)
        assertEquals(11.6, placed[1].timelineEnd, 0.0001)
        val windows = MediaTimeline.dissolveWindows(placed)
        assertEquals(1, windows.size)
        assertEquals("a", windows[0].fromClipID)
        assertEquals("b", windows[0].toClipID)
        assertEquals(0.4, windows[0].duration, 0.0001)
    }

    @Test
    fun sourceTimeUsesClipTrimAndSpeed() {
        val placed = MediaTimeline.placeClips(listOf(clip("a", 2.0, 8.0, speed = 2.0)))
        assertEquals(2.0, MediaTimeline.sourceTime(placed[0], 0.0)!!, 0.0001)
        assertEquals(5.0, MediaTimeline.sourceTime(placed[0], 1.5)!!, 0.0001)
        assertNull(MediaTimeline.sourceTime(placed[0], 100.0))
    }

    @Test
    fun captionBoundaryIsInclusiveLikeSwift() {
        val captions = listOf(
            CaptionSegment("c", 1.0, 2.0, "one"),
            CaptionSegment("d", 2.0, 3.0, "two"),
        )
        assertEquals("one", MediaTimeline.captionAt(2.0, captions)?.text)
        assertEquals("two", MediaTimeline.captionAt(2.5, captions)?.text)
        assertNull(MediaTimeline.captionAt(0.5, captions))
    }

    @Test
    fun musicPlacementClampsToTimelineAndDropsEmptyTails() {
        val placed = MediaTimeline.placeMusic(
            listOf(
                MusicClip("m1", "audio", offsetSeconds = 2.0, trimStart = 1.0, lengthSeconds = 10.0),
                MusicClip("m2", "audio", offsetSeconds = 9.98, trimStart = 0.0, lengthSeconds = 5.0),
            ),
            timelineEnd = 10.0,
        )
        assertEquals(1, placed.size)
        assertEquals(2.0, placed[0].timelineStart, 0.0001)
        assertEquals(10.0, placed[0].timelineEnd, 0.0001)
    }

    @Test
    fun coverTimeIsExplicitAndClamped() {
        assertEquals(5.0, MediaTimeline.coverTime(12.0, 5.0)!!, 0.0001)
        assertEquals(0.0, MediaTimeline.coverTime(-2.0, 5.0)!!, 0.0001)
        assertNull(MediaTimeline.coverTime(null, 5.0))
        assertNull(MediaTimeline.coverTime(Double.NaN, 5.0))
    }

    @Test
    fun shiftCaptionsKeepsOrderAndBounds() {
        val timeline = VideoTimeline(
            captions = listOf(
                CaptionSegment("c1", 1.0, 2.0, "a"),
                CaptionSegment("c2", 9.0, 9.5, "b"),
            ),
        )
        val shifted = MediaTimeline.shiftCaptions(timeline.captions, -2.0, 10.0)
        assertEquals(2, shifted.size)
        assertEquals(0.0, shifted[0].start, 0.0001)
        assertEquals(7.0, shifted[1].start, 0.0001)
        assertTrue(shifted.all { it.end > it.start })
    }
}
