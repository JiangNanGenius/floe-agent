// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.state.NotesRecoveryResumeResult
import com.floe.android.feature.notes.ui.state.createNotesWorkspaceSession
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Actual recovery entry point: a failed source read must never delete the only draft. */
class NotesRecoveryRetentionTest {
    private val draft = NotesPendingRecovery(
        documentID = "note-1", documentKind = "notebook", documentTitle = "My draft",
        baseRevision = 4, requestTitle = "Edit", edits = emptyList(),
        reasonCode = "staleGeneration", createdAt = 1L, requestID = "original-receipt",
        inkDrafts = mapOf("page-1" to byteArrayOf(1, 2, 3)),
    )

    // Resume the Kotlin continuation instead of throwing a checked exception from
    // Java's InvocationHandler, which would wrap NotesException in a proxy error.
    private fun service(read: () -> NoteDocument): NotesService = Proxy.newProxyInstance(
        NotesService::class.java.classLoader, arrayOf(NotesService::class.java),
    ) { _, method, args ->
        check(method.name == "document") { "Unexpected service call: ${method.name}" }
        check(args!![0] == draft.documentID)
        @Suppress("UNCHECKED_CAST")
        val continuation = args.last() as Continuation<NoteDocument>
        continuation.resumeWith(runCatching(read))
        COROUTINE_SUSPENDED
    } as NotesService

    private suspend fun restore(read: () -> NoteDocument): NotesRecoveryResumeResult {
        val recovery = InMemoryNotesRecoveryStore().also { it.put(draft) }
        val session = createNotesWorkspaceSession(
            service(read), unavailableNotesHostPorts(InMemoryNotesPresentationStore(), recovery),
        )
        try {
            return session.resumeRecovery(draft.documentID)
        } finally {
            assertSame(draft, recovery.pending().single())
            assertEquals("original-receipt", recovery.pending().single().requestID)
            session.close()
        }
    }

    @Test fun missingSourceRetainsDraft() = runBlocking {
        assertSame(NotesRecoveryResumeResult.DocumentMissing, restore { throw NotesException("notFound") })
    }

    @Test fun storageFailureRetainsDraft() = runBlocking {
        assertTrue(restore { throw NotesException("storageUnavailable") } is NotesRecoveryResumeResult.Failed)
    }

    @Test fun trashedSourceRetainsDraft() = runBlocking {
        assertSame(NotesRecoveryResumeResult.DocumentDeleted, restore {
            NoteDocument(id = draft.documentID, kind = NoteDocumentKind.NOTEBOOK,
                title = "Trashed", revision = 4, createdAt = 1.0, updatedAt = 2.0, deletedAt = 3.0)
        })
    }

    @Test fun changedKindRetainsDraft() = runBlocking {
        assertTrue(restore {
            NoteDocument(id = draft.documentID, kind = NoteDocumentKind.MIND_MAP,
                title = "Different kind", revision = 4, createdAt = 1.0, updatedAt = 2.0)
        } is NotesRecoveryResumeResult.Failed)
    }

    @Test fun cancellationRetainsDraftAndPropagates() = runBlocking {
        val cancellation = CancellationException("root changed")
        try {
            restore { throw cancellation }
            throw AssertionError("Cancellation was swallowed")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
    }
}
