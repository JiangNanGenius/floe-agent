// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.safgateway.AccessProbe
import com.floe.android.safgateway.ChildScan
import com.floe.android.safgateway.GrantSnapshot
import com.floe.android.safgateway.OpResult
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.ReadOpen
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafBackendFault
import com.floe.android.safgateway.SafBackendFaultException
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCapabilities
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafProviderFlagBits
import com.floe.android.safgateway.SafSharedGrantBroker
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.TakeOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for [OfficeSaveCopyController] state/identity/flags/hash/cancel/
 * lease-settlement behavior against a deterministic in-memory SAF provider. No
 * Android framework types are touched; the concentrated compile/run stays with
 * Main. Exact-operation identity, the single claimed acceptance slot, deferred
 * retirement, grant-retention failure and honest source-retention are the
 * review-repair contracts (Main review 2026-10-26).
 */
class OfficeSaveCopyControllerTest {

    // ---- deterministic in-memory provider ---------------------------------

    private class FakeDoc(val uriString: String, var name: String, var content: ByteArray)

    private class FakeBackend : SafPlatformBackend {
        val docs = LinkedHashMap<String, FakeDoc>()
        val session = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        val persisted = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        /** Provider-side document ids the controller may resolve for alias checks. */
        val docIds = LinkedHashMap<String, String>()
        var probeUnknown = true
        var closedStreams = 0
        var writeOpens = 0
        /** Runs inside probeAccess (used to park an acceptance mid-flight). */
        var probeHook: (() -> Unit)? = null
        /** Cancel this token once a destination write passes the threshold. */
        var cancelToken: SafCancelToken? = null
        var cancelWriteAfterBytes: Long = Long.MAX_VALUE
        /** Mutate the destination content when its write stream closes (drift). */
        var afterWriteCommit: ((FakeDoc) -> Unit)? = null
        /**
         * When set, [classifyUri] throws this backend fault — mirrors the guarded
         * AndroidSafBackend.classifyUri, which may raise SafBackendFaultException.
         */
        var classifyFault: SafBackendFault? = null
        /** When true, [classifyUri] throws a raw RuntimeException (unmapped hazard). */
        var classifyRuntimeFault = false
        /** When true, [persistedGrants] throws — the guarded currentAccess probe path. */
        var persistedGrantsFault = false

        fun seed(uri: String, name: String, content: ByteArray): FakeDoc =
            FakeDoc(uri, name, content).also { docs[uri] = it }

        override fun classifyUri(uriString: String): SafUriKind {
            if (classifyRuntimeFault) throw IllegalStateException("classify runtime hazard")
            classifyFault?.let { throw SafBackendFaultException(it, "classify-fault") }
            return when {
                !uriString.startsWith("content://") -> SafUriKind.NON_SAF
                "/tree/" in uriString -> SafUriKind.TREE
                "/document/" in uriString -> SafUriKind.DOCUMENT
                else -> SafUriKind.UNKNOWN
            }
        }

        override fun persistedGrants(): List<GrantSnapshot> {
            if (persistedGrantsFault) throw SafBackendFaultException(SafBackendFault.OFFLINE, "grants-fault")
            return persisted.map { (uri, flags) ->
                GrantSnapshot(SafUriRef(uri), read = SafAccessFlag.READ in flags, write = SafAccessFlag.WRITE in flags)
            }
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
        override fun documentIdOf(uri: SafUriRef): String? = docIds[uri.uriString]

        override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe {
            probeHook?.invoke()
            if (probeUnknown) return AccessProbe(ProbeFlag.UNKNOWN, ProbeFlag.UNKNOWN)
            val flags = session[uri.uriString].orEmpty() + persisted[uri.uriString].orEmpty()
            return AccessProbe(
                read = if (SafAccessFlag.READ in flags) ProbeFlag.GRANTED else ProbeFlag.DENIED,
                write = if (SafAccessFlag.WRITE in flags) ProbeFlag.GRANTED else ProbeFlag.DENIED,
            )
        }

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
            return ReadOpen.Opened(CountingInputStream(ByteArrayInputStream(doc.content)), doc.content.size.toLong())
        }

