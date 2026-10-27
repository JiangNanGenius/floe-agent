// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveRequest
import com.floe.android.host.OfficePreviewController
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import com.floe.android.host.WorkspaceSourceResult
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Serialized epoch pump regressions (Main host20, AUTHORED NOTRUN — Main
 * runs the composed batch). Scripted transport + fake document ports drive
 * the REAL production pump: one claim at a time, NonCancellable execution,
 * EXACTLY-ONE settlement per claimed ticket (status 0 bounded JSON or status
 * 1 typed envelope) even when the ticket stopped/expired, no retry or
 * double-settle on -101/-102/-110 classifications, real stop/drain before
 * the exact-epoch close, observer detach + transport release only after the
 * drain, and `stopAndJoin == false` while a claim still runs (the old
 * generation stays honestly owned/pending — never a forced clean stop).
 */
class OfficeAiHostPumpTest {

    // ---- scripted transport ----

    private lateinit var transport: FakeNativeTransport

    private inner class FakeNativeTransport : OfficeAiNativeTransport {
        val bindCalls = AtomicInteger()
        val closeCalls = CopyOnWriteArrayList<Long>()
        val completes = CopyOnWriteArrayList<Triple<Long, Int, ByteArray>>()
        val queue = java.util.concurrent.ConcurrentLinkedQueue<Long>()
        val nextCalls = AtomicInteger()
        val descriptors = ConcurrentHashMap<Long, ByteArray>()
        val payloads = ConcurrentHashMap<Long, ByteArray>()
        val deadClaims = ConcurrentHashMap.newKeySet<Long>()
        val stopClaims = ConcurrentHashMap.newKeySet<Long>()
        var completeResult = 0
        var bindRefuses = false

        fun enqueue(claim: Long, descriptor: ByteArray, payload: ByteArray = ByteArray(0)) {
            descriptors[claim] = descriptor
            if (payload.isNotEmpty()) payloads[claim] = payload
            queue.add(claim)
        }

        override fun bindEpoch(epoch: Long): Int {
            bindCalls.incrementAndGet()
            return if (bindRefuses) -1 else 0
        }

        override fun next(timeoutMillis: Int): Long {
            val claim = queue.poll()
            if (claim != null) return claim
            // Bounded idle like the real JNI clamp, without a hot spin.
            Thread.sleep(5)
            return 0L
        }

        override fun describe(claim: Long): ByteArray? = descriptors[claim]
        override fun payload(claim: Long): ByteArray? = payloads[claim] ?: ByteArray(0)
        override fun isLive(claim: Long): Int = if (claim in deadClaims) 0 else 1
        override fun shouldStop(claim: Long): Int = if (claim in stopClaims) 1 else 0

        override fun complete(claim: Long, status: Int, value: ByteArray): Int {
            completes.add(Triple(claim, status, value))
            return completeResult
        }

        override fun close(epoch: Long): Int {
            closeCalls.add(epoch)
            return 0
        }

        override fun stats(): ByteArray? = "{\"claims\":0}".toByteArray()
    }

    // ---- minimal fake ports (no document by default) ----

    private val epoch = 66L
    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()

