// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesAssistantPort
import com.floe.android.feature.notes.ui.api.NotesCoverImageRequest
import com.floe.android.feature.notes.ui.api.NotesDocxExportRequest
import com.floe.android.feature.notes.ui.api.NotesDocxLabels
import com.floe.android.feature.notes.ui.api.NotesExchangePort
import com.floe.android.feature.notes.ui.api.NotesExportedStream
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesImageInfo
import com.floe.android.feature.notes.ui.api.NotesImageProbeRequest
import com.floe.android.feature.notes.ui.api.NotesImportKind
import com.floe.android.feature.notes.ui.api.NotesInkCreateRequest
import com.floe.android.feature.notes.ui.api.NotesInkSurface
import com.floe.android.feature.notes.ui.api.NotesMediaCapabilities
import com.floe.android.feature.notes.ui.api.NotesMediaPort
import com.floe.android.feature.notes.ui.api.NotesOfficePort
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentRequest
import com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfOpenOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfOpenRequest
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import com.floe.android.feature.notes.ui.api.NotesPreparedImage
import com.floe.android.feature.notes.ui.api.NotesPrintOutcome
import com.floe.android.feature.notes.ui.api.NotesPrintRequest
import com.floe.android.feature.notes.ui.api.NotesShareOutcome
import com.floe.android.feature.notes.ui.api.NotesShareStreamRequest
import com.floe.android.feature.notes.ui.api.NotesShareTextRequest
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Delivery boundary regressions for Notes export: ordered page identity is
 * re-read from the stored document, a stale revision or invalid selection is
 * refused before media work, and no receipt is created until the existing
 * share surface actually launches.
 */
class NotesExportControllerTest {

    private fun page(id: String, text: String = id) = NotePage(
        id = id,
        elements = listOf(
            NoteElement(
                id = "$id-element",
                kind = NoteElementKind.TEXT,
                frame = NoteRect(x = 20.0, y = 20.0, width = 300.0, height = 60.0),
                text = text,
            ),
        ),
    )

