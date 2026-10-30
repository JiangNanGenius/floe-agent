// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSource
import com.floe.android.core.officeengine.pdf.PdfDocResult
import com.floe.android.core.officeengine.pdf.PdfFailure
import com.floe.android.core.officeengine.pdf.PdfPageResult
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * G07.1 preview LIFECYCLE at the changed boundary (pure JVM, fake stager
 * channel and PDF port; no renderer, Compose or device):
 *  - a root stop never claims clean before the renderer's release callback
 *    (the snapshot stays until that proof);
 *  - a failing release retains the snapshot/password and permanently blocks
 *    the clean-drain claim instead of deleting a possibly live source;
 *  - a cancelled staging job is joined before retirement;
 *  - an asynchronous failure cleanup is drained before the root retires;
 *  - a stale document result from a retired owner never adopts its replacement.
 */
class WorkspaceDocumentPreviewLifecycleTest {
    @get:Rule val temporary = TemporaryFolder()

    private val executor = Executors.newSingleThreadExecutor()
    private val dispatcher = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val root by lazy { temporary.newFolder("preview-root") }
    private val epoch = 9L
    private val generation = 3L
    private val pdfBody = "%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n".toByteArray()

    @After fun closeDispatcher() {
        dispatcher.close()
        executor.shutdownNow()
    }

    // ------------------------------------------------------------------
    // Fakes (the SAME stager channel shape used by the real egress)
    // ------------------------------------------------------------------

    private class PdfChannel(
        private val body: ByteArray,
        private val path: String = "docs/readonly.pdf",
        private val firstReadDelayMs: Long = 0,
    ) : WorkspaceOfficeSnapshotStager.Channel {
        val sha: String = MessageDigest.getInstance("SHA-256").digest(body)
            .joinToString("") { "%02x".format(it) }
        @Volatile var readStarted = false
        var closes = 0
        private var delayed = false

        override fun open(owner: WorkspaceOfficeSnapshotStager.Owner, path: String): Long = 7L

        override fun info(ticket: Long, reply: ByteArray): Int {
            val json = """{"ok":1,"mode":"export","logicalPath":"$path","sha256":"$sha","bytes":${body.size}}"""
                .toByteArray()
            json.copyInto(reply)
            return json.size
        }

        override fun read(ticket: Long, offset: Long, target: ByteArray): Int {
            if (offset >= body.size.toLong()) return 0
            if (!delayed) {
                delayed = true
                readStarted = true
                if (firstReadDelayMs > 0) Thread.sleep(firstReadDelayMs)
            }
            val count = minOf(target.size, body.size - offset.toInt())
            body.copyInto(target, 0, offset.toInt(), offset.toInt() + count)
            return count
        }

        override fun close(ticket: Long): Int {
            closes += 1
            return 0
        }
    }

    private class FakePdfPort(
        private val info: PdfDocResult? = PdfDocResult.Ready(2),
        private val render: PdfPageResult = PdfPageResult.Failed(PdfFailure.Busy),
        private val releaseFault: Throwable? = null,
        /** When true the fake renderer answers the release callback inline,
         * exactly like a rejected drain finalizer in the real host. */
        private val inlineQuiesce: Boolean = true,
    ) : WorkspacePreviewPdfPort {
        var documentInfoCalls = 0
        var releaseCalls = 0
        val infoCallbacks = mutableListOf<(PdfDocResult) -> Unit>()
        private var quiescent: (() -> Unit)? = null

        override fun documentInfo(
            source: OfficePdfVerifiedSource,
            password: CharArray?,
            onResult: (PdfDocResult) -> Unit,
        ) {
            documentInfoCalls += 1
            infoCallbacks += onResult
            info?.let(onResult)
        }

        override fun renderPage(
            source: OfficePdfVerifiedSource,
            pageIndex: Int,
            zoomPercent: Int,
            password: CharArray?,
            onResult: (PdfPageResult) -> Unit,
        ) = onResult(render)

        override fun release(onQuiescent: (() -> Unit)?) {
            releaseCalls += 1
            releaseFault?.let { throw it }
            quiescent = onQuiescent
            if (inlineQuiesce) quiesce()
        }

        fun quiesce() {
            val callback = quiescent ?: return
            quiescent = null
            callback()
        }

        fun deliverDocumentInfo(result: PdfDocResult) {
            infoCallbacks.last()(result)
        }
    }