    private inner class NoDocPorts : OfficeAiDocumentPorts {
        val snapshot = ConcurrentHashMap<String, OfficePreviewController.OwnedOperationSnapshot>()
        var observer: ((OfficeSaveReceipt) -> Unit)? = null
        val detached = AtomicInteger()
        val released = AtomicInteger()
        var generation = 9L
        val now = AtomicLong(0L)
        var blockPrecisionGate: CompletableDeferred<Unit>? = null

        override fun ownedSnapshot(
            taskID: String, workspaceID: String?, nativeEpoch: String,
        ): OfficePreviewController.OwnedOperationSnapshot? = snapshot[taskID]

        override fun viewerDisplayName(): String? = snapshot.values.firstOrNull()?.let { "doc.docx" }
        override fun isDocumentSlotBusy(): Boolean = false
        override fun openWorkspace(
            owner: WorkspaceOfficeSnapshotStager.Owner, logicalPath: String, ownerCurrent: () -> Boolean,
        ) {
        }

        override fun openAdmissionError(): String? = null
        override fun isApplicationForeground(): Boolean = true
        override fun isPlatformPickerPending(): Boolean = false
        override fun isConversationCurrentlyVisible(taskID: String): Boolean = true
        override fun isModalSurfaceOwned(): Boolean = false
        override fun isOwnedOperationViewing(taskID: String, workspaceID: String, nativeEpoch: String): Boolean = true
        override fun cancelUnclaimedLaunch(taskID: String, workspaceID: String, nativeEpoch: String) {}
        override fun engineGeneration(sessionToken: String): Long = generation
        override fun engineEditState(sessionToken: String, generation: Long) =
            OfficeAiEngineEditFacts("READY_EDITABLE", true)

        override fun saveSubmit(request: OfficeSaveRequest): OfficeAiSaveSubmit = OfficeAiSaveSubmit.Code(1)
        override fun attachSaveReceiptObserver(observer: (OfficeSaveReceipt) -> Unit) {
            this.observer = observer
        }

        override fun detachSaveReceiptObserver() { detached.incrementAndGet() }
        override fun releaseTransports() { released.incrementAndGet() }

        override suspend fun precision(
            request: com.floe.android.core.officeengine.precision.OfficePrecisionRequest,
            deadlineMs: Long,
        ): com.floe.android.core.officeengine.precision.OfficePrecisionResult {
            blockPrecisionGate?.let { withTimeout(30_000) { it.await() } }
            return com.floe.android.core.officeengine.precision.OfficePrecisionResult(
                opId = request.opId, sessionToken = request.sessionToken,
                generation = request.generation, action = request.action,
                state = com.floe.android.core.officeengine.precision.OfficePrecisionState.QUERY_OBSERVED,
                failure = null, detail = null, answer = null, attestation = "test",
                submittedAtElapsedMs = 0L, completedAtElapsedMs = 1L,
            )
        }

        override suspend fun pushOriginalViaHeadlessLane(
            taskID: String, workspaceID: String, nativeEpoch: Long, hostGeneration: Long,
            logicalPath: String, ownerFence: () -> Boolean,
        ): WorkspaceSourceResult? = null

        override fun currentNativeEpoch(): Long? = epoch
        override fun commandGeneration(): Long = 5L
        override fun isOwnedOrdinaryTask(taskID: String): Boolean = true
        override fun appDataRoot(): File? = tmpRoot
        override fun outputsRoot(): File = File(tmpRoot, "outputs")
        override fun baselineRoot(): File = File(tmpRoot, "baselines")
        override fun elapsedMs(): Long = now.getAndAdd(1L)
    }

    private val tmpRoot = File(System.getProperty("java.io.tmpdir"), "floe-office-ai-pump-" + UUID.randomUUID())
    private lateinit var ports: NoDocPorts
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val fakeVerifier = object : OfficeAiSavedPackageVerifier {
        override fun inspect(input: OfficeAiVerificationInput): OfficeAiVerificationResult =
            OfficeAiVerificationResult.Refused("packageUnreadable")
    }

    private fun newPump(): OfficeAiHostPump {
        tmpRoot.mkdirs()
        transport = FakeNativeTransport()
        ports = NoDocPorts()
        return OfficeAiHostPump(
            scope = scope, ioDispatcher = Dispatchers.IO,
            currentNativeEpoch = { ports.currentNativeEpoch() },
            ports = ports, transport = transport, verifier = fakeVerifier,
            timing = OfficeAiTiming(openPollMillis = 5, openWaitMillis = 30,
                commandDeadlineMillis = 5_000, flushWaitMillis = 30, exportWaitMillis = 30),
        )
    }

    private fun lookupDescriptor(): ByteArray {
        val base = mutableListOf(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "$epoch",
        )
        return base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
    }

    // ------------------------------------------------------------------

    @Test
    fun bindRefusalLeavesLaneAbsentWithoutObserver() {
        val pump = newPump()
        transport.bindRefuses = true
        runBlocking {
            assertFalse(pump.start(epoch))
        }
        assertEquals(1, transport.bindCalls.get())
        assertNull(ports.observer)
        assertEquals(0, transport.closeCalls.size)
    }

