// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.noteschattransfer

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioural tests for the explicit settled-reply -> Notes copy.
 *
 * The fake service is a dynamic proxy around [NotesService] that implements
 * the exact native semantics this controller depends on:
 *  * `document` / `createDocument` (idempotent explicit id),
 *  * `applyAtomically` with one revision/undo and a durable request receipt
 *    checked BEFORE the revision guard (the real `NotesStore.apply` order),
 *  * typed failures and a switch to make a commit land while the reply is
 *    reported as an uncertain failure.
 */
class NotesChatTransferControllerTest {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private class RecordingRecoveryStore(
        private val events: MutableList<String>? = null,
    ) : NotesRecoveryStore {
        private val values = LinkedHashMap<String, NotesPendingRecovery>()

        @Synchronized
        override fun put(recovery: NotesPendingRecovery) {
            events?.add("recovery.put")
            values[recovery.documentID] = recovery
        }

        @Synchronized
        override fun remove(documentID: String) {
            events?.add("recovery.remove")
            values.remove(documentID)
        }

        @Synchronized
        override fun pending(): List<NotesPendingRecovery> = values.values.toList()

        @Synchronized
        override fun clear() = values.clear()
    }

    private class FakeNotesService(
        val clock: () -> Long,
        val events: MutableList<String>? = null,
    ) : FakeNotesServiceBase() {
        val documents = ConcurrentHashMap<String, NoteDocument>()
        private val receipts = ConcurrentHashMap<String, NoteDocument>()
        val applyCalls = AtomicInteger(0)
        @Volatile var failApplyWith: NotesException? = null
        @Volatile var commitThenFailWith: Throwable? = null
        @Volatile var gate: CompletableDeferred<Unit>? = null
        /** "preCreate" | "create" | "apply" | null (see [gate]). */
        @Volatile var gateStage: String? = null
        @Volatile var enteredCreate = false
        @Volatile var lastAppliedRequest: NotesApplyRequest? = null

        override suspend fun document(documentID: String): NoteDocument {
            events?.add("document")
            return documents[documentID]
                ?: throw NotesException("notFound", "document", retryable = false)
        }

        override suspend fun createDocument(request: NotesCreateDocument): NoteDocument {
            events?.add("create")
            enteredCreate = true
            if (gateStage == "preCreate") gate?.await()
            request.documentID?.let { explicit -> documents[explicit]?.let { return it } }
            val id = request.documentID ?: "generated-" + documents.size
            val created = NoteDocument(
                id = id,
                kind = request.kind,
                title = request.title,
                revision = 1,
                pages = if (request.kind == NoteDocumentKind.NOTEBOOK) {
                    listOf(NotePage(id = java.util.UUID.randomUUID().toString()))
                } else {
                    emptyList()
                },
                createdAt = clock().toDouble(),
                updatedAt = clock().toDouble(),
            )
            documents[id] = created
            if (gateStage == "create") gate?.await()
            return created
        }

        override suspend fun applyAtomically(request: NotesApplyRequest): NoteDocument = apply(request)

        override suspend fun apply(request: NotesApplyRequest): NoteDocument {
            events?.add("apply")
            applyCalls.incrementAndGet()
            lastAppliedRequest = request
            // Native order: receipt BEFORE revision guard, so an uncertain
            // retry returns the committed document instead of re-applying.
            val receipt = request.requestID
            if (receipt != null) receipts[receipt]?.let { return it }
            val current = documents[request.documentID]
                ?: throw NotesException("notFound", "document", retryable = false)
            failApplyWith?.let { throw it }
            if (current.revision != request.expectedRevision) {
                throw NotesException("conflict", "revision", retryable = false)
            }
            if (gateStage == null || gateStage == "apply") gate?.let { running -> running.await() }
            val updated = applyEdits(current, request.edits)
            documents[request.documentID] = updated
            if (receipt != null) receipts[receipt] = updated
            commitThenFailWith?.let { failure ->
                commitThenFailWith = null
                throw failure
            }
            return updated
        }

        override suspend fun close() = Unit

        private fun applyEdits(document: NoteDocument, edits: List<NotesEdit>): NoteDocument {
            val pages = document.pages.toMutableList()
            edits.forEach { edit ->
                when (edit) {
                    is NotesEdit.InsertPage -> pages.add(edit.index.coerceIn(0, pages.size), edit.page)
                    is NotesEdit.UpsertElement -> {
                        val index = pages.indexOfFirst { it.id == edit.pageID }
                        if (index < 0) throw NotesException("notFound", "page", retryable = false)
                        val page = pages[index]
                        val elementIndex = page.elements.indexOfFirst { it.id == edit.element.id }
                        val elements = page.elements.toMutableList()
                        if (elementIndex >= 0) elements[elementIndex] = edit.element else elements.add(edit.element)
                        pages[index] = page.copy(elements = elements)
                    }
                    else -> throw UnsupportedOperationException("edit $edit")
                }
            }
            return document.copy(
                pages = pages,
                revision = document.revision + 1,
                updatedAt = clock().toDouble(),
            )
        }

        fun text(documentID: String): String {
            val document = documents.getValue(documentID)
            return document.pages.joinToString("\n") { page ->
                page.elements
                    .filter { it.kind == NoteElementKind.TEXT }
                    .joinToString("\n") { resolveElementText(document, it) }
            }
        }

        fun textElements(documentID: String): List<NoteElement> =
            documents.getValue(documentID).pages.flatMap { page ->
                page.elements.filter { it.kind == NoteElementKind.TEXT }
            }
    }

