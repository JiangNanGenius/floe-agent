// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfTextRect
import com.floe.android.core.officeengine.pdf.OfficePdfTextRegion
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regressions for the NEW default Notes text path: bounded isolated-renderer
 * page transactions, source/page identity fences, typed OCR fallback and
 * cancellation/truncation truthfulness. No Android runtime is required.
 */
class IsolatedPdfTextBackendTest {

    private val sha = "a".repeat(64)

    private fun source(bytes: Int = 4): VerifiedMediaSnapshot {
        val file = File(System.getProperty("java.io.tmpdir"), "isolated-text-${System.nanoTime()}.pdf")
        file.writeBytes(ByteArray(bytes) { it.toByte() })
        file.deleteOnExit()
        return VerifiedMediaSnapshot(
            file = file.absoluteFile,
            sha256 = sha,
            byteCount = bytes.toLong(),
            mediaType = com.floe.android.core.notesmedia.media.NotesMediaType.PDF,
            displayName = "fixture.pdf",
        )
    }

    private fun page(
        index: Int,
        pageCount: Int,
        bytes: Long,
        text: String,
        regions: List<OfficePdfTextRegion> = emptyList(),
    ) = OfficePdfPageText(
        pageIndex = index,
        pageCount = pageCount,
        sourceBytes = bytes,
        pageWidthPt = 612f,
        pageHeightPt = 792f,
        text = text,
        regions = regions,
        truncated = false,
    )

    private class FakeTransport(
        private val pages: Map<Int, PdfPageTextResult>,
    ) : PdfPageTextTransport {
        var calls = 0
        var lastPassword: CharArray? = null

        override suspend fun pageText(
            source: VerifiedMediaSnapshot,
            page: PdfPageId,
            password: CharArray?,
        ): PdfPageTextResult {
            calls++
            lastPassword = password
            return pages[page.pageIndex] ?: PdfPageTextResult.Failed(PdfMediaFailure.TEXT_UNSUPPORTED)
        }
    }

