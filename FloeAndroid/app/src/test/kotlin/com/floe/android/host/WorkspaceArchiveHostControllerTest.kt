// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WSF-SAFE-EXTRACT controller contract (pure JVM; no Compose/device/bridge):
 *  - the format/destination helpers mirror the original engine rules, so the
 *    UI can never propose an overwrite candidate;
 *  - the tree rebuild keeps the original directory-first presentation and
 *    refuses traversal-shaped rows even though the engine already rejected
 *    them;
 *  - the controller publishes honest typed states: stale owners fail OWNER,
 *    unsupported formats fail before any bridge call, extraction failures
 *    map to the typed surface and a cancelled extract is CANCELLED, never a
 *    hidden success;
 *  - close/root-stop drain everything the view used to own.
 */
class WorkspaceArchiveHostControllerTest {

    private data class Harness(
        val controller: WorkspaceArchiveHostController,
        val transport: FakeArchiveTransport,
        val epoch: Long?,
    )

    private class FakeArchiveTransport : WorkspaceArchiveTransport {
        var responses: MutableMap<String, String> = mutableMapOf()
        var failures: MutableMap<String, WorkspaceArchiveHostFailure> = mutableMapOf()
        var calls: MutableList<String> = mutableListOf()
        var throwRaw: Throwable? = null

        override fun exchange(request: String): String {
            calls.add(request)
            throwRaw?.let { throw it }
            for ((key, failure) in failures) {
                if (request.contains(key)) throw failure
            }
            for ((key, response) in responses) {
                if (request.contains(key)) return response
            }
            throw WorkspaceArchiveHostFailure("unscripted")
        }
    }

    private fun harness(
        epoch: Long? = 42L,
        temporary: Boolean = false,
        transport: FakeArchiveTransport = FakeArchiveTransport(),
    ): Harness {
        val controller = WorkspaceArchiveHostController(
            scope = CoroutineScope(Job() + Dispatchers.Unconfined),
            ioDispatcher = Dispatchers.Unconfined,
            currentNativeEpoch = { epoch },
            currentHostGeneration = { 7L },
            isTemporaryTask = { temporary },
            client = WorkspaceArchiveHostClient(transport),
            pollIntervalMillis = 10_000L,
        )
        return Harness(controller, transport, epoch)
    }

    private fun owner(epoch: Long = 42L, generation: Long = 7L) = Owner(
        taskID = UUID.randomUUID().toString(),
        workspaceID = UUID.randomUUID().toString(),
        nativeEpoch = epoch,
        hostGeneration = generation,
    )

    private fun listingResponse(format: String = "zip") = """
        {"ok":true,"version":25,"schema":"floe.archive/25","operation":"g04.archive.listing",
         "format":"$format","entryCount":2,"truncated":false,
         "summary":"status=ok action=list format=$format entries=2 truncated=false",
         "entries":[
           {"path":"docs/","isDirectory":true,"size":0},
           {"path":"docs/read me.txt","isDirectory":false,"size":12}
         ]}
    """.trimIndent()

    // ---- format helpers -------------------------------------------------

    @Test fun formatMirrorsTheOriginalExtensionRules() {
        assertEquals("tgz", WorkspaceArchiveFormat.formatFor("a/b.tar.gz"))
        assertEquals("tgz", WorkspaceArchiveFormat.formatFor("a/b.tgz"))
        assertEquals("tbz2", WorkspaceArchiveFormat.formatFor("a/b.tar.bz2"))
        assertEquals("txz", WorkspaceArchiveFormat.formatFor("a/b.tar.xz"))
        assertEquals("zip", WorkspaceArchiveFormat.formatFor("a/B.ZIP"))
        assertEquals("7z", WorkspaceArchiveFormat.formatFor("a/b.7z"))
        assertEquals("gz", WorkspaceArchiveFormat.formatFor("a/b.gz"))
        assertNull(WorkspaceArchiveFormat.formatFor("a/b"))
        assertNull(WorkspaceArchiveFormat.formatFor("a/.hidden"))
    }

