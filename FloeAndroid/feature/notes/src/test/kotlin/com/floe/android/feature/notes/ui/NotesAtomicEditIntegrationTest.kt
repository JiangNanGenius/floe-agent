// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesAtomicBatchService
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.NotesEditReceipt
import com.floe.android.feature.notes.ui.presentation.NotesRequestBudget
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesFlushResult
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Editor boundary for the staged whole-plan edit batch.
 *
 * A service with the real staging capability must receive ONE
 * `applyAtomically` request for a large multi-element plan (never a sequence
 * of per-chunk `apply` calls), and a failure must retain the entire intent
 * under the same content-derived receipt. The native one-revision/one-undo
 * transaction itself is covered by NotesAtomicEditTests against the real
 * GRDB store.
 */
class NotesAtomicEditIntegrationTest {
    private fun document(revision: Int = 3, title: String = "Large note") = NoteDocument(
        id = "doc-atomic",
        kind = NoteDocumentKind.NOTEBOOK,
        title = title,
        revision = revision,
        pages = listOf(NotePage(id = "page-1")),
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    /** Dynamic proxy because NotesService has many suspend methods; only the
     *  ones this session boundary actually calls are implemented. Implementing
     *  NotesAtomicBatchService is the capability the session must detect. */
    private class FakeAtomicService(
        @Volatile var documentProvider: () -> NoteDocument,
        @Volatile var failWith: Throwable? = null,
    ) {
        val atomicRequests = mutableListOf<NotesApplyRequest>()
        var applyCalls = 0

        @Suppress("UNCHECKED_CAST")
        private fun resume(continuation: Continuation<*>, result: Result<Any?>) {
            (continuation as Continuation<Any?>).resumeWith(result)
        }

        val service: NotesService = Proxy.newProxyInstance(
            NotesService::class.java.classLoader,
            arrayOf(NotesService::class.java, NotesAtomicBatchService::class.java),
        ) { _, method, args ->
            val continuation = args?.lastOrNull() as? Continuation<*>
                ?: throw UnsupportedOperationException("not suspend: ${method.name}")
            when (method.name) {
                "document" -> resume(continuation, runCatching { documentProvider() })
                "apply" -> {
                    applyCalls += 1
                    resume(continuation, runCatching { documentProvider().copy(revision = 4) })
                }
                "applyAtomically" -> {
                    val request = args.first() as NotesApplyRequest
                    atomicRequests += request
                    val failure = failWith
                    if (failure != null) {
                        resume(continuation, Result.failure(failure))
                    } else {
                        val current = documentProvider()
                        resume(continuation, Result.success(current.copy(revision = current.revision + 1)))
                    }
                }
                "history" -> resume(continuation, Result.success(NoteHistoryState(false, false)))
                "markOpened" -> resume(continuation, Result.success(Unit))
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService
    }

    private fun session(service: NotesService, recovery: InMemoryNotesRecoveryStore): NotesDocumentSession =
        NotesDocumentSession(
            documentID = "doc-atomic",
            service = service,
            ports = unavailableNotesHostPorts(InMemoryNotesPresentationStore(), recovery),
            resources = NotesResourceAccess(service),
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            generation = { 0L },
            fenced = { false },
            onLibraryInvalidated = {},
        )

    /** Two clearly over-budget edits: greedy splitting would produce two calls. */
    private fun largePlan(): List<NotesEdit> {
        val tail = "x".repeat(30_000)
        return listOf(
            NotesEdit.TextSource("source-a", "Aa$tail"),
            NotesEdit.TextSource("source-b", "Bb$tail"),
        )
    }

    @Test
    fun `large multi-element plan is sent as one atomic request`() = runBlocking {
        val fake = FakeAtomicService(documentProvider = { document() })
        val recovery = InMemoryNotesRecoveryStore()
        val session = session(fake.service, recovery)
        try {
            assertTrue(session.load())
            val edits = largePlan()
            assertTrue(
                "fixture must exceed the old split threshold",
                NotesRequestBudget.exceeds(edits, NotesRequestBudget.MAX_SAFE_BATCH_BYTES),
            )
            assertTrue(session.requestEdits(edits, "Large edit"))

            val result = session.flush()
            assertTrue(result is NotesFlushResult.Saved)
            assertEquals("one whole-plan call", 1, fake.atomicRequests.size)
            assertEquals("no per-chunk apply", 0, fake.applyCalls)
            val request = fake.atomicRequests.single()
            assertEquals(2, request.edits.size)
            assertEquals(edits, request.edits)
            assertNotNull(request.requestID)
            assertTrue(
                "receipt binds the exact whole plan",
                request.requestID!!.endsWith(":" + NotesEditReceipt.digest(edits)),
            )
            assertEquals(0, session.pendingEditCount)
            assertTrue(recovery.pending().isEmpty())
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `failed atomic commit keeps the entire intent and the same receipt`() = runBlocking {
        val fake = FakeAtomicService(documentProvider = { document() })
        val recovery = InMemoryNotesRecoveryStore()
        val session = session(fake.service, recovery)
        try {
            assertTrue(session.load())
            val edits = largePlan()
            assertTrue(session.requestEdits(edits, "Large edit"))
            fake.failWith = NotesException("storageUnavailable", retryable = true)

            val failed = session.flush()
            assertTrue(failed is NotesFlushResult.Failed)
            assertEquals("storageUnavailable", (failed as NotesFlushResult.Failed).failure.code)
            assertEquals(2, session.pendingEditCount)
            val retained = recovery.pending().single()
            assertEquals("the whole intent, never a committed prefix", edits, retained.edits)
            assertEquals(NotesEditReceipt.digest(edits), NotesEditReceipt.digest(retained.edits))
            assertNotNull(retained.requestID)
            assertFalse(retained.requestID!!.contains(":"))

            // Retry the same intent: the exact content-derived receipt is
            // reused so an uncertain dispatch can be reconciled by the native
            // store rather than applied a second time.
            val firstReceipt = fake.atomicRequests.last().requestID
            fake.failWith = null
            val saved = session.flush()
            assertTrue(saved is NotesFlushResult.Saved)
            assertEquals(firstReceipt, fake.atomicRequests.last().requestID)
            assertEquals(2, fake.atomicRequests.size)
            assertEquals(0, session.pendingEditCount)
            assertTrue(recovery.pending().isEmpty())
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `oversize typed failure retains the whole plan without a parts notice`() = runBlocking {
        val fake = FakeAtomicService(documentProvider = { document() })
        val recovery = InMemoryNotesRecoveryStore()
        val session = session(fake.service, recovery)
        try {
            assertTrue(session.load())
            val edits = largePlan()
            assertTrue(session.requestEdits(edits, "Large edit"))
            fake.failWith = NotesException("requestTooLarge", "editBatch")

            val failed = session.flush()
            assertTrue(failed is NotesFlushResult.Failed)
            assertEquals("requestTooLarge", (failed as NotesFlushResult.Failed).failure.code)
            assertEquals(2, session.pendingEditCount)
            assertEquals(edits, recovery.pending().single().edits)
            assertFalse(
                "a real atomic service never advertises 'saved in parts'",
                session.largeEditPending,
            )
        } finally {
            session.dispose()
        }
    }

    @Test
    fun `small plan also commits through one whole-plan call`() = runBlocking {
        val fake = FakeAtomicService(documentProvider = { document() })
        val recovery = InMemoryNotesRecoveryStore()
        val session = session(fake.service, recovery)
        try {
            assertTrue(session.load())
            assertTrue(session.requestEdits(listOf(NotesEdit.Rename("One call")), "Rename"))
            assertTrue(session.flush() is NotesFlushResult.Saved)
            assertEquals(1, fake.atomicRequests.size)
            assertEquals(1, fake.atomicRequests.single().edits.size)
            assertEquals(0, fake.applyCalls)
        } finally {
            session.dispose()
        }
    }
}
