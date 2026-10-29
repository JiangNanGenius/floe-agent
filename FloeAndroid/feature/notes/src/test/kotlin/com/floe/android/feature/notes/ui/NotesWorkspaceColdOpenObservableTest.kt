// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import androidx.compose.runtime.derivedStateOf
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesCounts
import com.floe.android.feature.notes.NotesDocumentPage
import com.floe.android.feature.notes.NotesEventBatch
import com.floe.android.feature.notes.NotesLibrarySummary
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.NotesWorkspacePreferences
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cold-reopen boundary: the last active document id is restored from
 * preferences before any session exists. `openDocument` then inserts the
 * session while `activeDocumentID` is already equal to the opened id, so the
 * session map itself must be snapshot-observable. With a plain `mutableMapOf`
 * the workspace composable keeps rendering the "Select a Note" placeholder and
 * the exact card tap appears to do nothing.
 */
class NotesWorkspaceColdOpenObservableTest {
    private val documentID = "11111111-2222-4333-8444-555555555555"

    private fun document() = NoteDocument(
        id = documentID,
        kind = NoteDocumentKind.NOTEBOOK,
        title = "Cold reopen",
        revision = 1,
        pages = listOf(NotePage(id = "66666666-7777-4888-8999-aaaaaaaaaaaa")),
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private fun summary() = NoteDocumentSummary(
        id = documentID,
        kind = NoteDocumentKind.NOTEBOOK,
        title = "Cold reopen",
        revision = 1,
        pageCount = 1,
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    /** Holds the first library call until the test has observed the empty pane. */
    private class GatedLibraryService(private val document: NoteDocument) {
        private var libraryContinuation: Continuation<*>? = null

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
                "library" -> libraryContinuation = continuation
                "documents" -> resume(
                    continuation,
                    Result.success(NotesDocumentPage(listOf(summaryOf(document)), false, 1)),
                )
                "notebooks" -> resume(continuation, Result.success(emptyList<Any>()))
                "collectDeletedResources" -> resume(continuation, Result.success(Unit))
                "document" -> resume(continuation, Result.success(document))
                "history" -> resume(continuation, Result.success(NoteHistoryState(false, false)))
                "markOpened" -> resume(continuation, Result.success(Unit))
                "pollEvents" -> resume(
                    continuation,
                    Result.success(
                        NotesEventBatch(
                            sequence = 0,
                            cursor = 0,
                            events = emptyList(),
                            hasMore = false,
                            resyncRequired = false,
                        ),
                    ),
                )
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService

        fun releaseLibrary() {
            val continuation = libraryContinuation ?: error("library was not requested")
            libraryContinuation = null
            resume(continuation, Result.success(librarySummary()))
        }

        private fun librarySummary(): NotesLibrarySummary = NotesLibrarySummary(
            notebooks = emptyList(),
            counts = NotesCounts(
                documents = 1,
                trashed = 0,
                favorites = 0,
                notebooks = 0,
                mindMaps = 0,
                office = 0,
                engineering = 0,
            ),
            recent = listOf(summaryOf(document)),
        )

        companion object {
            fun summaryOf(document: NoteDocument) = NoteDocumentSummary(
                id = document.id,
                kind = document.kind,
                title = document.title,
                revision = document.revision,
                pageCount = document.pages.size,
                createdAt = document.createdAt,
                updatedAt = document.updatedAt,
            )
        }
    }

    @Test
    fun restoredActiveDocumentBecomesVisibleWhenItsSessionIsInserted() = runBlocking {
        val presentation = InMemoryNotesPresentationStore()
        presentation.saveWorkspace(
            NotesWorkspacePreferences(
                openDocumentIDs = listOf(documentID),
                activeDocumentID = documentID,
                grid = false,
            ),
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val native = GatedLibraryService(document())
        try {
            val controller = NotesWorkspaceController(
                service = native.service,
                ports = unavailableNotesHostPorts(presentation, InMemoryNotesRecoveryStore()),
                scope = scope,
                generation = { 0L },
                fenced = { false },
            )
            val active = derivedStateOf { controller.activeSession }

            controller.start()
            // Cold restore has assigned the saved active id but the library
            // call is still in flight and no session exists yet.
            assertNull(active.value)

            native.releaseLibrary()

            assertNotNull(controller.activeSession)
            assertTrue(controller.activeDocumentID == documentID)
            assertNotNull("session insertion must invalidate activeSession", active.value)
        } finally {
            scope.cancel()
        }
    }

    private fun summaryOf(document: NoteDocument) = GatedLibraryService.summaryOf(document)
}
