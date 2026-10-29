// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regressions for the NEW isolated page-text transaction (2026-10-30).
 * They cover the fields shared by the binder writer/reader: source/page
 * identity, truncation metadata, region/rect caps and password shape.
 */
class OfficePdfTextContractTest {

    private fun line(text: String, vararg rects: OfficePdfTextLineRect) =
        OfficePdfTextLine(text, rects.toList())

    private fun payload(
        pageIndex: Int = 2,
        pageCount: Int = 10,
        sourceBytes: Long = 1234L,
        widths: Pair<Float, Float> = 612f to 792f,
        text: String = "hello world",
        regions: List<OfficePdfTextRegion> = listOf(
            OfficePdfTextRegion(0, 5, listOf(OfficePdfTextRect(10f, 20f, 80f, 40f))),
        ),
        truncated: Boolean = false,
    ) = OfficePdfPageText(
        pageIndex = pageIndex,
        pageCount = pageCount,
        sourceBytes = sourceBytes,
        pageWidthPt = widths.first,
        pageHeightPt = widths.second,
        text = text,
        regions = regions,
        truncated = truncated,
    )

    @Test
    fun buildCarriesExactPageSourceIdentityAndLineRegions() {
        val built = OfficePdfTextContract.build(
            pageIndex = 2,
            pageCount = 10,
            sourceBytes = 1234L,
            pageWidthPt = 612f,
            pageHeightPt = 792f,
            lines = listOf(
                line("Hello ", OfficePdfTextLineRect(10f, 20f, 80f, 40f)),
                line("World", OfficePdfTextLineRect(10f, 44f, 90f, 64f)),
            ),
        )!!
        assertEquals(2, built.pageIndex)
        assertEquals(10, built.pageCount)
        assertEquals(1234L, built.sourceBytes)
        assertEquals("Hello World", built.text)
        assertEquals(2, built.regions.size)
        assertEquals(0, built.regions[0].startChar)
        assertEquals(6, built.regions[0].endChar)
        assertEquals(6, built.regions[1].startChar)
        assertEquals(11, built.regions[1].endChar)
        assertFalse(built.truncated)
        assertTrue(OfficePdfTextContract.accept(built, 2, 1234L))
    }

    @Test
    fun adjacentLinesGetOneSearchableSeparatorWithoutSyntheticWhitespace() {
        val built = OfficePdfTextContract.build(
            0, 1, 10L, 100f, 100f,
            listOf(line("alpha"), line("beta"), line("gamma "), line("delta")),
        )!!
        assertEquals("alpha beta gamma delta", built.text)
        assertEquals(6, built.regions[1].startChar)
        assertEquals(11, built.regions[2].startChar)

        // The separator itself counts against the cap: a reply can never
        // exceed maxChars and fail the host's wire check.
        val capped = OfficePdfTextContract.build(
            0, 1, 10L, 100f, 100f,
            listOf(line("ab"), line("cd")),
            maxChars = 3,
        )!!
        assertTrue(capped.text.length <= 3)
        assertTrue(capped.truncated)
    }

    @Test
    fun buildTruncatesAtTheCapWithoutSplittingSurrogates() {
        val emoji = "\uD83D\uDE00" // surrogate pair
        val built = OfficePdfTextContract.build(
            pageIndex = 0,
            pageCount = 1,
            sourceBytes = 10L,
            pageWidthPt = 100f,
            pageHeightPt = 100f,
            lines = listOf(line("a" + emoji + "bcd")),
            maxChars = 2,
        )!!
        // Cap 2 would cut between the high and low surrogate: the high
        // surrogate is dropped (result is exactly "a"), and truncation is
        // reported.
        assertEquals("a", built.text)
        assertTrue(built.truncated)
        assertTrue(built.regions.all { it.endChar <= built.text.length })
    }

    @Test
    fun buildRefusesInvalidIdentityAndPageBox() {
        assertNull(
            OfficePdfTextContract.build(-1, 10, 10L, 100f, 100f, listOf(line("x"))),
        )
        assertNull(
            OfficePdfTextContract.build(10, 10, 10L, 100f, 100f, listOf(line("x"))),
        )
        assertNull(
            OfficePdfTextContract.build(0, 10, 0L, 100f, 100f, listOf(line("x"))),
        )
        assertNull(
            OfficePdfTextContract.build(0, 10, 10L, Float.NaN, 100f, listOf(line("x"))),
        )
        assertNull(
            OfficePdfTextContract.build(0, 10, 10L, 100f, 0f, listOf(line("x"))),
        )
        assertNull(
            OfficePdfTextContract.build(0, 0, 10L, 100f, 100f, listOf(line("x"))),
        )
    }

    @Test
    fun buildClampsOutOfPageRectsAndDropsEmptyOnes() {
        val built = OfficePdfTextContract.build(
            0, 1, 10L, 100f, 200f,
            listOf(
                line(
                    "x",
                    OfficePdfTextLineRect(-5f, -5f, 90f, 50f),
                    OfficePdfTextLineRect(90f, 90f, 90f, 120f), // empty
                    OfficePdfTextLineRect(10f, 10f, 500f, 500f), // clamped
                ),
            ),
        )!!
        assertEquals(2, built.regions[0].rects.size)
        assertEquals(0f, built.regions[0].rects[0].left)
        assertEquals(0f, built.regions[0].rects[0].top)
        assertEquals(100f, built.regions[0].rects[1].right)
        assertEquals(200f, built.regions[0].rects[1].bottom)
    }

