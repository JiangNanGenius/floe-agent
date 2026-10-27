// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.precision.OfficePrecisionState
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Session ledger regressions (Main host20, AUTHORED NOTRUN — Main runs the
 * composed batch). The ledgers are the host's ONLY source for the owned
 * proof facts the verifier and the shared gate consume: capture identity +
 * retained baseline, effect correlation, operation guards that keep the
 * manual picker away from AI exports, and exact session binds. All must be
 * bounded, exact-key and never optimistic.
 */
class OfficeAiLedgersTest {

    private val session = "sess-abc"
    private val other = "sess-xyz"

    // ---- effect correlation ----

    private fun effect(
        opId: String, handle: String, generation: Long = 9L, token: String = session,
        state: OfficePrecisionState? = OfficePrecisionState.MUTATION_VERIFIED,
    ) = OfficeAiEffectRecord(
        sessionToken = token, generation = generation, ownerTaskID = "task",
        targetHandle = handle, opId = opId, action = "setCellContent",
        expectedSha256 = "e".repeat(64), terminalState = state,
        workingCopySha256AfterEffect = null, dispatchedAtElapsedMs = 0L,
    )

    @Test
    fun mutationProofRequiresExactQuadrupleAndRealTerminal() {
        val ledger = EffectLedger { 0L }
        ledger.recordDispatched(effect("ap-1", "a".repeat(32)))
        assertTrue(ledger.provesMutationVerified(session, 9L, "a".repeat(32), "ap-1"))
        // Any part of the identity differing proves NOTHING.
        assertFalse(ledger.provesMutationVerified(session, 10L, "a".repeat(32), "ap-1"))
        assertFalse(ledger.provesMutationVerified(session, 9L, "b".repeat(32), "ap-1"))
        assertFalse(ledger.provesMutationVerified(session, 9L, "a".repeat(32), "ap-2"))
        assertFalse(ledger.provesMutationVerified(other, 9L, "a".repeat(32), "ap-1"))
        // nativeCompleted/unknown are NOT mutation proof.
        val pending = EffectLedger { 0L }
        pending.recordDispatched(effect("ap-3", "c".repeat(32), state = null))
        pending.settleOpId(session, "ap-3", OfficePrecisionState.NATIVE_COMPLETED, null)
        assertFalse(pending.provesMutationVerified(session, 9L, "c".repeat(32), "ap-3"))
        pending.settleOpId(session, "ap-3", OfficePrecisionState.UNKNOWN, null)
        assertFalse(pending.provesMutationVerified(session, 9L, "c".repeat(32), "ap-3"))
        pending.settleOpId(session, "ap-3", OfficePrecisionState.MUTATION_VERIFIED, "f".repeat(64))
        assertTrue(pending.provesMutationVerified(session, 9L, "c".repeat(32), "ap-3"))
    }

    @Test
    fun alreadyDispatchedClosesReplayAcrossSettledAndUnknown() {
        val ledger = EffectLedger { 0L }
        ledger.recordDispatched(effect("ap-9", "d".repeat(32), state = null))
        assertTrue(ledger.alreadyDispatched(session, "ap-9"))
        ledger.settleOpId(session, "ap-9", OfficePrecisionState.UNKNOWN, null)
        // Even an UNKNOWN outcome keeps the no-replay gate CLOSED (retained,
        // never re-applied; the reconcile/collect path decides honestly).
        assertTrue(ledger.alreadyDispatched(session, "ap-9"))
        assertFalse(ledger.alreadyDispatched(session, "ap-other"))
    }

    // ---- capture store ----

    private fun capture(
        token: String, handle: String, clockNow: Long,
        baseline: File? = null, sha: String? = baseline?.let { "0".repeat(64) },
        expires: Long = clockNow + 10_000L,
        generation: Long = 9L,
    ) = OfficeAiCaptureRecord(
        sessionToken = token, generation = generation, ownerTaskID = "task",
        workspaceID = null, targetHandle = handle, docType = "writer", partsCount = 1,
        selectedPart = "0", partIndex = 0, documentModified = false,
        inputEpoch = 4L, editEpoch = 5L,
        workingCopySha256AtCapture = sha, workingCopyBytesAtCapture = 4L,
        baselineFile = baseline, baselineSha256 = sha, baselineBytes = baseline?.length() ?: -1L,
        capturedAtElapsedMs = clockNow, expiresAtElapsedMs = expires,
    )

    @Test
    fun captureStoreIsBoundedAndExactHandle() {
        var now = 100L
        val store = CaptureStore { now }
        val tmp = File(System.getProperty("java.io.tmpdir"), "floe-capture-" + UUID.randomUUID())
        tmp.mkdirs()
        repeat(6) { index ->
            val baseline = File(tmp, "b$index.bin").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
            store.put(capture(session, "%032x".format(index), now, baseline))
            now += 1
        }
        // Newest exact handle resolves; older ones beyond the per-session cap
        // are evicted (bounded, never unbounded retention).
        assertNotNull(store.get(session, "%032x".format(5)))
        assertNull(store.get(session, "%032x".format(0)))
        assertEquals(4, store.count().coerceAtMost(4))
        assertNull(store.get(other, "%032x".format(5)))
        store.forgetSession(session)
        assertEquals(0, store.count())
    }

