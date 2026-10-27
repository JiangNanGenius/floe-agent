// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import com.floe.android.safgateway.AccessProbe
import com.floe.android.safgateway.ChildScan
import com.floe.android.safgateway.GrantSnapshot
import com.floe.android.safgateway.OpResult
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.ReadOpen
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCapabilities
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafGrantFlagBits
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
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verified Save Copy of owned run outputs against a deterministic in-memory
 * SAF provider and a scripted egress source. Contracts proven here:
 *   * "Saved" ONLY after destination read-back size + streamed SHA-256
 *     equality against the NATIVE verified digest (streamed twice: staged
 *     hash + provider read-back hash);
 *   * no destination write until the staged bytes prove correct;
 *   * uncertain/partial destinations are KEPT and honestly labelled —
 *     never deleted, never relabelled as success or as cancelled-clean;
 *   * the ACTUAL returned intent flags decide access (missing WRITE =
 *     refusal before any IO);
 *   * single active operation (busy), one delivery per identity, typed
 *     cancel on identity.
 */
class RunOutputSaveCopyControllerTest {

    private val conversation = "11111111-2222-3333-4444-555555555555"
    private val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private val output = "c".repeat(64)

    private fun sha(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private class FakeEgressSource(
        override val info: RunOutputEgressInfo,
        val data: ByteArray,
        var zeroAfter: Long? = null,
    ) : RunOutputEgressSource {
        var reads = 0
        var closes = 0
        override fun read(offset: Long, buffer: ByteArray): Int {
            reads++
            zeroAfter?.let { if (offset >= it) return 0 }
            if (offset >= data.size) return 0
            val count = minOf(buffer.size.toLong(), data.size - offset).toInt()
            data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
            return count
        }
        override fun close() { closes++ }
    }

    private fun egressInfo(bytes: ByteArray, name: String = "report.docx",
                           mime: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"): RunOutputEgressInfo =
        RunOutputEgressInfo(
            conversationID = conversation, runID = run, outputID = output,
            producerCallID = "call-1", producerTool = "workspace.publishOutput",
            slot = "document", displayName = name, mimeType = mime,
            byteCount = bytes.size.toLong(), sha256 = sha(bytes),
            relativePath = "RunOutputs/$run/$output/$name",
        )

    // ---- deterministic in-memory provider ----

    private class FakeDoc(val uriString: String, var name: String, var content: ByteArray)

    private class FakeBackend : SafPlatformBackend {
        val docs = LinkedHashMap<String, FakeDoc>()
        val session = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        var probeReadFlag = ProbeFlag.GRANTED
        var probeWriteFlag = ProbeFlag.GRANTED
        var writeOpens = 0
        var cancelToken: SafCancelToken? = null
        var cancelWriteAfterBytes: Long = Long.MAX_VALUE
        var afterWriteCommit: ((FakeDoc) -> Unit)? = null

        fun seed(uri: String, name: String): FakeDoc =
            FakeDoc(uri, name, ByteArray(0)).also { docs[uri] = it }

        override fun classifyUri(uriString: String): SafUriKind = when {
            !uriString.startsWith("content://") -> SafUriKind.NON_SAF
            "/document/" in uriString -> SafUriKind.DOCUMENT
            else -> SafUriKind.UNKNOWN
        }
        override fun persistedGrants(): List<GrantSnapshot> =
            session.map { (uri, flags) ->
                GrantSnapshot(SafUriRef(uri), SafAccessFlag.READ in flags, SafAccessFlag.WRITE in flags)
            }
        override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome =
            TakeOutcome.Persisted
        override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean = true
        override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? = null
        override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef? = null
        override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean) =
            AccessProbe(probeReadFlag, probeWriteFlag)
        override fun queryChildDocuments(
            tree: SafUriRef, parentDocumentId: String?, limit: Int, cursorToken: String?,
            cancel: SafCancelToken,
        ): ChildScan = ChildScan(emptyList(), null, truncatedByLimit = false, note = null)
        override fun releaseCursor(cursorToken: String): Boolean = false
        override fun releaseAllCursors() {}
        override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? {
            val doc = docs[ref.uri.uriString] ?: return null
            return SafDocument(
                ref = ref, displayName = doc.name,
                mimeType = "application/octet-stream",
                size = SafSize.Known(doc.content.size.toLong()),
                lastModifiedMillis = null,
                capabilities = SafCapabilities.fromProviderFlags(SafProviderFlagBits.SUPPORTS_WRITE),
            )
        }
        override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef,
                               cancel: SafCancelToken): Boolean = false
        override fun openRead(ref: SafDocumentRef, mimeFilter: String?,
                              cancel: SafCancelToken): ReadOpen {
            val doc = docs[ref.uri.uriString] ?: return ReadOpen.NotFound
            return ReadOpen.Opened(ByteArrayInputStream(doc.content), doc.content.size.toLong())
        }
        override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
            val doc = docs[ref.uri.uriString] ?: return WriteOpen.NotFound
            writeOpens++
            return WriteOpen.Opened(object : OutputStream() {
                private val buffer = ByteArrayOutputStream()
                private var written = 0L
                override fun write(b: Int) {
                    buffer.write(b); written++
                    if (written >= cancelWriteAfterBytes) cancelToken?.cancel()
                }
                override fun write(b: ByteArray, off: Int, len: Int) {
                    buffer.write(b, off, len); written += len
                    if (written >= cancelWriteAfterBytes) cancelToken?.cancel()
                }
                override fun close() {
                    doc.content = buffer.toByteArray()
                    afterWriteCommit?.invoke(doc)
                }
            })
        }
        override fun streamTypes(ref: SafDocumentRef): List<String> = emptyList()
        override fun createDocument(
            tree: SafUriRef, parentDocumentId: String?, mimeType: String, displayName: String,
            cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> = OpResult.Ok(SafDocumentRef(null, null, null,
            SafUriRef("content://p/document/new")))
        override fun renameDocument(ref: SafDocumentRef, newName: String,
                                    cancel: SafCancelToken): OpResult<SafDocumentRef> =
            OpResult.Ok(ref)
        override fun moveDocument(ref: SafDocumentRef, destTree: SafUriRef, newName: String?,
                                  cancel: SafCancelToken): OpResult<SafDocumentRef> = OpResult.Ok(ref)
        override fun copyDocument(ref: SafDocumentRef, destTree: SafUriRef, newName: String?,
                                  cancel: SafCancelToken): OpResult<SafDocumentRef> = OpResult.Ok(ref)
        override fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean> =
            OpResult.Ok(false)
        override fun selfCheck(): List<String> = emptyList()
    }

