// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.host.OfficeSaveCopyHandoff
import com.floe.android.host.OfficeSaveCopySettlement
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Integration tests for the Save-Copy handoff's durable recovery transitions:
 * OUTPUT_READY is journaled before a picker can be prepared, TRANSFERRING +
 * target are journaled BEFORE the scheduled transfer, cancellation never
 * journals a target, and only a real destination read-back becomes SAVED.
 * The SAF provider is an in-memory fake; no Android/framework call is used.
 */
class OfficeSaveCopyRecoveryJournalTest {

    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private class FakeDoc(val uriString: String, var name: String, var content: ByteArray)

    private class FakeBackend : SafPlatformBackend {
        val docs = LinkedHashMap<String, FakeDoc>()
        val session = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
        val persisted = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
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
                TakeOutcome.Refused("flag not granted")
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

    private class FakeJournal : OfficeRecoveryJournalSink {
        val events = ArrayList<String>()
        var outputReadyResult = true
        var transferResult = true
        var lastFacts: OfficeRecoverySaveFacts? = null
        var lastOutput: OfficeSaveReceipt? = null
        var lastTarget: String? = null

        override fun recordFlush(candidateId: String, workingCopySha256: String, workingCopyBytes: Long) {
            events += "flush"
        }

        override fun recordOutputReady(candidateId: String, receipt: OfficeSaveReceipt): Boolean {
            events += "output"
            lastOutput = receipt
            return outputReadyResult
        }

        override fun markTransferStarted(candidateId: String, opId: String, targetUri: String): Boolean {
            events += "transfer"
            lastTarget = targetUri
            return transferResult
        }

        override fun settleSave(candidateId: String, opId: String, facts: OfficeRecoverySaveFacts) {
            lastFacts = facts
            events += if (facts.saved) "settle-saved" else "settle-${facts.code}"
        }
    }

    private inner class Fixture {
        val outputsRoot = newDir("host-outputs")
        val stagingRoot = newDir("host-staging")
        val backend = FakeBackend()
        val service = SafGatewayService(backend)
        val journal = FakeJournal()
        val settlements = ArrayList<OfficeSaveCopySettlement>()
        val events = ArrayList<String>()
        var eventsAtSchedule: List<String> = emptyList()
        val handoff = OfficeSaveCopyHandoff(
            service = service,
            backend = backend,
            stagingRoot = stagingRoot,
            outputsRoot = outputsRoot,
            scheduler = { block ->
                eventsAtSchedule = journal.events.toList()
                block(SafCancelToken())
                events += "scheduled"
                true
            },
            settlementSink = { settlements += it },
            onSessionsIdle = {},
            recoveryJournal = journal,
            journalEligibility = { _, _ -> true },
        )

        init {
            assertEquals(
                true,
                handoff.beginSession(TOKEN, "Report.docx", null, "candidate-1") { true },
            )
        }

        fun moduleOutput(op: String, content: ByteArray, format: String = "docx"): Triple<String, String, Long> {
            val dir = File(outputsRoot, GENERATION.toString())
            check(dir.isDirectory || dir.mkdirs())
            val file = File(dir, "$op-1234.$format")
            file.writeBytes(content)
            return Triple(file.absolutePath, sha(content), content.size.toLong())
        }

        fun receipt(
            op: String,
            path: String,
            digest: String,
            bytes: Long,
            state: OfficeSaveState = OfficeSaveState.OUTPUT_READY,
            operation: OfficeSaveOperation = OfficeSaveOperation.STAGED_EXPORT,
            format: String? = "docx",
            workingCopySha: String? = null,
            workingCopyBytes: Long = 0L,
        ): OfficeSaveReceipt = OfficeSaveReceipt(
            opId = op,
            sessionToken = TOKEN,
            generation = GENERATION,
            operation = operation,
            state = state,
            format = format,
            suggestedName = "Report.docx",
            expectedBaseSha256 = null,
            workingCopySha256 = workingCopySha,
            workingCopyBytes = workingCopyBytes,
            outputDocumentPath = if (state == OfficeSaveState.OUTPUT_READY) path else null,
            outputSha256 = if (state == OfficeSaveState.OUTPUT_READY) digest else null,
            outputBytes = if (state == OfficeSaveState.OUTPUT_READY) bytes else 0L,
            failure = null,
            message = null,
            cancelRequested = false,
            attestation = "test",
            submittedAtElapsedMs = 1L,
            completedAtElapsedMs = 2L,
        )

        fun prepare(op: String): OfficeHostSaveHandoffPolicy.PrepareRequest =
            OfficeHostSaveHandoffPolicy.PrepareRequest(op, TOKEN, GENERATION, "docx", "Report.docx")

        fun pick(op: String, code: Int = -1, uri: String? = DESTINATION, flags: Int = GRANT_FLAGS): OfficeHostSaveHandoffPolicy.PickResult =
            OfficeHostSaveHandoffPolicy.PickResult(op, TOKEN, GENERATION, code, uri, flags)
    }

