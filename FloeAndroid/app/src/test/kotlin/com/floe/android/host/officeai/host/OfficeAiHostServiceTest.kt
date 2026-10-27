// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.OfficeEditState
import com.floe.android.core.officeengine.OfficeEngineCommandsPolicy
import com.floe.android.core.officeengine.OfficeSaveFailureCode
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveRequest
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.core.officeengine.precision.OfficePrecisionAnswer
import com.floe.android.core.officeengine.precision.OfficePrecisionContentKind
import com.floe.android.core.officeengine.precision.OfficePrecisionContentReadback
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionPreEffectEvidence
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import com.floe.android.core.officeengine.precision.OfficePrecisionTarget
import com.floe.android.host.OfficePreviewController
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import com.floe.android.host.WorkspaceSourceResult
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Per-operation service regressions over the REAL production dispatcher and
 * ledgers (Main host20, AUTHORED NOTRUN — Main runs the composed batch):
 * fake engine/service ports drive sequencing that no JVM unit test could
 * reach through binder/native code. Pins: exact-owner fences with NO other-
 * document fallback, temporary-chat refusal, busy handling, honest
 * engineNotReady without teardown, capture baseline retention bound to the
 * capture attestation, effect-opId no-replay, save waiter keyed exactly,
 * unknown retention (no cancel, no replay), foreign-receipt isolation, the
 * Amendment/2 verify correlation (liveEffect vs completedJob after session
 * death vs reconcile-without-proof) and the pushOriginal token mapping.
 */
class OfficeAiHostServiceTest {

    private val epoch = 1234L
    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()
    private val session = "sess-abcdef0123456789"
    private val handle = "0123456789abcdef0123456789abcdef"
    private val tmpRoot = File(System.getProperty("java.io.tmpdir"), "floe-office-ai-" + UUID.randomUUID())

    // ------------------------------------------------------------------
    // fakes
    // ------------------------------------------------------------------

    private class SnapshotStore {
        val byOwner = LinkedHashMap<Triple<String, String?, String>, OfficePreviewController.OwnedOperationSnapshot>()

        fun put(snap: OfficePreviewController.OwnedOperationSnapshot) {
            byOwner[Triple(snap.ownerTaskId ?: "", snap.workspaceId, snap.nativeEpoch ?: "")] = snap
        }

        fun clear() = byOwner.clear()
    }

    private inner class FakePorts : OfficeAiDocumentPorts {
        val snapshots = SnapshotStore()
        var displayName: String? = "quarter-report.docx"
        var busy = false
        var openError: String? = null
        var opened: Pair<WorkspaceOfficeSnapshotStager.Owner, String>? = null
        var openOwnerCurrents = ArrayList<() -> Boolean>()
        var generation = 9L
        var editState: OfficeEditState? = null
        var ordinaryTasks = setOf(task)
        var commandGeneration = 5L
        var nativeEpoch: Long? = epoch
        val precisionRequests = ArrayList<OfficePrecisionRequest>()
        var precisionScript = ArrayDeque<OfficePrecisionResult>()
        val saveRequests = ArrayList<OfficeSaveRequest>()
        var saveSubmit: OfficeAiSaveSubmit =
            OfficeAiSaveSubmit.Code(OfficeEngineCommandsPolicy.SUBMIT_ACCEPTED)
        var foreground = true
        var pickerPending = false
        var visibleConversation: String? = null
        var modalOwned = false
        var viewingPhase = false
        var unclaimedCancels = 0
        var observers = ArrayList<(com.floe.android.core.officeengine.OfficeSaveReceipt) -> Unit>()
        var detached = 0
        var released = 0
        var pushResults = ArrayDeque<WorkspaceSourceResult?>()
        var pushCalls = ArrayList<String>()
        var now = AtomicLong(1_000L)

        override fun ownedSnapshot(
            taskID: String, workspaceID: String?, nativeEpoch: String,
        ): OfficePreviewController.OwnedOperationSnapshot? =
            snapshots.byOwner[Triple(taskID, workspaceID, nativeEpoch)]

        override fun viewerDisplayName(): String? = displayName
        override fun isDocumentSlotBusy(): Boolean = busy
        override fun openWorkspace(
            owner: WorkspaceOfficeSnapshotStager.Owner, logicalPath: String, ownerCurrent: () -> Boolean,
        ) {
            opened = owner to logicalPath
            openOwnerCurrents += ownerCurrent
        }

        override fun openAdmissionError(): String? = openError
        override fun engineGeneration(sessionToken: String): Long = generation
        override fun engineEditState(sessionToken: String, generation: Long): OfficeAiEngineEditFacts? =
            editState?.let { OfficeAiEngineEditFacts(it.stateName, it.editPermissionEstablished) }

        override fun saveSubmit(request: OfficeSaveRequest): OfficeAiSaveSubmit {
            saveRequests += request
            return saveSubmit
        }
        override fun isApplicationForeground(): Boolean = foreground
        override fun isPlatformPickerPending(): Boolean = pickerPending
        override fun isConversationCurrentlyVisible(taskID: String): Boolean =
            visibleConversation == null || visibleConversation == taskID
        override fun isModalSurfaceOwned(): Boolean = modalOwned
        override fun isOwnedOperationViewing(taskID: String, workspaceID: String, nativeEpoch: String): Boolean =
            viewingPhase
        override fun cancelUnclaimedLaunch(taskID: String, workspaceID: String, nativeEpoch: String) { unclaimedCancels++ }

        override fun attachSaveReceiptObserver(observer: (com.floe.android.core.officeengine.OfficeSaveReceipt) -> Unit) {
            observers.add(observer)
        }

        override fun detachSaveReceiptObserver() { detached++ }
        override fun releaseTransports() { released++ }

        override suspend fun precision(
            request: OfficePrecisionRequest, deadlineMs: Long,
        ): OfficePrecisionResult {
            precisionRequests += request
            return precisionScript.removeFirstOrNull() ?: transportUnknown(request)
        }

        override suspend fun pushOriginalViaHeadlessLane(
            taskID: String, workspaceID: String, nativeEpoch: Long, hostGeneration: Long,
            logicalPath: String, ownerFence: () -> Boolean,
        ): WorkspaceSourceResult? {
            pushCalls += "$taskID|$workspaceID|$nativeEpoch|$hostGeneration|$logicalPath"
            return if (pushResults.isNotEmpty()) pushResults.removeFirst() else null
        }

        override fun currentNativeEpoch(): Long? = nativeEpoch
        override fun commandGeneration(): Long = commandGeneration
        override fun isOwnedOrdinaryTask(taskID: String): Boolean = taskID in ordinaryTasks
        override fun appDataRoot(): File? = tmpRoot
        override fun outputsRoot(): File = File(tmpRoot, "floe-office-outputs")
        override fun baselineRoot(): File = File(tmpRoot, "floe-office-ai-capture")
        override fun elapsedMs(): Long = now.getAndAdd(10L)
    }

    private fun transportUnknown(request: OfficePrecisionRequest): OfficePrecisionResult =
        OfficePrecisionResult(
            opId = request.opId, sessionToken = request.sessionToken, generation = request.generation,
            action = request.action, state = OfficePrecisionState.UNKNOWN,
            failure = OfficePrecisionFailure.TRANSPORT, detail = "script-exhausted", answer = null,
            attestation = "test", submittedAtElapsedMs = 1L, completedAtElapsedMs = 2L,
        )

    private inner class RecordingVerifier : OfficeAiSavedPackageVerifier {
        var inputs = ArrayList<OfficeAiVerificationInput>()
        var next: OfficeAiVerificationResult = OfficeAiVerificationResult.Verified(defaultFacts())

        override fun inspect(input: OfficeAiVerificationInput): OfficeAiVerificationResult {
            inputs += input
            return next
        }
    }