    @Test
    fun claimsSettleExactlyOnceAndDrainClosesEpoch() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            assertNotNull(ports.observer)
            transport.enqueue(11L, lookupDescriptor())
            transport.enqueue(12L, lookupDescriptor())
            withTimeout(5_000) {
                while (transport.completes.size < 2) delay(10)
            }
            assertEquals(2, transport.completes.size)
            assertEquals(setOf(11L, 12L), transport.completes.map { it.first }.toSet())
            // noOwnedDocument: typed status-1 envelopes, bounded and parseable.
            transport.completes.forEach { (claim, status, body) ->
                assertEquals("claim $claim", 1, status)
                assertTrue(String(body).contains("\"code\":\"noOwnedDocument\""))
                assertTrue(body.size <= OfficeAiWire.MAX_FAILURE_REPLY_BYTES)
            }
            assertTrue(pump.stopAndJoin(epoch, 5_000))
            assertEquals(listOf(epoch), transport.closeCalls)
            assertEquals(1, ports.detached.get())
            assertEquals(1, ports.released.get())
            assertEquals(0L, pump.boundNativeEpoch)
        }
    }

    @Test
    fun stoppedClaimStillSettlesOnceWithTypedRefusalWithoutDispatch() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            // Put a live document so an unstopped claim WOULD dispatch.
            ports.snapshot[task] = pumpOwnedSnapshot()
            // Mark the stop BEFORE enqueue so the reader cannot admit the
            // claim in the race window (deterministic stop-before-dispatch).
            transport.stopClaims.add(21L)
            transport.enqueue(21L, lookupDescriptor())
            withTimeout(5_000) {
                while (transport.completes.isEmpty()) delay(10)
            }
            assertEquals(1, transport.completes.size)
            val (claim, status, body) = transport.completes.first()
            assertEquals(21L, claim)
            assertEquals(1, status)
            assertTrue(String(body).contains("\"code\":\"sessionEnding\""))
            // A stopped-before-admission claim never reaches the engine ports:
            // the lookup WOULD have answered successfully; it answered the
            // stop instead, and only one settlement exists.
            assertTrue(pump.stopAndJoin(epoch, 5_000))
        }
    }

    @Test
    fun staleCompleteClassificationNeverRetries() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            transport.completeResult = -101
            transport.enqueue(31L, lookupDescriptor())
            withTimeout(5_000) {
                while (transport.completes.isEmpty()) delay(10)
            }
            delay(50)
            assertEquals(1, transport.completes.size) // never re-settled
            transport.completeResult = 0
            assertTrue(pump.stopAndJoin(epoch, 5_000))
        }
    }

    @Test
    fun claimExecutingUnderStopIsNotCutOffAndJoinReportsUnprovenThenDrained() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            // A command claim whose precision call blocks (dispatched real
            // work under NonCancellable): the stop must NOT force-cancel it.
            ports.snapshot[task] = pumpOwnedSnapshot()
            // bind the session through a real lookup first.
            transport.enqueue(40L, lookupDescriptor())
            withTimeout(5_000) {
                while (transport.completes.size < 1) delay(10)
            }
            val gate = CompletableDeferred<Unit>()
            ports.blockPrecisionGate = gate
            val command = (mutableListOf(
                "operation" to "office.command", "epoch" to "$epoch",
                "sessionToken" to "pump-sess-1", "generation" to "9",
                "opId" to "rd-blocked", "action" to "queryDocumentContext",
            )).joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray()
            transport.enqueue(41L, command)
            // stopAndJoin while the claim is inside the engine call: the
            // old generation is NOT declared stopped.
            delay(40)
            assertFalse(pump.stopAndJoin(epoch, 300))
            gate.complete(Unit)
            withTimeout(5_000) {
                while (transport.completes.none { it.first == 41L }) delay(10)
            }
            // The blocked claim settled EXACTLY once.
            assertEquals(1, transport.completes.count { it.first == 41L })
            assertTrue(pump.stopAndJoin(epoch, 5_000))
            assertEquals(listOf(epoch), transport.closeCalls)
        }
    }

    @Test
    fun descriptorOutsideGrammarSettlesTypedRefusalWithoutDispatch() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            val foreign = (mutableListOf(
                "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
                "workspacePresent" to "absent", "nativeEpoch" to "$epoch", "extra" to "x",
            )).joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray()
            transport.enqueue(51L, foreign)
            withTimeout(5_000) {
                while (transport.completes.isEmpty()) delay(10)
            }
            val (claim, status, body) = transport.completes.first()
            assertEquals(51L, claim)
            assertEquals(1, status)
            assertTrue(String(body).contains("\"code\":\"internal\""))
            assertTrue(pump.stopAndJoin(epoch, 5_000))
        }
    }

    private fun pumpOwnedSnapshot(): OfficePreviewController.OwnedOperationSnapshot {
        val working = File(tmpRoot, "pump-working.docx")
        working.writeBytes(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
        return OfficePreviewController.OwnedOperationSnapshot(
            sessionToken = "pump-sess-1", viewerIncarnation = 3L, hostGeneration = "5",
            nativeEpoch = "$epoch", ownerTaskId = task, workspaceId = null,
            sourceLogicalPath = "a.docx", sourceId = null, sourceRevision = null,
            originalSnapshotSha256 = "c".repeat(64), originalSnapshotBytes = 4L,
            editable = true, stagedWorkingCopyPath = working.canonicalPath,
            stagedWorkingCopySha256 = shaOf(working), stagedWorkingCopyBytes = working.length(),
        )
    }

    private fun shaOf(file: File): String =
        java.security.MessageDigest.getInstance("SHA-256")
            .digest(file.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) }

    @Test
    fun rebindSameEpochIsIdempotent() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            assertTrue(pump.start(epoch))
            assertEquals(1, transport.bindCalls.get())
            assertTrue(pump.stopAndJoin(epoch, 5_000))
            assertEquals(listOf(epoch), transport.closeCalls)
        }
    }

    @Test
    fun stopAndJoinWrongEpochNeverClaimsWithoutOwningGeneration() {
        val pump = newPump()
        runBlocking {
            assertTrue(pump.start(epoch))
            assertFalse(pump.stopAndJoin(epoch + 1, 500))
            // The real epoch is still owned:
            assertEquals(epoch, pump.boundNativeEpoch)
            assertTrue(pump.stopAndJoin(epoch, 5_000))
        }
    }

    @Test
    fun foreignReceiptThroughHandoffObserverCompletesNothing() {
        // Pump-level: the session waiter table receives ALL shape-valid
        // receipts through the observer wiring; a foreign-keyed receipt must
        // not complete a live waiter. (Real handoff ordering is pinned by
        // OfficeAiSaveReceiptObserverTest.)
        val waiters = SaveWaiters()
        val deferred = waiters.register(SaveWaiters.Key("mine", 9L, "op-1"))!!
        assertNotNull(deferred)
        assertFalse(waiters.observe(saveReceipt("op-1", token = "other")))
        assertFalse(waiters.observe(saveReceipt("op-1", generation = 10L)))
        // A different opId on the right session has NO registered waiter
        // (that op was never dispatched by this lane): completes nothing.
        assertFalse(waiters.observe(saveReceipt("op-2", token = "mine")))
        assertFalse(deferred.isCompleted)
        assertTrue(waiters.observe(saveReceipt("op-1", token = "mine")))
        assertTrue(deferred.isCompleted)
        // A duplicate terminal never re-completes.
        assertFalse(waiters.observe(saveReceipt("op-1", token = "mine")))
    }

    private fun saveReceipt(
        opId: String, token: String = "mine", generation: Long = 9L,
    ): OfficeSaveReceipt = com.floe.android.core.officeengine.OfficeSaveReceipt(
        opId = opId, sessionToken = token, generation = generation,
        operation = com.floe.android.core.officeengine.OfficeSaveOperation.WORKING_COPY_FLUSH,
        state = com.floe.android.core.officeengine.OfficeSaveState.FLUSHED,
        format = null, suggestedName = null, expectedBaseSha256 = null,
        workingCopySha256 = "d".repeat(64), workingCopyBytes = 5L,
        outputDocumentPath = null, outputSha256 = null, outputBytes = 0L,
        failure = null, message = null, cancelRequested = false, attestation = "t",
        submittedAtElapsedMs = 0L, completedAtElapsedMs = 1L,
    )
}
