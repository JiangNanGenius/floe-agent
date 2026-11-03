// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfTextRect
import com.floe.android.core.officeengine.pdf.OfficePdfTextRegion
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Session-level regressions for arbitrary PDF text selection: cache identity,
 * empty-page semantics, geometry fencing, encryption and cancellation. A fake
 * gateway/backend keeps this a pure JVM test.
 */
class PdfDocumentSessionPageTextTest {

    private val sha = "e".repeat(64)

    private fun source(): VerifiedMediaSnapshot {
        val file = File(System.getProperty("java.io.tmpdir"), "session-text-${System.nanoTime()}.pdf")
        file.writeBytes(byteArrayOf(1, 2, 3, 4))
        file.deleteOnExit()
        return VerifiedMediaSnapshot(
            file = file.absoluteFile,
            sha256 = sha,
            byteCount = 4,
            mediaType = NotesMediaType.PDF,
            displayName = "session.pdf",
        )
    }

    private fun payload(
        text: String = "Alpha beta",
        pageIndex: Int = 0,
        pageCount: Int = 3,
        bytes: Long = 4,
        widthPt: Float = 612f,
        heightPt: Float = 792f,
        truncated: Boolean = false,
    ) = OfficePdfPageText(
        pageIndex = pageIndex,
        pageCount = pageCount,
        sourceBytes = bytes,
        pageWidthPt = widthPt,
        pageHeightPt = heightPt,
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

    private class FakeGateway : PdfRenderGateway {
        override suspend fun documentInfo(source: VerifiedMediaSnapshot): PdfDocumentInfoResult =
            PdfDocumentInfoResult.Ready(3)

        override suspend fun renderPage(
            source: VerifiedMediaSnapshot,
            page: PdfPageId,
            zoomPercent: Int,
        ): PdfPageRenderResult = PdfPageRenderResult.Failed(PdfMediaFailure.TRANSPORT)

        override fun release(onQuiescent: (() -> Unit)?) = Unit
    }

    private class FakeTextBackend(
        private val outcome: (Int) -> PdfPageTextOutcome,
    ) : PdfTextBackend {
        override val id: String = "fake-page-text"
        var calls = 0

        override fun search(
            source: VerifiedMediaSnapshot,
            pageCount: Int,
            query: String,
            isCancelled: () -> Boolean,
        ): PdfTextSearchOutcome =
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NATIVE_TEXT_ASYNC_REQUIRED, id)

        override suspend fun pageText(
            source: VerifiedMediaSnapshot,
            pageCount: Int,
            page: PdfPageId,
            isCancelled: () -> Boolean,
        ): PdfPageTextOutcome {
            calls++
            return outcome(page.pageIndex)
        }
    }

    private fun session(
        backend: PdfTextBackend,
        password: PdfPassword? = null,
        geometry: PdfPageGeometry? = null,
    ) = PdfDocumentSession(
        source = source(),
        pageCount = 3,
        geometry = geometry,
        gateway = FakeGateway(),
        ownsGateway = false,
        textBackend = backend,
        password = password,
        renderBudgetBytes = 1L shl 20,
        thumbnailBudgetBytes = 1L shl 20,
    )