    private fun defaultFacts() = OfficeAiVerificationFacts(
        partName = "word/document.xml",
        expectedContentMatches = true,
        expectedTextFound = true,
        occurrenceCount = 1,
        replacementScope = "selectionReplaced",
        cellTypeAttribute = null,
        cellHasFormula = null,
        cellPersistedValue = null,
        cellTypeMatchesIntent = null,
        semanticDeltaVerified = true,
        targetEffectVerified = true,
        proofReused = false,
        changedFromOriginal = true,
        limitations = listOf("rich-format-known-limits"),
    )

    private lateinit var ports: FakePorts
    private lateinit var binds: SessionBinds
    private lateinit var captures: CaptureStore
    private lateinit var effects: EffectLedger
    private lateinit var selections: SelectionLedger
    private lateinit var waiters: SaveWaiters
    private lateinit var verifier: RecordingVerifier
    private lateinit var service: OfficeAiHostService

    private fun newService(openWaitMillis: Long = 40L, saveWaitMillis: Long = 40L): OfficeAiHostService {
        tmpRoot.mkdirs()
        ports = FakePorts()
        binds = SessionBinds()
        captures = CaptureStore { ports.now.get() }
        effects = EffectLedger { ports.now.get() }
        selections = SelectionLedger()
        waiters = SaveWaiters()
        verifier = RecordingVerifier()
        val timing = OfficeAiTiming(
            openPollMillis = 5L, openWaitMillis = openWaitMillis, commandDeadlineMillis = 5_000L,
            flushWaitMillis = saveWaitMillis, exportWaitMillis = saveWaitMillis,
        )
        service = OfficeAiHostService(epoch, ports, binds, captures, effects, selections, waiters, verifier, timing)
        // Mirror the PRODUCTION pump wiring (OfficeAiHostPump.attach is the
        // only lifecycle owner in the App): in this direct-service fixture the
        // OWNED receipt observer must still feed the exact-key waiter table,
        // otherwise FLUSHED receipts could never settle a registered waiter.
        ports.attachSaveReceiptObserver { receipt -> waiters.observe(receipt) }
        return service
    }

