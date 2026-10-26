// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.OfficeEditState
import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy
import com.floe.android.core.officeengine.OfficeHostSaveVerdict
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.safgateway.AccessProbe
import com.floe.android.safgateway.ChildScan
import com.floe.android.safgateway.GrantSnapshot
import com.floe.android.safgateway.OpResult
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.ReadOpen
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCapabilities
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafProviderFlagBits
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.TakeOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the Save-Copy host handoff core ([OfficeSaveCopyHandoff]):
 * OUTPUT_READY-before-prepare ordering, exact live-session/op/native-generation
 * fencing, canonical bounded private-output ownership, App per-save ordinals
 * distinct from the native generation, launch-captured identities, one-shot
 * delivery, foreground-only RESULT_OK trust, honest verdict mapping (only
 * destination read-back yields COPY_SAVED), session-close cancellation and
 * post-IO drain release with ZERO deletion of module-owned verified bytes.
 * JVM-only: the Android adapter's binder plumbing (parentBinder, bindService,
 * registerHostChannel on every onServiceConnected) is compile/review-verified
 * and belongs to Main's device acceptance; the inline scheduler exercises the
 * same core code paths.
 */
class OfficeSaveCopyHostTest {

    // ---- deterministic in-memory provider (same shape as the controller test) --

    private class FakeDoc(val uriString: String, var name: String, var content: ByteArray)

    private class FakeBackend : SafPlatformBackend {
        val docs = LinkedHashMap<String, FakeDoc>()
        val session = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        val persisted = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        /** Mutate the destination content when its write stream closes (provider drift). */
        var afterWriteCommit: ((FakeDoc) -> Unit)? = null

        fun seed(uri: String, name: String, content: ByteArray): FakeDoc =
            FakeDoc(uri, name, content).also { docs[uri] = it }

        override fun classifyUri(uriString: String): SafUriKind = when {
            !uriString.startsWith("content://") -> SafUriKind.NON_SAF
            "/tree/" in uriString -> SafUriKind.TREE
            "/document/" in uriString -> SafUriKind.DOCUMENT
            else -> SafUriKind.UNKNOWN
        }

        override fun persistedGrants(): List<GrantSnapshot> =
            persisted.map { (uri, flags) ->
                GrantSnapshot(SafUriRef(uri), read = SafAccessFlag.READ in flags, write = SafAccessFlag.WRITE in flags)
            }

        override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome =
            if (session[uri.uriString]?.contains(flag) == true) {
                persisted.getOrPut(uri.uriString) { mutableSetOf() } += flag
                TakeOutcome.Persisted
            } else {
                TakeOutcome.Refused("flag not granted by the system result")
            }

        override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean {
            val flags = persisted[uri.uriString] ?: return false
            flags -= flag
            if (flags.isEmpty()) persisted.remove(uri.uriString)
            return true
        }

        override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? = null
        override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef? = null
        override fun documentIdOf(uri: SafUriRef): String? = null
        override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe =
            AccessProbe(ProbeFlag.UNKNOWN, ProbeFlag.UNKNOWN)

        override fun queryChildDocuments(
            tree: SafUriRef, parentDocumentId: String?, limit: Int, cursorToken: String?, cancel: SafCancelToken,
        ): ChildScan = ChildScan(emptyList(), null, truncatedByLimit = false, note = null)

        override fun releaseCursor(cursorToken: String): Boolean = false
        override fun releaseAllCursors() {}

        override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? {
            val doc = docs[ref.uri.uriString] ?: return null
            return SafDocument(
                ref = ref,
                displayName = doc.name,
                mimeType = "application/octet-stream",
                size = SafSize.Known(doc.content.size.toLong()),
                lastModifiedMillis = null,
                capabilities = SafCapabilities.fromProviderFlags(SafProviderFlagBits.SUPPORTS_WRITE),
            )
        }

        override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef, cancel: SafCancelToken): Boolean = false

