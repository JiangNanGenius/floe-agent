// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteResourceRecord
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesCoverImageRequest
import com.floe.android.feature.notes.ui.api.NotesDocxExportRequest
import com.floe.android.feature.notes.ui.api.NotesExportedStream
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesImageInfo
import com.floe.android.feature.notes.ui.api.NotesImageProbeRequest
import com.floe.android.feature.notes.ui.api.NotesInkCreateRequest
import com.floe.android.feature.notes.ui.api.NotesInkSurface
import com.floe.android.feature.notes.ui.api.NotesMediaCapabilities
import com.floe.android.feature.notes.ui.api.NotesMediaPort
import com.floe.android.feature.notes.ui.api.NotesNormalizedRect
import com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfHandle
import com.floe.android.feature.notes.ui.api.NotesPdfOpenOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfOpenRequest
import com.floe.android.feature.notes.ui.api.NotesPdfPageSize
import com.floe.android.feature.notes.ui.api.NotesPdfPageText
import com.floe.android.feature.notes.ui.api.NotesPdfPageTextOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfSearchOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfTextRegion
import com.floe.android.feature.notes.ui.api.NotesPdfTextUnavailableReason
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import com.floe.android.feature.notes.ui.api.NotesPreparedImage
import com.floe.android.feature.notes.ui.api.NotesPrintOutcome
import com.floe.android.feature.notes.ui.api.NotesPrintRequest
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.NotesEditorTool
import com.floe.android.feature.notes.ui.presentation.NotesPdfTextNotice
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import java.lang.reflect.Proxy
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Session-bound regressions for the real Notes PDF selection flow: the source
 * text comes from the host handle, selection/copy are fenced by document
 * revision/page/source identity, and a late text callback after a page change
 * can never populate the new page.
 */
class NotesPdfTextSessionTest {

    private val sha = "a".repeat(64)
    private val resourceID = "resource-1"