        override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
            val doc = docs[ref.uri.uriString] ?: return WriteOpen.NotFound
            writeOpens++
            return WriteOpen.Opened(object : OutputStream() {
                private val buffer = ByteArrayOutputStream()
                private var written = 0L
                override fun write(b: Int) {
                    buffer.write(b)
                    written++
                    if (written >= cancelWriteAfterBytes) cancelToken?.cancel()
                }
                override fun write(b: ByteArray, off: Int, len: Int) {
                    buffer.write(b, off, len)
                    written += len
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
            tree: SafUriRef, parentDocumentId: String?, mimeType: String, displayName: String, cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> = OpResult.NullReturned("not used by save-copy tests")
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

    private class CountingInputStream(delegate: InputStream) : InputStream() {
        var closed = false
            private set
        private val inner = delegate
        override fun read(): Int = inner.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, len)
        override fun close() {
            closed = true
            inner.close()
        }
    }

    /** Lease whose close COUNT is observable: proves exactly-once release. */
    private class FlagLease : OfficeSaveCopyLease {
        var closeCount = 0
            private set
        val closed: Boolean get() = closeCount > 0
        override fun close() {
            closeCount++
        }
    }

    // ---- fixture ------------------------------------------------------------

    private val MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private val SESSION = "session-1"
    private val stagingRoot = File.createTempFile("office-save-copy-test", "").let {
        it.delete()
        check(it.mkdirs())
        it
    }
    private val backend = FakeBackend()
    private val service = SafGatewayService(backend)
    private val broker = SafSharedGrantBroker()
    private val retainedLeases = mutableListOf<SafSharedGrantBroker.Lease>()

    /** Injected seam failures model the two grant-acquisition hazards Main flagged. */
    private var retainThrows = false
    private var retainFailsAfter = Int.MAX_VALUE
    private val retainGrants: (SafUriRef, Set<SafAccessFlag>) -> List<SafSharedGrantBroker.Lease> = { uri, flags ->
        val taken = ArrayList<SafSharedGrantBroker.Lease>(flags.size)
        try {
            if (retainThrows) throw IllegalStateException("grant authority unavailable")
            var index = 0
            for (flag in flags) {
                if (index == retainFailsAfter) throw IllegalStateException("grant authority unavailable")
                taken += broker.retain(uri, flag)
                index++
            }
            retainedLeases += taken
            taken
        } catch (failure: RuntimeException) {
            // Seam contract: partials it did take are released by the seam itself.
            retainedLeases += taken
            taken.asReversed().forEach { runCatching { it.release() } }
            throw failure
        }
    }

    private val controller = OfficeSaveCopyController(
        service = service,
        backend = backend,
        sessionToken = SESSION,
        stagingRoot = stagingRoot,
        retainGrants = retainGrants,
    )

    private fun identity(generation: Long = 1, session: String = SESSION) =
        OfficeSaveCopyIdentity(session, "save-copy", generation)

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun source(
        bytes: ByteArray,
        sha: String = sha256(bytes),
        length: Long = bytes.size.toLong(),
        name: String = "Quarterly report.docx",
        id: OfficeSaveCopyIdentity = identity(),
        original: OfficeSaveCopyOriginal? = null,
        lease: OfficeSaveCopyLease? = null,
        stream: ((SafCancelToken) -> InputStream)? = null,
    ): OfficeSaveCopySource = OfficeSaveCopySource.create(
        identity = id,
        expectedSha256 = sha,
        lengthBytes = length,
        mimeType = MIME,
        suggestedName = name,
        original = original,
        lease = lease,
    ) { cancel -> stream?.invoke(cancel) ?: ByteArrayInputStream(bytes) }

    private val DEST = "content://fake.provider/document/save-copy-dest"
    private val READ_WRITE_PERSISTABLE =
        com.floe.android.safgateway.SafGrantFlagBits.GRANT_READ or
            com.floe.android.safgateway.SafGrantFlagBits.GRANT_WRITE or
            com.floe.android.safgateway.SafGrantFlagBits.PERSISTABLE

    /** Prepare + deliver a real CREATE_DOCUMENT result; returns the delivery. */
    private fun prepareAndAccept(
        src: OfficeSaveCopySource,
        destUri: String = DEST,
        flags: Int = READ_WRITE_PERSISTABLE,
    ): OfficeSaveCopyDelivery {
        val prepared = controller.prepare(src)
        assertTrue("expected Prepared, got $prepared", prepared is OfficeSaveCopyPrepareResult.Prepared)
        prepared as OfficeSaveCopyPrepareResult.Prepared
        assertEquals(PickKind.CREATE_DOCUMENT, prepared.spec.kind)
        assertEquals(listOf(MIME), prepared.spec.mimeTypes)
        assertEquals(src.suggestedName, prepared.spec.suggestedName)
        backend.session.getOrPut(destUri) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        return controller.deliverPickResult(destUri, flags, src.identity)
    }

    private fun assertSettledAndIdle() {
        assertTrue(controller.state() is OfficeSaveCopyState.Idle)
    }

    private fun assertScratchDrained() {
        assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
    }

    private fun assertRetainedLeasesReleased() {
        retainedLeases.forEach {
            assertEquals(SafSharedGrantBroker.Release.ALREADY_CLOSED, it.release())
        }
    }

    @After
    fun tearDown() {
        stagingRoot.deleteRecursively()
    }

    // ---- source factory validation ------------------------------------------

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsMalformedSha() {
        source(byteArrayOf(1), sha = "not-hex")
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsZeroLength() {
        source(byteArrayOf(), length = 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsLengthAboveOfficeCap() {
        source(byteArrayOf(1), length = OfficeSaveCopySource.MAX_BYTES + 1)
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsWildcardMime() {
        OfficeSaveCopySource.create(
            identity(), sha256(byteArrayOf(1)), 1,
            mimeType = "application/*", suggestedName = "a.docx",
        ) { ByteArrayInputStream(byteArrayOf(1)) }
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsFullWildcardMime() {
        OfficeSaveCopySource.create(
            identity(), sha256(byteArrayOf(1)), 1,
            mimeType = "*/*", suggestedName = "a.docx",
        ) { ByteArrayInputStream(byteArrayOf(1)) }
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsLeadingWildcardMime() {
        OfficeSaveCopySource.create(
            identity(), sha256(byteArrayOf(1)), 1,
            mimeType = "*/octet-stream", suggestedName = "a.docx",
        ) { ByteArrayInputStream(byteArrayOf(1)) }
    }

    @Test
    fun sourceAcceptsConcreteLenientSubtypeMime() {
        // Concrete +, . and - in a subtype stay valid (no wildcard, one pair).
        OfficeSaveCopySource.create(
            identity(), sha256(byteArrayOf(1)), 1,
            mimeType = "application/vnd.ms-excel.sheet.macroEnabled.12", suggestedName = "a.xlsm",
        ) { ByteArrayInputStream(byteArrayOf(1)) }
    }

    @Test(expected = IllegalArgumentException::class)
    fun sourceRejectsUnsafeSuggestedName() {
        source(byteArrayOf(1), name = "../escape.docx")
    }

    @Test(expected = IllegalArgumentException::class)
    fun controllerRejectsBlankSessionToken() {
        OfficeSaveCopyController(
            service = service, backend = backend, sessionToken = "", stagingRoot = stagingRoot,
            retainGrants = retainGrants,
        )
    }

    // ---- prepare / busy / stale ----------------------------------------------

    @Test
    fun secondPrepareWhileActiveIsBusy() {
        val src = source(byteArrayOf(1, 2, 3))
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val again = controller.prepare(source(byteArrayOf(9), id = identity(generation = 2)))
        assertEquals(OfficeSaveCopyPrepareResult.Busy(src.identity), again)
    }

    @Test
    fun settledIdentityIsStaleAndLowerGenerationIsStale() {
        val bytes = byteArrayOf(5, 6, 7, 8)
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(bytes)
        val accepted = prepareAndAccept(src)
        assertTrue(accepted is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)

        val sameAgain = controller.prepare(source(byteArrayOf(1), id = identity()))
        assertTrue(sameAgain is OfficeSaveCopyPrepareResult.Stale)
        // Same session, same per-save generation, different operation id: not newer.
        val notNewer = controller.prepare(
            source(byteArrayOf(1), id = OfficeSaveCopyIdentity(SESSION, "save-copy-again", 1)),
        )
        assertTrue(notNewer is OfficeSaveCopyPrepareResult.Stale)
        val next = controller.prepare(source(byteArrayOf(1), id = identity(generation = 2)))
        assertTrue(next is OfficeSaveCopyPrepareResult.Prepared)
    }

    @Test
    fun foreignSessionCannotPrepareDeliverOrTransfer() {
        val foreign = identity(session = "other-session")
        val prep = controller.prepare(source(byteArrayOf(1), id = foreign))
        assertTrue(prep is OfficeSaveCopyPrepareResult.Stale)
        // No phantom Active was created for a foreign session:
        assertTrue(controller.state() is OfficeSaveCopyState.Idle)
        val d = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, foreign)
        assertTrue(d is OfficeSaveCopyDelivery.Stale)
        val t = controller.transfer(foreign, SafCancelToken())
        assertTrue(t is OfficeSaveCopyOutcome.Stale)
        // The bound session still prepares fine:
        assertTrue(controller.prepare(source(byteArrayOf(2))) is OfficeSaveCopyPrepareResult.Prepared)
    }

    // ---- pick-result acceptance ----------------------------------------------

    @Test
    fun nullResultIsNoTargetAndSettledCancelled() {
        val lease = FlagLease()
        val src = source(byteArrayOf(1), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val delivery = controller.deliverPickResult(null, 0, src.identity)
        assertEquals(OfficeSaveCopyDelivery.NoTarget(src.identity, "null-result"), delivery)
        val settled = controller.settledOutcome()
        assertTrue(settled is OfficeSaveCopyOutcome.Cancelled)
        settled as OfficeSaveCopyOutcome.Cancelled
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, settled.stage)
        assertNull(settled.targetUri)
        // No source IO happened: recovery is NOT claimed, caller obligation stands.
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, settled.sourceRetention)
        assertSettledAndIdle()
        // A delivery-terminal without any IO still releases the borrow exactly once:
        assertEquals(1, lease.closeCount)
    }

    @Test
    fun duplicateDeliveryForTheSameOperationIsStale() {
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(byteArrayOf(1))
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val replay = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        assertTrue(replay is OfficeSaveCopyDelivery.Stale)
        replay as OfficeSaveCopyDelivery.Stale
        assertEquals(src.identity, replay.identity)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
    }

    @Test
    fun deliveryForWrongGenerationIsStaleAndLeavesTheSlotUnclaimed() {
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(byteArrayOf(1))
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val wrong = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, identity(generation = 2))
        assertTrue(wrong is OfficeSaveCopyDelivery.Stale)
        // A foreign generation never claimed the slot: the exact result still binds.
        backend.session.getOrPut(DEST) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val good = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        assertTrue(good is OfficeSaveCopyDelivery.TargetAccepted)
    }

    @Test
    fun nonContentResultIsRefused() {
        val src = source(byteArrayOf(1))
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val delivery = controller.deliverPickResult("file:///tmp/x.docx", READ_WRITE_PERSISTABLE, src.identity)
        assertTrue(delivery is OfficeSaveCopyDelivery.Refused)
        assertEquals("non-content-scheme", (delivery as OfficeSaveCopyDelivery.Refused).code)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertTrue(settled is OfficeSaveCopyOutcome.Failed)
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, settled.sourceRetention)
    }

    @Test
    fun missingWriteOrReadFlagsAreRefused() {
        val readOnly = com.floe.android.safgateway.SafGrantFlagBits.GRANT_READ
        val writeOnly = com.floe.android.safgateway.SafGrantFlagBits.GRANT_WRITE
        val srcW = source(byteArrayOf(1), id = identity())
        assertTrue(controller.prepare(srcW) is OfficeSaveCopyPrepareResult.Prepared)
        val noWrite = controller.deliverPickResult(DEST, readOnly, srcW.identity)
        assertEquals("missing-write-flag", (noWrite as OfficeSaveCopyDelivery.Refused).code)

        val srcR = source(byteArrayOf(1), id = identity(generation = 2))
        assertTrue(controller.prepare(srcR) is OfficeSaveCopyPrepareResult.Prepared)
        val noRead = controller.deliverPickResult(DEST, writeOnly, srcR.identity)
        assertEquals("missing-read-flag", (noRead as OfficeSaveCopyDelivery.Refused).code)
    }

    @Test
    fun resultEqualToSourceOriginalIsRefused() {
        val originalUri = "content://fake.provider/document/original-doc"
        backend.seed(originalUri, "original", byteArrayOf(9))
        val lease = FlagLease()
        val src = source(
            byteArrayOf(1),
            original = OfficeSaveCopyOriginal(SafUriRef(originalUri), "original-doc"),
            lease = lease,
        )
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(originalUri) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val delivery = controller.deliverPickResult(originalUri, READ_WRITE_PERSISTABLE, src.identity)
        assertEquals("result-is-original", (delivery as OfficeSaveCopyDelivery.Refused).code)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertEquals("result-is-original", settled.code)
        // Refusal settles the operation and releases the borrow exactly once.
        assertSettledAndIdle()
        assertEquals(1, lease.closeCount)
    }

    @Test
    fun knownDocumentIdSameAuthorityAliasRefusedBeforeAnyPersistence() {
        val originalUri = "content://fake.provider/document/original-doc"
        backend.seed(originalUri, "original", byteArrayOf(9))
        backend.seed(DEST, "dest", byteArrayOf())
        // The provider exposes the SAME document under the distinct DEST URI.
        backend.docIds[DEST] = "original-doc"
        val lease = FlagLease()
        val src = source(
            byteArrayOf(1),
            original = OfficeSaveCopyOriginal(SafUriRef(originalUri), "original-doc"),
            lease = lease,
        )
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(DEST) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        assertTrue(delivery is OfficeSaveCopyDelivery.Refused)
        assertEquals("result-is-original", (delivery as OfficeSaveCopyDelivery.Refused).code)
        // Ordered BEFORE gateway acceptance: the alias never persisted rights at all.
        assertFalse(backend.persisted.containsKey(DEST))
        assertEquals(1, lease.closeCount)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertEquals("result-is-original", settled.code)
        // The same id WITHOUT an original binding is NOT refused — the check is
        // concrete-identity, not a global document-id blocklist.
        val src2 = source(byteArrayOf(2), id = identity(generation = 2))
        assertTrue(prepareAndAccept(src2) is OfficeSaveCopyDelivery.TargetAccepted)
    }

    @Test
    fun sameDocumentIdDifferentAuthorityIsNotClaimedAsAlias() {
        val originalUri = "content://fake.provider/document/shared-doc"
        val other = "content://other.provider/document/mirror"
        backend.seed(originalUri, "original", byteArrayOf(9))
        backend.seed(other, "mirror", byteArrayOf())
        backend.docIds[other] = "shared-doc"
        val src = source(byteArrayOf(1), original = OfficeSaveCopyOriginal(SafUriRef(originalUri), "shared-doc"))
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(other) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val delivery = controller.deliverPickResult(other, READ_WRITE_PERSISTABLE, src.identity)
        // No cross-provider alias certainty: a different authority with an equal
        // id is NOT refused as the original.
        assertTrue(delivery is OfficeSaveCopyDelivery.TargetAccepted)
    }

    @Test
    fun platformDeniedAccessIsRefused() {
        backend.probeUnknown = false
        val lease = FlagLease()
        val src = source(byteArrayOf(1), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        assertEquals("access-not-live", (delivery as OfficeSaveCopyDelivery.Refused).code)
        // Probe-denied refusal is a delivery terminal without IO: lease released once.
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
    }

    // ---- settled service repairs: backend faults after the acceptance claim ----

    @Test
    fun classifyFaultAfterClaimSettlesExactActiveAndReleasesLeaseOnce() {
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        // The slot is claimed; the guarded classify inside acceptPickResult then throws.
        backend.classifyFault = SafBackendFault.FAILED
        val delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        backend.classifyFault = null
        assertTrue(delivery is OfficeSaveCopyDelivery.Refused)
        assertEquals("acceptance-backend-fault", (delivery as OfficeSaveCopyDelivery.Refused).code)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertEquals(src.identity, settled.identity)
        assertEquals("acceptance-backend-fault", settled.code)
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, settled.stage)
        // classify throws BEFORE any persistence: nothing persisted, no IO, no target.
        assertFalse(backend.persisted.containsKey(DEST))
        assertEquals(0, backend.writeOpens)
        // The claimed acceptance quiesced with the throw: the borrow released exactly once.
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
        assertScratchDrained()
    }

    @Test
    fun runtimeFaultAfterClaimSettlesExactActiveAndReleasesLeaseOnce() {
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        // An unexpected RuntimeException (not a mapped backend fault) after the
        // claim must settle the exact Active too, never leave it claimed forever.
        backend.classifyRuntimeFault = true
        val delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        backend.classifyRuntimeFault = false
        assertTrue(delivery is OfficeSaveCopyDelivery.Refused)
        assertEquals("acceptance-runtime-fault", (delivery as OfficeSaveCopyDelivery.Refused).code)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertEquals("acceptance-runtime-fault", settled.code)
        assertEquals(src.identity, settled.identity)
        assertEquals(0, backend.writeOpens)
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
    }

    @Test
    fun persistedGrantsProbeFaultSettlesExactActiveAndReleasesLeaseOnce() {
        backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(DEST) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        // acceptPickResult succeeds; the guarded persistedGrants inside currentAccess throws.
        backend.persistedGrantsFault = true
        val delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        backend.persistedGrantsFault = false
        assertTrue(delivery is OfficeSaveCopyDelivery.Refused)
        assertEquals("live-access-backend-fault", (delivery as OfficeSaveCopyDelivery.Refused).code)
        // A faulted probe never publishes the target and never reaches transfer.
        assertTrue(controller.state() is OfficeSaveCopyState.Idle)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Failed
        assertEquals("live-access-backend-fault", settled.code)
        assertEquals(src.identity, settled.identity)
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, settled.sourceRetention)
        assertEquals(0, backend.writeOpens)
        assertEquals(1, lease.closeCount)
        assertScratchDrained()
    }

    @Test
    fun transientSessionGrantIsAcceptedAndReported() {
        backend.seed(DEST, "dest", byteArrayOf())
        val bytes = "transient output".toByteArray()
        val src = source(bytes)
        val delivery = prepareAndAccept(src, flags = com.floe.android.safgateway.SafGrantFlagBits.GRANT_READ or
            com.floe.android.safgateway.SafGrantFlagBits.GRANT_WRITE)
        assertTrue(delivery is OfficeSaveCopyDelivery.TargetAccepted)
        delivery as OfficeSaveCopyDelivery.TargetAccepted
        assertTrue(delivery.transientOnly)
        assertTrue(delivery.persisted.isEmpty())
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
        outcome as OfficeSaveCopyOutcome.CopiedVerified
        assertTrue(outcome.grantTransientOnly)
        assertTrue(outcome.grantPersisted.isEmpty())
    }

    // ---- transfer: verified copy ---------------------------------------------

    @Test
    fun happyPathCopiesVerifiedBytesAndSettlesEverything() {
        val bytes = ("payload-" + "x".repeat(200_000)).toByteArray()
        val sha = sha256(bytes)
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(bytes, sha = sha, lease = lease)

        val delivery = prepareAndAccept(src)
        assertTrue(delivery is OfficeSaveCopyDelivery.TargetAccepted)
        delivery as OfficeSaveCopyDelivery.TargetAccepted
        assertEquals(setOf(SafAccessFlag.READ, SafAccessFlag.WRITE), delivery.granted)
        assertEquals(setOf(SafAccessFlag.READ, SafAccessFlag.WRITE), delivery.persisted)
        assertTrue(!delivery.transientOnly)

        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
        outcome as OfficeSaveCopyOutcome.CopiedVerified
        assertEquals(src.identity, outcome.identity)
        assertEquals(SafUriRef(DEST), outcome.destination.uri)
        assertEquals(bytes.size.toLong(), outcome.bytes)
        assertEquals(sha, outcome.sourceSha256)
        assertEquals(sha, outcome.destinationSha256)
        assertEquals(OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT, outcome.sourceRetention)

        assertArrayEquals(bytes, doc.content)
        assertEquals(1, lease.closeCount)
        // The staged scratch file is actually owned and removed by the finally.
        assertScratchDrained()
        assertRetainedLeasesReleased()
        assertSettledAndIdle()
        assertEquals(outcome, controller.settledOutcome())
    }

    // ---- transfer: source facts mismatches never touch the destination -------

    @Test
    fun sourceLengthMismatchFailsBeforeAnyWrite() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(bytes, sha = sha256(bytes), length = bytes.size + 1L, lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        outcome as OfficeSaveCopyOutcome.Failed
        assertEquals("source-length-mismatch", outcome.code)
        assertEquals(OfficeSaveCopyStage.TRANSFERRING, outcome.stage)
        assertTrue(!outcome.partialWritePossible)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        // EOF was reached and hashed durably: fully observed, even though mismatched.
        assertEquals(OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT, outcome.sourceRetention)
        assertEquals(1, lease.closeCount)
        assertScratchDrained()
    }

    @Test
    fun sourceHashMismatchFailsBeforeAnyWrite() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val other = sha256(byteArrayOf(9, 9))
        val src = source(bytes, sha = other, lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        outcome as OfficeSaveCopyOutcome.Failed
        assertEquals("source-hash-mismatch", outcome.code)
        assertTrue(!outcome.partialWritePossible)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        assertEquals(OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT, outcome.sourceRetention)
        assertEquals(1, lease.closeCount)
        assertScratchDrained()
    }

    @Test
    fun missingSourceOpenerFailsUnprovenAndReleasesLeaseOnce() {
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2), lease = lease) { throw IOException("staged output missing") }
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        outcome as OfficeSaveCopyOutcome.Failed
        assertEquals("io", outcome.code)
        // The opener threw: the service cannot claim the bytes were recovered.
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, outcome.sourceRetention)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        assertEquals(1, lease.closeCount)
        assertScratchDrained()
        assertRetainedLeasesReleased()
        assertSettledAndIdle()
    }