    private fun controller(
        notes: FakeNotesService,
        recovery: NotesRecoveryStore,
        epoch: Long = 7L,
        ids: () -> String = { "doc-" + java.util.UUID.randomUUID() },
    ) = NotesChatTransferController(
        scope = scope,
        targets = { NotesChatTransferTargets(notes, recovery) },
        currentRootEpoch = { epoch },
        clock = { System.currentTimeMillis() },
        documentIDSource = ids,
    )

    private fun owner(conversationID: String = "conversation-1", epoch: Long = 7L) =
        NotesChatTransferOwner(
            conversationID = conversationID,
            sessionEpoch = 3L,
            temporary = false,
            rootEpoch = epoch,
        )

    private fun awaitState(
        controller: NotesChatTransferController,
        timeoutMillis: Long = 10_000,
    ): NotesChatTransferState {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            val state = controller.latest.value
            if (state is NotesChatTransferState.Saved || state is NotesChatTransferState.Failed) {
                return state
            }
            Thread.sleep(10)
        }
        throw AssertionError("transfer did not settle: ${controller.latest.value}")
    }

    private fun longReply(): String = buildString {
        repeat(40) { index ->
            append("## Section ").append(index).append('\n')
            append("Paragraph with unicode: 你好，世界 \uD83D\uDE00 and code `x = ").append(index).append("`.\n")
            append("Second line for section ").append(index).append(" keeps the tail recognizable.\n\n")
        }
    }

    @Test
    fun temporarySessionIsNeverAdmitted() {
        val notes = FakeNotesService({ 0L })
        val controller = controller(notes, RecordingRecoveryStore())
        val admission = controller.admit(owner().copy(temporary = true), "reply")
        assertEquals(NotesChatTransferAdmission.REJECTED_TEMPORARY, admission)
        assertTrue(notes.documents.isEmpty())
        controller.close()
    }

    @Test
    fun rootEpochMismatchAndBlankTextAreRefused() {
        val notes = FakeNotesService({ 0L })
        val controller = controller(notes, RecordingRecoveryStore(), epoch = 9L)
        assertEquals(NotesChatTransferAdmission.REJECTED_ROOT, controller.admit(owner(epoch = 7L), "reply"))
        assertEquals(NotesChatTransferAdmission.REJECTED_ROOT, controller.admit(owner(epoch = 9L).copy(rootEpoch = 7L), "reply"))
        assertEquals(NotesChatTransferAdmission.REJECTED_EMPTY, controller.admit(owner(epoch = 9L), "  \n "))
        assertTrue(notes.documents.isEmpty())
        controller.close()
    }

    @Test
    fun oversizedReplyIsRefusedWithoutSavingAPrefix() {
        val notes = FakeNotesService({ 0L })
        val controller = NotesChatTransferController(
            scope = scope,
            targets = { NotesChatTransferTargets(notes, RecordingRecoveryStore()) },
            currentRootEpoch = { 7L },
            documentIDSource = { "doc-oversize" },
            maxTextBytes = 64,
        )
        val admission = controller.admit(owner(), "x".repeat(65))
        assertEquals(NotesChatTransferAdmission.REJECTED_TOO_LARGE, admission)
        assertTrue(notes.documents.isEmpty())
        controller.close()
    }

    @Test
    fun fullUnicodeReplyIsSavedAcrossPagesWithoutClipping() {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val controller = controller(notes, recovery, ids = { "document-full" })
        val text = longReply()
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), text))
        val state = awaitState(controller)
        assertTrue("unexpected state $state", state is NotesChatTransferState.Saved)
        state as NotesChatTransferState.Saved
        assertEquals("document-full", state.documentID)
        assertTrue("expected multiple pages", state.pageCount > 1)
        val elements = notes.textElements(state.documentID)
        assertTrue("expected multiple elements", elements.size > 1)
        assertTrue(elements.all { it.isMarkdown })
        // No character may be dropped: compare every non-whitespace character.
        val expected = text.filterNot { it.isWhitespace() }
        val actual = notes.text(state.documentID).filterNot { it.isWhitespace() }
        assertEquals(expected, actual)
        assertTrue("recovery must be cleared after success", recovery.pending().isEmpty())
        assertNull(controller.latest.value.let { it as? NotesChatTransferState.Failed })
        controller.close()
    }

    @Test
    fun repeatedAdmissionNeverCreatesASecondDocument() {
        val notes = FakeNotesService({ 0L })
        val controller = controller(notes, RecordingRecoveryStore(), ids = { "document-once" })
        val text = "Same reply body"
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), text))
        val second = controller.admit(owner(), text)
        assertTrue(
            second == NotesChatTransferAdmission.ALREADY_PENDING ||
                second == NotesChatTransferAdmission.ALREADY_SAVED,
        )
        val state = awaitState(controller)
        assertTrue(state is NotesChatTransferState.Saved)
        val third = controller.admit(owner(), text)
        assertEquals(NotesChatTransferAdmission.ALREADY_SAVED, third)
        assertEquals(1, notes.documents.size)
        assertEquals(1, notes.applyCalls.get())
        controller.close()
    }

    @Test
    fun failedCommitKeepsTheWholeDurableDraftAndRetrySavesOnce() {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val controller = controller(notes, recovery, ids = { "document-retry" })
        notes.failApplyWith = NotesException("storageUnavailable", "disk", retryable = true)
        val text = longReply()
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), text))
        val failed = awaitState(controller)
        assertTrue("unexpected state $failed", failed is NotesChatTransferState.Failed)
        failed as NotesChatTransferState.Failed
        assertTrue(failed.retryable)
        assertTrue(failed.keptRecovery)
        val record = recovery.pending().single()
        assertEquals("document-retry", record.documentID)
        assertNotNull(record.requestID)
        assertTrue(record.edits.isNotEmpty())

        notes.failApplyWith = null
        assertTrue(controller.retry(failed.transferID))
        val saved = awaitState(controller)
        assertTrue("unexpected state $saved", saved is NotesChatTransferState.Saved)
        assertEquals("document-retry", (saved as NotesChatTransferState.Saved).documentID)
        assertTrue(recovery.pending().isEmpty())
        // Exactly the full body, once.
        assertEquals(
            text.filterNot { it.isWhitespace() },
            notes.text("document-retry").filterNot { it.isWhitespace() },
        )
        assertEquals(2, notes.applyCalls.get())
        controller.close()
    }

    @Test
    fun uncertainCommitRetryUsesTheSameReceiptAndNeverDuplicates() {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val controller = controller(notes, recovery, ids = { "document-uncertain" })
        notes.commitThenFailWith = IllegalStateException("transport lost after commit")
        val text = "Answer paragraph one.\n\nAnswer paragraph two."
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), text))
        val failed = awaitState(controller)
        assertTrue(failed is NotesChatTransferState.Failed)
        val committed = notes.documents.getValue("document-uncertain")
        assertEquals(2, committed.revision)

        assertTrue(controller.retry((failed as NotesChatTransferState.Failed).transferID))
        val saved = awaitState(controller)
        assertTrue(saved is NotesChatTransferState.Saved)
        val after = notes.documents.getValue("document-uncertain")
        assertEquals("receipt must reconcile, not re-apply", committed.revision, after.revision)
        assertEquals(2, notes.applyCalls.get())
        assertEquals(
            text.filterNot { it.isWhitespace() },
            notes.text("document-uncertain").filterNot { it.isWhitespace() },
        )
        controller.close()
    }

    @Test
    fun rootStopRetiresWithADurableRecordAndResumeCompletesItOnce() = runBlocking {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val gate = CompletableDeferred<Unit>()
        notes.gate = gate
        val controller = controller(notes, recovery, ids = { "document-stop" })
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), "Root stop body"))
        // Wait until the apply is really dispatched.
        val deadline = System.currentTimeMillis() + 10_000
        while (notes.lastAppliedRequest == null && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        val retire = controller.prepareForRootStop(deadlineMillis = 500)
        assertTrue("a dispatched commit must be covered by durable recovery", retire.canRetire)
        assertEquals(listOf("document-stop"), retire.keptDocumentIDs)
        val record = recovery.pending().single()
        assertEquals("document-stop", record.documentID)
        // Release the gated commit; it lands under the old root. The new root
        // re-drives the SAME record and the native receipt reconciles it, so
        // the body exists exactly once.
        gate.complete(Unit)
        val reached = System.currentTimeMillis() + 10_000
        while (notes.documents.getValue("document-stop").revision < 2 &&
            System.currentTimeMillis() < reached
        ) {
            Thread.sleep(10)
        }
        val resumed = controller.resume()
        assertEquals(listOf("document-stop"), resumed.resumed)
        assertTrue(recovery.pending().isEmpty())
        val document = notes.documents.getValue("document-stop")
        assertEquals(2, document.revision)
        assertEquals(
            "Root stop body".filterNot { it.isWhitespace() },
            notes.text(document.id).filterNot { it.isWhitespace() },
        )
        controller.close()
    }

    @Test
    fun abortKeepsTheDurableDraftAndRetryDeliversItOnce() = runBlocking {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val gate = CompletableDeferred<Unit>()
        notes.gate = gate
        val controller = controller(notes, recovery, ids = { "document-abort" })
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), "Abort body"))
        val dispatched = System.currentTimeMillis() + 10_000
        while (notes.lastAppliedRequest == null && System.currentTimeMillis() < dispatched) {
            Thread.sleep(10)
        }
        val transferID = (controller.latest.value as? NotesChatTransferState.Saving)?.transferID
            ?: throw AssertionError("expected saving")
        assertTrue(controller.abort(transferID))
        val failed = awaitState(controller)
        assertTrue("unexpected $failed", failed is NotesChatTransferState.Failed)
        failed as NotesChatTransferState.Failed
        assertTrue(failed.keptRecovery)
        val record = recovery.pending().single()
        assertEquals("document-abort", record.documentID)

        notes.gate = null
        gate.complete(Unit)
        assertTrue(controller.retry(failed.transferID))
        val saved = awaitState(controller)
        assertTrue("unexpected $saved", saved is NotesChatTransferState.Saved)
        assertTrue(recovery.pending().isEmpty())
        assertEquals(
            "Abort body".filterNot { it.isWhitespace() },
            notes.text("document-abort").filterNot { it.isWhitespace() },
        )
        controller.close()
    }

    @Test
    fun fullBodyIsDurableBeforeTheFirstNativeCommand() {
        val events = mutableListOf<String>()
        val notes = FakeNotesService({ 0L }, events)
        val recovery = RecordingRecoveryStore(events)
        val controller = controller(notes, recovery, ids = { "document-order" })
        val text = longReply()
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), text))
        val state = awaitState(controller)
        assertTrue("unexpected $state", state is NotesChatTransferState.Saved)
        val put = events.indexOf("recovery.put")
        val firstNative = events.indexOfFirst {
            it == "document" || it == "create" || it == "apply"
        }
        assertTrue("expected a durable put, events=$events", put >= 0)
        assertTrue("first native call must come after the durable body, events=$events", firstNative > put)
        assertEquals(1, events.count { it == "recovery.put" })
        controller.close()
    }

    @Test
    fun cancelAfterCreateBeforeApplyKeepsTheBodyAndResumeCompletesTheSameNote() = runBlocking {
        val events = mutableListOf<String>()
        val notes = FakeNotesService({ 0L }, events)
        val recovery = RecordingRecoveryStore(events)
        val gate = CompletableDeferred<Unit>()
        notes.gate = gate
        notes.gateStage = "create"
        val controller = controller(notes, recovery, ids = { "document-created-only" })
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), "Created but unsaved body"))
        val deadline = System.currentTimeMillis() + 10_000
        while (events.count { it == "create" } == 0 && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertEquals(1, events.count { it == "create" })
        // The native create has happened; the body must already be durable.
        assertTrue(events.indexOf("recovery.put") < events.indexOf("create"))
        val retire = controller.prepareForRootStop(epoch = 7L, deadlineMillis = 300)
        assertTrue(retire.canRetire)
        assertEquals(listOf("document-created-only"), retire.keptDocumentIDs)
        gate.complete(Unit)
        Thread.sleep(150)
        assertEquals(0, events.count { it == "apply" })

        // A later root resumes the SAME record: the already-created note is
        // completed in place, never re-created and never duplicated.
        val resumer = controller(notes, recovery)
        val resumed = resumer.resume()
        assertEquals(listOf("document-created-only"), resumed.resumed)
        assertEquals(1, notes.documents.size)
        assertEquals(
            "Created but unsaved body".filterNot { it.isWhitespace() },
            notes.text("document-created-only").filterNot { it.isWhitespace() },
        )
        assertTrue(recovery.pending().isEmpty())
        resumer.close()
        controller.close()
    }

    @Test
    fun cancelBeforeCreateKeepsTheBodyAndResumeCreatesExactlyOneNote() = runBlocking {
        val events = mutableListOf<String>()
        val notes = FakeNotesService({ 0L }, events)
        val recovery = RecordingRecoveryStore(events)
        val gate = CompletableDeferred<Unit>()
        notes.gate = gate
        notes.gateStage = "preCreate"
        val controller = controller(notes, recovery, ids = { "document-not-created" })
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), "Body before create"))
        val deadline = System.currentTimeMillis() + 10_000
        while (!notes.enteredCreate && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertTrue(notes.enteredCreate)
        assertTrue(notes.documents.isEmpty())
        val retire = controller.prepareForRootStop(epoch = 7L, deadlineMillis = 300)
        assertTrue(retire.canRetire)
        gate.complete(Unit)
        Thread.sleep(150)
        assertEquals(0, notes.documents.size)

        val resumer = controller(notes, recovery)
        assertEquals(listOf("document-not-created"), resumer.resume().resumed)
        assertEquals(1, notes.documents.size)
        assertEquals(
            "Body before create".filterNot { it.isWhitespace() },
            notes.text("document-not-created").filterNot { it.isWhitespace() },
        )
        assertTrue(recovery.pending().isEmpty())
        resumer.close()
        controller.close()
    }

    @Test
    fun abortRootStopRefusesAStaleEpochAndNeverResolvesThePlatformOrReplays() = runBlocking {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        var providerCalls = 0
        var documentSequence = 0
        val gate = CompletableDeferred<Unit>()
        notes.gate = gate
        val controller = NotesChatTransferController(
            scope = scope,
            targets = {
                providerCalls += 1
                NotesChatTransferTargets(notes, recovery)
            },
            currentRootEpoch = { 7L },
            documentIDSource = { "document-abort-root-" + (++documentSequence) },
        )
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(epoch = 7L), "Fenced body"))
        val dispatched = System.currentTimeMillis() + 10_000
        while (notes.lastAppliedRequest == null && System.currentTimeMillis() < dispatched) {
            Thread.sleep(10)
        }
        val retire = controller.prepareForRootStop(epoch = 7L, deadlineMillis = 300)
        assertTrue(retire.canRetire)
        assertEquals(listOf("document-abort-root-1"), retire.keptDocumentIDs)
        assertEquals(1, recovery.pending().size)
        assertEquals(NotesChatTransferAdmission.REJECTED_ROOT, controller.admit(owner(epoch = 7L), "Blocked"))
        val callsBeforeAbort = providerCalls
        assertFalse("a stale epoch must not re-arm", controller.abortRootStop(6L))
        assertEquals("abortRootStop must not resolve the platform", callsBeforeAbort, providerCalls)
        assertEquals(NotesChatTransferAdmission.REJECTED_ROOT, controller.admit(owner(epoch = 7L), "Still blocked"))

        // Same live epoch: admission re-opens, and NOTHING is replayed.
        notes.gate = null
        gate.complete(Unit)
        val revisionBefore = notes.documents.getValue("document-abort-root-1").revision
        assertTrue(controller.abortRootStop(7L))
        assertEquals("abortRootStop must not replay", 1, recovery.pending().size)
        assertEquals(
            "abortRootStop must not touch any note",
            revisionBefore,
            notes.documents.getValue("document-abort-root-1").revision,
        )
        assertEquals(1, notes.documents.size)

        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(epoch = 7L), "After abort"))
        val saved = awaitState(controller)
        assertTrue("unexpected $saved", saved is NotesChatTransferState.Saved)
        assertEquals("document-abort-root-2", (saved as NotesChatTransferState.Saved).documentID)
        controller.close()
        assertFalse("a closed controller never re-arms", controller.abortRootStop(7L))
    }

    @Test
    fun durableRecordFromAPreviousProcessIsResumed() = runBlocking {
        // Simulate process death: the record exists, no live controller state.
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val first = controller(notes, recovery, ids = { "document-crash" })
        notes.failApplyWith = NotesException("storageUnavailable", "disk", retryable = true)
        assertEquals(NotesChatTransferAdmission.STARTED, first.admit(owner(), "Crash body"))
        assertTrue(awaitState(first) is NotesChatTransferState.Failed)
        first.close()
        notes.failApplyWith = null

        val second = controller(notes, recovery)
        val resumed = second.resume()
        assertEquals(listOf("document-crash"), resumed.resumed)
        assertTrue(recovery.pending().isEmpty())
        assertEquals(
            "Crash body".filterNot { it.isWhitespace() },
            notes.text("document-crash").filterNot { it.isWhitespace() },
        )
        second.close()
    }

    @Test
    fun deleteOfTheCreatedNoteIsReportedAndKeepsTheDraft() {
        val notes = FakeNotesService({ 0L })
        val recovery = RecordingRecoveryStore()
        val controller = controller(notes, recovery, ids = { "document-deleted" })
        notes.failApplyWith = NotesException("notFound", "document", retryable = false)
        assertEquals(NotesChatTransferAdmission.STARTED, controller.admit(owner(), "Body"))
        val failed = awaitState(controller) as NotesChatTransferState.Failed
        assertFalse(failed.retryable)
        assertTrue(failed.keptRecovery)
        assertTrue(recovery.pending().isNotEmpty())
        assertTrue(controller.dismiss(failed.transferID))
        assertTrue(
            "dismiss must never delete the durable draft",
            recovery.pending().isNotEmpty(),
        )
        controller.close()
    }
}