    private fun document(revision: Int = 1) = NoteDocument(
        id = "doc-1",
        kind = NoteDocumentKind.NOTEBOOK,
        title = "PDF note",
        revision = revision,
        pages = listOf(
            NotePage(
                id = "page-1",
                width = 612.0,
                height = 792.0,
                backgroundResourceID = resourceID,
                pdfPageIndex = 0,
            ),
            NotePage(id = "page-2"),
        ),
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private fun record() = NoteResourceRecord(
        id = resourceID,
        hash = sha,
        byteCount = 4,
        fileName = "document.pdf",
        mediaType = "application/pdf",
    )

    private fun pageText(
        text: String = "Alpha beta",
        widthPt: Float = 612f,
        heightPt: Float = 792f,
        truncated: Boolean = false,
        pageIndex: Int = 0,
        pageCount: Int = 1,
    ) = NotesPdfPageText(
        sourceSha256 = sha,
        sourceByteCount = 4,
        pageIndex = pageIndex,
        pageCount = pageCount,
        pageWidthPt = widthPt,
        pageHeightPt = heightPt,
        text = text,
        regions = if (text.isEmpty()) {
            emptyList()
        } else {
            listOf(
                NotesPdfTextRegion(
                    startChar = 0,
                    endChar = text.length,
                    rects = listOf(NotesNormalizedRect(0.1f, 0.1f, 0.6f, 0.2f)),
                ),
            )
        },
        truncated = truncated,
    )

    private class FakeHandle(
        private val started: CompletableDeferred<Unit>? = null,
        private val outcome: suspend (Int) -> NotesPdfPageTextOutcome,
    ) : NotesPdfHandle {
        override val documentID: String = "doc-1"
        override val resourceID: String = "resource-1"
        override val pageCount: Int = 1
        override val sourceSha256: String = "a".repeat(64)
        override val sourceByteCount: Long = 4

        override fun pageSize(pageIndex: Int): NotesPdfPageSize? = NotesPdfPageSize(612f, 792f)

        override suspend fun renderPage(pageIndex: Int, targetWidthPx: Int): ByteArray = ByteArray(0)

        override suspend fun search(
            query: String,
            limit: Int,
            matchCase: Boolean,
        ): NotesPdfSearchOutcome = NotesPdfSearchOutcome.NoMatches

        override suspend fun pageText(pageIndex: Int): NotesPdfPageTextOutcome {
            started?.complete(Unit)
            return outcome(pageIndex)
        }

        override suspend fun close() = Unit
    }

    private class FakeMedia(private val handle: NotesPdfHandle) : NotesMediaPort {
        override fun capabilities(): NotesMediaCapabilities =
            NotesMediaCapabilities(pdfRendering = true, pdfTextSearch = true, pdfTextSelection = true)

        override suspend fun probeImage(request: NotesImageProbeRequest): NotesImageInfo? = null

        override suspend fun prepareCoverImage(request: NotesCoverImageRequest): NotesPreparedImage =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun openPdf(request: NotesPdfOpenRequest): NotesPdfOpenOutcome =
            NotesPdfOpenOutcome.Opened(handle)

        override suspend fun exportPdf(request: NotesPdfExportRequest): NotesExportedStream =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun exportDocx(request: NotesDocxExportRequest): NotesExportedStream =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun print(request: NotesPrintRequest): NotesPrintOutcome =
            NotesPrintOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override fun createInk(request: NotesInkCreateRequest): NotesInkSurface =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    }

    private inner class Harness(
        val handle: FakeHandle,
        fenced: () -> Boolean = { false },
    ) {
        val current = AtomicReference(document())
        val fencedFlag = AtomicBoolean(false)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        private val service: NotesService = Proxy.newProxyInstance(
            NotesService::class.java.classLoader,
            arrayOf(NotesService::class.java),
        ) { _, method, args ->
            val continuation = args?.lastOrNull() as? Continuation<*>
                ?: throw UnsupportedOperationException("not suspend: ${method.name}")
            @Suppress("UNCHECKED_CAST")
            fun resume(value: Any?) {
                (continuation as Continuation<Any?>).resumeWith(Result.success(value))
            }
            when (method.name) {
                "document" -> resume(current.get())
                "resourceMetadata" -> resume(record())
                "history" -> resume(NoteHistoryState(false, false))
                "markOpened" -> resume(Unit)
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService

        private val base = unavailableNotesHostPorts(
            InMemoryNotesPresentationStore(),
            InMemoryNotesRecoveryStore(),
        )
        val ports = NotesHostPorts(
            media = FakeMedia(handle),
            office = base.office,
            assistant = base.assistant,
            exchange = base.exchange,
            presentation = base.presentation,
            recovery = base.recovery,
        )
        val session = NotesDocumentSession(
            documentID = "doc-1",
            service = service,
            ports = ports,
            resources = NotesResourceAccess(service),
            scope = scope,
            generation = { 0L },
            fenced = { fencedFlag.get() || fenced() },
            onLibraryInvalidated = {},
        )

        suspend fun load() {
            assertTrue(session.load())
        }

        fun close() {
            session.dispose()
            scope.cancel()
        }
    }

    @Test
    fun explicitSelectionCopiesOnlyTheExactCurrentText() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            assertTrue(harness.session.pdfTextMode)
            assertFalse(harness.session.pdfTextLoading)
            assertNull(harness.session.pdfTextNotice)
            assertNotNull(harness.session.pdfTextPage)
            harness.session.selectPdfTextRegions(0, 0)
            assertEquals("Alpha beta", harness.session.pdfTextSelection?.text)
            assertEquals("Alpha beta", harness.session.copyablePdfText())
            harness.session.selectAllPdfText()
            assertEquals("Alpha beta", harness.session.copyablePdfPageText())
            harness.session.exitPdfTextMode()
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextSelection)
        } finally {
            harness.close()
        }
    }