    @Test fun kindsMatchTheOriginalServiceCapabilities() {
        assertEquals(WorkspaceArchiveFormatKind.CONTAINER, WorkspaceArchiveFormat.kind("zip"))
        assertEquals(WorkspaceArchiveFormatKind.CONTAINER, WorkspaceArchiveFormat.kind("7z"))
        assertEquals(WorkspaceArchiveFormatKind.SINGLE_FILE, WorkspaceArchiveFormat.kind("gz"))
        assertEquals(WorkspaceArchiveFormatKind.SINGLE_FILE, WorkspaceArchiveFormat.kind("bz2"))
        assertNull(WorkspaceArchiveFormat.kind("rar"))
        assertNull(WorkspaceArchiveFormat.kind("exe"))
    }

    @Test fun destinationsDeriveFromTheOriginalRulesAndNeverOverwrite() {
        assertEquals("report-unpacked", WorkspaceArchiveFormat.extractDestinationFor("docs/report.zip"))
        assertEquals("archive-unpacked", WorkspaceArchiveFormat.extractDestinationFor(".zip"))
        assertEquals("log", WorkspaceArchiveFormat.decompressDestinationFor("docs/log.gz"))
        // Fixed iOS ArchiveBrowserView invokes this only for gz/bz2/xz.
        // A tar container must never produce a pretend single-file destination.
        assertTrue(runCatching { WorkspaceArchiveFormat.decompressDestinationFor("docs/data.tar.gz") }
            .exceptionOrNull() is IllegalArgumentException)
        assertTrue(runCatching { WorkspaceArchiveFormat.decompressDestinationFor("docs/blob") }
            .exceptionOrNull() is IllegalArgumentException)
        assertEquals(".log", WorkspaceArchiveFormat.decompressDestinationFor("docs/.log.gz"))
    }

    // ---- tree -----------------------------------------------------------

    @Test fun treeSortsDirectoriesFirstAndFiltersTraversalRows() {
        val rows = ArchiveTreeNode.fromEntries(
            listOf(
                Triple("b.txt", false, 1),
                Triple("folder/note.txt", false, 2),
                Triple("folder", true, 0),
                Triple("../escape.txt", false, 3),
                Triple("a.txt", false, 4),
            ),
        )
        assertEquals(3, rows.size)
        assertEquals("folder", rows[0].name)
        assertTrue(rows[0].isDirectory)
        assertEquals(listOf("a.txt", "b.txt"), rows.drop(1).map { it.name })
        assertEquals(listOf("note.txt"), rows[0].children?.map { it.name })
    }

    @Test fun treeNormalizesBackslashesAndSkipsEmptyParts() {
        val rows = ArchiveTreeNode.fromEntries(
            listOf(
                Triple("dir\\sub\\file.txt", false, 9),
                Triple("./weird//path.txt", false, 1),
            ),
        )
        assertEquals(2, rows.size)
        val dir = rows.first { it.name == "dir" }
        assertEquals("dir/sub/file.txt", dir.children!!.single().children!!.single().path)
    }

    // ---- controller states ----------------------------------------------

