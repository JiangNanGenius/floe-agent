// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PdfPageBoxReaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val sha = "a".repeat(64)

    private fun read(bytes: ByteArray, cancelled: () -> Boolean = { false }): PdfGeometryResult =
        PdfPageBoxReader().read(PdfFixtures.write(tmp.newFile(), bytes), sha, cancelled)

    @Test
    fun twoPagesReadTheirOwnBoxesAndRotation() {
        val result = read(PdfFixtures.twoPages())
        assertTrue(result is PdfGeometryResult.Ok)
        val geometry = (result as PdfGeometryResult.Ok).geometry
        assertEquals(2, geometry.pageCount)
        assertEquals(612f, geometry.pages[0].widthPt, 0.01f)
        assertEquals(792f, geometry.pages[0].heightPt, 0.01f)
        assertEquals(0, geometry.pages[0].rotationQuarterTurns)
        // /Rotate 90 keeps the unrotated box but reports the displayed landscape size.
        assertEquals(1, geometry.pages[1].rotationQuarterTurns)
        assertEquals(842f, geometry.pages[1].displayedWidthPt, 0.01f)
        assertEquals(595f, geometry.pages[1].displayedHeightPt, 0.01f)
        assertEquals(false, geometry.encrypted)
    }

    @Test
    fun inheritsMediaBoxRotationAndIntersectsCropBox() {
        val result = read(PdfFixtures.inheritedBoxes())
        assertTrue(result is PdfGeometryResult.Ok)
        val page = (result as PdfGeometryResult.Ok).geometry.pages.single()
        assertEquals(580f, page.widthPt, 0.01f)
        assertEquals(760f, page.heightPt, 0.01f)
        // -90 is normalized to 270 degrees == 3 quarter turns.
        assertEquals(3, page.rotationQuarterTurns)
        assertTrue(page.explicitRotation)
        assertEquals(760f, page.displayedWidthPt, 0.01f)
        assertEquals(580f, page.displayedHeightPt, 0.01f)
    }

    @Test
    fun readsPageTreeInsideFlateObjectStream() {
        val result = read(PdfFixtures.objectStream())
        assertTrue(result is PdfGeometryResult.Ok)
        val geometry = (result as PdfGeometryResult.Ok).geometry
        assertEquals(1, geometry.pageCount)
        assertEquals(300f, geometry.pages[0].widthPt, 0.01f)
        assertEquals(400f, geometry.pages[0].heightPt, 0.01f)
    }

    @Test
    fun classicTrailerEncryptFlagIsReported() {
        val result = read(PdfFixtures.encryptedClassicTrailer())
        assertTrue(result is PdfGeometryResult.Ok)
        assertTrue((result as PdfGeometryResult.Ok).geometry.encrypted)
    }

    @Test
    fun missingCatalogIsRefusedNotGuessed() {
        val result = read(PdfFixtures.noCatalog())
        assertTrue(result is PdfGeometryResult.Refused)
        assertEquals(
            PdfGeometryRefusal.PAGE_TREE_UNREADABLE,
            (result as PdfGeometryResult.Refused).reason,
        )
    }

    @Test
    fun degeneratePageBoxIsRefused() {
        val result = read(PdfFixtures.zeroSizePage())
        assertTrue(result is PdfGeometryResult.Refused)
        assertEquals(
            PdfGeometryRefusal.PAGE_TREE_UNREADABLE,
            (result as PdfGeometryResult.Refused).reason,
        )
    }

    @Test
    fun nonPdfIsRefused() {
        val result = read("hello, not a pdf".toByteArray())
        assertTrue(result is PdfGeometryResult.Refused)
        assertEquals(PdfGeometryRefusal.NOT_A_PDF, (result as PdfGeometryResult.Refused).reason)
    }

    @Test
    fun cancellationIsTyped() {
        val result = read(PdfFixtures.twoPages()) { true }
        assertTrue(result is PdfGeometryResult.Refused)
        assertEquals(PdfGeometryRefusal.CANCELLED, (result as PdfGeometryResult.Refused).reason)
    }

    @Test
    fun missingFileIsRefused() {
        val missing = tmp.newFile().also { assertTrue(it.delete()) }
        val result = PdfPageBoxReader().read(missing, sha)
        assertTrue(result is PdfGeometryResult.Refused)
        assertEquals(PdfGeometryRefusal.NOT_REGULAR, (result as PdfGeometryResult.Refused).reason)
    }

    @Test
    fun rotationConversionRoundTripsThroughDisplay() {
        val box = PdfPageBox.of(612f, 792f, 90f)
        assertNotNull(box)
        val displayed = box!!.toDisplayed(100f, 200f)
        val back = box.toUnrotated(displayed.first, displayed.second)
        assertEquals(100f, back.first, 0.001f)
        assertEquals(200f, back.second, 0.001f)
        assertTrue(box.matchesRenderedAspect(792, 612))
        assertTrue(!box.matchesRenderedAspect(612, 792))
    }
}