    @Test
    fun acceptRejectsForeignPageAndSourceLength() {
        val p = payload()
        assertFalse("different page", OfficePdfTextContract.accept(p, 3, 1234L))
        assertFalse("different source bytes", OfficePdfTextContract.accept(p, 2, 1235L))
        assertFalse("non-positive source", OfficePdfTextContract.accept(p, 2, 0L))
        assertNull(OfficePdfTextContract.sanitize(payload(pageCount = 0)))
    }

    @Test
    fun acceptRejectsOutOfRangeRegionsAndRects() {
        val badOffsets = payload(regions = listOf(OfficePdfTextRegion(0, 99, emptyList())))
        assertFalse(OfficePdfTextContract.accept(badOffsets, 2, 1234L))
        val badRect = payload(
            regions = listOf(
                OfficePdfTextRegion(0, 5, listOf(OfficePdfTextRect(10f, 20f, 700f, 40f))),
            ),
        )
        assertFalse("rect outside page", OfficePdfTextContract.accept(badRect, 2, 1234L))
        val tooMany = payload(
            regions = listOf(
                OfficePdfTextRegion(
                    0, 5,
                    List(OfficePdfTextContract.MAX_REGION_RECTS + 1) {
                        OfficePdfTextRect(10f, 20f, 80f, 40f)
                    },
                ),
            ),
        )
        assertFalse(OfficePdfTextContract.accept(tooMany, 2, 1234L))
    }

    @Test
    fun sanitizeReboundsTextRegionsAndRects() {
        val oversizedText = "x".repeat(OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE + 50)
        val payload = payload(
            text = oversizedText,
            regions = listOf(
                OfficePdfTextRegion(0, 10, listOf(OfficePdfTextRect(-1f, 0f, 10f, 10f))),
                OfficePdfTextRegion(5, 15, listOf(OfficePdfTextRect(10f, 10f, 30f, 30f))),
            ) + List(OfficePdfTextContract.MAX_TEXT_REGIONS) {
                OfficePdfTextRegion(0, 1, emptyList())
            },
        )
        val sanitized = OfficePdfTextContract.sanitize(payload)!!
        assertEquals(OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE, sanitized.text.length)
        assertTrue(sanitized.truncated)
        assertTrue(sanitized.regions.size <= OfficePdfTextContract.MAX_TEXT_REGIONS)
        assertTrue(sanitized.regions.all { region -> region.rects.all { it.left >= 0f } })
    }

    @Test
    fun passwordShapeIsNullableNonEmptyAndBounded() {
        assertTrue(OfficePdfTextContract.validPassword(null))
        assertTrue(OfficePdfTextContract.validPassword(CharArray(1)))
        assertTrue(
            OfficePdfTextContract.validPassword(CharArray(OfficePdfTextContract.MAX_PASSWORD_CHARS)),
        )
        assertFalse(OfficePdfTextContract.validPassword(CharArray(0)))
        assertFalse(
            OfficePdfTextContract.validPassword(CharArray(OfficePdfTextContract.MAX_PASSWORD_CHARS + 1)),
        )
    }

    @Test
    fun textStatusVocabularyStaysInsideTheContract() {
        val statuses = listOf(
            OfficePdfRendererContract.S_OK,
            OfficePdfRendererContract.S_BAD_REQUEST,
            OfficePdfRendererContract.S_INVALID_PDF,
            OfficePdfRendererContract.S_PASSWORD,
            OfficePdfRendererContract.S_PASSWORD_REJECTED,
            OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED,
            OfficePdfRendererContract.S_TEXT_UNSUPPORTED,
            OfficePdfRendererContract.S_BUSY,
            OfficePdfRendererContract.S_INTERNAL,
        )
        statuses.forEach { assertTrue("status $it", OfficePdfRendererContract.validTextStatus(it)) }
        assertFalse(OfficePdfRendererContract.validTextStatus(99))
        assertTrue(OfficePdfRendererContract.validStatus(OfficePdfRendererContract.S_TEXT_UNSUPPORTED))
        assertEquals(8, OfficePdfRendererContract.S_TEXT_UNSUPPORTED)
    }

    @Test
    fun maxCapsRemainBinderBounded() {
        // Worst legal reply: 32k UTF-16 chars + 256 regions * 32 rects * 16 bytes.
        val worstBytes = OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE * 2L +
            OfficePdfTextContract.MAX_TEXT_REGIONS.toLong() *
            OfficePdfTextContract.MAX_REGION_RECTS * 16L
        assertTrue("worst legal text reply ${worstBytes}B", worstBytes < 512L * 1024L)
        assertNotNull(OfficePdfTextContract.build(0, 1, 1L, 100f, 100f, emptyList()))
    }
}
