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
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafProviderFlagBits
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.TakeOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
import org.junit.Test

/**
 * G04-R1 provider SOURCE HOST controller — controller-lane tests.
 * AUTHORED, NOTRUN (Main runs the composed batch). The native C ABI is
 * injected through the `WorkspaceSourceChannel` seam (a scripted model of
 * G04WorkspaceSourceHostAPI computing REAL digests over the received
 * chunks), while the OS side runs the REAL frozen `SafGatewayService` over
 * an in-memory backend — so the ladder ORDER (sourceLookup -> egressOpen ->
 * backup stage -> journal prepare -> fresh observation -> ONE-TIME claim ->
 * exactly-one permit -> actual "wt" write -> read-back stage -> settle ->
 * egressClose), chunk bounds, typed refusal mapping, release gating, pick
 * flag plumbing and every fence are provable on the JVM without the
 * framework, a device or the native library. No production fake is added
 * and no assertion is weakened: each expectation matches the shipped
 * MODULE_API.json contract.
 */
class WorkspaceSourceHostControllerTest {

    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()
    private val epoch = 42L
    private val epochHolder = AtomicLong(epoch)
    private val ownerLive = AtomicBoolean(true)

    private val tmpRoot: File by lazy {
        File(System.getProperty("java.io.tmpdir"), "floe-src-host-" + UUID.randomUUID())
            .apply { mkdirs() }
    }

    // ------------------------------------------------------------------
    // scripted channel (models the -5xx replies + real digests)
    // ------------------------------------------------------------------

    private inner class FakeChannel : WorkspaceSourceChannel {
        val calls = CopyOnWriteArrayList<String>()
        val stages = ConcurrentHashMap<Long, Pair<String, ByteArrayOutputStream>>()
        /** The sourceDocumentID each stageOpen carried — pins durable identity
         * truth through the native hop (provider IO repair 2026-10-25). */
        val stageDocumentIds = ConcurrentHashMap<Long, String>()
        /** The logicalPath + sourceReference each stageOpen carried (the
         * folder-import walk pins per-child path AND exact child identity
         * through the native hop — G05-R3 repair 2026-10-27). */
        val stagePaths = ConcurrentHashMap<Long, String>()
        val stageReferences = ConcurrentHashMap<Long, String>()
        /** Test hook fired with the finished stage's logical path (null for
         * no-path purposes) right at stageFinish — the deterministic point
         * to drop the owner fence between folder-import children. */
        var onStageFinished: ((String?) -> Unit)? = null
        val stageChunkSizes = ConcurrentHashMap<Long, MutableList<Int>>()
        val snapshots = ConcurrentHashMap<Long, ByteArray>()
        /** The bytes native hashed at stage_finish. Kept as test evidence
         * after the lane releases the scratch: stageAbort below removes the
         * live stage exactly like the C ABI removes the staging file, so
         * byte-exact assertions must read the finalized body, not a live
         * session that the production contract (correctly) already aborted. */
        val finishedStageBodies = ConcurrentHashMap<Long, Pair<String, ByteArray>>()
        private val tickets = AtomicInteger(500)
        var sourceLookupBody: String? = null
        var sourcePageBody = """{"ok":1,"rows":[]}"""
        var recoveryPageBody = """{"ok":1,"rows":[]}"""
        var recordedSha = ""
        var revision = "rev-1"
        val nextRecoveryId = UUID.randomUUID().toString()
        val permitCounts = ConcurrentHashMap<String, Int>()
        var refusePermit = false
        var failStageWriteStatus = 0
        var chunkDelayMillis = 0
        var settleMatches = true
        var egressContent: ByteArray = ByteArray(0)

        override fun stageOpen(epoch: Long, taskID: String, workspaceID: String, purpose: String,
                               logicalPath: String, sourceReference: String, sourceDocumentID: String,
                               sourceID: String): Long {
            calls.add("stageOpen:$purpose")
            val ticket = tickets.incrementAndGet().toLong()
            stages[ticket] = purpose to ByteArrayOutputStream()
            stageDocumentIds[ticket] = sourceDocumentID
            stagePaths[ticket] = logicalPath
            stageReferences[ticket] = sourceReference
            stageChunkSizes[ticket] = mutableListOf()
            return ticket
        }

        override fun stageWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int {
            val stage = stages[ticket] ?: return -503
            if (length <= 0 || length > 65_536 || offset < 0 || offset + length > data.size) return -105
            if (failStageWriteStatus != 0) return failStageWriteStatus
            if (chunkDelayMillis > 0) try { Thread.sleep(chunkDelayMillis.toLong()) }
            catch (_: InterruptedException) { }
            stage.second.write(data, offset, length)
            stageChunkSizes.getValue(ticket) += length
            return 0
        }

        override fun stageFinish(ticket: Long, reply: ByteArray): Int {
            val stage = stages[ticket] ?: return -503
            calls.add("stageFinish:${stage.first}")
            val bytes = stage.second.toByteArray()
            finishedStageBodies[ticket] = stage.first to bytes
            val hex = digest(bytes)
            val status = if (stage.first == "import") {
                body(reply, """{"ok":1,"sourceID":"imported-row","sha256":"$hex",""" +
                    """"bytes":${bytes.size},"revision":"$revision"}""")
            } else {
                body(reply, """{"ok":1,"sha256":"$hex","bytes":${bytes.size}}""")
            }
            onStageFinished?.invoke(stagePaths[ticket]?.takeIf { it.isNotEmpty() })
            return status
        }

        override fun stageAbort(ticket: Long): Int {
            calls.add("stageAbort")
            stages.remove(ticket)
            return 0
        }

        override fun egressOpen(epoch: Long, mode: String, taskID: String, workspaceID: String,
                                logicalPath: String, sourceID: String): Long {
            calls.add("egressOpen:$mode")
            val ticket = tickets.incrementAndGet().toLong()
            snapshots[ticket] = egressContent
            return ticket
        }

        override fun egressInfo(ticket: Long, reply: ByteArray): Int {
            val snapshot = snapshots[ticket] ?: return -503
            calls.add("egressInfo")
            return body(reply, """{"ok":1,"mode":"save","sha256":"${digest(snapshot)}",""" +
                """"bytes":${snapshot.size},"logicalPath":"docs/doc.txt",""" +
                """"recoveryID":"$nextRecoveryId"}""")
        }

        override fun egressRead(ticket: Long, offset: Long, target: ByteArray): Int {
            val snapshot = snapshots[ticket] ?: return -503
            if (offset >= snapshot.size) return 0
            val count = minOf(target.size.toLong(), snapshot.size - offset).toInt()
            System.arraycopy(snapshot, offset.toInt(), target, 0, count)
            return count
        }

        override fun egressVerify(egressTicket: Long, stageTicket: Long, reply: ByteArray): Int {
            calls.add("egressVerify")
            val snapshot = snapshots[egressTicket] ?: return -503
            val stage = stages[stageTicket] ?: return -503
            val match = digest(snapshot) == digest(stage.second.toByteArray())
            return body(reply, """{"ok":1,"match":${if (match) 1 else 0},""" +
                """"snapshotSHA256":"${digest(snapshot)}",""" +
                """"observedSHA256":"${digest(stage.second.toByteArray())}"}""")
        }

        override fun egressClose(ticket: Long): Int {
            calls.add("egressClose")
            snapshots.remove(ticket)
            return 0
        }

        override fun savePrepare(saveTicket: Long, backupTicket: Long, receiptToken: String,
                                 reply: ByteArray): Int {
            calls.add("savePrepare")
            val backup = stages[backupTicket] ?: return -503
            val backupSha = digest(backup.second.toByteArray())
            return if (backupSha != recordedSha) {
                body(reply, """{"ok":0,"errorCode":"sourceChangedSinceImport","reason":""}""")
            } else {
                body(reply, """{"ok":1,"state":"prepared","recoveryID":"$nextRecoveryId",""" +
                    """"sourceRevision":"$revision"}""")
            }
        }

        override fun saveClaim(saveTicket: Long, freshTicket: Long, reply: ByteArray): Int {
            calls.add("saveClaim")
            return body(reply, """{"ok":1,"state":"writing","recoveryID":"$nextRecoveryId"}""")
        }

        override fun savePermit(saveTicket: Long, receiptToken: String): Int {
            calls.add("savePermit")
            if (refusePermit) return -508
            val count = permitCounts.merge(receiptToken, 1) { a, b -> a + b } ?: 1
            return if (count == 1) 0 else -508
        }

        override fun saveSettle(saveTicket: Long, readbackTicket: Long, reply: ByteArray): Int {
            calls.add("saveSettle")
            val readback = stages[readbackTicket] ?: return -503
            val observed = digest(readback.second.toByteArray())
            val replacement = digest(snapshots[saveTicket] ?: return -503)
            return if (settleMatches && observed == replacement) {
                body(reply, """{"ok":1,"state":"committed","recoveryID":"$nextRecoveryId",""" +
                    """"observedSHA256":"$observed","errorCode":""}""")
            } else {
                body(reply, """{"ok":0,"state":"conflict","recoveryID":"$nextRecoveryId",""" +
                    """"observedSHA256":"$observed","errorCode":"providerReadbackMismatch"}""")
            }
        }

        override fun saveRetain(saveTicket: Long, reply: ByteArray): Int {
            calls.add("saveRetain")
            return body(reply, """{"ok":1,"state":"retained","recoveryID":"$nextRecoveryId"}""")
        }

        override fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int,
                                reply: ByteArray): Int {
            calls.add("sourcePage")
            return body(reply, sourcePageBody)
        }