    @Test
    fun switchingToDrawingLeavesTextModeWithoutClearingTheSearchHighlight() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.showPdfSearchHighlight(0, listOf(NotesNormalizedRect(0.1f, 0.1f, 0.4f, 0.2f)))
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            harness.session.selectEditorTool(NotesEditorTool.INK)
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextSelection)
            assertEquals(0, harness.session.pdfSearchHighlightPage ?: -1)
            assertEquals(1, harness.session.pdfSearchRects.size)
        } finally {
            harness.close()
        }
    }

    @Test
    fun aDocumentRevisionChangeClearsTheSelection() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            harness.current.set(document(revision = 2))
            harness.session.load()
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextPage)
            assertNull(harness.session.pdfTextSelection)
            assertNull(harness.session.copyablePdfText())
        } finally {
            harness.close()
        }
    }

    @Test
    fun aPageChangeClearsTheSelection() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            harness.session.setActivePage("page-2")
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextSelection)
            assertNull(harness.session.copyablePdfText())
        } finally {
            harness.close()
        }
    }

    @Test
    fun rootFenceRefusesCopyAndClearsTheMode() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            harness.fencedFlag.set(true)
            assertNull(harness.session.copyablePdfText())
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextSelection)
        } finally {
            harness.close()
        }
    }

    @Test
    fun theVisibleFenceTimerClearsTextWhenTheRootIsRevoked() = runBlocking {
        val harness = Harness(FakeHandle { NotesPdfPageTextOutcome.Ready(pageText()) })
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            harness.fencedFlag.set(true)
            harness.session.fencePdfTextIfStale()
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextPage)
            assertNull(harness.session.pdfTextSelection)
        } finally {
            harness.close()
        }
    }

    @Test
    fun aLateTextCallbackAfterAPageChangeCannotPopulateTheNewPage() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<NotesPdfPageTextOutcome>()
        val harness = Harness(
            FakeHandle(outcome = { gate.await() }, started = started),
        )
        try {
            harness.load()
            val job = launch { harness.session.beginPdfTextSelection() }
            started.await()
            harness.session.setActivePage("page-2")
            gate.complete(NotesPdfPageTextOutcome.Ready(pageText()))
            job.join()
            assertFalse(harness.session.pdfTextMode)
            assertNull(harness.session.pdfTextPage)
            assertNull(harness.session.pdfTextNotice)
        } finally {
            harness.close()
        }
    }

    @Test
    fun cancellingTheReadClearsTheModeAndLoadingState() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<NotesPdfPageTextOutcome>()
        val harness = Harness(
            FakeHandle(outcome = { gate.await() }, started = started),
        )
        try {
            harness.load()
            val job = launch { harness.session.beginPdfTextSelection() }
            started.await()
            job.cancel()
            job.join()
            assertFalse(harness.session.pdfTextMode)
            assertFalse(harness.session.pdfTextLoading)
            assertNull(harness.session.pdfTextPage)
        } finally {
            harness.close()
        }
    }

    @Test
    fun emptyAndUnsupportedPagesAreTypedInsteadOfFakeText() = runBlocking {
        val empty = Harness(
            FakeHandle {
                NotesPdfPageTextOutcome.NoText(pageIndex = 0, pageCount = 1)
            },
        )
        try {
            empty.load()
            empty.session.beginPdfTextSelection()
            assertEquals(NotesPdfTextNotice.NO_TEXT, empty.session.pdfTextNotice)
            assertNull(empty.session.pdfTextPage)
            assertNull(empty.session.copyablePdfPageText())
        } finally {
            empty.close()
        }

        val unsupported = Harness(
            FakeHandle {
                NotesPdfPageTextOutcome.Unavailable(
                    NotesPdfTextUnavailableReason.NATIVE_TEXT_UNSUPPORTED,
                )
            },
        )
        try {
            unsupported.load()
            unsupported.session.beginPdfTextSelection()
            assertEquals(
                NotesPdfTextNotice.NATIVE_TEXT_UNSUPPORTED,
                unsupported.session.pdfTextNotice,
            )
            assertNull(unsupported.session.pdfTextPage)
        } finally {
            unsupported.close()
        }
    }

    @Test
    fun geometryMismatchKeepsTheTextSheetButRefusesViewportSelection() = runBlocking {
        val harness = Harness(
            FakeHandle {
                NotesPdfPageTextOutcome.Ready(pageText(widthPt = 500f, heightPt = 500f))
            },
        )
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            assertEquals(NotesPdfTextNotice.GEOMETRY_MISMATCH, harness.session.pdfTextNotice)
            assertNotNull(harness.session.pdfTextPage)
            harness.session.selectPdfTextRegions(0, 0)
            assertNull(harness.session.pdfTextSelection)
            assertEquals("Alpha beta", harness.session.copyablePdfPageText())
        } finally {
            harness.close()
        }
    }

    @Test
    fun truncatedPageSelectionCarriesTheTruncationFact() = runBlocking {
        val harness = Harness(
            FakeHandle { NotesPdfPageTextOutcome.Ready(pageText(truncated = true)) },
        )
        try {
            harness.load()
            harness.session.beginPdfTextSelection()
            harness.session.selectPdfTextRegions(0, 0)
            assertTrue(harness.session.pdfTextSelection?.truncated == true)
        } finally {
            harness.close()
        }
    }
}