    @Test
    fun extractsAndCachesTheExactPage() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(pageIndex = it)) }
        val session = session(backend)
        val first = session.pageTextAwait(PdfPageId(1))
        assertTrue(first is PdfPageTextOutcome.Ready)
        assertEquals("Alpha beta", (first as PdfPageTextOutcome.Ready).page.text)
        val second = session.pageTextAwait(PdfPageId(1))
        assertEquals(first, second)
        assertEquals(1, backend.calls)
        session.close()
    }

    @Test
    fun anOcrIndexNeverSubstitutesForTheActualPageText() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(text = "Real source", pageIndex = it)) }
        val session = session(backend)
        session.indexText(
            page = PdfPageId(0),
            text = "Different OCR text",
            regions = listOf(PdfTextRegion(0, 18, listOf(PdfRect(10f, 20f, 200f, 40f)))),
        )
        val outcome = session.pageTextAwait(PdfPageId(0))
        assertEquals(
            "Real source",
            (outcome as PdfPageTextOutcome.Ready).page.text,
        )
        assertEquals(1, backend.calls)
        session.close()
    }

    @Test
    fun aBlankPageIsNoTextAndIsCachedAsSuch() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(text = "", pageIndex = it)) }
        val session = session(backend)
        val first = session.pageTextAwait(PdfPageId(0))
        assertTrue(first is PdfPageTextOutcome.NoText)
        val second = session.pageTextAwait(PdfPageId(0))
        assertEquals(first, second)
        assertEquals(1, backend.calls)
        session.close()
    }

    @Test
    fun aForeignSourceLengthIsNotCachedOrPresentedAsText() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(bytes = 99, pageIndex = it)) }
        val session = session(backend)
        val outcome = session.pageTextAwait(PdfPageId(0))
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.SOURCE_CHANGED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
        // A refused reply must be asked again rather than cached as a fact.
        session.pageTextAwait(PdfPageId(0))
        assertEquals(2, backend.calls)
        session.close()
    }

    @Test
    fun pageCountAndPageIndexDisagreementAreRefused() = runBlocking {
        val backend = FakeTextBackend {
            PdfPageTextOutcome.Ready(payload(pageIndex = it, pageCount = 4))
        }
        val session = session(backend)
        val outcome = session.pageTextAwait(PdfPageId(0))
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.BACKEND_FAILED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
        session.close()
    }

    @Test
    fun aPageBoxMismatchKeepsTheRealTextButMarksGeometryUntrusted() = runBlocking {
        val geometry = PdfPageGeometry(
            sourceSha256 = sha,
            pages = List(3) { PdfPageBox(600f, 800f) },
            encrypted = false,
        )
        val backend = FakeTextBackend {
            PdfPageTextOutcome.Ready(payload(pageIndex = it, widthPt = 612f, heightPt = 792f))
        }
        val session = session(backend, geometry = geometry)
        val outcome = session.pageTextAwait(PdfPageId(0))
        assertTrue(outcome is PdfPageTextOutcome.Ready)
        val ready = outcome as PdfPageTextOutcome.Ready
        assertEquals("Alpha beta", ready.page.text)
        assertFalse("a mismatched box must not authorize viewport placement", ready.geometryMatches)
        session.close()
    }

    @Test
    fun encryptedSourceWithoutAPasswordNeverTouchesTheBackend() = runBlocking {
        val geometry = PdfPageGeometry(
            sourceSha256 = sha,
            pages = List(3) { PdfPageBox(612f, 792f) },
            encrypted = true,
        )
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(pageIndex = it)) }
        val session = session(backend, geometry = geometry)
        val outcome = session.pageTextAwait(PdfPageId(0))
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.ENCRYPTED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
        assertEquals(0, backend.calls)
        session.close()
    }

    @Test
    fun cancelledCallerNeitherCallsNorCaches() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(pageIndex = it)) }
        val session = session(backend)
        val outcome = session.pageTextAwait(PdfPageId(0)) { true }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.CANCELLED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
        assertEquals(0, backend.calls)
        session.close()
    }

    @Test
    fun outOfRangeAndClosedSessionsAreTyped() = runBlocking {
        val backend = FakeTextBackend { PdfPageTextOutcome.Ready(payload(pageIndex = it)) }
        val session = session(backend)
        val range = session.pageTextAwait(PdfPageId(3))
        assertEquals(
            PdfTextUnavailableReason.PAGE_OUT_OF_RANGE,
            (range as PdfPageTextOutcome.Unavailable).reason,
        )
        session.close()
        val closed = session.pageTextAwait(PdfPageId(0))
        assertEquals(
            PdfTextUnavailableReason.SESSION_CLOSED,
            (closed as PdfPageTextOutcome.Unavailable).reason,
        )
    }
}
