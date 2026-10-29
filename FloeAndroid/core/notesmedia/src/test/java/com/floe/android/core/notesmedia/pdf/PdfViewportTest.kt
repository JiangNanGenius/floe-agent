// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max

class PdfViewportTest {

    private val box = PdfPageBox.of(612f, 792f, 0f)!!

    @Test
    fun paperToViewAndBackRoundTrip() {
        val viewport = PdfViewport(box, densityDpi = 320)
        viewport.resize(1200, 1600)
        viewport.setZoom(1.5f)
        viewport.panBy(20f, -35f)
        val view = viewport.paperToView(300f, 400f)
        assertNotNull(view)
        val back = viewport.viewToPaper(view!!.first, view.second)
        assertNotNull(back)
        assertEquals(300f, back!!.first, 0.01f)
        assertEquals(400f, back.second, 0.01f)
    }

    @Test
    fun zoomIsClampedAndFitIsBounded() {
        val viewport = PdfViewport(box, 320)
        viewport.resize(1000, 1000)
        viewport.setZoom(100f)
        assertEquals(PdfViewport.MAX_ZOOM, viewport.zoom, 0.0001f)
        viewport.setZoom(0.0001f)
        assertEquals(PdfViewport.MIN_ZOOM, viewport.zoom, 0.0001f)
        val fit = viewport.fitPageZoom()
        assertTrue(fit in PdfViewport.MIN_ZOOM..PdfViewport.MAX_ZOOM)
    }

    @Test
    fun zoomAroundKeepsFocusPointAnchored() {
        val viewport = PdfViewport(box, 320)
        viewport.resize(1200, 1600)
        viewport.setZoom(1f)
        val before = viewport.viewToPaper(600f, 800f)!!
        viewport.zoomAround(600f, 800f, 2.4f)
        val after = viewport.viewToPaper(600f, 800f)!!
        assertEquals(before.first, after.first, 0.5f)
        assertEquals(before.second, after.second, 0.5f)
    }

    @Test
    fun rotationSwapsDisplayedSizeAndKeepsModelPoint() {
        val viewport = PdfViewport(box, 320)
        viewport.resize(1000, 1400)
        val paper = viewport.viewToPaper(500f, 700f)!!
        viewport.rotateBy(1)
        assertEquals(1, viewport.userRotationQuarterTurns)
        assertEquals(792f, viewport.effectiveWidthPt, 0.01f)
        assertEquals(612f, viewport.effectiveHeightPt, 0.01f)
        val mapped = viewport.paperToView(paper.first, paper.second)!!
        // The point under the view centre stays (approximately) under the centre.
        assertTrue(abs(mapped.first - 500f) < 1f || abs(mapped.second - 700f) < 1f)
        viewport.rotateBy(3)
        assertEquals(0, viewport.userRotationQuarterTurns)
    }

    @Test
    fun visibleTilesAreBoundedAndInsideThePage() {
        val viewport = PdfViewport(box, 320)
        viewport.resize(800, 1200)
        viewport.setZoom(4f)
        val tiles = viewport.visibleTiles(256)
        assertTrue(tiles.isNotEmpty())
        assertTrue(tiles.size <= PdfViewport.MAX_TILES)
        for (tile in tiles) {
            assertTrue(tile.paperRect.left >= -0.01f)
            assertTrue(tile.paperRect.top >= -0.01f)
            assertTrue(tile.paperRect.right <= 612.01f)
            assertTrue(tile.paperRect.bottom <= 792.01f)
            assertTrue(tile.widthPx > 0 && tile.heightPx > 0)
        }
    }

    @Test
    fun renderPlannerMatchesTheRendererClamp() {
        assertEquals(100, PdfRenderPlanner.zoomPercentForWidth(box, 816))
        val expected = PdfRenderPlanner.expectedBitmap(box, 100)
        assertNotNull(expected)
        assertEquals(815, expected!!.first)
        val thumb = PdfRenderPlanner.thumbnailZoomPercent(box, 256)
        val size = PdfRenderPlanner.expectedBitmap(box, thumb)!!
        // The renderer's 25% floor means a 792pt page cannot be smaller than
        // ~264px; the UI may downscale further, but the request stays honest.
        assertEquals(25, thumb)
        assertTrue(max(size.first, size.second) <= 264)
    }

    @Test
    fun viewportRefusesZeroSizedView() {
        val viewport = PdfViewport(box, 320)
        assertNull(viewport.paperToView())
        assertNull(viewport.visiblePaperBounds())
    }
}
