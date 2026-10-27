// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lane 17 lifecycle regression over the REAL production coordinator
 * ([RunOutputPdfLaunchRegistry]) and the REAL staging gate
 * ([RunOutputOfficeSnapshotStager] in its PDF format mode) — no mirrored
 * logic: these ARE the objects [RunOutputPdfPreviewController] and
 * [RunOutputPdfPreviewActivity] drive. Covers the exact Main contract:
 * opaque live-launch ownership (never Intent/path authority), the captured
 * owner fence re-checked at claim/attach, UI close NOT being print finish
 * (an admitted print retains the snapshot until the exactly-once finish
 * settles), rotation-safe renderer lease joining, exactly-once cleanup
 * decisions, honest expiry after process death, and the closed PDF MIME/
 * extension agreement + `%PDF-` magic + clean EOF staging proofs.
 */
class RunOutputPdfLaunchRegistryTest {

    private val conversation = "11111111-2222-3333-4444-555555555555"
    private val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private val output = "f".repeat(64)

    private fun staged(token: String = UUID.randomUUID().toString()) = RunOutputPdfStaged(
        launchToken = token,
        sessionDirectory = File("/data/user/0/com.floe.android/files/RunOutputPdfPreview/$token"),
        file = File("/data/user/0/com.floe.android/files/RunOutputPdfPreview/$token/document.pdf"),
        bytes = 1234L,
        sha256 = "0".repeat(64),
        displayName = "report.pdf",
        conversationID = conversation,
        runID = run,
        outputID = output,
    )

    /**
     * The real chain: admit -> publish -> claim(Live) -> attach -> close ->
     * quiesce -> exactly one cleanup decision. A second close/quiesce never
     * re-hands the snapshot; a concurrent open is refused while live.
     */
    @Test
    fun happyPathLeaseJoinHandsCleanupExactlyOnce() {
        val registry = RunOutputPdfLaunchRegistry()
        val owner = { true }
        val id = registry.admitStaging()
        assertTrue(id != 0L)
        assertTrue(registry.slotBusy())
        // A second open while staging is a typed refusal, nothing starts.
        assertEquals(0L, registry.admitStaging())
        val snap = staged()
        assertTrue(registry.publishLive(id, snap, owner))
        assertTrue(registry.claim(snap.launchToken) is RunOutputPdfClaim.Live)
        assertFalse(registry.drainPurges().isNotEmpty())
        assertTrue(registry.attachRenderer(snap.launchToken))
        assertTrue(registry.slotBusy())
        assertEquals(0L, registry.admitStaging()) // busy while live
        // User closes: slot frees, but the attached host has not drained.
        registry.userClose(snap.launchToken)
        assertFalse(registry.slotBusy())
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
        // The renderer's quiescent release join is the LAST owner: cleanup
        // is handed exactly once; later settles are no-ops.
        registry.rendererQuiesced(snap.launchToken)
        val handed = registry.drainPurges()
        assertEquals(1, handed.size)
        assertEquals(snap, handed.first())
        registry.rendererQuiesced(snap.launchToken) // late duplicate
        registry.userClose(snap.launchToken)         // late duplicate close
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
    }

    /**
     * UI close is NOT print finish: with an attempt counted, closing the
     * screen RETAINS the snapshot; only the exactly-once PrintFinish
     * settlement (AdapterFinished or StartAborted both flow through here)
     * releases it — even when that arrives after the viewer is gone.
     */
    @Test
    fun admittedPrintOutlivesUiCloseAndSettlesOnce() {
        val registry = RunOutputPdfLaunchRegistry()
        val id = registry.admitStaging()
        val snap = staged()
        assertTrue(registry.publishLive(id, snap, { true }))
        assertTrue(registry.attachRenderer(snap.launchToken))
        assertTrue(registry.beginPrint(snap.launchToken))
        // Host drains while the dialog is open: print still owns the file.
        registry.rendererQuiesced(snap.launchToken)
        registry.userClose(snap.launchToken)
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
        // The framework finish arrives late (screen already gone).
        registry.finishPrint(snap.launchToken)
        val handed = registry.drainPurges()
        assertEquals(listOf(snap), handed)
        registry.finishPrint(snap.launchToken) // late duplicate finish
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
    }