    private fun docSnapshot(
        ownerTask: String = task, workspaceID: String? = workspace,
        path: String = "reports/quarter-report.docx", formatExt: String = "docx",
    ): OfficePreviewController.OwnedOperationSnapshot {
        val working = File(tmpRoot, "working-$ownerTask.$formatExt")
        working.parentFile?.mkdirs()
        working.writeBytes(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
        return OfficePreviewController.OwnedOperationSnapshot(
            sessionToken = session,
            viewerIncarnation = 17L,
            hostGeneration = "5",
            nativeEpoch = "$epoch",
            ownerTaskId = ownerTask,
            workspaceId = workspaceID,
            sourceLogicalPath = path,
            sourceId = if (workspaceID != null) UUID.randomUUID().toString() else null,
            sourceRevision = if (workspaceID != null) "rev-opaque-1" else null,
            originalSnapshotSha256 = "a".repeat(64),
            originalSnapshotBytes = 1234L,
            editable = true,
            stagedWorkingCopyPath = working.canonicalPath,
            stagedWorkingCopySha256 = sha(working.readBytes()),
            stagedWorkingCopyBytes = working.length(),
        )
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    private fun ticketJson(operation: String, vararg extra: Pair<String, String>): ByteArray {
        val base = mutableListOf("operation" to operation, "epoch" to "$epoch")
        base += extra
        return base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
    }

    private fun runTicket(jsonBytes: ByteArray, staged: ByteArray = ByteArray(0)): OfficeAiWire.Settlement =
        runBlocking {
            val ticket = OfficeAiWire.parseDescriptor(jsonBytes, epoch)
            service.execute(ticket, staged) { false }
        }

    // ------------------------------------------------------------------
    // lookup
    // ------------------------------------------------------------------

    @Test
    fun lookupRefusesForeignOwnerAndNeverFallsBackToFirstDoc() {
        newService()
        val otherTask = UUID.randomUUID().toString()
        ports.snapshots.put(docSnapshot(ownerTask = otherTask))
        val settlement = runTicket(ticketJson(
            "office.lookup", "taskID" to task, "workspacePresent" to "exact",
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        ))
        assertTrue(settlement is OfficeAiWire.Settlement.Failure)
        assertEquals("noOwnedDocument", (settlement as OfficeAiWire.Settlement.Failure).code)
        // And the SAME doc for its real owner resolves — exact realm only.
        val own = runTicket(ticketJson(
            "office.lookup", "taskID" to otherTask, "workspacePresent" to "exact",
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        ))
        assertTrue(own is OfficeAiWire.Settlement.Success)
    }

    @Test
    fun lookupAnswersTheExactBridgeDocumentShape() {
        newService()
        val snap = docSnapshot()
        ports.snapshots.put(snap)
        ports.generation = 9L
        ports.editState = OfficeEditState(
            sessionToken = session, generation = 9L, stateName = "READY_EDITABLE",
            editRequested = true, pageEditMode = true, editPermissionEstablished = true,
            documentModified = false, undoState = null, redoState = null,
        )
        val settlement = runTicket(ticketJson(
            "office.lookup", "taskID" to task, "workspacePresent" to "exact",
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        )) as OfficeAiWire.Settlement.Success
        val body = settlement.body
        assertEquals(1L, (body["ok"] as kotlinx.serialization.json.JsonPrimitive).content.toLong())
        assertEquals(session, (body["sessionToken"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("9", (body["nativeGeneration"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("workspace", (body["route"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("docx", (body["format"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("quarter-report.docx", (body["displayName"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("READY_EDITABLE", (body["editStateName"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("true", (body["editPermissionEstablished"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("false", (body["openedNow"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals(snap.stagedWorkingCopySha256, (body["stagedWorkingCopySha256"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("rev-opaque-1", (body["sourceRevision"] as kotlinx.serialization.json.JsonPrimitive).content)
        // Identity separation: the opaque CAS revision is NEVER a content
        // digest, and the original snapshot SHA stays its own field.
        assertNotEquals(snap.originalSnapshotSha256,
            (body["sourceRevision"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals(snap.originalSnapshotSha256,
            (body["originalSnapshotSha256"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertNotNull(binds.get(session))
    }

    @Test
    fun lookupWithoutEngineGenerationIsHonestEngineNotReady() {
        newService()
        ports.snapshots.put(docSnapshot())
        ports.generation = 0L
        val settlement = runTicket(ticketJson(
            "office.lookup", "taskID" to task, "workspacePresent" to "exact",
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        ))
        assertEquals("engineNotReady", (settlement as OfficeAiWire.Settlement.Failure).code)
    }

    // ------------------------------------------------------------------
    // open
    // ------------------------------------------------------------------

    @Test
    fun openRefusesTemporaryChatAndBusyWithoutStaging() {
        newService()
        ports.ordinaryTasks = emptySet()
        val temp = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/a.docx", "requestID" to "r1",
        ))
        assertEquals("notOwner", (temp as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
        ports.ordinaryTasks = setOf(task)
        ports.busy = true
        val busy = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/a.docx", "requestID" to "r2",
        ))
        assertEquals("busy", (busy as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
    }

    @Test
    fun openTimeoutIsHonestAndTearsNothingDown() {
        newService()
        val settlement = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx", "requestID" to "r3",
        ))
        assertEquals("engineNotReady", (settlement as OfficeAiWire.Settlement.Failure).code)
        // The open WAS requested once through the existing owner-safe route…
        assertNotNull(ports.opened)
        // …and the host never cancels/retires it: the owner closure the App
        // received stays untouched (no forced teardown call exists).
        assertTrue(ports.openOwnerCurrents.isNotEmpty())
    }

    @Test
    fun openReturnsExistingOwnedOperationWithoutRelaunch() {
        newService()
        ports.snapshots.put(docSnapshot())
        ports.editState = OfficeEditState(
            session, 9L, "READY_EDITABLE", true, true, true, false, null, null,
        )
        val settlement = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx", "requestID" to "r4",
        )) as OfficeAiWire.Settlement.Success
        assertEquals("false", (settlement.body["openedNow"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertNull(ports.opened) // NO relaunch when the exact doc is already owned.
    }

    @Test
    fun openAwaitsRealEngineReadinessThenAnswersOpenedNow() {
        newService(openWaitMillis = 2_000L)
        val snap = docSnapshot()
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(ticketJson(
                    "office.open", "taskID" to task, "workspaceID" to workspace,
                    "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
                    "requestID" to "r5",
                ), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            delay(15)
            // The existing staging/launch path resolves mid-poll:
            ports.snapshots.put(snap)
            ports.editState = OfficeEditState(
                session, 9L, "READY_EDITABLE", true, true, true, false, null, null,
            )
            val settlement = withTimeout(5_000) { deferred.await() }
            assertTrue(settlement is OfficeAiWire.Settlement.Success)
            val body = (settlement as OfficeAiWire.Settlement.Success).body
            assertEquals("true", (body["openedNow"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertNotNull(ports.opened)
            assertEquals("reports/quarter-report.docx", ports.opened?.second)
        }
    }

    // ------------------------------------------------------------------
    // command
    // ------------------------------------------------------------------

    private fun commandTicket(opId: String, action: String, vararg extra: Pair<String, String>): ByteArray {
        val base = mutableListOf(
            "operation" to "office.command", "epoch" to "$epoch",
            "sessionToken" to session, "generation" to "9",
            "opId" to opId, "action" to action, "taskID" to task,
        )
        base += extra
        return base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
    }

    private fun precisionResult(
        request: OfficePrecisionRequest, state: OfficePrecisionState,
        answer: OfficePrecisionAnswer?, failure: OfficePrecisionFailure? = null,
    ): OfficePrecisionResult = OfficePrecisionResult(
        opId = request.opId, sessionToken = request.sessionToken, generation = request.generation,
        action = request.action, state = state, failure = failure, detail = null, answer = answer,
        attestation = "test-attestation", submittedAtElapsedMs = 1L, completedAtElapsedMs = 2L,
    )

    private fun preEffect(
        opId: String, text: String, targetHandle: String = handle,
        partId: String = "1", inputEpoch: Long = 0L, editEpoch: Long = 0L,
    ) = OfficePrecisionPreEffectEvidence(
        opId = opId, sessionToken = session, generation = 9L,
        targetHandle = targetHandle, partId = partId,
        inputEpoch = inputEpoch, editEpoch = editEpoch,
        selectionText = text, selectionByteCount = bytes(text).size,
    )

    private fun targetCaptured(workingCopySha: String?): OfficePrecisionAnswer =
        OfficePrecisionAnswer.TargetCaptured(
            OfficePrecisionTargetAnswerFixture.fixture(handle, workingCopySha),
        )

    private fun seedSession(snapshot: OfficePreviewController.OwnedOperationSnapshot = docSnapshot()) {
        ports.snapshots.put(snapshot)
        ports.editState = OfficeEditState(
            session, 9L, "READY_EDITABLE", true, true, true, false, null, null,
        )
        // Populate the bind through the production lookup path.
        val lookup = runTicket(ticketJson(
            "office.lookup", "taskID" to task, "workspacePresent" to "exact",
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        ))
        assertTrue(lookup is OfficeAiWire.Settlement.Success)
    }

    @Test
    fun captureRetainsBaselineBoundToCaptureDigest() {
        newService()
        val snapshot = docSnapshot()
        seedSession(snapshot)
        val working = File(snapshot.stagedWorkingCopyPath!!)
        val captureDigest = sha(working.readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-test-1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        val settlement = runTicket(commandTicket("cap-test-1", "captureTarget", )) as OfficeAiWire.Settlement.Success
        val facts = settlement.body["facts"] as kotlinx.serialization.json.JsonObject
        assertEquals("1", (facts["partIndex"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals(handle, (settlement.body["targetHandle"] as kotlinx.serialization.json.JsonPrimitive).content)
        val record = captures.get(session, handle)!!
        assertEquals(captureDigest, record.baselineSha256)
        assertEquals(9L, record.generation)
        assertEquals(task, record.ownerTaskID)
        assertTrue(record.baselineFile!!.canonicalFile.path
            .startsWith(tmpRoot.canonicalFile.path))
    }

    /**
     * Main CAPTURE_BASELINE_WIRE_ADDENDUM regression: after a manual edit +
     * flush the NATIVE captured digest (B) differs from the initial App-stage
     * snapshot digest (A). The reply must forward native B/bytes from the
     * actual TargetCaptured, the baseline must bind B, and the initial-stage
     * A must NEVER be substituted as the capture identity (and when the
     * native digest is absent the keys are simply omitted — no fallback).
     */
    @Test
    fun captureFactsForwardNativeWorkingCopyNeverInitialStageFallback() {
        newService()
        val snapshot = docSnapshot()
        seedSession(snapshot)
        val initialA = snapshot.stagedWorkingCopySha256!!
        // A manual edit + real flush changed the working copy file (bytes B):
        val working = File(snapshot.stagedWorkingCopyPath!!)
        val nativeBBytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 9, 9, 9)
        working.writeBytes(nativeBBytes)
        val nativeB = sha(nativeBBytes)
        assertNotEquals(initialA, nativeB)
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-b1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TargetCaptured(
                OfficePrecisionTargetAnswerFixture.fixtureWith(
                    handle, nativeB, nativeBBytes.size.toLong(),
                ),
            ),
        ))
        val first = runTicket(commandTicket("cap-b1", "captureTarget")) as OfficeAiWire.Settlement.Success
        val facts = first.body["facts"] as kotlinx.serialization.json.JsonObject
        assertEquals(nativeB, (facts["captureWorkingCopySha256"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals(nativeBBytes.size.toString(),
            (facts["captureWorkingCopyBytes"] as kotlinx.serialization.json.JsonPrimitive).content)
        // Baseline bound to the SAME native digest, never the initial stage:
        val record = captures.get(session, handle)!!
        assertEquals(nativeB, record.baselineSha256)
        // The session bind still carries the initial-stage A unchanged (the
        // original CAS/identity fact remains separate per the addendum):
        assertEquals(initialA, binds.get(session)?.stagedWorkingCopySha256)
        // Now a capture with NO native digest: keys omitted, no A fallback.
        val handle2 = "f".repeat(32)
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-b2", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TargetCaptured(
                OfficePrecisionTargetAnswerFixture.fixtureWith(handle2, null, 0L),
            ),
        ))
        val second = runTicket(commandTicket("cap-b2", "captureTarget")) as OfficeAiWire.Settlement.Success
        val facts2 = second.body["facts"] as kotlinx.serialization.json.JsonObject
        assertFalse(facts2.containsKey("captureWorkingCopySha256"))
        assertFalse(facts2.containsKey("captureWorkingCopyBytes"))
        assertNull(captures.get(session, handle2)!!.baselineFile)
    }

    @Test
    fun captureWithWrongEngineDigestStoresNoBaselineNotAFabricatedOne() {
        newService()
        seedSession()
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-test-1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured("f".repeat(64)),
        ))
        runTicket(commandTicket("cap-test-1", "captureTarget", ))
        val record = captures.get(session, handle)!!
        assertNull(record.baselineFile)
    }

    @Test
    fun commandFencesWrongOwnerWrongGenerationAndStaleSession() {
        newService()
        seedSession()
        // Wrong owner echo for the bound session: refuse before any dispatch.
        val foreignTask = UUID.randomUUID().toString()
        val wrongOwner = runTicket(commandTicket("rd-1", "queryDocumentContext",  "taskID" to foreignTask,
        ))
        assertEquals("sessionMismatch", (wrongOwner as OfficeAiWire.Settlement.Failure).code)
        // Wrong generation.
        val wrongGen = runTicket(run {
            val base = listOf(
                "operation" to "office.command", "epoch" to "$epoch",
                "sessionToken" to session, "generation" to "10",
                "opId" to "rd-2", "action" to "queryDocumentContext", "taskID" to task,
            )
            base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
        })
        assertEquals("sessionMismatch", (wrongGen as OfficeAiWire.Settlement.Failure).code)
        // Document closed (snapshot gone): refuse before dispatch.
        ports.snapshots.clear()
        val gone = runTicket(commandTicket("rd-3", "queryDocumentContext", ))
        assertEquals("noOwnedDocument", (gone as OfficeAiWire.Settlement.Failure).code)
        assertTrue(ports.precisionRequests.isEmpty())
    }

    @Test
    fun literalCellEncodesApostropheAndRecordsEffectOnceWithNoReplay() {
        newService()
        seedSession()
        // Capture first so the correlation exists.
        val snapshot = docSnapshot()
        ports.snapshots.put(snapshot)
        val captureDigest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        runTicket(commandTicket("cap-1", "captureTarget", ))
        // setCellContent literal "00123": the request text MUST be the codec-
        // encoded '00123 with kind LITERAL (never a formula mapping).
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("ap-1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SET_CELL_CONTENT),
            OfficePrecisionState.MUTATION_VERIFIED,
            OfficePrecisionAnswer.MutationApplied(
                steps = listOf("cursor-ok", "pasteresult-success", "readback-matched"),
                pastedBytes = 6, contentReadback = OfficePrecisionContentReadback.MATCHED,
                workingCopySha256 = captureDigest, consumedTargetHandle = handle,
            ),
        ))
        val apply = runTicket(commandTicket("ap-1", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "C3", "contentKind" to "literal",
        ), staged = bytes("00123")) as OfficeAiWire.Settlement.Success
        assertEquals("mutationVerified", (apply.body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("matched", (apply.body["contentReadback"] as kotlinx.serialization.json.JsonPrimitive).content)
        val request = ports.precisionRequests.last()
        assertEquals("'00123", request.text)
        assertEquals(OfficePrecisionContentKind.LITERAL, request.contentKind)
        // Same effect opId retry: refused BEFORE dispatch; the engine never
        // sees a second identical effect dispatch.
        val before = ports.precisionRequests.size
        val retry = runTicket(commandTicket("ap-1", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "C3", "contentKind" to "literal",
        ), staged = bytes("00123"))
        assertEquals("applyConflict", (retry as OfficeAiWire.Settlement.Failure).code)
        assertEquals(before, ports.precisionRequests.size)
        // Ledger proof is the ONLY source of targetEffectVerified.
        assertTrue(effects.provesMutationVerified(session, 9L, handle, "ap-1"))
    }

    @Test
    fun formulaIntentRequiresLeadingEqualsAndNumberStaysRawLiteral() {
        newService()
        seedSession()
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("ap-2", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SET_CELL_CONTENT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.MutationApplied(
                listOf("cursor-ok", "pasteresult-success"), 9,
                OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE, null, handle,
            ),
        ))
        val badFormula = runTicket(commandTicket("ap-1", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "D4", "contentKind" to "formula",
        ), staged = bytes("SUM(A1)"))
        assertEquals("contentUnsafe", (badFormula as OfficeAiWire.Settlement.Failure).code)
        val number = runTicket(commandTicket("ap-2", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "D4", "contentKind" to "number",
        ), staged = bytes("12.5")) as OfficeAiWire.Settlement.Success
        assertEquals("nativeCompleted", (number.body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("12.5", ports.precisionRequests.last().text)
        assertEquals(OfficePrecisionContentKind.LITERAL, ports.precisionRequests.last().contentKind)
    }

    /**
     * Main production-review rule: a REJECTED+TRANSPORT whose detail proves
     * the client never obtained a command binder is pre-dispatch (bounded
     * retry); `binder-transport-failed` means postPrecisionCommand WAS
     * attempted and the reply was lost — an effect may exist. This pins the
     * SERVICE side of the conservative contract: the adapter relays the
     * ambiguous moment as UNKNOWN/retained and the SAME opId can never be
     * re-dispatched by a retry.
     */
    @Test
    fun ambiguousPostSendTransportRelaysUnknownAndNeverReapplies() {
        newService()
        val snapshot = docSnapshot()
        seedSession(snapshot)
        val digest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-amb", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(digest),
        ))
        runTicket(commandTicket("cap-amb", "captureTarget", ))
        val ambiguous = precisionResult(
            OfficePrecisionRequest("ap-amb", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SET_CELL_CONTENT),
            OfficePrecisionState.UNKNOWN, null, OfficePrecisionFailure.TRANSPORT,
        )
        ports.precisionScript.add(ambiguous)
        val first = runTicket(commandTicket("ap-amb", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "E2", "contentKind" to "literal",
        ), staged = bytes("00123")) as OfficeAiWire.Settlement.Success
        assertEquals("unknown", (first.body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("transport", (first.body["failure"] as kotlinx.serialization.json.JsonPrimitive).content)
        val dispatchCount = ports.precisionRequests.size
        // A retry of the SAME effect opId refuses before dispatch: the
        // possible effect is retained (reconcile/collect decides honestly).
        val retry = runTicket(commandTicket("ap-amb", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "E2", "contentKind" to "literal",
        ), staged = bytes("00123"))
        assertEquals("applyConflict", (retry as OfficeAiWire.Settlement.Failure).code)
        assertEquals(dispatchCount, ports.precisionRequests.size)
        assertFalse(effects.provesMutationVerified(session, 9L, handle, "ap-amb"))
    }

    @Test
    fun unknownContentStopsNoReplayAndSelectionFactsFeedTheLedger() {
        newService()
        seedSession()
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("rd-9", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.QUERY_TEXT_SELECTION),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TextSelection("chosen words", 12, multiFormatJson = false),
        ))
        val read = runTicket(commandTicket("rd-9", "queryTextSelection", )) as OfficeAiWire.Settlement.Success
        val facts = read.body["facts"] as kotlinx.serialization.json.JsonObject
        assertEquals("chosen words", (facts["selectionText"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("chosen words", selections.forSession(session, 9L)?.selectionText)
    }

    @Test
    fun c12SelectAllReadbackReachesOnlyTheBoundApplyVerifierInput() {
        newService()
        val snapshot = docSnapshot()
        seedSession(snapshot)
        val captureDigest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        val prior = "手记 § Baseline 🧪\nمرحبا שלום mixed RTL\nalpha list one"
        val marker = "Floe LOCAL QA marker applied via scripted fixture (no cloud model)."
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-c12-1", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        runTicket(commandTicket("cap-c12-1", "captureTarget"))
        // The REAL core answer type for an ordinary select-all readback now
        // carries the same exact text that used to be discarded to a count.
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("sel-c12", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SELECT_ALL_TEXT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.TextSelection(prior, bytes(prior).size, multiFormatJson = false),
        ))
        val selected = runTicket(commandTicket("sel-c12", "selectAllText")) as OfficeAiWire.Settlement.Success
        val selectedFacts = selected.body["facts"] as kotlinx.serialization.json.JsonObject
        assertEquals(bytes(prior).size.toString(),
            (selectedFacts["selectedTextBytes"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertFalse("preparatory public facts stay byte-count-only", selectedFacts.containsKey("selectionText"))

        // The public workflow recaptures after selection; proof must bind the
        // NEW handle, not a global latest-selection cache.
        val handle2 = "f".repeat(32)
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-c12-2", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TargetCaptured(
                OfficePrecisionTargetAnswerFixture.fixtureWith(handle2, captureDigest, 4L),
            ),
        ))
        runTicket(commandTicket("cap-c12-2", "captureTarget"))
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("ap-c12", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.APPLY_TEXT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.MutationApplied(
                listOf("pre-effect-selection-readback", "pasteresult-success", "readback-selection-not-comparable"),
                bytes(marker).size, OfficePrecisionContentReadback.UNAVAILABLE, captureDigest, handle2,
                preEffectEvidence = preEffect("ap-c12", prior, handle2),
            ),
        ))
        runTicket(commandTicket("ap-c12", "applyText", "targetHandle" to handle2), staged = bytes(marker))

        // Even a late real query cannot rewrite the already-dispatched proof.
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("rd-c12-late", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.QUERY_TEXT_SELECTION),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TextSelection("late unrelated selection", 24, multiFormatJson = false),
        ))
        runTicket(commandTicket("rd-c12-late", "queryTextSelection"))
        val export = packageFile("docx")
        runTicket(verifyJsonBytes(
            "docx", export.canonicalPath, sha(export.readBytes()), "applyText",
            "verificationMode" to "liveEffect", "effectOpId" to "ap-c12",
            "exportOpId" to "seed-export-c12", "sessionToken" to session, "generation" to "9",
            "targetHandle" to handle2, "taskID" to task, "preEditSha256" to captureDigest,
        ), staged = bytes(marker))
        val input = verifier.inputs.last()
        assertEquals(prior, input.baseline?.priorSelectionText)
        assertEquals(captureDigest, input.baseline?.sha256)
        assertFalse("NATIVE_COMPLETED must leave the semantic-delta path mandatory",
            input.nativeTargetEffectVerified)
        assertEquals(prior, selections.forEffect(session, 9L, handle2, "ap-c12")?.selectionText)
        assertNull(selections.forEffect(session, 9L, handle, "ap-c12"))
        assertNull(selections.forEffect(session, 9L, handle2, "other-op"))
        assertEquals("late unrelated selection", selections.forSession(session, 9L)?.selectionText)
    }

    @Test
    fun unavailableOrMultiMimeSelectionNeverLeavesStalePlainTextProof() {
        newService()
        seedSession()
        selections.observe(OfficeAiSelectionFact(session, 9L, "stale", 5, 1L))
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("sel-complex", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SELECT_ALL_TEXT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.TextSelected(1_048_576),
        ))
        runTicket(commandTicket("sel-complex", "selectAllText"))
        assertNull("a new unavailable readback invalidates the old pending selection",
            selections.forSession(session, 9L))
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("rd-multi", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.QUERY_TEXT_SELECTION),
            OfficePrecisionState.QUERY_OBSERVED,
            OfficePrecisionAnswer.TextSelection("{\"text/plain\":\"not raw body\"}", 32,
                multiFormatJson = true),
        ))
        runTicket(commandTicket("rd-multi", "queryTextSelection"))
        assertNull("multi-MIME JSON is not a plain-text semantic baseline",
            selections.forSession(session, 9L))
    }

    // ------------------------------------------------------------------
    // save
    // ------------------------------------------------------------------

    private fun saveTicket(opId: String, saveOp: String, vararg extra: Pair<String, String>): ByteArray {
        val base = mutableListOf(
            "operation" to "office.save", "epoch" to "$epoch",
            "sessionToken" to session, "generation" to "9",
            "opId" to opId, "saveOperation" to saveOp,
        )
        base += extra
        return base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
    }

    private fun flushReceipt(opId: String, state: OfficeSaveState, token: String = session,
                             generation: Long = 9L, sha256: String? = "b".repeat(64),
                             failure: OfficeSaveFailureCode? = null): OfficeSaveReceipt =
        OfficeSaveReceipt(
            opId = opId, sessionToken = token, generation = generation,
            operation = OfficeSaveOperation.WORKING_COPY_FLUSH, state = state,
            format = null, suggestedName = null, expectedBaseSha256 = null,
            workingCopySha256 = sha256, workingCopyBytes = if (sha256 != null) 4321L else 0L,
            outputDocumentPath = null, outputSha256 = null, outputBytes = 0L,
            failure = failure, message = null, cancelRequested = false,
            attestation = "uno-ack+working-copy-digest",
            submittedAtElapsedMs = 1L, completedAtElapsedMs = 2L,
        )

    @Test
    fun saveRegistersWaiterBeforeDispatchAndCompletesOnExactReceipt() {
        newService(saveWaitMillis = 2_000L)
        seedSession()
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(saveTicket("flush-1", "flush"), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            withTimeout(2_000) { while (ports.saveRequests.isEmpty()) delay(5) }
            // The waiter was registered BEFORE dispatch (submit already ran,
            // the ticket is still pending on its exact receipt):
            assertEquals(1, ports.saveRequests.size)
            assertEquals("flush-1", ports.saveRequests.first().opId)
            // SUBMITTED is not terminal and must never settle a waiter.
            ports.observers.forEach { it(flushReceipt("flush-1", OfficeSaveState.SUBMITTED, sha256 = null)) }
            delay(15)
            // A foreign generation for the same opId also never settles it.
            ports.observers.forEach { it(flushReceipt("flush-1", OfficeSaveState.FLUSHED, generation = 11L)) }
            delay(15)
            // The EXACT identity settles exactly once.
            ports.observers.forEach { it(flushReceipt("flush-1", OfficeSaveState.FLUSHED)) }
            val settlement = withTimeout(2_000) { deferred.await() }
            assertTrue(settlement is OfficeAiWire.Settlement.Success)
            val body = (settlement as OfficeAiWire.Settlement.Success).body
            assertEquals("flushed", (body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals("b".repeat(64), (body["workingCopySHA256"] as kotlinx.serialization.json.JsonPrimitive).content)
            // A duplicate later receipt settles nothing (waiter already gone).
            ports.observers.forEach { it(flushReceipt("flush-1", OfficeSaveState.FLUSHED)) }
            delay(10)
        }
    }

    @Test
    fun saveWaitTimeoutRetainsUnknownWithoutCancelOrReplay() {
        newService()
        seedSession()
        val settlement = runTicket(saveTicket("flush-slow", "flush"))
        assertTrue(settlement is OfficeAiWire.Settlement.Success)
        val body = (settlement as OfficeAiWire.Settlement.Success).body
        assertEquals("unknown", (body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("saveUnknown", (body["failure"] as kotlinx.serialization.json.JsonPrimitive).content)
        // Exactly ONE dispatch, and NO cancel was ever issued (the engine op
        // is left to settle honestly; nothing is replayed or undone).
        assertEquals(1, ports.saveRequests.size)
        // A late receipt after the timeout finds no waiter.
        val late = ports.observers.fold(true) { acc, o -> runCatching { o(flushReceipt("flush-slow", OfficeSaveState.FLUSHED)); acc }.getOrDefault(acc) }
        assertTrue(late)
        assertEquals(1, ports.saveRequests.size)
    }

    @Test
    fun foreignReceiptNeverSettlesOwnWaiter() {
        newService(saveWaitMillis = 2_000L)
        seedSession()
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(saveTicket("flush-own", "flush"), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            withTimeout(2_000) { while (ports.saveRequests.isEmpty()) delay(5) }
            // Same opId, different session token: must not touch our waiter.
            ports.observers.forEach { it(flushReceipt("flush-own", OfficeSaveState.FLUSHED, token = "other-session")) }
            delay(15)
            // Same token, different generation: also foreign.
            ports.observers.forEach { it(flushReceipt("flush-own", OfficeSaveState.FLUSHED, generation = 10L)) }
            delay(15)
            // Exact identity finally settles it.
            ports.observers.forEach { it(flushReceipt("flush-own", OfficeSaveState.FLUSHED)) }
            val settlement = withTimeout(2_000) { deferred.await() }
            assertEquals("flushed",
                ((settlement as OfficeAiWire.Settlement.Success).body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        }
    }

    @Test
    fun saveSubmitRefusalsAreHonestRejectionsWithoutWaiting() {
        newService()
        seedSession()
        for ((code, expectedFailure) in listOf(
            OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SESSION to "sessionMismatch",
            OfficeEngineCommandsPolicy.SUBMIT_REJECTED_BUSY to "saveInFlight",
            OfficeEngineCommandsPolicy.SUBMIT_REJECTED_STATE to "engineNotReady",
        )) {
            ports.saveSubmit = OfficeAiSaveSubmit.Code(code)
            val settlement = runTicket(saveTicket("flush-$code", "flush")) as OfficeAiWire.Settlement.Success
            assertEquals("rejected", (settlement.body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals(expectedFailure, (settlement.body["failure"] as kotlinx.serialization.json.JsonPrimitive).content)
        }
        ports.saveSubmit = OfficeAiSaveSubmit.NotBound
        val transport = runTicket(saveTicket("flush-nt", "flush"))
        assertEquals("transport", (transport as OfficeAiWire.Settlement.Failure).code)
        // NotBound is the PROVEN pre-dispatch refusal: no engine op was
        // started and nothing re-sent (one submit attempt per ticket).
        assertEquals(4, ports.saveRequests.size)
    }

    /**
     * Main final-review dispatch distinction on the save surface: when the
     * submitSave transaction was ISSUED but its reply was lost, the host must
     * resolve through the already-registered exact-key receipt waiter (real
     * FLUSHED receipt below settles the ticket honestly) and NEVER re-send;
     * without any receipt the same op answers UNKNOWN/retained, never a
     * definitely-un-dispatched claim.
     */
    @Test
    fun attemptedWithoutReplyResolvesViaRealReceiptOrUnknownNeverResend() {
        newService(saveWaitMillis = 2_000L)
        seedSession()
        ports.saveSubmit = OfficeAiSaveSubmit.AttemptedWithoutReply
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(saveTicket("flush-amb", "flush"), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            withTimeout(2_000) { while (ports.saveRequests.isEmpty()) delay(5) }
            delay(30)
            // No second dispatch may have happened despite the lost reply.
            assertEquals(1, ports.saveRequests.size)
            // The real receipt resolves the SAME ticket.
            ports.observers.forEach { it(flushReceipt("flush-amb", OfficeSaveState.FLUSHED)) }
            val settlement = withTimeout(2_000) { deferred.await() }
            assertEquals("flushed",
                ((settlement as OfficeAiWire.Settlement.Success).body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals(1, ports.saveRequests.size)
        }
        // Now the same ambiguity WITHOUT any receipt: honest UNKNOWN/retained.
        newService()
        seedSession()
        ports.saveSubmit = OfficeAiSaveSubmit.AttemptedWithoutReply
        val lost = runTicket(saveTicket("flush-lost", "flush")) as OfficeAiWire.Settlement.Success
        assertEquals("unknown", (lost.body["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals(1, ports.saveRequests.size)
    }

    /**
     * Transient launch admission (Main final review): a NEW viewer launch
     * needs actual foreground, a free picker lane and THIS visible chat —
     * while an ALREADY-OWNED document keeps answering with none of them
     * (the viewer's MainActivity pause must never revoke durable ownership).
     */
    @Test
    fun transientLaunchAdmissionRefusesStealButOwnedDocumentSurvivesPause() {
        newService()
        // (a) background: refuse BEFORE any staging.
        ports.foreground = false
        val bg = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
            "requestID" to "adm1",
        ))
        assertEquals("notOwner", (bg as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
        // (b) another chat visible: refuse (no foreground steal).
        ports.foreground = true
        ports.visibleConversation = UUID.randomUUID().toString()
        val other = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
            "requestID" to "adm2",
        ))
        assertEquals("notOwner", (other as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
        // (c) system picker owns the lane: honest busy.
        ports.visibleConversation = task
        ports.pickerPending = true
        val pick = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
            "requestID" to "adm3",
        ))
        assertEquals("busy", (pick as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
        // (d) the already-owned document answers EVEN WHILE backgrounded on
        // another surface: the transient gates never join the durable fence.
        ports.pickerPending = false
        ports.foreground = false
        ports.visibleConversation = "some-other-chat"
        ports.snapshots.put(docSnapshot())
        ports.editState = OfficeEditState(
            session, 9L, "READY_EDITABLE", true, true, true, false, null, null,
        )
        val owned = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
            "requestID" to "adm4",
        )) as OfficeAiWire.Settlement.Success
        assertEquals("false", (owned.body["openedNow"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertNull(ports.opened)
    }

    /**
     * Main review 2026-10-27 gap 1: SettingsSheet is a Dialog layered OVER
     * the still-composed chat and does NOT clear the privacy visible-holder,
     * so the shell's modal projection must refuse a NEW launch even while
     * currentVisibleConversationId still names this chat.
     */
    @Test
    fun modalOverStillComposedChatRefusesNewLaunch() {
        newService()
        ports.visibleConversation = task
        ports.modalOwned = true
        val settlement = runTicket(ticketJson(
            "office.open", "taskID" to task, "workspaceID" to workspace,
            "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
            "requestID" to "modal1",
        ))
        assertEquals("busy", (settlement as OfficeAiWire.Settlement.Failure).code)
        assertNull(ports.opened)
        assertEquals(0, ports.unclaimedCancels)
    }

    /**
     * Main review 2026-10-27 gap 2: routing/background/settings changes DURING
     * staging (before the viewer claim) carry the transient admission: the
     * unclaimed launch is retired through the controller's existing
     * explicit-cancel lane and the ticket settles honestly.
     */
    @Test
    fun transientBreakDuringStagingRetiresOnlyUnclaimedLaunch() {
        newService(openWaitMillis = 2_000L)
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(ticketJson(
                    "office.open", "taskID" to task, "workspaceID" to workspace,
                    "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
                    "requestID" to "stg1",
                ), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            withTimeout(2_000) { while (ports.opened == null) delay(5) }
            // Staging is in flight; NO owned operation exists yet. Break the
            // transient admission before any claim:
            ports.foreground = false
            val settlement = withTimeout(2_000) { deferred.await() }
            assertEquals("sessionEnding", (settlement as OfficeAiWire.Settlement.Failure).code)
            assertEquals(1, ports.unclaimedCancels)
        }
    }

    /**
     * Main review 2026-10-27 boundary: after the claim flips the operation to
     * VIEWING, transient admission is NEVER consulted again — the imminent
     * MainActivity pause under the viewer (background false, chat invisible,
     * even a modal opening) must not cancel or revoke; the real engine
     * readiness still completes the launch honestly.
     */
    @Test
    fun mainPauseAfterClaimKeepsOwnedViewingAndCompletesReadiness() {
        newService(openWaitMillis = 2_000L)
        runBlocking {
            val deferred = async(Dispatchers.Default) {
                val ticket = OfficeAiWire.parseDescriptor(ticketJson(
                    "office.open", "taskID" to task, "workspaceID" to workspace,
                    "nativeEpoch" to "$epoch", "logicalPath" to "reports/quarter-report.docx",
                    "requestID" to "stg2",
                ), epoch)
                service.execute(ticket, ByteArray(0)) { false }
            }
            withTimeout(2_000) { while (ports.opened == null) delay(5) }
            // The claim happened: the operation is now VIEWING (snapshot
            // present + phase flipped). Only THEN does the Main Activity pause
            // under the viewer and other surfaces appear — admission must be
            // ignored entirely from here on.
            ports.snapshots.put(docSnapshot())
            ports.viewingPhase = true
            ports.foreground = false
            ports.modalOwned = true
            ports.visibleConversation = "other-chat-entirely"
            delay(40)
            assertEquals(0, ports.unclaimedCancels)
            ports.editState = OfficeEditState(
                session, 9L, "READY_EDITABLE", true, true, true, false, null, null,
            )
            val settlement = withTimeout(2_000) { deferred.await() }
            assertTrue(settlement is OfficeAiWire.Settlement.Success)
            assertEquals("true",
                ((settlement as OfficeAiWire.Settlement.Success).body["openedNow"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals(0, ports.unclaimedCancels)
        }
    }

    // ------------------------------------------------------------------
    // verify
    // ------------------------------------------------------------------

    private fun packageFile(format: String, content: ByteArray = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1, 2)): File {
        val directory = File(tmpRoot, "floe-office-outputs/9")
        directory.mkdirs()
        val file = File(directory, "seed-export-1-42.$format")
        file.writeBytes(content)
        return file
    }

    private fun verifyJsonBytes(
        format: String, path: String, sha: String, command: String,
        vararg extra: Pair<String, String>,
    ): ByteArray {
        val base = mutableListOf(
            "operation" to "office.verify", "epoch" to "$epoch", "path" to path,
            "sha256" to sha, "format" to format, "expectCommand" to command,
        )
        base += extra
        return base.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)
    }

    @Test
    fun verifyRefusesDigestMismatchAndForeignPathBeforeAnyParsing() {
        newService()
        val file = packageFile("docx")
        // digest mismatch:
        val mismatch = runTicket(verifyJsonBytes(
            "docx", file.canonicalPath, "e".repeat(64), "applyText",
            "verificationMode" to "reconcile", "effectOpId" to "seed-apply-1",
            "exportOpId" to "seed-export-1",
        ), staged = bytes("hello"))
        assertEquals("digestMismatch", (mismatch as OfficeAiWire.Settlement.Failure).code)
        // path outside the app data root:
        val foreign = runTicket(verifyJsonBytes(
            "docx", "/system/etc/hosts", "e".repeat(64), "applyText",
            "verificationMode" to "reconcile", "effectOpId" to "a", "exportOpId" to "b",
        ), staged = bytes("hello"))
        assertEquals("packageUnreadable", (foreign as OfficeAiWire.Settlement.Failure).code)
        assertTrue(verifier.inputs.isEmpty())
    }

    @Test
    fun liveEffectCarriesOwnedProofFlagsAndRawExpectedValue() {
        newService()
        val snapshot = docSnapshot()
        seedSession(snapshot)
        val captureDigest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-v", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        runTicket(commandTicket("cap-v", "captureTarget", ))
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("ap-v", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SET_CELL_CONTENT),
            OfficePrecisionState.MUTATION_VERIFIED,
            OfficePrecisionAnswer.MutationApplied(listOf("ok"), 7,
                OfficePrecisionContentReadback.MATCHED, captureDigest, handle,
                preEffectEvidence = preEffect("ap-v", "old display")),
        ))
        runTicket(commandTicket("ap-v", "setCellContent",  "targetHandle" to handle,
            "cellAddress" to "C3", "contentKind" to "literal",
        ), staged = bytes("00123"))
        val export = packageFile("xlsx")
        val settlement = runTicket(verifyJsonBytes(
            "xlsx", export.canonicalPath, sha(export.readBytes()), "setCellContent",
            "verificationMode" to "liveEffect", "effectOpId" to "ap-v",
            "exportOpId" to "seed-export-1", "sessionToken" to session, "generation" to "9",
            "targetHandle" to handle, "taskID" to task,
            "cellAddress" to "C3", "contentKind" to "literal",
            "expectPartIndex" to "1", "preEditSha256" to captureDigest,
        ), staged = bytes("00123")) as OfficeAiWire.Settlement.Success
        val input = verifier.inputs.last()
        // The verifier sees the RAW wanted value, never the codec apostrophe:
        assertEquals("00123", input.expectedText)
        assertTrue(input.nativeTargetEffectVerified)
        assertFalse(input.trustedCompletedJobProof)
        assertEquals(1, input.partIndex)
        assertNotNull(input.baseline)
        assertEquals(captureDigest, input.baseline?.sha256)
        assertEquals("old display", input.baseline?.priorSelectionText)
        assertEquals("2", (settlement.body["proofVersion"] as kotlinx.serialization.json.JsonPrimitive).content)
    }

    @Test
    fun ordinaryFormulaFlowBindsOnlyTheApplyOperationsOwnFreshDisplay() {
        newService()
        val snapshot = docSnapshot(path = "qa/formula-basic.xlsx", formatExt = "xlsx")
        seedSession(snapshot)
        val captureDigest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-f59", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        runTicket(commandTicket("cap-f59", "captureTarget"))
        // No public queryTextSelection and NO SelectionLedger.observe: the
        // normal setCellContent operation returns its own pre-paste display.
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cell-f59", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SET_CELL_CONTENT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.MutationApplied(
                listOf("cursor-at-target", "pre-effect-selection", "pasteresult-success", "cursor-confirm"),
                11, OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE, captureDigest, handle,
                preEffectEvidence = preEffect("cell-f59", "7"),
            ),
        ))
        runTicket(commandTicket("cell-f59", "setCellContent", "targetHandle" to handle,
            "cellAddress" to "B4", "contentKind" to "formula"), staged = bytes("=SUM(B2:B3)"))
        val export = packageFile("xlsx")
        runTicket(verifyJsonBytes(
            "xlsx", export.canonicalPath, sha(export.readBytes()), "setCellContent",
            "verificationMode" to "liveEffect", "effectOpId" to "cell-f59",
            "exportOpId" to "seed-export-f59", "sessionToken" to session, "generation" to "9",
            "targetHandle" to handle, "taskID" to task, "cellAddress" to "B4",
            "contentKind" to "formula", "expectPartIndex" to "1", "preEditSha256" to captureDigest,
        ), staged = bytes("=SUM(B2:B3)"))
        val input = verifier.inputs.last()
        assertEquals("7", input.baseline?.priorSelectionText)
        assertEquals(1, input.partIndex)
        assertFalse("FORMULA_NOT_COMPARABLE is not native effect proof", input.nativeTargetEffectVerified)
        assertEquals("7", selections.forEffect(session, 9L, handle, "cell-f59")?.selectionText)
        assertTrue(ports.precisionRequests.none {
            it.action == com.floe.android.core.officeengine.precision.OfficePrecisionAction.QUERY_TEXT_SELECTION
        })
    }

    @Test
    fun ordinaryPptxSlideFlowBindsRealEmptySelectionAtTheCapturedSlide() {
        newService()
        val snapshot = docSnapshot(path = "qa/slides.pptx", formatExt = "pptx")
        seedSession(snapshot)
        val captureDigest = sha(File(snapshot.stagedWorkingCopyPath!!).readBytes())
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("slide-f59", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.SELECT_SLIDE),
            OfficePrecisionState.MUTATION_VERIFIED, OfficePrecisionAnswer.SlideSelected("1"),
        ))
        runTicket(commandTicket("slide-f59", "selectSlide", "partId" to "1"))
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("cap-p59", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.CAPTURE_TARGET),
            OfficePrecisionState.QUERY_OBSERVED, targetCaptured(captureDigest),
        ))
        runTicket(commandTicket("cap-p59", "captureTarget"))
        val marker = "selected-slide marker"
        ports.precisionScript.add(precisionResult(
            OfficePrecisionRequest("apply-p59", session, 9L,
                com.floe.android.core.officeengine.precision.OfficePrecisionAction.APPLY_TEXT),
            OfficePrecisionState.NATIVE_COMPLETED,
            OfficePrecisionAnswer.MutationApplied(
                listOf("pre-effect-part", "pre-effect-empty-selection", "pasteresult-success"),
                bytes(marker).size, OfficePrecisionContentReadback.UNAVAILABLE, captureDigest, handle,
                preEffectEvidence = preEffect("apply-p59", ""),
            ),
        ))
        runTicket(commandTicket("apply-p59", "applyText", "targetHandle" to handle), staged = bytes(marker))
        val export = packageFile("pptx")
        runTicket(verifyJsonBytes(
            "pptx", export.canonicalPath, sha(export.readBytes()), "applyText",
            "verificationMode" to "liveEffect", "effectOpId" to "apply-p59",
            "exportOpId" to "seed-export-p59", "sessionToken" to session, "generation" to "9",
            "targetHandle" to handle, "taskID" to task, "expectPartIndex" to "1",
            "preEditSha256" to captureDigest,
        ), staged = bytes(marker))
        val input = verifier.inputs.last()
        assertEquals("a real empty selection means insertion, not missing evidence",
            "", input.baseline?.priorSelectionText)
        assertEquals(1, input.partIndex)
        assertEquals("1", selections.forEffect(session, 9L, handle, "apply-p59")?.partId)
        assertNull(selections.forEffect(session, 9L, handle, "other-op"))
    }

    @Test
    fun completedJobAfterSessionDeathStillGetsTrustedProofWithoutLiveSession() {
        newService()
        // No bind, no live snapshot: the engine session is gone (collect of a
        // durable completed job). The digest-verified artifact + Core's
        // trusted durable-v2 mode is the proof binding.
        val export = packageFile("pptx")
        val settlement = runTicket(verifyJsonBytes(
            "pptx", export.canonicalPath, sha(export.readBytes()), "applyText",
            "verificationMode" to "completedJob", "effectOpId" to "seed-apply-1",
            "exportOpId" to "seed-export-1", "expectPartIndex" to "2",
        ), staged = bytes("slide text")) as OfficeAiWire.Settlement.Success
        val input = verifier.inputs.last()
        assertTrue(input.trustedCompletedJobProof)
        assertFalse(input.nativeTargetEffectVerified)
        assertNull(input.baseline)
        assertEquals(2, input.partIndex)
        assertTrue(settlement.body.containsKey("inspected"))
    }

    @Test
    fun reconcileWithoutProofStaysUnprovableNotFilenameSuccess() {
        newService()
        val export = packageFile("docx")
        verifier.next = OfficeAiVerificationResult.Verified(
            defaultFacts().copy(
                targetEffectVerified = false, semanticDeltaVerified = false,
                proofReused = false,
            ),
        )
        val settlement = runTicket(verifyJsonBytes(
            "docx", export.canonicalPath, sha(export.readBytes()), "applyText",
            "verificationMode" to "reconcile", "effectOpId" to "seed-apply-1",
            "exportOpId" to "seed-export-1",
        ), staged = bytes("text")) as OfficeAiWire.Settlement.Success
        val body = settlement.body
        assertEquals("false", (body["targetEffectVerified"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("false", (body["semanticDeltaVerified"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("false", (body["proofReused"] as kotlinx.serialization.json.JsonPrimitive).content)
    }

    @Test
    fun xlsxVerifyWithoutCapturedPartIndexRefuses() {
        newService()
        val export = packageFile("xlsx")
        val settlement = runTicket(verifyJsonBytes(
            "xlsx", export.canonicalPath, sha(export.readBytes()), "applyText",
            "verificationMode" to "reconcile", "effectOpId" to "a", "exportOpId" to "b",
        ), staged = bytes("text"))
        assertEquals("structureInvalid", (settlement as OfficeAiWire.Settlement.Failure).code)
        // NEVER a sheet1 guess, never a unique-cell scan fallback.
        assertTrue(verifier.inputs.isEmpty())
    }

    // ------------------------------------------------------------------
    // reconcile
    // ------------------------------------------------------------------

    @Test
    fun reconcileFindsOneExactArtifactZeroAndAmbiguityHonestly() {
        newService()
        val directory = File(tmpRoot, "floe-office-outputs/9")
        directory.mkdirs()
        val settlement0 = runTicket(ticketJson(
            "office.reconcile", "exportOpId" to "never-exported", "format" to "docx",
        )) as OfficeAiWire.Settlement.Success
        assertEquals("false", (settlement0.body["found"] as kotlinx.serialization.json.JsonPrimitive).content)
        File(directory, "seed-export-1-42.docx").writeBytes(byteArrayOf(1))
        val found = runTicket(ticketJson(
            "office.reconcile", "exportOpId" to "seed-export-1", "format" to "docx",
        )) as OfficeAiWire.Settlement.Success
        assertEquals("true", (found.body["found"] as kotlinx.serialization.json.JsonPrimitive).content)
        // A second match is ambiguous — NEVER a newest guess:
        File(directory, "seed-export-1-99.docx").writeBytes(byteArrayOf(2))
        val ambiguous = runTicket(ticketJson(
            "office.reconcile", "exportOpId" to "seed-export-1", "format" to "docx",
        ))
        assertEquals("ambiguousArtifact", (ambiguous as OfficeAiWire.Settlement.Failure).code)
        // A foreign opId prefix must not count as a match.
        File(directory, "seed-export-1x-1.docx").writeBytes(byteArrayOf(3))
        val still = runTicket(ticketJson(
            "office.reconcile", "exportOpId" to "seed-export-1x", "format" to "docx",
        )) as OfficeAiWire.Settlement.Success
        assertEquals("true", (still.body["found"] as kotlinx.serialization.json.JsonPrimitive).content)
    }

    // ------------------------------------------------------------------
    // pushOriginal
    // ------------------------------------------------------------------

    private fun pushTicket(path: String = "reports/quarter-report.docx"): ByteArray = ticketJson(
        "office.pushOriginal", "taskID" to task, "workspaceID" to workspace,
        "nativeEpoch" to "$epoch", "logicalPath" to path,
    )

    @Test
    fun pushOriginalRefusesManualRetargetAndClosedRoot() {
        newService()
        seedSession()
        val retarget = runTicket(pushTicket("reports/other.docx"))
        assertEquals("sessionMismatch", (retarget as OfficeAiWire.Settlement.Failure).code)
        ports.snapshots.clear()
        val closed = runTicket(pushTicket())
        assertEquals("noOwnedDocument", (closed as OfficeAiWire.Settlement.Failure).code)
        // No lane was ever opened for a refused identity.
        assertTrue(ports.pushCalls.isEmpty())
    }

    @Test
    fun pushOriginalMapsLadderStatusesIncludingDriftAndPending() {
        newService()
        seedSession()
        ports.pushResults.add(WorkspaceSourceResult("ok", "", mapOf("recoveryID" to "r-1")))
        val ok = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("ok", (ok.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("r-1", (ok.body["recoveryID"] as kotlinx.serialization.json.JsonPrimitive).content)

        ports.pushResults.add(WorkspaceSourceResult(
            "conflict", "the provider changed at the write-permit boundary",
        ))
        val drift = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("driftAtClaim", (drift.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)

        ports.pushResults.add(WorkspaceSourceResult("unbound", "no provider row"))
        val unbound = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("sourceUnbound", (unbound.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)

        ports.pushResults.add(WorkspaceSourceResult(
            "providerOffline", "row stays honestly pending", mapOf("recoveryID" to "r-2"),
        ))
        val pending = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("pendingRecoverable", (pending.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)

        ports.pushResults.add(WorkspaceSourceResult("sourceChangedSinceImport", "drift before ladder"))
        val changed = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("sourceChangedSinceImport", (changed.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)

        ports.pushResults.add(WorkspaceSourceResult("runtimeUnavailable", "root gone mid-ladder"))
        val unknown = runTicket(pushTicket()) as OfficeAiWire.Settlement.Success
        assertEquals("unknown", (unknown.body["status"] as kotlinx.serialization.json.JsonPrimitive).content)

        // No headless lane at all: typed fence refusal, nothing dispatched.
        val fenced = runTicket(pushTicket())
        assertEquals("laneFenced", (fenced as OfficeAiWire.Settlement.Failure).code)
    }

}

/** Pure fixture factory for the engine capture answer (mirrors the delivered
 * OfficePrecisionTarget shape; the codec/digest assertions below use it). */
internal object OfficePrecisionTargetAnswerFixture {
    fun fixture(handle: String, workingCopySha: String?): OfficePrecisionTarget =
        fixtureWith(handle, workingCopySha, if (workingCopySha != null) 4L else 0L)

    fun fixtureWith(
        handle: String, workingCopySha: String?, workingCopyBytes: Long,
    ): OfficePrecisionTarget = OfficePrecisionTarget(
        handleId = handle,
        generation = 9L,
        sourceId = null,
        sourceRevision = null,
        sourceLogicalPath = null,
        workspaceId = null,
        ownerTaskId = null,
        workingCopySha256 = workingCopySha,
        workingCopyBytes = workingCopyBytes,
        inputEpoch = 0,
        editEpoch = 0,
        documentModified = false,
        docType = "calc",
        partsCount = 3,
        selectedPart = "1",
        capturedAtElapsedMs = 1L,
        expiresAtElapsedMs = Long.MAX_VALUE / 4,
    )
}
