// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Session-level regressions for the new password pass-through and the
 * asynchronous-isolated text entry point. A fake gateway proves the exact
 * secret buffer is handed to the transaction and cleared with the session;
 * no Android runtime is involved.
 */
class PdfDocumentSessionPasswordTest {

    private val sha = "c".repeat(64)

    private fun source(): VerifiedMediaSnapshot {
        val file = File(System.getProperty("java.io.tmpdir"), "session-password-${System.nanoTime()}.pdf")
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

    private class CapturingGateway : PdfRenderGateway {
        var seenPassword: CharArray? = null
        var renderCalls = 0

        override suspend fun documentInfo(source: VerifiedMediaSnapshot): PdfDocumentInfoResult =
            PdfDocumentInfoResult.Ready(3)

        override suspend fun documentInfoWithPassword(
            source: VerifiedMediaSnapshot,
            password: CharArray?,
        ): PdfDocumentInfoResult {
            seenPassword = password
            return PdfDocumentInfoResult.Ready(3)
        }

        override suspend fun renderPage(
            source: VerifiedMediaSnapshot,
            page: PdfPageId,
            zoomPercent: Int,
        ): PdfPageRenderResult = PdfPageRenderResult.Failed(PdfMediaFailure.TRANSPORT)

        override suspend fun renderPageWithPassword(
            source: VerifiedMediaSnapshot,
            page: PdfPageId,
            zoomPercent: Int,
            password: CharArray?,
        ): PdfPageRenderResult {
            seenPassword = password
            renderCalls++
            return PdfPageRenderResult.Failed(PdfMediaFailure.TRANSPORT)
        }

        override fun release(onQuiescent: (() -> Unit)?) = Unit
    }

    private class AsyncOnlyBackend : PdfTextBackend {
        override val id: String = "fake-async"
        var asyncCalls = 0

        override fun search(
            source: VerifiedMediaSnapshot,
            pageCount: Int,
            query: String,
            isCancelled: () -> Boolean,
        ): PdfTextSearchOutcome =
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NATIVE_TEXT_ASYNC_REQUIRED, id)

        override suspend fun searchAsync(
            source: VerifiedMediaSnapshot,
            pageCount: Int,
            query: String,
            limit: Int,
            isCancelled: () -> Boolean,
        ): PdfTextSearchOutcome {
            asyncCalls++
            return PdfTextSearchOutcome.Matches(
                query = query,
                matches = listOf(PdfTextMatch(PdfPageId(0), 0, query.length, query)),
                truncated = false,
            )
        }
    }

    private fun session(
        gateway: PdfRenderGateway,
        backend: PdfTextBackend,
        password: PdfPassword?,
        geometry: PdfPageGeometry? = null,
    ) = PdfDocumentSession(
        source = source(),
        pageCount = 3,
        geometry = geometry,
        gateway = gateway,
        ownsGateway = false,
        textBackend = backend,
        password = password,
        renderBudgetBytes = 1L shl 20,
        thumbnailBudgetBytes = 1L shl 20,
    )

    @Test
    fun sessionBorrowsTheSameSecretBufferForAPasswordRender() = runBlocking {
        val gateway = CapturingGateway()
        val password = PdfPassword.ofString("correct horse")!!
        val session = session(gateway, AsyncOnlyBackend(), password)
        session.renderPage(PdfPageId(1), 100)
        assertEquals(1, gateway.renderCalls)
        assertNotNull(gateway.seenPassword)
        // The binder receives the holder's own buffer (no app-process String).
        assertEquals("correct horse", String(gateway.seenPassword!!))
        session.close()
        assertTrue("session close clears the RAM-only holder", password.isEmpty)
    }

    @Test
    fun searchTextAwaitUsesTheAsyncBackend() = runBlocking {
        val backend = AsyncOnlyBackend()
        val session = session(CapturingGateway(), backend, password = null)
        val outcome = session.searchTextAwait("needle")
        assertTrue(outcome is PdfTextSearchOutcome.Matches)
        assertEquals(1, backend.asyncCalls)
        session.close()
    }

    @Test
    fun encryptedSourceWithoutPasswordNeverTouchesTheBackend() = runBlocking {
        val backend = AsyncOnlyBackend()
        val geometry = PdfPageGeometry(
            sourceSha256 = sha,
            pages = listOf(PdfPageBox(612f, 792f)),
            encrypted = true,
        )
        val session = session(CapturingGateway(), backend, password = null, geometry = geometry)
        val outcome = session.searchTextAwait("needle")
        assertTrue(outcome is PdfTextSearchOutcome.Unavailable)
        assertEquals(
            PdfTextUnavailableReason.ENCRYPTED,
            (outcome as PdfTextSearchOutcome.Unavailable).reason,
        )
        assertEquals("no false text claim after a refusal", 0, backend.asyncCalls)
        session.close()
    }

    @Test
    fun encryptedSourceWithAPasswordIsAllowedToSearch() = runBlocking {
        val backend = AsyncOnlyBackend()
        val geometry = PdfPageGeometry(
            sourceSha256 = sha,
            pages = listOf(PdfPageBox(612f, 792f)),
            encrypted = true,
        )
        val password = PdfPassword.ofString("pw")!!
        val session = session(CapturingGateway(), backend, password = password, geometry = geometry)
        val outcome = session.searchTextAwait("needle")
        assertTrue(outcome is PdfTextSearchOutcome.Matches)
        assertEquals(1, backend.asyncCalls)
        session.close()
        assertTrue(password.isEmpty)
    }
}
