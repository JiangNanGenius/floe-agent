// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafGrantFlagBits
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Native editing over the REAL gateway service and the in-memory provider:
 *  - import produces a verified working copy + an honest launch request;
 *  - an unchanged working copy never touches the provider;
 *  - changed bytes are written back ONLY through the verified ladder and
 *    reported after the provider read-back matches (same source);
 *  - a stale source is a conflict: nothing is overwritten and BOTH versions
 *    (provider-current recovery + edited working copy) stay recoverable;
 *  - no handler / revoked grant / read-only document stay typed and truthful;
 *  - a provider that rejects truncate-write lands the bytes in an explicit
 *    sibling with the original untouched;
 *  - sessions restore after a process restart and reconcile honestly.
 */
class SpaceFilesEditControllerTest {

    private lateinit var cache: File
    private lateinit var editsRoot: File
    private lateinit var store: SpaceFilesInMemoryRootStore
    private lateinit var backend: FakeSpaceFilesBackend
    private lateinit var service: SafGatewayService
    private lateinit var scope: CoroutineScope
    private lateinit var controller: SpaceFilesController

    private val defaultFlags: Int
        get() = SafGrantFlagBits.GRANT_READ or
            SafGrantFlagBits.GRANT_WRITE or
            SafGrantFlagBits.PERSISTABLE

    @Before
    fun setUp() {
        cache = Files.createTempDirectory("space-edit-test-cache").toFile()
        editsRoot = Files.createTempDirectory("space-edit-test-edits").toFile()
        store = SpaceFilesInMemoryRootStore()
        backend = FakeSpaceFilesBackend()
        service = SafGatewayService(backend)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        controller = newController(service, scope)
    }

    @After
    fun tearDown() {
        controller.close()
        cache.deleteRecursively()
        editsRoot.deleteRecursively()
    }

    private fun newController(gateway: SafGatewayService, coroutineScope: CoroutineScope) =
        SpaceFilesController(
            service = gateway,
            backend = backend,
            store = store,
            scope = coroutineScope,
            ioDispatcher = Dispatchers.IO,
            cacheRoot = cache,
            editsRoot = editsRoot,
            clock = { 1_700_000_000_000L },
        )

    private suspend fun addRoot(flags: Int = defaultFlags) {
        controller.requestAddFolder()
        val pick = controller.state.value.pick ?: error("no picker request was captured")
        controller.handlePickerResultInternal(pick.incarnation, backend.treeUri, flags)
    }

    private suspend fun startEdit(documentId: String = "doc"): Pair<SpaceFileEntry, SpaceFilesEditSession> {
        val entry = controller.state.value.browse!!.entries.first { it.documentId == documentId }
        val id = controller.startEditInternal(entry) ?: error("edit was refused")
        return entry to controller.state.value.editSessions.first { it.id == id }
    }

    private fun awaitCondition(timeoutMs: Long = 10_000, check: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (!check()) {
            if (System.nanoTime() > deadline) error("condition was not met in ${timeoutMs}ms")
            Thread.sleep(10)
        }
    }