        override fun sourceLookup(epoch: Long, workspaceID: String, logicalPath: String,
                                  reply: ByteArray): Int {
            calls.add("sourceLookup")
            return sourceLookupBody?.let { body(reply, it) } ?: -506
        }

        override fun recoveryPage(epoch: Long, workspaceID: String, afterID: String, limit: Int,
                                  reply: ByteArray): Int {
            calls.add("recoveryPage")
            return body(reply, recoveryPageBody)
        }

        override fun reconcileRun(epoch: Long, workspaceID: String, reply: ByteArray): Int {
            calls.add("reconcileRun")
            return body(reply, """{"ok":1,"settled":0}""")
        }

        override fun reconcileStaged(epoch: Long, taskID: String, workspaceID: String,
                                     recoveryID: String, stageTicket: Long, reply: ByteArray): Int {
            calls.add("reconcileStaged")
            return body(reply, """{"ok":1,"state":"conflict","recoveryID":"$recoveryID",""" +
                """"observedSHA256":""}""")
        }

        override fun hostStats(reply: ByteArray): Int =
            body(reply, """{"live":0,"retired":0,"aggregateStagedBytes":0,"counters":{}}""")
    }

    private fun body(buffer: ByteArray, json: String): Int {
        val bytes = json.toByteArray(Charsets.UTF_8)
        if (bytes.size + 1 > buffer.size) return -106
        System.arraycopy(bytes, 0, buffer, 0, bytes.size)
        buffer[bytes.size] = 0
        return bytes.size
    }

    private fun digest(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }

    // ------------------------------------------------------------------
    // in-memory backend under the REAL gateway service
    // ------------------------------------------------------------------

    private inner class FakeBackend : SafPlatformBackend {
        val content = ConcurrentHashMap<String, ByteArray>()
        var takeCalls = 0
        var releaseCalls = 0
        var writeCapability = true
        var probeGranted = true
        /** Scripted platform identity decodes: URI -> the exact DECODED
         * document id the provider would report (null when the platform
         * refuses). Mirrors the AndroidSafBackend.documentIdOf contract. */
        val decodedDocumentIds = ConcurrentHashMap<String, String>()
        var faultOnOpenWrite: Throwable? = null
        var faultOnOpenRead: Throwable? = null
        /** URIs the in-memory provider reports as DIRECTORY documents. */
        val directoryUris = ConcurrentHashMap.newKeySet<String>()
        /** Scripts a child scan per parent key (parentDocumentId, or
         * "__root__" when the caller passes null = the tree root's own id). */
        val childrenByParent = ConcurrentHashMap<String, List<SafDocument>>()
        /** Counts reads attempted on DIRECTORY URIs: exactly the device
         * failure route ("read failed: EISDIR (Is a directory)", G05-R3
         * 2026-10-27). Every folder-import assertion demands ZERO. */
        val eisdirDirectoryReadAttempts = AtomicInteger(0)

        private fun refFor(uri: String): SafDocumentRef = SafDocumentRef(null, null, null, SafUriRef(uri))

        private fun documentFor(uri: String): SafDocument {
            val isDirectory = directoryUris.contains(uri)
            return SafDocument(
                ref = refFor(uri),
                displayName = uri.substringAfterLast('/'),
                mimeType = if (isDirectory) SafDocument.MIME_DIR else "application/octet-stream",
                size = content[uri]?.let { SafSize.Known(it.size.toLong()) } ?: SafSize.Unknown,
                lastModifiedMillis = null,
                capabilities = SafCapabilities(
                    write = writeCapability, delete = false, rename = false, copy = false,
                    move = false, createChildren = false, removeFromParent = false,
                    blocksOpenDocumentTree = false,
                    virtual = false, rawFlags = if (writeCapability) SafProviderFlagBits.SUPPORTS_WRITE else 0,
                ),
            )
        }

        override fun classifyUri(uriString: String): SafUriKind = when {
            uriString.endsWith("/tree/1") -> SafUriKind.TREE
            uriString.contains("/document/") -> SafUriKind.DOCUMENT
            else -> SafUriKind.NON_SAF
        }

        override fun persistedGrants(): List<GrantSnapshot> = emptyList()

        override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome {
            takeCalls += 1
            return TakeOutcome.Persisted
        }

        override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean {
            releaseCalls += 1
            return true
        }

        override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? =
            refFor(tree.uriString + "/document/root-doc")

        override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef? =
            SafUriRef(tree.uriString + "/document/" + documentId)

        override fun documentIdOf(uri: SafUriRef): String? = decodedDocumentIds[uri.uriString]

        override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe =
            if (probeGranted) AccessProbe(ProbeFlag.GRANTED, ProbeFlag.GRANTED)
            else AccessProbe(ProbeFlag.DENIED, ProbeFlag.DENIED)

        override fun queryChildDocuments(tree: SafUriRef, parentDocumentId: String?, limit: Int,
                                         cursorToken: String?, cancel: SafCancelToken): ChildScan {
            childrenByParent[(parentDocumentId ?: "__root__")]?.let { scripted ->
                // Respect the caller's page cap honestly: offset rides the
                // fake cursor token, mirroring the shipped held-cursor paging
                // (a caller that keeps paging converges; budget tests need
                // this to terminate).
                val from = cursorToken?.removePrefix("fake-cursor-")?.toIntOrNull() ?: 0
                val page = scripted.drop(from).take(limit)
                val next = from + page.size
                val more = next < scripted.size
                return ChildScan(documents = page,
                                 nextCursorToken = if (more) "fake-cursor-$next" else null,
                                 truncatedByLimit = more, note = null)
            }
            val childUri = tree.uriString + "/document/kid-1"
            return ChildScan(documents = listOf(documentFor(childUri)), nextCursorToken = null,
                             truncatedByLimit = false, note = null)
        }

        override fun releaseCursor(cursorToken: String) = false
        override fun releaseAllCursors() = Unit

        override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? =
            documentFor(ref.uri.uriString)

        override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef,
                               cancel: SafCancelToken) = true

        override fun openRead(ref: SafDocumentRef, mimeFilter: String?,
                              cancel: SafCancelToken): ReadOpen {
            faultOnOpenRead?.let { throw it }
            if (directoryUris.contains(ref.uri.uriString)) {
                // EXACT device behavior (ExternalStorageProvider): the open
                // itself SUCCEEDS and the first read() faults —
                // ErrnoException message "read failed: EISDIR (Is a
                // directory)" (G05-R3 folder-import failure 2026-10-27).
                eisdirDirectoryReadAttempts.incrementAndGet()
                return ReadOpen.Opened(object : InputStream() {
                    override fun read(): Int = throw IOException("read failed: EISDIR (Is a directory)")
                    override fun read(target: ByteArray, off: Int, len: Int): Int =
                        throw IOException("read failed: EISDIR (Is a directory)")
                }, null)
            }
            val bytes = content[ref.uri.uriString] ?: return ReadOpen.NotFound
            return ReadOpen.Opened(chunking(bytes), bytes.size.toLong())
        }

        /** Real "wt" semantics: the stream REPLACES the stored content when
         * the provider closes it (never appends), so the gateway read-back
         * genuinely reflects the write. */
        var wtOpens = 0
        override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
            faultOnOpenWrite?.let { throw it }
            wtOpens += 1
            val sink = ByteArrayOutputStream()
            val uri = ref.uri.uriString
            return WriteOpen.Opened(object : OutputStream() {
                override fun write(byte: Int) = sink.write(byte)
                override fun write(data: ByteArray, offset: Int, length: Int) =
                    sink.write(data, offset, length)
                override fun close() {
                    content[uri] = sink.toByteArray()
                }
            })
        }

        override fun streamTypes(ref: SafDocumentRef): List<String> = emptyList()

        override fun createDocument(tree: SafUriRef, parentDocumentId: String?, mimeType: String,
                                    displayName: String, cancel: SafCancelToken): OpResult<SafDocumentRef> {
            val created = tree.uriString + "/document/new-" + System.nanoTime()
            content[created] = ByteArray(0)
            return OpResult.Ok(refFor(created))
        }

        override fun renameDocument(ref: SafDocumentRef, newName: String,
                                    cancel: SafCancelToken): OpResult<SafDocumentRef> =
            OpResult.NullReturned("unused in tests")

        override fun moveDocument(ref: SafDocumentRef, destTree: SafUriRef,
                                  destParentDocumentId: String?,
                                  cancel: SafCancelToken): OpResult<SafDocumentRef> =
            OpResult.NullReturned("unused in tests")

        override fun copyDocument(ref: SafDocumentRef, destTree: SafUriRef,
                                  destParentDocumentId: String?,
                                  cancel: SafCancelToken): OpResult<SafDocumentRef> =
            OpResult.NullReturned("unused in tests")

        override fun deleteDocument(ref: SafDocumentRef,
                                    cancel: SafCancelToken): OpResult<Boolean> =
            OpResult.NullReturned("unused in tests")

        override fun selfCheck(): List<String> = emptyList()
    }

    /** Yields at most 64 KiB per read so chunk-bound behavior is exercised. */
    private fun chunking(bytes: ByteArray): InputStream = object : InputStream() {
        private var offset = 0
        override fun read(): Int = if (offset < bytes.size) bytes[offset++].toInt() and 255 else -1
        override fun read(target: ByteArray, off: Int, len: Int): Int {
            if (offset >= bytes.size) return -1
            val count = minOf(len, 65_536, bytes.size - offset)
            System.arraycopy(bytes, offset, target, off, count)
            offset += count
            return count
        }
    }

    // ------------------------------------------------------------------
    // fixtures
    // ------------------------------------------------------------------

    private val channel = FakeChannel()
    private val backend = FakeBackend()
    private val gateway by lazy { SafGatewayService(backend, releaseBroker = SharedUriGrantAuthority.broker) }

    private fun controller() = WorkspaceSourceHostController(
        recoveryRoot = tmpRoot,
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        ioDispatcher = Dispatchers.IO,
        currentNativeEpoch = { epochHolder.get() },
        gatewayProvider = { e -> if (e == epochHolder.get()) gateway else null },
        backendProvider = { e -> if (e == epochHolder.get()) backend else null },
        channel = channel,
    )

    private fun laneFor(controller: WorkspaceSourceHostController) =
        controller.laneFor(task, workspace, epoch, 7L) { ownerLive.get() }!!

    private val docUri = "content://com.floe.testprovider/tree/1/document/src-1"

    private fun acceptImportPick(lane: WorkspaceSourceHostController.Lane, uri: String,
                                 flags: Int = FLAG_READ or FLAG_PERSISTABLE): WorkspaceSourceResult {
        val issued = lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT)!!
        return lane.onPickerResult(issued, uri, flags)
    }

    companion object {
        const val FLAG_READ = 0x00000001
        const val FLAG_WRITE = 0x00000002
        const val FLAG_PERSISTABLE = 0x00000040
    }

    // ------------------------------------------------------------------
    // 1. reply plumbing
    // ------------------------------------------------------------------

    @Test
    fun replyParsingAcceptsNativeBodiesAndRefusesBadOnes() {
        val ok = SourceHostReply.call { buffer ->
            body(buffer, """{"ok":1,"state":"prepared","sourceRevision":"rev-9"}""")
        }
        assertTrue(ok.ok)
        assertEquals("prepared", ok.text("state"))
        assertEquals("rev-9", ok.text("sourceRevision"))

        val refused = SourceHostReply.call { buffer ->
            body(buffer, """{"ok":0,"errorCode":"sourceChangedSinceImport"}""")
        }
        assertFalse(refused.ok)
        assertEquals("sourceChangedSinceImport", refused.errorCode)

        // A reply that is not strict UTF-8 JSON is never guessed.
        val broken = SourceHostReply.call { buffer ->
            byteArrayOf(0xFF.toByte(), 0xFE.toByte()).copyInto(buffer)
            2
        }
        assertFalse(broken.protocolOk)

        // A negative protocol status carries no body.
        val negative = SourceHostReply.call { _ -> -502 }
        assertEquals(-502, negative.status)
        assertNull(negative.body)
    }

    // ------------------------------------------------------------------
    // 2. pick lifecycle + flag truth
    // ------------------------------------------------------------------

    @Test
    fun pickCancelAndStaleIncarnationNeverTouchGrantTruth() {
        val lane = laneFor(controller())
        val issued = lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT)!!
        assertEquals(issued, lane.state.value.pending?.incarnation)
        // Callback for a foreign incarnation: refused, pending intact.
        val stale = lane.onPickerResult(issued + 5, docUri, FLAG_READ or FLAG_PERSISTABLE)
        assertEquals("journalRefused", stale.status)
        assertNotNull(lane.state.value.pending)
        assertNull(lane.state.value.accepted)
        // Dismissal: cancel = NO user grant; pending clears, nothing else.
        val cancelled = lane.onPickerResult(issued, null, 0)
        assertEquals("cancelled", cancelled.status)
        assertNull(lane.state.value.pending)
        assertNull(lane.state.value.accepted)
        // Accept READ|PERSISTABLE: granted + persisted mirror the platform take.
        val accepted = acceptImportPick(lane, docUri)
        assertEquals("ok", accepted.status)
        val pick = lane.state.value.accepted!!
        assertEquals(docUri, pick.uri)
        assertEquals(setOf("READ"), pick.granted)
        assertEquals(setOf("READ"), pick.persisted)
        assertFalse(pick.transientOnly)
    }

    @Test
    fun sessionOnlyPickStaysHonestAboutPersistence() {
        val lane = laneFor(controller())
        // READ without the persistable bit: the session grant stands, but
        // NOTHING claims persistence and re-pick is flagged as the recovery.
        acceptImportPick(lane, docUri, flags = FLAG_READ)
        val pick = lane.state.value.accepted!!
        assertEquals(setOf("READ"), pick.granted)
        assertTrue(pick.transientOnly)
        assertTrue(pick.needsRePick)
        assertEquals(0, backend.takeCalls) // persistable never offered => never taken
    }

    @Test
    fun treeChildSelectionDerivesUriWithoutNewTakeCalls() {
        val lane = laneFor(controller())
        val treeUri = "content://com.floe.testprovider/tree/1"
        val issued = lane.requestPick(PickKind.OPEN_TREE, PickPurpose.IMPORT)!!
        lane.onPickerResult(issued, treeUri, FLAG_READ or FLAG_PERSISTABLE)
        val before = backend.takeCalls
        val outcome = lane.selectTreeChild(treeUri, "kid-1", "kid file")
        assertEquals("ok", outcome.status)
        val pick = lane.state.value.accepted!!
        assertEquals(treeUri + "/document/kid-1", pick.uri)
        assertEquals("kid-1", pick.documentId)
        assertEquals(treeUri, pick.treeAnchor)
        assertEquals(before, backend.takeCalls) // inherited access only, no new take
    }

    // ------------------------------------------------------------------
    // 3. import: every byte streamed in bounded chunks; typed refusals
    // ------------------------------------------------------------------

    @Test
    fun importStreamsEveryByteInBoundedChunksThroughRealGatewayIO() = runBlocking {
        backend.content[docUri] = ByteArray(200_000) { (it % 251).toByte() }
        val lane = laneFor(controller())
        acceptImportPick(lane, docUri)
        val outcome = lane.importAcceptedToWorkspace("Imported/x.bin")
        assertEquals(outcome.detail, "ok", outcome.status)
        val written = channel.stageChunkSizes.values.single()
        assertTrue(written.isNotEmpty())
        assertTrue(written.all { it in 1..65_536 })
        assertEquals(200_000, written.sum())
        // The staged body whose digest native would take is EXACTLY the
        // provider bytes (byte-for-byte, streamed in order). The lane
        // correctly aborts the live scratch after the import (asserted below),
        // so the byte check reads the body archived at stage_finish.
        val stage = channel.finishedStageBodies.values.first { it.first == "import" }
        assertEquals(digest(backend.content.getValue(docUri)), digest(stage.second))
        assertTrue(channel.calls.contains("stageAbort")) // this lane's scratch cleaned up
        assertFalse(lane.state.value.busy)
        assertNull(lane.state.value.progressBytes)
    }

    @Test
    fun importRefusalFromNativeIsTypedAndScratchIsAborted() = runBlocking {
        backend.content[docUri] = ByteArray(10_000)
        channel.failStageWriteStatus = -509
        val lane = laneFor(controller())
        acceptImportPick(lane, docUri)
        val outcome = lane.importAcceptedToWorkspace("Imported/y.bin")
        assertEquals("sizeLimit", outcome.status)
        assertTrue(channel.calls.contains("stageAbort"))
        channel.failStageWriteStatus = 0
    }

    @Test
    fun importDeniedGrantMapsToTheActionableRePickFamily() = runBlocking {
        backend.content[docUri] = "data".toByteArray()
        val lane = laneFor(controller())
        val issued = lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT)!!
        lane.onPickerResult(issued, docUri, FLAG_READ) // session-only pick
        backend.probeGranted = false // the live truth now denies it
        val outcome = lane.importAcceptedToWorkspace("Imported/z.bin")
        assertTrue("actual: ${outcome.status}",
                   outcome.status in setOf("rePickRequired", "revoked", "grantMissing"))
        // The staged ticket that was already open is aborted, never leaked.
        assertTrue(channel.calls.contains("stageAbort"))
        backend.probeGranted = true
    }

    // ------------------------------------------------------------------
    // 4. save ladder: order, ONE-TIME permit, settle truth
    // ------------------------------------------------------------------

    private fun scriptSavedRow(saveUri: String, original: ByteArray) {
        backend.content[saveUri] = original
        channel.recordedSha = digest(original)
        channel.sourceLookupBody = """{"ok":1,"id":"row-1","kind":"saf","path":"docs/doc.txt",""" +
            """"reference":"$saveUri","documentID":"save-1",""" +
            """"sha256":"${digest(original)}","revision":"rev-1"}"""
    }

    @Test
    fun saveLadderRunsJournalOrderAndPermitsDestructiveWriteOnce() = runBlocking {
        val original = "provider original".toByteArray()
        val replacement = "edited working copy".toByteArray()
        val saveUri = "content://com.floe.testprovider/tree/1/document/save-1"
        scriptSavedRow(saveUri, original)
        channel.egressContent = replacement
        val lane = laneFor(controller())
        val outcome = lane.savePathToProvider("docs/doc.txt")
        assertEquals(outcome.detail, "ok", outcome.status)
        val order = channel.calls.filter {
            it.startsWith("sourceLookup") || it.startsWith("egressOpen") || it.startsWith("stageOpen") ||
                it == "savePrepare" || it == "saveClaim" || it == "savePermit" ||
                it == "saveSettle" || it == "egressClose"
        }
        assertEquals(
            listOf("sourceLookup", "egressOpen:save", "stageOpen:backup-verify", "savePrepare",
                   "stageOpen:fresh-observe", "saveClaim", "savePermit", "stageOpen:readback",
                   "saveSettle", "egressClose"),
            order,
        )
        // The gateway really wrote the replacement through the "wt" stream.
        assertEquals(digest(replacement), digest(backend.content.getValue(saveUri)))
        // The permit was handed exactly once.
        assertEquals(1, channel.permitCounts.values.sum())
        // The recovery original stays on disk (never deleted by this lane)…
        val recoveries = tmpRoot.listFiles()?.filter { it.name.endsWith(".recovery") } ?: emptyList()
        assertTrue(recoveries.isNotEmpty())
        assertEquals(digest(original), digest(recoveries.first().readBytes()))
        // …while the replacement transfer scratch is removed after the commit.
        assertTrue(tmpRoot.listFiles()?.none { it.name.startsWith("replacement-") } == true)
    }

    @Test
    fun saveRefusesDestructiveWriteWhenJournalReportsDrift() = runBlocking {
        val original = "untouched provider".toByteArray()
        val saveUri = "content://com.floe.testprovider/tree/1/document/drift-1"
        scriptSavedRow(saveUri, original)
        channel.recordedSha = digest("something else".toByteArray()) // scripted drift
        channel.egressContent = "edited".toByteArray()
        val lane = laneFor(controller())
        val outcome = lane.savePathToProvider("docs/doc.txt")
        assertEquals("sourceChangedSinceImport", outcome.status)
        // NOTHING destructive touched the provider; the ladder stopped before
        // claim/settle and honestly retained/abandoned.
        assertEquals(digest(original), digest(backend.content.getValue(saveUri)))
        assertFalse(channel.calls.contains("saveClaim"))
        assertFalse(channel.calls.contains("saveSettle"))
        assertTrue(channel.calls.contains("saveRetain"))
        assertTrue(channel.calls.contains("egressClose"))
    }

    @Test
    fun saveSettleConflictIsNeverRelabeledAndPermitReplayRefused() = runBlocking {
        val original = "provider original".toByteArray()
        val replacement = "edited working copy".toByteArray()
        val saveUri = "content://com.floe.testprovider/tree/1/document/conf-1"
        scriptSavedRow(saveUri, original)
        channel.egressContent = replacement
        channel.settleMatches = false // native read-back will not match
        val lane = laneFor(controller())
        val outcome = lane.savePathToProvider("docs/doc.txt")
        channel.settleMatches = true
        assertEquals("conflict", outcome.status)
        // The provider holds the write, the JOURNAL refused the commit: the
        // observed digest is reported and reconcile owns the next step.
        assertEquals(digest(replacement), digest(backend.content.getValue(saveUri)))
        // Permit was asked exactly once by the gateway and answered once.
        assertEquals(1, channel.permitCounts.values.sum())
        assertTrue(outcome.facts.containsKey("observedSHA256"))
        assertEquals(digest(replacement), outcome.facts["observedSHA256"])
    }

    @Test
    fun refusedNativePermitStopsTheDestructiveWriteAndSettlesHonest() = runBlocking {
        val original = "provider original".toByteArray()
        val replacement = "edited working copy".toByteArray()
        val saveUri = "content://com.floe.testprovider/tree/1/document/permit-1"
        scriptSavedRow(saveUri, original)
        channel.egressContent = replacement
        channel.refusePermit = true // the native session will not hand a permit
        val lane = laneFor(controller())
        val outcome = lane.savePathToProvider("docs/doc.txt")
        channel.refusePermit = false
        // The gateway refused the destructive write (no "wt" open); the lane
        // STILL ran the native settle and reported the journal's verdict —
        // provider bytes never matched the replacement -> conflict, never a
        // retry-to-green or a fake success.
        assertEquals(digest(original), digest(backend.content.getValue(saveUri)))
        assertEquals(0, backend.wtOpens)
        assertTrue("actual: " + outcome.status,
                   outcome.status == "conflict" || outcome.status == "providerOffline")
        assertTrue(channel.calls.contains("savePermit"))
        assertTrue(channel.calls.contains("saveSettle") || channel.calls.contains("saveRetain"))
    }

    // ------------------------------------------------------------------
    // 5. release gating + reconcile runs
    // ------------------------------------------------------------------

    @Test
    fun releaseRequiresDurableRowsAndNoUnfinishedRecovery() = runBlocking {
        val bound = "content://com.floe.testprovider/tree/1/document/rev-1"
        channel.sourcePageBody = """{"ok":1,"rows":[{"id":"row-r","kind":"saf","path":"docs/r.txt",""" +
            """"reference":"$bound","documentID":"rev-1","sha256":"","revision":"rev-1"}]}"""
        channel.recoveryPageBody = """{"ok":1,"rows":[{"id":"rec-1","sourceID":"row-r","state":"prepared",""" +
            """"backupSHA256":"aa","replacementSHA256":"bb","observedSHA256":"",""" +
            """"reference":"$bound","revision":"rev-1"}]}"""
        val lane = laneFor(controller())
        lane.refresh()
        val blocked = lane.revoke(bound)
        assertEquals("journalRefused", blocked.status)
        assertEquals(0, backend.releaseCalls)
        // Unknown references are never releasable (durable-rows gate).
        assertEquals("unbound", lane.revoke("content://other/tree/9/document/1").status)
        // With no unfinished receipt and a pick THIS gateway instance
        // persisted (then dropped), release runs through the broker.
        channel.recoveryPageBody = """{"ok":1,"rows":[]}"""
        lane.refresh()
        val issued = lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT)!!
        lane.onPickerResult(issued, bound, FLAG_READ or FLAG_PERSISTABLE)
        lane.clearAccepted() // drops this lane's references; OS grant stands
        val released = lane.revoke(bound)
        assertEquals(released.detail, "ok", released.status)
        assertEquals(1, backend.releaseCalls) // READ only (WRITE never granted)
    }

    @Test
    fun reconcileAndStagedReconcileRunThroughNativeOnly() = runBlocking {
        val row = WorkspaceSourceRowUi(
            id = UUID.randomUUID().toString(), path = "docs/r.txt", kind = "saf",
            reference = "content://com.floe.testprovider/tree/1/document/rev-1",
            documentID = "rev-1", sha256 = "", revision = "rev-1",
        )
        // Fixture precondition: the staged receipt reconcile streams the
        // provider's CURRENT bytes into native staging and lets NATIVE's
        // digest decide, so this durable row must exist on the provider —
        // otherwise the honest typed verdict really is "notFound".
        backend.content[row.reference] = "current provider bytes".toByteArray()
        channel.sourcePageBody = """{"ok":1,"rows":[{"id":"${row.id}","kind":"saf",""" +
            """"path":"${row.path}","reference":"${row.reference}",""" +
            """"documentID":"${row.documentID}","sha256":"","revision":"${row.revision}"}]}"""
        val lane = laneFor(controller())
        val outcome = lane.reconcile()
        assertEquals("ok", outcome.status)
        assertTrue(channel.calls.contains("reconcileRun"))
        assertTrue(channel.calls.contains("sourcePage"))
        val staged = lane.reconcileReceipt(UUID.randomUUID().toString(), row)
        assertEquals(staged.detail, "ok", staged.status)
        assertEquals("conflict", staged.facts["state"]) // scripted single-receipt verdict
        assertTrue(channel.calls.contains("stageOpen:readback"))
        assertTrue(channel.calls.contains("reconcileStaged"))
        assertFalse(lane.state.value.busy)
    }

    // ------------------------------------------------------------------
    // 6. fences: epoch rebind, retirement, busy serialization
    // ------------------------------------------------------------------

    @Test
    fun reboundEpochAndRetiredLaneFailClosed() = runBlocking {
        backend.content[docUri] = "x".toByteArray()
        val controller = controller()
        val lane = laneFor(controller)
        acceptImportPick(lane, docUri)
        epochHolder.set(epoch + 1) // the root rebound under this lane
        assertEquals("runtimeUnavailable", lane.importAcceptedToWorkspace("Imported/f.bin").status)
        epochHolder.set(epoch)
        controller.retireEpoch(epoch)
        assertNull(controller.laneFor(task, workspace, epoch, 8L) { true })
        assertEquals("runtimeUnavailable", lane.importAcceptedToWorkspace("Imported/f.bin").status)
    }

    @Test
    fun lateConstructedLaneCannotReadAfterRootRetirement() = runBlocking {
        val controller = controller()
        controller.retireEpoch(epoch)
        // Models a constructor finishing after retireEpoch took its lane
        // snapshot, while the captured native-epoch pointer still looks old.
        val late = controller.Lane(taskID = task, workspaceID = workspace,
            nativeEpoch = epoch, initialGeneration = 8L, initialOwner = { true })
        assertEquals("runtimeUnavailable", late.importAcceptedToWorkspace("Imported/late.bin").status)
        assertFalse(late.state.value.busy)
        assertTrue("retired wrappers must not start native/provider IO", channel.calls.isEmpty())
    }

    @Test
    fun concurrentOperationsAreRefusedWhileOneLadderOwnsTheLane() = runBlocking {
        backend.content[docUri] = ByteArray(300_000)
        channel.chunkDelayMillis = 4 // 5 chunks keep the lane busy ~20 ms
        val lane = laneFor(controller())
        acceptImportPick(lane, docUri)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val first = scope.async { lane.importAcceptedToWorkspace("Imported/slow.bin") }
        val deadline = System.currentTimeMillis() + 5_000
        while (!lane.state.value.busy && System.currentTimeMillis() < deadline) delay(2)
        assertTrue("the first import never reached busy", lane.state.value.busy)
        val second = lane.importAcceptedToWorkspace("Imported/second.bin")
        assertEquals("journalRefused", second.status)
        val settled = withTimeoutOrNull(20_000) { first.join(); true }
        assertNotNull(settled)
        assertEquals("ok", first.getCompleted().status)
        channel.chunkDelayMillis = 0
        assertFalse(lane.state.value.busy)
    }

    // ------------------------------------------------------------------
    // 7. save-as: egress down + native verify, platform identity decode,
    //    and the CLOSED backend-fault diagnostic route (provider IO repair
    //    2026-10-25). AUTHORED, NOT RUN — Main's composed batch executes it.
    // ------------------------------------------------------------------

    private fun acceptSaveTargetPick(lane: WorkspaceSourceHostController.Lane, uri: String): WorkspaceSourceResult {
        val issued = lane.requestPick(
            PickKind.CREATE_DOCUMENT, PickPurpose.SAVE_TARGET,
            mimeTypes = listOf("text/plain"), suggestedName = "sample.py",
        )!!
        return lane.onPickerResult(issued, uri, FLAG_READ or FLAG_WRITE or FLAG_PERSISTABLE)
    }

    @Test
    fun pickerDocumentIdComesFromPlatformDecodeNotRawSegment() = runBlocking {
        // A tree-SCOPED child URI must carry the CHILD's platform id (the
        // decoded form), never the percent-encoded raw segment and never the
        // tree ROOT's id — AndroidSafBackend.documentIdOf answers
        // isDocumentUri FIRST precisely for this (Main steer 2026-10-25).
        val scopedChild = "content://com.android.externalstorage.documents/tree/primary%3A/document/primary%3ADownload%2Fsample.py"
        backend.decodedDocumentIds[scopedChild] = "primary:Download/sample.py"
        backend.decodedDocumentIds["content://com.android.externalstorage.documents/tree/primary%3A"] = "primary:"
        channel.egressContent = "print(\"G04 start\")\n".toByteArray()
        val lane = laneFor(controller())
        assertEquals("ok", acceptSaveTargetPick(lane, scopedChild).status)
        val pick = lane.state.value.accepted!!
        assertEquals("primary:Download/sample.py", pick.documentId) // CHILD id, not "primary:" and not "%3A" garbage
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals(outcome.detail, "ok", outcome.status)
        // The same child identity rode the native export-verify hop.
        val verifyTicket = channel.stages.keys.single { channel.stages.getValue(it).first == "export-verify" }
        assertEquals("primary:Download/sample.py", channel.stageDocumentIds[verifyTicket])
        assertArrayEquals(channel.egressContent, backend.content.getValue(scopedChild))
        assertTrue(channel.calls.contains("egressVerify"))
        assertFalse(channel.calls.contains("stageAbort")) // verify consumed, nothing leaked
    }

    @Test
    fun pickerWithoutPlatformDecodeStoresHonestNullNotEncodedGuess() = runBlocking {
        val scopedChild = "content://p/tree/primary%3A/document/primary%3ADownload%2Fx.py"
        // No decode-table entry: an unavailable platform answer is stored as
        // an honest absence — never a raw-segment guess like "primary%3A...".
        val lane = laneFor(controller())
        assertEquals("ok", acceptSaveTargetPick(lane, scopedChild).status)
        assertNull(lane.state.value.accepted!!.documentId)
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals(outcome.detail, "ok", outcome.status)
        val verifyTicket = channel.stages.keys.single { channel.stages.getValue(it).first == "export-verify" }
        assertEquals("", channel.stageDocumentIds[verifyTicket]) // stageOpen received "" — no poisoned id
    }

    @Test
    fun saveAsWriteFaultCarriesClosedStageAndClassDiagnostic() = runBlocking {
        val newDoc = "content://com.floe.testprovider/tree/1/document/new-write-fault"
        channel.egressContent = "x".toByteArray()
        backend.faultOnOpenWrite = SafBackendFaultException(
            SafBackendFault.FAILED, "openWrite.ProviderSocketException",
        )
        val lane = laneFor(controller())
        acceptSaveTargetPick(lane, newDoc)
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals("failed", outcome.status)
        // The closed token names exactly WHERE (openWrite) and WHICH class
        // failed — the stage previously invisible behind "provider failure".
        assertEquals("provider failure [diagnostic:openWrite.ProviderSocketException]", outcome.detail)
        // The ladder stopped BEFORE the read-back hop; the egress ticket closed.
        assertFalse(channel.calls.contains("stageOpen:export-verify"))
        assertTrue(channel.calls.contains("egressClose"))
        assertNull(backend.content[newDoc]) // nothing written, nothing promoted
        assertFalse(lane.state.value.busy)
    }

    @Test
    fun saveAsReadbackFaultKeepsCreatedDocumentAndNamesReadbackStage() = runBlocking {
        val newDoc = "content://com.floe.testprovider/tree/1/document/new-readback-fault"
        val written = "print(\"G04 start\")\n".toByteArray()
        channel.egressContent = written
        backend.faultOnOpenRead = SafBackendFaultException(
            SafBackendFault.FAILED, "openRead.RemoteUriException",
        )
        val lane = laneFor(controller())
        acceptSaveTargetPick(lane, newDoc)
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals("failed", outcome.status)
        assertEquals("provider failure [diagnostic:openRead.RemoteUriException]", outcome.detail)
        // The write ACTUALLY settled; the created document keeps its bytes.
        // A read-back failure is never turned into a delete or a success.
        assertArrayEquals(written, backend.content.getValue(newDoc))
        assertFalse(channel.calls.contains("egressVerify")) // native verify never ran
        assertTrue(channel.calls.contains("stageAbort"))    // live verify stage aborted
        assertTrue(channel.calls.contains("egressClose"))
    }

    @Test
    fun saveAsBackendFaultDetailWithoutClosedGrammarLeaksNothing() = runBlocking {
        val newDoc = "content://com.floe.testprovider/tree/1/document/new-raw-fault"
        channel.egressContent = "x".toByteArray()
        backend.faultOnOpenWrite = SafBackendFaultException(
            SafBackendFault.FAILED,
            "open failed: content://com.example/private?token=leak header Secret",
        )
        val lane = laneFor(controller())
        acceptSaveTargetPick(lane, newDoc)
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals("failed", outcome.status)
        assertEquals("provider failure", outcome.detail) // closed UI text ONLY
        assertFalse(outcome.detail.contains("content://"))
        assertFalse(outcome.detail.contains("token"))
        assertFalse(outcome.detail.contains("Secret"))
    }

    @Test
    fun saveAsWithDirectDocumentUriPreservesGrantedRefExact() = runBlocking {
        // CREATE_DOCUMENT results are DIRECT /document/ URIs with no tree
        // anchor. The lane must keep the granted URI byte-exact through the
        // write, verify hop and read-back metadata — no tree-scoped synthesis
        // is ever invented for a direct pick (AndroidSafBackend
        // mapQueriedDocument fix, Main review 2026-10-25: the old mapRow
        // forced EVERY direct import / save-as read-back through
        // buildDocumentUriUsingTree, whose IAE surfaced as "provider failure").
        val direct = "content://com.android.externalstorage.documents/document/primary%3ADownload%2Fsample.py"
        backend.decodedDocumentIds[direct] = "primary:Download/sample.py"
        channel.egressContent = "print(\"G04 start\")\n".toByteArray()
        val lane = laneFor(controller())
        assertEquals("ok", acceptSaveTargetPick(lane, direct).status)
        val pick = lane.state.value.accepted!!
        assertEquals(direct, pick.uri)
        assertNull(pick.treeAnchor)
        assertEquals("primary:Download/sample.py", pick.documentId)
        val outcome = lane.saveAsAccepted("sample.py")
        assertEquals(outcome.detail, "ok", outcome.status)
        assertEquals(direct, outcome.facts["created"]) // EXACT granted URI published back
        assertArrayEquals(channel.egressContent, backend.content.getValue(direct))
        val verifyTicket = channel.stages.keys.single { channel.stages.getValue(it).first == "export-verify" }
        assertEquals("primary:Download/sample.py", channel.stageDocumentIds[verifyTicket])
    }

    @Test
    fun importReadsMetadataAndBytesOfDirectDocumentUri() = runBlocking {
        // The actual G04 unicode fixture shape: a direct OPEN_DOCUMENT URI.
        // Import queries metadata on the EXACT granted URI (never a
        // synthesized tree-scoped one) and streams every byte.
        val direct = "content://com.android.externalstorage.documents/document/primary%3AG04%2Fg04-unicode.py.bin"
        val bytes = ByteArray(4096) { (it % 97).toByte() }
        backend.content[direct] = bytes
        backend.decodedDocumentIds[direct] = "primary:G04/g04-unicode.py.bin"
        val lane = laneFor(controller())
        assertEquals("ok", acceptImportPick(lane, direct).status)
        assertEquals("primary:G04/g04-unicode.py.bin", lane.state.value.accepted!!.documentId)
        val outcome = lane.importAcceptedToWorkspace("Imported/g04-unicode.py.bin")
        assertEquals(outcome.detail, "ok", outcome.status)
        val stage = channel.finishedStageBodies.values.first { it.first == "import" }
        assertArrayEquals(bytes, stage.second)
    }

    // ------------------------------------------------------------------
    // 3b. FOLDER import (G05-R3 repair 2026-10-27): the device failure was
    // "ioFailed / read failed: EISDIR (Is a directory)" because the single-
    // document ladder opened the tree root's OWN descriptor. The walk must
    // traverse the scoped provider tree, validate names, and run the
    // ORIGINAL per-file ladder once per child — never streaming a directory,
    // never fabricating an empty success, never taking new permissions.
    // ------------------------------------------------------------------

    private fun fileDoc(tree: SafUriRef, docId: String, name: String, bytes: ByteArray?,
                        virtual: Boolean = false): SafDocument {
        val uri = tree.uriString + "/document/" + docId
        if (bytes != null) backend.content[uri] = bytes
        return SafDocument(
            ref = SafDocumentRef(tree = tree, documentId = docId, parentDocumentId = null,
                                 uri = SafUriRef(uri)),
            displayName = name, mimeType = "application/octet-stream",
            size = bytes?.let { SafSize.Known(it.size.toLong()) } ?: SafSize.Unknown,
            lastModifiedMillis = null,
            capabilities = SafCapabilities(
                write = false, delete = false, rename = false, copy = false, move = false,
                createChildren = false, removeFromParent = false, blocksOpenDocumentTree = false,
                virtual = virtual, rawFlags = 0,
            ),
        )
    }

    private fun dirDoc(tree: SafUriRef, docId: String, name: String): SafDocument {
        val uri = tree.uriString + "/document/" + docId
        backend.directoryUris += uri
        return SafDocument(
            ref = SafDocumentRef(tree = tree, documentId = docId, parentDocumentId = null,
                                 uri = SafUriRef(uri)),
            displayName = name, mimeType = SafDocument.MIME_DIR, size = SafSize.Unknown,
            lastModifiedMillis = null,
            capabilities = SafCapabilities(
                write = true, delete = false, rename = false, copy = false, move = false,
                createChildren = true, removeFromParent = false, blocksOpenDocumentTree = false,
                virtual = false, rawFlags = 0,
            ),
        )
    }

    private fun acceptTreeImportPick(lane: WorkspaceSourceHostController.Lane, treeUri: String,
                                     flags: Int = FLAG_READ or FLAG_PERSISTABLE): WorkspaceSourceResult {
        val issued = lane.requestPick(PickKind.OPEN_TREE, PickPurpose.IMPORT)!!
        return lane.onPickerResult(issued, treeUri, flags)
    }

    @Test
    fun folderImportTraversesTreeAndNeverStreamsTheDirectory() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        val tree = SafUriRef(treeUri)
        // EXACT device fixture shape: one granted folder with ordinary
        // files and one subfolder; the root itself is a DIRECTORY document.
        backend.directoryUris += treeUri + "/document/root-doc" // resolveTreeRoot target
        backend.decodedDocumentIds[treeUri] = "primary:Download/Floe-G05-R3-QA"
        backend.childrenByParent["__root__"] = listOf(
            fileDoc(tree, "a-doc", "a.docx", "docx-bytes".toByteArray()),
            fileDoc(tree, "b-doc", "b.xlsx", "xlsx-bytes!".toByteArray()),
            dirDoc(tree, "sub-doc", "sub"),
        )
        backend.childrenByParent["sub-doc"] = listOf(
            fileDoc(tree, "c-doc", "c.pptx", ByteArray(300_000) { (it % 251).toByte() }),
        )
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val takesBefore = backend.takeCalls
        val outcome = lane.importAcceptedToWorkspace("qa")
        // (1) the ACTUAL failure must be gone: honest success, zero
        // directory reads.
        assertEquals(outcome.detail, "ok", outcome.status)
        assertEquals(0, backend.eisdirDirectoryReadAttempts.get())
        // (2) exactly ONE native stage per child, on the child's reserved
        // workspace path + EXACT child identity (never the tree root's).
        val importTickets = channel.stagePaths.filterValues { it.startsWith("qa/") }
        assertEquals(setOf("qa/a.docx", "qa/b.xlsx", "qa/sub/c.pptx"), importTickets.values.toSet())
        importTickets.forEach { (ticket, path) ->
            val docId = path.substringAfterLast('/')
            val expected = when (docId) {
                "a.docx" -> "a-doc"
                "b.xlsx" -> "b-doc"
                else -> "c-doc"
            }
            assertEquals(expected, channel.stageDocumentIds[ticket])
            assertEquals(treeUri + "/document/" + expected, channel.stageReferences[ticket])
        }
        // (3) every staged body is byte-exact against the provider content.
        // Key order matches the existing fake API: stagePaths is
        // Map<Long ticket, String logicalPath>, same as the forEach above.
        for ((ticket, path) in importTickets) {
            val expectedUri = treeUri + "/document/" + when (path) {
                "qa/a.docx" -> "a-doc"; "qa/b.xlsx" -> "b-doc"; else -> "c-doc"
            }
            assertArrayEquals(backend.content.getValue(expectedUri),
                              channel.finishedStageBodies.getValue(ticket).second)
        }
        // (4) summary facts + no permission drift + scratch released.
        assertEquals("3", outcome.facts["imported"])
        assertEquals("docx-bytes".toByteArray().size + "xlsx-bytes!".toByteArray().size + 300_000,
                     outcome.facts["committedBytes"]!!.toInt())
        assertEquals(takesBefore, backend.takeCalls) // traversal rides the EXISTING tree grant
        assertEquals(3, channel.calls.count { it == "stageAbort" })
        assertFalse(lane.state.value.busy)
    }

    @Test
    fun fileRouteRefusesDirectoryEntryWithTypedUnsupportedAndAbortsScratch() = runBlocking {
        // Defense-in-depth for the provider misclassification edge: if the
        // metadata row SAYS directory, the single-document route must refuse
        // typed — the EISDIR class of failure can no longer reach staging.
        val dirUri = "content://com.floe.testprovider/tree/1/document/dir-doc"
        backend.directoryUris += dirUri
        backend.decodedDocumentIds[dirUri] = "primary:Download/SomeDir"
        val lane = laneFor(controller())
        assertEquals("ok", acceptImportPick(lane, dirUri).status)
        val outcome = lane.importAcceptedToWorkspace("x.bin")
        assertEquals("unsupported", outcome.status)
        assertTrue(outcome.detail, outcome.detail.contains("folder"))
        assertEquals(0, backend.eisdirDirectoryReadAttempts.get())
        assertTrue(channel.calls.contains("stageAbort"))
    }

    @Test
    fun emptyFolderImportFailsClosedAndOpensNoStages() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        backend.directoryUris += treeUri + "/document/root-doc"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Empty"
        backend.childrenByParent["__root__"] = emptyList()
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val outcome = lane.importAcceptedToWorkspace("qa")
        // Never an empty success: an honest typed refusal.
        assertEquals("unsupported", outcome.status)
        assertTrue(outcome.detail, outcome.detail.contains("no files to import"))
        assertEquals(0, channel.calls.count { it == "stageOpen:import" })
        assertEquals(0, backend.eisdirDirectoryReadAttempts.get())
    }

    @Test
    fun folderImportRefusesDuplicateTargetNamesBeforeCommittingAnything() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        val tree = SafUriRef(treeUri)
        backend.directoryUris += treeUri + "/document/root-doc"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Dupes"
        backend.childrenByParent["__root__"] = listOf(
            fileDoc(tree, "x1", "same.bin", "one".toByteArray()),
            fileDoc(tree, "x2", "same.bin", "two".toByteArray()),
        )
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val outcome = lane.importAcceptedToWorkspace("qa")
        assertEquals("conflict", outcome.status)
        assertTrue(outcome.detail, outcome.detail.contains("share the same name"))
        assertTrue(outcome.detail, outcome.detail.contains("nothing was imported"))
        assertEquals(0, channel.calls.count { it == "stageOpen:import" })
    }

    @Test
    fun folderImportSkipsVirtualChildrenHonestlyAndImportsTheRest() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        val tree = SafUriRef(treeUri)
        backend.directoryUris += treeUri + "/document/root-doc"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Mixed"
        backend.childrenByParent["__root__"] = listOf(
            fileDoc(tree, "real-doc", "real.bin", "real bytes".toByteArray()),
            fileDoc(tree, "virt-doc", "live.drawing", null, virtual = true),
        )
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val outcome = lane.importAcceptedToWorkspace("qa")
        assertEquals(outcome.detail, "ok", outcome.status)
        assertEquals("1", outcome.facts["imported"])
        assertTrue(outcome.detail, outcome.detail.contains("skipped 1 live item"))
        assertEquals(setOf("qa/real.bin"), channel.stagePaths.values.toSet())
        assertEquals(0, backend.eisdirDirectoryReadAttempts.get())
    }

    @Test
    fun folderImportDepthBudgetRefusesTheWholeWalkBeforeCommitting() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        val tree = SafUriRef(treeUri)
        backend.directoryUris += treeUri + "/document/root-doc"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Deep"
        // A 10-deep directory chain exceeds the 8-level budget.
        var parentKey = "__root__"
        for (level in 1..10) {
            val dirId = "d$level"
            backend.childrenByParent[parentKey] = listOf(dirDoc(tree, dirId, "dir$level"))
            parentKey = dirId
        }
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val outcome = lane.importAcceptedToWorkspace("qa")
        assertEquals("unsupported", outcome.status)
        assertTrue(outcome.detail, outcome.detail.contains("too deeply"))
        assertEquals(0, channel.calls.count { it == "stageOpen:import" })
    }

    @Test
    fun folderImportOwnerFenceMidBatchReportsCommittedChildrenAndStops() = runBlocking {
        val treeUri = "content://com.floe.testprovider/tree/1"
        val tree = SafUriRef(treeUri)
        backend.directoryUris += treeUri + "/document/root-doc"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Fence"
        backend.childrenByParent["__root__"] = listOf(
            fileDoc(tree, "f1", "one.bin", "first".toByteArray()),
            fileDoc(tree, "f2", "two.bin", "second".toByteArray()),
        )
        val lane = laneFor(controller())
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        // Drop the owner fence at the FIRST child's commit point: the batch
        // must stop honestly at the next boundary, never pump into a newer
        // root, and never pretend the un-imported second file landed.
        channel.onStageFinished = { path -> if (path == "qa/one.bin") ownerLive.set(false) }
        val outcome = lane.importAcceptedToWorkspace("qa")
        channel.onStageFinished = null
        ownerLive.set(true)
        assertEquals("runtimeUnavailable", outcome.status)
        assertEquals("1", outcome.facts["imported"])
        assertEquals(setOf("qa/one.bin"), channel.stagePaths.values.toSet())
        assertTrue(outcome.detail, outcome.detail.contains("stopped after 1 complete file"))
    }

    @Test
    fun directPicksKeepOpaqueIdsOpaqueAndBrowseChildKeepsTheProviderName() {
        // G05-R3 companion rule (Main review 2026-10-27): a SAF document id
        // is an OPAQUE provider identity — decoded or not — and must NEVER
        // be converted into a user-facing "display name". Direct platform
        // picks therefore store the identity truth in uri/documentId with an
        // honest display-name ABSENCE; only a browse-child selection, which
        // carries the provider's real DISPLAY_NAME column, supplies a name.
        val lane = laneFor(controller())
        val treeUri = "content://com.floe.testprovider/tree/1"
        backend.decodedDocumentIds[treeUri] = "primary:Download/Floe-G05-R3-QA"
        assertEquals("ok", acceptTreeImportPick(lane, treeUri).status)
        val treePick = lane.state.value.accepted!!
        assertEquals("TREE", treePick.kind)
        assertEquals("primary:Download/Floe-G05-R3-QA", treePick.documentId) // identity kept
        assertNull(treePick.displayName)                                      // name NOT guessed
        val fileUri = "content://com.floe.testprovider/tree/1/document/f-doc"
        backend.decodedDocumentIds[fileUri] = "primary:Download/paragraphs-unicode.docx"
        assertEquals("ok", acceptImportPick(lane, fileUri).status)
        assertEquals("primary:Download/paragraphs-unicode.docx",
                     lane.state.value.accepted!!.documentId)
        assertNull(lane.state.value.accepted!!.displayName)
        // The browsed child row's displayName is REAL provider metadata and
        // stays usable (no new IO, no new take calls).
        val child = lane.selectTreeChild(treeUri, "kid-1", "Quarterly report")
        assertEquals("ok", child.status)
        assertEquals("Quarterly report", lane.state.value.accepted!!.displayName)
        assertEquals(treeUri, lane.state.value.accepted!!.treeAnchor)
    }
}
