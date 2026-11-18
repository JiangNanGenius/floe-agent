// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.SafBackendFault
import com.floe.android.safgateway.SafBackendFaultException
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafGrantFlagBits
import com.floe.android.safgateway.SafSize
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Behavioural tests over the REAL gateway service and an in-memory provider.
 *
 * What is exercised (not the code's own shape):
 *  - the picker's ACTUAL returned flags decide persistence, and only offered
 *    flags are ever taken;
 *  - the OS persisted row + live probe (not the saved metadata) decide whether
 *    a root is usable after a restart and after a revoke;
 *  - listing uses the exact tree and the exact parent document id, with held
 *    cursor paging;
 *  - create/rename/delete/copy/move are gated by the row's COLUMN_FLAGS and
 *    only publish provider receipts;
 *  - a cancelled scan cannot publish another folder's rows;
 *  - preview is size-bounded and never labels binary bytes as text;
 *  - forgetting a root never releases the OS grant.
 */
class SpaceFilesControllerTest {

    private lateinit var cache: File
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
        cache = Files.createTempDirectory("space-files-test").toFile()
        store = SpaceFilesInMemoryRootStore()
        backend = FakeSpaceFilesBackend()
        service = SafGatewayService(backend)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        controller = SpaceFilesController(
            service = service,
            backend = backend,
            store = store,
            scope = scope,
            ioDispatcher = Dispatchers.IO,
            cacheRoot = cache,
            clock = { 1_700_000_000_000L },
        )
    }

    @After
    fun tearDown() {
        controller.close()
        cache.deleteRecursively()
    }

    private suspend fun addRoot(flags: Int = defaultFlags) {
        controller.requestAddFolder()
        val pick = controller.state.value.pick ?: error("no picker request was captured")
        controller.handlePickerResultInternal(pick.incarnation, backend.treeUri, flags)
    }

    @Test(timeout = 20_000)
    fun pickedTreeUsesOnlyReturnedFlagsAndReportsSessionOnly() = runBlocking {
        backend.addFile("a", "a.txt")

        // READ only: no WRITE bit was returned, so the live probe denies write.
        backend.probeWriteGranted = false
        addRoot(flags = SafGrantFlagBits.GRANT_READ)

        val state = controller.state.value
        val root = state.roots.single()
        assertTrue(root.read)
        assertFalse(root.write)
        assertEquals(SpaceRootAccess.READ_ONLY, root.access)
        assertFalse("no PERSISTABLE bit was returned", root.persisted)
        assertTrue("takePersistable may only run for an offered persistable flag", backend.takeCalls.isEmpty())
        val notice = state.notice as SpaceFilesNotice.RootAdded
        assertTrue("a read-only session grant is session-only", notice.sessionOnly)
        assertEquals(listOf("a.txt"), state.browse?.entries?.map { it.name })
        assertEquals("the exact tree is used as the grant anchor", backend.treeUri, state.browse?.root?.uri?.uriString)
    }

    @Test(timeout = 20_000)
    fun persistablePickPersistsEachGrantedFlagAndIsReopenedAfterRestart() = runBlocking {
        backend.addFile("a", "a.txt")

        addRoot()

        assertEquals(listOf("WRITE", "READ"), backend.takeCalls.toList())
        val root = controller.state.value.roots.single()
        assertTrue(root.persisted)
        assertEquals(SpaceRootAccess.READ_WRITE, root.access)
        assertFalse((controller.state.value.notice as SpaceFilesNotice.RootAdded).sessionOnly)

        // Process restart: a new controller and gateway, the same OS-persisted
        // row. The saved metadata alone must not be trusted; the probe is.
        val restartedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val restartedService = SafGatewayService(backend)
        val restarted = SpaceFilesController(
            service = restartedService,
            backend = backend,
            store = store,
            scope = restartedScope,
            ioDispatcher = Dispatchers.IO,
            cacheRoot = cache,
            clock = { 1_700_000_100_000L },
        )
        try {
            restarted.refreshCatalogInternal(openFirstUsable = true)
            val state = restarted.state.value
            assertEquals(1, state.roots.size)
            assertTrue("the persisted OS grant must re-open the root", state.roots.single().usable)
            assertEquals(listOf("a.txt"), state.browse?.entries?.map { it.name })
        } finally {
            restarted.close()
        }
    }

    @Test(timeout = 20_000)
    fun revokedAccessRequiresReselectAndForgettingNeverReleasesTheGrant() = runBlocking {
        backend.addFile("a", "a.txt")
        addRoot()
        assertTrue(controller.state.value.browse?.entries?.isNotEmpty() == true)

        // The user revoked the tree in system settings.
        backend.persisted.clear()
        backend.probeGranted = false
        controller.refreshCatalogInternal(openFirstUsable = false)

        val state = controller.state.value
        assertEquals(SpaceRootAccess.REVOKED, state.roots.single().access)
        assertEquals(SpaceFilesProblem.GRANT_REVOKED, state.browse?.error?.problem)
        assertTrue("stale rows must not stay visible after a revoke", state.browse?.entries?.isEmpty() == true)

        controller.removeRootInternal(backend.tree)
        assertTrue(controller.state.value.roots.isEmpty())
        assertNull(controller.state.value.browse)
        assertEquals(
            "removing local metadata must never call the OS release path",
            0,
            backend.releaseCalls.get(),
        )
        assertTrue("the saved metadata was removed", store.read().isEmpty())
    }

    @Test(timeout = 30_000)
    fun listingPagesHeldCursorsAndNavigatesExactSubfolders() = runBlocking {
        repeat(205) { index -> backend.addFile("f$index", "f%03d.txt".format(index)) }
        backend.addDirectory("sub", "sub")
        backend.addFile("inside", "inside.txt", parentDocumentId = "sub")

        addRoot()

        val first = controller.state.value.browse!!
        assertEquals(200, first.entries.size)
        assertTrue(first.hasMore)
        assertNotNull(first.nextCursorToken)
        val firstCall = backend.listingCalls.first()
        assertEquals("the exact granted tree is listed", backend.treeUri, firstCall.tree)
        assertEquals("the tree root document is the parent", backend.rootDocumentId, firstCall.parentDocumentId)

        controller.loadMoreInternal()
        val second = controller.state.value.browse!!
        assertEquals(206, second.entries.size)
        assertFalse(second.hasMore)
        assertEquals("cursor-200", backend.listingCalls[1].cursor)

        val sub = second.entries.first { it.isDirectory }
        controller.enterFolderInternal(sub)
        val third = controller.state.value.browse!!
        assertEquals(2, third.path.size)
        assertEquals("sub", third.path.last().documentId)
        assertTrue(third.canGoUp)
        assertEquals(listOf("inside.txt"), third.entries.map { it.name })
        assertEquals("sub", backend.listingCalls.last().parentDocumentId)

        controller.goUpInternal()
        assertEquals(1, controller.state.value.browse!!.path.size)
    }

    @Test(timeout = 20_000)
    fun createRenameDeleteRequireExactFlagsAndPublishRealReceipts() = runBlocking {
        backend.addDirectory("plain", "plain", createChildren = false)
        backend.addFile("doc", "doc.txt", rename = true, delete = true)
        backend.addFile("fixed", "fixed.txt", rename = false)
        addRoot()

        assertTrue("the root advertises DIR_SUPPORTS_CREATE", controller.createFolderInternal("Docs"))
        assertTrue(controller.state.value.browse!!.entries.any { it.name == "Docs" && it.isDirectory })
        assertEquals(
            SpaceFilesOperation.CREATE_FOLDER,
            (controller.state.value.notice as SpaceFilesNotice.Completed).operation,
        )

        val plain = controller.state.value.browse!!.entries.first { it.documentId == "plain" }
        controller.enterFolderInternal(plain)
        val createsBefore = backend.createCalls.size
        assertFalse("a folder without DIR_SUPPORTS_CREATE must refuse", controller.createFileInternal("note.txt"))
        assertEquals(createsBefore, backend.createCalls.size)
        assertEquals(
            SpaceFilesProblem.UNSUPPORTED,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
        controller.goUpInternal()

        controller.reloadBrowseInternal()
        val fixed = controller.state.value.browse!!.entries.first { it.documentId == "fixed" }
        assertFalse("rename without FLAG_SUPPORTS_RENAME must refuse", controller.renameInternal(fixed, "x.txt"))
        assertTrue(backend.renameCalls.isEmpty())
        assertEquals(
            SpaceFilesProblem.UNSUPPORTED,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )

        val doc = controller.state.value.browse!!.entries.first { it.documentId == "doc" }
        assertTrue(controller.renameInternal(doc, "renamed.txt"))
        assertEquals("renamed.txt", backend.renameCalls.single().second)
        assertTrue(controller.state.value.browse!!.entries.any { it.name == "renamed.txt" })

        val renamed = controller.state.value.browse!!.entries.first { it.name == "renamed.txt" }
        assertTrue(controller.deleteInternal(renamed))
        assertEquals(1, backend.deleteCalls.size)
        assertFalse(controller.state.value.browse!!.entries.any { it.name == "renamed.txt" })
        assertTrue("other files survive the delete", controller.state.value.browse!!.entries.any { it.name == "fixed.txt" })

        val before = backend.createCalls.size
        assertFalse("an unsafe segment is refused before any provider call", controller.createFolderInternal("a/b"))
        assertEquals(before, backend.createCalls.size)
        assertEquals(
            SpaceFilesProblem.INVALID_NAME,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
    }

    @Test(timeout = 30_000)
    fun copyAndMoveUseVerifiedReceiptsAndRefuseSelfDestinations() = runBlocking {
        backend.addDirectory("dest", "dest")
        backend.addDirectory("folder", "folder")
        backend.addFile("src", "src.txt", bytes = "payload".toByteArray(), copy = true)
        backend.addFile(
            "retained",
            "retained.txt",
            bytes = "keep".toByteArray(),
            copy = true,
            move = false,
            delete = false,
        )
        addRoot()

        val src = controller.state.value.browse!!.entries.first { it.documentId == "src" }
        assertTrue(controller.beginTransferInternal(src, SpaceFilesOperation.COPY))
        assertTrue(controller.transferConfirmInternal())
        assertEquals(1, backend.copyCalls.size)
        val copied = controller.state.value.notice as SpaceFilesNotice.Completed
        assertEquals(SpaceFilesOperation.COPY, copied.operation)
        assertFalse(copied.sourceRetained)

        // Moving a folder into itself must be refused before any provider move.
        controller.reloadBrowseInternal()
        val folder = controller.state.value.browse!!.entries.first { it.documentId == "folder" }
        assertTrue(controller.beginTransferInternal(folder, SpaceFilesOperation.MOVE))
        val folderInDest = controller.state.value.transfer!!.directories.first { it.documentId == "folder" }
        controller.transferEnterInternal(folderInDest)
        val movesBefore = backend.moveCalls.size
        assertFalse(controller.transferConfirmInternal())
        assertEquals(movesBefore, backend.moveCalls.size)
        assertEquals(
            SpaceFilesProblem.INVALID_DESTINATION,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
        controller.transferCancel()

        // A provider that cannot delete the source yields a verified copy with
        // the original retained -- reported as such, never as a full move.
        controller.reloadBrowseInternal()
        val retained = controller.state.value.browse!!.entries.first { it.documentId == "retained" }
        assertTrue(controller.beginTransferInternal(retained, SpaceFilesOperation.MOVE))
        val dest = controller.state.value.transfer!!.directories.first { it.documentId == "dest" }
        controller.transferEnterInternal(dest)
        assertTrue(controller.transferConfirmInternal())
        val moved = controller.state.value.notice as SpaceFilesNotice.Completed
        assertEquals(SpaceFilesOperation.MOVE, moved.operation)
        assertTrue("a verified copy that kept the original must say so", moved.sourceRetained)
        assertTrue(backend.deleteCalls.isEmpty())
    }

    @Test(timeout = 20_000)
    fun nativeMoveIsReportedAsAMoveWithoutRetention() = runBlocking {
        backend.addDirectory("dest", "dest")
        backend.addFile("src", "src.txt", bytes = "payload".toByteArray(), move = true)
        addRoot()

        val src = controller.state.value.browse!!.entries.first { it.documentId == "src" }
        assertTrue(controller.beginTransferInternal(src, SpaceFilesOperation.MOVE))
        val dest = controller.state.value.transfer!!.directories.first { it.documentId == "dest" }
        controller.transferEnterInternal(dest)
        assertTrue(controller.transferConfirmInternal())

        val moved = controller.state.value.notice as SpaceFilesNotice.Completed
        assertEquals(SpaceFilesOperation.MOVE, moved.operation)
        assertFalse(moved.sourceRetained)
        assertEquals(1, backend.moveCalls.size)
        assertTrue(backend.deleteCalls.isEmpty())
    }

    @Test(timeout = 20_000)
    fun cancellingAFolderScanPublishesCancelledInsteadOfAnotherFoldersRows() = runBlocking {
        backend.addDirectory("slow", "slow")
        backend.addFile("root-file", "root.txt")
        addRoot()

        val slow = controller.state.value.browse!!.entries.first { it.documentId == "slow" }
        backend.blockScansUntilCancelled = true
        backend.scanEntered = CountDownLatch(1)
        val job = launch(Dispatchers.Default) { controller.enterFolderInternal(slow) }
        assertTrue("the fake scan never started", backend.scanEntered!!.await(5, TimeUnit.SECONDS))
        job.cancel()
        job.join()

        assertTrue("the provider scan did not observe cancellation", backend.cancelObserved.get())
        val browse = controller.state.value.browse!!
        assertEquals("slow", browse.path.last().documentId)
        assertEquals(SpaceFilesProblem.CANCELLED, browse.error?.problem)
        assertFalse(browse.loading)
        assertTrue("no rows were invented for the cancelled folder", browse.entries.isEmpty())
    }

    @Test(timeout = 20_000)
    fun providerRevocationOnListingBecomesATypedBlockingError() = runBlocking {
        backend.addDirectory("sub", "sub")
        addRoot()

        val sub = controller.state.value.browse!!.entries.first { it.documentId == "sub" }
        backend.faultOnChildScan = SafBackendFaultException(SafBackendFault.REVOKED, "grant gone")
        controller.enterFolderInternal(sub)

        val browse = controller.state.value.browse!!
        assertEquals(SpaceFilesProblem.GRANT_REVOKED, browse.error?.problem)
        assertTrue(browse.error!!.blocking)
        assertTrue(browse.entries.isEmpty())
        assertFalse(browse.loading)
    }

    @Test(timeout = 20_000)
    fun previewIsBoundedByDeclaredSizeAndNeverCallsBinaryBytesText() = runBlocking {
        backend.addFile("text", "note.txt", bytes = "hello".toByteArray(), mimeType = "text/plain")
        backend.addFile("binary", "blob.txt", bytes = byteArrayOf(0, 1, 2, 3), mimeType = "text/plain")
        backend.addFile(
            "big",
            "big.txt",
            bytes = "x".toByteArray(),
            mimeType = "text/plain",
            size = SafSize.Known(300_000),
        )
        addRoot()
        val entries = controller.state.value.browse!!.entries

        controller.previewInternal(entries.first { it.documentId == "text" })
        val text = controller.state.value.preview as SpaceFilesPreview.Text
        assertEquals("hello", text.text)
        assertEquals(5L, text.bytes)
        controller.dismissPreview()

        val readsBefore = backend.openReadCalls.get()
        controller.previewInternal(entries.first { it.documentId == "big" })
        val big = controller.state.value.preview as SpaceFilesPreview.Unavailable
        assertEquals(SpaceFilesProblem.SIZE_LIMIT, big.failure.problem)
        assertEquals("an oversized preview must not open the stream", readsBefore, backend.openReadCalls.get())

        controller.previewInternal(entries.first { it.documentId == "binary" })
        val binary = controller.state.value.preview as SpaceFilesPreview.Unavailable
        assertEquals(SpaceFilesProblem.BINARY, binary.failure.problem)
    }

    @Test(timeout = 20_000)
    fun externalOpenUsesTheExactDocumentAndReportsOnlyObservedFailures() = runBlocking {
        backend.addFile("text", "note.txt", mimeType = "text/plain")
        backend.addFile("virtual", "cloud.doc", mimeType = "application/vnd.example.cloud", virtual = true)
        addRoot()

        val entry = controller.state.value.browse!!.entries.first { it.documentId == "text" }
        controller.openExternally(entry.ref, entry.isVirtual, entry.name, entry.mimeType)
        val request = controller.state.value.openRequest!!
        assertEquals(entry.uri.uriString, request.uri.uriString)
        assertEquals("text/plain", request.mimeType)
        controller.completeOpenRequest(request.id, SpaceFilesOpenResult.NO_HANDLER)
        assertNull(controller.state.value.openRequest)
        assertEquals(
            SpaceFilesProblem.NO_HANDLER,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )

        // Opening is not editing: a successful launch produces no success claim.
        controller.dismissNotice()
        controller.openExternally(entry.ref, entry.isVirtual, entry.name, entry.mimeType)
        val launched = controller.state.value.openRequest!!
        controller.completeOpenRequest(launched.id, SpaceFilesOpenResult.LAUNCHED)
        assertNull(controller.state.value.openRequest)
        assertNull("a launched viewer is not a successful edit", controller.state.value.notice)

        // Virtual documents have no raw byte representation for a viewer.
        val virtual = controller.state.value.browse!!.entries.first { it.documentId == "virtual" }
        controller.openExternally(virtual.ref, virtual.isVirtual, virtual.name, virtual.mimeType)
        assertNull(controller.state.value.openRequest)
        assertEquals(
            SpaceFilesProblem.UNSUPPORTED,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
    }

    @Test(timeout = 20_000)
    fun externalOpenAfterGrantLossIsReportedAsRevoked() = runBlocking {
        backend.addFile("text", "note.txt", mimeType = "text/plain")
        addRoot()
        val entry = controller.state.value.browse!!.entries.first { it.documentId == "text" }

        backend.persisted.clear()
        backend.probeGranted = false

        controller.openExternally(entry.ref, entry.isVirtual, entry.name, entry.mimeType)
        assertNull(controller.state.value.openRequest)
        assertEquals(
            SpaceFilesProblem.GRANT_REVOKED,
            (controller.state.value.notice as SpaceFilesNotice.Failed).failure.problem,
        )
    }
}