    @Test fun openPublishesTheBoundedListing() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        val o = owner()
        assertTrue(h.controller.open(o, "docs/report.zip", token = 1))
        val listed = h.controller.state.value as WorkspaceArchiveState.Listed
        assertEquals(2, listed.entryCount)
        assertEquals("docs/read me.txt", listed.entries.last().path)
        assertEquals("zip", listed.format)
    }

    @Test fun staleOwnerFailsOwnerWithoutAnyBridgeCall() = runBlocking {
        val h = harness(epoch = 42L)
        val o = owner(epoch = 41L)
        assertFalse(h.controller.open(o, "docs/report.zip", token = 1))
        val failed = h.controller.state.value as WorkspaceArchiveState.ListingFailed
        assertEquals(ArchiveFailure.OWNER, failed.failure)
        assertFalse(failed.retryable)
        assertTrue(h.transport.calls.isEmpty())
    }

    @Test fun temporaryTaskIsRefusedLikeEveryOtherDocumentSurface() = runBlocking {
        val h = harness(temporary = true)
        assertFalse(h.controller.open(owner(), "docs/report.zip", token = 1))
        assertEquals(
            ArchiveFailure.OWNER,
            (h.controller.state.value as WorkspaceArchiveState.ListingFailed).failure,
        )
    }

    @Test fun unsupportedExtensionFailsBeforeAnyBridgeCall() = runBlocking {
        val h = harness()
        assertFalse(h.controller.open(owner(), "docs/program.exe", token = 1))
        val failed = h.controller.state.value as WorkspaceArchiveState.ListingFailed
        assertEquals(ArchiveFailure.UNSUPPORTED, failed.failure)
        assertTrue(h.transport.calls.isEmpty())
    }

    @Test fun retiredListingKeepsOwnerFailureAndDoesNotReplay() = runBlocking {
        val h = harness()
        h.transport.failures["g04.archive.listing"] = WorkspaceArchiveHostFailure("retired")
        val o = owner()
        assertTrue(h.controller.open(o, "docs/report.zip", token = 1))
        val failed = h.controller.state.value as WorkspaceArchiveState.ListingFailed
        assertEquals(ArchiveFailure.OWNER, failed.failure)
        assertTrue(h.transport.calls.size == 1)

        h.transport.failures.clear()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.controller.retry(1)
        assertEquals(failed, h.controller.state.value)
        assertEquals(1, h.transport.calls.count { it.contains("g04.archive.listing") })
    }

    @Test fun transportFailureRetryReopensWithTheSameCurrentOwner() = runBlocking {
        val h = harness()
        h.transport.failures["g04.archive.listing"] = WorkspaceArchiveHostFailure("transport")
        val o = owner()
        assertTrue(h.controller.open(o, "docs/report.zip", token = 1))
        val failed = h.controller.state.value as WorkspaceArchiveState.ListingFailed
        assertEquals(ArchiveFailure.TRANSPORT, failed.failure)
        assertTrue(failed.retryable)
        h.transport.failures.clear()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.controller.retry(1)
        assertTrue(h.controller.state.value is WorkspaceArchiveState.Listed)
        assertEquals(2, h.transport.calls.count { it.contains("g04.archive.listing") })
    }

    @Test fun needsCoreUpdateMapsToTheTypedSurface() = runBlocking {
        val h = harness()
        h.transport.failures["g04.archive.listing"] = WorkspaceArchiveHostFailure("unsupportedVersion")
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        val failed = h.controller.state.value as WorkspaceArchiveState.ListingFailed
        assertEquals(ArchiveFailure.NEEDS_CORE_UPDATE, failed.failure)
    }

    @Test fun extractPublishesTheRealReceiptAndStaysListed() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.transport.responses["g04.archive.extract"] = """
            {"ok":true,"version":25,"operation":"g04.archive.extract","destination":"report-unpacked",
             "summary":"status=ok action=extract format=zip entries=2 skipped=0 uncompressedBytes=12",
             "entries":2,"skipped":0,"uncompressedBytes":12}
        """.trimIndent()
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.extractConfirmed(1)
        val listed = h.controller.state.value as WorkspaceArchiveState.Listed
        val receipt = listed.extractReceipt!!
        assertEquals("report-unpacked", receipt.destination)
        assertEquals(2, receipt.entries)
        assertEquals(12L, receipt.uncompressedBytes)
        assertNull(listed.extracting)
        assertNull(listed.extractFailure)
        assertEquals(2, listed.entryCount)
    }

    @Test fun singleFileArchiveDecompressesToAFileReceipt() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse("gz")
        h.transport.responses["g04.archive.decompress"] = """
            {"ok":true,"version":25,"operation":"g04.archive.decompress","destination":"report",
             "summary":"status=ok action=extract format=gz entries=1 skipped=0 uncompressedBytes=5",
             "entries":1,"skipped":0,"uncompressedBytes":5}
        """.trimIndent()
        assertTrue(h.controller.open(owner(), "docs/report.gz", token = 1))
        h.controller.extractConfirmed(1)
        val receipt = (h.controller.state.value as WorkspaceArchiveState.Listed).extractReceipt!!
        assertEquals("report", receipt.destination)
    }

    @Test fun cancelledExtractIsTypedCancelledNeverSuccess() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.transport.failures["g04.archive.extract"] = WorkspaceArchiveHostFailure("cancelled")
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.extractConfirmed(1)
        val listed = h.controller.state.value as WorkspaceArchiveState.Listed
        assertNull(listed.extractReceipt)
        assertEquals(ArchiveFailure.CANCELLED, listed.extractFailure?.failure)
        assertFalse(listed.extractFailure?.retryable == true)
    }

    @Test fun conflictFailureIsTypedAndRetryableFromTheEngine() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.transport.failures["g04.archive.extract"] = WorkspaceArchiveHostFailure("conflict")
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.extractConfirmed(1)
        val listed = h.controller.state.value as WorkspaceArchiveState.Listed
        assertEquals(ArchiveFailure.CONFLICT, listed.extractFailure?.failure)
        assertNull(listed.extractReceipt)
    }

    @Test fun staleCloseTokenIsANoOp() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.close(999)
        assertTrue(h.controller.state.value is WorkspaceArchiveState.Listed)
        h.controller.close(1)
        assertEquals(WorkspaceArchiveState.Idle, h.controller.state.value)
    }

    @Test fun previewEntryPublishesReadyState() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.transport.responses["g04.archive.previewEntry"] = """
            {"ok":true,"version":25,"operation":"g04.archive.previewEntry",
             "previewable":true,"byteCount":12,"truncated":false,"text":"hello world"}
        """.trimIndent()
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.previewEntry("docs/read me.txt")
        val ready = h.controller.preview.value as WorkspaceArchivePreviewState.Ready
        assertEquals("hello world", ready.text)
        assertFalse(ready.truncated)
    }

    @Test fun previewBinaryEntryIsHonestUnavailable() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        h.transport.responses["g04.archive.previewEntry"] = """
            {"ok":true,"version":25,"operation":"g04.archive.previewEntry",
             "previewable":false,"byteCount":99,"truncated":false,"message":"notUTF8"}
        """.trimIndent()
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        h.controller.previewEntry("docs/logo.png")
        val unavailable = h.controller.preview.value as WorkspaceArchivePreviewState.Unavailable
        assertEquals("notUTF8", unavailable.message)
    }

    @Test fun rootStopDrainsToIdle() = runBlocking {
        val h = harness()
        h.transport.responses["g04.archive.listing"] = listingResponse()
        assertTrue(h.controller.open(owner(), "docs/report.zip", token = 1))
        assertTrue(h.controller.prepareForRootStop())
        assertEquals(WorkspaceArchiveState.Idle, h.controller.state.value)
        assertEquals(WorkspaceArchivePreviewState.Idle, h.controller.preview.value)
    }

    // ---- client guards ---------------------------------------------------

    @Test fun clientRejectsVersionMismatchAndInvalidPayloads() {
        val transport = FakeArchiveTransport()
        val client = WorkspaceArchiveHostClient(transport)
        transport.responses["handshake"] = """
            {"ok":true,"version":24,"operation":"handshake"}
        """.trimIndent()
        val mismatch = runCatching { client.handshake() }
        assertTrue(mismatch.exceptionOrNull() is WorkspaceArchiveHostFailure)
        assertEquals("unsupportedVersion", (mismatch.exceptionOrNull() as WorkspaceArchiveHostFailure).code)

        transport.responses.clear()
        transport.responses["handshake"] = "not-json"
        val invalid = runCatching { client.handshake() }
        assertEquals("invalidResponse", (invalid.exceptionOrNull() as WorkspaceArchiveHostFailure).code)
    }

    @Test fun failureMappingStaysTotal() {
        val h = harness()
        assertEquals(ArchiveFailure.OWNER, h.controller.mapFailure("retired"))
        assertEquals(ArchiveFailure.OWNER, h.controller.mapFailure("ownerChanged"))
        assertEquals(ArchiveFailure.UNSUPPORTED, h.controller.mapFailure("unsupportedFormat"))
        assertEquals(ArchiveFailure.NOT_FOUND, h.controller.mapFailure("notFound"))
        assertEquals(ArchiveFailure.CANCELLED, h.controller.mapFailure("cancelled"))
        assertEquals(ArchiveFailure.TOO_LARGE, h.controller.mapFailure("tooLarge"))
        assertEquals(ArchiveFailure.CONFLICT, h.controller.mapFailure("alreadyExists"))
        assertEquals(ArchiveFailure.NEEDS_CORE_UPDATE, h.controller.mapFailure("coreUnavailable"))
        assertEquals(ArchiveFailure.NEEDS_CORE_UPDATE, h.controller.mapFailure("runtimeUnavailable"))
        assertEquals(ArchiveFailure.TRANSPORT, h.controller.mapFailure("transport"))
        assertEquals(ArchiveFailure.FAILED, h.controller.mapFailure("anything-else"))
    }
}