    private fun document(
        pages: List<NotePage> = listOf(page("p1"), page("p2")),
        revision: Int = 3,
    ) = NoteDocument(
        id = "doc-1",
        kind = NoteDocumentKind.NOTEBOOK,
        title = "Export",
        revision = revision,
        pages = pages,
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private class FakeService(initial: NoteDocument) {
        @Volatile
        var current: NoteDocument = initial

        @Volatile
        var documentFailure: Throwable? = null

        @Suppress("UNCHECKED_CAST")
        private fun resume(continuation: Continuation<*>, result: Result<Any?>) {
            (continuation as Continuation<Any?>).resumeWith(result)
        }

        val service: NotesService = Proxy.newProxyInstance(
            NotesService::class.java.classLoader,
            arrayOf(NotesService::class.java),
        ) { _, method, args ->
            val continuation = args?.lastOrNull() as? Continuation<*>
                ?: throw UnsupportedOperationException("not suspend: ${method.name}")
            when (method.name) {
                "document" -> resume(continuation, runCatching {
                    documentFailure?.let { throw it }
                    current
                })
                "history" -> resume(continuation, Result.success(NoteHistoryState(false, false)))
                "markOpened" -> resume(continuation, Result.success(Unit))
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService
    }

    private class FakeMedia : NotesMediaPort {
        var pdfRequest: NotesPdfExportRequest? = null
        var imageRequest: NotesPageImageExportRequest? = null
        var docxRequest: NotesDocxExportRequest? = null
        var closed = 0

        private fun bytes(): ByteArray = "export-bytes".encodeToByteArray()

        private fun stream(name: String, mediaType: String): NotesExportedStream {
            val data = bytes()
            return NotesExportedStream(
                fileName = name,
                mediaType = mediaType,
                totalBytes = data.size.toLong(),
                read = { offset, maxBytes ->
                    val start = offset.toInt().coerceIn(0, data.size)
                    val end = (start + maxBytes).coerceAtMost(data.size)
                    data.copyOfRange(start, end)
                },
                close = { closed += 1 },
            )
        }

        override fun capabilities(): NotesMediaCapabilities =
            NotesMediaCapabilities(pdfExport = true, imageExport = true)

        override suspend fun exportPdf(request: NotesPdfExportRequest): NotesExportedStream {
            pdfRequest = request
            return stream(request.fileName, "application/pdf")
        }

        override suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream {
            imageRequest = request
            return stream(request.fileName, "image/png")
        }

        override suspend fun exportDocx(request: NotesDocxExportRequest): NotesExportedStream {
            docxRequest = request
            return stream(request.fileName, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        }

        override suspend fun probeImage(request: NotesImageProbeRequest): NotesImageInfo? = null

        override suspend fun prepareCoverImage(request: NotesCoverImageRequest): NotesPreparedImage =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun openPdf(request: NotesPdfOpenRequest): NotesPdfOpenOutcome =
            NotesPdfOpenOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun print(request: NotesPrintRequest): NotesPrintOutcome =
            NotesPrintOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override fun createInk(request: NotesInkCreateRequest): NotesInkSurface =
            throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    }

    private class FakeExchange : NotesExchangePort {
        var fail = false
        var cancel = false
        var contentUri: String? = null
        var openOutcome: NotesOpenAttachmentOutcome = NotesOpenAttachmentOutcome.Opened
        var openedUri: String? = null
        var streamRequest: NotesShareStreamRequest? = null
        var textRequest: NotesShareTextRequest? = null

        override suspend fun shareStream(request: NotesShareStreamRequest): NotesShareOutcome {
            streamRequest = request
            if (cancel) throw CancellationException("cancelled")
            if (fail) throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.FAILED, "shareFailed"))
            return NotesShareOutcome(launched = true, locationLabel = "Files", contentUri = contentUri)
        }

        override suspend fun shareText(request: NotesShareTextRequest): NotesShareOutcome {
            textRequest = request
            if (fail) throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.FAILED, "shareFailed"))
            return NotesShareOutcome(launched = true, locationLabel = "Files")
        }

        override suspend fun pickFile(
            kinds: Set<NotesImportKind>,
            suggestedName: String?,
        ): NotesPickedFile? = null

        override suspend fun openAttachment(
            request: NotesOpenAttachmentRequest,
        ): NotesOpenAttachmentOutcome =
            NotesOpenAttachmentOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))

        override suspend fun openOwnedExport(uri: String): NotesOpenAttachmentOutcome {
            openedUri = uri
            return openOutcome
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T : Any> unusedPort(type: Class<T>): T =
        Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { _, method, _ ->
            throw UnsupportedOperationException("Unexpected ${method.name}")
        } as T

    private inner class Harness(initial: NoteDocument) {
        val media = FakeMedia()
        val exchange = FakeExchange()
        val service = FakeService(initial)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val ports = NotesHostPorts(
            media = media,
            office = unusedPort(NotesOfficePort::class.java),
            assistant = unusedPort(NotesAssistantPort::class.java),
            exchange = exchange,
            presentation = InMemoryNotesPresentationStore(),
            recovery = InMemoryNotesRecoveryStore(),
        )
        val session = NotesDocumentSession(
            documentID = "doc-1",
            service = service.service,
            ports = ports,
            resources = NotesResourceAccess(service.service),
            scope = scope,
            generation = { 0L },
            fenced = { false },
            onLibraryInvalidated = {},
        )
        val controller = NotesWorkspaceController(
            service = service.service,
            ports = ports,
            scope = scope,
            generation = { 0L },
            fenced = { false },
        )

        suspend fun load() {
            assertTrue(session.load())
        }

        fun close() {
            session.dispose()
        }
    }

    @Test
    fun `explicit page order reaches the renderer and the receipt`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertTrue(harness.controller.exportPdf(harness.session, listOf("p2", "p1")))
            assertEquals(listOf("p2", "p1"), harness.media.pdfRequest?.pages?.map { it.pageID })
            assertEquals(1, harness.media.closed)
            val receipt = harness.controller.lastExportReceipt
            assertNotNull(receipt)
            val deliveredReceipt = receipt!!
            assertEquals(listOf("p2", "p1"), deliveredReceipt.pageIDs)
            assertEquals(2, deliveredReceipt.pageCount!!)
            assertEquals(12L, deliveredReceipt.byteCount)
            assertNull(harness.controller.lastFailure)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `default export re-reads the whole document in document order`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertTrue(harness.controller.exportPdf(harness.session))
            assertEquals(listOf("p1", "p2"), harness.media.pdfRequest?.pages?.map { it.pageID })
        } finally {
            harness.close()
        }
    }

    @Test
    fun `stale stored revision refuses before media work`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.service.current = document(revision = 4, pages = listOf(page("p1")))
            assertFalse(harness.controller.exportPdf(harness.session, listOf("p1")))
            assertNull(harness.media.pdfRequest)
            assertNull(harness.controller.lastExportReceipt)
            assertEquals("conflict", harness.controller.lastFailure?.code)
            assertEquals("documentChanged", harness.controller.lastFailure?.detail)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `revoked storage access refuses before any renderer work`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.service.documentFailure = NotesException("permissionDenied", "rootRevoked")
            assertFalse(harness.controller.exportPdf(harness.session))
            assertNull(harness.media.pdfRequest)
            assertNull(harness.controller.lastExportReceipt)
            assertEquals("permissionDenied", harness.controller.lastFailure?.code)
            assertEquals("rootRevoked", harness.controller.lastFailure?.detail)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `duplicate selection is refused without generating or delivering bytes`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertFalse(harness.controller.exportPdf(harness.session, listOf("p1", "p1")))
            assertNull(harness.media.pdfRequest)
            assertNull(harness.exchange.streamRequest)
            assertEquals("invalidPageSelection", harness.controller.lastFailure?.code)
            assertEquals("duplicatePage", harness.controller.lastFailure?.detail)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `share failure is not reported as a delivered export`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.exchange.fail = true
            assertFalse(harness.controller.exportPdf(harness.session))
            assertNotNull(harness.media.pdfRequest)
            assertNull(harness.controller.lastExportReceipt)
            assertEquals("failed", harness.controller.lastFailure?.code)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `notebook markdown is delivered as a real markdown document`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertTrue(harness.controller.exportNotebookMarkdown(harness.session))
            val request = harness.exchange.textRequest
            assertNotNull(request)
            val delivered = request!!
            assertEquals("text/markdown", delivered.mediaType)
            assertEquals("Export.md", delivered.fileName)
            assertTrue(delivered.text.startsWith("# Export\n\n## Page 1"))
            assertTrue(delivered.text.contains("## Page 2"))
            val receipt = harness.controller.lastExportReceipt
            assertNotNull(receipt)
            val deliveredReceipt = receipt!!
            assertEquals(listOf("p1", "p2"), deliveredReceipt.pageIDs)
            assertEquals(2, deliveredReceipt.pageCount!!)
            assertTrue(deliveredReceipt.byteCount > 0L)
            assertNull(harness.media.pdfRequest)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `mind map markdown outline keeps its existing shape`() = runBlocking {
        val map = NoteDocument(
            id = "doc-1",
            kind = NoteDocumentKind.MIND_MAP,
            title = "Mind Map",
            revision = 1,
            pages = emptyList(),
            nodes = listOf(
                MindMapNode(id = "root", title = "Root"),
                MindMapNode(id = "child", parentID = "root", title = "Child"),
            ),
            createdAt = 1.0,
            updatedAt = 2.0,
        )
        val harness = Harness(map)
        try {
            harness.load()
            assertTrue(harness.controller.exportOutline(harness.session))
            val request = harness.exchange.textRequest
            assertNotNull(request)
            val delivered = request!!
            assertEquals("text/markdown", delivered.mediaType)
            assertEquals("Mind Map.md", delivered.fileName)
            assertTrue(delivered.text.startsWith("# Mind Map\n"))
            assertTrue(delivered.text.contains("- Root"))
            assertTrue(delivered.text.contains("  - Child"))
            assertNull(harness.media.pdfRequest)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `cancellation during delivery keeps the generated file out of a receipt`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.exchange.cancel = true
            val error = runCatching { harness.controller.exportPdf(harness.session) }.exceptionOrNull()
            assertTrue(error is CancellationException)
            assertNull(harness.controller.lastExportReceipt)
            assertNotNull(harness.exchange.streamRequest)
            assertEquals(1, harness.media.closed)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `default page image keeps the existing current-page behavior`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.session.setActivePage("p1")
            assertTrue(harness.controller.exportCurrentPageImage(harness.session))
            assertEquals("p1", harness.media.imageRequest?.page?.pageID)
            assertEquals(listOf("p1"), harness.controller.lastExportReceipt?.pageIDs)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `notebook markdown honors an ordered subset and excludes unselected pages`() = runBlocking {
        val harness = Harness(document(pages = listOf(page("p1"), page("p2"), page("p3"))))
        try {
            harness.load()
            assertTrue(harness.controller.exportNotebookMarkdown(harness.session, listOf("p3", "p1")))
            val request = harness.exchange.textRequest
            assertNotNull(request)
            val delivered = request!!
            assertEquals("Export.md", delivered.fileName)
            assertTrue(delivered.text.contains("## Page 3"))
            assertTrue(delivered.text.contains("## Page 1"))
            assertFalse(delivered.text.contains("## Page 2"))
            assertFalse(delivered.text.contains("p2"))
            assertEquals(listOf("p3", "p1"), harness.controller.lastExportReceipt?.pageIDs)
            assertEquals(2, harness.controller.lastExportReceipt?.pageCount)
            assertNull(harness.media.pdfRequest)
            assertNull(harness.media.docxRequest)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `notebook markdown default keeps the whole document in stored order`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertTrue(harness.controller.exportNotebookMarkdown(harness.session))
            val text = harness.exchange.textRequest?.text.orEmpty()
            assertTrue(text.indexOf("## Page 1") < text.indexOf("## Page 2"))
            assertEquals(listOf("p1", "p2"), harness.controller.lastExportReceipt?.pageIDs)
            assertEquals(2, harness.controller.lastExportReceipt?.pageCount)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `notebook markdown refuses stale duplicate unknown and empty selections before sharing`() = runBlocking {
        val cases = listOf(
            Triple(document(revision = 4), listOf("p1"), "conflict"),
            Triple(document(), listOf("p1", "p1"), "invalidPageSelection"),
            Triple(document(), listOf("missing"), "notFound"),
            Triple(document(), emptyList(), "invalidPageSelection"),
        )
        for ((current, selection, code) in cases) {
            val harness = Harness(document())
            try {
                harness.load()
                harness.service.current = current
                assertFalse(harness.controller.exportNotebookMarkdown(harness.session, selection))
                assertNull(harness.exchange.textRequest)
                assertNull(harness.controller.lastExportReceipt)
                assertEquals(code, harness.controller.lastFailure?.code)
            } finally {
                harness.close()
            }
        }
    }

    @Test
    fun `docx export passes the exact ordered selection and produces a share receipt`() = runBlocking {
        val harness = Harness(document(pages = listOf(page("p1"), page("p2"), page("p3"))))
        try {
            harness.load()
            assertTrue(harness.controller.exportDocx(harness.session, listOf("p3", "p1")))
            val request = harness.media.docxRequest
            assertNotNull(request)
            val delivered = request!!
            assertEquals(listOf("p3", "p1"), delivered.pages.map { it.pageID })
            assertEquals(listOf(3, 1), delivered.pageNumbers)
            assertEquals("Export.docx", delivered.fileName)
            assertEquals(NotesDocxLabels().pageHeadingFormat, delivered.labels.pageHeadingFormat)
            assertEquals(listOf("p3", "p1"), harness.controller.lastExportReceipt?.pageIDs)
            assertEquals(2, harness.controller.lastExportReceipt?.pageCount)
            assertEquals(1, harness.media.closed)
            assertNull(harness.exchange.textRequest)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `docx default exports the whole document in stored order`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            assertTrue(harness.controller.exportDocx(harness.session))
            assertEquals(listOf("p1", "p2"), harness.media.docxRequest?.pages?.map { it.pageID })
            assertEquals(listOf(1, 2), harness.media.docxRequest?.pageNumbers)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `docx stale or invalid selection never reaches the media or share surface`() = runBlocking {
        val stale = Harness(document())
        try {
            stale.load()
            stale.service.current = document(revision = 4)
            assertFalse(stale.controller.exportDocx(stale.session, listOf("p1")))
            assertNull(stale.media.docxRequest)
            assertNull(stale.exchange.streamRequest)
            assertNull(stale.controller.lastExportReceipt)
            assertEquals("conflict", stale.controller.lastFailure?.code)
        } finally {
            stale.close()
        }
        val duplicate = Harness(document())
        try {
            duplicate.load()
            assertFalse(duplicate.controller.exportDocx(duplicate.session, listOf("p1", "p1")))
            assertNull(duplicate.media.docxRequest)
            assertNull(duplicate.exchange.streamRequest)
            assertEquals("invalidPageSelection", duplicate.controller.lastFailure?.code)
        } finally {
            duplicate.close()
        }
    }

    @Test
    fun `docx cancellation during delivery leaves no success receipt`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.exchange.cancel = true
            val error = runCatching { harness.controller.exportDocx(harness.session) }.exceptionOrNull()
            assertTrue(error is CancellationException)
            assertNull(harness.controller.lastExportReceipt)
            assertNotNull(harness.media.docxRequest)
            assertEquals(1, harness.media.closed)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `docx reopen uses the exact owned handle and never invents one`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.exchange.contentUri = "content://com.floe.android.dev.notes.exports/share/token1"
            assertTrue(harness.controller.exportDocx(harness.session))
            val receipt = harness.controller.lastExportReceipt
            assertNotNull(receipt)
            assertEquals(harness.exchange.contentUri, receipt!!.contentUri)
            val outcome = harness.controller.openExportedDocument()
            assertTrue(outcome is NotesOpenAttachmentOutcome.Opened)
            assertEquals(harness.exchange.contentUri, harness.exchange.openedUri)
            assertEquals(harness.exchange.contentUri, harness.controller.lastExportReceipt?.contentUri)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `reopen without a generated export is unavailable and does not call the host`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            val outcome = harness.controller.openExportedDocument()
            assertTrue(outcome is NotesOpenAttachmentOutcome.Unavailable)
            assertNull(harness.exchange.openedUri)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `docx share failure leaves no success receipt`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.exchange.fail = true
            assertFalse(harness.controller.exportDocx(harness.session))
            assertNotNull(harness.media.docxRequest)
            assertNull(harness.controller.lastExportReceipt)
            assertEquals("failed", harness.controller.lastFailure?.code)
            assertEquals(1, harness.media.closed)
        } finally {
            harness.close()
        }
    }

    @Test
    fun `page image uses the explicitly selected page rather than the active page`() = runBlocking {
        val harness = Harness(document())
        try {
            harness.load()
            harness.session.setActivePage("p1")
            assertTrue(harness.controller.exportCurrentPageImage(harness.session, "p2"))
            assertEquals("p2", harness.media.imageRequest?.page?.pageID)
            assertEquals(listOf("p2"), harness.controller.lastExportReceipt?.pageIDs)
            assertEquals(1, harness.controller.lastExportReceipt!!.pageCount!!)
        } finally {
            harness.close()
        }
    }
}