        override fun openRead(ref: SafDocumentRef, mimeFilter: String?, cancel: SafCancelToken): ReadOpen {
            val doc = docs[ref.uri.uriString] ?: return ReadOpen.NotFound
            return ReadOpen.Opened(ByteArrayInputStream(doc.content), doc.content.size.toLong())
        }

        override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
            val doc = docs[ref.uri.uriString] ?: return WriteOpen.NotFound
            return WriteOpen.Opened(object : OutputStream() {
                private val buffer = ByteArrayOutputStream()
                override fun write(b: Int) = buffer.write(b)
                override fun write(b: ByteArray, off: Int, len: Int) = buffer.write(b, off, len)
                override fun close() {
                    doc.content = buffer.toByteArray()
                    afterWriteCommit?.invoke(doc)
                }
            })
        }

        override fun streamTypes(ref: SafDocumentRef): List<String> = emptyList()
        override fun createDocument(
            tree: SafUriRef, parentDocumentId: String?, mimeType: String, displayName: String, cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> = OpResult.NullReturned("not used")
        override fun renameDocument(ref: SafDocumentRef, newName: String, cancel: SafCancelToken): OpResult<SafDocumentRef> =
            OpResult.NullReturned("not used")
        override fun moveDocument(
            ref: SafDocumentRef, destTree: SafUriRef, destParentDocumentId: String?, cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> = OpResult.NullReturned("not used")
        override fun copyDocument(
            ref: SafDocumentRef, destTree: SafUriRef, destParentDocumentId: String?, cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> = OpResult.NullReturned("not used")
        override fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean> = OpResult.Ok(false)
        override fun selfCheck(): List<String> = emptyList()
    }

    // ---- fixture ------------------------------------------------------------

    private val TOKEN = "11111111-2222-3333-4444-555555555555"
    private val NATIVE_GEN = 7L
    private val DEST = "content://fake.provider/document/save-copy-dest"
    private val READ_WRITE_PERSISTABLE =
        com.floe.android.safgateway.SafGrantFlagBits.GRANT_READ or
            com.floe.android.safgateway.SafGrantFlagBits.GRANT_WRITE or
            com.floe.android.safgateway.SafGrantFlagBits.PERSISTABLE
    private val RESULT_OK = -1
    private val RESULT_CANCELLED = 0

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private inner class Fixture(val runInline: Boolean = true) {
        val outputsRoot = newDir("office-host-outputs")
        val stagingRoot = newDir("office-host-staging")
        val backend = FakeBackend()
        val service = SafGatewayService(backend)
        val alive = AtomicBoolean(true)
        val queued = mutableListOf<(SafCancelToken) -> Unit>()
        val settlements = mutableListOf<OfficeSaveCopySettlement>()
        /** Quiescent-drain idle notifications (the adapter's connection-release seam). */
        val idleNotifications = AtomicInteger(0)
        /** When set, the settlement sink throws this instead of recording (lifecycle test). */
        var sinkFailure: Throwable? = null
        val handoff = OfficeSaveCopyHandoff(
            service = service,
            backend = backend,
            stagingRoot = stagingRoot,
            outputsRoot = outputsRoot,
            scheduler = { block ->
                if (runInline) {
                    block(SafCancelToken())
                } else {
                    queued += block
                }
                true
            },
            settlementSink = {
                sinkFailure?.let { throw it }
                settlements += it
            },
            onSessionsIdle = { idleNotifications.incrementAndGet() },
        )

        fun drainQueued() {
            val blocks = queued.toList()
            queued.clear()
            blocks.forEach { it(SafCancelToken()) }
        }

        /** Writes a well-shaped private module output and returns (path, bytes, sha). */
        fun moduleOutput(
            op: String,
            content: ByteArray,
            generation: Long = NATIVE_GEN,
            format: String = "docx",
        ): Triple<String, ByteArray, String> {
            val dir = File(outputsRoot, generation.toString())
            check(dir.isDirectory || dir.mkdirs())
            val file = File(dir, "$op-1234.$format")
            file.writeBytes(content)
            return Triple(file.path, content, sha256(content))
        }

        /** Opens the exact-session controller (once per session token). */
        fun openSession(original: OfficeSaveCopyOriginal? = null): Boolean =
            handoff.beginSession(TOKEN, "Report.docx", original) { alive.get() }

        /** Stages one module OUTPUT_READY artifact + receipt for an open session. */
        fun stageReceipt(op: String, content: ByteArray): Triple<String, ByteArray, String> {
            val staged = moduleOutput(op, content)
            assertTrue(
                "OUTPUT_READY receipt must bind",
                handoff.onReceipt(receipt(op, staged.first, staged.third, staged.second.size.toLong())),
            )
            return staged
        }

        /** Convenience for a first save: open the session AND stage the receipt. */
        fun begin(content: ByteArray, op: String = "export-1"): Triple<String, ByteArray, String> {
            assertTrue(openSession())
            return stageReceipt(op, content)
        }

        fun grantDestination(uri: String = DEST) {
            backend.session.getOrPut(uri) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        }
    }

    private fun receipt(
        op: String,
        path: String?,
        sha: String?,
        bytes: Long,
        state: OfficeSaveState = OfficeSaveState.OUTPUT_READY,
        operation: OfficeSaveOperation = OfficeSaveOperation.STAGED_EXPORT,
        token: String = TOKEN,
        generation: Long = NATIVE_GEN,
        format: String = "docx",
    ) = OfficeSaveReceipt(
        opId = op,
        sessionToken = token,
        generation = generation,
        operation = operation,
        state = state,
        format = format,
        suggestedName = "Report.docx",
        expectedBaseSha256 = null,
        workingCopySha256 = null,
        workingCopyBytes = 0,
        outputDocumentPath = path,
        outputSha256 = sha,
        outputBytes = bytes,
        failure = null,
        message = null,
        cancelRequested = false,
        attestation = "jni-saveas-sync+output-verified",
        submittedAtElapsedMs = 1L,
        completedAtElapsedMs = 2L,
    )

    private fun prepare(op: String, token: String = TOKEN, generation: Long = NATIVE_GEN, format: String = "docx") =
        OfficeHostSaveHandoffPolicy.PrepareRequest(op, token, generation, format, "Report.docx")

    private fun pick(
        op: String,
        resultCode: Int = RESULT_OK,
        uri: String? = DEST,
        flags: Int = READ_WRITE_PERSISTABLE,
        token: String = TOKEN,
        generation: Long = NATIVE_GEN,
    ) = OfficeHostSaveHandoffPolicy.PickResult(op, token, generation, resultCode, uri, flags)

    // ---- ordering + happy path -------------------------------------------------

    @Test
    fun prepareWithoutStoredReceiptIsRefused() {
        val fixture = Fixture()
        assertTrue(fixture.openSession())
        // The viewer asks for a picker before any OUTPUT_READY arrived: refuse.
        assertNull(fixture.handoff.onPrepare(prepare("export-1")))
        // A receipt for a different op id does not unlock it either.
        val staged = fixture.stageReceipt("export-9", "x".toByteArray())
        assertNotNull(staged)
        assertNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertNotNull(fixture.handoff.onPrepare(prepare("export-9")))
    }

    @Test
    fun happyFlowSettlesCopySavedOnlyAfterDestinationReadback() {
        val fixture = Fixture()
        val content = ("verified-" + "v".repeat(120_000)).toByteArray()
        val (_, bytes, _) = fixture.begin(content)
        fixture.backend.seed(DEST, "dest", "old-provider-content".toByteArray())
        fixture.grantDestination()

        val prepared = fixture.handoff.onPrepare(prepare("export-1"))
        assertNotNull(prepared)
        prepared!!
        // App per-save ordinal, distinct from the native mount generation.
        assertEquals(1L, prepared.identity.generation)
        assertEquals(TOKEN, prepared.identity.sessionToken)
        assertEquals("export-1", prepared.identity.operation)
        assertEquals(PickKind.CREATE_DOCUMENT, prepared.spec.kind)

        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        assertEquals(1, fixture.settlements.size)
        val settlement = fixture.settlements[0]
        assertEquals(OfficeHostSaveVerdict.COPY_SAVED, settlement.verdict)
        assertNull(settlement.message)
        assertEquals("export-1", settlement.opId)
        assertEquals(NATIVE_GEN, settlement.nativeGeneration)
        // The provider destination actually holds the copied bytes (read-back proof).
        assertArrayEquals(bytes, fixture.backend.docs[DEST]?.content)
        // The module output file remains for recovery: the service never deletes it.
        val outputs = File(fixture.outputsRoot, NATIVE_GEN.toString()).listFiles().orEmpty()
        assertEquals(1, outputs.size)
        assertTrue(outputs[0].isFile)
        // The session stays open until the viewer closes (the user may save again).
        assertTrue(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun secondPrepareForSameOpIsRefusedAndSecondDeliveryNotAccepted() {
        val fixture = Fixture(runInline = false)
        fixture.begin("verified".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        // One prepare per op: the exact op already has a launch record.
        assertNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        // A duplicate delivery for the same launched op is refused (one-shot).
        assertFalse(fixture.handoff.onPickResult(pick("export-1")))
        // A foreign op never bound a launch record.
        assertFalse(fixture.handoff.onPickResult(pick("export-404")))
        // Drain the first op, then the native generation is fenced exactly.
        fixture.drainQueued()
        fixture.stageReceipt("export-2", "second".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-2")))
        assertFalse(fixture.handoff.onPickResult(pick("export-2", generation = 8L)))
    }

    @Test
    fun onlyResultOkCarriesTheRealUriAndFlags() {
        val fixture = Fixture()
        fixture.begin("content".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        // Cancellation: the App settles COPY_CANCELLED honestly; a non-OK result's
        // URI/flags are never treated as a grant.
        assertTrue(fixture.handoff.onPickResult(pick("export-1", resultCode = RESULT_CANCELLED, uri = DEST)))
        val settlement = fixture.settlements.single()
        assertEquals(OfficeHostSaveVerdict.COPY_CANCELLED, settlement.verdict)
        assertEquals(NATIVE_GEN, settlement.nativeGeneration)
        // The destination was never created or touched.
        assertNull(fixture.backend.docs[DEST])
        // The session remains open for a later retry (viewer still live).
        assertTrue(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun perSaveOrdinalsIncreaseAcrossOpsWhileNativeGenerationStaysTheFence() {
        val fixture = Fixture()
        fixture.begin("first".toByteArray(), op = "export-1")
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        val first = fixture.handoff.onPrepare(prepare("export-1"))!!
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        // Second save on the SAME session: new receipt, ordinal 2 (App ledger),
        // while the native fence generation is still the mount's 7.
        fixture.stageReceipt("export-2", "second".toByteArray())
        val second = fixture.handoff.onPrepare(prepare("export-2"))!!
        assertEquals(1L, first.identity.generation)
        assertEquals(2L, second.identity.generation)
        assertTrue(fixture.handoff.onPickResult(pick("export-2", uri = DEST)))
        assertEquals(2, fixture.settlements.count { it.verdict == OfficeHostSaveVerdict.COPY_SAVED })
        // Both settlements fence the SAME native generation, distinct identities.
        assertTrue(fixture.settlements.all { it.nativeGeneration == NATIVE_GEN })
    }

    @Test
    fun busyRefusesSecondPrepareUntilFirstSettles() {
        val fixture = Fixture(runInline = false)
        fixture.begin("one".toByteArray(), op = "export-1")
        fixture.stageReceipt("export-2", "two".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        // The first op is still active in the controller: one save at a time.
        assertNull(fixture.handoff.onPrepare(prepare("export-2")))
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        fixture.drainQueued()
        // Now the second one may prepare (its own ordinal 2).
        val second = fixture.handoff.onPrepare(prepare("export-2"))
        assertNotNull(second)
        assertEquals(2L, second!!.identity.generation)
    }

    // ---- receipt validation ------------------------------------------------------

    @Test
    fun receiptShapeAndOwnershipRefusalsAreFailClosed() {
        val fixture = Fixture()
        assertTrue(fixture.openSession())
        val content = "x".toByteArray()
        val (goodPath, _, goodSha) = fixture.moduleOutput("export-1", content)

        // Non-STAGED_EXPORT or non-OUTPUT_READY states never enter the ledger.
        assertFalse(fixture.handoff.onReceipt(receipt("export-2", goodPath, goodSha, 1, state = OfficeSaveState.FLUSHED)))
        assertFalse(fixture.handoff.onReceipt(receipt("export-3", goodPath, goodSha, 1, operation = OfficeSaveOperation.WORKING_COPY_FLUSH)))
        // Foreign session token.
        assertFalse(fixture.handoff.onReceipt(receipt("export-4", goodPath, goodSha, 1, token = "other-session")))
        // Missing or malformed facts.
        assertFalse(fixture.handoff.onReceipt(receipt("export-5", null, goodSha, 1)))
        assertFalse(fixture.handoff.onReceipt(receipt("export-6", goodPath, null, 1)))
        assertFalse(fixture.handoff.onReceipt(receipt("export-7", goodPath, goodSha, 0)))
        assertFalse(fixture.handoff.onReceipt(receipt("export-8", goodPath, "nothex", 1)))
        // Path outside the module outputs root.
        val escape = File(fixture.stagingRoot, "escape.docx")
        escape.writeBytes(content)
        assertFalse(fixture.handoff.onReceipt(receipt("export-9", escape.path, goodSha, content.size.toLong())))
        // Wrong generation directory under the root.
        val wrongDir = File(fixture.outputsRoot, "99")
        check(wrongDir.mkdirs())
        val misplaced = File(wrongDir, "export-10-1234.docx")
        misplaced.writeBytes(content)
        assertFalse(fixture.handoff.onReceipt(receipt("export-10", misplaced.path, goodSha, content.size.toLong())))
        // Right directory, wrong op-shaped file name.
        val wrongName = File(File(fixture.outputsRoot, NATIVE_GEN.toString()), "tampered.docx")
        wrongName.writeBytes(content)
        assertFalse(fixture.handoff.onReceipt(receipt("export-11", wrongName.path, goodSha, content.size.toLong())))
        // A symlinked output path is refused even with a matching name shape.
        val real = File(fixture.stagingRoot, "real-target.docx")
        real.writeBytes(content)
        val linked = File(File(fixture.outputsRoot, NATIVE_GEN.toString()), "export-12-1234.docx")
        assertFalse(linked.exists())
        Files.createSymbolicLink(linked.toPath(), real.toPath())
        assertFalse(fixture.handoff.onReceipt(receipt("export-12", linked.path, goodSha, content.size.toLong())))
    }

    @Test
    fun deadOwnerCannotReceiveReceiptsOrPrepare() {
        val fixture = Fixture()
        fixture.begin("content".toByteArray())
        fixture.alive.set(false)
        // A late receipt after the viewer op was replaced: refused.
        val staged = fixture.moduleOutput("export-2", "late".toByteArray())
        assertFalse(fixture.handoff.onReceipt(receipt("export-2", staged.first, staged.third, staged.second.size.toLong())))
        // A late prepare request likewise: no intent for a dead owner.
        assertNull(fixture.handoff.onPrepare(prepare("export-1")))
    }

    // ---- session close / drain -----------------------------------------------------

    @Test
    fun endSessionCancelsPreparedUnpickedAndReleasesImmediatelyWhenIdle() {
        val fixture = Fixture(runInline = false)
        fixture.begin("content".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        // Close before the user picked anything: honest COPY_CANCELLED for the exact op.
        fixture.handoff.endSession(TOKEN)
        val settlement = fixture.settlements.single()
        assertEquals(OfficeHostSaveVerdict.COPY_CANCELLED, settlement.verdict)
        assertEquals("export-1", settlement.opId)
        assertEquals(NATIVE_GEN, settlement.nativeGeneration)
        assertFalse(fixture.handoff.hasOpenSessions())
        fixture.drainQueued()
        assertEquals(1, fixture.settlements.size)
    }

    @Test
    fun sessionControllerReleasedOnlyAfterScheduledIoDrains() {
        val fixture = Fixture(runInline = false)
        fixture.begin("content".toByteArray())
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        // Delivery was accepted for processing but is still queued (in flight):
        // the session may not be released yet, and a close must not strand it.
        fixture.handoff.endSession(TOKEN)
        assertTrue(fixture.handoff.hasOpenSessions())
        assertEquals(0, fixture.settlements.size)
        // Drain: the running owner settles the EXACT op honestly at quiescence.
        // The close retired the waiting operation first, so the drained body
        // observes its own Cancelled terminal — never a fabricated success.
        fixture.drainQueued()
        val settlement = fixture.settlements.single()
        assertEquals(OfficeHostSaveVerdict.COPY_CANCELLED, settlement.verdict)
        assertArrayEquals(byteArrayOf(), fixture.backend.docs[DEST]?.content)
        assertFalse(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun deliveredAndDrainedSuccessKeepsVerifiedOutputAndReportsSaved() {
        val fixture = Fixture(runInline = false)
        fixture.begin("content".toByteArray())
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        fixture.drainQueued()
        assertEquals(OfficeHostSaveVerdict.COPY_SAVED, fixture.settlements.single().verdict)
        // Viewer closes normally after a real saved copy: nothing is deleted.
        fixture.handoff.endSession(TOKEN)
        assertTrue(File(fixture.outputsRoot, NATIVE_GEN.toString()).listFiles().orEmpty().isNotEmpty())
        assertFalse(fixture.handoff.hasOpenSessions())
    }

    // ---- quiescent-drain idle notification (Main lifecycle fix 2026-10-26) ----

    @Test
    fun idleNotificationFiresOnlyAfterQueuedIoDrains() {
        val fixture = Fixture(runInline = false)
        fixture.begin("content".toByteArray())
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        fixture.handoff.endSession(TOKEN)
        // Still draining: NO premature idle notice, so the adapter must keep
        // its command binding for this session's in-flight IO.
        assertEquals(0, fixture.idleNotifications.get())
        assertTrue(fixture.handoff.hasOpenSessions())
        assertEquals(0, fixture.settlements.size)
        // Drain: session removed, then exactly one idle notification.
        fixture.drainQueued()
        assertEquals(1, fixture.settlements.size)
        assertEquals(1, fixture.idleNotifications.get())
        assertFalse(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun idleNotificationFiresImmediatelyForIdleClose() {
        val fixture = Fixture()
        assertTrue(fixture.handoff.beginSession(TOKEN, "Report.docx", null) { true })
        fixture.handoff.endSession(TOKEN)
        assertEquals(1, fixture.idleNotifications.get())
        assertFalse(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun throwingSettlementSinkStillDrainsSessionAndPreservesFailure() {
        val fixture = Fixture(runInline = false)
        fixture.begin("content".toByteArray())
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        fixture.handoff.endSession(TOKEN)
        assertEquals(0, fixture.idleNotifications.get())
        val boom = IllegalStateException("settlement sink exploded")
        fixture.sinkFailure = boom
        val surfaced = runCatching { fixture.drainQueued() }.exceptionOrNull()
        // The original failure surfaces unchanged (never swallowed)…
        assertSame(boom, surfaced)
        // …yet the drain bookkeeping already ran: the session is released and
        // the adapter got exactly one idle notification to free its binding.
        assertFalse(fixture.handoff.hasOpenSessions())
        assertEquals(1, fixture.idleNotifications.get())
        assertTrue(fixture.settlements.isEmpty())
    }

    @Test
    fun endSessionSinkThrowingStillNotifiesIdleInFinally() {
        val fixture = Fixture()
        fixture.begin("content".toByteArray())
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        val boom = IllegalStateException("sink exploded at close")
        fixture.sinkFailure = boom
        val surfaced = runCatching { fixture.handoff.endSession(TOKEN) }.exceptionOrNull()
        assertSame(boom, surfaced)
        assertEquals(1, fixture.idleNotifications.get())
        assertFalse(fixture.handoff.hasOpenSessions())
    }

    @Test
    fun beginSessionRejectsReuseAndUnsafeTokens() {
        val fixture = Fixture()
        assertTrue(fixture.handoff.beginSession(TOKEN, "Report.docx", null) { true })
        assertFalse(fixture.handoff.beginSession(TOKEN, "Report.docx", null) { true })
        assertFalse(fixture.handoff.beginSession("bad/token", "Report.docx", null) { true })
        assertFalse(fixture.handoff.beginSession("  ", "Report.docx", null) { true })
    }

    // ---- honest failure mapping -----------------------------------------------------

    @Test
    fun sameOriginalPickIsRefusedBeforeAnyProviderWriteAndSettlesFailed() {
        val fixture = Fixture()
        val originalUri = "content://fake.provider/document/original-doc"
        fixture.backend.seed(originalUri, "original", byteArrayOf(9))
        assertTrue(
            fixture.handoff.beginSession(
                TOKEN, "Report.docx",
                OfficeSaveCopyOriginal(SafUriRef(originalUri), null),
            ) { true },
        )
        val staged = fixture.moduleOutput("export-1", "edited".toByteArray())
        assertTrue(fixture.handoff.onReceipt(receipt("export-1", staged.first, staged.third, staged.second.size.toLong())))
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1", uri = originalUri)))
        val settlement = fixture.settlements.single()
        // OUTPUT_READY + a picked target + NO read-back: this must be FAILED, never SAVED.
        assertEquals(OfficeHostSaveVerdict.COPY_FAILED, settlement.verdict)
        assertEquals("result-is-original", settlement.message)
        // No provider write happened.
        assertArrayEquals(byteArrayOf(9), fixture.backend.docs[originalUri]?.content)
    }

    @Test
    fun destinationDriftSettlesCopyFailedWithTechnicalCodeOnly() {
        val fixture = Fixture()
        fixture.begin("content".toByteArray())
        fixture.backend.seed(DEST, "dest", byteArrayOf())
        fixture.grantDestination()
        // Provider-side drift after the write makes the read-back differ.
        fixture.backend.afterWriteCommit = { it.content = it.content + byteArrayOf(0) }
        assertNotNull(fixture.handoff.onPrepare(prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(pick("export-1")))
        val settlement = fixture.settlements.single()
        assertEquals(OfficeHostSaveVerdict.COPY_FAILED, settlement.verdict)
        // The message carries only the short technical code — never a path or URI.
        assertEquals("verify-mismatch", settlement.message)
        // Failed copies keep everything recoverable: the module output survives.
        assertTrue(File(fixture.outputsRoot, NATIVE_GEN.toString()).listFiles().orEmpty().isNotEmpty())
    }

    @Test
    fun editStateOnlyBindsLiveSessions() {
        val fixture = Fixture()
        val state = OfficeEditState(TOKEN, NATIVE_GEN, "READY_EDITABLE", true, true, true, true, "true", "false")
        assertFalse(fixture.handoff.onEditState(state)) // no session yet
        assertTrue(fixture.handoff.beginSession(TOKEN, "Report.docx", null) { true })
        assertTrue(fixture.handoff.onEditState(state))
        assertFalse(fixture.handoff.onEditState(OfficeEditState("other", 1, "X", false, false, false, null, null, null)))
    }
}
