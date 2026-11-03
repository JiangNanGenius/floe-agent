// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.ui.api.NotesNormalizedRect
import com.floe.android.feature.notes.ui.api.NotesPdfTextRegion
import com.floe.android.feature.notes.ui.presentation.NotesPdfTextIdentity
import com.floe.android.feature.notes.ui.presentation.NotesPdfTextSelectionRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regressions for arbitrary PDF text selection: real region geometry (no
 * invented glyph boxes), UTF-16/grapheme-safe ranges, CJK/RTL/multiline copy,
 * truncation truthfulness and exact document/page/source/revision identity.
 */
class NotesPdfTextSelectionTest {

    private val sha = "a".repeat(64)
    private val text = "Alpha beta 你好世界 שלום"

    private fun identity(
        revision: Int = 3,
        documentID: String = "doc-1",
        pageID: String = "page-1",
        resourceID: String = "resource-1",
        sourceSha: String = sha,
        bytes: Long = 4,
        pageIndex: Int = 0,
        pageCount: Int = 2,
    ) = NotesPdfTextIdentity(
        documentID = documentID,
        documentRevision = revision,
        pageID = pageID,
        resourceID = resourceID,
        sourceSha256 = sourceSha,
        sourceByteCount = bytes,
        pageIndex = pageIndex,
        pageCount = pageCount,
    )

    private fun rect(left: Float, top: Float, right: Float, bottom: Float) =
        NotesNormalizedRect(left, top, right, bottom)

    private fun page(
        value: String = text,
        geometryMatches: Boolean = true,
        truncated: Boolean = false,
    ) = NotesPdfTextSelectionRules.page(
        identity = identity(),
        pageWidthPt = 612f,
        pageHeightPt = 792f,
        text = value,
        regions = listOf(
            NotesPdfTextRegion(0, 10, listOf(rect(0.10f, 0.10f, 0.60f, 0.15f))),
            NotesPdfTextRegion(11, 15, listOf(rect(0.10f, 0.20f, 0.40f, 0.25f))),
            NotesPdfTextRegion(16, 20, listOf(rect(0.10f, 0.30f, 0.30f, 0.35f))),
        ),
        truncated = truncated,
        geometryMatchesPage = geometryMatches,
    )!!

    @Test
    fun arbitraryRegionSpanIsNotOnlyASearchHitOrTheWholePage() {
        val model = page()
        val selection = NotesPdfTextSelectionRules.regionSpan(model, identity(), 0, 1)
        assertNotNull(selection)
        assertEquals("Alpha beta 你好世界", selection!!.text)
        assertEquals(2, selection.rects.size)
        assertEquals(0, selection.startChar)
        assertEquals(15, selection.endChar)
    }

    @Test
    fun cjkAndRtlCopyExactUtf16Substrings() {
        val model = page()
        val cjk = NotesPdfTextSelectionRules.range(model, identity(), 11, 15)
        assertEquals("你好世界", cjk?.text)
        val rtl = NotesPdfTextSelectionRules.range(model, identity(), 16, 20)
        assertEquals("שלום", rtl?.text)
        val mixed = NotesPdfTextSelectionRules.regionSpan(model, identity(), 1, 2)
        assertEquals("你好世界 שלום", mixed?.text)
    }

    @Test
    fun graphemeRangesNeverSplitSurrogatePairsOrCombiningSequences() {
        assertEquals(1 to 3, NotesPdfTextSelectionRules.graphemeRange("A😀B", 1, 2))
        assertEquals(1 to 3, NotesPdfTextSelectionRules.graphemeRange("A😀B", 2, 3))
        assertEquals(0 to 2, NotesPdfTextSelectionRules.graphemeRange("e\u0301x", 0, 1))
        assertEquals(2 to 2, NotesPdfTextSelectionRules.graphemeRange("A😀B", 2, 2))
        assertEquals(0 to 4, NotesPdfTextSelectionRules.graphemeRange("A😀B", -5, 99))
    }

    @Test
    fun selectionRangeIsBoundedAndReturnsOnlyFullyCoveredRegionRects() {
        val model = page()
        val partial = NotesPdfTextSelectionRules.range(model, identity(), 0, 12)
        assertEquals(text.substring(0, 12), partial?.text)
        // The second region (11..15) is only partially covered, so its box is
        // not claimed; only the fully covered first region contributes.
        assertEquals(1, partial?.rects?.size)
        assertNull(NotesPdfTextSelectionRules.range(model, identity(), 4, 4))
    }

    @Test
    fun regionHitTestingUsesRealNormalizedBoundsAndTolerance() {
        val model = page()
        assertEquals(0, NotesPdfTextSelectionRules.regionAt(model, 0.2f, 0.12f))
        assertEquals(1, NotesPdfTextSelectionRules.regionAt(model, 0.2f, 0.22f))
        assertEquals(2, NotesPdfTextSelectionRules.regionAt(model, 0.2f, 0.32f))
        assertNull(NotesPdfTextSelectionRules.regionAt(model, 0.9f, 0.9f))
        assertEquals(
            0,
            NotesPdfTextSelectionRules.regionAt(model, 0.10f, 0.09f, tolerance = 0.02f),
        )
    }

