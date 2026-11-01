// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.feature.workbench.LargeImportKind
import com.floe.android.feature.workbench.NewMediaProjectKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaWorkbenchImportPolicyTest {
    @Test
    fun genericCanvasLimitStaysTheBoundaryForImages() {
        val limit = MediaWorkbenchImportPolicy.GENERIC_MEDIA_LIMIT
        assertFalse(MediaWorkbenchImportPolicy.shouldUseLargeRoute("image", limit))
        assertTrue(MediaWorkbenchImportPolicy.shouldUseLargeRoute("image", limit + 1))
        assertFalse(MediaWorkbenchImportPolicy.shouldUseLargeRoute("image", null))
        // Video/audio are always service-owned large candidates.
        assertTrue(MediaWorkbenchImportPolicy.shouldUseLargeRoute("video", 1))
        assertTrue(MediaWorkbenchImportPolicy.shouldUseLargeRoute("audio", 1))
        assertFalse(MediaWorkbenchImportPolicy.shouldUseLargeRoute("other", limit + 1))
    }

    @Test
    fun assetRoutingClassifiesByRealMimeFirstThenExtension() {
        assertEquals(
            LargeImportKind.VIDEO,
            MediaWorkbenchImportPolicy.classifyKind("video/mp4", "clip.bin"),
        )
        assertEquals(
            LargeImportKind.AUDIO,
            MediaWorkbenchImportPolicy.classifyKind("audio/mpeg", "music.bin"),
        )
        assertEquals(
            LargeImportKind.IMAGE,
            MediaWorkbenchImportPolicy.classifyKind("image/heic", "photo.bin"),
        )
        assertEquals(
            LargeImportKind.VIDEO,
            MediaWorkbenchImportPolicy.classifyKind(null, "clip.MOV"),
        )
        assertEquals(
            LargeImportKind.AUDIO,
            MediaWorkbenchImportPolicy.classifyKind(null, "track.flac"),
        )
        assertEquals(
            LargeImportKind.IMAGE,
            MediaWorkbenchImportPolicy.classifyKind(null, "image.webp"),
        )
        assertNull(MediaWorkbenchImportPolicy.classifyKind(null, "archive.zip"))
    }

    @Test
    fun newProjectKindsRemainImageOrVideoOnly() {
        assertEquals(NewMediaProjectKind.IMAGE, MediaWorkbenchImportPolicy.newProjectKind("IMAGE"))
        assertEquals(NewMediaProjectKind.VIDEO, MediaWorkbenchImportPolicy.newProjectKind("video"))
        assertNull(MediaWorkbenchImportPolicy.newProjectKind("audio"))
    }
}