    /**
     * A refused print admission (beginPrint false on an expired launch)
     * counts nothing: a later finish cannot fabricate a release, and the
     * close decision stays with the actual owners.
     */
    @Test
    fun beginPrintRefusedOnRetiredLaunchCountsNothing() {
        val registry = RunOutputPdfLaunchRegistry()
        val id = registry.admitStaging()
        val snap = staged()
        var current = true
        assertTrue(registry.publishLive(id, snap, { current }))
        current = false
        assertFalse(registry.beginPrint(snap.launchToken))
        // The claim path already closed it (owner false): cleanup was handed
        // at the fence check — nothing may render or print after.
        assertTrue(registry.drainPurges().contains(snap))
        registry.finishPrint(snap.launchToken)
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
        // Claiming again is the honest expired state.
        assertTrue(registry.claim(snap.launchToken) is RunOutputPdfClaim.Expired)
        assertFalse(registry.attachRenderer(snap.launchToken))
    }

    /**
     * Process death / restored Intent: a FRESH registry (new process
     * generation) resolves ANY token as Expired — no launch ownership is
     * ever reconstructed from the Intent's bytes, and nothing is purged or
     * rendered.
     */
    @Test
    fun restoredTokenNeverResurrectsALaunch() {
        val first = RunOutputPdfLaunchRegistry()
        val id = first.admitStaging()
        val snap = staged()
        assertTrue(first.publishLive(id, snap, { true }))
        val second = RunOutputPdfLaunchRegistry()
        assertTrue(second.claim(snap.launchToken) is RunOutputPdfClaim.Expired)
        assertTrue(second.claim(null) is RunOutputPdfClaim.Expired)
        assertTrue(second.claim("not-a-token") is RunOutputPdfClaim.Expired)
        assertFalse(second.attachRenderer(snap.launchToken))
        assertFalse(second.beginPrint(snap.launchToken))
        assertEquals(emptyList<RunOutputPdfStaged>(), second.drainPurges())
    }

    /**
     * Owner retired BEFORE the viewer ever attached: the claim expires the
     * launch and its never-watched snapshot becomes cleanup-eligible
     * immediately (no leak), while the screen only ever shows the honest
     * expired state.
     */
    @Test
    fun ownerExpiryBeforeFirstRenderCleansRightThere() {
        val registry = RunOutputPdfLaunchRegistry()
        val id = registry.admitStaging()
        val snap = staged()
        assertTrue(registry.publishLive(id, snap, { false }))
        assertTrue(registry.claim(snap.launchToken) is RunOutputPdfClaim.Expired)
        val handed = registry.drainPurges()
        assertEquals(listOf(snap), handed)
        assertFalse(registry.slotBusy())
    }

