// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfTextRect
import com.floe.android.core.officeengine.pdf.OfficePdfTextRegion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regressions for the source-bound page-text cache used by arbitrary PDF text
 * selection. A cached page must never answer for a different snapshot, page
 * count, page index, or malformed payload.
 */
class PdfPageTextCacheTest {

    private fun source(sha: String = "a".repeat(64), bytes: Long = 4): VerifiedMediaSnapshot {
        val file = File(System.getProperty("java.io.tmpdir"), "page-text-cache-${System.nanoTime()}.pdf")
        file.writeBytes(ByteArray(bytes.toInt().coerceAtLeast(1)))
        file.deleteOnExit()
        return VerifiedMediaSnapshot(
            file = file.absoluteFile,
            sha256 = sha,
            byteCount = bytes,
            mediaType = NotesMediaType.PDF,
            displayName = "cache.pdf",
        )
    }

    private fun payload(
        text: String,
        pageIndex: Int = 0,
        pageCount: Int = 2,
        bytes: Long = 4,
        truncated: Boolean = false,
    ) = OfficePdfPageText(
        pageIndex = pageIndex,
        pageCount = pageCount,
        sourceBytes = bytes,
        pageWidthPt = 612f,
        pageHeightPt = 792f,
        text = text,
        regions = if (text.isEmpty()) {
            emptyList()
        } else {
            listOf(
                OfficePdfTextRegion(
                    startChar = 0,
                    endChar = text.length,
                    rects = listOf(OfficePdfTextRect(10f, 20f, 220f, 40f)),
                ),
            )
        },
        truncated = truncated,
    )

    @Test
    fun sameIdentityReturnsTheCachedPage() {
        val cache = PdfPageTextCache()
        val src = source()
        val page = PdfPageId(0)
        assertTrue(cache.put(src, page, 2, payload("Alpha beta")))
        assertEquals("Alpha beta", cache.get(src, page, 2)?.text)
        assertEquals(1, cache.size)
    }

    @Test
    fun aDifferentSnapshotNeverReusesText() {
        val cache = PdfPageTextCache()
        val page = PdfPageId(0)
        assertTrue(cache.put(source("a".repeat(64)), page, 2, payload("Alpha")))
        assertNull(cache.get(source("b".repeat(64)), page, 2))
        assertEquals("refused entry is removed", 0, cache.size)
    }

    @Test
    fun differentByteLengthPageCountOrPageIndexIsRefused() {
        val cache = PdfPageTextCache()
        val src = source()
        assertTrue(cache.put(src, PdfPageId(0), 2, payload("Alpha")))
        assertNull(cache.get(src, PdfPageId(0), 3))
        assertNull(cache.get(src, PdfPageId(1), 2))
        assertNull(cache.get(source(bytes = 5), PdfPageId(0), 2))
    }

    @Test
    fun malformedPayloadIsNeverCached() {
        val cache = PdfPageTextCache()
        val bad = payload("Alpha").copy(sourceBytes = 999)
        assertFalse(cache.put(source(), PdfPageId(0), 2, bad))
        assertEquals(0, cache.size)
    }

    @Test
    fun pageLimitEvictsTheLeastRecentlyUsedPage() {
        val cache = PdfPageTextCache(maxPages = 2, maxChars = 10_000)
        val src = source()
        assertTrue(cache.put(src, PdfPageId(0), 3, payload("one", pageIndex = 0, pageCount = 3)))
        assertTrue(cache.put(src, PdfPageId(1), 3, payload("two", pageIndex = 1, pageCount = 3)))
        // Access page 0 so page 1 becomes the least recently used entry.
        assertEquals("one", cache.get(src, PdfPageId(0), 3)?.text)
        assertTrue(cache.put(src, PdfPageId(2), 3, payload("three", pageIndex = 2, pageCount = 3)))
        assertEquals(2, cache.size)
        assertEquals("one", cache.get(src, PdfPageId(0), 3)?.text)
        assertNull(cache.get(src, PdfPageId(1), 3))
        assertEquals("three", cache.get(src, PdfPageId(2), 3)?.text)
    }

    @Test
    fun characterBudgetEvictsOlderPages() {
        val cache = PdfPageTextCache(maxPages = 4, maxChars = 10)
        val src = source()
        assertTrue(cache.put(src, PdfPageId(0), 3, payload("12345678", pageIndex = 0, pageCount = 3)))
        assertTrue(cache.put(src, PdfPageId(1), 3, payload("abcdefgh", pageIndex = 1, pageCount = 3)))
        assertEquals(1, cache.size)
        assertNull(cache.get(src, PdfPageId(0), 3))
        assertEquals("abcdefgh", cache.get(src, PdfPageId(1), 3)?.text)
    }

    @Test
    fun clearDropsEveryEntry() {
        val cache = PdfPageTextCache()
        assertTrue(cache.put(source(), PdfPageId(0), 2, payload("Alpha")))
        cache.clear()
        assertEquals(0, cache.size)
        assertNull(cache.get(source(), PdfPageId(0), 2))
    }
}
