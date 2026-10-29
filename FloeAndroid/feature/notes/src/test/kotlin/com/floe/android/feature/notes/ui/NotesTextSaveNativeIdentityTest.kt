// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesAtomicBatchService
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesFlushResult
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import java.lang.reflect.Proxy
import java.util.Locale
import java.util.UUID
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real text-dialog boundary for the native UUID wire form.
 *
 * Android mints element ids with `UUID.randomUUID().toString()` (lowercase)
 * while the Swift `NoteDocument` response encodes every UUID through
 * Foundation's `UUID.uuidString` (uppercase). The toolbar-created text element
 * is still referenced by the Android-side id when the sheet's Save callback
 * runs, so `commitElementText` must resolve the UUID value instead of
 * comparing the stale strings. The fake service below deliberately canonicalises
 * every returned identity exactly like the native `JSONEncoder`, and records the
 * exact `NotesApplyRequest` the host would put on the real `floe.notes/4` wire.
 */
class NotesTextSaveNativeIdentityTest {
    private val documentID = UUID.fromString("11111111-2222-4333-8444-555555555555")
        .toString().uppercase(Locale.ROOT)
    private val pageID = UUID.fromString("66666666-7777-4888-8999-aaaaaaaaaaaa")
        .toString().uppercase(Locale.ROOT)