    @Test
    fun stagingRuntimeExceptionRemovesOwnedPartBeforeSettle() {
        val bytes = ("boom-" + "b".repeat(100_000)).toByteArray()
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        // The stream opens fine, the .part gets created and the first chunk is
        // written; then the source raises a RuntimeException (not IOException).
        val src = source(bytes, lease = lease) {
            object : InputStream() {
                private var pos = 0
                private var reads = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    reads++
                    if (reads == 2) throw IllegalStateException("opener exploded")
                    if (pos >= bytes.size) return -1
                    val n = minOf(len, bytes.size - pos)
                    System.arraycopy(bytes, pos, b, off, n)
                    pos += n
                    return n
                }
                override fun read(): Int = error("single-byte read not used by the controller")
            }
        }
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        outcome as OfficeSaveCopyOutcome.Failed
        // The original failure is preserved (rethrown), never swallowed:
        assertEquals("unexpected-IllegalStateException", outcome.code)
        assertEquals("opener exploded", outcome.detail)
        // stageSource removed its OWNED .part before onStaged: the finally saw
        // scratch=null yet NOTHING leaks in the staging root.
        assertScratchDrained()
        // The provider destination was never opened and the caller's bytes remain:
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        assertEquals(1, lease.closeCount)
        assertRetainedLeasesReleased()
        assertSettledAndIdle()
    }

