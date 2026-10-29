package com.floe.android.feature.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesContractTest {
    private val now = 1_790_000_000_000.0

    private fun document(
        kind: NoteDocumentKind = NoteDocumentKind.NOTEBOOK,
        revision: Int = 3,
    ) = NoteDocument(
        id = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
        kind = kind,
        title = "手记 § baseline",
        revision = revision,
        pages = listOf(
            NotePage(
                id = "f36c5c5a-3b31-4a5a-b602-e8d516b0e3d1",
                elements = listOf(
                    NoteElement(
                        id = "89f9f6fb-d771-4f49-897a-fd0f63c8d471",
                        text = "Independent notes workspace",
                        frame = NoteRect(10.0, 20.0, 300.0, 80.0),
                    ),
                ),
                drawingResourceID = "f3c8a6be-9e09-4b99-9d11-4d3b1f7d1a2b",
                ocrSourceKey = "native-opaque-key",
            ),
        ),
        createdAt = now,
        updatedAt = now,
    )

    @Test
    fun documentContractKeepsPageAndResourceIdentity() {
        val value = document()
        assertEquals("手记 § baseline", value.title)
        assertEquals(3, value.revision)
        assertEquals(NoteCoverMode.AUTOMATIC, value.coverMode)
        assertTrue(value.resourceIDs.contains("f3c8a6be-9e09-4b99-9d11-4d3b1f7d1a2b"))
        assertEquals("native-opaque-key", value.pages.single().ocrSourceKey)
    }

    @Test
    fun customCoverWinsOverAutomatic() {
        val value = document().copy(coverResourceID = "9c0d6a5c-5792-4ab4-87f0-8b2a5f1d7c31",
            coverRevision = 0)
        assertEquals(NoteCoverMode.CUSTOM, value.coverMode)
        assertEquals(0, value.normalizedCoverRevision)
    }

    @Test
    fun coverBaselineNeverUsesAnAbsentVersionAsOne() {
        val value = document().copy(coverRevision = null)
        assertEquals(0, value.normalizedCoverRevision)
    }

    @Test
    fun editVocabularyRejectsImpossibleFramesAndSlices() {
        var failed = false
        try {
            NoteRect(width = 0.0)
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
        failed = false
        try {
            NoteTextSlice(start = 5, count = 5, total = 8)
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun applyRequestKeepsRevisionAndRebaseMutuallyExclusiveWithAssistant() {
        val request = NotesApplyRequest(
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            expectedRevision = 3,
            edits = listOf(NotesEdit.Rename("Renamed")),
            requestID = "ui-edit-1",
            baseRevision = 2,
        )
        assertEquals(2, request.baseRevision)
        var failed = false
        try {
            NotesApplyRequest(
                documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
                expectedRevision = 3,
                edits = listOf(NotesEdit.Rename("Renamed")),
                baseRevision = 2,
                conversationID = "5f3a2f83-1a92-4c0c-8a3f-0b3f5f8a8f11",
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun createRequiresAnImportedResourceForOfficeAndEngineering() {
        var failed = false
        try {
            NotesCreateDocument(kind = NoteDocumentKind.OFFICE, title = "Report")
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
        val value = NotesCreateDocument(
            kind = NoteDocumentKind.OFFICE,
            title = "Report",
            resourceID = "e7d6b0e3-9f2f-4e2d-8d1c-8b0a9c7d6e5f",
            fileName = "report.docx",
        )
        assertEquals("report.docx", value.fileName)
    }

    @Test
    fun eventBatchCannotLeadTheServiceOrDuplicateSequence() {
        val batch = NotesEventBatch(
            sequence = 7,
            cursor = 5,
            events = listOf(NotesEvent(6, "document.updated", revision = 4),
                NotesEvent(7, "document.updated", revision = 5)),
            hasMore = false,
            resyncRequired = false,
        )
        assertEquals(5L, batch.cursor)
        var failed = false
        try {
            NotesEventBatch(sequence = 5, cursor = 6, events = emptyList(), hasMore = false,
                resyncRequired = false)
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun errorsExposeOnlyTypedCodes() {
        val conflict = NotesException("conflict", "revisionOrSourceChanged", retryable = true)
        assertTrue(conflict.isConflict)
        assertTrue(conflict.retryable)
        assertFalse(conflict.needsRebind)
        assertTrue(NotesException("staleGeneration").needsRebind)
        assertNull(NotesException("notFound").reason)
    }

    @Test
    fun largeTextWriteRequiresAnExactBoundedByteCount() {
        val append = NotesTextWrite(
            mode = NotesTextWriteMode.APPEND_BLOCK,
            byteCount = 2_000_000,
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            pageID = "f36c5c5a-3b31-4a5a-b602-e8d516b0e3d1",
            expectedRevision = 4,
            title = "Paste",
        )
        assertEquals(2_000_000L, append.byteCount)
        var failed = false
        try {
            NotesTextWrite(
                mode = NotesTextWriteMode.REPLACE_ELEMENT,
                byteCount = 10,
                documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
                pageID = "f36c5c5a-3b31-4a5a-b602-e8d516b0e3d1",
                expectedRevision = 4,
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun protocolBoundsMatchTheNativeChannel() {
        assertEquals(4, NotesProtocol.VERSION)
        assertEquals("floe.notes/4", NotesProtocol.SCHEMA)
        assertEquals(65_536, NotesProtocol.MAX_REQUEST_BYTES)
        assertEquals(44_000, NotesProtocol.CHUNK_BYTES)
        assertEquals(10_000, NotesProtocol.MAX_EDITS)
        assertEquals(2_097_152L, NotesProtocol.MAX_STAGED_TEXT_BYTES)
    }
}