    private companion object {
        const val TOKEN = "11111111-2222-3333-4444-555555555555"
        const val GENERATION = 7L
        const val DESTINATION = "content://fake.provider/document/save-copy-dest"
        const val GRANT_FLAGS =
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE
    }

    private fun seedDestination(fixture: Fixture): ByteArray {
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1, 2, 3)
        fixture.backend.seed(DESTINATION, "copy.docx", ByteArray(0))
        fixture.backend.session[DESTINATION] = mutableSetOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        return bytes
    }

    @Test
    fun receiptIsPersistedBeforeAnyPickerCanBePrepared() {
        val fixture = Fixture()
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 4)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        assertTrue(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertEquals(listOf("output"), fixture.journal.events)
        assertNotNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
    }

    @Test
    fun refusedJournalWriteMeansNoPickerAndNoClaim() {
        val fixture = Fixture()
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 4)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        fixture.journal.outputReadyResult = false
        assertFalse(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
        assertEquals(listOf("output"), fixture.journal.events)
    }

    @Test
    fun transferringAndTargetAreJournaledBeforeTheScheduledBodyRuns() {
        val fixture = Fixture()
        seedDestination(fixture)
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 5)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        assertTrue(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertNotNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(fixture.pick("export-1")))
        assertEquals(DESTINATION, fixture.journal.lastTarget)
        // At the first instant the scheduled transfer body may run, the exact
        // output and TRANSFERRING+target were already journaled.
        assertEquals(listOf("output", "transfer"), fixture.eventsAtSchedule)
        assertTrue(fixture.journal.lastFacts?.saved == true)
        assertEquals(bytes.toList(), fixture.backend.docs[DESTINATION]!!.content.toList())
    }

    @Test
    fun pickerCancellationNeverJournalsATarget() {
        val fixture = Fixture()
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 6)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        assertTrue(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertNotNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
        assertTrue(fixture.handoff.onPickResult(fixture.pick("export-1", code = 0, uri = null, flags = 0)))
        assertTrue(fixture.journal.events.none { it == "transfer" })
        assertEquals(1, fixture.settlements.size)
    }

    @Test
    fun refusedTransferJournalAbortsBeforeProviderWrite() {
        val fixture = Fixture()
        seedDestination(fixture)
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 7)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        assertTrue(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertNotNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
        fixture.journal.transferResult = false
        assertTrue(fixture.handoff.onPickResult(fixture.pick("export-1")))
        assertEquals(0, fixture.backend.docs[DESTINATION]!!.content.size)
        assertTrue(fixture.journal.events.contains("transfer"))
        assertTrue(fixture.journal.events.none { it.startsWith("settle-saved") })
    }

    @Test
    fun partialDestinationWriteIsSettledUncertainNotSaved() {
        val fixture = Fixture()
        seedDestination(fixture)
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 8, 9)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        assertTrue(fixture.handoff.onReceipt(fixture.receipt("export-1", path, digest, size)))
        assertNotNull(fixture.handoff.onPrepare(fixture.prepare("export-1")))
        fixture.backend.afterWriteCommit = { doc -> doc.content = byteArrayOf(1) }
        assertTrue(fixture.handoff.onPickResult(fixture.pick("export-1")))
        val facts = fixture.journal.lastFacts
        assertNotNull(facts)
        assertFalse(facts!!.saved)
        assertTrue(facts.uncertain)
        assertEquals("verify-mismatch", facts.code)
    }

    @Test
    fun flushReceiptUpdatesTheWorkingCopyFingerprintWithoutBecomingAnOutput() {
        val fixture = Fixture()
        val digest = "a".repeat(64)
        val receipt = fixture.receipt(
            "flush-1",
            path = "/unused",
            digest = digest,
            bytes = 8,
            state = OfficeSaveState.FLUSHED,
            operation = OfficeSaveOperation.WORKING_COPY_FLUSH,
            format = null,
            workingCopySha = digest,
            workingCopyBytes = 8,
        )
        assertFalse(fixture.handoff.onReceipt(receipt))
        assertEquals(listOf("flush"), fixture.journal.events)
    }

    @Test
    fun foreignSessionReceiptNeverTouchesTheJournal() {
        val fixture = Fixture()
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1)
        val (path, digest, size) = fixture.moduleOutput("export-1", bytes)
        val foreign = fixture.receipt("export-1", path, digest, size).copy(sessionToken = "foreign-session")
        assertFalse(fixture.handoff.onReceipt(foreign))
        assertTrue(fixture.journal.events.isEmpty())
    }
}