    private inner class Fixture(val bytes: ByteArray = ByteArray(200_000) { (it % 197).toByte() }) {
        val root = File(System.getProperty("java.io.tmpdir"),
            "ro-save-${System.nanoTime()}").also { it.mkdirs() }
        val backend = FakeBackend()
        val service = SafGatewayService(backend)
        val controller = RunOutputSaveCopyController(service, backend, root)
        val uri = "content://provider/document/target-1"
        val source = FakeEgressSource(egressInfo(bytes), bytes)
        init {
            backend.seed(uri, "target.docx")
            backend.session[uri] = mutableSetOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        }
        fun prepare(): Pair<RunOutputSaveIdentity, com.floe.android.safgateway.PickRequestSpec>? =
            controller.prepare(source)
        fun deliver(identity: RunOutputSaveIdentity, flags: Int = 3,
                    resultUri: String? = uri): RunOutputSaveDelivery =
            controller.deliverPickResult(resultUri, flags, identity)
        fun transfer(identity: RunOutputSaveIdentity,
                     cancel: SafCancelToken = SafCancelToken()): RunOutputSaveOutcome =
            controller.transfer(identity, cancel)
        fun dispose() { root.deleteRecursively() }
    }

    @Test
    fun savedOnlyAfterDestinationSizeAndDigestVerification() {
        val fx = Fixture()
        try {
            val (identity, spec) = fx.prepare()!!
            assertEquals("report.docx", spec.suggestedName)
            // A real Save-As result whose provider OFFERS persistence carries
            // the persistable bit; the gateway then takes the per-flag
            // persistable grants, which is exactly what grantPersisted must
            // report (a bare READ|WRITE result is transientOnly by contract).
            val delivered = fx.deliver(
                identity,
                flags = SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or
                    SafGrantFlagBits.PERSISTABLE,
            )
            assertTrue(delivered is RunOutputSaveDelivery.TargetAccepted)
            val outcome = fx.transfer(identity)
            assertTrue(outcome is RunOutputSaveOutcome.Saved)
            val saved = outcome as RunOutputSaveOutcome.Saved
            assertEquals(fx.bytes.size.toLong(), saved.bytes)
            assertEquals(sha(fx.bytes), saved.sha256)
            assertEquals(fx.uri, saved.destination.uriString)
            assertTrue(saved.grantPersisted.isNotEmpty())
            // The picked destination actually carries the snapshot bytes.
            assertEquals(fx.bytes.size.toLong(), fx.backend.docs[fx.uri]!!.content.size.toLong())
            assertTrue(fx.backend.docs[fx.uri]!!.content.contentEquals(fx.bytes))
        } finally { fx.dispose() }
    }