    // ---- selection ledger ----

    @Test
    fun selectionFactsAreGenerationExact() {
        val ledger = SelectionLedger()
        ledger.observe(OfficeAiSelectionFact(session, 9L, "chosen", 6, 1L))
        assertEquals("chosen", ledger.forSession(session, 9L)?.selectionText)
        // A remounted generation must not reuse the old selection baseline.
        assertNull(ledger.forSession(session, 10L))
        assertNull(ledger.forSession(other, 9L))
    }

    private fun preEffect(
        handle: String, opId: String, text: String,
        token: String = session, generation: Long = 9L,
        partId: String = "0", inputEpoch: Long = 4L, editEpoch: Long = 5L,
    ) = OfficeAiPreEffectSelectionFact(
        sessionToken = token, generation = generation, targetHandle = handle,
        effectOpId = opId, partId = partId, inputEpoch = inputEpoch, editEpoch = editEpoch,
        selectionText = text, selectionByteCount = text.toByteArray(Charsets.UTF_8).size,
    )

    @Test
    fun preEffectBindingRequiresExactCaptureScopeAndCannotBeRewritten() {
        val ledger = SelectionLedger()
        val handle = "a".repeat(32)
        val captured = capture(session, handle, 100L)
        // Ambient observations never become effect proof by themselves.
        ledger.observe(OfficeAiSelectionFact(session, 9L, "ambient", 7, 1L))
        assertNull(ledger.forEffect(session, 9L, handle, "apply-1"))
        assertTrue(ledger.bindPreEffect(preEffect(handle, "apply-1", "before\n🧪"), captured))
        assertEquals("before\n🧪", ledger.forEffect(session, 9L, handle, "apply-1")?.selectionText)
        assertNull(ledger.forEffect(other, 9L, handle, "apply-1"))
        assertNull(ledger.forEffect(session, 10L, handle, "apply-1"))
        assertNull(ledger.forEffect(session, 9L, "b".repeat(32), "apply-1"))
        assertNull(ledger.forEffect(session, 9L, handle, "apply-2"))
        // Late facts, another op and every capture-scope drift fail closed.
        assertFalse(ledger.bindPreEffect(preEffect(handle, "apply-1", "late"), captured))
        assertEquals("before\n🧪", ledger.forEffect(session, 9L, handle, "apply-1")?.selectionText)
        assertFalse(ledger.bindPreEffect(preEffect(handle, "apply-2", "wrong", partId = "1"), captured))
        assertFalse(ledger.bindPreEffect(preEffect(handle, "apply-2", "wrong", inputEpoch = 6L), captured))
        assertFalse(ledger.bindPreEffect(preEffect(handle, "apply-2", "wrong", editEpoch = 6L), captured))
        assertFalse(ledger.bindPreEffect(preEffect(handle, "apply-2", "wrong", generation = 10L), captured))
        assertFalse(ledger.bindPreEffect(preEffect("b".repeat(32), "apply-2", "wrong"), captured))
        assertTrue(ledger.bindPreEffect(preEffect(handle, "apply-2", "next"), captured))
        assertEquals("next", ledger.forEffect(session, 9L, handle, "apply-2")?.selectionText)
        ledger.forgetSession(session)
        assertNull(ledger.forEffect(session, 9L, handle, "apply-1"))
    }

    // ---- session binds ----

    @Test
    fun bindsAreBoundedLruAndExactToken() {
        val binds = SessionBinds()
        repeat(SessionBinds.MAX_BINDS + 3) { index ->
            binds.bind(OfficeAiSessionBind(
                sessionToken = "s$index", nativeGeneration = 1L, ownerTaskID = "t",
                workspaceID = null, nativeEpoch = 1L, viewerIncarnation = index.toLong(),
                sourceLogicalPath = null, stagedWorkingCopyPath = null,
                stagedWorkingCopySha256 = null, format = "docx", boundAtElapsedMs = 0L,
            ))
        }
        assertNotNull(binds.get("s${SessionBinds.MAX_BINDS + 2}"))
        assertNull(binds.get("s0")) // oldest evicted first
    }

    // ---- operation guard ----

    @Test
    fun operationGuardIsExactKeyAndBounded() {
        val guard = OfficeAiOperationGuard()
        guard.track("s1", "op-1")
        assertTrue(guard.contains("s1", "op-1"))
        assertFalse(guard.contains("s1", "op-2"))
        assertFalse(guard.contains("s2", "op-1"))
        repeat(OfficeAiOperationGuard.MAX_TRACKED + 5) { index ->
            guard.track("bulk", "op-$index")
        }
        // Oldest ages out; the newest stays tracked. A tracked AI op can
        // NEVER reach the manual SAF picker (the host consults this guard on
        // EVERY prepare request); an aged-out long-lost op has nothing left
        // the viewer can legitimately re-prepare either, since the manual
        // flow mints its own fresh opIds.
        assertTrue(guard.contains("bulk", "op-${OfficeAiOperationGuard.MAX_TRACKED + 4}"))
        assertFalse(guard.contains("bulk", "op-0"))
    }
}
