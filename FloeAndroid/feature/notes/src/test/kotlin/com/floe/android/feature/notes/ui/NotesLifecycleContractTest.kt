// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesFlushResult
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import com.floe.android.feature.notes.ui.state.NotesStopOutcome
import com.floe.android.feature.notes.ui.state.NotesWorkspaceSession
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lifecycle/recovery contract at the real document-session boundary.
 *
 * These are deliberate regression entries for behaviour Main fixed while the
 * App ports were integrated: a failed durable recovery put must not claim
 * "kept", a deleted/kind-mismatched source must retain the only draft, and a
 * fresh session must restore a durable draft instead of deleting it.
 */
class NotesLifecycleContractTest {
    private val draft = NotesPendingRecovery(
        documentID = "doc-1",
        documentKind = "notebook",
        documentTitle = "My draft",
        baseRevision = 3,
        requestTitle = "Rename",
        edits = listOf(NotesEdit.Rename("Restored")),
        reasonCode = "staleGeneration",
        createdAt = 1L,
        requestID = "receipt-1",
        inkDrafts = emptyMap(),
    )

    private fun document(deletedAt: Double? = null, kind: NoteDocumentKind = NoteDocumentKind.NOTEBOOK) =
        NoteDocument(
            id = "doc-1",
            kind = kind,
            title = "Document",
            revision = 3,
            pages = listOf(NotePage(id = "page-1")),
            createdAt = 1.0,
            updatedAt = 2.0,
            deletedAt = deletedAt,
        )

    /** Kotlin-continuation fake so suspend failures are not wrapped by Proxy. */
    private class FakeService(
        @Volatile var documentProvider: () -> NoteDocument,
        @Volatile var applyProvider: (NotesApplyRequest) -> NoteDocument = {
            throw NotesException("storageUnavailable", "apply")
        },
    ) {
        var applyCalls = 0

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
                "document" -> resume(continuation, runCatching { documentProvider() })
                "apply" -> {
                    applyCalls++
                    val request = args.first() as NotesApplyRequest
                    resume(continuation, runCatching { applyProvider(request) })
                }
                "history" -> resume(continuation, Result.success(NoteHistoryState(false, false)))
                "markOpened" -> resume(continuation, Result.success(Unit))
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService
    }

    private class FlakyRecoveryStore(
        var failuresRemaining: Int = 0,
    ) : NotesRecoveryStore {
        private val delegate = InMemoryNotesRecoveryStore()

        override fun put(recovery: NotesPendingRecovery) {
            if (failuresRemaining > 0) {
                failuresRemaining -= 1
                throw IllegalStateException("recovery storage unavailable")
            }
            delegate.put(recovery)
        }

        override fun remove(documentID: String) = delegate.remove(documentID)

        override fun pending(): List<NotesPendingRecovery> = delegate.pending()

        override fun clear() = delegate.clear()
    }

    private fun session(
        service: NotesService,
        recovery: NotesRecoveryStore,
    ): NotesDocumentSession = NotesDocumentSession(
        documentID = "doc-1",
        service = service,
        ports = unavailableNotesHostPorts(InMemoryNotesPresentationStore(), recovery),
        resources = NotesResourceAccess(service),
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        generation = { 0L },
        fenced = { false },
        onLibraryInvalidated = {},
    )


    @Test
    fun `abortRootStop re-arms the same session after a stop decision`() = runBlocking {
        val service = FakeService(documentProvider = { document() })
        val ports = unavailableNotesHostPorts(
            InMemoryNotesPresentationStore(),
            InMemoryNotesRecoveryStore(),
        )
        val session = NotesWorkspaceSession(
            service.service,
            ports,
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        )
        try {
            val first = session.prepareForRootStop(250)
            assertTrue(first.canRetire)
            val resumed = session.abortRootStop()
            assertTrue(resumed.failures.isEmpty())
            val second = session.prepareForRootStop(250)
            assertTrue(second.canRetire)
        } finally {
            session.close()
        }
    }

