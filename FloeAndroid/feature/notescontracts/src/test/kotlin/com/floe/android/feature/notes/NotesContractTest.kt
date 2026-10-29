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

    // MARK: - G06 C5 authority contract

    @Test
    fun proposalRequestCarriesExplicitOriginAndValidatedEdits() {
        val request = NotesProposalRequest(
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            expectedRevision = 4,
            title = "Title",
            edits = listOf(NotesEdit.Rename("Renamed")),
            conversationID = "5f3a2f83-1a92-4c0c-8a3f-0b3f5f8a8f11",
            environmentID = "env-a",
        )
        assertEquals(4, request.expectedRevision)
        assertEquals("env-a", request.environmentID)

        var failed = false
        try {
            NotesProposalRequest(
                documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
                expectedRevision = 4,
                title = "Title",
                edits = emptyList(),
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)

        failed = false
        try {
            NotesProposalRequest(
                documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
                expectedRevision = 4,
                title = "Title",
                edits = listOf(NotesEdit.Rename("Renamed")),
                environmentID = "env-without-conversation",
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun proposalApplyNeedsTheEditorGrantAndAcceptanceCannotBeResolved() {
        val apply = NotesProposalApplyRequest(
            proposalID = "4c9d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b90",
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            grantID = "opaque-grant",
            conversationID = "5f3a2f83-1a92-4c0c-8a3f-0b3f5f8a8f11",
            environmentID = "env-a",
        )
        assertEquals("opaque-grant", apply.grantID)

        var failed = false
        try {
            NotesProposalResolveRequest(
                proposalID = "4c9d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b90",
                decision = NoteProposalDecision.ACCEPTED,
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)

        failed = false
        try {
            NotesProposalApplyRequest(
                proposalID = "4c9d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b90",
                documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
                grantID = " ",
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun indexCacheReceiptKeepsStaleAndFailedDistinctFromSuccess() {
        val stale = NotesIndexCacheReceipt(
            status = NotesIndexCacheStatus.STALE,
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            documentRevision = 7,
            sourceKey = "old-native-key",
            indexed = false,
            retryable = false,
            currentKey = "new-native-key",
            storedKey = "old-native-key",
            reason = "sourceChanged",
        )
        assertTrue(stale.stale)
        assertFalse(stale.applied)
        assertFalse(stale.retryable)
        assertEquals("new-native-key", stale.currentKey)

        val failed = NotesIndexCacheReceipt(
            status = NotesIndexCacheStatus.FAILED,
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            documentRevision = 7,
            sourceKey = "old-native-key",
            indexed = false,
            retryable = false,
            reason = "pageNotFound",
        )
        assertEquals(NotesIndexCacheStatus.FAILED, failed.status)
        assertEquals("pageNotFound", failed.reason)
    }

    @Test
    fun pageOCRStateCarriesOnlyNativeRetryMetadata() {
        val state = NotesPageOCRState(
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            pageID = "f36c5c5a-3b31-4a5a-b602-e8d516b0e3d1",
            visualIndexKey = "native-opaque-key",
            current = false,
            indexed = false,
            needsVisualIndex = true,
            retryable = true,
        )
        assertFalse(state.current)
        assertTrue(state.retryable)
        assertEquals("native-opaque-key", state.visualIndexKey)
    }

    @Test
    fun conflictReviewRetainsBothDocumentsAndNeverAcceptsPartialResolution() {
        val current = document()
        val copy = document().copy(id = "1d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11")
        val request = NotesConflictReviewRequest(
            documentID = current.id,
            expectedRevision = current.revision,
            copyDocumentID = copy.id,
            expectedCopyRevision = copy.revision,
            title = "Conflict",
            edits = listOf(NotesEdit.Rename("Mine")),
        )
        assertEquals(copy.id, request.copyDocumentID)

        var failed = false
        try {
            NotesConflictReviewRequest(
                documentID = current.id,
                expectedRevision = current.revision,
                copyDocumentID = current.id,
                expectedCopyRevision = current.revision,
                title = "Conflict",
                edits = listOf(NotesEdit.Rename("Mine")),
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)

        failed = false
        try {
            NotesApplyRequest(
                documentID = current.id,
                expectedRevision = current.revision,
                edits = listOf(NotesEdit.Rename("Mine")),
                resolvingConflictID = "review-id",
            )
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)

        val resolved = NotesApplyRequest(
            documentID = current.id,
            expectedRevision = current.revision,
            edits = listOf(NotesEdit.Rename("Mine")),
            resolvingConflictID = "review-id",
            reviewedCopyID = copy.id,
            reviewedCopyRevision = copy.revision,
        )
        assertEquals(copy.id, resolved.reviewedCopyID)
    }

    @Test
    fun decisionEnvelopeIsDeliverableOnlyWhenRecorded() {
        val committed = NotesProposalDecisionEnvelope(
            intentID = "4c9d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b90",
            eventID = "8a1d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b91",
            proposalID = "9b1d0a6e-2e5b-4b8e-9c16-2f7a3d1e5b92",
            documentID = "0d9c2e64-1c6b-4f18-a01d-1d0a2d3f5e11",
            conversationID = "5f3a2f83-1a92-4c0c-8a3f-0b3f5f8a8f11",
            decision = NoteProposalDecision.ACCEPTED,
            baseRevision = 4,
            baseSHA256 = "a".repeat(64),
            phase = "recorded",
            ready = true,
            content = "structured",
            revision = 5,
        )
        assertTrue(committed.deliverable)
        assertFalse(committed.copy(phase = "committing", ready = false).deliverable)
    }
}
