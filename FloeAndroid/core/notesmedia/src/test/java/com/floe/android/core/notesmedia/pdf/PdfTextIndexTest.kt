// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PdfTextIndexTest {

    private val source = snapshot("a".repeat(64))

    private fun snapshot(sha: String) = VerifiedMediaSnapshot(
        file = File("/tmp/does-not-need-to-exist.pdf"),
        sha256 = sha,
        byteCount = 100,
        mediaType = NotesMediaType.PDF,
        displayName = "fixture.pdf",
    )

    @Test
    fun matchesAreCaseInsensitiveAndCarrySnippets() {
        val index = PdfTextIndex()
        assertTrue(index.addPage(source, PdfPageId(0), "The Quick Brown Fox jumps over the lazy dog."))
        val outcome = index.search(source, "brown FOX") as PdfTextSearchOutcome.Matches
        assertEquals(1, outcome.matches.size)
        val match = outcome.matches[0]
        assertEquals(0, match.page.pageIndex)
        assertEquals(10, match.startChar)
        assertTrue(match.snippet.contains("Brown Fox"))
    }

    @Test
    fun queryNormalizationCollapsesWhitespaceAndRejectsEmpty() {
        assertEquals("a b", PdfTextIndex.normalizeQuery("  A \n\t b  "))
        assertEquals(null, PdfTextIndex.normalizeQuery("   "))
        assertEquals(null, PdfTextIndex.normalizeQuery("x".repeat(PdfTextIndex.MAX_QUERY_CHARS + 1)))
    }

    @Test
    fun missingTextReportsNeedsOcrInsteadOfNoMatches() {
        val index = PdfTextIndex()
        index.markPageWithoutText(source, PdfPageId(0))
        val outcome = index.search(source, "invoice") as PdfTextSearchOutcome.NeedsOcr
        assertEquals(1, outcome.pagesWithoutText)
    }

    @Test
    fun staleSourceReturnsStaleNotOldMatches() {
        val index = PdfTextIndex()
        index.addPage(source, PdfPageId(0), "hello world")
        val other = snapshot("b".repeat(64))
        val outcome = index.search(other, "hello")
        assertTrue(outcome is PdfTextSearchOutcome.StaleSource)
        assertEquals(source.sha256, (outcome as PdfTextSearchOutcome.StaleSource).expectedSha256)
    }

    @Test
    fun pageAddedForAnotherSourceClearsTheIndex() {
        val index = PdfTextIndex()
        index.addPage(source, PdfPageId(0), "hello world")
        val other = snapshot("b".repeat(64))
        index.addPage(other, PdfPageId(0), "different document")
        assertEquals(other.sha256, index.boundSourceSha256)
        assertEquals(1, index.pageCount())
    }

    @Test
    fun limitAndCancellationAreHonoured() {
        val index = PdfTextIndex()
        index.addPage(source, PdfPageId(0), "aa aa aa aa aa aa")
        val limited = index.search(source, "aa", limit = 2) as PdfTextSearchOutcome.Matches
        assertEquals(2, limited.matches.size)
        assertTrue(limited.truncated)
        val cancelled = index.search(source, "aa") { true }
        assertTrue(cancelled is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.CANCELLED,
            (cancelled as PdfTextSearchOutcome.Unavailable).reason,
        )
    }

    @Test
    fun ocrRegionsProvidePaperRects() {
        val index = PdfTextIndex()
        val text = "Total 42.00"
        index.addPage(
            source,
            PdfPageId(2),
            text,
            listOf(PdfTextRegion(0, text.length, listOf(PdfRect(10f, 20f, 100f, 40f)))),
        )
        val outcome = index.search(source, "42.00") as PdfTextSearchOutcome.Matches
        assertEquals(1, outcome.matches.size)
        assertEquals(listOf(PdfRect(10f, 20f, 100f, 40f)), outcome.matches[0].rects)
    }

    @Test
    fun nativeOcrSourceKeyIsStoredOpaquelyAndNeverDerived() {
        val index = PdfTextIndex()
        index.addPage(source, PdfPageId(0), "text", nativeOcrSourceKey = "native:key/7")
        assertEquals("native:key/7", index.nativeOcrSourceKey(PdfPageId(0)))
        assertEquals(null, index.nativeOcrSourceKey(PdfPageId(1)))
    }

    @Test
    fun unavailableBackendNeverClaimsEmptyText() {
        val backend = UnavailablePdfTextBackend(PdfTextUnavailableReason.NATIVE_TEXT_NOT_EXPOSED)
        val outcome = backend.search(source, 3, "anything") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.NATIVE_TEXT_NOT_EXPOSED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
    }
}
