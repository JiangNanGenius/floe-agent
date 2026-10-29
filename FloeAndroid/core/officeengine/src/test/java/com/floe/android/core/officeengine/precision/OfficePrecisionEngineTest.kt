// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import com.floe.android.core.officeengine.CoolMessageTriage
import com.floe.android.core.officeengine.OfficeDocumentFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM regression for the precision ENGINE orchestration with a fake mount
 * host: admission fences, the exact pinned wire sequence per action, the
 * native-operation lease (page retarget/write fencing with render/keepalive
 * preserved), capture→apply CAS conflicts, and honest terminal states.
 *
 * The fake host runs the control lane INLINE and hands timeouts back to the
 * test, so every interleaving here is deterministic. Real frames are built
 * as bytes and pushed through the REAL CoolMessageTriage classifier (the
 * same path Session.onMessageToJs uses before the WebView relay).
 */
class OfficePrecisionEngineTest {

    private class FakeHost(
        private val format: OfficeDocumentFormat = OfficeDocumentFormat.DOCX,
    ) : OfficePrecisionEngine.OfficePrecisionHost {
        var readyState = true
        var editableReady = true
        var mountLive = true
        var saveBusy = false
        var digest: Pair<String, Long>? = "sha-a" to 10L
        var modified: Boolean? = false
        var ownerTask: String? = null
        var workspace: String? = null
        var pageEditMode = true
        var deferEditPreparation = false
        var editPreparationFailure: OfficePrecisionFailure? = null
        var beforeWireSend: ((String) -> Unit)? = null

        /** Stand-in for LOActivity.nativeIngressLock (the session-wide monitor). */
        val ingressLock = Any()

        val wires = ArrayList<String>()

        /**
         * The ENGINE's own dispatched wire channel only. Production keeps
         * this separate from a page's admitted JNI send: an admitted
         * keepalive (`tile`, `ping`, …) is posted by LOActivity's own ingress
         * section and never flows through [OfficePrecisionEngine]'s
         * `sendWire`, while [wires] above deliberately records BOTH channels
         * so the lease-fence assertions can see an admitted page send. Any
         * assertion about the engine's plan ordering must therefore read this
         * list, not the shared one.
         */
        val engineWires = ArrayList<String>()
        val dispatchEvents = ArrayList<String>()
        val editAssertionsUnderMonitor = ArrayList<Boolean>()
        val digestUnderMonitor = ArrayList<Boolean>()
        val editPreparationCallbacks =
            LinkedHashMap<String, (OfficePrecisionFailure?, String) -> Unit>()

        /** For every wire: whether the send happened UNDER the ingress monitor. */
        val wireUnderMonitor = ArrayList<Boolean>()
        val diagnostics = ArrayList<String>()
        private val timeouts = ArrayList<Pair<Long, Runnable>>()
        private val cancelledTimeouts = HashSet<Int>()
        var now = 5_000L

        override fun sessionToken() = "tok"
        override fun generation() = 3L
        override fun documentFormat() = format
        override fun isReadyState() = readyState
        override fun isEditableReady() = editableReady
        override fun isMountLive() = mountLive
        override fun saveBusy() = saveBusy
        override fun workingCopyDigest(): Pair<String, Long>? {
            digestUnderMonitor.add(Thread.holdsLock(ingressLock))
            return digest
        }
        override fun ownerTaskId() = ownerTask
        override fun workspaceId() = workspace
        override fun sourceId() = "src-1"
        override fun sourceRevision() = "rev-9"
        override fun sourceLogicalPath() = null
        override fun documentModified() = modified
        override fun isPageEditMode() = pageEditMode
        override fun prepareEditableView(
            opId: String,
            callback: (OfficePrecisionFailure?, String) -> Unit,
        ) {
            val failure = editPreparationFailure
            when {
                failure != null -> callback(failure, "edit-preparation:test-refusal")
                pageEditMode && !deferEditPreparation ->
                    callback(null, "edit-preparation:page-edit-mode-observed")
                else -> editPreparationCallbacks[opId] = callback
            }
        }
        override fun cancelEditableViewPreparation(opId: String) {
            editPreparationCallbacks.remove(opId)
        }
        override fun sendOwnedNativeEditable() {
            dispatchEvents.add("native-editable")
            editAssertionsUnderMonitor.add(Thread.holdsLock(ingressLock))
        }
        override fun sendWire(message: String) {
            beforeWireSend?.invoke(message)
            wires.add(message)
            engineWires.add(message)
            dispatchEvents.add("wire:$message")
            wireUnderMonitor.add(Thread.holdsLock(ingressLock))
        }
        override fun runOnControlLane(task: Runnable): Boolean {
            task.run() // deterministic inline control lane
            return true
        }
        override fun scheduleTimeout(delayMs: Long, task: Runnable): Any {
            timeouts.add(delayMs to task)
            return timeouts.size - 1
        }
        override fun cancelTimeout(handle: Any) {
            cancelledTimeouts.add(handle as Int)
        }
        override fun nativeIngressLock(): Any = ingressLock
        override fun recordDiagnostic(detail: String) {
            diagnostics.add(detail)
        }
        override fun elapsedMs() = now

        /** Fires the most recent still-armed timeout (bounded watchdog). */
        fun fireLatestTimeout() {
            val index = timeouts.size - 1
            assertTrue("no timeout armed", index >= 0)
            assertFalse("timeout already cancelled", cancelledTimeouts.contains(index))
            timeouts[index].second.run()
        }

        /** Completes only the page handshake; native assertion remains a separate dispatch fact. */
        fun completeEditPreparation(opId: String) {
            pageEditMode = true
            val callback = editPreparationCallbacks.remove(opId)
                ?: error("no deferred edit preparation for $opId")
            callback(null, "edit-preparation:page-edit-mode-observed")
        }

        /**
         * Mirrors the pinned LOActivity atomic ingress section for one page
         * message: gate check → "JNI send" → forwarded callback, all inside
         * the SAME monitor the precision dispatch uses. Returns true when
         * the page message was admitted (and its epoch bookkeeping ran).
         */
        fun admittedPageSend(engine: OfficePrecisionEngine, commandHead: String): Boolean =
            synchronized(ingressLock) {
                if (engine.blocksPageCommand(commandHead)) {
                    false
                } else {
                    wires.add("page:$commandHead")
                    engine.noteForwardedPageCommand(commandHead)
                    true
                }
            }
    }

    private fun feed(engine: OfficePrecisionEngine, frame: String) {
        val bytes = frame.toByteArray(Charsets.UTF_8)
        engine.observeNativeFrame(CoolMessageTriage.classify(bytes), bytes)
    }

    private fun req(
        opId: String,
        action: OfficePrecisionAction,
        text: String? = null,
        contentKind: OfficePrecisionContentKind? = null,
        cellAddress: String? = null,
        partId: String? = null,
        targetHandle: String? = null,
        ownerTaskId: String? = null,
        workspaceId: String? = null,
    ) = OfficePrecisionRequest(
        opId = opId,
        sessionToken = "tok",
        generation = 3L,
        action = action,
        text = text,
        contentKind = contentKind,
        cellAddress = cellAddress,
        partId = partId,
        targetHandle = targetHandle,
        ownerTaskId = ownerTaskId,
        workspaceId = workspaceId,
    )

    private val statusFrame =
        "status: {\"type\":\"text\",\"partscount\":1,\"selectedpart\":\"0\"," +
            "\"width\":11906,\"height\":16838,\"viewid\":0}"

