// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored R2 contract tests. NOT RUN in the contracts09 package; Main runs
 * them with the integrated batch. They assert the closed command vocabulary
 * and the exact actual-Swift VideoTimeline keys, not rendering behavior.
 */
class VideoEditCommandR2Test {
    @Test
    fun `video command wire types are closed unique and complete`() {
        val commands: List<VideoEditCommand> = listOf(
            VideoEditCommand.AppendClip(
                VideoClip(
                    id = "c1", assetID = "a1", trimStart = 0.0, trimEnd = 1.0)),
            VideoEditCommand.UpdateClip(id = "c1"),
            VideoEditCommand.ReorderClips(listOf("c1")),
            VideoEditCommand.SplitClip(id = "c1", atTimelineSeconds = 0.5),
            VideoEditCommand.DuplicateClip("c1"),
            VideoEditCommand.RemoveClip("c1"),
            VideoEditCommand.SetPrimaryAudio(volume = 0.5, muted = false),
            VideoEditCommand.SetCover(null),
            VideoEditCommand.ShiftCaptions(0.25),
            VideoEditCommand.AddMusic(
                MusicClip(
                    id = "m1", assetID = "a2", offsetSeconds = 0.0,
                    trimStart = 0.0, lengthSeconds = 2.0)),
            VideoEditCommand.UpdateMusic(id = "m1", volume = 0.5),
            VideoEditCommand.RemoveMusic("m1"),
            VideoEditCommand.AddCaption(
                CaptionSegment(id = "s1", start = 0.0, end = 1.0, text = "Hi")),
            VideoEditCommand.UpdateCaption(id = "s1", text = "Hello"),
            VideoEditCommand.RemoveCaption("s1"),
            VideoEditCommand.SetCaptionStyle(CaptionStyle()),
            VideoEditCommand.SetCanvas(width = 1920, height = 1080, frameRate = 30.0),
        )
        assertEquals(17, commands.size)
        assertEquals(VideoCommandWire.ALL_TYPES.toSet(), commands.map { it.wireType() }.toSet())
        assertEquals(17, commands.map { it.wireType() }.distinct().size)
        assertEquals(VideoCommandWire.ALL_TYPES.toSet(), VideoCommandWire.FIELDS.keys)
    }

    @Test
    fun `video command field map matches the shared Swift engine names`() {
        assertEquals(
            setOf("clip"), VideoCommandWire.FIELDS[VideoCommandWire.APPEND_CLIP])
        assertEquals(
            setOf(
                "id", "trimStart", "trimEnd", "speed", "volume", "isMuted",
                "rotationDegrees", "crop", "leadingTransition", "transitionDuration"),
            VideoCommandWire.FIELDS[VideoCommandWire.UPDATE_CLIP])
        assertEquals(
            setOf("id", "start", "end", "text"),
            VideoCommandWire.FIELDS[VideoCommandWire.UPDATE_CAPTION])
        assertEquals(
            setOf("id", "offsetSeconds", "trimStart", "lengthSeconds", "volume",
                "fadeInSeconds", "fadeOutSeconds"),
            VideoCommandWire.FIELDS[VideoCommandWire.UPDATE_MUSIC])
        assertEquals(
            setOf("width", "height", "frameRate"),
            VideoCommandWire.FIELDS[VideoCommandWire.SET_CANVAS])
    }

    @Test
    fun `update clip keeps unchanged clear and set crop distinct`() {
        val unchanged = VideoEditCommand.UpdateClip(id = "c1")
        val clear = VideoEditCommand.UpdateClip(id = "c1", crop = OptionalUpdate.Clear)
        val set = VideoEditCommand.UpdateClip(
            id = "c1", crop = OptionalUpdate.Set(NormalizedRect.UNIT))
        assertTrue(unchanged.crop is OptionalUpdate.Unchanged)
        assertTrue(clear.crop is OptionalUpdate.Clear)
        assertEquals(NormalizedRect.UNIT, (set.crop as OptionalUpdate.Set).value)
        assertEquals("crossDissolve", VideoTransitionKind.CROSS_DISSOLVE.wire)
        assertEquals("manual", CaptionSource.MANUAL.wire)
    }

    @Test
    fun `typed timeline mirrors the actual swift model fields and defaults`() {
        val timeline = VideoTimeline(
            clips = listOf(
                VideoClip(
                    id = "c1", assetID = "a1", trimStart = 0.0, trimEnd = 2.0,
                    speed = 1.5, volume = 0.8, isMuted = false,
                    rotationDegrees = 90.0, crop = NormalizedRect.UNIT,
                    leadingTransition = VideoTransitionKind.CROSS_DISSOLVE,
                    transitionDuration = 0.5)),
            music = listOf(
                MusicClip(
                    id = "m1", assetID = "a2", offsetSeconds = 0.1,
                    trimStart = 0.0, lengthSeconds = 2.0, volume = 0.5)),
            captions = listOf(
                CaptionSegment(
                    id = "s1", start = 0.0, end = 1.0, text = "Hi",
                    source = CaptionSource.MANUAL)),
            captionStyle = CaptionStyle(alignment = CaptionAlignment.CENTER),
            coverTime = 1.0,
        )
        assertEquals(1, timeline.clips.size)
        assertEquals(1, timeline.music.size)
        assertEquals(1, timeline.captions.size)
        assertEquals(1.0, timeline.primaryVolume, 0.0)
        assertEquals(false, timeline.primaryMuted)
        assertEquals(VideoTransitionKind.CROSS_DISSOLVE, timeline.clips.single().leadingTransition)
        assertEquals(CaptionAlignment.CENTER, timeline.captionStyle.alignment)
    }

    @Test
    fun `timeline wire key lists are the exact swift codable keys`() {
        assertEquals(
            listOf("clips", "music", "captions", "captionStyle", "coverTime",
                "primaryVolume", "primaryMuted"),
            VideoTimelineWire.TIMELINE_KEYS)
        assertEquals(
            listOf("id", "assetID", "trimStart", "trimEnd", "speed", "volume",
                "isMuted", "rotationDegrees", "crop", "leadingTransition",
                "transitionDuration"),
            VideoTimelineWire.CLIP_KEYS)
        assertEquals(
            listOf("id", "assetID", "offsetSeconds", "trimStart", "lengthSeconds",
                "volume", "fadeInSeconds", "fadeOutSeconds"),
            VideoTimelineWire.MUSIC_KEYS)
        assertEquals(
            listOf("id", "start", "end", "text", "source"),
            VideoTimelineWire.CAPTION_KEYS)
        assertEquals(
            listOf("fontSize", "colorHex", "backgroundHex", "positionY",
                "alignment", "respectsSafeArea"),
            VideoTimelineWire.CAPTION_STYLE_KEYS)
    }
}
