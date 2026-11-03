// SPDX-License-Identifier: MPL-2.0
//
// Pure VNC viewport coordinate tests (authored, NOT RUN in this lane).
// Covers fit/letterboxing, zoom, pan clamping and out-of-image rejection.

package com.floe.android.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteVncViewportTest {
    @Test
    fun portraitViewLetterboxesLandscapeFrameAndMapsInside() {
        val transform = vncTransform(
            viewWidth = 800f,
            viewHeight = 1280f,
            frameWidth = 1920,
            frameHeight = 1080,
            zoom = 1f,
            panX = 0f,
            panY = 0f,
        )
        assertEquals(800f, transform.displayWidth, 0.01f)
        assertEquals(450f, transform.displayHeight, 0.01f)
        assertEquals(0f, transform.offsetX, 0.01f)
        assertEquals(415f, transform.offsetY, 0.01f)

        assertEquals(960 to 540, vncMapPoint(transform, 400f, 640f))
        assertNull(vncMapPoint(transform, 400f, 10f))
    }

    @Test
    fun zoomAndPanClampToImageEdges() {
        val transform = vncTransform(
            viewWidth = 1000f,
            viewHeight = 1000f,
            frameWidth = 1920,
            frameHeight = 1080,
            zoom = 2f,
            panX = 100_000f,
            panY = -100_000f,
        )
        assertEquals(2000f, transform.displayWidth, 0.1f)
        assertEquals(1125f, transform.displayHeight, 0.1f)
        assertEquals(-125f, transform.offsetY, 0.1f)
        assertEquals(0f, transform.offsetX, 0.1f)
    }

    @Test
    fun fitNeverExceedsZoomRange() {
        assertEquals(1f, vncClampZoom(1f, 0.1f), 0.001f)
        assertEquals(8f, vncClampZoom(1f, 100f), 0.001f)
    }

    @Test
    fun textDiffProducesOrderedInsertAndBackspace() {
        val edits = vncTextDiff("ab", "abc")
        assertEquals(1, edits.size)
        assertEquals("c", (edits[0] as VncTextEdit.Insert).text)

        val removed = vncTextDiff("abcd", "ad")
        assertEquals(2, removed.size)
        assertEquals(3, (removed[0] as VncTextEdit.Backspace).count)
        assertEquals("d", (removed[1] as VncTextEdit.Insert).text)
    }
}