    @Test(timeout = 20_000)
    fun editImportsVerifiedWorkingCopyAndLaunchIsNotASave() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray(), mimeType = "text/plain")
        addRoot()
        // Adopting the picked root surfaces its own notice; the launch
        // assertion below is about what the EDIT adds, so clear it first.
        controller.dismissNotice()

        val (entry, session) = startEdit()
        assertEquals(SpaceFilesEditPhase.EDITING, session.phase)
        assertArrayEquals("the working copy is the verified provider bytes",
            "original".toByteArray(), session.workingFile.readBytes())
        assertEquals(entry.uri.uriString, session.target.uri.uriString)
        assertNotNull(controller.state.value.editLaunch)
        assertEquals(session.id, controller.state.value.editLaunch!!.sessionId)

        // Launching is never a save claim: no notice, session stays editing.
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)
        assertNull(controller.state.value.editLaunch)
        assertNull(controller.state.value.notice)
        assertEquals(SpaceFilesEditPhase.EDITING, controller.state.value.editSessions.single().phase)
        assertEquals("original", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
    }

    @Test(timeout = 20_000)
    fun unchangedWorkingCopyNeverTouchesTheProvider() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        val readsBefore = backend.openReadCalls.get()
        controller.reconcileEditInternal(session.id)

        assertEquals(SpaceFilesEditPhase.EDITING, controller.state.value.editSessions.single().phase)
        assertEquals("original", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        assertEquals("no provider read is needed for an unchanged copy", readsBefore, backend.openReadCalls.get())
        assertTrue("no recovery was staged", File(editsRoot, "recovery").listFiles().isNullOrEmpty())
    }

    @Test(timeout = 20_000)
    fun changedWorkingCopySavesBackToTheSameSourceAndRestoresThePreview() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray(), mimeType = "text/plain")
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        // The open preview shows the pre-edit bytes; after the verified save
        // it must re-open on the CURRENT provider bytes.
        controller.previewInternal(entry)
        assertEquals("original", (controller.state.value.preview as SpaceFilesPreview.Text).text)

        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)

        val saved = controller.state.value.editSessions.single()
        assertEquals(SpaceFilesEditPhase.SAVED, saved.phase)
        assertNull(saved.errorCode)
        assertEquals("edited", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        val notice = controller.state.value.notice as SpaceFilesNotice.Completed
        assertEquals(SpaceFilesOperation.EDIT, notice.operation)
        assertNull("null detail means verified at the same source", notice.detail)
        // The restored preview re-reads the saved bytes from the provider;
        // afterEditSaved runs inside reconcile, so the state is final here.
        assertEquals("edited", (controller.state.value.preview as SpaceFilesPreview.Text).text)
        // The coordinator persisted the recovery receipt before permitting.
        assertTrue(File(editsRoot, "journal/receipts").listFiles()!!.isNotEmpty())
    }

    @Test(timeout = 20_000)
    fun staleSourceIsAConflictAndBothVersionsStayRecoverable() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        // A third party changes the provider bytes after import.
        backend.content[entry.uri.uriString] = "other".toByteArray()
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)

        val conflicted = controller.state.value.editSessions.single()
        assertEquals(SpaceFilesEditPhase.CONFLICT, conflicted.phase)
        assertEquals("sourceChanged", conflicted.errorCode)
        assertEquals("the provider keeps the version it had", "other",
            String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        assertEquals("the edited working copy is kept", "edited", session.workingFile.readText())
        val recovery = File(editsRoot, "recovery").listFiles()!!.single()
        assertEquals("the recovery file holds the provider-current bytes", "other", recovery.readText())
        assertEquals(
            SpaceFilesProblem.CONFLICT,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
    }

    @Test(timeout = 20_000)
    fun conflictResolutionExportsTheEditedCopyAsAnExplicitSibling() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)
        backend.content[entry.uri.uriString] = "other".toByteArray()
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)
        assertEquals(SpaceFilesEditPhase.CONFLICT, controller.state.value.editSessions.single().phase)

        controller.saveConflictCopyAsNew(session.id)
        awaitCondition {
            controller.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.FINISHED
        }
        val finished = controller.state.value.editSessions.single()
        assertEquals("note (edited).txt", finished.savedSiblingName)
        assertEquals("the original is untouched", "other",
            String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        val sibling = backend.contentByDisplayName("note (edited).txt")
        assertNotNull(sibling)
        assertEquals("edited", sibling!!.second)
    }

    @Test(timeout = 20_000)
    fun keepProviderVersionFinishesWithoutOverwriting() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)
        backend.content[entry.uri.uriString] = "other".toByteArray()
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)

        controller.keepProviderVersion(session.id)
        awaitCondition {
            controller.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.FINISHED
        }
        assertEquals("keptProviderVersion", controller.state.value.editSessions.single().errorCode)
        assertEquals("other", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        assertEquals("edited", session.workingFile.readText())
    }

    @Test(timeout = 20_000)
    fun noHandlerFinishesTheSessionWithoutAnySaveClaim() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()

        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.NO_HANDLER)
        awaitCondition {
            controller.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.FINISHED
        }
        assertEquals("noHandler", controller.state.value.editSessions.single().errorCode)
        assertEquals(
            SpaceFilesProblem.NO_HANDLER,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
        assertEquals("original", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        assertTrue("the imported copy stays recoverable", session.workingFile.isFile)
    }

    @Test(timeout = 20_000)
    fun revokedGrantRefusesTheEditAndIsReportedAgainDuringSaveBack() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()

        // A real revocation drops the persisted row AND denies the live
        // probe (a stale persisted row alone still counts as access).
        backend.persisted.clear()
        backend.probeGranted = false

        val entry = controller.state.value.browse!!.entries.first { it.documentId == "doc" }
        assertNull(controller.startEditInternal(entry))
        assertEquals(
            SpaceFilesProblem.GRANT_REVOKED,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
        assertTrue(controller.state.value.editSessions.isEmpty())

        // Grant returns for the import, then dies before the save-back.
        backend.probeGranted = true
        val (_, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)
        backend.persisted.clear()
        backend.probeGranted = false
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)

        val row = controller.state.value.editSessions.single()
        assertEquals(SpaceFilesEditPhase.RECOVERABLE_FAILURE, row.phase)
        assertEquals("revoked", row.errorCode)
        assertEquals("original", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
    }

    @Test(timeout = 20_000)
    fun readOnlyDocumentRefusesEditBeforeAnyWrite() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray(), write = false)
        addRoot()
        val entry = controller.state.value.browse!!.entries.first { it.documentId == "doc" }

        assertNull(controller.startEditInternal(entry))
        assertEquals(
            SpaceFilesProblem.READ_ONLY,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
        assertTrue(controller.state.value.editSessions.isEmpty())
    }

    @Test(timeout = 20_000)
    fun providerRejectingTruncateWriteLandsTheBytesInAnExplicitSibling() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (_, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        // Only the original document rejects truncate-write; the fallback
        // sibling the provider creates for the save-as stays writable.
        backend.truncateUnsupportedUris += session.target.uri.uriString
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)

        val saved = controller.state.value.editSessions.single()
        assertEquals(SpaceFilesEditPhase.SAVED, saved.phase)
        assertEquals("note (edited).txt", saved.savedSiblingName)
        assertEquals("original", String(backend.content[session.target.uri.uriString]!!, Charsets.UTF_8))
        val sibling = backend.contentByDisplayName("note (edited).txt")
        assertNotNull(sibling)
        assertEquals("edited", sibling!!.second)
        val notice = controller.state.value.notice as SpaceFilesNotice.Completed
        assertEquals("note (edited).txt", notice.detail)
    }

    @Test(timeout = 30_000)
    fun sessionsRestoreAfterRestartAndSettleHonestly() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)
        session.workingFile.writeText("edited")
        controller.close()

        // Process restart: same durable edits root, same OS grant, new RAM.
        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restartedService = SafGatewayService(backend)
        val restarted = newController(restartedService, restartedScope)
        try {
            restarted.start()
            awaitCondition { restarted.state.value.editSessions.isNotEmpty() }
            val restored = restarted.state.value.editSessions.single()
            assertEquals(session.id, restored.id)
            awaitCondition {
                restarted.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.SAVED
            }
            assertEquals("edited", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
            assertEquals("edited", restored.workingFile.readText())
        } finally {
            restarted.close()
        }
    }

    @Test(timeout = 20_000)
    fun finishedSessionsAreRetiredOnRestoreAndDismissRemovesTheRow() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (_, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.NO_HANDLER)
        awaitCondition {
            controller.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.FINISHED
        }
        controller.dismissEdit(session.id)
        awaitCondition { restartedRowCount() == 0 }

        // A restart after dismissal must not resurrect the finished session.
        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restarted = newController(SafGatewayService(backend), restartedScope)
        try {
            restarted.start()
            awaitCondition { restarted.state.value.catalogLoaded }
            assertTrue(restarted.state.value.editSessions.isEmpty())
        } finally {
            restarted.close()
        }
    }

    @Test(timeout = 30_000)
    fun restartAfterLandedCommitSettlesSavedWithoutFalseConflict() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray(), mimeType = "text/plain")
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        // Simulate process death between the provider commit and the journal
        // ACK: the provider already holds the edited bytes, the working copy
        // matches, but the durable row still says SAVING (what the journal
        // last persisted before the crash).
        session.workingFile.writeText("edited")
        backend.content[entry.uri.uriString] = "edited".toByteArray()
        val journalFile = File(editsRoot, "journal/${session.id}.json")
        journalFile.writeText(SpaceFilesEditJournal.encode(
            session.copy(phase = SpaceFilesEditPhase.SAVING)).toString())
        controller.close()

        // Cold restart over the same durable edits root.
        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restarted = newController(SafGatewayService(backend), restartedScope)
        try {
            restarted.start()
            awaitCondition {
                restarted.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.SAVED
            }
            val settled = restarted.state.value.editSessions.single()
            assertNull(settled.errorCode)
            assertNull("same-source settle, no sibling", settled.savedSiblingName)
            assertEquals("edited", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
            val notice = restarted.state.value.notice as SpaceFilesNotice.Completed
            assertEquals(SpaceFilesOperation.EDIT, notice.operation)
            assertNull("null detail means verified at the same source", notice.detail)
        } finally {
            restarted.close()
        }
    }

    @Test(timeout = 30_000)
    fun restartFromConflictRestoresBothVersionsAndResolutionStillWorks() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        backend.content[entry.uri.uriString] = "other".toByteArray()
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)
        assertEquals(SpaceFilesEditPhase.CONFLICT, controller.state.value.editSessions.single().phase)
        controller.close()

        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restarted = newController(SafGatewayService(backend), restartedScope)
        try {
            restarted.start()
            awaitCondition { restarted.state.value.editSessions.isNotEmpty() }
            val restored = restarted.state.value.editSessions.single()
            assertEquals(session.id, restored.id)
            assertEquals(SpaceFilesEditPhase.CONFLICT, restored.phase)
            assertEquals("the working edit survives the restart", "edited", restored.workingFile.readText())
            assertEquals("the provider version is untouched", "other",
                String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))

            restarted.saveConflictCopyAsNew(session.id)
            awaitCondition {
                restarted.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.FINISHED
            }
            assertEquals("note (edited).txt", restarted.state.value.editSessions.single().savedSiblingName)
            assertEquals("other", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
            val sibling = backend.contentByDisplayName("note (edited).txt")
            assertNotNull(sibling)
            assertEquals("edited", sibling!!.second)
        } finally {
            restarted.close()
        }
    }

    @Test(timeout = 30_000)
    fun restartFromRevokedSaveBackKeepsWorkingCopyAndSettlesWhenGrantReturns() = runBlocking {
        backend.addFile("doc", "note.txt", bytes = "original".toByteArray())
        addRoot()
        val (entry, session) = startEdit()
        controller.completeEditLaunch(controller.state.value.editLaunch!!.id, SpaceFilesEditLaunchResult.LAUNCHED)

        // The grant dies after import: the save-back must fail typed, keep
        // the working bytes on disk, and leave the provider untouched.
        backend.persisted.clear()
        backend.probeGranted = false
        session.workingFile.writeText("edited")
        controller.reconcileEditInternal(session.id)
        assertEquals(SpaceFilesEditPhase.RECOVERABLE_FAILURE,
            controller.state.value.editSessions.single().phase)
        controller.close()

        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restarted = newController(SafGatewayService(backend), restartedScope)
        try {
            restarted.start()
            awaitCondition { restarted.state.value.editSessions.isNotEmpty() }
            awaitCondition {
                restarted.state.value.editSessions.singleOrNull()?.phase ==
                    SpaceFilesEditPhase.RECOVERABLE_FAILURE
            }
            val restored = restarted.state.value.editSessions.single()
            assertEquals(session.id, restored.id)
            assertEquals("the working edit survives the restart", "edited", restored.workingFile.readText())
            assertEquals("original", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))

            // The grant returns: the same retry path a resume takes settles
            // the verified bytes at the same source document.
            backend.probeGranted = true
            restarted.reconcileEdit(session.id)
            awaitCondition {
                restarted.state.value.editSessions.singleOrNull()?.phase == SpaceFilesEditPhase.SAVED
            }
            assertEquals("edited", String(backend.content[entry.uri.uriString]!!, Charsets.UTF_8))
        } finally {
            restarted.close()
        }
    }

    private fun restartedRowCount(): Int = controller.state.value.editSessions.size
}