    @Test
    fun `colliding chunk hashCodes still apply both chunks without a native replay`() = runBlocking {
        // "Aa"/"BB" collide in both the id and text fields, so two one-edit
        // chunks have equal List.hashCode(); the old suffix would reuse one
        // native receipt and the second edit would be dropped as a replay.
        val tail = "x".repeat(30_000)
        val first = NotesEdit.TextSource("Aa", "Aa$tail")
        val second = NotesEdit.TextSource("BB", "BB$tail")
        assertEquals(listOf(first).hashCode(), listOf(second).hashCode())

        val seenReceipts = mutableSetOf<String>()
        val applied = mutableListOf<NotesEdit>()
        val service = FakeService(
            documentProvider = { document() },
            applyProvider = { request ->
                val requestID = request.requestID ?: ""
                if (seenReceipts.add(requestID)) {
                    applied += request.edits
                }
                document().copy(revision = 4)
            },
        )
        val session = session(service.service, FlakyRecoveryStore())
        try {
            assertTrue(session.load())
            assertTrue(session.requestEdits(listOf(first, second), "Edit"))
            val result = session.flush()
            assertTrue(result is NotesFlushResult.Saved)
            assertEquals(2, seenReceipts.size)
            assertEquals(setOf("Aa", "BB"), applied.map { (it as NotesEdit.TextSource).id }.toSet())
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `throwing recovery put leaves edits queued and does not claim kept`() = runBlocking {
        val service = FakeService(documentProvider = { document() })
        val store = FlakyRecoveryStore(failuresRemaining = 1)
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            assertTrue(session.requestEdits(listOf(NotesEdit.Rename("Renamed")), "Rename"))
            val error = runCatching { session.prepareForStop(500) }.exceptionOrNull()
            assertNotNull(error)
            assertEquals(1, session.pendingEditCount)
            assertFalse(session.recoveryKept)
            assertTrue(store.pending().isEmpty())
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `retry after storage failure keeps the same receipt and pending edits`() = runBlocking {
        val service = FakeService(documentProvider = { document() })
        val store = FlakyRecoveryStore(failuresRemaining = 1)
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            assertTrue(session.requestEdits(listOf(NotesEdit.Rename("Renamed")), "Rename"))
            assertNotNull(runCatching { session.prepareForStop(500) }.exceptionOrNull())

            val outcome = session.prepareForStop(500)
            assertTrue(outcome is NotesStopOutcome.Kept)
            val record = (outcome as NotesStopOutcome.Kept).recovery
            assertNotNull(record)
            assertEquals("storageUnavailable", record!!.reasonCode)
            assertEquals(1, record.edits.size)
            assertNotNull(record.requestID)
            assertTrue(session.recoveryKept)
            assertEquals(listOf("doc-1"), store.pending().map { it.documentID })
            assertEquals(record.requestID, store.pending().single().requestID)
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `deleted source retains the draft during restore`() = runBlocking {
        val store = FlakyRecoveryStore().also { it.put(draft) }
        val service = FakeService(documentProvider = { document(deletedAt = 3.0) })
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            val result = session.restoreRecovery(draft)
            assertTrue(result is NotesFlushResult.Failed)
            assertEquals("deleted", (result as NotesFlushResult.Failed).failure.detail)
            assertSame(draft, store.pending().single())
            assertTrue(session.recoveryKept)
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `kind mismatch retains the draft during restore`() = runBlocking {
        val store = FlakyRecoveryStore().also { it.put(draft) }
        val service = FakeService(
            documentProvider = { document(kind = NoteDocumentKind.MIND_MAP) },
        )
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            val result = session.restoreRecovery(draft)
            assertTrue(result is NotesFlushResult.Failed)
            assertEquals("kindMismatch", (result as NotesFlushResult.Failed).failure.detail)
            assertSame(draft, store.pending().single())
            assertTrue(session.recoveryKept)
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `deleted source persists pending edits on resumeAfterRoot`() = runBlocking {
        var deleted = false
        val service = FakeService(
            documentProvider = { document(deletedAt = if (deleted) 3.0 else null) },
        )
        val store = FlakyRecoveryStore()
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            assertTrue(session.requestEdits(listOf(NotesEdit.Rename("Pending")), "Rename"))
            deleted = true
            assertTrue(session.load())
            val result = session.resumeAfterRoot()
            assertTrue(result is NotesFlushResult.Failed)
            assertEquals("deleted", (result as NotesFlushResult.Failed).failure.detail)
            assertEquals("deleted", store.pending().single().reasonCode)
            assertEquals(1, session.pendingEditCount)
            assertTrue(session.recoveryKept)
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `stop with only a durable draft reports kept not flushed`() = runBlocking {
        val store = FlakyRecoveryStore().also { it.put(draft) }
        val service = FakeService(documentProvider = { document() })
        val session = session(service.service, store)
        try {
            assertTrue(session.load())
            val outcome = session.prepareForStop(500)
            assertTrue(outcome is NotesStopOutcome.Kept)
            assertEquals("receipt-1", (outcome as NotesStopOutcome.Kept).recovery?.requestID)
            assertTrue(session.recoveryKept)
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `fresh session restores a durable draft instead of deleting it`() = runBlocking {
        val store = FlakyRecoveryStore().also { it.put(draft) }
        val service = FakeService(
            documentProvider = { document() },
            applyProvider = { request ->
                document().copy(revision = 4, title = request.title)
            },
        )
        val session = session(service.service, store)
        try {
            // No live queue: the only content is the durable draft.
            val result = session.resumeAfterRoot()
            assertTrue(result is NotesFlushResult.Saved)
            assertEquals(1, service.applyCalls)
            assertTrue(store.pending().isEmpty())
            assertFalse(session.recoveryKept)
        } finally {
            session.dispose()
        }
    }
}