    @Test
    fun samePagePointAtDifferentZoomOrDisplayedRotationStillHitsTheSameRegion() {
        // The caller passes the CURRENT displayed page box (zoom already
        // applied). Doubling both axes must not change the normalized point.
        val normal = NotesPdfTextSelectionRules.normalizedPoint(100f, 154f, 500f, 700f)!!
        val zoomed = NotesPdfTextSelectionRules.normalizedPoint(200f, 308f, 1000f, 1400f)!!
        assertEquals(normal.first, zoomed.first, 0.0001f)
        assertEquals(normal.second, zoomed.second, 0.0001f)
        val model = page()
        assertEquals(1, NotesPdfTextSelectionRules.regionAt(model, normal.first, normal.second))
        assertEquals(1, NotesPdfTextSelectionRules.regionAt(model, zoomed.first, zoomed.second))

        // A page whose displayed box is landscape (rotation already applied)
        // still uses the same normalized region geometry.
        val landscape = NotesPdfTextSelectionRules.page(
            identity = identity(),
            pageWidthPt = 792f,
            pageHeightPt = 612f,
            text = text,
            regions = model.regions,
            truncated = false,
            geometryMatchesPage = true,
        )!!
        assertEquals(1, NotesPdfTextSelectionRules.regionAt(landscape, 0.2f, 0.22f))
        assertNull(NotesPdfTextSelectionRules.normalizedPoint(1f, 1f, 0f, 10f))
    }

    @Test
    fun anEmptyPageProducesNoSelection() {
        val model = page(value = "")
        assertEquals("", model.text)
        assertNull(NotesPdfTextSelectionRules.regionSpan(model, identity(), 0, 0))
        assertNull(NotesPdfTextSelectionRules.selectAll(model, identity()))
    }

    @Test
    fun truncationIsCarriedIntoEverySelection() {
        val model = page(truncated = true)
        val selection = NotesPdfTextSelectionRules.regionSpan(model, identity(), 0, 0)
        assertTrue(selection!!.truncated)
    }

    @Test
    fun aDifferentRevisionPageResourceOrSourceInvalidatesSelectionAndCopy() {
        val model = page()
        val selection = NotesPdfTextSelectionRules.regionSpan(model, identity(), 0, 0)!!
        assertEquals("Alpha beta", NotesPdfTextSelectionRules.copyText(selection, identity()))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(revision = 4)))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(pageID = "page-2")))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(resourceID = "resource-2")))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(sourceSha = "b".repeat(64))))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(bytes = 5)))
        assertNull(NotesPdfTextSelectionRules.copyText(selection, identity(pageCount = 3)))
        assertFalse(NotesPdfTextSelectionRules.selectionIsCurrent(selection, identity(pageIndex = 1)))
    }

    @Test
    fun geometryMismatchAllowsFullTextButNotViewportRegionSelection() {
        val model = page(geometryMatches = false)
        assertNull(NotesPdfTextSelectionRules.regionSpan(model, identity(), 0, 1))
        val full = NotesPdfTextSelectionRules.range(model, identity(), 0, model.text.length)
        assertEquals(text, full?.text)
    }

    @Test
    fun oversizedOrMalformedPagesAreRefused() {
        assertNull(
            NotesPdfTextSelectionRules.page(
                identity = identity(),
                pageWidthPt = 612f,
                pageHeightPt = 792f,
                text = "x".repeat(NotesPdfTextSelectionRules.MAX_TEXT_CHARS_PER_PAGE + 1),
                regions = emptyList(),
                truncated = false,
                geometryMatchesPage = true,
            ),
        )
        assertNull(
            NotesPdfTextSelectionRules.page(
                identity = identity(sourceSha = "not-a-sha"),
                pageWidthPt = 612f,
                pageHeightPt = 792f,
                text = "alpha",
                regions = emptyList(),
                truncated = false,
                geometryMatchesPage = true,
            ),
        )
        assertNull(
            NotesPdfTextSelectionRules.page(
                identity = identity(),
                pageWidthPt = -1f,
                pageHeightPt = 792f,
                text = "alpha",
                regions = emptyList(),
                truncated = false,
                geometryMatchesPage = true,
            ),
        )
    }

    @Test
    fun invalidRegionBoundsAreDroppedNotConvertedToInventedBoxes() {
        val model = NotesPdfTextSelectionRules.page(
            identity = identity(),
            pageWidthPt = 612f,
            pageHeightPt = 792f,
            text = "alpha",
            regions = listOf(
                NotesPdfTextRegion(
                    startChar = 0,
                    endChar = 5,
                    rects = listOf(
                        NotesNormalizedRect(0.8f, 0.1f, 0.2f, 0.2f),
                        NotesNormalizedRect(0.1f, 0.1f, 0.4f, 0.2f),
                    ),
                ),
            ),
            truncated = false,
            geometryMatchesPage = true,
        )!!
        assertEquals(1, model.regions.single().rects.size)
        assertEquals(0.1f, model.regions.single().rects.single().left, 0.0001f)
    }
}