    // ---- grant acquisition failures settle without stranding ----------------

    @Test
    fun grantRetentionFailureSettlesBeforeWriteAndReleasesLeaseOnce() {
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2, 3), lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        retainThrows = true
        val outcome = controller.transfer(src.identity, SafCancelToken())
        retainThrows = false
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        outcome as OfficeSaveCopyOutcome.Failed
        assertEquals("grant-retention-failed", outcome.code)
        assertEquals(OfficeSaveCopyStage.TRANSFERRING, outcome.stage)
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, outcome.sourceRetention)
        assertTrue(!outcome.partialWritePossible)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        assertEquals(1, lease.closeCount)
        assertTrue(retainedLeases.isEmpty())
        assertScratchDrained()
        assertSettledAndIdle()
    }

    @Test
    fun grantSeamPartialAcquisitionIsReleasedAndOperationSettles() {
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2, 3), lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        // The seam takes READ, then fails on WRITE (mirrors the default-seam hazard).
        retainFailsAfter = 1
        val outcome = controller.transfer(src.identity, SafCancelToken())
        retainFailsAfter = Int.MAX_VALUE
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        assertEquals("grant-retention-failed", (outcome as OfficeSaveCopyOutcome.Failed).code)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        // The one partial reference the seam did take was released (no double release later):
        assertEquals(1, retainedLeases.size)
        assertRetainedLeasesReleased()
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
    }

    // ---- transfer: uncertain partial + cancel --------------------------------

    @Test
    fun readbackMismatchIsUncertainPartialWithOwnedTargetPreserved() {
        val bytes = ("final-output-" + "y".repeat(150_000)).toByteArray()
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        backend.afterWriteCommit = { it.content = it.content + byteArrayOf(0) } // provider-side drift
        val lease = FlagLease()
        val src = source(bytes, lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.Failed)
        outcome as OfficeSaveCopyOutcome.Failed
        assertEquals("verify-mismatch", outcome.code)
        assertEquals(OfficeSaveCopyStage.VERIFYING, outcome.stage)
        assertEquals(SafUriRef(DEST), outcome.ownedTargetUri)
        assertTrue(outcome.partialWritePossible)
        assertEquals(OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT, outcome.sourceRetention)
        assertEquals(bytes.size + 1, doc.content.size) // partial destination kept, never deleted
        assertScratchDrained()
        assertEquals(1, lease.closeCount)
    }

    @Test
    fun cancelDuringStagingDrainsBeforeSettlingAndKeepsDestinationUntouched() {
        val bytes = ("cancel-me-" + "z".repeat(300_000)).toByteArray()
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val cancel = SafCancelToken()
        val lease = FlagLease()
        var reads = 0
        val src = source(bytes, lease = lease) {
            object : InputStream() {
                private var pos = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    reads++
                    if (reads == 2) cancel.cancel() // request after the first chunk
                    if (pos >= bytes.size) return -1
                    val n = minOf(len, bytes.size - pos)
                    System.arraycopy(bytes, pos, b, off, n)
                    pos += n
                    return n
                }
                override fun read(): Int = error("single-byte read not used by the controller")
            }
        }
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, cancel)
        assertTrue(outcome is OfficeSaveCopyOutcome.Cancelled)
        outcome as OfficeSaveCopyOutcome.Cancelled
        assertEquals(OfficeSaveCopyStage.TRANSFERRING, outcome.stage)
        assertTrue(!outcome.partialWritePossible)
        assertEquals(SafUriRef(DEST), outcome.targetUri)
        // Stream was cut before EOF: nothing is claimed about recovery.
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, outcome.sourceRetention)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        assertEquals(1, lease.closeCount)
        assertScratchDrained()
        assertRetainedLeasesReleased()
    }

    @Test
    fun cancelDuringProviderWriteReportsPartialAndDrainsBeforeRelease() {
        val chunk = 64 * 1024
        val bytes = ByteArray(chunk * 4) { (it % 251).toByte() }
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val cancel = SafCancelToken()
        backend.cancelToken = cancel
        backend.cancelWriteAfterBytes = chunk.toLong()
        val lease = FlagLease()
        val src = source(bytes, lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, cancel)
        assertTrue(outcome is OfficeSaveCopyOutcome.Cancelled)
        outcome as OfficeSaveCopyOutcome.Cancelled
        assertEquals(OfficeSaveCopyStage.TRANSFERRING, outcome.stage)
        assertTrue(outcome.partialWritePossible)
        assertEquals(SafUriRef(DEST), outcome.targetUri)
        // Staging had fully observed + durably staged the bytes before the write: honest.
        assertEquals(OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT, outcome.sourceRetention)
        assertEquals(1, backend.writeOpens)
        assertTrue(doc.content.size in 1 until bytes.size) // partial destination kept, not deleted
        assertScratchDrained()
        assertEquals(1, lease.closeCount)
        assertRetainedLeasesReleased()
    }

    // ---- exact identity on transfer -------------------------------------------

    @Test
    fun transferForWrongIdentityIsStaleAndCannotTakeOverTheActiveOperation() {
        val bytes = byteArrayOf(4, 5)
        backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(bytes, lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val wrong = controller.transfer(identity(generation = 9), SafCancelToken())
        assertTrue(wrong is OfficeSaveCopyOutcome.Stale)
        assertEquals(identity(generation = 9), wrong.identity)
        // A foreign identity never touched the operation or its borrow:
        assertEquals(0, lease.closeCount)
        assertEquals(0, backend.writeOpens)
        val state = controller.state()
        assertTrue(state is OfficeSaveCopyState.Active)
        assertEquals(src.identity, (state as OfficeSaveCopyState.Active).identity)
        // The exact identity still runs normally:
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
    }

    // ---- bounded retirement ----------------------------------------------------

    @Test
    fun retireWaitingOperationSettlesCancelledAndReleasesLeaseOnce() {
        val lease = FlagLease()
        val src = source(byteArrayOf(1), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val retirement = controller.retire(src.identity)
        assertTrue(retirement is OfficeSaveCopyRetirement.Retired)
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Cancelled
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, settled.stage)
        assertNull(settled.targetUri)
        assertEquals(OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION, settled.sourceRetention)
        // Idempotency + no resurrection of the retired identity:
        assertTrue(controller.retire(src.identity) is OfficeSaveCopyRetirement.Stale)
        assertTrue(controller.prepare(source(byteArrayOf(2), id = src.identity)) is OfficeSaveCopyPrepareResult.Stale)
        // The next per-save generation on the same session still works.
        assertTrue(
            controller.prepare(source(byteArrayOf(2), id = identity(generation = 2)))
                is OfficeSaveCopyPrepareResult.Prepared,
        )
    }

    @Test
    fun retireAfterAcceptedTargetKeepsTargetUriAndLeavesDestinationUntouched() {
        val doc = backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1), lease = lease)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val retirement = controller.retire(src.identity)
        assertTrue(retirement is OfficeSaveCopyRetirement.Retired)
        assertEquals(1, lease.closeCount)
        assertEquals(0, backend.writeOpens)
        assertEquals(0, doc.content.size)
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Cancelled
        assertEquals(SafUriRef(DEST), settled.targetUri)
        assertEquals("retired by App before transfer", settled.reason)
        // Transfer after retire returns the settled Cancelled and never starts a write:
        assertEquals(settled, controller.transfer(src.identity, SafCancelToken()))
        assertEquals(0, backend.writeOpens)
    }

    @Test
    fun retireForeignIdentityChangesNothingAndActiveKeepsWaiting() {
        val lease = FlagLease()
        val src = source(byteArrayOf(1), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val wrong = controller.retire(identity(generation = 4))
        assertTrue(wrong is OfficeSaveCopyRetirement.Stale)
        assertEquals(0, lease.closeCount)
        val state = controller.state()
        assertTrue(state is OfficeSaveCopyState.Active)
        assertEquals(src.identity, (state as OfficeSaveCopyState.Active).identity)
        // The real operation still completes afterwards:
        backend.seed(DEST, "dest", byteArrayOf())
        assertTrue(controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
            is OfficeSaveCopyDelivery.TargetAccepted)
    }

    @Test
    fun retireDuringInFlightAcceptanceIsDeferredAndCannotPublishTarget() {
        backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val src = source(byteArrayOf(1, 2), lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(DEST) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val inProbe = CountDownLatch(1)
        val releaseProbe = CountDownLatch(1)
        backend.probeHook = { inProbe.countDown(); releaseProbe.await() }
        var delivery: OfficeSaveCopyDelivery? = null
        val carrier = Thread {
            delivery = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        }.also { it.start() }
        assertTrue("acceptance did not reach the live probe", inProbe.await(5, TimeUnit.SECONDS))
        val retirement = controller.retire(src.identity)
        assertTrue(retirement is OfficeSaveCopyRetirement.Deferred)
        // In-flight acceptance is NOT cleared or lease-released by the late retire:
        assertEquals(0, lease.closeCount)
        val during = controller.state()
        assertTrue(during is OfficeSaveCopyState.Active)
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, (during as OfficeSaveCopyState.Active).stage)
        assertNull(during.targetUri)
        releaseProbe.countDown()
        carrier.join(5_000)
        backend.probeHook = null
        val d = delivery
        assertTrue("expected NoTarget, got $d", d is OfficeSaveCopyDelivery.NoTarget)
        d as OfficeSaveCopyDelivery.NoTarget
        assertEquals("retired during acceptance; no target published", d.reason)
        // Only the running owner settled and released, exactly once, at quiescence:
        assertEquals(1, lease.closeCount)
        assertSettledAndIdle()
        val settled = controller.settledOutcome() as OfficeSaveCopyOutcome.Cancelled
        assertEquals(src.identity, settled.identity)
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, settled.stage)
        assertEquals(settled, controller.transfer(src.identity, SafCancelToken()))
    }

    @Test
    fun retireDuringInFlightTransferIsDeferredAndOwnerCompletesHonestly() {
        val bytes = ("mid-" + "w".repeat(300_000)).toByteArray()
        backend.seed(DEST, "dest", byteArrayOf())
        val lease = FlagLease()
        val deferred = booleanArrayOf(false)
        val holder = arrayOfNulls<OfficeSaveCopySource>(1)
        var reads = 0
        val src = source(bytes, lease = lease) {
            object : InputStream() {
                private var pos = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    reads++
                    if (reads == 2) {
                        // A late retire arriving mid-staging must defer, never clear.
                        deferred[0] = controller.retire(holder[0]!!.identity) is OfficeSaveCopyRetirement.Deferred
                    }
                    if (pos >= bytes.size) return -1
                    val n = minOf(len, bytes.size - pos)
                    System.arraycopy(bytes, pos, b, off, n)
                    pos += n
                    return n
                }
                override fun read(): Int = error("single-byte read not used by the controller")
            }
        }
        holder[0] = src
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(deferred[0])
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
        assertEquals(1, lease.closeCount)
        assertTrue(controller.retire(src.identity) is OfficeSaveCopyRetirement.Stale)
        assertSettledAndIdle()
    }

    // ---- concurrent acceptance --------------------------------------------------

    @Test
    fun concurrentDuplicateDeliveriesClaimTheAcceptanceSlotExactlyOnce() {
        backend.seed(DEST, "dest", byteArrayOf())
        val bytes = byteArrayOf(8, 8, 8)
        val lease = FlagLease()
        val src = source(bytes, lease = lease)
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        backend.session.getOrPut(DEST) { mutableSetOf() } += setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val go = CountDownLatch(1)
        val results = arrayOfNulls<OfficeSaveCopyDelivery>(2)
        val carriers = (0..1).map { i ->
            Thread {
                go.await()
                results[i] = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
            }.also { it.start() }
        }
        go.countDown()
        carriers.forEach { it.join(5_000) }
        val accepted = results.filterIsInstance<OfficeSaveCopyDelivery.TargetAccepted>()
        val stale = results.filterIsInstance<OfficeSaveCopyDelivery.Stale>()
        assertEquals(1, accepted.size)
        assertEquals(1, stale.size)
        // Exactly one slot claim ⇒ exactly one published target, still current:
        val state = controller.state()
        state as OfficeSaveCopyState.Active
        assertEquals(src.identity, state.identity)
        assertEquals(SafUriRef(DEST), state.targetUri)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)
        assertEquals(1, lease.closeCount)
    }

    // ---- late binding -----------------------------------------------------------

    @Test
    fun latePickResultForSettledOperationIsStaleAndCannotDeliverSuccess() {
        val bytes = byteArrayOf(7, 7, 7)
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(bytes)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertTrue(outcome is OfficeSaveCopyOutcome.CopiedVerified)

        val late = controller.deliverPickResult(
            "content://fake.provider/document/other", READ_WRITE_PERSISTABLE, src.identity,
        )
        assertTrue(late is OfficeSaveCopyDelivery.Stale)
        val replay = controller.prepare(source(byteArrayOf(1), id = src.identity))
        assertTrue(replay is OfficeSaveCopyPrepareResult.Stale)
        // The settled verified outcome stands; nothing was relabeled.
        assertEquals(outcome, controller.settledOutcome())
    }

    @Test
    fun lateDeliveryCannotPoisonANewerOperationAfterSettle() {
        val bytes = byteArrayOf(2, 2)
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(bytes)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val first = controller.transfer(src.identity, SafCancelToken())
        assertTrue(first is OfficeSaveCopyOutcome.CopiedVerified)

        // A newer generation prepares and accepts its own target elsewhere.
        val other = "content://fake.provider/document/second-dest"
        backend.seed(other, "second", byteArrayOf())
        val src2 = source(byteArrayOf(3, 3), id = identity(generation = 2))
        assertTrue(prepareAndAccept(src2, destUri = other) is OfficeSaveCopyDelivery.TargetAccepted)
        // A late result for the OLD settled identity is Stale and cannot settle
        // or clear the newer Active.
        val late = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, src.identity)
        assertTrue(late is OfficeSaveCopyDelivery.Stale)
        val state = controller.state()
        state as OfficeSaveCopyState.Active
        assertEquals(src2.identity, state.identity)
        assertEquals(SafUriRef(other), state.targetUri)
    }

    @Test
    fun transferWithoutActiveOperationReturnsSettledOutcome() {
        val bytes = byteArrayOf(3)
        backend.seed(DEST, "dest", byteArrayOf())
        val src = source(bytes)
        assertTrue(prepareAndAccept(src) is OfficeSaveCopyDelivery.TargetAccepted)
        val outcome = controller.transfer(src.identity, SafCancelToken())
        assertEquals(outcome, controller.transfer(src.identity, SafCancelToken()))
    }

    @Test
    fun deliveryWithForeignIdentityIsStaleWhileActive() {
        val src = source(byteArrayOf(1))
        assertTrue(controller.prepare(src) is OfficeSaveCopyPrepareResult.Prepared)
        val foreign = controller.deliverPickResult(DEST, READ_WRITE_PERSISTABLE, identity(session = "other-session"))
        assertTrue(foreign is OfficeSaveCopyDelivery.Stale)
        // The active operation is still waiting for its real result.
        val state = controller.state()
        assertTrue(state is OfficeSaveCopyState.Active)
        assertEquals(src.identity, (state as OfficeSaveCopyState.Active).identity)
        assertEquals(OfficeSaveCopyStage.AWAITING_TARGET, state.stage)
    }
}