    // ------------------------------------------------------------------
    // Fixture helpers
    // ------------------------------------------------------------------

    private fun owner(): Owner = Owner(
        UUID.randomUUID().toString(), UUID.randomUUID().toString(), epoch, generation)

    private fun controller(
        channel: WorkspaceOfficeSnapshotStager.Channel,
        portFactory: () -> FakePdfPort,
    ): WorkspaceDocumentPreviewController = WorkspaceDocumentPreviewController(
        root = root,
        scope = scope,
        ioDispatcher = dispatcher,
        currentNativeEpoch = { epoch },
        currentHostGeneration = { generation },
        isTemporaryTask = { false },
        admitsPasswordPrompt = { true },
        pdfPortFactory = portFactory,
        stager = WorkspaceOfficeSnapshotStager(root, channel),
    )

    private fun awaitState(
        controller: WorkspaceDocumentPreviewController,
        timeoutMs: Long = 4_000,
        predicate: (WorkspacePreviewState) -> Boolean,
    ): WorkspacePreviewState {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (System.nanoTime() < deadline) {
            val state = controller.state.value
            if (predicate(state)) return state
            Thread.sleep(5)
        }
        throw AssertionError("state never matched; last=${controller.state.value}")
    }

    private fun awaitTrue(timeoutMs: Long = 4_000, condition: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (System.nanoTime() < deadline) {
            if (condition()) return
            Thread.sleep(5)
        }
        throw AssertionError("condition never became true")
    }

    private fun snapshotDirectory(): File {
        val entries = root.listFiles()?.toList().orEmpty()
        return entries.singleOrNull { it.isDirectory }
            ?: throw AssertionError(
                "expected exactly one live snapshot directory; root=$root " +
                    "exists=${root.exists()} entries=${entries.map { it.name }}",
            )
    }

