// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.*
import com.floe.android.feature.notes.ui.api.*
import com.floe.android.feature.notes.ui.state.NotesVisualResourceImport
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NotesVisualResourceImportTest {
    private class Fixture {
        var mime = "application/pdf"
        var pageCount = 2
        var closed = 0
        var createCalls = 0
        var applyCalls = 0
        var protected = false
        var failApply = false
        var lastRequest: NotesApplyRequest? = null
        var document = NoteDocument(id = "note", kind = NoteDocumentKind.NOTEBOOK,
            title = "Imported", revision = 1, pages = listOf(NotePage("placeholder")),
            createdAt = 0.0, updatedAt = 0.0)
        val handle = Proxy.newProxyInstance(NotesPdfHandle::class.java.classLoader,
            arrayOf(NotesPdfHandle::class.java)) { _, method, _ ->
            when (method.name) {
                "getPageCount" -> pageCount
                "pageSize" -> NotesPdfPageSize(612f, 792f)
                "close" -> { closed++; Unit }
                else -> error("Unexpected PDF call: ${method.name}")
            }
        } as NotesPdfHandle
        val media = Proxy.newProxyInstance(NotesMediaPort::class.java.classLoader,
            arrayOf(NotesMediaPort::class.java)) { _, method, _ ->
            when (method.name) {
                "openPdf" -> if (protected) NotesPdfOpenOutcome.PasswordRequired else NotesPdfOpenOutcome.Opened(handle)
                "probeImage" -> NotesImageInfo(160, 80, "image/png")
                else -> error("Unexpected media call: ${method.name}")
            }
        } as NotesMediaPort
        val service = Proxy.newProxyInstance(NotesService::class.java.classLoader,
            arrayOf(NotesService::class.java)) { _, method, args ->
            when (method.name) {
                "resourceMetadata" -> NoteResourceRecord(args[0] as String, "a".repeat(64), 32, "input", mime)
                "createDocument" -> { createCalls++; document }
                "applyAtomically" -> {
                    applyCalls++
                    val request = args[0] as NotesApplyRequest
                    lastRequest = request
                    if (failApply) {
                        @Suppress("UNCHECKED_CAST")
                        (args.last() as Continuation<Any?>).resumeWith(Result.failure(
                            NotesException("storageUnavailable", "testFailure"),
                        ))
                        COROUTINE_SUSPENDED
                    } else {
                    val pages = request.edits.map { edit -> when (edit) {
                        is NotesEdit.UpdatePage -> edit.page
                        is NotesEdit.InsertPage -> edit.page
                        else -> error("Unexpected edit")
                    } }
                    document.copy(revision = document.revision + 1, pages = pages).also { document = it }
                    }
                }
                else -> error("Unexpected service call: ${method.name}")
            }
        } as NotesService
        suspend fun import() = NotesVisualResourceImport.create(service, media, "resource", "input", "Imported", "note")
    }

    @Test fun pdfUsesOriginalPagesInOneAtomicCommitAndClosesRenderer() = runBlocking {
        val f = Fixture(); val doc = f.import()
        assertEquals(2, doc.pages.size); assertEquals("placeholder", doc.pages[0].id)
        assertEquals(listOf(0, 1), doc.pages.map { it.pdfPageIndex })
        assertTrue(doc.pages.all { it.backgroundResourceID == "resource" })
        assertEquals(1, f.applyCalls); assertEquals(1, f.closed)
    }

    @Test fun imageUsesNativeNotebookBackgroundAndOriginalAspect() = runBlocking {
        val f = Fixture(); f.mime = "image/png"; val page = f.import().pages.single()
        assertEquals(384.0, page.height, 0.0); assertNull(page.pdfPageIndex)
        assertEquals("resource", page.backgroundResourceID); assertEquals(1, f.applyCalls)
    }

    @Test fun completedRetryDoesNotReplaceSubsequentUserEdits() = runBlocking {
        val f = Fixture(); f.import(); f.document = f.document.copy(revision = 9)
        assertEquals(9, f.import().revision); assertEquals(1, f.applyCalls)
    }

    @Test fun modifiedPlaceholderRefusesOverwrite() = runBlocking {
        val f = Fixture(); f.document = f.document.copy(revision = 4)
        try { f.import(); fail("Expected conflict") } catch (e: NotesException) { assertEquals("conflict", e.code) }
        assertEquals(0, f.applyCalls)
    }

    @Test fun passwordRequiredNeverCreatesBlankDocument() = runBlocking {
        val f = Fixture(); f.protected = true
        try { f.import(); fail("Expected password outcome") } catch (e: NotesException) { assertEquals("passwordRequired", e.code) }
        assertEquals(0, f.createCalls); assertEquals(0, f.applyCalls)
    }

    @Test fun failedAtomicApplyCanResumeSameUnchangedPlaceholder() = runBlocking {
        val f = Fixture(); f.failApply = true
        try { f.import(); fail("Expected failure") } catch (e: NotesException) { assertEquals("storageUnavailable", e.code) }
        val requestID = f.lastRequest!!.requestID
        f.failApply = false; assertEquals(2, f.import().pages.size)
        assertEquals(requestID, f.lastRequest!!.requestID); assertEquals(2, f.closed)
    }

    @Test fun oversizedPdfIsRefusedBeforeDocumentCreate() = runBlocking {
        val f = Fixture(); f.pageCount = NotesProtocol.MAX_EDITS + 1
        try { f.import(); fail("Expected size refusal") } catch (e: NotesException) { assertEquals("requestTooLarge", e.code) }
        assertEquals(0, f.createCalls); assertEquals(1, f.closed)
    }
}