    @Test
    fun findsMatchesWithRealPageRegions() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(
                0 to PdfPageTextResult.Page(
                    page(
                        index = 0,
                        pageCount = 2,
                        bytes = src.byteCount,
                        text = "Invoice total 42.00 due",
                        regions = listOf(
                            OfficePdfTextRegion(0, 21, listOf(OfficePdfTextRect(10f, 20f, 200f, 40f))),
                        ),
                    ),
                ),
                1 to PdfPageTextResult.Page(page(1, 2, src.byteCount, "")),
            ),
        )
        val backend = IsolatedPdfTextBackend(transport)
        val outcome = backend.searchAsync(src, 2, "42.00") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Matches)
        val matches = (outcome as PdfTextSearchOutcome.Matches).matches
        assertEquals(1, matches.size)
        assertEquals(0, matches[0].page.pageIndex)
        assertEquals(2, transport.calls)
        assertEquals(listOf(PdfRect(10f, 20f, 200f, 40f)), matches[0].rects)
    }

    @Test
    fun foreignSourceLengthIsNeverTrustedAsText() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(0 to PdfPageTextResult.Page(page(0, 1, src.byteCount + 1, "hello"))),
        )
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 1, "hello") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.SOURCE_CHANGED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
        assertTrue(outcome.backendId.isNotEmpty())
    }

    @Test
    fun pageCountDisagreementIsRefusedNotSilentlySearched() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(0 to PdfPageTextResult.Page(page(0, pageCount = 3, bytes = src.byteCount, text = "hello"))),
        )
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 2, "hello") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.BACKEND_FAILED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
    }

    @Test
    fun oldPlatformWithoutTextApiRequestsOcr() = runBlocking {
        val src = source()
        val transport = FakeTransport(emptyMap())
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 7, "anything") { false }
        assertTrue(outcome is PdfTextSearchOutcome.NeedsOcr)
        assertEquals(7, (outcome as PdfTextSearchOutcome.NeedsOcr).pagesWithoutText)
    }

    @Test
    fun scanLikeDocumentRequestsOcrNotNoMatches() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(
                0 to PdfPageTextResult.Page(page(0, 2, src.byteCount, "")),
                1 to PdfPageTextResult.Page(page(1, 2, src.byteCount, "   ")),
            ),
        )
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 2, "invoice") { false }
        assertTrue(outcome is PdfTextSearchOutcome.NeedsOcr)
        assertEquals(2, (outcome as PdfTextSearchOutcome.NeedsOcr).pagesWithoutText)
    }

    @Test
    fun boundedPageScanNeverClaimsWholeDocumentNoMatches() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(
                0 to PdfPageTextResult.Page(page(0, 3, src.byteCount, "alpha")),
            ),
        )
        val backend = IsolatedPdfTextBackend(transport, maxPagesPerSearch = 1)
        val outcome = backend.searchAsync(src, 3, "missing") { false }
        assertTrue(outcome is PdfTextSearchOutcome.NoMatches)
        val none = outcome as PdfTextSearchOutcome.NoMatches
        assertEquals(1, none.pagesSearched)
        assertTrue("partial scan must be marked truncated", none.truncated)
    }

    @Test
    fun truncatedPageTextMarksNoMatchesAsPartial() = runBlocking {
        val src = source()
        val truncated = page(0, 1, src.byteCount, "alpha").copy(truncated = true)
        val transport = FakeTransport(mapOf(0 to PdfPageTextResult.Page(truncated)))
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 1, "missing") { false }
        assertTrue(outcome is PdfTextSearchOutcome.NoMatches)
        assertTrue((outcome as PdfTextSearchOutcome.NoMatches).truncated)
    }

    @Test
    fun cancellationIsPolledBeforeAnyTransaction() = runBlocking {
        val src = source()
        val transport = FakeTransport(mapOf(0 to PdfPageTextResult.Page(page(0, 1, src.byteCount, "x"))))
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 1, "x") { true }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.CANCELLED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
        assertEquals(0, transport.calls)
    }

    @Test
    fun passwordRefusalIsTypedAndNeverReportedAsNoMatches() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            mapOf(0 to PdfPageTextResult.Failed(PdfMediaFailure.PASSWORD_REJECTED)),
        )
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 1, "x") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.PASSWORD_REJECTED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
    }

    @Test
    fun limitCutsMatchesAndReportsTruncation() = runBlocking {
        val src = source()
        val text = (1..80).joinToString(" ") { "x" }
        val transport = FakeTransport(
            mapOf(0 to PdfPageTextResult.Page(page(0, 1, src.byteCount, text))),
        )
        val outcome = IsolatedPdfTextBackend(transport).searchAsync(src, 1, "x") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Matches)
        val matches = outcome as PdfTextSearchOutcome.Matches
        assertEquals(PdfTextIndex.DEFAULT_LIMIT, matches.matches.size)
        assertTrue(matches.truncated)
    }

    @Test
    fun defaultBackendSelectionUsesTheIsolatedTransportWhenPresent() {
        assertTrue(PdfTextBackends.officeRendererDefault(FakeTransport(emptyMap())) is IsolatedPdfTextBackend)
        // No transport = honest typed fallback, never a fake empty index.
        assertEquals(
            PdfTextUnavailableReason.NATIVE_TEXT_NOT_EXPOSED,
            (PdfTextBackends.officeRendererDefault().search(source(), 1, "x") { false }
                as PdfTextSearchOutcome.Unavailable).reason,
        )
    }

    @Test
    fun blockingEntryPointRefusesInsteadOfCallingBinderOffDispatcher() {
        val backend = IsolatedPdfTextBackend(FakeTransport(emptyMap()))
        val outcome = backend.search(source(), 1, "x") { false }
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.NATIVE_TEXT_ASYNC_REQUIRED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
    }

    @Test
    fun passwordIsBorrowedPerPageAndNeverCopiedByTheBackend() = runBlocking {
        val src = source()
        val transport = FakeTransport(mapOf(0 to PdfPageTextResult.Page(page(0, 1, src.byteCount, "secret"))))
        val password = PdfPassword.ofString("pw")!!
        val backend = IsolatedPdfTextBackend(transport, password)
        backend.searchAsync(src, 1, "secret") { false }
        assertNotNull(transport.lastPassword)
        assertEquals("pw", String(transport.lastPassword!!))
        password.close()
        // After the session-owned holder is closed, the backend cannot borrow
        // a secret; it must surface a typed failure, not a crash or a false
        // empty result.
        val afterClose = backend.searchAsync(src, 1, "secret") { false }
        assertTrue(afterClose is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.BACKEND_FAILED,
            (afterClose as PdfTextSearchOutcome.Unavailable).reason,
        )
    }
}
