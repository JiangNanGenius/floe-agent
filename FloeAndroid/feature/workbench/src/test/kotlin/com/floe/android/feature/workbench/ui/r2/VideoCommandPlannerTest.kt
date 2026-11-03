// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.workbench.OptionalUpdate
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoEditCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoCommandPlannerTest {
    @Test
    fun updateClipClampsToTheEngineVocabulary() {
        val command = VideoCommandPlanner.updateClip(
            id = "clip",
            trimStart = -2.0,
            speed = 99.0,
            volume = -1.0,
            rotationDegrees = 45.0,
            transitionDuration = 8.0,
        )
        assertEquals(0.0, command.trimStart!!, 0.0)
        assertEquals(16.0, command.speed!!, 0.0)
        assertEquals(0.0, command.volume!!, 0.0)
        assertNull(command.rotationDegrees)
        assertEquals(2.0, command.transitionDuration!!, 0.0)
        assertTrue(command.crop is OptionalUpdate.Unchanged)
    }

    @Test
    fun explicitCropClearStaysDistinctFromUnchanged() {
        val cleared = VideoCommandPlanner.updateClip("clip", crop = OptionalUpdate.Clear)
        assertTrue(cleared.crop is OptionalUpdate.Clear)
        val set = VideoCommandPlanner.updateClip(
            "clip",
            crop = OptionalUpdate.Set(NormalizedRect(0.1, 0.1, 0.5, 0.5)),
        )
        assertTrue(set.crop is OptionalUpdate.Set)
    }

    @Test
    fun captionRequiresNonBlankTextAndPositiveRange() {
        assertNull(VideoCommandPlanner.addCaption("   ", 1.0, 2.0))
        val command = VideoCommandPlanner.addCaption("Hello", 3.0, 1.0)!!
        assertEquals(3.0, command.caption.start, 0.0)
        assertTrue(command.caption.end > command.caption.start)
        assertNull(VideoCommandPlanner.updateCaption("id", text = "  "))
    }

    @Test
    fun addMusicCapsTheDuration() {
        val command = VideoCommandPlanner.addMusic("audio", 99_999.0)
        assertEquals(3600.0, command.music.lengthSeconds, 0.0)
        assertEquals(0.0, command.music.offsetSeconds, 0.0)
        assertEquals(1.0, command.music.volume, 0.0)
    }

    @Test
    fun moveClipReturnsACompleteReorderOrNullAtTheEdge() {
        val clips = listOf(clip("a"), clip("b"), clip("c"))
        val moved = VideoCommandPlanner.moveClip(clips, "b", earlier = true)!!
        assertEquals(listOf("b", "a", "c"), moved.orderedIDs)
        assertNull(VideoCommandPlanner.moveClip(clips, "a", earlier = true))
        assertNull(VideoCommandPlanner.moveClip(clips, "c", earlier = false))
    }

    @Test
    fun canvasAndRotationUseDiscreteValidValues() {
        val canvas = VideoCommandPlanner.setCanvas(99_999, 1, 999.0)
        assertEquals(8192, canvas.width)
        assertEquals(2, canvas.height)
        assertEquals(120.0, canvas.frameRate!!, 0.0)
        val update = VideoCommandPlanner.updateClip("clip", rotationDegrees = 270.0)
        assertEquals(270.0, update.rotationDegrees!!, 0.0)
        // The concrete command type is fixed by updateClip's return type; assert
        // the carried identity/wire identity instead of a tautological is-check.
        assertEquals("clip", update.id)
        assertEquals("updateClip", update.wireType())
    }

    private fun clip(id: String) = VideoClip(
        id = id,
        assetID = "asset-$id",
        trimStart = 0.0,
        trimEnd = 2.0,
    )
}