    private fun initialDocument() = NoteDocument(
        id = documentID,
        kind = NoteDocumentKind.NOTEBOOK,
        title = "G06TabletNote",
        revision = 1,
        pages = listOf(NotePage(id = pageID)),
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private class FakeNativeService(initial: NoteDocument) {
        var current: NoteDocument = initial
            private set
        val requests = mutableListOf<NotesApplyRequest>()

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
                "document" -> resume(continuation, Result.success(current))
                "apply", "applyAtomically" -> {
                    val request = args.first() as NotesApplyRequest
                    requests += request
                    resume(continuation, runCatching { apply(request) })
                }
                "history" -> resume(continuation, Result.success(NoteHistoryState(false, false)))
                "markOpened" -> resume(continuation, Result.success(Unit))
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService

        private fun apply(request: NotesApplyRequest): NoteDocument {
            check(request.documentID == current.id) { "native document identity" }
            check(request.expectedRevision == current.revision) { "native expected revision" }
            var next = current
            request.edits.forEach { edit -> next = applyEdit(next, edit) }
            next = next.copy(revision = next.revision + 1, updatedAt = next.updatedAt + 1)
            current = withNativeIdentity(next)
            return current
        }

        private fun applyEdit(document: NoteDocument, edit: NotesEdit): NoteDocument = when (edit) {
            is NotesEdit.UpsertElement -> {
                val pageIndex = document.pages.indexOfFirst { sameUUID(it.id, edit.pageID) }
                check(pageIndex >= 0) { "native page identity" }
                val page = document.pages[pageIndex]
                val elementIndex = page.elements.indexOfFirst { sameUUID(it.id, edit.element.id) }
                val elements = page.elements.toMutableList()
                if (elementIndex >= 0) elements[elementIndex] = edit.element else elements += edit.element
                document.copy(
                    pages = document.pages.toMutableList().also { it[pageIndex] = page.copy(elements = elements) },
                )
            }
            else -> throw UnsupportedOperationException("Unexpected edit: $edit")
        }

        /** Exactly Foundation's `UUID.uuidString` form used by the native JSON. */
        private fun withNativeIdentity(document: NoteDocument): NoteDocument = document.copy(
            id = nativeIdentity(document.id),
            pages = document.pages.map { page ->
                page.copy(
                    id = nativeIdentity(page.id),
                    elements = page.elements.map { it.copy(id = nativeIdentity(it.id)) },
                )
            },
        )

        private fun nativeIdentity(value: String): String =
            runCatching { UUID.fromString(value).toString().uppercase(Locale.ROOT) }.getOrDefault(value)
    }

    private fun session(
        service: NotesService,
        scope: CoroutineScope,
        fenced: () -> Boolean = { false },
    ): NotesDocumentSession = NotesDocumentSession(
        documentID = documentID,
        service = service,
        ports = unavailableNotesHostPorts(InMemoryNotesPresentationStore(), InMemoryNotesRecoveryStore()),
        resources = NotesResourceAccess(service),
        scope = scope,
        generation = { 0L },
        fenced = fenced,
        onLibraryInvalidated = {},
    )

    @Test
    fun toolbarTextSaveSurvivesTheNativeUppercaseUuidResponse() = runBlocking {
        val native = FakeNativeService(initialDocument())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val session = session(native.service, scope)
            assertTrue(session.load())

            val inserted = session.insertTextElement()!!
            // The local element id is the real lowercase JVM UUID form.
            assertEquals(inserted.id, inserted.id.lowercase(Locale.ROOT))
            assertNotEquals(inserted.id, inserted.id.uppercase(Locale.ROOT))

            // The real host service sends this queued upsert; the native store
            // returns the document with the UUID re-encoded in uppercase.
            assertEquals(NotesFlushResult.Saved, session.flush())
            val stored = session.document!!.pages.single().elements.single()
            assertEquals(inserted.id.uppercase(Locale.ROOT), stored.id)
            assertEquals("", stored.text)

            // This is exactly the sheet's Save callback: it still holds the
            // lower-case element captured before the native response.
            val plan = session.commitElementText(inserted, "G06_persistent_note_body_20261030", false)
            assertNotNull("text save must resolve the stored native identity", plan)
            assertEquals(NotesFlushResult.Saved, session.flush())

            val saved = native.current.pages.single().elements.single()
            assertEquals(1, native.current.pages.single().elements.size)
            assertEquals("G06_persistent_note_body_20261030", saved.text)
            assertEquals(inserted.id.uppercase(Locale.ROOT), saved.id)
            assertEquals(3, native.current.revision)
            assertEquals(2, native.requests.size)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun textSaveQueuedBeforeTheInsertResponseCoalescesIntoTheSameEdit() = runBlocking {
        val native = FakeNativeService(initialDocument())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val session = session(native.service, scope)
            assertTrue(session.load())

            // The picker is opened immediately: no autosave has adopted the
            // inserted element yet, so only the pending upsert carries it.
            val inserted = session.insertTextElement()!!
            val plan = session.commitElementText(inserted, "G06_persistent_note_body_20261030", false)
            assertNotNull(plan)
            assertEquals(NotesFlushResult.Saved, session.flush())

            assertEquals(1, native.requests.size)
            val edit = native.requests.single().edits.single()
            assertTrue(edit is NotesEdit.UpsertElement)
            assertEquals("G06_persistent_note_body_20261030", (edit as NotesEdit.UpsertElement).element.text)
            val saved = native.current.pages.single().elements.single()
            assertEquals(1, native.current.pages.single().elements.size)
            assertEquals("G06_persistent_note_body_20261030", saved.text)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun refusedQueueKeepsTheTextDraftInsteadOfReportingSuccess() = runBlocking {
        val native = FakeNativeService(initialDocument())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        var fencedNow = false
        try {
            val session = session(native.service, scope, fenced = { fencedNow })
            assertTrue(session.load())
            val inserted = session.insertTextElement()!!
            assertEquals(NotesFlushResult.Saved, session.flush())

            // A root/read-only refusal must not be presented as a saved edit.
            fencedNow = true
            val plan = session.commitElementText(inserted, "draft must stay", false)
            assertNull(plan)
            assertEquals("invalidOperation", session.saveFailure?.code)
            assertEquals(1, native.requests.size)
        } finally {
            scope.cancel()
        }
    }
}

private fun sameUUID(left: String, right: String): Boolean {
    if (left == right) return true
    val leftValue = runCatching { UUID.fromString(left) }.getOrNull() ?: return false
    val rightValue = runCatching { UUID.fromString(right) }.getOrNull() ?: return false
    return leftValue == rightValue
}
