// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfTextRect
import com.floe.android.core.officeengine.pdf.OfficePdfTextRegion
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regressions for one-page selection extraction: real source text only, exact
 * page/source identity, bounded payloads, and typed unavailability for older
 * devices. No Android runtime is required.
 */
class PdfPageTextExtractionTest {

    private val sha = "d".repeat(64)

    private fun source(bytes: Int = 4): VerifiedMediaSnapshot {
        val file = File(System.getProperty("java.io.tmpdir"), "page-text-${System.nanoTime()}.pdf")
        file.writeBytes(ByteArray(bytes) { it.toByte() })
        file.deleteOnExit()
        return VerifiedMediaSnapshot(
            file = file.absoluteFile,
            sha256 = sha,
            byteCount = bytes.toLong(),
            mediaType = NotesMediaType.PDF,
            displayName = "fixture.pdf",
        )
    }

    private fun page(
        index: Int = 0,
        pageCount: Int = 2,
        bytes: Long = 4,
        text: String = "Alpha beta",
        truncated: Boolean = false,
    ) = OfficePdfPageText(
        pageIndex = index,
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

    private class FakeTransport(
        private val result: PdfPageTextResult,
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
            return result
        }
    }

    @Test
    fun returnsRealTextWithBoundsForExactlyTheRequestedPage() = runBlocking {
        val src = source()
        val transport = FakeTransport(PdfPageTextResult.Page(page(bytes = src.byteCount)))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        assertTrue(outcome is PdfPageTextOutcome.Ready)
        val ready = outcome as PdfPageTextOutcome.Ready
        assertEquals("Alpha beta", ready.page.text)
        assertEquals(0, ready.page.pageIndex)
        assertEquals(2, ready.page.pageCount)
        assertEquals(src.byteCount, ready.page.sourceBytes)
        assertEquals(1, transport.calls)
    }

    @Test
    fun sourceLengthDisagreementIsTypedNotSelected() = runBlocking {
        val src = source()
        val transport = FakeTransport(PdfPageTextResult.Page(page(bytes = src.byteCount + 1)))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.SOURCE_CHANGED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
    }

    @Test
    fun pageCountDisagreementIsRefused() = runBlocking {
        val src = source()
        val transport = FakeTransport(PdfPageTextResult.Page(page(pageCount = 3, bytes = src.byteCount)))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.BACKEND_FAILED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
    }

    @Test
    fun payloadOutsideTheWireContractIsRefused() = runBlocking {
        val src = source()
        val malformed = page(bytes = src.byteCount).copy(
            regions = listOf(
                OfficePdfTextRegion(
                    startChar = 0,
                    endChar = 99,
                    rects = listOf(OfficePdfTextRect(10f, 20f, 220f, 40f)),
                ),
            ),
        )
        val transport = FakeTransport(PdfPageTextResult.Page(malformed))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.BACKEND_FAILED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
    }

    @Test
    fun oldPlatformWithoutTextApiReturnsNativeUnsupported() = runBlocking {
        val src = source()
        val transport = FakeTransport(PdfPageTextResult.Failed(PdfMediaFailure.TEXT_UNSUPPORTED))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.NATIVE_TEXT_UNSUPPORTED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
    }

    @Test
    fun passwordAndTransportFailuresStayTyped() = runBlocking {
        val src = source()
        for ((failure, expected) in listOf(
            PdfMediaFailure.PASSWORD_PROTECTED to PdfTextUnavailableReason.ENCRYPTED,
            PdfMediaFailure.PASSWORD_REJECTED to PdfTextUnavailableReason.PASSWORD_REJECTED,
            PdfMediaFailure.PASSWORD_UNSUPPORTED to PdfTextUnavailableReason.PASSWORD_UNSUPPORTED,
            PdfMediaFailure.TRANSPORT to PdfTextUnavailableReason.BACKEND_FAILED,
        )) {
            val outcome = IsolatedPdfTextBackend(
                FakeTransport(PdfPageTextResult.Failed(failure)),
            ).pageText(src, 2, PdfPageId(0)) { false }
            assertEquals(expected, (outcome as PdfPageTextOutcome.Unavailable).reason)
        }
    }

    @Test
    fun cancellationIsCheckedBeforeAnyTransaction() = runBlocking {
        val src = source()
        val transport = FakeTransport(PdfPageTextResult.Page(page(bytes = src.byteCount)))
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { true }
        assertTrue(outcome is PdfPageTextOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.CANCELLED,
            (outcome as PdfPageTextOutcome.Unavailable).reason,
        )
        assertEquals(0, transport.calls)
    }

    @Test
    fun truncatedTextKeepsTheTruncationFact() = runBlocking {
        val src = source()
        val transport = FakeTransport(
            PdfPageTextResult.Page(page(bytes = src.byteCount, text = "Alpha", truncated = true)),
        )
        val outcome = IsolatedPdfTextBackend(transport).pageText(src, 2, PdfPageId(0)) { false }
        val ready = outcome as PdfPageTextOutcome.Ready
        assertTrue(ready.page.truncated)
        assertEquals("Alpha", ready.page.text)
    }
}