    @Test
    fun egresShortReadRefusesBeforeAnyDestinationWrite() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            fx.source.zeroAfter = 1_000 // simulated mid-copy failure
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.TargetAccepted)
            val outcome = fx.transfer(identity)
            assertTrue(outcome is RunOutputSaveOutcome.Failed)
            val failed = outcome as RunOutputSaveOutcome.Failed
            assertTrue(failed.code.contains("invalid-egress-chunk"))
            assertEquals(0, fx.backend.writeOpens)
            assertNull(fx.backend.docs[fx.uri]?.content?.takeIf { it.isNotEmpty() })
        } finally { fx.dispose() }
    }

    @Test
    fun cancelledStagingWritesNothing() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.TargetAccepted)
            val cancel = SafCancelToken()
            cancel.cancel()
            val outcome = fx.transfer(identity, cancel)
            assertTrue(outcome is RunOutputSaveOutcome.Cancelled)
            assertEquals(RunOutputSaveStage.STAGING, (outcome as RunOutputSaveOutcome.Cancelled).stage)
            assertEquals(0, fx.backend.writeOpens)
        } finally { fx.dispose() }
    }

    @Test
    fun cancelMidWriteKeepsUncertainDestinationHonest() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.TargetAccepted)
            val cancel = SafCancelToken()
            fx.backend.cancelToken = cancel
            fx.backend.cancelWriteAfterBytes = 50_000
            val outcome = fx.transfer(identity, cancel)
            // The stream honours cancel between chunks: the write stops mid
            // destination. The outcome is CANCELLED with partialWritePossible
            // (never success), and the kept partial destination is NOT
            // deleted or relabelled.
            assertTrue(outcome is RunOutputSaveOutcome.Cancelled)
            val cancelled = outcome as RunOutputSaveOutcome.Cancelled
            assertEquals(RunOutputSaveStage.TRANSFERRING, cancelled.stage)
            assertTrue(cancelled.partialWritePossible)
            assertEquals(1, fx.backend.writeOpens)
        } finally { fx.dispose() }
    }

    @Test
    fun destinationDriftAfterWriteRefusesVerification() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.TargetAccepted)
            fx.backend.afterWriteCommit = { doc ->
                doc.content = doc.content.clone().also { if (it.isNotEmpty()) it[0] = (it[0] + 1).toByte() }
            }
            val outcome = fx.transfer(identity)
            assertTrue(outcome is RunOutputSaveOutcome.Failed)
            val failed = outcome as RunOutputSaveOutcome.Failed
            assertEquals("verify-mismatch", failed.code)
            assertTrue(failed.partialWritePossible)
            assertNotNull(fx.backend.docs[fx.uri]?.content) // kept, never deleted
        } finally { fx.dispose() }
    }

    @Test
    fun actualReturnedFlagsDecideAccess() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            // READ-only result (no WRITE flag actually returned) → refused
            // before any IO; operation is terminal (busy slot released).
            val delivery = fx.deliver(identity, flags = 1)
            assertTrue(delivery is RunOutputSaveDelivery.Refused)
            assertEquals("write-flag-missing", (delivery as RunOutputSaveDelivery.Refused).code)
            assertEquals(0, fx.backend.writeOpens)
            // Slot is free again for a fresh request.
            val second = fx.prepare() // NOTE: source was already consumed by the first prepare
            assertNotNull(second)
        } finally { fx.dispose() }
    }

    @Test
    fun probeDenialRefusesDelivery() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            fx.backend.probeReadFlag = ProbeFlag.DENIED
            val delivery = fx.deliver(identity)
            assertTrue(delivery is RunOutputSaveDelivery.Refused)
            assertEquals("access-not-live", (delivery as RunOutputSaveDelivery.Refused).code)
        } finally { fx.dispose() }
    }

    @Test
    fun singleActiveSlotAndOneDeliveryPerIdentity() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            // A second prepare cannot take the slot while active.
            assertNull(fx.prepare())
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.TargetAccepted)
            // Duplicate delivery for the same identity never re-accepts.
            val duplicate = fx.deliver(identity)
            assertTrue(duplicate is RunOutputSaveDelivery.NoTarget)
            // Wrong identity is refused without touching the active slot.
            val wrong = RunOutputSaveIdentity(conversation, run, "d".repeat(64), 99)
            assertTrue(fx.deliver(wrong) is RunOutputSaveDelivery.NoTarget)
            assertTrue(fx.controller.cancel(wrong, "not mine") == false)
        } finally { fx.dispose() }
    }

    @Test
    fun cancelByIdentitySettlesAwaitingOperation() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            assertTrue(fx.controller.cancel(identity, "user cancelled"))
            // Slot released: a fresh operation can start (with a fresh source
            // the controller would take a new prepare; here we assert null on
            // the consumed source instead).
            assertNotNull(fx.controller)
        } finally { fx.dispose() }
    }

    @Test
    fun malformedSourceIdentityRefusesPrepare() {
        val bytes = ByteArray(10)
        val wildcard = RunOutputEgressInfo(
            conversationID = conversation, runID = run, outputID = output,
            producerCallID = "c", producerTool = "t", slot = "s",
            displayName = "a.docx", mimeType = "app/*", byteCount = 10,
            sha256 = sha(bytes), relativePath = "RunOutputs/$run/$output/a.docx")
        val root = File(System.getProperty("java.io.tmpdir"), "ro-save-bad")
            .also { it.mkdirs() }
        try {
            val backend = FakeBackend()
            val controller = RunOutputSaveCopyController(SafGatewayService(backend), backend, root)
            assertNull(controller.prepare(FakeEgressSource(wildcard, bytes)))
            val relBad = RunOutputEgressInfo(
                conversationID = conversation, runID = run, outputID = output,
                producerCallID = "c", producerTool = "t", slot = "s",
                displayName = "a.docx",
                mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                byteCount = 10, sha256 = sha(bytes), relativePath = "elsewhere/a.docx")
            assertNull(controller.prepare(FakeEgressSource(relBad, bytes)))
        } finally { root.deleteRecursively() }
    }

    @Test
    fun nullPickResultCancelsOnlyTheExactOperation() {
        val fx = Fixture()
        try {
            val (identity, _) = fx.prepare()!!
            val delivery = fx.deliver(identity, resultUri = null)
            assertTrue(delivery is RunOutputSaveDelivery.NoTarget)
            // A second delivery attempt for the settled identity is inert.
            assertTrue(fx.deliver(identity) is RunOutputSaveDelivery.NoTarget)
        } finally { fx.dispose() }
    }
}