    private fun snapshotFile(): File = File(snapshotDirectory(), "document.pdf")

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    @Test fun rootStopWaitsForReleaseCallbackBeforeDeletingTheSnapshot() {
        val port = FakePdfPort(inlineQuiesce = false)
        val controller = this.controller(PdfChannel(pdfBody)) { port }

        assertTrue(controller.open(owner(), "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitState(controller) { it is WorkspacePreviewState.Pdf }
        assertEquals(1, port.documentInfoCalls)
        assertEquals(0, port.releaseCalls)
        val snapshot = snapshotFile()
        assertTrue(snapshot.isFile)

        // The renderer has not answered with quiescence yet: a clean drain is
        // unprovable and the snapshot must stay.
        assertFalse(runBlocking { controller.prepareForRootStop(150) })
        assertEquals(1, port.releaseCalls)
        assertTrue("snapshot was deleted before renderer quiescence", snapshot.isFile)
        assertTrue(controller.state.value is WorkspacePreviewState.Failed)
        assertEquals(
            WorkspacePreviewState.Failure.OWNER,
            (controller.state.value as WorkspacePreviewState.Failed).failure,
        )

        // The real release callback is the only thing that may unlink it.
        port.quiesce()
        assertFalse(snapshot.exists())
        assertTrue(runBlocking { controller.prepareForRootStop(1_000) })
        assertTrue(root.listFiles().isNullOrEmpty())
    }

    @Test fun closeLeavesTheSnapshotUntilTheRendererReleaseCallback() {
        val port = FakePdfPort(inlineQuiesce = false)
        val controller = this.controller(PdfChannel(pdfBody)) { port }
        assertTrue(controller.open(owner(), "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitState(controller) { it is WorkspacePreviewState.Pdf }

        val snapshot = snapshotFile()
        controller.close(1L)
        assertEquals(WorkspacePreviewState.Idle, controller.state.value)
        // close() itself is synchronous; the deletion proof still belongs to
        // the release callback and the root drain must not fake it.
        assertTrue(snapshot.isFile)
        assertFalse(runBlocking { controller.prepareForRootStop(120) })
        assertTrue(snapshot.isFile)

        port.quiesce()
        assertFalse(snapshot.exists())
        assertTrue(runBlocking { controller.prepareForRootStop(1_000) })
    }

    @Test fun failedRendererReleaseRetainsSnapshotAndRefusesCleanDrainForever() {
        val port = FakePdfPort(releaseFault = IllegalStateException("renderer release refused"))
        val controller = this.controller(PdfChannel(pdfBody)) { port }
        assertTrue(controller.open(owner(), "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitState(controller) { it is WorkspacePreviewState.Pdf }
        val snapshot = snapshotFile()

        controller.close(1L)
        assertEquals(1, port.releaseCalls)
        assertTrue("failed release must retain the possibly pinned source", snapshot.isFile)

        // No second release attempt is presented as proof, and no drain ever
        // reports clean for this process.
        assertFalse(runBlocking { controller.prepareForRootStop(200) })
        assertTrue(snapshot.isFile)
        assertFalse(runBlocking { controller.prepareForRootStop(200) })
        assertTrue(snapshot.isFile)
        assertEquals(1, port.releaseCalls)
    }

    @Test fun staleDocumentInfoCannotAdoptAReplacementOwner() {
        val ports = mutableListOf<FakePdfPort>()
        val first = FakePdfPort(info = null)
        val second = FakePdfPort(info = PdfDocResult.Ready(3))
        ports += first
        ports += second
        var next = 0
        val controller = this.controller(PdfChannel(pdfBody)) { ports[next++] }

        val firstOwner = owner()
        assertTrue(controller.open(firstOwner, "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitTrue { first.documentInfoCalls == 1 }

        // A different request retires the first owner while its document
        // reply is still outstanding.
        val secondOwner = owner()
        assertTrue(controller.open(secondOwner, "docs/readonly.pdf", WorkspacePreviewKind.PDF, 2L))
        val live = awaitState(controller) {
            (it as? WorkspacePreviewState.Pdf)?.token == 2L
        } as WorkspacePreviewState.Pdf
        assertEquals(3, live.pageCount)

        first.deliverDocumentInfo(PdfDocResult.Ready(9))
        val after = controller.state.value as WorkspacePreviewState.Pdf
        assertEquals(2L, after.token)
        assertEquals(3, after.pageCount)
        assertTrue(controller.isPresenting(2L))
        assertFalse(controller.isPresenting(1L))
    }

    @Test fun rootStopJoinsACancelledStagingJobBeforeRetiring() {
        val channel = PdfChannel(pdfBody, firstReadDelayMs = 250)
        val controller = this.controller(channel) { FakePdfPort() }
        assertTrue(controller.open(owner(), "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitTrue { channel.readStarted }

        val started = System.nanoTime()
        assertTrue(runBlocking { controller.prepareForRootStop(3_000) })
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("drain did not wait for the staging job (${elapsedMs}ms)", elapsedMs >= 150)
        assertTrue(root.listFiles().isNullOrEmpty())
        assertEquals(1, channel.closes)
        val state = controller.state.value as WorkspacePreviewState.Failed
        assertEquals(WorkspacePreviewState.Failure.OWNER, state.failure)
    }

    @Test fun rootStopDrainsLateFailureCleanupBeforeRetiring() {
        val invalid = PdfChannel("PK\u0003\u0004not-a-pdf".toByteArray())
        val controller = this.controller(invalid) { FakePdfPort() }
        assertTrue(controller.open(owner(), "docs/readonly.pdf", WorkspacePreviewKind.PDF, 1L))
        awaitState(controller) { it is WorkspacePreviewState.Failed }

        assertTrue(runBlocking { controller.prepareForRootStop(3_000) })
        assertTrue(root.listFiles().isNullOrEmpty())
        assertEquals(1, invalid.closes)
    }
}