    // Producer-pinned presentation identifiers (Collabora Mobile
    // 26.04.4.2/937 @2333344185931274f9c49d6c12a408cefcef6844): a
    // presentation's `selectedpart` is the braced page GUID and each
    // `parts` entry carries its `part` (kit/KitHelper.hpp documentStatus +
    // fetchPartsData; the pinned ImpressTileLayer consumes exactly these
    // fields for its own setclientpart). Decimal selectedpart is NEVER the
    // presentation wire shape — the old fixtures that showed it were
    // parroting the wrong algorithm.
    private val pageGuidA = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5A0}"
    private val pageGuidB = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1}"
    private val pageGuidC = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5C2}"

    private fun presentationStatus(
        selected: String,
        ids: List<String> = listOf(pageGuidA, pageGuidB, pageGuidC),
    ) = "status: {\"type\":\"presentation\",\"partscount\":${ids.size}," +
        "\"selectedpart\":\"$selected\",\"width\":10,\"height\":10,\"viewid\":0," +
        "\"parts\":[" + ids.joinToString(",") {
        "{\"part\":\"$it\",\"width\":10,\"height\":10,\"mode\":0}"
    } + "]}"

    private fun statusFor(part: String, type: String = "text") =
        if (type == "presentation" || type == "drawing") {
            presentationStatus(part)
        } else {
            "status: {\"type\":\"$type\",\"partscount\":3,\"selectedpart\":\"$part\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}"
        }

    /** Drive the production pre-effect status + selection pulls. The apply
     * itself then dispatches paste; no host ledger or verifier prior is set.
     *
     * Ordering is asserted on [FakeHost.engineWires] — the engine's own
     * channel — because a keepalive page send admitted DURING a live lease
     * (`admittedPageSend(engine, "tile")`) is recorded in the shared [FakeHost.wires]
     * list after the engine's pre-effect `status` wire, exactly as production
     * allows it (LEASE_KEEPALIVE_COMMANDS). Reading the shared list here
     * would mistake that legitimate page traffic for the engine's last plan
     * wire. */
    private fun acquirePreEffect(
        engine: OfficePrecisionEngine,
        host: FakeHost,
        prior: String,
        part: String = "0",
        type: String = "text",
        status: String? = null,
    ) {
        assertEquals("status", host.engineWires.last())
        feed(engine, status ?: statusFor(part, type))
        assertEquals(OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION, host.engineWires.last())
        feed(engine, "textselectioncontent: $prior")
    }

    // ------------------------------------------------------------------
    // Admission fences
    // ------------------------------------------------------------------

    @Test
    fun fencesRefuseTypedBeforeAnyWireEffect() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)

        // Wrong token / generation: engine identity fence.
        val badToken = engine.submit(
            req("a", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT).copy(sessionToken = "other"),
        )
        assertEquals(OfficePrecisionState.REJECTED, badToken.state)
        assertEquals(OfficePrecisionFailure.SESSION_MISMATCH, badToken.failure)
        val badGen = engine.submit(
            req("b", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT).copy(generation = 99L),
        )
        assertEquals(OfficePrecisionFailure.SESSION_MISMATCH, badGen.failure)
        assertTrue(host.wires.isEmpty())

        // Mount not ready.
        host.readyState = false
        val notReady = engine.submit(req("c", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertEquals(OfficePrecisionFailure.SESSION_ENDING, notReady.failure)
        assertEquals("mount-not-ready", notReady.detail)
        host.readyState = true

        // Owner echo disagreement is refused; the mount record wins.
        host.ownerTask = "task-1"
        val ownerClash = engine.submit(
            req("d", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT, ownerTaskId = "task-2"),
        )
        assertEquals(OfficePrecisionFailure.OWNER_MISMATCH, ownerClash.failure)
        // Matching echo is admitted.
        val ownerOk = engine.submit(
            req("e", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT, ownerTaskId = "task-1"),
        )
        assertEquals(OfficePrecisionState.ADMITTED, ownerOk.state)
        feed(engine, statusFrame)

        // Mutations require the full editable witness set; queries do not.
        host.editableReady = false
        feed(engine, statusFrame) // drain "e"
        val query = engine.submit(req("f", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertEquals(OfficePrecisionState.ADMITTED, query.state)
        feed(engine, statusFrame)
        assertNotNull(engine.readAnswer("f", "tok", 3L))
        val mutation = engine.submit(
            req("g", OfficePrecisionAction.SELECT_ALL_TEXT),
        )
        assertEquals(OfficePrecisionState.REJECTED, mutation.state)
        assertEquals(OfficePrecisionFailure.NOT_EDITABLE, mutation.failure)

        // Save in flight fences mutations (one native-session op at a time).
        host.editableReady = true
        host.saveBusy = true
        val busy = engine.submit(req("h", OfficePrecisionAction.SELECT_ALL_TEXT))
        assertEquals(OfficePrecisionFailure.SAVE_IN_FLIGHT, busy.failure)
        host.saveBusy = false

        // Family availability is honest, never an all-unsupported stub.
        val calcOnly = engine.submit(req("i", OfficePrecisionAction.QUERY_CELL_CURSOR))
        assertEquals(OfficePrecisionFailure.UNSUPPORTED_ACTION, calcOnly.failure)
    }

    // ------------------------------------------------------------------
    // Capture → apply CAS lifecycle
    // ------------------------------------------------------------------

    @Test
    fun captureIssuesHandleAndApplyConsumesIt() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        val admitted = engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        assertEquals(OfficePrecisionState.ADMITTED, admitted.state)
        assertEquals(listOf("status"), host.wires)
        feed(
            engine,
            "status: {\"type\":\"text\",\"partscount\":2,\"selectedpart\":\"1\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val capture = engine.readAnswer("cap", "tok", 3L)!!
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, capture.state)
        val target = (capture.answer as OfficePrecisionAnswer.TargetCaptured).target
        assertTrue(target.handleId.matches(Regex("^[0-9a-f]{32}$")))
        // Dual identity: original-source base stays separate from the
        // current flushed-file working identity + epochs.
        assertEquals("src-1", target.sourceId)
        assertEquals("rev-9", target.sourceRevision)
        assertEquals("sha-a", target.workingCopySha256)
        assertEquals(10L, target.workingCopyBytes)
        assertEquals("text", target.docType)
        assertEquals("1", target.selectedPart)

        // APPLY_TEXT consumes the handle, acquires fresh BEFORE evidence at
        // the captured part, then sends paste followed by soft readback.
        val apply = engine.submit(
            req("ap", OfficePrecisionAction.APPLY_TEXT, text = "hello", targetHandle = target.handleId),
        )
        assertEquals(OfficePrecisionState.ADMITTED, apply.state)
        acquirePreEffect(engine, host, "before", part = "1")
        assertEquals(
            "paste mimetype=text/plain;charset=utf-8\naGVsbG8=",
            host.wires.last(),
        )
        feed(engine, "pasteresult: success")
        assertEquals(
            "gettextselection mimetype=text/plain;charset=utf-8",
            host.wires.last(),
        )
        feed(engine, "textselectioncontent: hello")
        val applied = engine.readAnswer("ap", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, applied.state)
        assertEquals(
            OfficePrecisionContentReadback.MATCHED,
            (applied.answer as OfficePrecisionAnswer.MutationApplied).contentReadback,
        )
        val evidence = (applied.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals("before", evidence?.selectionText)
        assertEquals("ap", evidence?.opId)
        assertEquals(target.handleId, evidence?.targetHandle)
        assertEquals("1", evidence?.partId)
        assertEquals(target.inputEpoch, evidence?.inputEpoch)
        assertEquals(target.editEpoch, evidence?.editEpoch)

        // The consumed handle can never be replayed.
        val replay = engine.submit(
            req("ap2", OfficePrecisionAction.APPLY_TEXT, text = "again", targetHandle = target.handleId),
        )
        assertEquals(OfficePrecisionState.ADMITTED, replay.state) // admitted, then refused at dispatch
        val replayResult = engine.readAnswer("ap2", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, replayResult.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNKNOWN, replayResult.failure)
    }

    /**
     * The capture handle must CARRY the producer's own observed part, not
     * merely advertise it: the target handed to the fenced owner and the
     * target a later content mutation validates/consumes are ONE immutable
     * value. A handle whose stored `selectedPart` stayed null could never
     * satisfy the mandatory pre-effect part gate, so every APPLY_TEXT /
     * SET_CELL_CONTENT would be refused TARGET_UNVERIFIED before its own
     * paste wire in all three families (the real C13 defect behind the 13
     * grouped `expected gettextselection but was status` failures).
     */
    @Test
    fun capturedHandleBindsProducerObservedPartForThePreEffectGate() {
        val host = FakeHost(format = OfficeDocumentFormat.PPTX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFor(pageGuidC, "presentation"))
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        // The pinned producer names presentation pages by their braced GUID
        // (never a decimal index) — the capture binds exactly that witness.
        assertEquals(pageGuidC, target.selectedPart)
        // …AND the separately carried logical ordinal from the SAME status
        // answer's ordered parts witness (page C = position 2), which the
        // host forwards as facts partIndex for the saved-verification
        // lineage (pre-84 the host re-parse made this null for every GUID).
        assertEquals(2, target.selectedPartIndex)
        assertEquals("presentation", target.docType)
        assertEquals(3, target.partsCount)

        // A stale/foreign part at the pre-effect status pull refuses BEFORE
        // the selection pull and BEFORE any paste wire — no late query reuse
        // and no replay of the consumed handle.
        engine.submit(
            req("ap-foreign", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        assertEquals("status", host.engineWires.last())
        val wiresAtRefusal = host.engineWires.size
        feed(engine, statusFor(pageGuidB, "presentation"))
        val refused = engine.readAnswer("ap-foreign", "tok", 3L)!!
        assertEquals(OfficePrecisionState.FAILED, refused.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, refused.failure)
        assertEquals("pre-effect-part-mismatch", refused.detail)
        assertEquals("refused before the pre-effect selection pull", wiresAtRefusal, host.engineWires.size)
        assertTrue(host.wires.none { it.startsWith("paste ") })

        // The same lineage at the REAL captured part reaches paste, and the
        // bound evidence carries the producer-observed part plus both native
        // epochs — never a null guess and never an ambient cached selection.
        engine.submit(req("cap2", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFor(pageGuidC, "presentation"))
        val target2 = (engine.readAnswer("cap2", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        assertEquals(pageGuidC, target2.selectedPart)
        engine.submit(
            req("ap-real", OfficePrecisionAction.APPLY_TEXT, text = "marker", targetHandle = target2.handleId),
        )
        acquirePreEffect(engine, host, "", part = pageGuidC, type = "presentation")
        assertTrue(host.engineWires.last().startsWith("paste "))
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: marker")
        val applied = engine.readAnswer("ap-real", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, applied.state)
        val evidence = (applied.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals(pageGuidC, evidence?.partId)
        assertEquals("the actual empty native selection is the insertion baseline", "", evidence?.selectionText)
        assertEquals(0, evidence?.selectionByteCount)
        assertEquals(target2.handleId, evidence?.targetHandle)
        assertEquals(target2.inputEpoch, evidence?.inputEpoch)
        assertEquals(target2.editEpoch, evidence?.editEpoch)
    }

    /**
     * Main lineage review (part-ordinal84): a byte-exact GUID match at the
     * pre-effect status is NOT a position match — the pinned producer can
     * re-order the deck while keeping the shown page's identifier. The
     * captured witnessed ordinal must be RE-PROVEN from THIS fresh
     * synchronous status' own complete, closed, count-consistent ordered
     * parts witness; otherwise the operation refuses BEFORE the pre-effect
     * selection pull and before any paste/commit wire, with zero effect —
     * never left for the later OOXML verifier to discover after the bytes
     * already moved.
     */
    @Test
    fun capturedPresentationReorderRefusesPreEffectWithZeroEffectWires() {
        val host = FakeHost(format = OfficeDocumentFormat.PPTX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        assertEquals(pageGuidB, target.selectedPart)
        assertEquals(1, target.selectedPartIndex)

        engine.submit(
            req("ap-reorder", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        assertEquals("status", host.engineWires.last())
        val wiresAtRefusal = host.engineWires.size
        // SAME GUID identity, now witnessed at logical ordinal 0
        // (the deck reordered: parts [B, A]).
        feed(engine, presentationStatus(pageGuidB, listOf(pageGuidB, pageGuidA)))
        val refused = engine.readAnswer("ap-reorder", "tok", 3L)!!
        assertEquals(OfficePrecisionState.FAILED, refused.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, refused.failure)
        assertEquals("pre-effect-part-ordinal-drift", refused.detail)
        // Zero effect: no pre-effect selection pull and no paste wire ever
        // left the engine for this attempt.
        assertEquals("refused before the pre-effect selection pull", wiresAtRefusal, host.engineWires.size)
        assertTrue(host.wires.none { it.startsWith("paste ") })

        // Ordinary UNCHANGED-witness path (control): a fresh capture whose
        // shown page keeps the same complete ordered witness applies
        // normally — the fence never disturbs the healthy lineage.
        engine.submit(req("cap2", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        val target2 = (engine.readAnswer("cap2", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        assertEquals(1, target2.selectedPartIndex)
        engine.submit(
            req("ap-plain", OfficePrecisionAction.APPLY_TEXT, text = "marker", targetHandle = target2.handleId),
        )
        acquirePreEffect(engine, host, "", part = pageGuidB, type = "presentation",
            status = presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        assertTrue(host.engineWires.last().startsWith("paste "))
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: marker")
        val applied = engine.readAnswer("ap-plain", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, applied.state)
        val evidence = (applied.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals(pageGuidB, evidence?.partId)
        assertEquals(target2.handleId, evidence?.targetHandle)
    }

    @Test
    fun capturedPresentationFamilyOrCountDriftRefusesBeforeEffects() {
        val capturedStatus = presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB))
        val variants = linkedMapOf(
            "text" to capturedStatus.replace("\"type\":\"presentation\"", "\"type\":\"text\""),
            "unknown" to capturedStatus.replace("\"type\":\"presentation\"", "\"type\":\"unknown\""),
            "missing-family" to capturedStatus.replace("\"type\":\"presentation\",", ""),
            "drawing" to capturedStatus.replace("\"type\":\"presentation\"", "\"type\":\"drawing\""),
            "count" to presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB, pageGuidC)),
        )
        for ((label, freshStatus) in variants) {
            assertTrue("$label must change the native answer", freshStatus != capturedStatus)
            val host = FakeHost(format = OfficeDocumentFormat.PPTX)
            val engine = OfficePrecisionEngine(host)
            engine.submit(req("cap-$label", OfficePrecisionAction.CAPTURE_TARGET))
            feed(engine, capturedStatus)
            val target = (engine.readAnswer("cap-$label", "tok", 3L)!!
                .answer as OfficePrecisionAnswer.TargetCaptured).target
            assertEquals("presentation", target.docType)
            assertEquals(2, target.partsCount)
            assertEquals(1, target.selectedPartIndex)
            val operation = "apply-$label"
            engine.submit(req(operation, OfficePrecisionAction.APPLY_TEXT,
                text = "x", targetHandle = target.handleId))
            assertEquals("status", host.engineWires.last())
            val before = host.engineWires.size
            feed(engine, freshStatus)
            val refused = engine.readAnswer(operation, "tok", 3L)!!
            assertEquals(label, OfficePrecisionState.FAILED, refused.state)
            assertEquals(label, OfficePrecisionFailure.TARGET_UNVERIFIED, refused.failure)
            assertEquals(label, "pre-effect-part-ordinal-drift", refused.detail)
            assertEquals("$label refused before selection/effect", before, host.engineWires.size)
            assertTrue(label, host.wires.none { it.startsWith("paste ") })
        }
    }

    @Test
    fun manualPageInputWhileThinkingConflictsApply() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(
            engine,
            "status: {\"type\":\"text\",\"partscount\":1,\"selectedpart\":\"0\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target

        // The user manually retargets/types while the model thinks: the
        // forwarded page frame advances the input epoch. ModifiedStatus
        // staying false/true is irrelevant — the apply MUST conflict.
        host.modified = true
        engine.noteForwardedPageCommand("key")
        engine.submit(
            req("ap", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        val result = engine.readAnswer("ap", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, result.state)
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, result.failure)
        assertEquals("manual-input-since-capture", result.detail)
        // No paste wire was ever emitted (refused BEFORE any effect).
        assertTrue(host.wires.none { it.startsWith("paste ") })
    }

    @Test
    fun flushChangedWorkingCopyConflictsApply() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        // An owned flush rewrote the working copy between capture and apply.
        host.digest = "sha-b" to 12L
        engine.submit(
            req("ap", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        val result = engine.readAnswer("ap", "tok", 3L)!!
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, result.failure)
        assertEquals("working-copy-changed", result.detail)
    }

    // ------------------------------------------------------------------
    // Lease: retarget/write fencing, keepalive preserved
    // ------------------------------------------------------------------

    @Test
    fun leaseFencesRetargetAndQueryCollisionsButKeepsRenderKeepalive() {
        val host = FakeHost(format = OfficeDocumentFormat.PPTX)
        val engine = OfficePrecisionEngine(host)
        assertFalse(engine.leaseActive())
        // No lease: nothing is blocked.
        assertFalse(engine.blocksPageCommand("mouse"))

        engine.submit(req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertTrue(engine.leaseActive())
        // Competing SELECTION/PART/WINDOW retargeting + writes + manual
        // history triggers + reply-collision queries are ALL fenced.
        for (blocked in listOf(
            "mouse", "windowmouse", "windowgesture", "key", "windowkey",
            "selecttext", "windowselecttext", "selectgraphic", "resetselection",
            "setclientpart", "selectclientpart", "moveselectedclientparts",
            "uno", "save", "paste", "setviewreadonly", "dialogevent",
            "windowcommand", "gettextselection", "commandvalues",
            "getpresentationinfo", "status", "editcell", "celladdress",
        )) {
            assertTrue("expected lease to fence $blocked", engine.blocksPageCommand(blocked))
        }
        // Allowed lifecycle/cancel/render keepalives keep flowing.
        for (allowed in listOf(
            "tile", "tilecombine", "tileprocessed", "canceltiles", "renderfont",
            "clientvisiblearea", "clientzoom", "clientarea", "resizewindow",
            "paintwindow", "renderwindow", "useractive", "userinactive", "ping",
            "a11ystate", "statusupdate", "rendersearchresult",
        )) {
            assertFalse("lease must not block keepalive $allowed", engine.blocksPageCommand(allowed))
        }
        feed(engine, "textselectioncontent: payload")
        assertFalse(engine.leaseActive())
        assertFalse(engine.blocksPageCommand("mouse"))
    }

    @Test
    fun leaseNoticeIsBoundedToOnePerOperation() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertTrue(engine.claimLeaseNoticeOnce(engine.ledger.armedOpId()))
        assertFalse(engine.claimLeaseNoticeOnce(engine.ledger.armedOpId()))
        feed(engine, "textselectioncontent: x")
    }

    // ------------------------------------------------------------------
    // Wire sequences (exact pinned producer spellings)
    // ------------------------------------------------------------------

    @Test
    fun setCellContentWalksExactPinnedWireLadder() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(
            engine,
            "status: {\"type\":\"spreadsheet\",\"partscount\":1,\"selectedpart\":\"0\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target

        host.wires.clear()
        engine.submit(
            req(
                "cell",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "=SUM(A1:A2)",
                contentKind = OfficePrecisionContentKind.FORMULA,
                cellAddress = "B2",
                targetHandle = target.handleId,
            ),
        )
        // goto-cell (no ack frame in the pinned producer) then the semantic
        // POSITION readback is dispatched before any content effect.
        assertEquals(
            listOf(
                "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"B2\"}}",
                "commandvalues command=.uno:CellCursor",
            ),
            host.wires,
        )
        // Wrong-cell readback FAILS before any paste (target first).
        feed(
            engine,
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 5, 5\"}",
        )
        val failed = engine.readAnswer("cell", "tok", 3L)!!
        assertEquals(OfficePrecisionState.FAILED, failed.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, failed.failure)
        assertTrue(host.wires.none { it.startsWith("paste ") })

        // Correct ladder on a fresh capture.
        engine.submit(req("cap2", OfficePrecisionAction.CAPTURE_TARGET))
        feed(
            engine,
            "status: {\"type\":\"spreadsheet\",\"partscount\":1,\"selectedpart\":\"0\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target2 = (engine.readAnswer("cap2", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.wires.clear()
        engine.submit(
            req(
                "cell2",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "42",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = target2.handleId,
            ),
        )
        feed(
            engine,
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 380, 1219, 256, 1, 1\"}",
        )
        acquirePreEffect(engine, host, "7", type = "spreadsheet")
        feed(engine, "pasteresult: success")
        feed(
            engine,
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 380, 1219, 256, 1, 1\"}",
        )
        feed(engine, "textselectioncontent: 42")
        assertEquals(
            listOf(
                "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"B2\"}}",
                "commandvalues command=.uno:CellCursor",
                "status",
                "gettextselection mimetype=text/plain;charset=utf-8",
                "paste mimetype=text/plain;charset=utf-8\nNDI=",
                "commandvalues command=.uno:CellCursor",
                "gettextselection mimetype=text/plain;charset=utf-8",
            ),
            host.wires,
        )
        val verified = engine.readAnswer("cell2", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, verified.state)
        val evidence = (verified.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals("7", evidence?.selectionText)
        assertEquals("cell2", evidence?.opId)
        assertEquals("0", evidence?.partId)
    }

    @Test
    fun ordinaryDocxSelectAllApplyAcquiresFreshPriorInsideApply() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("read", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        feed(engine, statusFrame)
        val prior = "手记 § Baseline 🧪\nalpha list one"
        engine.submit(req("select", OfficePrecisionAction.SELECT_ALL_TEXT))
        feed(engine, "textselectioncontent: $prior")
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.wires.clear()

        engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "marker", targetHandle = target.handleId))
        acquirePreEffect(engine, host, prior)
        assertEquals(
            listOf(
                "status",
                OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                "paste mimetype=text/plain;charset=utf-8\nbWFya2Vy",
            ),
            host.wires,
        )
        feed(engine, "pasteresult: success")
        // APPLY_TEXT's old/current VIEW selection is not a comparable body
        // conflict; the final saved-OOXML proof remains mandatory.
        feed(engine, "textselectioncontent: $prior")
        val result = engine.readAnswer("apply", "tok", 3L)!!
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, result.state)
        val evidence = (result.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals(prior, evidence?.selectionText)
        assertEquals("apply", evidence?.opId)
        assertEquals(target.handleId, evidence?.targetHandle)
        assertEquals(target.editEpoch, evidence?.editEpoch)
    }

    @Test
    fun ordinaryXlsxFormulaAcquiresPriorDisplayAfterCellNavigationBeforePaste() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("read", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        feed(engine, statusFor("0", "spreadsheet"))
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFor("0", "spreadsheet"))
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.wires.clear()
        engine.submit(req(
            "formula", OfficePrecisionAction.SET_CELL_CONTENT,
            text = "=SUM(B2:B3)", contentKind = OfficePrecisionContentKind.FORMULA,
            cellAddress = "B4", targetHandle = target.handleId,
        ))
        feed(engine, "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 1, 3\"}")
        acquirePreEffect(engine, host, "7", type = "spreadsheet")
        assertEquals(
            listOf(
                "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"B4\"}}",
                OfficePrecisionProtocol.CMD_CELL_CURSOR_VALUES,
                "status",
                OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                "paste mimetype=text/plain;charset=utf-8\nPVNVTShCMjpCMyk=",
            ),
            host.wires,
        )
        feed(engine, "pasteresult: success")
        feed(engine, "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 1, 3\"}")
        val result = engine.readAnswer("formula", "tok", 3L)!!
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, result.state)
        val applied = result.answer as OfficePrecisionAnswer.MutationApplied
        assertEquals(OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE, applied.contentReadback)
        assertEquals("7", applied.preEffectEvidence?.selectionText)
        assertEquals("formula", applied.preEffectEvidence?.opId)
        assertTrue("no formula-source/display post comparison is invented",
            host.wires.count { it == OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION } == 1)
    }

    @Test
    fun ordinaryPptxSelectSlideApplyAcquiresRealEmptyPriorAtSelectedPart() {
        val host = FakeHost(format = OfficeDocumentFormat.PPTX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("read", OfficePrecisionAction.QUERY_PRESENTATION_INFO))
        feed(engine, "presentationinfo: {\"slides\":[{\"slideNumber\":1},{\"slideNumber\":2}]}")
        // Real C15 shape: two slides, scripted "slide 2" (decimal partId "1").
        // Repaired plan: resolve pull (the view still shows page 1's GUID),
        // then setclientpart carrying page 2's OWN GUID, then the proven
        // readback. Pre-repair this dispatched `setclientpart part=1` — a
        // decimal that names no page in the pinned Impress boundary — the
        // selection silently landed nowhere and the honest `status:`
        // readback refused with part-readback-mismatch (the recorded real
        // first failure).
        engine.submit(req("slide", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        feed(engine, presentationStatus(pageGuidA, listOf(pageGuidA, pageGuidB)))
        feed(engine, presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        val slid = engine.readAnswer("slide", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, slid.state)
        val selected = slid.answer as OfficePrecisionAnswer.SlideSelected
        assertEquals(pageGuidB, selected.shownPart)
        assertEquals(1, selected.shownPartIndex)
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        // Full wanted-chain lineage for the real C15 two-slide shape: the
        // capture at the shown page GUID carries the separately witnessed
        // ordinal 1 (second page) — the value the App host records and the
        // OOXML verifier uses to resolve the SECOND ordered slide part.
        assertEquals(pageGuidB, target.selectedPart)
        assertEquals(1, target.selectedPartIndex)
        host.wires.clear()

        engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "marker", targetHandle = target.handleId))
        acquirePreEffect(engine, host, "", part = pageGuidB, type = "presentation",
            status = presentationStatus(pageGuidB, listOf(pageGuidA, pageGuidB)))
        assertEquals(
            listOf(
                "status",
                OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
                "paste mimetype=text/plain;charset=utf-8\nbWFya2Vy",
            ),
            host.wires,
        )
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: ")
        val result = engine.readAnswer("apply", "tok", 3L)!!
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, result.state)
        val evidence = (result.answer as OfficePrecisionAnswer.MutationApplied).preEffectEvidence
        assertEquals("the actual empty native selection is insertion evidence", "", evidence?.selectionText)
        assertEquals(0, evidence?.selectionByteCount)
        assertEquals(pageGuidB, evidence?.partId)
        assertEquals(target.handleId, evidence?.targetHandle)
    }

    @Test
    fun ambiguousCalcPreEffectTextRefusesBeforeAnyPasteWire() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFor("0", "spreadsheet"))
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        engine.submit(req(
            "formula", OfficePrecisionAction.SET_CELL_CONTENT,
            text = "=SUM(B2:B3)", contentKind = OfficePrecisionContentKind.FORMULA,
            cellAddress = "B4", targetHandle = target.handleId,
        ))
        feed(engine, "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 1, 3\"}")
        feed(engine, statusFor("0", "spreadsheet"))
        // No guessed TSV terminator removal/unquoting: an ambiguous single-
        // cell plaintext representation cannot become a semantic baseline.
        feed(engine, "textselectioncontent: 7\n")
        val result = engine.readAnswer("formula", "tok", 3L)!!
        assertEquals(OfficePrecisionState.FAILED, result.state)
        assertEquals(OfficePrecisionFailure.COMPLEX_SELECTION_UNAVAILABLE, result.failure)
        assertEquals("pre-effect-single-cell-plaintext-required", result.detail)
        assertTrue(host.wires.none { it.startsWith("paste ") })
    }

    @Test
    fun wrongPartOrMissingPreEffectAnswerNeverReachesPaste() {
        run {
            val host = FakeHost(format = OfficeDocumentFormat.PPTX)
            val engine = OfficePrecisionEngine(host)
            engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
            feed(engine, statusFor(pageGuidB, "presentation"))
            val target = (engine.readAnswer("capture", "tok", 3L)!!
                .answer as OfficePrecisionAnswer.TargetCaptured).target
            engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId))
            feed(engine, statusFor(pageGuidA, "presentation"))
            val result = engine.readAnswer("apply", "tok", 3L)!!
            assertEquals(OfficePrecisionState.FAILED, result.state)
            assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, result.failure)
            assertEquals("pre-effect-part-mismatch", result.detail)
            assertTrue(host.wires.none { it.startsWith("paste ") })
        }
        run {
            val host = FakeHost()
            val engine = OfficePrecisionEngine(host)
            engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
            feed(engine, statusFrame)
            val target = (engine.readAnswer("capture", "tok", 3L)!!
                .answer as OfficePrecisionAnswer.TargetCaptured).target
            engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId))
            feed(engine, statusFrame)
            host.fireLatestTimeout() // mandatory pre-effect selection answer missing
            val result = engine.readAnswer("apply", "tok", 3L)!!
            assertEquals(OfficePrecisionState.UNKNOWN, result.state)
            assertEquals(OfficePrecisionFailure.TIMEOUT, result.failure)
            assertTrue(host.wires.none { it.startsWith("paste ") })
        }
    }

    @Test
    fun workingCopyDriftDuringPreEffectReadRefusesAtTheActualPasteBoundary() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.beforeWireSend = { message ->
            if (message == OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION) {
                host.beforeWireSend = null
                host.digest = "sha-b" to 12L
            }
        }
        engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId))
        acquirePreEffect(engine, host, "before")
        val result = engine.readAnswer("apply", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, result.state)
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, result.failure)
        assertEquals("pre-paste-working-copy-changed", result.detail)
        assertTrue(host.wires.none { it.startsWith("paste ") })
    }

    @Test
    fun manualEpochDriftDuringPreEffectReadRefusesBeforePaste() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("capture", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("capture", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.beforeWireSend = { message ->
            if (message == OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION) {
                host.beforeWireSend = null
                // Simulates an already-admitted native ingress callback whose
                // epoch update becomes visible while the answer is in flight.
                engine.ledger.notePageInput()
            }
        }
        engine.submit(req("apply", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId))
        acquirePreEffect(engine, host, "before")
        val result = engine.readAnswer("apply", "tok", 3L)!!
        assertEquals(OfficePrecisionState.FAILED, result.state)
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, result.failure)
        assertEquals("pre-effect-manual-input-drift", result.detail)
        assertTrue(host.wires.none { it.startsWith("paste ") })
    }

    @Test
    fun singleCellContentRefusesTabAndNewlineSpread() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target

        // A tab/newline in single-cell content would silently become a
        // MULTI-CELL TSV paste — refused, never applied.
        val tsv = engine.submit(
            req(
                "c1",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "a\tb",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "A1",
                targetHandle = target.handleId,
            ),
        )
        assertEquals(OfficePrecisionState.REJECTED, tsv.state)
        assertEquals(OfficePrecisionFailure.CONTENT_UNSAFE, tsv.failure)
        // Literal/formula intent mismatch is refused both ways.
        val sneakyFormula = engine.submit(
            req(
                "c2",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "=1+1",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "A1",
                targetHandle = target.handleId,
            ),
        )
        assertEquals(OfficePrecisionFailure.CONTENT_UNSAFE, sneakyFormula.failure)
        val fakeFormula = engine.submit(
            req(
                "c3",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "42",
                contentKind = OfficePrecisionContentKind.FORMULA,
                cellAddress = "A1",
                targetHandle = target.handleId,
            ),
        )
        assertEquals(OfficePrecisionFailure.CONTENT_UNSAFE, fakeFormula.failure)
        // APPLY_TEXT on a spreadsheet carries the same single-cell rule.
        val multiline = engine.submit(
            req("c4", OfficePrecisionAction.APPLY_TEXT, text = "a\nb", targetHandle = target.handleId),
        )
        assertEquals(OfficePrecisionFailure.CONTENT_UNSAFE, multiline.failure)
        assertTrue(host.wires.none { it.startsWith("paste ") })
    }

    @Test
    fun preventiveBarrierOrdersAfterPageQueryForwarding() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        // The page ran its own clipboard pull while idle.
        engine.noteForwardedPageCommand("gettextselection")
        engine.submit(req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        // The ordered barrier goes out FIRST; the real query only after its
        // reply (the stale page reply can never complete the fresh op).
        assertEquals(listOf("commandvalues command=.uno:ReadOnly"), host.wires)
        feed(engine, "textselectioncontent: stale-page-copy")
        assertNull("stale page answer must not settle", engine.readAnswer("q", "tok", 3L))
        feed(engine, "commandvalues: {\"commandName\":\".uno:ReadOnly\",\"success\":false}")
        assertEquals(
            listOf(
                "commandvalues command=.uno:ReadOnly",
                "gettextselection mimetype=text/plain;charset=utf-8",
            ),
            host.wires,
        )
        feed(engine, "textselectioncontent: fresh")
        val result = engine.readAnswer("q", "tok", 3L)!!
        assertEquals(OfficePrecisionState.QUERY_OBSERVED, result.state)
        assertEquals("fresh", (result.answer as OfficePrecisionAnswer.TextSelection).text)
    }

    // ------------------------------------------------------------------
    // Timeouts / mount end
    // ------------------------------------------------------------------

    @Test
    fun stepTimeoutIsUnknownAndMountEndSettlesEverything() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertTrue(engine.leaseActive())
        host.fireLatestTimeout()
        val unknown = engine.readAnswer("q", "tok", 3L)!!
        assertEquals(OfficePrecisionState.UNKNOWN, unknown.state)
        assertEquals(OfficePrecisionFailure.TIMEOUT, unknown.failure)
        assertFalse(engine.leaseActive())

        // Mount end settles an in-flight op UNKNOWN (data retained).
        engine.submit(req("q2", OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT))
        assertTrue(engine.leaseActive())
        engine.onMountTerminal()
        val settled = engine.readAnswer("q2", "tok", 3L)!!
        assertEquals(OfficePrecisionState.UNKNOWN, settled.state)
        assertFalse(engine.leaseActive())
    }

    @Test
    fun epochClassesAdvanceOnlyForRetargetWrites() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        val before = engine.ledger.inputEpoch()
        // Keepalive/render traffic never advances the manual-input epoch.
        engine.noteForwardedPageCommand("tile")
        engine.noteForwardedPageCommand("clientvisiblearea")
        engine.noteForwardedPageCommand("useractive")
        assertEquals(before, engine.ledger.inputEpoch())
        // Retarget/write traffic does (unknown commands fail closed to it).
        engine.noteForwardedPageCommand("mouse")
        assertEquals(before + 1, engine.ledger.inputEpoch())
        engine.noteForwardedPageCommand("somefuturecommand")
        assertEquals(before + 2, engine.ledger.inputEpoch())
    }

    @Test
    fun diagnosticsNeverCarryContent() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        engine.readAnswer("cap", "tok", 3L)
        engine.submit(
            req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION),
        )
        feed(engine, "textselectioncontent: SUPER-SECRET-DOCUMENT-TEXT")
        engine.readAnswer("q", "tok", 3L)
        // Identity-safe summaries only: no selected text, formulas, tokens,
        // nonces or paths may reach the diagnostic history.
        for (line in host.diagnostics) {
            assertFalse(line.contains("SUPER-SECRET-DOCUMENT-TEXT"))
            assertFalse(line.contains("tok"))
        }
        assertTrue(host.diagnostics.any { it.contains("state=QUERY_OBSERVED") })
    }

    // ------------------------------------------------------------------
    // Ingress-monitor integration (Main 2026-10-26): atomic admission
    // ------------------------------------------------------------------

    @Test
    fun everyWireDispatchHoldsTheSessionIngressMonitor() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(
            engine,
            "status: {\"type\":\"spreadsheet\",\"partscount\":1,\"selectedpart\":\"0\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        engine.submit(
            req(
                "cell",
                OfficePrecisionAction.SET_CELL_CONTENT,
                text = "42",
                contentKind = OfficePrecisionContentKind.LITERAL,
                cellAddress = "B2",
                targetHandle = target.handleId,
            ),
        )
        feed(
            engine,
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 1, 1\"}",
        )
        acquirePreEffect(engine, host, "7", type = "spreadsheet")
        feed(engine, "pasteresult: success")
        feed(
            engine,
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 0, 10, 10, 1, 1\"}",
        )
        feed(engine, "textselectioncontent: 42")
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, engine.readAnswer("cell", "tok", 3L)!!.state)
        // EVERY real send (capture, goto, pulls, paste, readback) happened
        // under the same monitor that makes an admitted page send atomic —
        // never a bare boolean check followed by an unsynchronized JNI call.
        assertTrue(host.wireUnderMonitor.isNotEmpty())
        assertTrue(
            "wire dispatched outside the ingress monitor",
            host.wireUnderMonitor.all { it },
        )
    }

    @Test
    fun admittedPageSendRacingLeaseStartConflictsTheTarget() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target

        // A page send ADMITTED before the lease exists completes its whole
        // atomic section (check → send → forwarded/epoch update) first, so
        // the apply's under-monitor target validation provably sees it.
        assertTrue(host.admittedPageSend(engine, "mouse"))
        engine.submit(
            req("ap", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        val conflicted = engine.readAnswer("ap", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, conflicted.state)
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, conflicted.failure)
        assertEquals("manual-input-since-capture", conflicted.detail)
        assertTrue(host.wires.none { it.startsWith("paste ") })

        // Reverse order: once the lease is active, a competing page
        // mutation/selection send is refused inside the same monitor and
        // never bumps the epoch (it had no native effect).
        engine.submit(req("cap2", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target2 = (engine.readAnswer("cap2", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        engine.submit(
            req("ap2", OfficePrecisionAction.APPLY_TEXT, text = "y", targetHandle = target2.handleId),
        )
        // ap2 is armed awaiting its pre-effect status answer: the lease is live.
        assertFalse(host.admittedPageSend(engine, "selecttext"))
        assertFalse(host.admittedPageSend(engine, "key"))
        assertFalse(host.admittedPageSend(engine, "setclientpart"))
        // Keepalive still flows during the lease.
        assertTrue(host.admittedPageSend(engine, "tile"))
        acquirePreEffect(engine, host, "before")
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: y")
        assertEquals(
            OfficePrecisionState.MUTATION_VERIFIED,
            engine.readAnswer("ap2", "tok", 3L)!!.state,
        )
    }

    @Test
    fun competingNativeSendsAreGatedByTheLeaseState() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        // The re-check the service performs UNDER the ingress monitor right
        // before a real flush/edit-toggle/undo-redo send.
        assertTrue(engine.canDispatchCompetingNative())
        engine.submit(req("q", OfficePrecisionAction.QUERY_TEXT_SELECTION))
        assertFalse(engine.canDispatchCompetingNative())
        feed(engine, "textselectioncontent: x")
        assertTrue(engine.canDispatchCompetingNative())
    }

    // ------------------------------------------------------------------
    // Callback-emitted frames are corroboration only — never proof
    // ------------------------------------------------------------------

    @Test
    fun retargetOpsNeverSettleOnDelayedCallbackFrames() {
        val host = FakeHost(format = OfficeDocumentFormat.PPTX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        // Repaired proven-readback plan: synchronous `status` resolve pull
        // first, then the setclientpart carrying the PRODUCER's own page
        // GUID (never the decimal request — the C15 defect: `setclientpart
        // part=1` named no page and the honest readback mismatched), then
        // the proving `status` pull.
        assertEquals(listOf("status"), host.wires)
        // A stale decimal-carrying setpart CALLBACK echo never settles the
        // resolve pull (frame + elapsed time is not operation proof).
        feed(engine, "setpart: part=1")
        assertNull(engine.readAnswer("n1", "tok", 3L))
        feed(engine, statusFor(pageGuidA, "presentation")) // view still page 1
        assertEquals(
            listOf("status", "setclientpart part=$pageGuidB", "status"),
            host.wires,
        )
        // Even the perfectly matching setpart echo during the readback is
        // corroboration only.
        feed(engine, "setpart: part=$pageGuidB")
        assertNull(engine.readAnswer("n1", "tok", 3L))
        // Only the pinned-ordering-proven status readback completes it.
        feed(engine, statusFor(pageGuidB, "presentation"))
        val result = engine.readAnswer("n1", "tok", 3L)!!
        assertEquals(OfficePrecisionState.MUTATION_VERIFIED, result.state)
        assertEquals(pageGuidB, (result.answer as OfficePrecisionAnswer.SlideSelected).shownPart)
        // The proven readback answer itself witnesses the shown ordinal —
        // the delayed callback echo above contributed nothing to it.
        assertEquals(1, (result.answer as OfficePrecisionAnswer.SlideSelected).shownPartIndex)

        // SELECT_ALL_TEXT: the callback TEXT_SELECTION frame never settles;
        // the proven selection readback yields the honest PARTIAL state.
        engine.submit(req("s1", OfficePrecisionAction.SELECT_ALL_TEXT))
        assertEquals("uno .uno:SelectAll", host.wires[host.wires.size - 2])
        assertEquals(
            "gettextselection mimetype=text/plain;charset=utf-8",
            host.wires.last(),
        )
        feed(engine, "textselection: 0, 0, 100, 100")
        assertNull(engine.readAnswer("s1", "tok", 3L))
        feed(engine, "textselectioncontent: selected")
        val sel = engine.readAnswer("s1", "tok", 3L)!!
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, sel.state)
        assertEquals("selection-postcondition-partial-readback", sel.detail)
    }

    @Test
    fun precisionRetargetInvalidatesEarlierCapturesIncludingUnknown() {
        val host = FakeHost(format = OfficeDocumentFormat.XLSX)
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap", OfficePrecisionAction.CAPTURE_TARGET))
        feed(
            engine,
            "status: {\"type\":\"spreadsheet\",\"partscount\":2,\"selectedpart\":\"0\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target = (engine.readAnswer("cap", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target

        // A SELECT_SLIDE dispatched but left UNKNOWN (maybe-effect): the
        // sheet context may have moved, so the earlier capture must die.
        engine.submit(req("n1", OfficePrecisionAction.SELECT_SLIDE, partId = "1"))
        host.fireLatestTimeout() // part-index-resolve window expires
        val unknown = engine.readAnswer("n1", "tok", 3L)!!
        assertEquals(OfficePrecisionState.UNKNOWN, unknown.state)

        engine.submit(
            req("ap", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        val refused = engine.readAnswer("ap", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, refused.state)
        assertEquals(OfficePrecisionFailure.APPLY_CONFLICT, refused.failure)
        assertEquals("precision-effect-since-capture", refused.detail)
        assertTrue(host.wires.none { it.startsWith("paste ") })

        // A FRESH capture after the effect is immediately usable. The
        // missed status answer quarantined its kind, so the capture first
        // barrier-fences (proven kinds re-arm through the ordered barrier).
        engine.submit(req("cap2", OfficePrecisionAction.CAPTURE_TARGET))
        assertEquals("commandvalues command=.uno:ReadOnly", host.wires.last())
        feed(engine, "commandvalues: {\"commandName\":\".uno:ReadOnly\",\"success\":false}")
        assertEquals("status", host.wires.last())
        feed(
            engine,
            "status: {\"type\":\"spreadsheet\",\"partscount\":2,\"selectedpart\":\"1\"," +
                "\"width\":10,\"height\":10,\"viewid\":0}",
        )
        val target2 = (engine.readAnswer("cap2", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        assertEquals("1", target2.selectedPart)
        engine.submit(
            req("ap2", OfficePrecisionAction.APPLY_TEXT, text = "y", targetHandle = target2.handleId),
        )
        acquirePreEffect(engine, host, "before", part = "1", type = "spreadsheet")
        assertTrue(host.wires.any { it.startsWith("paste ") })
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: y")
        assertEquals(
            OfficePrecisionState.MUTATION_VERIFIED,
            engine.readAnswer("ap2", "tok", 3L)!!.state,
        )
    }

    // ------------------------------------------------------------------
    // Real page edit-mode handshake + ordered owned dispatch
    // ------------------------------------------------------------------

    @Test
    fun pageViewingDefersMutationUntilActualEditAckAndOrderedNativeAssertion() {
        val host = FakeHost()
        host.pageEditMode = false
        host.deferEditPreparation = true
        val engine = OfficePrecisionEngine(host)

        engine.submit(req("view-select", OfficePrecisionAction.SELECT_ALL_TEXT))
        assertTrue(host.wires.isEmpty())
        assertTrue(host.editPreparationCallbacks.containsKey("view-select"))

        host.completeEditPreparation("view-select")
        // Full ordered trace: the one native-editable assertion, the ONE
        // effect-bearing SelectAll, then the plan's permitted synchronous
        // gettextselection readback (fire-and-forget step advances in-line).
        assertEquals(
            listOf(
                "native-editable",
                "wire:uno .uno:SelectAll",
                "wire:gettextselection mimetype=text/plain;charset=utf-8",
            ),
            host.dispatchEvents,
        )
        assertEquals(listOf(true), host.editAssertionsUnderMonitor)
        feed(engine, "textselectioncontent: selected")
        assertEquals(
            OfficePrecisionState.NATIVE_COMPLETED,
            engine.readAnswer("view-select", "tok", 3L)!!.state,
        )
    }

    @Test
    fun pageViewingAfterEffectSendIsUnknownAndNeverReplays() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("view-lost", OfficePrecisionAction.SELECT_ALL_TEXT))
        // Full ordered trace: the ONE effect-bearing mutation, then the
        // permitted synchronous readback (a query, not a repeated mutation).
        assertEquals(
            listOf(
                "uno .uno:SelectAll",
                "gettextselection mimetype=text/plain;charset=utf-8",
            ),
            host.wires,
        )

        host.pageEditMode = false
        engine.onPageViewingObserved()
        val result = engine.readAnswer("view-lost", "tok", 3L)!!
        assertEquals(OfficePrecisionState.UNKNOWN, result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, result.failure)
        assertEquals("page-viewing-after-effect-dispatch", result.detail)
        assertTrue(result.attestation.contains("page-edit-mode-lost"))
        // Fence adds nothing and replays nothing: the two-wire trace above
        // is the whole dispatch record (SelectAll exactly once, readback
        // never re-issued).
        assertEquals(2, host.wires.size)

        // A late answer cannot revive or repeat the already-settled effect.
        feed(engine, "textselectioncontent: selected")
        assertEquals(2, host.wires.size)
        assertNull(engine.readAnswer("view-lost", "tok", 3L))
    }

    @Test
    fun synchronousPageOffInsideNativeSendSeesConservativeEffectMarker() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        host.beforeWireSend = { message ->
            if (message == "uno .uno:SelectAll") {
                host.beforeWireSend = null
                host.pageEditMode = false
                // Re-enter before sendWire returns, as a native/page callback
                // may do. The wire is then recorded as potentially landed.
                engine.onPageViewingObserved()
            }
        }

        engine.submit(req("view-reentry", OfficePrecisionAction.SELECT_ALL_TEXT))
        val result = engine.readAnswer("view-reentry", "tok", 3L)!!
        assertEquals(OfficePrecisionState.UNKNOWN, result.state)
        assertEquals(OfficePrecisionFailure.TARGET_UNVERIFIED, result.failure)
        assertEquals("page-viewing-after-effect-dispatch", result.detail)
        assertEquals(listOf("uno .uno:SelectAll"), host.wires)
    }

    @Test
    fun pageViewingBeforeEffectSendRejectsWithoutPlanWire() {
        val host = FakeHost()
        host.pageEditMode = false
        host.deferEditPreparation = true
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("view-before", OfficePrecisionAction.SELECT_ALL_TEXT))
        engine.onPageViewingObserved()

        val result = engine.readAnswer("view-before", "tok", 3L)!!
        assertEquals(OfficePrecisionState.REJECTED, result.state)
        assertEquals(OfficePrecisionFailure.NOT_EDITABLE, result.failure)
        assertEquals("page-viewing-before-dispatch", result.detail)
        assertTrue(host.wires.isEmpty())
        assertTrue(host.editPreparationCallbacks.isEmpty())
    }

    @Test
    fun asyncEditContinuationConsumesTargetUnderIngressMonitor() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap-lock", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("cap-lock", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.dispatchEvents.clear()
        host.digestUnderMonitor.clear()
        host.pageEditMode = false
        host.deferEditPreparation = true

        engine.submit(
            req("apply-lock", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        assertTrue(host.wires.none { it.startsWith("paste ") })
        host.completeEditPreparation("apply-lock")
        assertTrue(host.digestUnderMonitor.isNotEmpty())
        assertTrue(host.digestUnderMonitor.last())
        assertEquals("native-editable", host.dispatchEvents.first())
        acquirePreEffect(engine, host, "before")
        assertTrue(host.dispatchEvents.any { it.startsWith("wire:paste ") })

        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: x")
        assertEquals(
            OfficePrecisionState.MUTATION_VERIFIED,
            engine.readAnswer("apply-lock", "tok", 3L)!!.state,
        )
    }

    @Test
    fun failedEditPreparationDoesNotConsumeSingleUseTarget() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        engine.submit(req("cap-prep", OfficePrecisionAction.CAPTURE_TARGET))
        feed(engine, statusFrame)
        val target = (engine.readAnswer("cap-prep", "tok", 3L)!!
            .answer as OfficePrecisionAnswer.TargetCaptured).target
        host.pageEditMode = false
        host.deferEditPreparation = true
        host.editPreparationFailure = OfficePrecisionFailure.NOT_EDITABLE

        engine.submit(
            req("apply-prep-fail", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        assertEquals(
            OfficePrecisionFailure.NOT_EDITABLE,
            engine.readAnswer("apply-prep-fail", "tok", 3L)!!.failure,
        )
        assertTrue(host.wires.none { it.startsWith("paste ") })

        host.editPreparationFailure = null
        host.deferEditPreparation = false
        host.pageEditMode = true
        engine.submit(
            req("apply-prep-ok", OfficePrecisionAction.APPLY_TEXT, text = "x", targetHandle = target.handleId),
        )
        acquirePreEffect(engine, host, "before")
        assertTrue(host.wires.any { it.startsWith("paste ") })
        feed(engine, "pasteresult: success")
        feed(engine, "textselectioncontent: x")
        assertEquals(
            OfficePrecisionState.MUTATION_VERIFIED,
            engine.readAnswer("apply-prep-ok", "tok", 3L)!!.state,
        )
    }

    // ------------------------------------------------------------------
    // Reply-budget gate (Main marshalling review 2026-10-27)
    // ------------------------------------------------------------------

    @Test
    fun readAnswerRefusesOversizeRepliesBeforeConsuming() {
        val host = FakeHost()
        val engine = OfficePrecisionEngine(host)
        // Defence in depth: a stored result whose serialized UTF-16 reply
        // would exceed the binder budget is replaced BEFORE consumption —
        // never truncated, never lost to TransactionTooLargeException.
        val huge = String(CharArray(OfficePrecisionProtocol.MAX_REPLY_PARCEL_BYTES) { 'x' })
        val stored = OfficePrecisionResult(
            opId = "huge",
            sessionToken = "tok",
            generation = 3L,
            action = OfficePrecisionAction.QUERY_TEXT_SELECTION,
            state = OfficePrecisionState.QUERY_OBSERVED,
            failure = null,
            detail = null,
            answer = OfficePrecisionAnswer.TextSelection(huge, huge.length, false),
            attestation = "text-selection-pull:selection-bytes=786432",
            submittedAtElapsedMs = 1L,
            completedAtElapsedMs = 2L,
        )
        assertTrue(!OfficePrecisionProtocol.fitsReplyBudget(stored))
        engine.ledger.recordRejection(stored)
        val refusal = engine.readAnswer("huge", "tok", 3L)!!
        // An oversize READ is never labelled successful content.
        assertEquals(OfficePrecisionState.FAILED, refusal.state)
        assertEquals(OfficePrecisionFailure.ANSWER_TOO_LARGE, refusal.failure)
        assertNull(refusal.answer)
        assertTrue(refusal.detail!!.contains("content-bytes=${huge.length}"))
        assertTrue(refusal.attestation.contains("reply-budget-refused"))
        // Consumed exactly once: the oversize original is gone.
        assertNull(engine.readAnswer("huge", "tok", 3L))

        // A completed mutation's SMALL receipt passes the same gate intact
        // (the effect that already occurred keeps its state and receipt).
        val mutation = OfficePrecisionResult(
            opId = "mut",
            sessionToken = "tok",
            generation = 3L,
            action = OfficePrecisionAction.APPLY_TEXT,
            state = OfficePrecisionState.NATIVE_COMPLETED,
            failure = null,
            detail = "pending-flush-or-export-verification",
            answer = OfficePrecisionAnswer.MutationApplied(
                steps = listOf("paste-text:pasteresult-success", "content-readback:no-answer"),
                pastedBytes = 5,
                contentReadback = OfficePrecisionContentReadback.UNAVAILABLE,
                workingCopySha256 = "sha-a",
                consumedTargetHandle = "0123456789abcdef0123456789abcdef",
            ),
            attestation = "paste-text:pasteresult-success+content-readback:no-answer",
            submittedAtElapsedMs = 1L,
            completedAtElapsedMs = 2L,
        )
        assertTrue(OfficePrecisionProtocol.fitsReplyBudget(mutation))
        engine.ledger.recordRejection(mutation)
        val kept = engine.readAnswer("mut", "tok", 3L)!!
        assertEquals(OfficePrecisionState.NATIVE_COMPLETED, kept.state)
        assertTrue(kept.answer is OfficePrecisionAnswer.MutationApplied)
    }
}