    /**
     * Rotation model: a NEW screen instance attaches while the old host is
     * still draining (two renderer leases); the live launch's close waits
     * for BOTH drains. Nothing unlinks mid-rotation and no admitted print
     * is ever unwound by the UI moving.
     */
    @Test
    fun rotationReattachWaitsForBothHostsAndKeepsPrint() {
        val registry = RunOutputPdfLaunchRegistry()
        val id = registry.admitStaging()
        val snap = staged()
        assertTrue(registry.publishLive(id, snap, { true }))
        assertTrue(registry.attachRenderer(snap.launchToken))
        assertTrue(registry.beginPrint(snap.launchToken))
        assertTrue(registry.claim(snap.launchToken) is RunOutputPdfClaim.Live)
        assertTrue(registry.attachRenderer(snap.launchToken)) // new instance
        registry.rendererQuiesced(snap.launchToken)           // old instance
        registry.userClose(snap.launchToken)                  // user closes during print
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
        registry.finishPrint(snap.launchToken)
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges()) // one host left
        registry.rendererQuiesced(snap.launchToken)
        val handed = registry.drainPurges()
        assertEquals(listOf(snap), handed)
    }

    /**
     * The staging-failure screen: honest path-free code answers the claim,
     * it has NO snapshot of its own to purge, closing frees the slot for
     * the next open, and a stale ticket can never publish anything.
     */
    @Test
    fun stageFailedScreenClosesCleanlyAndStaleTicketPublishRefuses() {
        val registry = RunOutputPdfLaunchRegistry()
        val id = registry.admitStaging()
        // Abandon first (owner retired mid-stage), then the late worker's
        // publish attempts must be refused for BOTH kinds.
        assertTrue(registry.abandonStaging(id))
        val late = staged()
        assertFalse(registry.publishLive(id, late, { true }))
        assertNull(registry.publishFailed(id, "source", { true }))
        assertFalse(registry.pendingActive(id))
        // A fresh admission publishes an honest failure screen.
        val id2 = registry.admitStaging()
        val token = registry.publishFailed(id2, "format", { true })
        assertNotNull(token)
        val claim = registry.claim(token)
        assertTrue(claim is RunOutputPdfClaim.StageFailed && (claim as RunOutputPdfClaim.StageFailed).code == "format")
        registry.userClose(token!!)
        assertFalse(registry.slotBusy())
        assertEquals(emptyList<RunOutputPdfStaged>(), registry.drainPurges())
        // And a second failure screen is claimable after the slot frees.
        val id3 = registry.admitStaging()
        assertNotNull(registry.publishFailed(id3, "source", { true }))
    }

    /** The closed PDF agreement rule the router + card gate share. */
    @Test
    fun pdfAgreementIsBothMimeAndExtensionNeverEitherAlone() {
        assertTrue(runOutputPdfOpenAgreement("application/pdf", "报告.pdf"))
        assertTrue(runOutputPdfOpenAgreement("application/pdf", "Report.PDF"))
        assertFalse(runOutputPdfOpenAgreement("application/pdf", "report.txt"))
        assertFalse(runOutputPdfOpenAgreement("text/plain", "report.pdf"))
        assertFalse(runOutputPdfOpenAgreement("application/octet-stream", "report.pdf"))
        assertFalse(runOutputPdfOpenAgreement("application/pdf", "pdf"))
        assertFalse(runOutputPdfOpenAgreement("application/pdf", ""))
        assertFalse(runOutputPdfOpenAgreement(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "a.docx"))
    }

    // ------------------------------------------------------------------
    // The REAL stager in PDF mode (scripted owned egress + real files)
    // ------------------------------------------------------------------

    private val pdfPayload = ByteArray(70_000) { (it % 211).toByte() }
        .also { "%PDF-1.7".toByteArray().copyInto(it, 0) }

    private fun sha(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun pdfInfoJson(
        name: String = "report.pdf",
        bytes: Long = pdfPayload.size.toLong(),
        digest: String = sha(pdfPayload),
        mime: String = RunOutputOfficeSnapshotStager.PDF_MIME,
    ): String = """{"ok":1,"schema":"floe.run-output.egress.v1","conversationID":"$conversation",
        "runID":"$run","outputID":"$output","producerCallID":"call-1",
        "producerTool":"workspace.publishOutput","slot":"document","displayName":"$name",
        "mimeType":"$mime","byteCount":$bytes,"sha256":"$digest",
        "relativePath":"RunOutputs/$run/$output/$name"}"""

    private class ScriptedChannel(
        var info: String,
        val data: ByteArray,
    ) : RunOutputEgressChannel {
        var closes = 0
        override fun list(epoch: Long, conversationID: String, runID: String, reply: ByteArray) = -701
        override fun open(epoch: Long, conversationID: String, runID: String, outputID: String) = 42L
        override fun info(ticket: Long, reply: ByteArray): Int {
            val bytes = info.toByteArray()
            bytes.copyInto(reply)
            return bytes.size
        }
        override fun read(ticket: Long, offset: Long, target: ByteArray): Int {
            if (offset >= data.size) return 0
            val count = minOf(target.size.toLong(), data.size - offset).toInt()
            data.copyInto(target, 0, offset.toInt(), offset.toInt() + count)
            return count
        }
        override fun close(ticket: Long): Int {
            closes++
            return 0
        }
    }

    private fun owner() = RunOutputOfficeSnapshotStager.Owner(
        conversation, run, output, nativeEpoch = 7, hostGeneration = 1)

    private fun tempRoot(): File =
        File(System.getProperty("java.io.tmpdir"), "ro-pdf-${System.nanoTime()}")
            .also { it.mkdirs() }

    private fun pdfStager(root: File, channel: RunOutputEgressChannel) = RunOutputOfficeSnapshotStager(
        root, channel, RunOutputOfficeSnapshotStager.PDF_FORMAT_EXTENSIONS)

    @Test
    fun agreedPdfStagesImmutableVerifiedSnapshot() {
        val root = tempRoot()
        try {
            val channel = ScriptedChannel(pdfInfoJson(), pdfPayload)
            val snapshot = pdfStager(root, channel).stage(owner()) { true }
            assertEquals("report.pdf", snapshot.displayName)
            assertEquals(pdfPayload.size.toLong(), snapshot.bytes)
            assertEquals(sha(pdfPayload), snapshot.sha256)
            assertTrue(snapshot.file.name == "document.pdf")
            assertTrue(snapshot.file.readBytes().contentEquals(pdfPayload))
            assertFalse("immutable snapshot must be read-only", snapshot.file.canWrite())
            assertEquals(1, channel.closes)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun pdfMimeExtensionDisagreementRefusesBeforeAnyBytes() {
        val root = tempRoot()
        try {
            // A pdf-NAMED sealed output whose host header declares another
            // MIME is refused WHOLE (closed agreement, never either alone).
            val channel = ScriptedChannel(pdfInfoJson(mime = "text/plain"), pdfPayload)
            val failure = runCatching { pdfStager(root, channel).stage(owner()) { true } }
                .exceptionOrNull()
            assertTrue(failure is RunOutputOfficeSnapshotStager.Failure)
            assertEquals("invalidPdfFormat",
                (failure as RunOutputOfficeSnapshotStager.Failure).code)
            assertEquals(1, channel.closes) // opened the lease, then refused
            assertEquals(0, root.walk().filter { it != root }.count())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun nonPdfBytesUnderPdfIdentityRefuseAndCleanOwnDirectory() {
        val root = tempRoot()
        try {
            val notPdf = ByteArray(70_000) { (it % 199).toByte() } // no %PDF- head
            val channel = ScriptedChannel(pdfInfoJson(digest = sha(notPdf)), notPdf)
            val failure = runCatching { pdfStager(root, channel).stage(owner()) { true } }
                .exceptionOrNull()
            assertEquals("invalidPdfMagic",
                (failure as RunOutputOfficeSnapshotStager.Failure).code)
            assertEquals(1, channel.closes)
            // Only the stager's own random directory existed; it is gone.
            assertEquals(0, root.walk().filter { it != root }.count())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun defaultOfficeInstanceStillRefusesPdfAndPdfInstanceRefusesOfficeNames() {
        val root = tempRoot()
        try {
            // consumer12's reviewed Office route is UNCHANGED: pdf never
            // stages there (the default format set is the OOXML triple).
            val officeChannel = ScriptedChannel(pdfInfoJson(), pdfPayload)
            val officeFailure = runCatching {
                RunOutputOfficeSnapshotStager(root, officeChannel).stage(owner()) { true }
            }.exceptionOrNull()
            assertEquals("invalidOfficeFormat",
                (officeFailure as RunOutputOfficeSnapshotStager.Failure).code)
            // The PDF instance refuses an Office-named output the same way.
            val docxInfo = pdfInfoJson(name = "report.docx")
            val pdfChannel = ScriptedChannel(docxInfo, pdfPayload)
            val pdfFailure = runCatching {
                pdfStager(root, pdfChannel).stage(owner()) { true }
            }.exceptionOrNull()
            assertEquals("invalidOfficeFormat",
                (pdfFailure as RunOutputOfficeSnapshotStager.Failure).code)
            assertEquals(2, officeChannel.closes + pdfChannel.closes)
            assertEquals(0, root.walk().filter { it != root }.count())
        } finally {
            root.deleteRecursively()
        }
    }
}
